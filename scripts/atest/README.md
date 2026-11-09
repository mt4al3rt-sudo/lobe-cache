# atest — Universal Auto-Test (LobeHub Sandbox)

Satu perintah, laporan PASS/FAIL dengan bukti. Tanpa instalasi berat.

## Pakai

```sh
sh atest.sh fixtures/calc.py        # Python: compile + pytest (atau unittest)
sh atest.sh fixtures/page.html      # HTML: struktur, elemen, inline JS, host luar, secret scan, browser (bila ada)
sh atest.sh fixtures/app.js         # JS: node --check + load di vm (stub DOM)
sh atest.sh <dir>                   # direktori: cari test_*.py / *.js / *.html
sh atest.sh <target> --json         # ringkasan JSON ke stdout
```

Exit code: `0` = tidak ada FAIL, `1` = ada FAIL.

## Tingkatan

| Tier | Butuh | Status bila tidak tersedia |
|---|---|---|
| 1 statis + unit | python3, node, pytest | selalu jalan |
| 2 browser smoke | Playwright + binary browser | `SKIP` — tidak pernah diklaim PASS |

## Bukti

Setiap run menulis `reports/<stamp>/report.json` + `report.md` (nama tes, status, durasi, potongan output).

## Verifikasi paket

```sh
python3 -m pytest -q selfcheck.py    # 5 tes meta: PASS pada fixture baik, FAIL pada fixture rusak
```

## Batasan

- Tier 2 tidak tersedia di sandbox LobeHub standar (tidak ada binary browser). Bila nanti ada, `SMOKE_PY` di `atest.py` otomatis dipakai.
- Stub DOM di `js_check` cukup untuk mendeteksi error load/inisialisasi, bukan untuk menguji interaksi/event nyata.
- `html:external_hosts` hanya memberi `WARN`, tidak memblokir.
