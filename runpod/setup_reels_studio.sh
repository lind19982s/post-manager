#!/usr/bin/env bash
# Reels studio for a RunPod ComfyUI pod:
#   Wan 2.2 Animate (motion copy), Wan 2.2 S2V (talk + prompt motion), InfiniteTalk (long talk),
#   LTX-2 (fast, native audio), SeedVR2 upscale, RIFE interpolation.
# Usage: bash setup_reels_studio.sh      optional env: COMFY_DIR=/path  HF_TOKEN=hf_xxx  SKIP_LTX=1
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
log(){ printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn(){ printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
export PIP_DISABLE_PIP_VERSION_CHECK=1
# Template checkouts often have no upstream branch; point them at the remote's default branch.
git_update(){
  local d="$1" b
  if ! git -C "$d" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
    git -C "$d" fetch -q origin || return 1
    git -C "$d" remote set-head origin -a >/dev/null 2>&1
    b=$(git -C "$d" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || return 1
    git -C "$d" checkout -q -B "${b#origin/}" "$b" || return 1
  fi
  git -C "$d" pull -q --ff-only
}

COMFY="${COMFY_DIR:-}"
if [ -z "$COMFY" ]; then
  for d in /workspace/ComfyUI /workspace/runpod-slim/ComfyUI /ComfyUI /root/ComfyUI; do
    [ -f "$d/main.py" ] && COMFY="$d" && break
  done
fi
[ -n "$COMFY" ] || { echo "ComfyUI not found. Run with COMFY_DIR=/path/to/ComfyUI"; exit 1; }
PY=python3
for p in "${VIRTUAL_ENV:-/nonexistent}/bin/python" "$COMFY"/.venv*/bin/python "$COMFY"/../.venv*/bin/python "$COMFY/venv/bin/python" /workspace/venv/bin/python; do
  [ -x "$p" ] && PY="$p" && break
done
WFDIR="$COMFY/user/default/workflows"; mkdir -p "$WFDIR"
log "ComfyUI: $COMFY | python: $PY | GPU: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null)"
FREE_GB=$(df -BG --output=avail "$COMFY" | tail -1 | tr -dc '0-9')
[ "${FREE_GB:-0}" -lt 180 ] && warn "Only ${FREE_GB}GB free; the full studio needs about 150GB. Use a 250GB volume or SKIP_LTX=1."

log "Updating ComfyUI core (needed for native Wan 2.2 S2V and LTX-2 nodes)"
if [ -d "$COMFY/.git" ]; then git_update "$COMFY" || warn "ComfyUI update failed"; fi
"$PY" -m pip install -q -U -r "$COMFY/requirements.txt" || warn "ComfyUI requirements update failed"

log "Custom nodes"
cd "$COMFY/custom_nodes"
REPOS=(
  https://github.com/ltdrdata/ComfyUI-Manager
  https://github.com/kijai/ComfyUI-WanVideoWrapper
  https://github.com/kijai/ComfyUI-WanAnimatePreprocess
  https://github.com/kijai/ComfyUI-KJNodes
  https://github.com/kijai/ComfyUI-MelBandRoFormer
  https://github.com/kijai/ComfyUI-SCAIL-Pose
  https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite
  https://github.com/yolain/ComfyUI-Easy-Use
  https://github.com/cubiq/ComfyUI_essentials
  https://github.com/ltdrdata/ComfyUI-Impact-Pack
  https://github.com/chflame163/ComfyUI_LayerStyle
  https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes
  https://github.com/LAOGOU-666/Comfyui_LG_Tools
  https://github.com/judian17/ComfyUI_YOLO_For_Multi_SDPose_Detection
  https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler
  https://github.com/Fannovel16/ComfyUI-Frame-Interpolation
)
for r in "${REPOS[@]}"; do
  n="$(basename "$r")"
  if [ -d "$n/.git" ]; then git_update "$n" || warn "update failed: $n"
  else git clone -q --depth 1 "$r" "$n" || warn "clone failed: $r"; fi
  [ -f "$n/requirements.txt" ] && { "$PY" -m pip install -q -r "$n/requirements.txt" || warn "requirements failed: $n"; }
  [ -f "$n/install.py" ] && [ "$n" = "ComfyUI-Frame-Interpolation" ] && (cd "$n" && "$PY" install.py >/dev/null 2>&1 || true)
done

log "Python packages"
# diffusers and tokenizers require huggingface_hub < 2.0
"$PY" -m pip install -q "huggingface_hub>=1.23,<2.0" onnxruntime-gpu ultralytics gguf
"$PY" -m pip install -q sageattention || true
SAGE=1; "$PY" -c "import sageattention" 2>/dev/null || { SAGE=0; warn "sageattention unavailable; workflows will be switched to sdpa"; }

log "Collecting workflows"
[ -f "$HERE/wan_animate_runpod.json" ] && cp "$HERE/wan_animate_runpod.json" "$WFDIR/01_wan22_animate_motion_copy.json"
COMFY="$COMFY" WFDIR="$WFDIR" SKIP_LTX="${SKIP_LTX:-}" "$PY" - <<'PYEOF'
import glob, json, os, shutil, site
comfy, wfdir = os.environ["COMFY"], os.environ["WFDIR"]
roots = [p for p in site.getsitepackages() + [site.getusersitepackages()] if os.path.isdir(p)]
tpl = [f for r in roots for f in glob.glob(os.path.join(r, "comfyui_workflow_templates*", "**", "*.json"), recursive=True)]
kj = glob.glob(os.path.join(comfy, "custom_nodes", "ComfyUI-WanVideoWrapper", "example_workflows", "**", "*.json"), recursive=True)
def is_wf(f):
    try: return "nodes" in json.load(open(f, encoding="utf-8"))
    except Exception: return False
def pick(files, keys, prefer=()):
    c = [f for f in files if any(k in os.path.basename(f).lower() for k in keys)
         and not os.path.basename(f).lower().startswith("api_") and is_wf(f)]
    if not c: return None
    c.sort(key=lambda f: (not any(p in os.path.basename(f).lower() for p in prefer), len(os.path.basename(f))))
    return c[0]
wanted = [("02_wan22_s2v_talk_prompt_motion", tpl + kj, ["s2v"], ["wan2.2", "wan22", "video_wan"]),
          ("03_infinitetalk_long_talk", kj + tpl, ["infinitetalk"], ["i2v", "single"])]
if not os.environ.get("SKIP_LTX"):
    wanted.append(("04_ltx2_fast_native_audio", tpl, ["ltx2", "ltx_2", "ltx-2"], ["i2v"]))
for name, files, keys, prefer in wanted:
    f = pick(files, keys, prefer)
    if f: shutil.copy(f, os.path.join(wfdir, name + ".json")); print(f"{name}  <-  {os.path.basename(f)}")
    else: print(f"[!] no workflow found for {name}; it will be skipped")
# example workflows saved on Windows use backslashes in model paths
EXT = (".safetensors", ".onnx", ".pt", ".pth", ".gguf", ".bin", ".ckpt")
for f in glob.glob(os.path.join(wfdir, "*.json")):
    w = json.load(open(f, encoding="utf-8")); changed = False
    for n in list(w.get("nodes", [])) + [n for sg in (w.get("definitions") or {}).get("subgraphs", []) for n in sg.get("nodes", [])]:
        wv = n.get("widgets_values")
        if isinstance(wv, list):
            for i, v in enumerate(wv):
                if isinstance(v, str) and "\\" in v and v.lower().endswith(EXT):
                    wv[i] = v.replace("\\", "/"); changed = True
    if changed:
        json.dump(w, open(f, "w", encoding="utf-8"), ensure_ascii=False); print("fixed Windows paths in", os.path.basename(f))
PYEOF
[ "$SAGE" = 0 ] && sed -i 's/"sageattn"/"sdpa"/g' "$WFDIR"/*.json

log "Models: downloading everything the workflows reference"
export HF_XET_HIGH_PERFORMANCE=1
COMFY="$COMFY" WFDIR="$WFDIR" "$PY" - <<'PYEOF'
import glob, json, os, re, shutil, urllib.request
from huggingface_hub import HfApi, hf_hub_download
M = os.path.join(os.environ["COMFY"], "models")
api = HfApi()
EXT = (".safetensors", ".onnx", ".pt", ".pth", ".gguf", ".bin", ".ckpt")
SEARCH_REPOS = ["Kijai/WanVideo_comfy_fp8_scaled", "Kijai/WanVideo_comfy", "Comfy-Org/Wan_2.1_ComfyUI_repackaged",
                "Comfy-Org/Wan_2.2_ComfyUI_Repackaged", "Kijai/vitpose_comfy", "Wan-AI/Wan2.2-Animate-14B",
                "lightx2v/Wan2.2-Lightning", "alibaba-pai/Wan2.2-Fun-Reward-LoRAs", "RaphaelLiu/PusaV1",
                "Kijai/MelBandRoFormer_comfy", "Lightricks/LTX-2", "Kijai/WanVideo_comfy_GGUF",
                "city96/Wan2.1-I2V-14B-480P-gguf", "Kijai/wav2vec2_safetensors"]
LOADER_DIR = {"WanVideoModelLoader": "diffusion_models", "UNETLoader": "diffusion_models", "WanVideoVAELoader": "vae",
              "VAELoader": "vae", "CLIPVisionLoader": "clip_vision", "CheckpointLoaderSimple": "checkpoints",
              "WanVideoTextEncodeCached": "text_encoders", "LoadWanVideoT5TextEncoder": "text_encoders",
              "CLIPLoader": "text_encoders", "DualCLIPLoader": "text_encoders", "OnnxDetectionModelLoader": "detection",
              "LoraLoaderModelOnly": "loras", "WanVideoLoraSelect": "loras", "WanVideoLoraSelectMulti": "loras",
              "AudioEncoderLoader": "audio_encoders", "MelBandRoFormerModelLoader": "diffusion_models",
              "LTXVAudioVAELoader": "checkpoints", "MultiTalkModelLoader": "diffusion_models",
              "Wav2VecModelLoader": "wav2vec2"}
# the folder a loader reads from, taken from its source: class X ... folder_paths.get_filename_list("folder")
SRC = {}
for f in [os.path.join(os.environ["COMFY"], "nodes.py")] + glob.glob(os.path.join(os.environ["COMFY"], "comfy_extras", "*.py")) \
        + glob.glob(os.path.join(os.environ["COMFY"], "custom_nodes", "**", "*.py"), recursive=True):
    try: SRC[f] = open(f, encoding="utf-8", errors="ignore").read()
    except Exception: pass
VIRTUAL = {"unet_gguf": "diffusion_models", "clip_gguf": "text_encoders"}
def loader_folder(node_type):
    for txt in SRC.values():
        m = re.search(r"\nclass\s+" + re.escape(node_type) + r"\b", txt)
        if not m: continue
        body = re.split(r"\nclass\s", txt[m.end():], maxsplit=1)[0]
        g = re.search(r"get_filename_list\(\s*[\"']([\w\-]+)[\"']", body)
        if g: return VIRTUAL.get(g.group(1), g.group(1))
    return LOADER_DIR.get(node_type)
def all_nodes(w):
    yield from w.get("nodes", [])
    for sg in (w.get("definitions") or {}).get("subgraphs", []):
        yield from sg.get("nodes", [])
want = {}  # dest path -> (url or None, basename)
for f in sorted(glob.glob(os.path.join(os.environ["WFDIR"], "*.json"))):
    w = json.load(open(f, encoding="utf-8"))
    entries = list(w.get("models") or [])
    for n in all_nodes(w):
        entries += (n.get("properties") or {}).get("models") or []
        wv = n.get("widgets_values")
        folder = loader_folder(n.get("type", "")) if isinstance(wv, list) else None
        if folder:
            for v in wv:
                if isinstance(v, str) and v.lower().endswith(EXT):
                    want.setdefault(os.path.join(M, folder, v), (None, os.path.basename(v)))
    for e in entries:
        if e.get("name") and e.get("directory"):
            want[os.path.join(M, e["directory"], e["name"])] = (e.get("url"), os.path.basename(e["name"]))
cache = {}
def files(repo):
    if repo not in cache:
        try: cache[repo] = api.list_repo_files(repo)
        except Exception: cache[repo] = []
    return cache[repo]
def locate(name):
    for r in SEARCH_REPOS:
        for f in files(r):
            if os.path.basename(f) == name: return r, f
    kw = re.split(r"[_\-.]", name)[0]
    for m in api.list_models(search=kw, limit=25):
        for f in files(m.id):
            if os.path.basename(f) == name: return m.id, f
    return None
tmp = os.path.join(M, ".dl_tmp"); missing = []
for dst, (url, name) in sorted(want.items()):
    rest = os.path.relpath(dst, M).split(os.sep, 1)[-1]
    found = [p for p in glob.glob(os.path.join(M, "*", rest)) if os.path.getsize(p) > 1_000_000]
    if found: print("ok (exists)", os.path.relpath(found[0], M)); continue
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    try:
        hf = re.match(r"https://huggingface\.co/([^/]+/[^/]+)/resolve/[^/]+/([^?]+)", url or "")
        if hf: repo, path = hf.group(1), hf.group(2)
        elif url: print("downloading", name); urllib.request.urlretrieve(url, dst); continue
        else:
            hit = locate(name)
            if not hit: raise FileNotFoundError(name)
            repo, path = hit
        print(f"downloading {name}  ({repo})")
        shutil.move(hf_hub_download(repo, path, local_dir=tmp), dst)
    except Exception as e:
        missing.append(name); print("FAILED", name, "-", e)
shutil.rmtree(tmp, ignore_errors=True)
try:
    from ultralytics import YOLO
    os.chdir("/tmp"); YOLO("yolo11x-pose.pt")
    for sub in ("yolo", "ultralytics", "ultralytics/bbox"):
        d = os.path.join(M, sub); os.makedirs(d, exist_ok=True); shutil.copy("/tmp/yolo11x-pose.pt", d)
    missing = [m for m in missing if m != "yolo11x-pose.pt"]
except Exception as e:
    missing.append("yolo11x-pose.pt"); print("yolo download failed:", e)
print("\nMISSING MODELS:", missing) if missing else print("\nall referenced models downloaded")
PYEOF

run_check(){
  log "Verification: starting a temporary ComfyUI and checking every workflow"
  cd "$COMFY"
  "$PY" main.py --listen 127.0.0.1 --port 8199 >/tmp/comfy_check.log 2>&1 &
  local CPID=$!
  rm -f /tmp/object_info.json
  for _ in $(seq 1 150); do curl -sf http://127.0.0.1:8199/object_info >/tmp/object_info.json && break; sleep 3; done
  kill $CPID 2>/dev/null; wait $CPID 2>/dev/null
  COMFY="$COMFY" WFDIR="$WFDIR" HEAL="$1" "$PY" - <<'PYEOF'
import collections, glob, json, os, shutil, sys
M = os.path.join(os.environ["COMFY"], "models")
try: info = json.load(open("/tmp/object_info.json"))
except Exception: sys.exit("ComfyUI did not start. See /tmp/comfy_check.log")
skip = {"Reroute", "Note", "MarkdownNote", "PrimitiveNode", "GetNode", "SetNode"}
EXT = (".safetensors", ".onnx", ".pt", ".pth", ".gguf", ".bin", ".ckpt")
VIRTUAL = {"unet_gguf": "diffusion_models", "clip_gguf": "text_encoders"}
def on_disk(rel):
    return [p for p in glob.glob(os.path.join(M, "*", rel)) if os.path.isfile(p)]
def heal(val, opts):
    # put the file in the folder where the loader's other listed files live
    src = on_disk(val)
    if not src: return False
    votes = collections.Counter(os.path.relpath(p, M).split(os.sep)[0] for o in opts for x in o
                                if isinstance(x, str) and x.lower().endswith(EXT) for p in on_disk(x))
    cur = os.path.relpath(src[0], M).split(os.sep)[0]
    target = votes.most_common(1)[0][0] if votes else VIRTUAL.get(cur)
    if not target or target == cur: return False
    dst = os.path.join(M, target, val); os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.move(src[0], dst); print(f"   moved {val}: {cur}/ -> {target}/"); return True
moved, all_ok = False, True
for f in sorted(glob.glob(os.path.join(os.environ["WFDIR"], "*.json"))):
    w = json.load(open(f, encoding="utf-8"))
    sgs = (w.get("definitions") or {}).get("subgraphs", [])
    sg_ids = {s.get("id") for s in sgs}
    nodes = list(w.get("nodes", [])) + [n for s in sgs for n in s.get("nodes", [])]
    bad_nodes, bad_models = set(), set()
    for n in nodes:
        t = n.get("type")
        if t in skip or t in sg_ids or n.get("mode") in (2, 4): continue
        if t not in info: bad_nodes.add(t); continue
        inp = info[t]["input"]
        opts = [v[0] for v in {**inp.get("required", {}), **inp.get("optional", {})}.values()
                if isinstance(v, list) and v and isinstance(v[0], list)]
        wv = n.get("widgets_values")
        for val in (wv if isinstance(wv, list) else []):
            if isinstance(val, str) and val.lower().endswith(EXT) and opts and not any(val in o for o in opts):
                if os.environ.get("HEAL") == "1" and heal(val, opts): moved = True
                else: bad_models.add(f"{t}: {val}")
    ok = not bad_nodes and not bad_models; all_ok &= ok
    print(("\033[1;32mOK     \033[0m" if ok else "\033[1;31mPROBLEM\033[0m"), os.path.basename(f))
    if bad_nodes: print("   missing nodes:", sorted(bad_nodes))
    if bad_models: print("   models not visible:", sorted(bad_models))
if moved: print("\nMoved models into the right folders; checking again."); sys.exit(3)
print("\n\033[1;32mALL GOOD: every workflow is ready.\033[0m" if all_ok else
      "\nSend this whole output to Claude. Startup log: /tmp/comfy_check.log")
PYEOF
}
run_check 1; [ $? -eq 3 ] && run_check 0
log "Done. Restart the pod, open ComfyUI -> Workflows. SeedVR2 and RIFE download their own weights on first use."
