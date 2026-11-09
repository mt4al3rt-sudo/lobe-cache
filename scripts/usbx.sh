#!/usr/bin/env bash
# usbx v0.9.1 — Universal Sandbox Skill (LobeHub Cloud Sandbox Free)
# Satu pintu masuk: readiness, lazy bootstrap, checkpoint/resume, anti-duplikat,
# token saver, read-back verify, cost/error log. REUSE-FIRST, tidak menambah infra.
#
# v0.9.1 (patch keamanan/reliabilitas, aditif):
#   doc_find nyata (judul+task-key tepat), bootstrap FAIL-CLOSED, payload byte-exact
#   (trailing newline utuh), verifikasi hapus & flush log, validasi task-key,
#   fallback KB lokal saat lh gagal. Lock tetap LOKAL, bukan lintas-sandbox.
#
#   usbx ready                 cek kesiapan sandbox + lh (retry 3x, fallback resmi)
#   usbx boot [--ocr-only|--with-whisper|--models-only|--plan]
#   usbx ckpt save <KEY> [DESC] [FILE|-]   simpan checkpoint ke KB (payload via stdin)
#   usbx ckpt get <KEY>        pulihkan + verifikasi sha256 (payload mentah ke stdout)
#   usbx ckpt list [PREFIX]    cari checkpoint berdasarkan task-key
#   usbx ckpt del <KEY>        hapus 1 checkpoint (wajib cocok persis + verifikasi)
#   usbx guard <KEY> -- <cmd...>           single-writer LOKAL (flock), bukan global
#   usbx trim '<jq-filter>' [maxbytes]     saring data besar sebelum ke LLM
#   usbx verify <FILE> [SHA]   baca ulang file, cocokkan sha256
#   usbx log <KEY> <pesan> | usbx log flush
#
# Exit: 0 ok, 2 argumen/data, 3 lingkungan (lh/sandbox), 4 verifikasi gagal,
#       5 lock aktif, 6 output dipotong.
set -uo pipefail
USBX_VER="0.9.1"
KB="${USBX_KB:-kb_pEpJxnLfdrAR}"
PROJ="${USBX_PROJECTS:-docs_mHQhSgO9pI2YFR3r}"
BOOT_URL="${USBX_BOOT_URL:-https://raw.githubusercontent.com/mt4al3rt-sudo/lobe-cache/main/scripts/bootstrap.sh}"
BOOT_SHA="${USBX_BOOT_SHA:-3168ae1c65093795222c299df429a6afb9beaa8e1e69ddd7167e7c8271eb01ef}"
STATE="${USBX_STATE:-/tmp/usbx-state}"; LOGF="$STATE/usbx.log"
mkdir -p "$STATE/locks"

LH="${USBX_LH:-}"
lh_candidates() {
  local c
  [ -n "${USBX_LH:-}" ] && printf '%s\n' "$USBX_LH"
  for c in $(printf '%s' "$PATH" | tr ':' ' '); do [ -x "$c/lh" ] && printf '%s\n' "$c/lh"; done
  ls -1t /tmp/tmp.*/lh 2>/dev/null
  c=$(command -v lh 2>/dev/null) && [ -n "$c" ] && printf '%s\n' "$c"
}

# Pilih biner lh pertama yang benar-benar bisa bicara ke API.
need_lh() {
  local i c
  for i in 1 2 3; do
    while IFS= read -r c; do
      [ -n "$c" ] && [ -x "$c" ] || continue
      if "$c" kb list >/dev/null 2>&1; then LH="$c"; printf '%s' "$LH"; return 0; fi
    done <<EOF
$(lh_candidates | awk '!seen[$0]++')
EOF
    sleep 2
  done
  echo "[usbx] GAGAL: tidak ada lh siap (PATH / /tmp/tmp.* / global). Fallback resmi: lh login atau lh doctor" >&2
  return 3
}

# --- validasi task-key: cegah path traversal & karakter kendali ---
valid_key() {
  local k="${1:-}"
  [ -n "$k" ] || return 1
  case "$k" in *..*|*/*|*\\*|*[[:space:]]*|*[[:cntrl:]]*) return 1 ;; esac
  printf '%s' "$k" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
}
require_key() {
  valid_key "${1:-}" && return 0
  echo "[usbx] task-key tidak valid: '${1:-}' (hanya A-Za-z0-9 . _ - , maks 64, tanpa '..' / '/' / spasi)" >&2
  return 2
}

# --- akses dokumen lh ---
doc_list_json() { [ -n "${LH:-}" ] || return 1; "$LH" doc list --json id,title -L 200 --all 2>/dev/null; }

# doc_find <title-prefix> [--unique]
# Prefix wajib memuat pemisah ('CHECKPOINT <KEY> —'), sehingga task-key A tidak
# pernah cocok dengan task-key A2. Hasil ganda: default pakai yang pertama +
# PERINGATAN; dengan --unique batal (rc 2) daripada menebak dokumen yang salah.
doc_find() {
  local want="${1:-}" mode="${2:-}"
  [ -n "$want" ] || return 0
  local j ids n
  j=$(doc_list_json) || return 0
  ids=$(printf '%s' "$j" | jq -r --arg w "$want" '
    if type=="array" then
      [ .[]? | select(((.title // "") | startswith($w))) | .id ]
    else empty end | .[]' 2>/dev/null) || return 0
  [ -n "$ids" ] || return 0
  n=$(printf '%s\n' "$ids" | grep -c .)
  if [ "$n" -gt 1 ]; then
    echo "[usbx] PERINGATAN: $n dokumen cocok prefix '$want': $(printf '%s' "$ids" | tr '\n' ' ')" >&2
    if [ "$mode" = "--unique" ]; then
      echo "[usbx] BATAL: judul tidak unik — rapikan duplikat dulu, jangan menebak" >&2
      return 2
    fi
  fi
  printf '%s\n' "$ids" | head -1
}
ckpt_prefix() { printf 'CHECKPOINT %s —' "${1:-}"; }

# Ambil PAYLOAD-B64 dari keluaran `lh doc view` (tahan baris terlipat/spasi).
doc_b64() {
  printf '%s\n' "${1:-}" | awk '
    /PAYLOAD-B64:/ { sub(/.*PAYLOAD-B64:[ \t]*/, ""); c=1; print; next }
    c && /^[ \t]*$/ { exit }
    c { print }' | tr -d ' \t\r\n'
}
doc_sha_field() { printf '%s\n' "${1:-}" | sed -n 's/.*PAYLOAD-SHA256:[[:space:]]*\([a-f0-9]\{64\}\).*/\1/p' | head -1; }

cmd_ready() {
  echo "[usbx] versi      : $USBX_VER"
  echo "[usbx] arch       : $(uname -m) (arm64/aarch64 = tanpa aset prebuilt x86_64)"
  echo "[usbx] python3    : $(command -v python3 || echo TIDAK-ADA)"
  echo "[usbx] jq/flock   : $(command -v jq >/dev/null && echo ok || echo TIDAK-ADA) / $(command -v flock >/dev/null && echo ok || echo TIDAK-ADA)"
  echo "[usbx] sha256sum  : $(command -v sha256sum >/dev/null && echo ok || echo TIDAK-ADA)"
  echo "[usbx] tesseract  : $(command -v tesseract >/dev/null && tesseract --version 2>/dev/null | head -1 || echo belum)"
  python3 -c "import rapidocr_onnxruntime" >/dev/null 2>&1 && echo "[usbx] rapidocr   : ok" || echo "[usbx] rapidocr   : belum"
  [ -f /tmp/whisper-models/small/model.bin ] && echo "[usbx] whisper    : ada (/tmp/whisper-models/small)" || echo "[usbx] whisper    : tidak ada (mode OCR saja)"
  local L; if L=$(need_lh); then
    local who; who=$("$L" user info 2>/dev/null | jq -r '.username // .email // "?"' 2>/dev/null)
    echo "[usbx] lh         : $("$L" --version 2>/dev/null | head -1) | auth ok | user: ${who:-?}"
    "$L" kb view "$KB" >/dev/null 2>&1 && echo "[usbx] KB memori  : $KB ok" || echo "[usbx] KB memori  : TIDAK TERBACA ($KB)"
  else echo "[usbx] lh         : TIDAK SIAP"; return 3; fi
}

cmd_boot() {
  local mode="${1:---ocr-only}"
  case "$mode" in --ocr-only|--with-whisper|--models-only|--plan|--help) ;; *) echo "[usbx] mode tidak dikenal: $mode" >&2; return 2 ;; esac
  case "$mode" in
    --ocr-only|--plan)
      if [ "$mode" = "--ocr-only" ] && command -v tesseract >/dev/null 2>&1 && python3 -c "import rapidocr_onnxruntime" >/dev/null 2>&1; then
        echo "[usbx] sudah siap (tesseract + rapidocr) — tidak mengunduh apa pun"; return 0; fi ;;
    --with-whisper|--models-only)
      [ -f /tmp/whisper-models/small/model.bin ] && [ "$mode" = "--models-only" ] && { echo "[usbx] model whisper sudah ada"; return 0; } ;;
  esac
  local bs="/tmp/bs.sh" s
  if [ ! -s "$bs" ]; then
    echo "[usbx] ambil bootstrap.sh"
    curl -fsSL -o "$bs" "$BOOT_URL" || { echo "[usbx] GAGAL unduh bootstrap.sh" >&2; return 3; }
  fi
  s=$(sha256sum "$bs" | cut -d' ' -f1)
  if [ "$s" != "$BOOT_SHA" ]; then
    echo "[usbx] sha lokal ($s) != pin — unduh ulang sekali untuk menyingkirkan berkas basi"
    curl -fsSL -o "$bs" "$BOOT_URL" || { echo "[usbx] GAGAL unduh ulang bootstrap.sh" >&2; return 3; }
    s=$(sha256sum "$bs" | cut -d' ' -f1)
  fi
  echo "[usbx] bootstrap.sh sha256=$s"
  # FAIL-CLOSED: hash tidak cocok = skrip TIDAK dijalankan.
  if [ -z "$s" ] || [ "$s" != "$BOOT_SHA" ]; then
    echo "[usbx] BOOT FAIL-CLOSED: sha256 ($s) != pin ($BOOT_SHA). Skrip TIDAK dijalankan." >&2
    echo "[usbx] Periksa manual: less $bs — jangan jalankan sebelum yakin." >&2
    return 4
  fi
  bash "$bs" "$mode"; local rc=$?
  [ -f /tmp/lobe-cache/whisper_env.sh ] && echo "[usbx] env: source /tmp/lobe-cache/whisper_env.sh"
  return $rc
}

cmd_ckpt() {
  local sub="${1:-}"; shift || true
  local key="${1:-}"; [ $# -gt 0 ] && shift || true
  case "$sub" in
    save)
      local desc="${1:-Sandbox checkpoint}"; local src="${2:--}"
      require_key "$key" || return 2
      local pf="$STATE/ckpt-$key.payload"
      if [ "$src" = "-" ]; then
        cat >"$pf"
      else
        [ -f "$src" ] || { echo "[usbx] file tidak ada: $src" >&2; return 2; }
        cp -- "$src" "$pf" || { echo "[usbx] gagal menyalin payload" >&2; return 2; }
      fi
      [ -s "$pf" ] || { echo "[usbx] payload kosong" >&2; return 2; }
      local sha b64 ts f title
      # sha & base64 dari BERKAS, bukan variabel: trailing newline tetap utuh.
      sha=$(sha256sum "$pf" | cut -d' ' -f1)
      b64=$(base64 -w0 <"$pf")
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      title="CHECKPOINT $key — $desc"
      f="$STATE/ckpt-$key.md"
      { printf 'Checkpoint Universal Sandbox v%s.\n\nTASK-KEY: %s\nCREATED: %s\nARCH: %s\nSANDBOX: %s\n\nPAYLOAD-SHA256: %s\nPAYLOAD-B64: %s\n\nRESUME: ambil PAYLOAD-B64, base64 -d, lalu cocokkan PAYLOAD-SHA256. Jangan hapus tanpa cek task-key.\n' \
        "$USBX_VER" "$key" "$ts" "$(uname -m)" "${HOSTNAME:-sandbox}" "$sha" "$b64"; } >"$f"
      local L
      if ! L=$(need_lh); then
        echo "[usbx] PENDING-LH: checkpoint lokal siap ($f, payload $pf)."
        echo "[usbx] Fallback resmi: simpan isi berkas berikut sebagai dokumen KB $KB (judul di atas), lalu verifikasi read-back."
        echo "-----BEGIN CKPT $key-----"; cat "$f"; echo "-----END CKPT $key-----"
        return 3
      fi
      local out id
      out=$("$L" doc create -t "$title" -F "$f" --kb "$KB" --parent "$PROJ" 2>&1) || { echo "[usbx] GAGAL create: $out" >&2; return 3; }
      id=$(printf '%s' "$out" | grep -o 'docs_[A-Za-z0-9]*' | head -1)
      [ -n "$id" ] || id=$(doc_find "$(ckpt_prefix "$key")")
      [ -n "$id" ] || { echo "[usbx] GAGAL: dokumen tidak ditemukan setelah create" >&2; return 3; }
      # read-back verification
      local back hit got
      back=$("$L" doc view "$id" 2>/dev/null)
      hit=$(doc_b64 "$back")
      got=$(printf '%s' "$hit" | base64 -d 2>/dev/null | sha256sum | cut -d' ' -f1)
      if [ -n "$hit" ] && [ "$got" = "$sha" ]; then
        echo "[usbx] CKPT PASS  key=$key id=$id sha=$sha"
      else
        echo "[usbx] CKPT FAIL  key=$key id=$id (read-back tidak cocok: ${got:-kosong})" >&2
        echo "[usbx] FALLBACK: berkas lokal siap -> $f ; simpan manual ke KB $KB bila API tidak konsisten" >&2
        return 4
      fi ;;
    get)
      require_key "$key" || return 2
      local L; L=$(need_lh) || L=""
      local id="" back=""
      if [ -n "$L" ]; then
        id=$(doc_find "$(ckpt_prefix "$key")" --unique) || return 2
        [ -n "$id" ] && back=$("$L" doc view "$id" 2>/dev/null)
      fi
      local b64 sha2 src="kb"
      if [ -n "$back" ]; then
        b64=$(doc_b64 "$back"); sha2=$(doc_sha_field "$back")
      elif [ -s "$STATE/ckpt-$key.md" ]; then
        echo "[usbx] PENDING-LH: lh/KB tidak siap — pulih dari cache lokal $STATE/ckpt-$key.md" >&2
        back=$(cat "$STATE/ckpt-$key.md"); src="lokal"
        b64=$(doc_b64 "$back"); sha2=$(doc_sha_field "$back")
      else
        echo "[usbx] TIDAK ADA checkpoint untuk key=$key (lh/KB tidak siap, cache lokal kosong)" >&2
        [ -n "$L" ] && return 2 || return 3
      fi
      [ -n "$b64" ] || { echo "[usbx] GAGAL: payload tidak ada di ${id:-$src}" >&2; return 4; }
      local of="$STATE/ckpt-$key.out"
      printf '%s' "$b64" | base64 -d >"$of" 2>/dev/null || { echo "[usbx] GAGAL decode base64 (${id:-$src})" >&2; return 4; }
      local got; got=$(sha256sum "$of" | cut -d' ' -f1)
      if [ "$got" = "$sha2" ]; then
        echo "[usbx] CKPT PASS  key=$key id=${id:-$src} sha=$sha2" >&2
        cat "$of"
      else
        echo "[usbx] CKPT FAIL  sha tidak cocok (dapat $got, harap ${sha2:-?})" >&2; return 4
      fi ;;
    list)
      local L; L=$(need_lh) || { echo "[usbx] PENDING-LH: daftar tidak terbaca; pakai 'usbx ckpt get <KEY>' (cache lokal) atau baca KB via tool" >&2; return 3; }
      if [ -n "$key" ]; then require_key "$key" || return 2; fi
      local r="CHECKPOINT ${key:-}"
      "$L" doc list --json id,title -L 200 --all 2>/dev/null | jq -r --arg r "$r" '.[]? | select((.title // "")|startswith($r)) | "\(.id)\t\(.title)"' ;;
    del)
      require_key "$key" || return 2
      local L; L=$(need_lh) || { echo "[usbx] PENDING-LH: hapus tidak bisa diverifikasi tanpa lh. Tidak ada klaim sukses." >&2; return 3; }
      local id; id=$(doc_find "$(ckpt_prefix "$key")" --unique) || return 2
      [ -n "$id" ] || { echo "[usbx] tidak ada checkpoint berjudul tepat 'CHECKPOINT $key —'" >&2; return 2; }
      # identitas: judul (dari listing) + TASK-KEY di isi dokumen, keduanya wajib cocok
      local title body
      title=$(printf '%s' "$(doc_list_json)" | jq -r --arg id "$id" '.[]? | select(.id==$id) | .title' 2>/dev/null | head -1)
      printf '%s' "$title" | grep -Fq "CHECKPOINT $key —" || { echo "[usbx] identitas judul tidak cocok, batal: ${title:-?}" >&2; return 4; }
      body=$("$L" doc view "$id" 2>/dev/null)
      printf '%s\n' "$body" | grep -Fxq "TASK-KEY: $key" || { echo "[usbx] isi dokumen bukan milik $key, batal" >&2; return 4; }
      local rc=0; "$L" doc delete "$id" --yes >/dev/null 2>&1 || rc=$?
      # verifikasi nyata: id harus hilang dari listing, bukan sekadar exit code 0
      local gone=0 i j
      for i in 1 2 3; do
        if ! j=$(doc_list_json); then sleep 1; continue; fi
        if printf '%s' "$j" | jq -e --arg id "$id" '[ .[]? | select(.id==$id) ] | length==0' >/dev/null 2>&1; then gone=1; break; fi
        sleep 1
      done
      if [ "$gone" = 1 ]; then
        rm -f "$STATE/ckpt-$key.payload" "$STATE/ckpt-$key.out"
        echo "[usbx] TERHAPUS key=$key id=$id (terverifikasi: tidak ada di listing)"
      else
        echo "[usbx] GAGAL hapus key=$key id=$id (rc=$rc, dokumen masih ada / listing tidak konklusif)" >&2; return 3
      fi ;;
    *) echo "[usbx] ckpt: save|get|list|del" >&2; return 2 ;;
  esac
}

cmd_guard() {
  local key="${1:-}"; shift || true; [ "${1:-}" = "--" ] && shift
  if [ -z "$key" ] || [ $# -eq 0 ]; then echo "[usbx] guard <KEY> -- <cmd...>" >&2; return 2; fi
  require_key "$key" || return 2
  mkdir -p "$STATE/locks"
  local lf="$STATE/locks/$key.lock"
  exec 9>"$lf" || return 3
  if ! flock -n 9; then echo "[usbx] LOCKED: writer lain aktif untuk $key (LOCK LOKAL sandbox ini saja, bukan lintas-sandbox)" >&2; return 5; fi
  "$@"
}

cmd_trim() {
  local f="${1:-.}"; local cap="${2:-20000}"
  local txt; txt=$(jq -c "$f" 2>/dev/null) || { echo "[usbx] jq gagal untuk filter: $f" >&2; return 2; }
  local n=${#txt}
  if [ "$n" -gt "$cap" ]; then
    printf '%s' "$txt" | head -c "$cap"
    echo; echo "[usbx] DIPOTONG: $n -> $cap byte. Perjelas filter (keys/select/map) daripada memotong JSON." >&2
    return 6
  fi
  printf '%s' "$txt"; echo
}

cmd_verify() {
  local f="${1:-}"; local want="${2:-}"
  [ -f "$f" ] || { echo "[usbx] file tidak ada: $f" >&2; return 2; }
  local got; got=$(sha256sum "$f" | cut -d' ' -f1)
  if [ -z "$want" ]; then echo "[usbx] sha256 $f = $got"; return 0; fi
  if [ "$got" = "$want" ]; then echo "[usbx] VERIFY PASS  $f"; else echo "[usbx] VERIFY FAIL  $f (dapat $got, harap $want)" >&2; return 4; fi
}

# Sidik jari isi log = sha256 dari baris berformat log saja.
log_sig() { grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z \| ' "${1:-}" 2>/dev/null | sha256sum | cut -d' ' -f1; }

cmd_log() {
  local key="${1:-}"; shift || true
  if [ "$key" = "flush" ]; then
    local L; L=$(need_lh) || {
      echo "[usbx] PENDING-LH: log tetap lokal ($LOGF). Fallback resmi: simpan isi berkas ini sebagai dokumen 'USBX-LOG — ringkasan biaya & error' di KB $KB lewat tool Documents/Knowledge Base." >&2
      return 3; }
    [ -s "$LOGF" ] || { echo "[usbx] log kosong"; return 0; }
    local sig; sig=$(log_sig "$LOGF")
    local title="USBX-LOG — ringkasan biaya & error"
    local id; id=$(doc_find "USBX-LOG —")
    if [ -n "$id" ]; then
      "$L" doc edit "$id" -F "$LOGF" >/dev/null 2>&1
    else
      local out; out=$("$L" doc create -t "$title" -F "$LOGF" --kb "$KB" --parent "$PROJ" 2>&1)
      id=$(printf '%s' "$out" | grep -o 'docs_[A-Za-z0-9]*' | head -1)
      [ -n "$id" ] || id=$(doc_find "USBX-LOG —")
    fi
    [ -n "$id" ] || { echo "[usbx] LOG GAGAL: dokumen log tidak ditemukan setelah tulis" >&2; return 3; }
    # read-back verification: isi di KB harus sama dengan berkas lokal
    local back="" got="" i
    for i in 1 2 3; do
      back=$("$L" doc view "$id" 2>/dev/null)
      printf '%s\n' "$back" >"$STATE/.logback"
      got=$(log_sig "$STATE/.logback")
      [ "$got" = "$sig" ] && break
      sleep 1
    done
    if [ "$got" = "$sig" ]; then
      echo "[usbx] LOG PASS id=$id entri=$(grep -c . "$LOGF") sha=$sig"
    else
      echo "[usbx] LOG FAIL id=$id (read-back beda: ${got:-kosong} != $sig)" >&2; return 4
    fi
    return 0
  fi
  [ -z "$key" ] && { echo "[usbx] log <KEY> <pesan>" >&2; return 2; }
  require_key "$key" || return 2
  printf '%s | %s | %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$key" "$*" >>"$LOGF"
  echo "[usbx] log: $LOGF"
}

case "${1:-help}" in
  ready) shift; cmd_ready "$@" ;;
  boot) shift; cmd_boot "$@" ;;
  ckpt) shift; cmd_ckpt "$@" ;;
  guard) shift; cmd_guard "$@" ;;
  trim) shift; cmd_trim "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  log) shift; cmd_log "$@" ;;
  version|-V|--version) echo "usbx $USBX_VER" ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
