"""ASR backends. The ONLY place that touches torch / qwen-asr (official package). Everything else is portable Python.

QwenBackend   official `qwen-asr` (PyTorch). Intel x86_64 -> CPU / float32 ; Apple Silicon arm64 -> MPS / bfloat16.
              Models are loaded one at a time (0.6B <-> 1.7B) and released as soon as a pass is finished.
ReplayBackend answers from a JSON cache of earlier real runs (tests only)."""
import gc
import json
import os
import time

REPOS = {"06": "Qwen/Qwen3-ASR-0.6B", "17": "Qwen/Qwen3-ASR-1.7B"}
CAP_PER_SEC, CAP_ADD = 6.0, 16            # proven token guard: ~6 tokens/second + 16
LANGUAGE = "Vietnamese"


class BackendError(Exception):
    def __init__(self, code, message):
        super().__init__(message); self.code = code


class QwenBackend:
    def __init__(self, device, hf_home, emit=None):
        self.device = device                                    # "cpu" | "mps"
        self.dtype_name = "bfloat16" if device == "mps" else "float32"
        self.hf_home = hf_home
        self.emit = emit or (lambda e: None)
        self._model = None; self._model_id = None; self._tok = None; self._parse = None; self._torch = None
        os.environ["HF_HOME"] = hf_home
        os.environ["HF_HUB_OFFLINE"] = "1"                      # NEVER download anything from inside the app
        os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
        os.environ["TOKENIZERS_PARALLELISM"] = "false"

    def describe(self):
        return {"device": self.device, "dtype": self.dtype_name, "engine": "qwen-asr (official)"}

    def _load(self, model_id):
        if self._model_id == model_id: return
        self.unload()
        try:
            import torch
            from huggingface_hub import snapshot_download
            from qwen_asr import Qwen3ASRModel
            from qwen_asr.inference.utils import parse_asr_output
        except Exception as e:
            raise BackendError("runtime_missing", f"qwen-asr / torch not importable: {e}")
        self._torch = torch; self._parse = parse_asr_output
        if self.device == "mps" and not torch.backends.mps.is_available():
            raise BackendError("backend_unavailable", "MPS is not available on this machine")
        self.emit({"event": "model", "name": model_id, "state": "loading"})
        try:
            path = snapshot_download(REPOS[model_id], local_files_only=True)
        except Exception as e:
            raise BackendError("model_missing", f"{REPOS[model_id]} was not found in {self.hf_home}")
        dtype = torch.bfloat16 if self.device == "mps" else torch.float32
        t0 = time.time()
        self._model = Qwen3ASRModel.from_pretrained(path, dtype=dtype, device_map=self.device, max_inference_batch_size=1, max_new_tokens=512)
        self._tok = self._model.processor.tokenizer
        self._model_id = model_id
        self.emit({"event": "model", "name": model_id, "state": "ready", "seconds": round(time.time() - t0, 1)})

    def unload(self):
        if self._model is None: return
        model_id = self._model_id
        self._model = None; self._tok = None; self._model_id = None
        gc.collect()
        try:
            if self.device == "mps": self._torch.mps.empty_cache()
        except Exception:
            pass
        self.emit({"event": "model", "name": model_id, "state": "released"})

    def transcribe(self, model_id, seg, sr, context="", **_):
        self._load(model_id)
        dur = len(seg) / sr
        cap = int(CAP_PER_SEC * dur) + CAP_ADD
        self._model.max_new_tokens = cap
        raw = self._model._infer_asr_transformers([context], [seg], [LANGUAGE])[0]
        if self.device == "mps": self._torch.mps.synchronize()
        ntok = len(self._tok(raw, add_special_tokens=False)["input_ids"])
        _lang, text = self._parse(raw, user_language=LANGUAGE)
        return {"raw": raw, "text": text, "ntok": ntok, "cap": cap, "cap_hit": bool(ntok >= cap - 1), "context": context}


class ReplayBackend:
    """Serves results recorded by earlier real runs: cache/{song}_{06|17}.json keyed 'start|end|context'."""
    def __init__(self, cache_dir, song):
        self.data = {}
        for m in ("06", "17"):
            p = f"{cache_dir}/{song}_{m}.json"
            self.data[m] = json.load(open(p)) if os.path.exists(p) else {}
        self.missing = []

    def describe(self):
        return {"device": "replay", "dtype": "n/a", "engine": "replay"}

    def unload(self): pass

    def transcribe(self, model_id, seg, sr, context="", start=None, end=None):
        r = self.data[model_id].get(f"{start:.3f}|{end:.3f}|{context}")
        if r is None:
            self.missing.append((model_id, start, end, context))
            return None
        return r
