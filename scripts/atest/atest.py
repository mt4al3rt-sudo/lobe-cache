#!/usr/bin/env python3
"""atest.py — Universal Auto-Test LobeHub Sandbox (REUSE-FIRST).
Mode statis (default, aman): sintaks + struktur + scan, TANPA mengeksekusi kode target.
Mode --trusted: menjalankan pytest/unittest dan load JS di vm (hanya untuk kode tepercaya).
Tier 2 browser smoke hanya bila Playwright + binary browser ada; kalau tidak -> SKIP (verdict PASS TERBATAS).
Pemakaian:
  python3 atest.py <target>                    # file .py/.html/.js, atau direktori
  python3 atest.py <target> --trusted          # eksekusi kode (hanya sumber tepercaya)
  python3 atest.py <target> --json             # ringkas JSON ke stdout
Exit: 0 = tidak ada FAIL, 1 = ada FAIL.
"""
import json, os, re, shutil, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "reports"
MODE = "static"
SECRET_PATTERNS = [
    (r"sk-[A-Za-z0-9_\-]{16,}", "openai-like key"),
    (r"AKIA[0-9A-Z]{16}", "aws access key"),
    (r"-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----", "private key"),
    (r"ghp_[A-Za-z0-9]{20,}", "github token"),
    (r"(?i)(api[_-]?key|secret|passwd|password)\s*[:=]\s*['\"][^'\"]{12,}['\"]", "hardcoded credential"),
]
RESULT = {"tool": "atest", "version": "1.1", "mode": MODE, "target": None, "env": {},
          "tests": [], "started": None}

def run(cmd, timeout=180, cwd=None):
    """Eksekusi TANPA shell. cmd wajib list/tuple -> tidak ada interpolasi string perintah."""
    if not isinstance(cmd, (list, tuple)):
        raise TypeError("run() butuh list argumen, bukan string shell")
    t0 = time.time()
    try:
        p = subprocess.run([str(c) for c in cmd], capture_output=True, text=True,
                           timeout=timeout, cwd=cwd)
        return p.returncode, (p.stdout or "") + (p.stderr or ""), round(time.time() - t0, 2)
    except subprocess.TimeoutExpired:
        return 124, f"TIMEOUT after {timeout}s", round(time.time() - t0, 2)
    except FileNotFoundError as e:
        return 127, str(e), round(time.time() - t0, 2)

def add(name, status, detail, dur=0.0, evidence=""):
    RESULT["tests"].append({"name": name, "status": status, "detail": detail,
                            "seconds": dur, "evidence": evidence})
    print(f"[{status:4}] {name} — {detail}" + (f" ({dur}s)" if dur else ""))

def probe_env():
    env = {}
    env["python"] = run(["python3", "-V"])[1].strip()
    rc, o, _ = run(["python3", "-c", "import pytest;print(pytest.__version__)"])
    env["pytest"] = o.strip() if rc == 0 else None
    rc, o, _ = run(["node", "-v"])
    env["node"] = o.strip() if rc == 0 else None
    rc1, _, _ = run(["python3", "-c", "import playwright"])
    rc2, o2, _ = run(["npx", "--no-install", "playwright", "--version"])
    env["playwright_python"] = rc1 == 0
    env["playwright_node"] = rc2 == 0 and "Version" in o2
    browsers = []
    for pat in [os.path.expanduser("~/.cache/ms-playwright"), "/ms-playwright"]:
        if os.path.isdir(pat):
            browsers += [d for d in os.listdir(pat)]
    env["browsers"] = browsers
    env["browser_tier"] = bool((env["playwright_python"] or env["playwright_node"]) and browsers)
    env["mode"] = MODE
    RESULT["env"] = env
    return env

# ---------- Tier 1: Python ----------
def test_python(target: Path):
    if target.is_file():
        rc, o, d = run(["python3", "-m", "py_compile", str(target)])
        add("py:compile", "PASS" if rc == 0 else "FAIL",
            target.name if rc == 0 else o.strip()[:300], d)
        tests = [target] if re.search(r"test_.*\.py$|.*_test\.py$", target.name) else []
        if not tests:
            cand = sorted(target.parent.glob("test_*.py")) + sorted(target.parent.glob("*_test.py"))
            tests = [p for p in cand if target.stem in p.stem or p.parent == target.parent]
    else:
        tests = sorted(target.glob("test_*.py")) + sorted(target.glob("*_test.py"))
    if MODE != "trusted":
        add("py:pytest", "SKIP",
            "mode statis: kode target tidak dieksekusi (pakai --trusted untuk sumber tepercaya)")
        return
    if not tests:
        add("py:pytest", "SKIP", "tidak ada file test_*.py")
        return
    cwd = str(target.parent if target.is_file() else target)
    if RESULT["env"].get("pytest"):
        cmd = ["python3", "-m", "pytest", "-q", "--no-header", "-p", "no:cacheprovider"] + [str(p) for p in tests]
        rc, o, d = run(cmd, timeout=300, cwd=cwd)
        tail = " ".join([l for l in o.strip().splitlines() if l.strip()][-3:])
        add("py:pytest", "PASS" if rc == 0 else "FAIL", tail[:400], d, o[-4000:])
    else:
        cmd = ["python3", "-m", "unittest", "-q"] + [str(p) for p in tests]
        rc, o, d = run(cmd, timeout=300, cwd=cwd)
        add("py:unittest", "PASS" if rc == 0 else "FAIL", o.strip()[-300:] or "ok", d, o[-4000:])

# ---------- Tier 1: JS ----------
def js_check(label, code, tmpdir, execute=False):
    f = Path(tmpdir) / (re.sub(r"\W+", "_", label)[:40] + ".js")
    f.write_text(code)
    rc, o, d = run(["node", "--check", str(f)])
    if rc != 0:
        return False, o.strip()[:300], d
    if not execute:
        return True, "syntax ok (statis, tidak dieksekusi)", d
    runner = Path(tmpdir) / "_vm_run.js"
    runner.write_text(
        "const fs=require('fs'),vm=require('vm');const src=fs.readFileSync(process.argv[2],'utf8');"
        "const el=()=>({style:{},dataset:{},classList:{add(){},remove(){},toggle(){}},setAttribute(){},"
        "getAttribute:()=>null,appendChild(){},addEventListener(){},removeEventListener(){},"
        "querySelector:()=>null,querySelectorAll:()=>[],focus(){},click(){}});"
        "const doc={getElementById:()=>el(),querySelector:()=>el(),querySelectorAll:()=>[],"
        "getElementsByTagName:()=>[],getElementsByClassName:()=>[],createElement:()=>el(),"
        "addEventListener(){},body:el(),documentElement:el()};"
        "try{vm.runInNewContext(src,{console,window:{document:doc,location:{href:''},"
        "addEventListener(){},setTimeout,clearTimeout},document:doc,navigator:{userAgent:'node'},"
        "localStorage:{getItem:()=>null,setItem(){},removeItem(){}},fetch:()=>Promise.resolve({ok:true,json:()=>Promise.resolve({}),text:()=>Promise.resolve('')}),"
        "setTimeout,clearTimeout,setInterval:()=>0,clearInterval(){},Math,Date,JSON,Array,Object,String,Number,Promise}, {timeout:5000});console.log('VM_OK')}"
        "catch(e){console.log('VM_ERR: '+e.message);process.exit(3)}")
    rc2, o2, d2 = run(["node", str(runner), str(f)])
    if rc2 != 0:
        return False, o2.strip()[:300], d + d2
    return True, "syntax+load ok (trusted)", d + d2

def test_js(target: Path, tmpdir):
    execute = MODE == "trusted"
    if target.is_file():
        ok, detail, d = js_check(target.name, target.read_text(errors="replace"), tmpdir, execute)
        add("js:check", "PASS" if ok else "FAIL", detail, d)
    else:
        files = sorted(target.glob("*.js"))
        bad = 0
        for f in files:
            ok, detail, _ = js_check(f.name, f.read_text(errors="replace"), tmpdir, execute)
            if not ok:
                bad += 1
                add(f"js:check:{f.name}", "FAIL", detail)
        add("js:check", "PASS" if files and not bad else ("SKIP" if not files else "FAIL"),
            f"{len(files)} file, {bad} gagal")

# ---------- Tier 1: HTML statis ----------
REQUIRED = ["<!doctype", "<html", "<head", "<body", "</html>"]
IMPORTANT_TAGS = ["title", "h1", "main", "button", "form", "canvas", "script"]
EXTERNAL = re.compile(r'(?:src|href)\s*=\s*["\'](https?://[^"\']+)', re.I)

def static_html(p: Path, tmpdir):
    txt = p.read_text(errors="replace")
    low = txt.lower()
    misses = [t for t in REQUIRED if t not in low]
    add("html:structure", "PASS" if not misses else "FAIL",
        "struktur lengkap" if not misses else "hilang: " + ", ".join(misses))
    present = [t for t in IMPORTANT_TAGS if f"<{t}" in low]
    add("html:elements", "PASS" if present else "FAIL",
        "elemen: " + ", ".join(present or ["<tidak ada elemen utama>"]))
    scripts = re.findall(r"<script[^>]*>(.*?)</script>", txt, re.S | re.I)
    inline = [s for s in scripts if s.strip()]
    bad = []
    for i, s in enumerate(inline):
        ok, detail, _ = js_check(f"inline{i}", s, tmpdir, MODE == "trusted")
        if not ok:
            bad.append(detail)
    add("html:inline_js", "PASS" if not bad else "FAIL",
        f"{len(inline)} blok inline" + ("" if not bad else " | error: " + bad[0][:200]))
    ext = EXTERNAL.findall(txt)
    add("html:external_hosts", "WARN" if ext else "PASS",
        ("host luar: " + ", ".join(sorted(set(ext))[:5])) if ext else "tanpa host eksternal")
    leaks = []
    for pat, label in SECRET_PATTERNS:
        if re.search(pat, txt):
            leaks.append(label)
    add("html:secret_scan", "PASS" if not leaks else "FAIL",
        "bersih" if not leaks else "terdeteksi: " + ", ".join(leaks))

# ---------- Tier 2: browser smoke ----------
SMOKE_PY = r'''
import sys, json
from playwright.sync_api import sync_playwright
url = "file://" + sys.argv[1]
errs, failed = [], []
with sync_playwright() as pw:
    b = pw.chromium.launch()
    pg = b.new_page()
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.on("requestfailed", lambda r: failed.append(r.url))
    pg.goto(url, wait_until="load", timeout=15000)
    title = pg.title()
    visible = pg.evaluate("() => { const l=['h1','main','button','canvas','form'];"
                          " return l.filter(s=>{const e=document.querySelector(s);"
                          " return e && (e.offsetWidth>0||e.offsetHeight>0);}); }")
    txt = pg.evaluate("() => document.body.innerText.trim().length")
    b.close()
print(json.dumps({"title": title, "visible": visible, "text_len": txt,
                  "page_errors": errs, "request_failed": failed}))
'''

def browser_smoke(p: Path):
    env = RESULT["env"]
    if not env.get("browser_tier"):
        add("browser:smoke", "SKIP",
            "Playwright/browser tidak tersedia (aturan: tanpa instalasi besar, tanpa klaim PASS)")
        return
    sp = Path(ROOT) / "_smoke.py"
    sp.write_text(SMOKE_PY)
    rc, o, d = run(["python3", str(sp), str(p)], timeout=120)
    if rc != 0:
        add("browser:smoke", "SKIP", "browser gagal dijalankan: " + o.strip()[:200], d)
        return
    try:
        j = json.loads(o.strip().splitlines()[-1])
    except Exception:
        add("browser:smoke", "SKIP", "output tidak terparse", d)
        return
    ok = not j["page_errors"] and bool(j["visible"])
    add("browser:smoke", "PASS" if ok else "FAIL",
        f"title='{j['title']}' visible={j['visible']} err={len(j['page_errors'])}", d, json.dumps(j)[:2000])

# ---------- main ----------
def main():
    global MODE
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    if "--trusted" in flags:
        MODE = "trusted"
        print("MODE: TRUSTED — kode target akan dieksekusi. Hanya untuk sumber tepercaya.")
    RESULT["mode"] = MODE
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print(__doc__)
        return 2
    target = Path(args[0]).resolve()
    RESULT["target"] = str(target)
    RESULT["started"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    if not target.exists():
        print(f"target tidak ada: {target}")
        return 2
    probe_env()
    tmpdir = Path("/tmp/atest_tmp")
    shutil.rmtree(tmpdir, ignore_errors=True)
    tmpdir.mkdir(parents=True)
    ext = target.suffix.lower()
    if ext == ".py" or (target.is_dir() and list(target.glob("*.py"))):
        test_python(target)
    if ext == ".js":
        test_js(target, tmpdir)
    if ext == ".html":
        static_html(target, tmpdir)
        browser_smoke(target)
    if ext not in (".py", ".js", ".html"):
        if target.is_dir() and list(target.glob("*.html")):
            for h in sorted(target.glob("*.html")):
                print(f"--- {h.name} ---")
                static_html(h, tmpdir)
                browser_smoke(h)
        elif target.is_dir():
            add("dispatch", "FAIL", f"tipe target tidak dikenali: {target}")
    RESULT["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    stamp = time.strftime("%Y%m%d-%H%M%S")
    rep = OUT / stamp
    rep.mkdir(parents=True, exist_ok=True)
    fails = [t for t in RESULT["tests"] if t["status"] == "FAIL"]
    warns = [t for t in RESULT["tests"] if t["status"] == "WARN"]
    skips = [t for t in RESULT["tests"] if t["status"] == "SKIP"]
    verdict = "FAIL" if fails else ("PASS TERBATAS" if skips else "PASS")
    RESULT["summary"] = {"PASS": len([t for t in RESULT["tests"] if t["status"] == "PASS"]),
                         "FAIL": len(fails), "WARN": len(warns), "SKIP": len(skips),
                         "mode": MODE, "verdict": verdict}
    (rep / "report.json").write_text(json.dumps(RESULT, indent=2, ensure_ascii=False))
    lines = [f"target: {RESULT['target']}",
             f"mode: {MODE}",
             f"env: pytest={RESULT['env'].get('pytest')} node={RESULT['env'].get('node')} browser_tier={RESULT['env'].get('browser_tier')}",
             f"tes: " + " | ".join(f"{t['name']}={t['status']}" for t in RESULT["tests"]),
             f"VERDICT: {verdict} ({RESULT['summary']['PASS']} PASS / {RESULT['summary']['FAIL']} FAIL / {RESULT['summary']['WARN']} WARN / {RESULT['summary']['SKIP']} SKIP)",
             f"bukti: {rep}/report.json"]
    (rep / "report.md").write_text("\n".join(lines) + "\n")
    print("-" * 60)
    print("\n".join(lines))
    if "--json" in sys.argv:
        print(json.dumps(RESULT["summary"]))
    return 0 if not fails else 1

if __name__ == "__main__":
    sys.exit(main())
