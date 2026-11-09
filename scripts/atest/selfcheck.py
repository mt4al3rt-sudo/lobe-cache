"""Self-check paket atest: membuktikan runner memberi PASS/FAIL yang benar.
Jalankan: cd /tmp/atest && python3 -m pytest -q selfcheck.py
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def run(target, *flags):
    p = subprocess.run([sys.executable, "atest.py", target, *flags], cwd=ROOT,
                       capture_output=True, text=True, timeout=300)
    return p.returncode, p.stdout


def test_python_target_pass():
    rc, out = run("fixtures/calc.py", "--trusted")
    assert rc == 0, out
    assert "py:pytest=PASS" in out, out
    assert "VERDICT: PASS" in out


def test_html_good_pass():
    rc, out = run("fixtures/page.html")
    assert rc == 0, out
    assert "browser:smoke=SKIP" in out, "browser tidak boleh diklaim PASS"
    assert "html:inline_js=PASS" in out
    assert "VERDICT: PASS TERBATAS" in out, "SKIP browser harus jadi PASS TERBATAS"


def test_html_bad_fail():
    rc, out = run("fixtures/bad.html")
    assert rc == 1, out
    for k in ("html:structure=FAIL", "html:inline_js=FAIL", "html:secret_scan=FAIL"):
        assert k in out, out


def test_js_pass():
    rc, out = run("fixtures/app.js")
    assert rc == 0 and "js:check=PASS" in out, out


def test_report_written():
    run("fixtures/calc.py")
    reports = sorted((ROOT / "reports").glob("*/report.json"))
    assert reports, "report.json tidak terbentuk"
    assert "verdict" in reports[-1].read_text()
