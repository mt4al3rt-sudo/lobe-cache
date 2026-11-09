#!/bin/sh
# atest — pembungkus tunggal. Pemakaian: sh atest.sh <target> [--json]
DIR=$(dirname "$0")
exec python3 "$DIR/atest.py" "$@"
