#!/bin/bash
# setup-client-runtime.sh — bootstrap everything KaraokeMaker's "Auto Karaoke" (AI, no-lyrics-needed)
# feature needs on a vanilla macOS machine that is NOT the original dev Mac:
#   1) the 3 ONNX models (vocal separation + forced alignment) into Sources/KaraokeMaker/Resources/
#   2) a Python + PyTorch + qwen-asr virtualenv at the exact path AutoLyricsRuntime.swift looks for
#   3) the Qwen3-ASR 0.6B + 1.7B model weights pre-cached (so the first real use isn't slow/online-only)
#
# Scope: this does NOT install Xcode / the Swift toolchain and does NOT build the app. It assumes
# you already have (or will separately build) KaraokeMaker.app; see CLAUDE.md "Build / Run".
# This is only for the DEV-RUNTIME path (`-DKM_DEV_RUNTIME`, i.e. `Scripts/pack-local.sh`) — a real
# RELEASE build (`Scripts/package-release.sh`) bundles its own runtime inside the .app and needs none
# of this.
#
# Usage:
#   ./Scripts/setup-client-runtime.sh
#   ./Scripts/setup-client-runtime.sh --models-source "/path/to/5_KaraokeApp_source_with_git.zip"
#   ./Scripts/setup-client-runtime.sh --models-source "/path/to/folder/with/the/3/onnx/files"
#   ./Scripts/setup-client-runtime.sh --skip-models       # only set up the Python runtime
#   ./Scripts/setup-client-runtime.sh --skip-runtime       # only fetch/verify the ONNX models
#
set -euo pipefail
cd "$(dirname "$0")/.."

RESOURCES="Sources/KaraokeMaker/Resources"
MODELS_SOURCE=""
DO_MODELS=1
DO_RUNTIME=1

while [ $# -gt 0 ]; do
  case "$1" in
    --models-source) MODELS_SOURCE="$2"; shift 2;;
    --skip-models) DO_MODELS=0; shift;;
    --skip-runtime) DO_RUNTIME=0; shift;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "Unknown argument: $1" >&2; exit 2;;
  esac
done

ARCH="$(uname -m)"   # arm64 | x86_64
BOLD="$(tput bold 2>/dev/null || true)"; RESET="$(tput sgr0 2>/dev/null || true)"
ok()   { echo "  ✓ $*"; }
info() { echo "  → $*"; }
warn() { echo "  ⚠ $*" >&2; }
err()  { echo "  ✗ $*" >&2; }

# ============================================================================
# Step 1 — ONNX models (vocal separation + forced alignment)
# ============================================================================
# Known checksums (sha256) of the exact files this project's Package.swift expects, taken from the
# original dev Mac on 2026-09-29 — used to verify ANY source (download or local copy) before trusting it.
# (Plain functions instead of associative arrays: macOS ships bash 3.2 as /bin/bash, which predates
# `declare -A` — this script must run on a vanilla client Mac with no Homebrew/newer-bash assumed.)
expected_sha256() {
  case "$1" in
    "UVR-MDX-NET-Voc_FT.onnx") echo "534b2070fcc7df514b13ef660dc8cbb328679c2374d04354a5c42bb14ecce111";;
    "mdx23c-vocinst.onnx")     echo "76d86410007cc23086fab2d01812586eda9b706b33ece057172de9fc4af6fea3";;
    "mms-aligner-uint8.onnx")  echo "dc79e3bd48bffa9b4fb850d6195710d4eeb13e2fdf1f521eccbca512ab530254";;
  esac
}
# Confirmed-working public source (audio-separation community's standard model host; sha256
# cross-checked against this project's own copy on 2026-09-29 — safe to auto-download). The other
# two models have no verified public source — the original developer converted/quantized them by
# hand (mdx23c ONNX export, and a uint8-quantized MMS forced aligner). Those must come from a copy
# of this project (--models-source) or wherever you choose to host them yourself.
public_url() {
  case "$1" in
    "UVR-MDX-NET-Voc_FT.onnx") echo "https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/UVR-MDX-NET-Voc_FT.onnx";;
  esac
}

verify_sha256() {
  local file="$1" want; want="$(expected_sha256 "$2")"
  local got; got="$(shasum -a 256 "$file" | awk '{print $1}')"
  [ -n "$want" ] && [ "$got" = "$want" ]
}

install_model() {
  local name="$1" dest="$RESOURCES/$1"
  if [ -f "$dest" ] && verify_sha256 "$dest" "$name"; then
    ok "$name already present and verified"
    return 0
  fi
  rm -f "$dest"

  # (a) explicit --models-source: a zip (handover archive) or a plain directory
  # NOTE: capture the full `unzip -l` listing via command substitution (runs to completion) rather
  # than piping into `grep -q` — with `pipefail` set, `grep -q` exiting early on the first match
  # closes the pipe and SIGPIPEs `unzip -l` mid-listing on a multi-GB archive, which pipefail then
  # reports as a failed pipeline even though the match actually succeeded.
  if [ -n "$MODELS_SOURCE" ]; then
    if [ -d "$MODELS_SOURCE" ] && [ -f "$MODELS_SOURCE/$name" ]; then
      info "copying $name from $MODELS_SOURCE ..."
      cp "$MODELS_SOURCE/$name" "$dest"
    elif [ -f "$MODELS_SOURCE" ]; then
      local zip_listing zpath
      zip_listing="$(unzip -l "$MODELS_SOURCE" 2>/dev/null || true)"
      zpath="$(echo "$zip_listing" | grep "Resources/$name\$" | awk '{print $4}')"
      if [ -n "$zpath" ]; then
        info "extracting $name from $(basename "$MODELS_SOURCE") ..."
        unzip -p "$MODELS_SOURCE" "$zpath" > "$dest"
      fi
    fi
  fi

  # (b) known-good public URL
  local url; url="$(public_url "$name")"
  if [ ! -f "$dest" ] && [ -n "$url" ]; then
    info "downloading $name from verified public source ..."
    curl -fL --progress-bar -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi

  if [ ! -f "$dest" ]; then
    err "$name — no source available."
    if [ -z "$url" ]; then
      err "    No verified public download exists for this one (custom-converted by the original"
      err "    developer). Get it from the handover archive (5_KaraokeApp_source_with_git.zip) and"
      err "    re-run with: --models-source /path/to/that.zip  (or a folder containing $name)"
    fi
    return 1
  fi

  if ! verify_sha256 "$dest" "$name"; then
    err "$name downloaded/copied but checksum does NOT match the expected file — removing it."
    err "    (got $(shasum -a 256 "$dest" | awk '{print $1}'))"
    rm -f "$dest"
    return 1
  fi
  ok "$name installed and verified"
}

MODELS_MISSING=0
if [ "$DO_MODELS" = 1 ]; then
  echo "${BOLD}▶ Step 1/2 — ONNX models${RESET} ($RESOURCES)"
  mkdir -p "$RESOURCES"
  for m in "UVR-MDX-NET-Voc_FT.onnx" "mdx23c-vocinst.onnx" "mms-aligner-uint8.onnx"; do
    install_model "$m" || MODELS_MISSING=1
  done
  echo
fi

# ============================================================================
# Step 2 — Python + PyTorch + qwen-asr runtime (dev-runtime path only)
# ============================================================================
# AutoLyricsRuntime.swift looks for exactly these paths when built with -DKM_DEV_RUNTIME (see
# `Services/AutoLyrics/AutoLyricsRuntime.swift`):
#   Apple Silicon → ~/qwen3_asr_m4_test/venv_official
#   Intel         → ~/qwen3_asr_intel_test/venv_qwenasr
# Package set is the app's actual minimal runtime closure (torch/transformers/soundfile/numpy/
# huggingface_hub/qwen-asr — see Scripts/asr-runtime/build_runtime.py ROOT_DISTS; deliberately
# excludes qwen-asr's unused extras like librosa/sklearn/numba, which are lab-only).
if [ "$DO_RUNTIME" = 1 ]; then
  echo "${BOLD}▶ Step 2/2 — Python ASR runtime${RESET} (arch: $ARCH)"

  if [ "$ARCH" = "arm64" ]; then
    ROOT="$HOME/qwen3_asr_m4_test"; VENV="$ROOT/venv_official"
    TORCH_PIN="torch==2.14.0"    # verified working on this project's own arm64 dev Mac, 2026-09-29
  elif [ "$ARCH" = "x86_64" ]; then
    ROOT="$HOME/qwen3_asr_intel_test"; VENV="$ROOT/venv_qwenasr"
    TORCH_PIN="torch==2.2.2"     # per 00_DOC_TRUOC_README.md, CPU-only Intel path
  else
    err "unrecognized architecture: $ARCH"; exit 1
  fi

  PY=""
  for cand in python3.12 python3; do
    if command -v "$cand" >/dev/null 2>&1; then PY="$cand"; break; fi
  done
  if [ -z "$PY" ]; then
    err "no python3 found on PATH. Install Python 3.12 first (e.g. \`brew install python@3.12\`), then re-run."
    exit 1
  fi
  info "using $($PY --version) ($(command -v "$PY"))"

  if [ ! -x "$VENV/bin/python" ]; then
    info "creating venv at $VENV ..."
    mkdir -p "$ROOT"
    "$PY" -m venv "$VENV"
  else
    ok "venv already exists at $VENV"
  fi

  info "installing pinned packages (this downloads ~2-3GB, needs internet) ..."
  "$VENV/bin/pip" install -q --upgrade pip
  "$VENV/bin/pip" install -q \
    "$TORCH_PIN" \
    "transformers==4.57.6" \
    "huggingface_hub==0.36.2" \
    "soundfile==0.14.0" \
    numpy \
    "qwen-asr==0.0.6" \
    --no-deps
  # --no-deps: qwen-asr declares extras (librosa/numba/sklearn/nagisa) the app never imports — see
  # build_runtime.py comment above. Install its own real runtime deps explicitly instead:
  "$VENV/bin/pip" install -q einops safetensors accelerate

  info "verifying imports ..."
  "$VENV/bin/python" - <<'PYEOF'
import torch, transformers, qwen_asr
print(f"    torch {torch.__version__} | transformers {transformers.__version__} | qwen_asr OK")
print(f"    MPS available: {getattr(torch.backends, 'mps', None) and torch.backends.mps.is_available()}")
PYEOF
  ok "Python runtime OK"

  HF_HOME="$ROOT/hf_cache"
  echo
  info "pre-caching Qwen3-ASR model weights into $HF_HOME (this downloads several GB, needs internet) ..."
  HF_HOME="$HF_HOME" "$VENV/bin/python" - <<'PYEOF'
from huggingface_hub import snapshot_download
for repo in ("Qwen/Qwen3-ASR-0.6B", "Qwen/Qwen3-ASR-1.7B"):
    print(f"    fetching {repo} ...")
    snapshot_download(repo_id=repo)
print("    done.")
PYEOF
  ok "Qwen3-ASR weights cached"
  echo
fi

# ============================================================================
echo "${BOLD}Summary${RESET}"
if [ "$DO_MODELS" = 1 ]; then
  if [ "$MODELS_MISSING" = 1 ]; then
    warn "one or more ONNX models still missing — see errors above. The app will still BUILD, but"
    warn "vocal separation / forced alignment will fail at runtime until they're in place."
  else
    ok "all 3 ONNX models present and verified"
  fi
fi
if [ "$DO_RUNTIME" = 1 ]; then
  ok "Python ASR runtime ready at $VENV"
fi
echo
echo "Next: build + run with the dev runtime flag —"
echo "  cd \"$(pwd)\" && ./Scripts/pack-local.sh && open dist/KaraokeMaker.app"
