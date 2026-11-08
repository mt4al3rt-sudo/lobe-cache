#!/usr/bin/env bash
# bootstrap.sh — siapkan tesseract + rapidocr + faster-whisper + model Whisper small lokal.
#
# Sumber resmi saja: GitHub Release repo publik ini, apt Debian, PyPI, HuggingFace.
# Tidak menyimpan kredensial, tidak melakukan curl|bash, tidak menjalankan kode dari jaringan.
#
# PAKAI — dua langkah, periksa dulu:
#   curl -fsSL -o /tmp/bootstrap.sh https://raw.githubusercontent.com/mt4al3rt-sudo/lobe-cache/main/scripts/bootstrap.sh
#   sha256sum /tmp/bootstrap.sh && less /tmp/bootstrap.sh
#   bash /tmp/bootstrap.sh
#
# Setiap tarball diverifikasi terhadap SHA256SUMS sebelum diekstrak. Bila checksum
# tidak tersedia atau tidak cocok, aset tersebut DILEWATI (tidak diekstrak) dan
# instalasi jatuh ke apt/PyPI/HuggingFace resmi.
set -euo pipefail

REPO="${LOBE_CACHE_REPO:-mt4al3rt-sudo/lobe-cache}"
TAG="${LOBE_CACHE_TAG:-v1.0-cache}"
W="${LOBE_CACHE_DIR:-/tmp/lobe-cache}"
MD="${LOBE_WHISPER_DIR:-/tmp/whisper-models}"
MODEL="${MD}/small"
BASE="https://github.com/${REPO}/releases/download/${TAG}"

ok_ocr()   { command -v tesseract >/dev/null 2>&1; }
ok_py()    { python3 -c "import rapidocr_onnxruntime, faster_whisper" >/dev/null 2>&1; }
ok_model() { [ -f "${MODEL}/model.bin" ]; }

mkdir -p "$W"
printf 'export WHISPER_MODEL=%s\n' "$MODEL" > "${W}/whisper_env.sh"

if ok_ocr && ok_py && ok_model; then
  echo "[cache] sudah siap (model: ${MODEL})"
  echo "[cache] env: source ${W}/whisper_env.sh"
  exit 0
fi

cd "$W"
echo "[cache] target   : ${REPO}@${TAG}"
echo "[cache] skrip sha: $(sha256sum "$0" 2>/dev/null | cut -d' ' -f1)"

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

# --- checksum manifest ---
if [ -s SHA256SUMS ]; then
  echo "[cache] SHA256SUMS: pakai cache lokal"
elif curl -fsSL --retry 2 --connect-timeout 20 -o SHA256SUMS "${BASE}/SHA256SUMS"; then
  echo "[cache] SHA256SUMS: ok ($(wc -l < SHA256SUMS) berkas tercatat)"
else
  rm -f SHA256SUMS
  echo "[cache] SHA256SUMS tidak tersedia -> aset cache dilewati, pakai sumber resmi online"
fi
have_sum() { [ -s SHA256SUMS ]; }

# --- 1. tesseract dari .deb lokal ---
if ! ok_ocr; then
  if have_sum && fetch_verified debs.tar.gz; then
    rm -rf deb && mkdir -p deb && tar -xzf debs.tar.gz -C deb
    for d in deb/*.deb; do
      [ -f "$d" ] || continue
      p="$(dpkg-deb -f "$d" Package 2>/dev/null || true)"
      v="$(dpkg-deb -f "$d" Version 2>/dev/null || true)"
      [ -n "$p" ] && [ -n "$v" ] || continue
      c="$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || true)"
      if [ -n "$c" ] && dpkg --compare-versions "$c" ge "$v" 2>/dev/null; then continue; fi
      dpkg -i "$d" >/dev/null 2>&1 || dpkg -i --force-depends "$d" >/dev/null 2>&1 || true
    done
  fi
fi

# --- 2. fallback tesseract via apt resmi ---
if ! ok_ocr; then
  echo "[cache] tesseract: pasang via apt"
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    tesseract-ocr tesseract-ocr-ind tesseract-ocr-eng tesseract-ocr-osd >/dev/null 2>&1 || true
fi

# --- 3. wheel python offline ---
if ! ok_py; then
  if have_sum && fetch_verified wheels.tar.gz; then
    rm -rf whl && mkdir -p whl && tar -xzf wheels.tar.gz -C whl
    pip install -q --no-index --find-links=whl rapidocr-onnxruntime faster-whisper >/dev/null 2>&1 || true
  fi
fi

# --- 4. fallback python via PyPI resmi ---
if ! ok_py; then
  echo "[cache] paket python: pasang via PyPI"
  pip install -q rapidocr-onnxruntime faster-whisper
fi

# --- 5. model Whisper small dari aset lokal ---
if ! ok_model && have_sum && fetch_verified models.tar.gz; then
  mkdir -p "$MD"
  tar -xzf models.tar.gz -C "$MD"
  if [ ! -f "${MODEL}/model.bin" ] && [ -f "${MD}/model.bin" ]; then
    mkdir -p "$MODEL" && mv "${MD}"/* "$MODEL"/ 2>/dev/null || true
  fi
fi

printf 'export WHISPER_MODEL=%s\n' "$MODEL" > "${W}/whisper_env.sh"

# --- ringkasan ---
echo "[cache] tesseract: $(command -v tesseract >/dev/null 2>&1 && tesseract --version 2>/dev/null | head -1 || echo GAGAL)"
if python3 -c "import rapidocr_onnxruntime, faster_whisper" >/dev/null 2>&1; then
  echo "[cache] python   : ok"
else
  echo "[cache] python   : GAGAL"
fi
if ok_model; then
  echo "[cache] model    : ${MODEL} ($(du -sh "$MODEL" 2>/dev/null | cut -f1))"
else
  echo "[cache] model    : tidak ada -> faster-whisper akan unduh 'small' dari HuggingFace"
fi
echo "[cache] env      : source ${W}/whisper_env.sh"
