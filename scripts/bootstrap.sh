#!/usr/bin/env bash
# bootstrap.sh — siapkan OCR (dan opsional Whisper) di sandbox LobeHub.
#
# Bertingkat: default hanya OCR (tanpa model). Whisper 426 MB hanya bila diminta.
# Aset prebuilt (wheels/.deb) hanya dipakai pada x86_64; di arm64 dilewati karena
# isinya binary x86_64.
#
# PAKAI — dua langkah, periksa dulu:
#   curl -fsSL -o /tmp/bootstrap.sh https://raw.githubusercontent.com/mt4al3rt-sudo/lobe-cache/main/scripts/bootstrap.sh
#   sha256sum /tmp/bootstrap.sh && less /tmp/bootstrap.sh
#   bash /tmp/bootstrap.sh --ocr-only        # metadata + OCR, 0 MB model
#   bash /tmp/bootstrap.sh --with-whisper    # + model Whisper small (426 MB)
#   bash /tmp/bootstrap.sh --models-only     # hanya model (OCR sudah siap)
#   bash /tmp/bootstrap.sh --plan            # cetak rencana, tanpa mengunduh
#
# Exit code: 0 sukses, 3 model diminta tapi tidak tersedia, 4 paket Python gagal.
set -euo pipefail

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

REPO="${LOBE_CACHE_REPO:-mt4al3rt-sudo/lobe-cache}"
TAG="${LOBE_CACHE_TAG:-v1.0-cache}"
W="${LOBE_CACHE_DIR:-/tmp/lobe-cache}"
MD="${LOBE_WHISPER_DIR:-/tmp/whisper-models}"
MODEL="${MD}/small"
BASE="https://github.com/${REPO}/releases/download/${TAG}"
HF_REPO="Systran/faster-whisper-small"
HF_REV="${LOBE_CACHE_HF_REV:-536b0662742c02347bc0e980a01041f333bce120}"

MODE="ocr"
PLAN=0
usage() {
  echo "Pemakaian: bootstrap.sh [--ocr-only|--with-whisper|--models-only] [--plan]"
  echo "  --ocr-only     (default) tesseract + rapidocr + faster-whisper, tanpa model"
  echo "  --with-whisper OCR + model Whisper small (426 MB)"
  echo "  --models-only  hanya model Whisper"
  echo "  --plan         cetak rencana unduhan, tidak mengeksekusi"
}
for a in "$@"; do
  case "$a" in
    --ocr-only) MODE="ocr" ;;
    --with-whisper) MODE="whisper" ;;
    --models-only) MODE="models" ;;
    --plan) PLAN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[cache] argumen tidak dikenal: $a"; usage; exit 2 ;;
  esac
done

ARCH="$(uname -m 2>/dev/null || echo unknown)"
case "$ARCH" in
  x86_64|amd64) PREBUILT=1 ;;
  *) PREBUILT=0 ;;
esac

# Versi dikunci — identik dengan PINS di .github/workflows/build-cache.yml (29 paket).
PY_PINS="rapidocr-onnxruntime==1.4.4 opencv-python-headless==4.12.0.88 numpy==2.2.6 onnxruntime==1.31.1
pyclipper==1.4.0 pillow==13.0.0 pyyaml==6.0.3 shapely==2.2.0 six==1.17.0 tqdm==4.70.1
faster-whisper==1.2.1 ctranslate2==4.8.5 av==18.1.0 tokenizers==0.23.3 huggingface_hub==2.4.0
hf-xet==1.8.0 filelock==4.2.9 fsspec==2026.9.0 packaging==26.3 typing_extensions==4.16.0
flatbuffers==25.12.19 protobuf==7.36.2 httpx2==2.16.0 httpcore2==2.16.0 anyio==4.16.0
h11==0.16.0 idna==3.20 truststore==0.10.5 click==8.5.1"
PY_PINS="$(printf '%s' "$PY_PINS" | tr '\n' ' ' | tr -s ' ')"

ok_ocr()   { command -v tesseract >/dev/null 2>&1; }
ok_py()    { python3 -c "import rapidocr_onnxruntime, faster_whisper" >/dev/null 2>&1; }
ok_model() { [ -f "${MODEL}/model.bin" ]; }

want_model=0
case "$MODE" in whisper|models) want_model=1 ;; esac

# Mode "models" hanya menyentuh model: OCR & paket python tidak dipasang.
need_ocr=1
[ "$MODE" = "models" ] && need_ocr=0

plan_status() { # $1 = ocr|py
  if [ "$need_ocr" = 0 ]; then echo "tidak (mode ${MODE})"; return; fi
  if [ "$1" = "ocr" ]; then
    if ok_ocr; then echo "sudah ada"; else echo "pasang/unduh"; fi
  else
    if ok_py; then echo "sudah ada"; else echo "pasang/unduh"; fi
  fi
}

# --- rencana ---
if [ "$PLAN" = 1 ]; then
  echo "[cache] arch    : ${ARCH} (prebuilt: $([ "$PREBUILT" = 1 ] && echo ya || echo tidak))"
  echo "[cache] mode    : ${MODE}"
  echo "[cache] tesseract: $(plan_status ocr)"
  echo "[cache] python   : $(plan_status py)"
  echo "[cache] wheels  : $([ "$PREBUILT" = 1 ] && [ "$need_ocr" = 1 ] && ! ok_py && echo "unduh wheels.tar.gz" || echo "tidak (tidak perlu / arch lain)")"
  echo "[cache] debs    : $([ "$PREBUILT" = 1 ] && [ "$need_ocr" = 1 ] && ! ok_ocr && echo "unduh debs.tar.gz" || echo "tidak (tidak perlu / arch lain)")"
  echo "[cache] model   : $([ "$want_model" = 1 ] && ! ok_model && echo "unduh models.tar.gz (426 MB)" || ([ "$want_model" = 1 ] && echo "sudah ada" || echo "tidak diminta (mode ${MODE})"))"
  exit 0
fi

mkdir -p "$W"
printf 'export WHISPER_MODEL=%s\n' "$MODEL" > "${W}/whisper_env.sh"

ready=1
if [ "$need_ocr" = 1 ]; then
  ok_ocr || ready=0
  ok_py || ready=0
fi
[ "$want_model" = 1 ] && { ok_model || ready=0; }
if [ "$ready" = 1 ]; then
  echo "[cache] sudah siap (mode: ${MODE}, model: $(ok_model && echo ada || echo tidak diminta))"
  echo "[cache] env: source ${W}/whisper_env.sh"
  exit 0
fi

echo "[cache] target   : ${REPO}@${TAG}"
echo "[cache] arch     : ${ARCH} | mode: ${MODE}"
echo "[cache] skrip    : ${SCRIPT_PATH} | sha: $(sha256sum "$SCRIPT_PATH" 2>/dev/null | cut -d' ' -f1 || echo n/a)"

cd "$W"

sum_for() { awk -v f="$1" '$2 == f { print $1; exit }' SHA256SUMS 2>/dev/null; }

verify() {
  local f="$1" want got
  [ -s "$f" ] || { echo "[cache] tidak ada berkas: $f"; return 1; }
  want="$(sum_for "$f")"
  [ -n "$want" ] || { echo "[cache] checksum tidak tercatat untuk $f"; return 1; }
  got="$(sha256sum "$f" | cut -d' ' -f1)"
  if [ "$want" != "$got" ]; then
    echo "[cache] CHECKSUM BEDA: $f (harap $want, dapat $got)"
    return 1
  fi
  echo "[cache] checksum ok: $f"
}

fetch_verified() {
  local n="$1"
  if [ -s "$n" ] && verify "$n"; then return 0; fi
  rm -f "$n" "${n}.part"
  if ! curl -fsSL --retry 2 --connect-timeout 20 -o "${n}.part" "${BASE}/${n}"; then
    rm -f "${n}.part"
    echo "[cache] unduh gagal: $n"
    return 1
  fi
  mv "${n}.part" "$n"
  verify "$n" || { rm -f "$n"; return 1; }
}

# Pasang .deb lokal tanpa opsi pemaksa dependensi.
install_debs() {
  local dir="$1" list=() d pkg ver cur
  for d in "$dir"/*.deb; do
    [ -f "$d" ] || continue
    pkg="$(dpkg-deb -f "$d" Package 2>/dev/null || true)"
    ver="$(dpkg-deb -f "$d" Version 2>/dev/null || true)"
    [ -n "$pkg" ] && [ -n "$ver" ] || continue
    cur="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
    if [ -n "$cur" ] && dpkg --compare-versions "$cur" ge "$ver" 2>/dev/null; then
      continue
    fi
    list+=("$d")
  done
  if [ "${#list[@]}" -eq 0 ]; then
    echo "[cache] deb: semua paket sudah terpasang versi lebih baru/sama"
    return 0
  fi
  if dpkg -i "${list[@]}" >/dev/null 2>&1; then
    echo "[cache] deb: terpasang via dpkg (${#list[@]} paket)"
    return 0
  fi
  echo "[cache] deb: dpkg belum bersih, apt-get menyusun ulang dependensi"
  if apt-get install -y --no-install-recommends "${list[@]}" >/dev/null 2>&1; then
    echo "[cache] deb: terpasang via apt-get lokal (${#list[@]} paket)"
    return 0
  fi
  echo "[cache] deb: apt-get lokal gagal, lanjut ke arsip resmi"
  return 1
}

need_debs=0; need_wheels=0; need_model_tar=0
[ "$PREBUILT" = 1 ] && ! ok_ocr && need_debs=1
[ "$PREBUILT" = 1 ] && ! ok_py && need_wheels=1
[ "$want_model" = 1 ] && ! ok_model && need_model_tar=1

if [ "$PREBUILT" = 0 ] && { [ "$need_debs" = 1 ] || [ "$need_wheels" = 1 ]; }; then
  echo "[cache] aset prebuilt dilewati: arsitektur ${ARCH} != x86_64 (hemat ~232 MB)"
fi

if [ "$need_debs" = 1 ] || [ "$need_wheels" = 1 ] || [ "$need_model_tar" = 1 ]; then
  if [ -s SHA256SUMS ]; then
    echo "[cache] SHA256SUMS: pakai berkas lokal"
  elif curl -fsSL --retry 2 --connect-timeout 20 -o SHA256SUMS "${BASE}/SHA256SUMS"; then
    echo "[cache] SHA256SUMS: ok ($(wc -l < SHA256SUMS) berkas tercatat)"
  else
    rm -f SHA256SUMS
    echo "[cache] SHA256SUMS tidak tersedia -> jalur online"
  fi
fi
have_sum() { [ -s SHA256SUMS ]; }

# --- 1. tesseract ---
if [ "$need_ocr" = 1 ] && ! ok_ocr; then
  if [ "$need_debs" = 1 ] && have_sum && fetch_verified debs.tar.gz; then
    rm -rf deb && mkdir -p deb && tar -xzf debs.tar.gz -C deb
    install_debs deb || true
  fi
fi
if [ "$need_ocr" = 1 ] && ! ok_ocr; then
  echo "[cache] tesseract: pasang via apt resmi"
  apt-get update -qq || true
  apt-get install -y -qq --no-install-recommends \
    tesseract-ocr tesseract-ocr-ind tesseract-ocr-eng tesseract-ocr-osd >/dev/null 2>&1 || true
fi

# --- 2. paket python ---
if [ "$need_ocr" = 1 ] && ! ok_py; then
  if [ "$need_wheels" = 1 ] && have_sum && fetch_verified wheels.tar.gz; then
    rm -rf whl && mkdir -p whl && tar -xzf wheels.tar.gz -C whl
    pip install -q --no-index --no-deps --find-links=whl $PY_PINS >/dev/null 2>&1 || true
  fi
fi
if [ "$need_ocr" = 1 ] && ! ok_py; then
  echo "[cache] paket python: pasang via PyPI (versi dikunci)"
  # --no-deps wajib: set pin sudah lengkap; tanpa ini resolver menarik opencv-python
  # (varian GUI) yang menautkan libxcb/libGL dan gagal di image minimal.
  pip install -q --no-deps $PY_PINS || true
fi

# --- 3. model Whisper (hanya bila diminta) ---
if [ "$want_model" = 1 ] && ! ok_model; then
  if [ "$need_model_tar" = 1 ] && have_sum && fetch_verified models.tar.gz; then
    mkdir -p "$MD"
    if tar -xzf models.tar.gz -C "$MD" 2>/dev/null; then
      if [ ! -f "${MODEL}/model.bin" ] && [ -f "${MD}/model.bin" ]; then
        mkdir -p "$MODEL" && mv "${MD}"/* "$MODEL"/ 2>/dev/null || true
      fi
    fi
  fi
  if ! ok_model; then
    echo "[cache] model: aset tidak tersedia/ekstrak gagal, unduh dari HuggingFace (revisi ${HF_REV})"
    mkdir -p "$MODEL"
    if python3 -c "import huggingface_hub" >/dev/null 2>&1; then
      python3 - "$MODEL" "$HF_REPO" "$HF_REV" <<'PY' || true
import sys
from huggingface_hub import snapshot_download

target, repo_id, rev = sys.argv[1], sys.argv[2], sys.argv[3]
snapshot_download(repo_id, revision=rev, local_dir=target)
print("[cache] model: unduhan selesai")
PY
    else
      echo "[cache] model: huggingface_hub tidak tersedia, unduhan langsung dilewati"
    fi
  fi
fi

printf 'export WHISPER_MODEL=%s\n' "$MODEL" > "${W}/whisper_env.sh"

# --- ringkasan ---
if [ "$need_ocr" = 1 ]; then
  echo "[cache] tesseract: $(command -v tesseract >/dev/null 2>&1 && tesseract --version 2>/dev/null | head -1 || echo GAGAL)"
else
  echo "[cache] tesseract: dilewati (mode ${MODE})"
fi
echo "[cache] env      : source ${W}/whisper_env.sh"

if [ "$need_ocr" = 1 ]; then
  if ! python3 -c "import rapidocr_onnxruntime, faster_whisper" >/dev/null 2>&1; then
    echo "[cache] python   : GAGAL (rapidocr/faster-whisper tidak bisa diimpor)"
    exit 4
  fi
  echo "[cache] python   : ok"
else
  echo "[cache] python   : dilewati (mode ${MODE})"
fi

if [ "$want_model" = 1 ]; then
  if ! ok_model; then
    echo "[cache] model    : GAGAL (${MODEL}/model.bin tidak ada)"
    echo "[cache]             transkripsi tidak bisa dijalankan; OCR tetap bisa dipakai"
    exit 3
  fi
  echo "[cache] model    : ${MODEL} ($(du -sh "$MODEL" 2>/dev/null | cut -f1))"
else
  echo "[cache] model    : tidak diminta (mode ${MODE}) -> 0 MB"
fi
echo "[cache] selesai"
