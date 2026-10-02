#!/usr/bin/env bash
# One-file installer: unpacks the workflow and setup script next to itself, then runs the setup.
HERE="$(cd "$(dirname "$0")" && pwd)"
exec 9>/tmp/reels_install.lock
flock -n 9 || { echo "An install is already running. Watch it with: tail -f $HERE/install_log.txt"; exit 1; }
# write to temp files and rename, so a script that is still being read is never overwritten in place
sed -n '/^__WORKFLOW_B64__$/,$p' "$0" | tail -n +2 | base64 -d | gunzip > "$HERE/wan_animate_runpod.json.tmp" && mv -f "$HERE/wan_animate_runpod.json.tmp" "$HERE/wan_animate_runpod.json"
sed -n '2,/^__SETUP_END__$/p' "$0" | sed '1,/^__SETUP_START__$/d;$d' > "$HERE/setup_reels_studio.sh.tmp" && mv -f "$HERE/setup_reels_studio.sh.tmp" "$HERE/setup_reels_studio.sh"
bash "$HERE/setup_reels_studio.sh" 2>&1 | tee "$HERE/install_log.txt"
echo; echo "Log saved to $HERE/install_log.txt"
exit 0
__SETUP_START__
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
    c = [f for f in files if any(k in os.path.basename(f).lower() for k in keys) and is_wf(f)]
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
def loader_folder(node_type):
    for txt in SRC.values():
        m = re.search(r"\nclass\s+" + re.escape(node_type) + r"\b", txt)
        if not m: continue
        body = re.split(r"\nclass\s", txt[m.end():], maxsplit=1)[0]
        g = re.search(r"get_filename_list\(\s*[\"']([\w\-]+)[\"']", body)
        if g: return g.group(1)
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
except Exception as e:
    missing.append("yolo11x-pose.pt"); print("yolo download failed:", e)
print("\nMISSING MODELS:", missing) if missing else print("\nall referenced models downloaded")
PYEOF

log "Verification: starting a temporary ComfyUI and checking every workflow"
cd "$COMFY"
"$PY" main.py --listen 127.0.0.1 --port 8199 >/tmp/comfy_check.log 2>&1 &
CPID=$!
for _ in $(seq 1 150); do curl -sf http://127.0.0.1:8199/object_info >/tmp/object_info.json && break; sleep 3; done
kill $CPID 2>/dev/null; wait $CPID 2>/dev/null
WFDIR="$WFDIR" "$PY" - <<'PYEOF'
import glob, json, os, sys
try: info = json.load(open("/tmp/object_info.json"))
except Exception: sys.exit("ComfyUI did not start. See /tmp/comfy_check.log")
skip = {"Reroute", "Note", "MarkdownNote", "PrimitiveNode", "GetNode", "SetNode"}
EXT = (".safetensors", ".onnx", ".pt", ".pth", ".gguf", ".bin", ".ckpt")
all_ok = True
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
                bad_models.add(f"{t}: {val}")
    ok = not bad_nodes and not bad_models; all_ok &= ok
    print(("\033[1;32mOK     \033[0m" if ok else "\033[1;31mPROBLEM\033[0m"), os.path.basename(f))
    if bad_nodes: print("   missing nodes:", sorted(bad_nodes))
    if bad_models: print("   models not visible:", sorted(bad_models))
print("\n\033[1;32mALL GOOD: every workflow is ready.\033[0m" if all_ok else
      "\nSend this whole output to Claude. Startup log: /tmp/comfy_check.log")
PYEOF
log "Done. Restart the pod, open ComfyUI -> Workflows. SeedVR2 and RIFE download their own weights on first use."
__SETUP_END__
__WORKFLOW_B64__
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
3UkkO0U9/ZxcMpVsbyfP5//0ZT9Ok87sZnIrNWqVJcuSbtyUXN0eTSfjgpNZP5UcyiYM97Zz7kfb
OrToqcM3/+vwy1cO3/zt/bv3/vjtO4d/eOPg40/kj4effHjw4kvyx4Pfv3741ssHn3/64Ldv3b/7
o4O7r8mP+7/+2f7XH2TZ/u3dg198K3/cv/fz/Z/m+f/p9/J38ePhJ5+pon6d/Tj44Hf37/10/733
H7z0Zfbvz1/c/58vDn/3+cM33stLeHfx+6+vbJ7ff/ftB9/+x8EXbz/44MMs+e77Dz98+8FHr2aU
8uO33xS/5UJ0/96HmZnAm28fvPNGUfH+dz+TvO7/8l7x/eErn1e/H756V33/4O7+vc9Uyb95af+L
r1XJ9z6TXbBIPXz5M8l9liev6PBffrT/4x8umpcV+9bnMtui2QefvHz/668ywlfeOfjwN3kT3jz4
5NPD1/6QdXT+8f433+x/90PZhKy6F3/y4JMXD//7y9MP//Pb/XtfLSaPHNxsfubzsZhFp/XsKU03
NSeWH7LZkdNPJ8lgQbicR0m/n24rc0I50fem4zz3bDdNB7I4Oal3stmnKPV8WQLsVNXX1o3dvXUc
bUn5lI7lamB50tVix51sy8QrVy9fvJILxkvnNq92V/jMNctsd0mdBxMvSgIuqks53AHMzbSmBsR2
xW3cafZHsxp752UGl8dMK6kpu1atzbl1rRIOno9puWrajMX6W98MOxusGfg2w8lI42b83V4it4N/
X2sub+SpNMCZ2nQSVatv5QZ4MJrd6vaT/k0Qq1Yup8dfR3o7f782G80fF8p9Qc273yK1+qzQ/N60
r8uVtfGq9ayUpptymzFIz2ZNHPj61aJx9kqfxDGOkfyjHK50KGZyx5VfE0Pv+2OKA7n3CkkclhxE
8MzzVslFbNXH1hG6ghUc9dAAxShl4YBJjjhLCRr0wwENh0PRZ3EP9UQvPPGuYEurjPkIwZYjVU+s
pWluJi6XAuu7JWHNVDUfzY+GQGjrtqoyU113Iy2tBEeWSZrpeRXch45a26eNxuvtmOJ8p30C/Eat
8h7e3mfUqMEbqFVhM2B/USjkgRCxiCz/M5QGiOAQvjEJn3iMauQxanQi3iix74E9y8pL+Rbeonj0
yLxFQcZmj8PIhXNKAkowwpGhDTAUBTikEVHGAhVtgIknB7TO2wp+lEYuSydlUvQuLAdwhB+dsan7
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
9odpN8j508e1LI7/AMJ1V59fnL8Q7U21AgA=
