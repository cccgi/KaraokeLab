#!/usr/bin/env python3
"""KaraokeMaker local lyric helper (isolated process). The Swift app starts this with the runtime's Python and talks to it
through JSON lines on stdout. It never touches the project, the timing engine or the network.

  lyric_asr_helper.py --probe --device cpu|mps --hf-home DIR
  lyric_asr_helper.py --mix MIX_16k.wav --vocal VOCAL_16k.wav --out RESULT.json --device cpu|mps --hf-home DIR
                      [--diagnostics] [--replay-cache DIR --replay-song NAME]

stdout events (one JSON object per line):
  {"event":"status","phase":"prepare|check|finish"}
  {"event":"progress","phase":"recognize|verify|context","done":4,"total":14}
  {"event":"model","name":"06|17","state":"loading|ready|released"}
  {"event":"done","result":"/path/RESULT.json"}     |     {"event":"error","code":"...","message":"..."}
Cancel = SIGTERM (exits at once; the OS frees the model memory). If the parent app dies, stdin closes and we exit too."""
import argparse
import json
import os
import signal
import sys
import threading
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lyric_correct"))
sys.dont_write_bytecode = True

_proto = os.fdopen(os.dup(1), "w", buffering=1, encoding="utf-8")   # protocol channel
sys.stdout = sys.stderr                                              # library chatter must never corrupt the protocol
_lock = threading.Lock()


def emit(ev):
    with _lock:
        _proto.write(json.dumps(ev, ensure_ascii=False, default=_json_default) + "\n"); _proto.flush()


def _json_default(o):
    try:
        import numpy as np
        if isinstance(o, np.generic): return o.item()
        if isinstance(o, np.ndarray): return o.tolist()
    except Exception:
        pass
    if isinstance(o, (set, tuple)): return list(o)
    raise TypeError(f"not JSON serializable: {type(o).__name__}")


def _terminate(signum, frame):
    os._exit(143)


def _watch_parent():
    try:
        while sys.stdin.buffer.read(4096): pass                      # blocks until the app closes our stdin (or dies)
    except Exception:
        pass
    os._exit(144)


def probe(args):
    info = {"event": "probe", "python": sys.version.split()[0], "device": args.device, "hf_home": args.hf_home}
    try:
        import torch
        info["torch"] = torch.__version__
        info["mps"] = bool(getattr(torch.backends, "mps", None) and torch.backends.mps.is_available())
    except Exception as e:
        info["torch_error"] = str(e)
    try:
        import qwen_asr
        info["qwen_asr"] = getattr(qwen_asr, "__version__", "installed")
    except Exception as e:
        info["qwen_asr_error"] = str(e)
    for mod in ("numpy", "soundfile"):
        try: __import__(mod); info[mod] = True
        except Exception as e: info[mod] = False; info[mod + "_error"] = str(e)
    models = {}
    os.environ["HF_HOME"] = args.hf_home; os.environ["HF_HUB_OFFLINE"] = "1"
    try:
        from huggingface_hub import snapshot_download
        for k, repo in (("06", "Qwen/Qwen3-ASR-0.6B"), ("17", "Qwen/Qwen3-ASR-1.7B")):
            try: snapshot_download(repo, local_files_only=True); models[k] = True
            except Exception: models[k] = False
    except Exception as e:
        info["hub_error"] = str(e)
    info["models"] = models
    info["ready"] = ("torch" in info and "qwen_asr" in info and info.get("numpy") and info.get("soundfile")
                     and models.get("06") and models.get("17") and (args.device != "mps" or info.get("mps")))
    emit(info)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--probe", action="store_true")
    ap.add_argument("--mix"); ap.add_argument("--vocal"); ap.add_argument("--out")
    ap.add_argument("--device", choices=["cpu", "mps"], required=True)
    ap.add_argument("--hf-home", required=True)
    ap.add_argument("--diagnostics", action="store_true")
    ap.add_argument("--replay-cache"); ap.add_argument("--replay-song")
    ap.add_argument("--no-watch", action="store_true", help="manual testing: do not exit when stdin closes")
    args = ap.parse_args()
    os.environ["HF_HOME"] = args.hf_home; os.environ["HF_HUB_OFFLINE"] = "1"          # BEFORE any hub/transformers import
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"; os.environ["TOKENIZERS_PARALLELISM"] = "false"
    signal.signal(signal.SIGTERM, _terminate); signal.signal(signal.SIGINT, _terminate)
    if not (args.replay_cache or args.no_watch): threading.Thread(target=_watch_parent, daemon=True).start()
    if args.probe:
        probe(args); return 0
    if not (args.mix and args.vocal and args.out):
        emit({"event": "error", "code": "bad_arguments", "message": "--mix, --vocal and --out are required"}); return 2
    try:
        import asr_backend as AB
        import engine as EN
        if args.replay_cache:
            backend = AB.ReplayBackend(args.replay_cache, args.replay_song)
        else:
            backend = AB.QwenBackend(args.device, args.hf_home, emit)
        result = EN.run(args.mix, args.vocal, backend, emit, want_diagnostics=args.diagnostics)
        if args.replay_cache and backend.missing: result["replay_missing"] = [list(m) for m in backend.missing]
        tmp = args.out + ".part"
        with open(tmp, "w", encoding="utf-8") as f: json.dump(result, f, ensure_ascii=False, default=_json_default)
        os.replace(tmp, args.out)
        emit({"event": "done", "result": args.out})
        return 0
    except EN.Cancelled:
        return 143
    except AB.BackendError as e:
        emit({"event": "error", "code": e.code, "message": str(e)}); return 2
    except MemoryError:
        emit({"event": "error", "code": "out_of_memory", "message": "not enough memory"}); return 2
    except Exception as e:
        traceback.print_exc()
        emit({"event": "error", "code": "failed", "message": f"{type(e).__name__}: {e}"}); return 2


if __name__ == "__main__":
    rc = main()
    try:                                       # leave WITHOUT interpreter finalisation: the stdin-watcher daemon thread is blocked in read()
        _proto.flush(); sys.stderr.flush()     # and would make Python abort at shutdown ("could not acquire lock for <stdin>")
    except Exception:
        pass
    os._exit(rc)
