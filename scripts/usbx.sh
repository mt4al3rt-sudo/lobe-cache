#!/usr/bin/env bash
# usbx v0.9 — Universal Sandbox Skill (LobeHub Cloud Sandbox Free)
# Satu pintu masuk: readiness, lazy bootstrap, checkpoint/resume, anti-duplikat,
# token saver, read-back verify, cost/error log. REUSE-FIRST, tidak menambah infra.
#
#   usbx ready                 cek kesiapan sandbox + lh (retry 3x, fallback resmi)
#   usbx boot [--ocr-only|--with-whisper|--models-only|--plan]
#   usbx ckpt save <KEY> [DESC] [FILE|-]   simpan checkpoint ke KB (payload via stdin)
#   usbx ckpt get <KEY>        pulihkan + verifikasi sha256
#   usbx ckpt list [PREFIX]    cari checkpoint berdasarkan task-key
#   usbx ckpt del <KEY>        hapus 1 checkpoint (wajib cocok persis)
#   usbx guard <KEY> -- <cmd...>           single-writer lokal (flock)
#   usbx trim '<jq-filter>' [maxbytes]     saring data besar sebelum ke LLM
#   usbx verify <FILE> [SHA]   baca ulang file, cocokkan sha256
#   usbx log <KEY> <pesan> | usbx log flush
#
# Exit: 0 ok, 2 argumen/data, 3 lingkungan (lh/sandbox), 4 verifikasi gagal.
set -uo pipefail
USBX_VER="0.9"
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

# Pilih biner lh pertama yang benar-benar bisa bicara ke API (versi global lama bisa ada di PATH).
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
  if [ ! -s /tmp/bs.sh ]; then
    echo "[usbx] ambil bootstrap.sh"
    curl -fsSL -o /tmp/bs.sh "$BOOT_URL" || { echo "[usbx] GAGAL unduh bootstrap.sh" >&2; return 3; }
  fi
  local s; s=$(sha256sum /tmp/bs.sh | cut -d' ' -f1)
  echo "[usbx] bootstrap.sh sha256=$s"
  [ "$s" = "$BOOT_SHA" ] || echo "[usbx] PERINGATAN: sha beda dari pin ($BOOT_SHA) — periksa dulu: less /tmp/bs.sh"
  bash /tmp/bs.sh "$mode"; local rc=$?
  [ -f /tmp/lobe-cache/whisper_env.sh ] && echo "[usbx] env: source /tmp/lobe-cache/whisper_env.sh"
  return $rc
}

cmd_ckpt() {
  local sub="${1:-}"; local key="${2:-}"; shift 2 2>/dev/null || shift $#
  case "$sub" in
    save)
      local desc="${1:-Sandbox checkpoint}"; local src="${2:--}"
      [ -z "$key" ] && { echo "[usbx] butuh task-key" >&2; return 2; }
      local payload
      if [ "$src" = "-" ]; then payload=$(cat); else [ -f "$src" ] || { echo "[usbx] file tidak ada: $src" >&2; return 2; }; payload=$(cat "$src"); fi
      [ -n "$payload" ] || { echo "[usbx] payload kosong" >&2; return 2; }
      local sha b64 ts f title
      sha=$(printf '%s' "$payload" | sha256sum | cut -d' ' -f1)
      b64=$(printf '%s' "$payload" | base64 -w0)
      ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      title="CHECKPOINT $key — $desc"
      f="$STATE/ckpt-$key.md"
      { printf 'Checkpoint Universal Sandbox v%s.\n\nTASK-KEY: %s\nCREATED: %s\nARCH: %s\nSANDBOX: %s\n\nPAYLOAD-SHA256: %s\nPAYLOAD-B64: %s\n\nRESUME: ambil PAYLOAD-B64, base64 -d, lalu cocokkan PAYLOAD-SHA256. Jangan hapus tanpa cek task-key.\n' \
        "$USBX_VER" "$key" "$ts" "$(uname -m)" "${HOSTNAME:-sandbox}" "$sha" "$b64"; } >"$f"
      local L
      if ! L=$(need_lh); then
        echo "[usbx] PENDING-LH: checkpoint lokal siap ($f)."
        echo "[usbx] Fallback resmi: simpan isi berkas berikut sebagai dokumen KB $KB (judul di atas), lalu verifikasi read-back."
        echo "-----BEGIN CKPT $key-----"; cat "$f"; echo "-----END CKPT $key-----"
        return 3
      fi
      local out id
      out=$("$L" doc create -t "$title" -F "$f" --kb "$KB" --parent "$PROJ" 2>&1) || { echo "[usbx] GAGAL create: $out" >&2; return 3; }
      id=$(printf '%s' "$out" | grep -o 'docs_[A-Za-z0-9]*' | head -1)
      [ -n "$id" ] || id=$(doc_find "CHECKPOINT $key ")
      [ -n "$id" ] || { echo "[usbx] GAGAL: dokumen tidak ditemukan setelah create" >&2; return 3; }
      # read-back verification
      local back hit
      back=$("$L" doc view "$id" 2>/dev/null)
      hit=$(printf '%s' "$back" | grep -o 'PAYLOAD-B64: [A-Za-z0-9+/=]*' | head -1 | cut -d' ' -f2)
      if [ -n "$hit" ] && [ "$(printf '%s' "$hit" | base64 -d 2>/dev/null | sha256sum | cut -d' ' -f1)" = "$sha" ]; then
        echo "[usbx] CKPT PASS  key=$key id=$id sha=$sha"
      else
        echo "[usbx] CKPT FAIL  key=$key id=$id (read-back tidak cocok)" >&2; return 4
      fi ;;
    get)
      local L; L=$(need_lh) || return 3
      local id; id=$(doc_find "CHECKPOINT $key ")
      [ -n "$id" ] || { echo "[usbx] TIDAK ADA checkpoint untuk key=$key" >&2; return 2; }
      local back b64 sha2
      back=$("$L" doc view "$id" 2>/dev/null)
      b64=$(printf '%s' "$back" | grep -o 'PAYLOAD-B64: [A-Za-z0-9+/=]*' | head -1 | cut -d' ' -f2)
      sha2=$(printf '%s' "$back" | grep -o 'PAYLOAD-SHA256: [a-f0-9]*' | head -1 | cut -d' ' -f2)
      [ -n "$b64" ] || { echo "[usbx] GAGAL decode: payload tidak ada di $id" >&2; return 4; }
      if [ "$(printf '%s' "$b64" | base64 -d | sha256sum | cut -d' ' -f1)" = "$sha2" ]; then
        echo "[usbx] CKPT PASS  key=$key id=$id sha=$sha2"
        printf '%s' "$b64" | base64 -d; echo
      else echo "[usbx] CKPT FAIL  sha tidak cocok di $id" >&2; return 4; fi ;;
    list)
      local L; L=$(need_lh) || return 3
      local r="CHECKPOINT ${key:-}"
      "$L" doc list --json id,title -L 100 --all 2>/dev/null | jq -r --arg r "$r" '.[]? | select(.title|startswith($r)) | "\(.id)\t\(.title)"' ;;
    del)
      local L; L=$(need_lh) || return 3
      [ -z "$key" ] && { echo "[usbx] butuh task-key persis" >&2; return 2; }
      local id; id=$(doc_find "CHECKPOINT $key —")
      [ -n "$id" ] || { echo "[usbx] tidak ada checkpoint berjudul tepat 'CHECKPOINT $key —'" >&2; return 2; }
      local title; title=$("$L" doc view "$id" 2>/dev/null | head -1)
      printf '%s' "$title" | grep -q "CHECKPOINT $key " || { echo "[usbx] identitas tidak cocok, batal: $title" >&2; return 4; }
      "$L" doc delete "$id" --yes >/dev/null 2>&1
      if [ -z "$(doc_find "CHECKPOINT $key —")" ]; then echo "[usbx] terhapus: $id ($title)"
      else echo "[usbx] GAGAL hapus $id" >&2; return 3; fi ;;
    *) echo "[usbx] ckpt: save|get|list|del" >&2; return 2 ;;
  esac
}

cmd_guard() {
  local key="${1:-}"; shift || true; [ "${1:-}" = "--" ] && shift
  [ -z "$key" ] || [ $# -eq 0 ] && { echo "[usbx] guard <KEY> -- <cmd...>" >&2; return 2; }
  local lf="$STATE/locks/$key.lock"
  exec 9>"$lf" || return 3
  if ! flock -n 9; then echo "[usbx] LOCKED: writer lain aktif untuk $key (lokal, bukan lintas-sandbox)" >&2; return 5; fi
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

cmd_log() {
  local key="${1:-}"; shift || true
  if [ "$key" = "flush" ]; then
    local L; L=$(need_lh) || return 3
    [ -s "$LOGF" ] || { echo "[usbx] log kosong"; return 0; }
    local title="USBX-LOG — ringkasan biaya & error"
    local id; id=$(doc_find "USBX-LOG —")
    if [ -n "$id" ]; then "$L" doc edit "$id" -F "$LOGF" >/dev/null 2>&1; echo "[usbx] log diperbarui: $id"
    else
      local out; out=$("$L" doc create -t "$title" -F "$LOGF" --kb "$KB" --parent "$PROJ" 2>&1)
      echo "[usbx] log dibuat: $(printf '%s' "$out" | grep -o 'docs_[A-Za-z0-9]*' | head -1)"
    fi
    return 0
  fi
  [ -z "$key" ] && { echo "[usbx] log <KEY> <pesan>" >&2; return 2; }
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
