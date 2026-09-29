#!/usr/bin/env python3
"""Chạy helper nhận dạng lời NGUYÊN VẸN (có tách mô hình 0.6B + 1.7B) trong venv dev và ghi lại mọi module đã nạp.
Dùng để biết chính xác gói nào của site-packages thật sự cần cho bản đóng gói (bỏ phần thừa: scipy, numba, sklearn, nagisa…).

  python trace_imports.py --out imports.json -- <đối số của lyric_asr_helper.py: --mix … --vocal … --out … --device … --hf-home …>
"""
import json, os, runpy, sys, threading, time

def dump(path):
    mods = {}
    for name, m in list(sys.modules.items()):
        f = getattr(m, "__file__", None)
        if f: mods[name] = f
    json.dump({"prefix": sys.prefix, "base_prefix": sys.base_prefix, "modules": mods, "argv": sys.argv}, open(path, "w"))

def main():
    a = sys.argv[1:]
    out = a[a.index("--out") + 1] if "--out" in a else "imports.json"
    rest = a[a.index("--") + 1:]
    helper = None
    for i, x in enumerate(rest):
        if x.endswith("lyric_asr_helper.py"): helper = x; rest.pop(i); break
    assert helper, "đưa đường dẫn lyric_asr_helper.py làm đối số đầu sau `--`"
    real_exit = os._exit
    def exit_hook(code=0): dump(out); real_exit(code)
    os._exit = exit_hook
    def periodic():
        while True: time.sleep(2); dump(out)
    threading.Thread(target=periodic, daemon=True).start()
    sys.argv = [helper] + rest
    try: runpy.run_path(helper, run_name="__main__")
    finally: dump(out)

if __name__ == "__main__": main()
