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
#
# Exit code: 0 sukses, 3 model Whisper tidak tersedia, 4 paket Python gagal dipasang.
set -euo pipefail

REPO="${LOBE_CACHE_REPO:-mt4al3rt-sudo/lobe-cache}"
TAG="${LOBE_CACHE_TAG:-v1.0-cache}"
W="${LOBE_CACHE_DIR:-/tmp/lobe-cache}"
MD="${LOBE_WHISPER_DIR:-/tmp/whisper-models}"
MODEL="${MD}/small"
BASE="https://github.com/${REPO}/releases/download/${TAG}"
HF_REPO="Systran/faster-whisper-small"
HF_REV="${LOBE_CACHE_HF_REV:-536b0662742c02347bc0e980a01041f333bce120}"

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

# Pasang .deb lokal tanpa opsi pemaksa dependensi: satu dpkg -i untuk seluruh berkas
# (dpkg menyusun urutan dependensi sendiri), lalu apt-get menangani sisa dependensi.
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

# --- checksum manifest ---
if [ -s SHA256SUMS ]; then
  echo "[cache] SHA256SUMS: pakai berkas lokal"
elif curl -fsSL --retry 2 --connect-timeout 20 -o SHA256SUMS "${BASE}/SHA256SUMS"; then
  echo "[cache] SHA256SUMS: ok ($(wc -l < SHA256SUMS) berkas tercatat)"
else
  rm -f SHA256SUMS
  echo "[cache] SHA256SUMS tidak tersedia -> aset cache dilewati, pakai sumber resmi online"
fi
have_sum() { [ -s SHA256SUMS ]; }

# --- 1. tesseract dari .deb lokal ---
if ! ok_ocr && have_sum && fetch_verified debs.tar.gz; then
  rm -rf deb && mkdir -p deb && tar -xzf debs.tar.gz -C deb
  install_debs deb || true
fi

# --- 2. fallback tesseract via apt resmi ---
if ! ok_ocr; then
  echo "[cache] tesseract: pasang via apt resmi"
  apt-get update -qq || true
  apt-get install -y -qq --no-install-recommends \
    tesseract-ocr tesseract-ocr-ind tesseract-ocr-eng tesseract-ocr-osd >/dev/null 2>&1 || true
fi

# --- 3. wheel python offline ---
if ! ok_py && have_sum && fetch_verified wheels.tar.gz; then
  rm -rf whl && mkdir -p whl && tar -xzf wheels.tar.gz -C whl
  pip install -q --no-index --no-deps --find-links=whl $PY_PINS >/dev/null 2>&1 || true
fi

# --- 4. fallback python via PyPI, versi dikunci sama ---
if ! ok_py; then
  echo "[cache] paket python: pasang via PyPI (versi dikunci)"
  # --no-deps wajib: set pin sudah lengkap; tanpa ini resolver menarik opencv-python
  # (varian GUI) yang menautkan libxcb/libGL dan gagal di image minimal.
  pip install -q --no-deps $PY_PINS || true
fi

# --- 5. model Whisper small ---
if ! ok_model && have_sum && fetch_verified models.tar.gz; then
  mkdir -p "$MD"
  if tar -xzf models.tar.gz -C "$MD" 2>/dev/null; then
    if [ ! -f "${MODEL}/model.bin" ] && [ -f "${MD}/model.bin" ]; then
      mkdir -p "$MODEL" && mv "${MD}"/* "$MODEL"/ 2>/dev/null || true
    fi
  fi
fi

# --- 6. fallback model dari HuggingFace, revisi dikunci ---
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

printf 'export WHISPER_MODEL=%s\n' "$MODEL" > "${W}/whisper_env.sh"

# --- ringkasan ---
echo "[cache] tesseract: $(command -v tesseract >/dev/null 2>&1 && tesseract --version 2>/dev/null | head -1 || echo GAGAL)"
echo "[cache] env      : source ${W}/whisper_env.sh"

if ! python3 -c "import rapidocr_onnxruntime, faster_whisper" >/dev/null 2>&1; then
  echo "[cache] python   : GAGAL (rapidocr/faster-whisper tidak bisa diimpor)"
  exit 4
fi
echo "[cache] python   : ok"

if ! ok_model; then
  echo "[cache] model    : GAGAL (${MODEL}/model.bin tidak ada)"
  echo "[cache]             transkripsi tidak bisa dijalankan; OCR tetap bisa dipakai"
  exit 3
fi
echo "[cache] model    : ${MODEL} ($(du -sh "$MODEL" 2>/dev/null | cut -f1))"
echo "[cache] selesai"
