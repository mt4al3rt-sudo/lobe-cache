# atest — Universal Auto-Test (LobeHub Sandbox)

Satu perintah, laporan PASS/FAIL dengan bukti. Tanpa instalasi berat, tanpa eksekusi otomatis kode asing.

## Pakai

```sh
sh atest.sh fixtures/calc.py        # Python: py_compile (statis) — pytest hanya dengan --trusted
sh atest.sh fixtures/page.html      # HTML: struktur, elemen, sintaks inline JS, host luar, secret scan, browser (bila ada)
sh atest.sh fixtures/app.js         # JS: node --check (statis) — load di vm hanya dengan --trusted
sh atest.sh <dir>                   # direktori: cari test_*.py / *.js / *.html
sh atest.sh <target> --trusted      # HANYA untuk kode tepercaya: pytest/unittest + load JS di vm
sh atest.sh <target> --json         # ringkasan JSON ke stdout
```

Exit code: `0` = tidak ada FAIL, `1` = ada FAIL, `2` = target tidak ada.

## Mode eksekusi (v1.1)

- **statis (default)** — hanya membaca dan memeriksa: `py_compile`, `node --check`, regex struktur/secret. Kode target **tidak dijalankan**.
- **`--trusted`** — menjalankan `pytest`/`unittest` dan memuat JS di `vm` (stub DOM). Pakai hanya untuk sumber yang Anda tulis/audit sendiri.

Semua perintah dijalankan lewat `subprocess` dengan daftar argumen (tanpa `shell=True`), sehingga nama file tidak bisa disisipi perintah shell.

## Tingkatan

| Tier | Butuh | Status bila tidak tersedia |
|---|---|---|
| 1 statis + unit | python3, node, pytest | selalu jalan |
| 2 browser smoke | Playwright + binary browser | `SKIP` — tidak pernah diklaim PASS |

## Verdict

| Kondisi | Verdict |
|---|---|
| ada FAIL | `FAIL` (exit 1) |
| tanpa FAIL, ada SKIP (mis. browser tidak ada, mode statis) | `PASS TERBATAS` (exit 0) |
| tanpa FAIL dan tanpa SKIP | `PASS` (exit 0) |

## Bukti

Setiap run menulis `reports/<stamp>/report.json` + `report.md` (mode, nama tes, status, durasi, potongan output).

## Verifikasi paket

```sh
python3 -m pytest -q selfcheck.py    # 5 tes meta: PASS pada fixture baik, FAIL pada fixture rusak
```

## Batasan

- Tier 2 tidak tersedia di sandbox LobeHub standar (tidak ada binary browser) → verdict maksimal `PASS TERBATAS`.
- Stub DOM hanya menangkap error load/inisialisasi (dan hanya di `--trusted`), bukan interaksi/event nyata.
- `html:external_hosts` hanya memberi `WARN`, tidak memblokir.
- Tidak ada screenshot/visual diff (butuh browser).
