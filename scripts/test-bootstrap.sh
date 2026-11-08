#!/usr/bin/env bash
# test-bootstrap.sh — tes mode bootstrap tanpa mengunduh apa pun (semua lewat --plan).
# Pakai: bash scripts/test-bootstrap.sh [path/bootstrap.sh]
set -uo pipefail

B="${1:-scripts/bootstrap.sh}"
fails=0

chk() { # $1 deskripsi, $2 pola regex, sisanya perintah
  local desc="$1" pat="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if printf '%s\n' "$out" | grep -qE "$pat"; then
    echo "PASS: ${desc}"
  else
    echo "FAIL: ${desc} (exit ${rc})"
    printf '%s\n' "$out" | head -6
    fails=$((fails + 1))
  fi
}

chk_exit() { # $1 deskripsi, $2 exit yang diharapkan, sisanya perintah
  local desc="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" = "$want" ]; then echo "PASS: ${desc}"; else echo "FAIL: ${desc} (exit ${rc}, harap ${want})"; fails=$((fails + 1)); fi
}

echo "== bash -n =="
if bash -n "$B"; then echo "PASS: syntax"; else echo "FAIL: syntax"; exit 1; fi
chmod +x "$B" 2>/dev/null || true

echo "== --help & argumen =="
chk "help menampilkan pemakaian" "Pemakaian" bash "$B" --help
chk_exit "argumen tak dikenal -> exit 2" 2 bash "$B" --ngawur

echo "== --plan: --ocr-only tidak menyentuh model =="
chk "ocr-only: mode ocr" "mode +: ocr" bash "$B" --plan --ocr-only
chk "ocr-only: model tidak diminta" "model +: tidak diminta" bash "$B" --plan --ocr-only
chk "ocr-only: tidak mengunduh models.tar.gz" "^\[cache\] model .*tidak diminta" bash "$B" --plan --ocr-only

echo "== --plan: --models-only tidak memasang OCR =="
chk "models-only: tesseract dilewati" "tesseract: tidak \(mode models\)" bash "$B" --plan --models-only
chk "models-only: python dilewati" "python +: tidak \(mode models\)" bash "$B" --plan --models-only
chk "models-only: tanpa wheels" "wheels +: tidak" bash "$B" --plan --models-only
chk "models-only: tanpa debs" "debs +: tidak" bash "$B" --plan --models-only
chk "models-only: model dipertimbangkan" "model +: (unduh models\.tar\.gz|sudah ada)" bash "$B" --plan --models-only

echo "== --plan: --with-whisper =="
chk "with-whisper: mode whisper" "mode +: whisper" bash "$B" --plan --with-whisper
chk "with-whisper: model dipertimbangkan" "model +: (unduh models\.tar\.gz|sudah ada)" bash "$B" --plan --with-whisper
chk "with-whisper: OCR tetap disiapkan" "tesseract: (pasang/unduh|sudah ada)" bash "$B" --plan --with-whisper

echo "== --plan: informasi arch =="
chk "plan mencetak arsitektur" "arch +: " bash "$B" --plan

echo "== sandbox kosong (mock): --models-only tidak memanggil apt-get/pip =="
BASH_BIN="$(command -v bash)"
MOCK="$(mktemp -d)"; TMPD="$(mktemp -d)"
for spec in "apt-get:APT" "pip:PIP"; do
  cmd="${spec%%:*}"; tag="${spec##*:}"
  printf '#!/bin/sh\necho "%s $*" >> %s/calls.log\nexit 0\n' "$tag" "$TMPD" > "$MOCK/$cmd"
done
printf '#!/bin/sh\nexit 22\n' > "$MOCK/curl"
printf '#!/bin/sh\nexit 1\n' > "$MOCK/python3"
chmod +x "$MOCK"/* 2>/dev/null
for t in uname sha256sum cut mkdir tar du head awk grep readlink tr sed cat wc rm mv ls sort env dirname basename; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$MOCK/$t"
done

# kontrol: mock memang menangkap panggilan (mode ocr wajib memanggil apt-get/pip)
PATH="$MOCK" LOBE_CACHE_DIR="$TMPD/w0" LOBE_WHISPER_DIR="$TMPD/m0" "$BASH_BIN" "$B" --ocr-only >/dev/null 2>&1
if grep -q "APT" "$TMPD/calls.log" 2>/dev/null && grep -q "PIP" "$TMPD/calls.log" 2>/dev/null; then
  echo "PASS: kontrol mock (ocr-only memanggil apt-get dan pip)"
else
  echo "FAIL: kontrol mock tidak menangkap panggilan"; fails=$((fails + 1))
fi
rm -f "$TMPD/calls.log"

PATH="$MOCK" LOBE_CACHE_DIR="$TMPD/w1" LOBE_WHISPER_DIR="$TMPD/m1" "$BASH_BIN" "$B" --models-only > "$TMPD/out.txt" 2>&1
rc=$?
if [ -s "$TMPD/calls.log" ]; then
  echo "FAIL: models-only memanggil apt-get/pip:"; cat "$TMPD/calls.log"; fails=$((fails + 1))
else
  echo "PASS: models-only tidak memanggil apt-get maupun pip"
fi
if [ "$rc" = 3 ] && grep -q "model    : GAGAL" "$TMPD/out.txt"; then
  echo "PASS: models-only berhenti dengan exit 3 + pesan model GAGAL"
else
  echo "FAIL: models-only exit ${rc}"; head -6 "$TMPD/out.txt"; fails=$((fails + 1))
fi
rm -rf "$MOCK" "$TMPD"

echo "== ringkasan =="
if [ "$fails" -eq 0 ]; then echo "SEMUA TES PASS"; exit 0; fi
echo "GAGAL: ${fails} tes"; exit 1
