#!/usr/bin/env python3
"""Dựng thư mục runtime TỰ CHỨA cho 1 kiến trúc (chạy trên máy đúng kiến trúc, bằng Python của venv dev).

  <VENV>/bin/python build_runtime.py --venv   (PHẢI chạy bằng Python của venv để đọc đúng metadata gói)
  --venv VENV --python-base UVPY --imports imports.json --hf-cache HF --out OUT [--no-models]

OUT/python/          Python standalone (đã cắt test/idle/tk…)
OUT/site-packages/   CHỈ các gói thật sự được nạp (theo imports.json) + phần phụ thuộc bắt buộc + dist-info
OUT/hf_cache/hub/    2 mô hình (0.6B, 1.7B) dạng file thật (không symlink)
OUT/MANIFEST.json
"""
import argparse, importlib.metadata as md, json, os, re, shutil, subprocess, sys
from pathlib import Path

REPOS = ["Qwen--Qwen3-ASR-0.6B", "Qwen--Qwen3-ASR-1.7B"]
# Phần cắt khỏi Python standalone (an toàn: không dùng khi chạy helper)
PY_PRUNE = ["lib/python3.11/test", "lib/python3.11/idlelib", "lib/python3.11/tkinter", "lib/python3.11/turtledemo",
            "lib/python3.11/ensurepip", "lib/python3.11/lib2to3", "lib/python3.11/pydoc_data", "lib/python3.11/site-packages",
            "lib/python3.11/config-3.11-darwin", "lib/tcl8.6", "lib/tk8.6", "lib/itcl4.2.4", "lib/thread2.8.9", "lib/tdbc1.1.5",
            "lib/tdbcsqlite31.1.5", "lib/tdbcodbc1.1.5", "lib/tdbcmysql1.1.5", "lib/tdbcpostgres1.1.5", "lib/sqlite3.40.1",
            "include", "share", "lib/pkgconfig"]
PY_PRUNE_GLOBS = ["lib/libpython3*.dylib", "lib/libpython3*.a", "lib/libtcl*", "lib/libtk*", "lib/tcl*", "lib/tk*", "lib/itcl*", "lib/thread*", "lib/tdbc*", "lib/sqlite*", "lib/python3.11/lib-dynload/_tkinter*"]
PY_BIN_KEEP = {"python", "python3", "python3.11"}     # bỏ pip/idle/2to3/pydoc/*-config (không dùng, có shebang tuyệt đối)
EXCLUDE_TOPS = {"_virtualenv.py", "_distutils_hack", "pip", "setuptools", "pkg_resources", "wheel", "distutils-precedence.pth"}
# Bắt buộc dù trace không thấy (nạp qua dlopen/cffi)
ALWAYS_WITH = {"soundfile": ["_soundfile_data", "_soundfile"], "cffi": ["_cffi_backend"]}
# Phụ thuộc khai báo của các gói lõi (không kéo extras của qwen-asr: librosa/numba/sklearn/nagisa… không được dùng)
ROOT_DISTS = ["torch", "transformers", "soundfile", "numpy", "huggingface_hub"]

def norm(n): return re.sub(r"[-_.]+", "-", n).lower()

def closure(roots):
    seen, todo = set(), [norm(r) for r in roots]
    while todo:
        d = todo.pop()
        if d in seen: continue
        try: dist = md.distribution(d)
        except md.PackageNotFoundError: continue
        seen.add(d)
        for r in dist.requires or []:
            if "extra ==" in r: continue                       # bỏ extras
            name = re.split(r"[ ;<>=!~\[(]", r.strip(), maxsplit=1)[0]
            if "sys_platform" in r and "darwin" not in r and "!= 'darwin'" not in r and "sys_platform ==" in r: continue
            todo.append(norm(name))
    return seen

def copy_models(hf_cache, out):
    """Chép 2 mô hình dạng file thật (không symlink; bỏ README/.gitattributes). `cp -c` = clonefile → cùng ổ APFS không tốn thêm đĩa."""
    models = {}
    hub = hf_cache / "hub"
    for r in REPOS:
        src = hub / f"models--{r}"
        rev = (src / "refs" / "main").read_text().strip()
        dst = out / "hf_cache" / "hub" / f"models--{r}"
        shutil.rmtree(dst, ignore_errors=True)
        (dst / "refs").mkdir(parents=True); (dst / "refs" / "main").write_text(rev)
        snap = dst / "snapshots" / rev; snap.mkdir(parents=True)
        for f in (src / "snapshots" / rev).iterdir():
            if f.name in ("README.md", ".gitattributes"): continue
            subprocess.check_call(["cp", "-cLp", str(f), str(snap / f.name)])
        models[r] = rev
    return models

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--venv"); ap.add_argument("--python-base")
    ap.add_argument("--imports"); ap.add_argument("--hf-cache", required=True)
    ap.add_argument("--out", required=True); ap.add_argument("--no-models", action="store_true")
    ap.add_argument("--models-only", action="store_true", help="chỉ chép 2 mô hình vào OUT (OUT đã có python/ và site-packages/)")
    a = ap.parse_args()
    out = Path(a.out)
    if a.models_only:
        copy_models(Path(a.hf_cache), out); print("models added:", out / "hf_cache"); return
    assert a.venv and a.python_base and a.imports, "cần --venv --python-base --imports"
    shutil.rmtree(out, ignore_errors=True); out.mkdir(parents=True)

    # 1) Python standalone
    py = out / "python"
    subprocess.check_call(["ditto", a.python_base, str(py)])
    for rel in PY_PRUNE: shutil.rmtree(py / rel, ignore_errors=True)
    for pat in PY_PRUNE_GLOBS:                                   # Tcl/Tk/libpython dylib (python3.11 đã nhúng libpython tĩnh — dylib có id tuyệt đối tới máy dev)
        for f in py.glob(pat):
            shutil.rmtree(f, ignore_errors=True) if f.is_dir() else f.unlink()
    for f in list(py.rglob("__pycache__")): shutil.rmtree(f, ignore_errors=True)
    for f in (py / "bin").iterdir():
        if f.name not in PY_BIN_KEEP: f.unlink()

    # 2) site-packages tối thiểu
    venv_sp = next(Path(a.venv, "lib").glob("python3*/site-packages"))
    tr = json.load(open(a.imports))
    tops = set()
    for name, f in tr["modules"].items():
        try: rel = Path(f).resolve().relative_to(venv_sp.resolve())
        except ValueError: continue
        tops.add(rel.parts[0])
    # gói (dist) tương ứng với các top-level đã nạp + phụ thuộc bắt buộc
    pkg2dist = md.packages_distributions()
    dists = set()
    for t in list(tops):
        stem = t.split(".")[0]
        for d in pkg2dist.get(stem, []): dists.add(norm(d))
    dists |= closure(ROOT_DISTS)                              # KHÔNG kéo khai báo của qwen-asr (librosa/numba/sklearn/nagisa… không dùng)
    # thêm top-level của mọi dist trong closure (chỉ những gì thực sự có trong venv)
    for d in list(dists):
        try: dist = md.distribution(d)
        except md.PackageNotFoundError: continue
        for f in dist.files or []:
            top = f.parts[0]
            if top.endswith(".dist-info") or top in ("..", "__pycache__") or top.startswith("~"): continue
            if (venv_sp / top).exists() and not top.startswith("bin"): tops.add(top)
    # nhưng KHÔNG kéo các gói nặng chỉ do qwen-asr khai báo mà không được nạp: giữ đúng (đã lọc ở closure vì ta chỉ kéo ROOT_DISTS)
    for base, extra in ALWAYS_WITH.items():
        if base in tops or base in pkg2dist:
            for e in extra:
                if (venv_sp / e).exists(): tops.add(e)
    tops -= EXCLUDE_TOPS
    site = out / "site-packages"; site.mkdir()
    copied = []
    for t in sorted(tops):
        s = venv_sp / t
        if not s.exists(): continue
        if s.is_dir(): shutil.copytree(s, site / t, symlinks=True, ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "tests", "test"))
        else: shutil.copy2(s, site / t)
        copied.append(t)
    # dist-info của các dist được giữ (importlib.metadata cần để kiểm tra phiên bản)
    kept_di = []
    for di in venv_sp.glob("*.dist-info"):
        n = norm(re.sub(r"-[0-9].*$", "", di.name[:-len(".dist-info")]))
        if n in dists or n == "qwen-asr":
            shutil.copytree(di, site / di.name, symlinks=True); kept_di.append(di.name)
    # torch: bỏ phần chỉ dùng để biên dịch
    for rel in ("torch/include", "torch/share", "torch/test"):
        shutil.rmtree(site / rel, ignore_errors=True)

    # kiểm chứng: MỌI module đã được nạp trong lần chạy thật đều có mặt trong bản cắt gọn
    missing = []
    for name, f in tr["modules"].items():
        try: rel = Path(f).resolve().relative_to(venv_sp.resolve())
        except ValueError: continue
        if rel.parts[0] in EXCLUDE_TOPS: continue                 # bootstrap của venv dev, không thuộc bản đóng gói
        if not (site / rel).exists(): missing.append(str(rel))
    if missing: print("THIẾU (đã nạp khi chạy thật nhưng không có trong bản cắt gọn):", missing[:20]); sys.exit(3)

    # 3) mô hình
    models = {} if a.no_models else copy_models(Path(a.hf_cache), out)

    # 4) pyc (không phụ thuộc mtime → bền khi copy/nén/giải nén)
    pyexe = py / "bin" / "python3"
    subprocess.call([str(pyexe), "-m", "compileall", "-q", "-j", "0", "--invalidation-mode", "unchecked-hash", str(site), str(py / "lib")],
                    env={**os.environ, "PYTHONDONTWRITEBYTECODE": ""}, stdout=subprocess.DEVNULL)

    def size(p):
        return int(subprocess.check_output(["du", "-sk", str(p)]).split()[0]) // 1024
    man = {"arch": subprocess.check_output(["uname", "-m"]).decode().strip(), "python": size(py), "site_packages_mb": size(site),
           "models_mb": size(out / "hf_cache") if not a.no_models else 0, "top_level": copied, "dist_info": kept_di, "models": models}
    json.dump(man, open(out / "MANIFEST.json", "w"), indent=1)
    print(json.dumps({k: v for k, v in man.items() if k not in ("top_level", "dist_info")}, indent=1)); print("top-level:", len(copied), "dist-info:", len(kept_di))

if __name__ == "__main__": main()
