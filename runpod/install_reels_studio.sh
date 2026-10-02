#!/usr/bin/env bash
# One-file installer: unpacks the Wan Animate workflow next to itself, then runs the studio setup.
HERE="$(cd "$(dirname "$0")" && pwd)"
sed -n '/^__WORKFLOW_B64__$/,$p' "$0" | tail -n +2 | base64 -d | gunzip > "$HERE/wan_animate_runpod.json"
sed -n '2,/^__SETUP_END__$/p' "$0" | sed '1,/^__SETUP_START__$/d;$d' > "$HERE/setup_reels_studio.sh"
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
"$PY" -m pip install -q "huggingface_hub>=1.23,<2.0" onnxruntime-gpu ultralytics
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
                "Kijai/MelBandRoFormer_comfy", "Lightricks/LTX-2"]
LOADER_DIR = {"WanVideoModelLoader": "diffusion_models", "UNETLoader": "diffusion_models", "WanVideoVAELoader": "vae",
              "VAELoader": "vae", "CLIPVisionLoader": "clip_vision", "CheckpointLoaderSimple": "checkpoints",
              "WanVideoTextEncodeCached": "text_encoders", "LoadWanVideoT5TextEncoder": "text_encoders",
              "CLIPLoader": "text_encoders", "DualCLIPLoader": "text_encoders", "OnnxDetectionModelLoader": "detection",
              "LoraLoaderModelOnly": "loras", "WanVideoLoraSelect": "loras", "WanVideoLoraSelectMulti": "loras",
              "AudioEncoderLoader": "audio_encoders", "MelBandRoFormerModelLoader": "diffusion_models",
              "LTXVAudioVAELoader": "checkpoints"}
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
        if isinstance(wv, list) and n.get("type") in LOADER_DIR:
            for v in wv:
                if isinstance(v, str) and v.lower().endswith(EXT):
                    want.setdefault(os.path.join(M, LOADER_DIR[n["type"]], v), (None, os.path.basename(v)))
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
    if os.path.exists(dst) and os.path.getsize(dst) > 1_000_000: print("ok (exists)", os.path.relpath(dst, M)); continue
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
H4sICAR5vmoCA3dhbl9hbmltYXRlX3J1bnBvZC5qc29uAOw9a28jR3Lf91cICpAPvtW4n9M9hmGA
u6I3irXSYqW1HQQBMSSbEm8pUiFH2pWdAxxcLoYvgPMGghh5+JBkDwgSBEmAGE7s+zGJvOt/kR6S
M5yZ7p7pGZIi1xRgY8V+TXV1VVd1dXXVx3e2tnv+KGj0uv2njW57+60t7Lp3ZWl/0BYj+fO372xt
fSz/39oeXATnF0FUNi2V5X3/TMjC7b2HtQf17bvT0nDAWdutLQTx5K/fiVv4TdFTOwZX54nhxoU/
uRP3224NeoNhWP9ryMcubk76bT/rtk9EMGpc+r0LMfvu9lB0xFD0W6LRPfNPxHZipG4/ms60oNPz
T8LfH/9k8juC5IEIDiQ2pl86C/98awtMfjVPZgDhDoXUmzYbdT8SMRgITppvUZ4A4HwwA5RD6DkU
YQ9RxiGik+Y72KXAQYRxgBgmmNEk/OFqQYangw0H52IYdMeTnyzN9oVoaIojZDVkdWvQ74tW4Dd7
YjbxCDdhg4u+qcmlGI66g344c+bg6UJNKgs/sO1fPJ9QWxq5W9vh31shRW11BsOto19/nGxzJ/7E
9mDYFiHWwZ1pkSWNHhybKRS7RgpNdIvpU5blUCdsEtf1Cqjz+3/+q+uv/8mOKCc95Ad6/vlIhLgL
hhcigZKy5Io81/NaueSKiYFcGeSugzziIchZTKzE8xyIgQslIeuJlWw0scJFEiu9aWK9/tdvfkjE
6oIiYqUbTaxoccSKoXe7s1oSKyWcOohNpP2UViGTGytB1KWe/NPlOmJ114FY4aqIFZck1nxVdbI4
N62qXn/x7cvPPr3++d+/+uabFRGuhQZbdpd1x7ssZhB42k2WbfQmS8rR7f39vUeN9/eO9g4Pcg5a
yES9uu4RiWiHHrT8nqSCdkMHQB69I1RA7K1e97xx2Q2XoHHqjPyOCER/NBiO9JSfwsZkzBlBzPAz
HnX8Y1ITr7baQEGOWhWj5vDhvcMcpGS+mkSJ6UgZ4vH98ez3B35ICkWcCQCoerBE2oMlJUUHS27m
zFZ/OKX/1uCsc7XTGgxjFrgcE/Y2cLATbSXrKIKmfWdrN9s8485ablaWTsPWtBxbf1A7eL+WI4+o
UR5lekbkNS3O4VBcyKHRADcvhSjG1USQS6nUnTxEOCDuTAghQMfqEzVKIQ42WntyF6k9YYCqaE/m
7XUh2tXE8DA+gRdIl+izE3thcpbhoQgQZVbphrazmpkjowUvFm9NP2idNrr9tnhuEnDJJgrsVIFd
1zx5DDPDr8BiPYue6J8Ep6YJTGsV2F0F9kxLO7CTH9cKauvdbC9cwHeHg7N7ISYWoVpzZJLh4ZmQ
eBBNtq9oW3MxczgDLqBEeybkcG4JzmhlCR4t+xTjEzzejUqT5JOQvFtLV+HvmKEyAZWrDujIQBJJ
cNA8OZQADrvt5GdNFCGrToaDi/NkLePebFtRdrsZBWeNjMBboJkR3LxN/JPP/u+rf7n+6sV3f/lv
r6H9hhOm5VVWwKtoo8/BrBzJ1p7s7h3maCDGq8Z0x4guJqXz2m++/7v/+P4Xf/rq2z+//vTr19B+
YxAylBcQ7gbdP65+c+fl+OTd/cNajlkeGM+V6Y4RGU5K8/gEF50q5b7+8vNPV8UeFFflDU/LG0UK
2GZfd5bUQ8YnooY4a4r2yKyQIOO9p7Z/0iKytzs+lDVCC0794b367lHR+SwabR5TJ7yb/Ge73R2F
CG9HSPXlWs3OjzNtdEqSwKH2R9aEUVU5QEGkt3hmmpczBydH0B0C08iEKlDYsIqw2nm6AbVgjE79
8SDsrhYutG2AAlWEApWDoi9O/KB7GbkoKcAY6m1hynQvd1gfBcPxSSnCrHpgT7RQINfUpWWJGers
h8tDjAohRjkQo+oQo5IQt6QcMF5YhHUq5yZLra8p4s/YQzY4a3b76W1QA2O6lQqtvt4abg0Q1jOQ
kqolGoNOpzfw26YJpBsp8OurI/DvHR7u12t5u6QGBmv4g25PKIg37iST1soE0sV2hrLEh62BHcp9
ZmAN7KS1Amy62Jb5Ep+2uX/7wO+/L5X3wX0pwCaXOXWpTFmokIZ7OAyhA1nyhg25RmsedsMbOUBB
2tOz6EKOezbmvPuhOe/J3k40ww+G/vl5dMEY2/ZQs93m0IegCXALEkJwi3nNdgc3GcdN2BFN3IYd
H6/9/V1CTKRteRP6TZdldpJ0ZWL7Tlek2TczYrinposmlGhrPjQSou5W0St/rbi3Wz88rn94nNV3
FZcXkHfFaBglrVynmsxrTAk1y9fWlCIPhOE9JKAo5caFACy4h/TArTHlJi3l1fjp4eFufT/nhMqL
WCk9QJaLJrXzMtB3v/zy+m//6IfHQkVX+R68ZaEbZKGMS3uaGIoY6o0cj2HjvdMbCuO8oTJLaadb
pjrdeq7Z6dZo3nzxq+uf/2qhXDcla5THg5vgt7IGxL5Il3gE7sZ/wpu+Y3315T9ef/Xi+k8+f/nX
f/DdJ//92l626p3lcZGzvLfZb+YgXqh7Ija/7Lx1T0zrNJw4DFKOAJ4d/BHE1KEAuZwarpE8stHe
iZBUUdPNVz0K+ZJ8fd04UsHd0rwa/KsXf/jqxWfrq8E7Ug3ndHYfWkq7slDk6a0if4O6DV2oDzCk
r81j/7U69upZpdBstNmP/+BC/dcRIbFm7q7kIWBSO7/+4tvrn/5xVUru+L3Rkkk57+ERdDzuMeKm
nGYYZA7S0PBmPwSEbIFOuyRy9N9C1Iv/ZOD1ihgwL/FaHCxLE68XEi/xWKT5qGTMN5uM+SLJ2I1p
1wUzMoavVyyBdSRjXkjG3maTsbfI4Bf8NlLLPPY8TgrseQhs9vNNBJZ1CcNWfwkDyl/CvPryl9/9
9GeLv4SRB7HbS5hVGyoQXOhhz3zPuKzHykWWbTLvE2W4yifK/tngoh+YHC2ntQrE6sPkTEs7n8Xk
xy0f95q0s8fiXPjB+HGn3fve6gE6XCx1NOVtiYfyVTQE8Nyve1137te9U5Sv4gmv+ulcTztlRXXP
q0rejIXk0Ms5wODZOdwoStNjRPT36PConvEzUsh90nOuMDyX3UDSotjp7Tw7HfREc9C+ciSyo2AA
21dyrEsIzlKF95/s1urPResikEv3aDi47EZhUKrG7ZmC0UjMSN080o0UPOqrbZ3MNRBY73khkvJB
T7RQ4NbU2QKd/bA1xOFqNtristsyRkpKNlFg1lXaAq1828Zf+1B22hWB3AQkyT0MZzxn3CSMHM4p
JpRQ7nGC+fSV1uS9u/1RGgOqM2dGcULsnbVrfSluA/FoKGSXlhiNMvu1ILTtdzoQ+QDzZlNInZhJ
RQlT3mQdt+03wytkiN2b99guuW2nOS3tO50g6HRFkmg0G/5MmX3a/bHffdMGr1ohYaQznSaKFvoY
F+Ebf4w7OShd/8/Xq7MWVH6SqzUVuKzQVLAWt8psZaYCvED7rLfWIYhXYW7lPFTlUwEwAdHLB3ez
6bCkT4/yyE45xxuNrNmu2Xd7c4f9+JtfXP/sv/73k9+//of/fPnFX7x68WevPvv3Nc4zoFdj4FiN
AYgQSICrI1i2OQS7BlYuusB9GtLXyL94Fdu21gKDQaEFhm/2Hr5YtxvKb/PD5NAoZjoaLd62vc2m
0ZJuNYdPjh89yXNJMJrxMj1n12JmS8i0yzwGvOj0ZXdfcHjQOH78pK7a39XgmtmmVvOZ9smLBCPb
vFvbP9LAwHQwpNtaAjHpVDK06mDQE37fGFZ1Wq1AzdWQqpmm9nEiUjDYWMX2/Y+ujp51g9YpfOZf
zX1FwUoKSKg/2kBgfTFx0W30ThqBnHfW3AUd4qCbt2WxcrasaMVs7yAyC6aLmbXIHEHeWie0WpMD
OsR6KoabLThLOvJNAl9dDHsjUzCtVF206EfHj/cOHhQG1Br3LQwwZvr0qNrNd+WwbyUu70eqRPGW
PQkTAz4aisuueLY38xWocq8CHSb5k3LiJQ0MyJO0jAnBLsBSCU5rqqksMtTVZZFBuVlkouB2c92F
w/W9OcmVKeqyrdRyweYLUboGdx6WlzfjGyAyH+Dl71WOln2v4kIXO5lkMYhj7jBKIAXY0x4z4Tqa
Qs5DzhhcjA6ma7hdXooeWUjRo5zEGu5in66+Lg9Tq77LHfMUXfZ0TQLwaG47DubUoRCymewyq6IE
6KLAYTyOAme0OcIce46J3l8Hh/0yjLYGYbgrRo7SRWJb7zhrVQLLjbnYXdYElygzzXwtz4iEuaHe
WiA+PTDO4w0JT/glYOTmczUCt1y9BqpryUu3kX92ngysOuoNgjh7DDCHWjTmx8oOGNv5asf1XMfn
qGPeEbkt+oOu5JNG9ivx540trOFQRpjLET4VOD2Wpy7lzEM89Nuj08Ltod9vD85Cjs2GUd9un5/9
6EeNUUxgIB2OPSK78dkw3WRn2iZ2EbfbHFWf4DGHc0vHX0OQwVzn37vl4umP4fGqx8+vEjvfMhR6
IJ4HJpAxUAMba5rnyJKcaMeJgUoBbGSmpfCyEYyOCPyGPzzRAKJWxYfS+nGt9vhBHl5mnUuBIwXD
GKOD89CPUrOUUBMkXN8lvZz3Dw/C9cyNFp4epxzcfutUGPCoqYtdnmv3f6NegMlE93Ir2xs8E+1u
YFpdbXXC7PBBfXfvuGiVU4OUo//eiQEypSZWx/YfFMATdy0FSm8wODfAolbF7Hh4+KgAmlnnUuCI
51I3656JfuD3DGCZm0Tg1T98VH+891DuGLX9AjDVwcotZPfkzNctY7o8XsS9Bw9ruWs46VcKhot+
15+4azdCF3ENNMYWEVxPDvZqB1JMHdcb4ROaHACVocqxpS/xPLqSuH7a7Z8YUx/kN4vZtCbX9+i3
5Bq/t3fwoFi+6kcti2rcMoKtrU2gGN8vBjI1RinYzi56QTecnBE+Y4sIxodP9o/3QnwWw6mMVY4O
hkJ0++btWVsdr/vjen3voHh7Tg1SNhuKOB+ZE6GElZocKMliu6eXie/YZxfpnBhTisgqVQInCm3z
QsTfsMfYabdjfMA6qVQxliq2Thgz+5I9dEIY05iM61TYkqWWixl/ZGPyrIykdta+6E1f+uiQGzdQ
MaxU2b6Fy3zVPtFKt9MTzxtyY/jd/HTQakM134qxiR2xGGCxnsvUZtCI8m9Y549ROpoMGmoLWw7V
w1YuX7ccTrPRGWeV7KNP152pLOFflgXHnt4G56LRueiPn8XZJ/hJ9VIJT1ttyzoakEoIRX8YNEKR
ZT2XRBeNvFTqbIVmGg7rCYh+uxz4cQf1DJKtsQM9DYF9eIi2HGLMUsEgbSS0mIS2sxo5Iq+VPbOY
IS2TX+po3LH6M2WXORwkg+x6wJRWykXjjBkQwNk1xQ4CPHwRSTB09f7hCC0uqZSgouMxinwmOHGb
CKNOC9BO2/MwRsxHgjPgM87XPqmUdu3TD5IVyZBJJiWEkipK7rqZRmP9L10W81UmqZQiZLPJq0L1
O1MWKxfZtvGuk65IyofM51ObbXF6LPu8VykGWentj1fyaazfvwpO5fE750WL8d2V0tfGsz3uNOed
L75b4emAdrZjUy5ayuysz5Ch/7VkiUD0R93gyniezDTT5MLVN7CThloorOdw0c87NE1rNTaaisek
5Ofmu1h/KM4Gw6v74eQtZJzF8yduFG6UAocrGbihx6HDMHdJ9J5VFXA5YZKqOVxqZr3ajcub6x3e
2ryys3w0ON508Hzgr8KHpNj1kmGi8X2mZOz77EKKtHlBIyfUNXUegTfiPKLz5vAW+jwVzgJpY7y8
mIH6q3yJtaR9I4JNBSDd0E54Tfrkff5UdE9OA5vvZ1raATDtlAfBmT96qrkGSJbGQql29F6euT/s
M49bCo80HsKnDC0B6rc+GsRP2BLZubfB3a3wv1hMxDU8anx+EVW+HQzfeTtov3M4ptS3tt5+U/4I
C95uvgPffrP5ztbzLfknQ2D2AyIOtn5vCwKH0of3wvJJrzflWFIiyvMgFa2W4Ihw3xWMEN5sc9zx
OBGgxDasjzSJlx9p0nxJtAyKsNXYEiyjKmwqs45xRZfMrGZok/ylgqth7jG87tKZO0cjPh/JcUTj
TASnA7NmnG6lasj6elsLow4I6xk8FeJ8LGIHQ53N1NRMmYOpge0ktHBYz+LcbzcmW6MB/lkDBXK1
yvrRX+az9odBOc/wMr+bh/J0I/UgqK22RbcGAvuLkO5ld9SV6lCjaTzHptqo9x26Wjs2VT9e4gJH
F0cy59pGH1OyYjjJwkiS9jF/x0/oHotQa3/vNy/R3O/psQuMmj4mDuCUZN85MuTkRZxBtMTT+p2n
P+5L2LMv64nLO60WdzugiTzBPJ9TCKSCgD3RhJRB0nYZYf78oYEnoiplLIzFwULiBZe06qZ5M23E
nO04GTNvki3SVZrpKbttujYjULIG5URwy6hQxVauZUJLwCu1TdCSr0EV69UaRnGzDlA3VqPY/FNZ
T2uFiwB15H6B+PhJaHTh5LqugzHgEOizmUYvgzb6qejqGdPld+bKAbzKDL+2SYrH/MfnBXl53Fc5
kTBnSPd21J28HeUAMYOlkN1aCnW8UNJSOA5f3fYD32wtHA+pNRGqnZMh/3drx7W8g1HcOc9Y1vEj
Q/sox55pjGSm625ryEn2zQPxqbhqdIbyRyNMOSC1sm4/GNkYGPM7Wp8w9cPkQdxsDp7r3E0y5bEw
v3f4YZ4r1qRX4SqavqqrTH76btEapQCY3xA67/M4gpeUF+Numdg7hCwl9o6lRXMoAn8YbnkZY2vs
L6evtwUp033pBk/ymhk8yTIMnjZhl+SeXuu335VcGWceqGx6oNiJFQLIjbksMGUOpxMFfRbjBTkU
M05MofMxXXBKC0KamFLkMs8TkPkC+03XZ0D4ou1BwUmrSYjrsfbap7TQmQJKHt21VKDTVUrGB3zD
RqhaZfMrncS6KAmfBbxjvmTV4K1gADy6kUC+nDopxqMedAhj8cW/ynjurdq+Bm42bKH+BGTmT0Ar
+ROsKsv8SoJfc9cByMVuIrLSThhQxeEuJ4AjgKHGuRmzzY7hWfJcW5DNjs5ycFN0m83uNpvdbTa7
dclmF+YGoB51Sfjeg0fH2Jxkdph6Ttp6iDAJY1yFKbT02j9fsPbPSIdj0vRES7SA8DqEU0z9JhIt
jyLodSjiHEDur30Q8GUktJs7OR0GFWyaQzG66AU5RkMP5Zo1s/0jej/Yf/fR4/pukWEz6r4iM1w1
obMD57Z92YaGkmhcnunLuwHTV46jkRg2mnFWXhs3klkPlRaVKjvLTQYIm508pOyhaHdbwYL37rxc
DNzxXDrVeWPrDQQO4RxxrR7sLe6RH/FDM41HuU/bEgwgmkTgFhJNyKj8t81atMlYy137bXu22rb7
b2KxdZaZktED28+yQW6U3ZaYdlulb0SPux+EqnZeMJG461KD2xu02+lmQ0FJfdfm/FCs8xZsgRTe
WOR9e5NUaBeMZf773SD8fTyQyyz/XfCWQ4zaokuw41KCvKTZymWuQxCUR3OmtVqRMmlgdkYtv9vb
OY9nFe83HgbU64COIMLHnMMWaLuhwogRE3IHQoBKwNgqjMTVz/XpJMVH92t7+zuPElM3WoiNlKDb
j8hC7VUU3qZny0shSImDoYdx4q3+DqKMOi4mUZpilUc2O8kMhgsXmfiHKjLRWopMvLJkNeshF7nD
PMZpKuQGoczxAAHU5IZF0K1kXKlkLBnpQc39YrhHXVrSmuuvXrz8/NPlSr+ChDE5os/1HDw5eca2
RMQdylzJBUhvTSR4swUfqpBdrXSgeWA8P64kLdosmPo0JxhDmT9gbLmOwqVvt0XHv+gFJTwILn31
oSpVHbuSzTIuwDkC0xe5YlIJShV9n95MfPC8iGEhMcvVEI2g24vjrKg3JWpDTcgwUxP7ICQGeKzn
IzuJhjHs4bRWjRefLrczCyY/VQ6+q1z4rgzwXVWB76oKfKMgdKMoQGPcSA+tUl0C6PT3K8F+ZQP7
VT7sV3PAXhbv/cHwLBzOLxVJMd1LmYy+2vYKUwPSnEaryIK8K1o2qkfRO0rocWNYIMIcThBKq+CQ
Q+641IWIeSYFxL2Ne6eYxKc7SfqmMk0e6brp1qgpjNnDXPdcCX2XFQllg8kl6W2lvmIQlLwMkAPn
vCbhxrcaqX7pVBn7h49ruVkNhv583jb9QT9OquNMDQHJQjhnUUJVtEzBY74sHIrLRhrH8WWhUlUK
jbPupXz9m3Kkp7pr7HR57Jha36/fP67v3ts/vP9enqlq2r+cTArBbwCTIJ3WakkvUW4rbZIfKxGw
dxJl0wxlooWifLuaiL1Ka+ug7RlQymEZ5mIZGrAMq2EZVsUyLMQy3DbjFFbHKayCU5SLU2TAKaqG
U1QVp6gQpygHp6g6TlEVnOJcnGIDTnE1nOKqOMWFOMU5OMXVcYqr4JTk4pQYcEqq4ZRUxSkpxCnJ
wSmpjlNSGqfPGmfirKGLnZqTIyrRSYNwTa29TUOFyHoyZ2J4IsZ6hH049GQf1YNMU2k/EwWcMjHP
92W3I9GTx4uHYWqdqsc/TOJn8KaosBxi5gDiRdHNp8e/8OrFYZ45Wznhizv8NdH/s3c9vY3k2P2r
GD4ljXEtyeLfOQRwd7t7nHHbhu3u2T0VSlKprW1bciR53J7TXjbB7p72kCDIIYMJkt0FggQb5DLZ
INgvMz3I3PIRwiqpSsUiWSKr5Ja6V4MBxiM+sh5Z9R7J9+f3urzbF1T0u30KUkcMx0mMukjEfchY
nMA+4h0kNv7yVzrYVPHCi93Z0oBtDcjWEFYa5ucVw4/I9KOxO9Z+LImj2lT+vg0jAe+bZ/WbN3md
2MpQBjYYVQBvUQW2qAJtzAoEzp1B8o+2kdWEbQKqAOFbVIGVoQoQ8WGhClDwJ4QqgHmgBomGgJAg
pDbkciy2iALrRxRAraJh1hr74hiukwkiasfyA4LwkYYwYJShMKCUC0xKqSBSCnnAgeAQz37XxI7A
TcYTCNcFAwahZ770/sunhycux0uVMP8+Zr+2Bq78+j9/+Kdfe+Ns6LxnQhK2432tSJUEWL3EAgaQ
YQ7KuBtyW5LSgwWkwoK7QdAWd2MDfKnQF3jj2LA9lX8sn7hqxA92MKVi2e707//z7g+/8Sloc2zY
m3Bzfh8Q5kYe5YToNosKpZTCAFCu5EOERJ4QOaTUapkj4VbkTDKA4AbLwA//+vcrkAHyEcoAxmU7
dCEFIQxQCAroZF0KthWdzFKANlkKfvaL7779N3lb+f5vf99WFuhHKAuCBYJgtTyt3BBgQBAn1HpX
Idu7ilEUPPE9JqPbtExr/2byf19//TuDB9fc7uzFVbvXxsjPSTM7eXd0O5zWc2Shc6ywbR7Egb/e
7TiLeKxlzkjkuWbKGA6MZaahWq50Cq/FWnR34GZmlKplx0DixU+pfx1DqZtPdp59gr+pgeZG9mBK
4wiu77PS3YVX5bOs45ku49kykttCWwZxmEHp4/3Nro05I5HnqipjODCWf8R1i4qXLKo+htdyLro7
8Ft85HUMkyUMGwbx4rjUv7FZKndELM127iWjaDDsj/TTDzOkOmvU+cRefXYevTp8enByePysHhKv
GGIVZ6bssemQhwVTzaxXiAREMLo4FCEraltq6g1CQaplH0AG5oyQrQQyoT75xtlCXSZXknRyO5hW
s45pwvo0Bf0gHHc6sN/BAuNeSCFDskVwHNJeLGK4+Ycx45nL8F7XbP3yLNQyvOpHS4A8MbfpEb2z
B/bYonO7tAI5zFV0nYbRRCAIAxRMR+Pu5aQ7HtzkXlO32vU14XZ18JYWZMtmoJZN8Czv4vH17Y1z
HOCcXPeLq7+7R/+Vn+/ia346ustKyu8PeykgYfqpLNZqZTAM1trwnDMSCCiUUnpIhCKgFGBgNTXy
LSia7neevfpK3brxlbPX2fYtmJLgwwYBcUsC0EJSX3inYeBNue9qa0dDmucsqv9103D1sYLZYUq8
z1jBlYb6MPBhhfowuMaKyUUc1k3c69Wk92t09oCwKoUb92ZGnOeRBU5OpoPum6j2k9Ho9BBKG4Xb
PMyMuH9B8bDnMg+NTv+GbBSOX5OREffivuP4Tt4LY2sR7gWBDrmlNbmfQSrPdTqGyC6vBhetEKCK
lHM7/qoIYQCqtfcQ4/IeB3gIZj/rp41Vh7rBOCQdDmMMeafTiUEKPUfjHhQd+W8fxYzGCPdx0rqM
7+JNVEr5apJeaTfX/61+jnX1gYtfNWFcSf1gz5g8y0IsWQdzKF/tKhgXoXYN6o9kJbkwHMO4p1Nt
lhZ9cFK5Dpara+rNak513to29un7333z7h9/5R37ZJlBvo2j1c5pPXWIKAhgWMLkqoHvEmGAgZhX
/cqNSqG8PslfaAgspcgp2DrmNgFowhPl9eTlxenLC7ttiFmhJio9F5W37Jv4vEtLMfe7Cp0cRxdn
L/VCwEwPbaySOk1p3qfOpC9pnu0fnRt4wCYeVFpHJmadfM/Wo6skHtqP1LNmjWtiOFurpO7nOoWH
dqGjR/FX9+d3g2n3Et7F922UZX7TZHzFEaS0JtK6mX3aNOn1lkXzRLqZJm+nNerH6pNT+rkISdah
1oN9OUrPc1cG06ne5JwDuOja9nQjPoW0VR2qxQoY4NGU11C7yEunXFrpVgL95GznomCgXSw4BCsX
ZbRqUVamu1YZDj0PEYNhjQhzKwR3uZub8SLt0cbeGoI28pMNZq3fljUaYEXLP7vNsvQcFztHEk/u
d4q1bOJfWRqsB4EIOEWhKiNSMgIiiMAMZf5qXUawj6M5ncferQZrzbsxjbsJpYzADgsZZv044THp
0JB3YZfGtMdEjMHmw1obpV59e+sVe8+tu381imsEH9lz/5WOrpE/s15txB8GQP0HbYY6WDbzJgqh
tMYPohKAEAHIw3SLqlOEBJQie81wSrYawUkjlEVkrTqBrlQnELppOgEEqKIU8FYpND8n0IARhDEs
4y8hLFAgQmTNb6F0qxU+LK3gmYJpMiUpeiG0mhkfwLTkW55gM/TB8gk30QjK8j6MToAogGH18oAo
BwGU9+4cq01TCgxulYKTUlAlZK1qgTdxHT45Ob44+PGFzXVYbVbdbHlrqxDTPJhv57tvf/ndt7/6
/u/+5oef/eKHb/7L24eoTWVuMudwtZN7QB+iFfMHB2xetm6ZB5EjEkAShkpFWihQGEipJwQbbwYM
bWAFIJvj8qP1HzJP538tTn0INhKnfhFME42TqzSyIkN+jPo3kAaTuJ9Mk+FkNJ5UAOllNxSgvaO0
w3AwfB0dold7+xA/3sOTaXIz2csGOTr5YtlAz+LJVA4WXaBXkeweYQ5uZhyM4+GbSJ6So05/KSsw
Or2dxK9gdDQ628/GSXsTiFw6y3k8ux3OuD8cnkrW7/aGo8Ek2fvs9Fxu1/buDwvCn6tLtoXl/9OB
5d+C8G9B+Lcg/FsQ/i0I/xaEfwvCv9kg/AjCgDNOgCAIYo5DvhSTn4AwKOLgC0T+UF4RUYjEHP9F
vw7SLST/FpL/PUPyc08HeLlmrGMN3tCaa92yAG3zyzCKYCSfIq+tITJc/HbT++Tuym9/3dH1TVr8
Lx6/NmhKY2tpVeR2e3oo9eXZ87prljKKp+5Ps1RnA9Wlhc8ozLnhaptXgnjpwc4cyytudzDxqSK6
6GG6bleaXPmvsOHM/u1Ear2b26gbdy8T5ymovbRpmJvdt1wDU84Tkoq+k6fYuEwlp9cVQ6XBwyFU
ZsHntCDVQZqtne+kbRLnQmBPNKEBUNBABQi4PA6wefV4/VDAtkVatUNBSWGo++RCEn23ysXrNzl5
PFGxq4CGioWYQtt2aAM4tH/tS0Abl0eCqHbSyW1nOo6701Yh17Ft99CNnkL3EcWeK+CbhN+xpn4Y
TJ6++dKevKSiZSyCrRNovOlNrrtV5anObvPreHp52CLkdhGXbgN3EpCRgHHViSa1FJM6E80dcZqC
5GDVQenKbE1HZro6bYAA8dUGbUFav//Zf7/7+X/87zf/8t0f/vrdP//Du9//+t23vzVLfOM0huer
g1O1ln6QWxgJsICSsrSjIgaZvK4DCixOVw43wenaPDnzuYNz9bkdNRV7gqZWSiZpm5kVSbJZLSV7
CaXishBP3rgUnFDo8se/2D//vO4ikvZZSeUuLqh2fVwcVHZf39zuaj9O40H3cuARgJHChKVgNHq9
LYGMuGYqcQnX7PTs4OkSWLNZXy9XYu/Oxp6eiKrRFpAWX6SQPHVX3qKrZ1GwfjTvqfOHDZAwOrk7
i+XeDw4aJMiHBRok6BpBgzJEi7Rwn/OlddHDjPaiNHmivSwY8USniYe9id8MZl0sgDVKmy9izYIX
D+imodyeol7y5cDjTai9DCJranY9JhtYcndiycESz5dS7qP7tQyN7q9FY8f3vXTi7hv5l++LybvZ
3ky13fPVKFy5XGPOsn7pdrfYaVpcZJDdASQIDAgJmXo0JfJXzDG0Aopw5BP/K1/r4GqvtCPldh4R
AiL6oJ/gJPX8wC7o0aQLEnmTSkhPyDsHwfI+1WuNi7QcvqglPBFrAE+U6dDl+EMlXeVaY3BxCH8z
+Gk8+FFudTt/sn94tHdaehHGU3nl8zPdLD2TkOPh/fRSQbDTwhGt10utrwugQNGpVUZyE3hH41Sz
ZK3wQabmqiG7aRx6NBimDqTB9N529KmS6d4fC4Hb0cfIhbsfYmiKXai06o6GYcPwhPLjWkZ4v0iu
R+P7J+nsV2C4t8LrCsjDABBGIYPlyq4hDlhIeJhCfpvUOV61aUqdrxEMyTMf4dngKkn/Nhw69KYy
8vuzw6OD4/0XtdeexQjN9MV8rSbxl0k0m4iiq3f78/Hl9pX0B2+zSwCieOf+9kuMQI5cIhkb3cxq
Oiz81Ls3g7dR/zr9ZbdCnj3uOpnGGcbrp+Ur/G533M9Kz+RX9vHgOpqOovi2NxhVSDMQ+SyaPrkr
7VE38W3pmy42nUGvlwyrv97E4/h6dpJRNiL5RVzH0wLS/0fppPeub/Kgp93hKFo8uMzTrLzFOJ6m
rydcLMXw9c0oQ+2rCtoSrWwu9x0CtM5y37OXofFk2CcUQrWuZ81GkfXy4ij9mORxddq9NAVIaW1l
MXuctryIh3IZxrWBUsUoXpyVIzBqwzJcYzJc95zSl2jZd0oU2rvU7TMGaueE6gorHpF/hV6xRlQW
FIYgP63NtVKJ+lj3Na+oS9vCV8j0tbYQOKMlGRlxn8ZM+9m4n7XqTKu/u941yw9zj0vJFaqFx6Jd
D0Kptrgfq9SHutsqSpurLeK2RKKbJgyNHqaJ6tOd+S7tca5miVIX3Tyut7nPosqL3+IXR4265S+I
zC9Aa64y78eXeq6x4acpRDqQmrHZzJeD8aaoSiNv3Z3BsHFWJxEkkGd2jsisMm8ezWvP7YRYBADg
UK0xjxgBQQitbkaywoJDMGCBaG2tsR2jjQdppVk5QCst1bOy0lg9HauPzM+w6q/lA6rSUjqkrsCw
RAPkGYdsW7z6tbMuXd3K1S2ccd2sy2ZcNbfiT4qYrbn+k6dZ7JGLf/iRwTrUFq7y3W//+O6Xf/QG
436kH3BJM37XA7S9tPKtgFwEglIVXxumCpTIy6ItsoduS0BvgvR51ihSi4S55QiEwAqSZa45ZsGv
r6091iJdAM2z53+U5Q6gvfn/7qU56P0bHmUetl6U4OuwP4w+/8voS2NaQZolH/XjyXTxA887zYbI
G0b9FPeopzov5Z7xOomn0wL3pJf049srl3DNzc5JqE9GjyZ38Y2FQRtBcczM0tK/2D9dwmJ1HC8u
1YT+leI9uJpx5P4fXWdWoutkOLUsVi1Vcc4+238Rvdg/3n9+8OLg+GLJuhmH9GI9eTsdx5Gl4KCp
cWGRenJwun/xWQ135e5eTPXj4TSe3E/jqzcp7IWFu1qqwvq0Lxfx/CcX+0efHx4/X6avjEP62RrT
TK+0v41rG0HhU3l5dHGYsrtUt1YGarLCN6OxfEWD6ZIltpBV1vj05OzibP/wwnGRK4M2SJba2PKZ
nXiS3UfM2VEWKl25mttdGTcx4TyDv7qVL2nwVW14vEKjcW9sdeVdf7yHVXixb1vNwtWtvVLIumnQ
kvZsZ67lsULqbznbTBqcTWqVbrqLxdzuOh8TV+7BS9eTaChvy1FfHumnPlmCek89hMlK4hzFZGbP
J2ctqyvaNmsNBiD3YM9NYdBqCmMkDDCkswT2cmI7EYRlWRv6LW6bwKZbkyrfdSUNPFP4VTPSQrAr
NdFULas2KmrMNyWu/HWZMglgm3uhfgPkG3gDdLPf6DPLbDj0AWfS6GaSM8YeHJtumeI6T6Yphlvz
GEw0NyVgag3B5DygAGOlJHbIURhQCjklyGJ0Elt15RiMpL1MU2kktEolgRj62JQEX7+SsBpZch7F
eza7tDNolz7Lx+nw53L0h9MzAkAQIMWuLRgPMMOchMQM9CPAVsf465jFyzTpGc+wx7ryTWHuz0j/
hIs/0fsr6uTgbPooyjo5JxQ7F3xyKHFYg9tOpSyzagZ6FueLKOXYdscRaIvb/gEVfcKoQQ50lFx3
kt6kpvYTq02FrvZXN/YsDjY6ePH44On5snDYfKQ2Xi35ic83Np7DMswLdZbujwjnwCC9wSR9yT0V
GBl4wWIZQ07nRwwYrhobzPHs070a3JjebMYUNmRp6OSmF/nk6PB06cssD+adumyJvIbEmLncMPq6
1NWLwTQnzcqhfi02kbuyWO7r6YDo2nlkBkdEtzGP5b5+J/PXGofFCfx1U24WPf38SgruwopQFhyf
PZnG42lUfI0m3FczgeuaVPs/dI5+CPkHlaMfQrHGHP3h7XWURbhNbFyXKKqcI6DH+urUbtxXGfEJ
WZcqYB7UURO5XiIyBbAbmt2DlA08eGZr3A2GvdFdlJ2qa5M2yoTa+4CW3A1TJ7fXYuHOPYczPTdd
L5JnDOmbCwpDjIzW5uoCqj7YPcEg3fVy2FprloFCVH0PGJv3Ya2DaxqNgSf37yvdIZfNRyXSvqvQ
vGc3no+BJ/f4+UEaDlacRh1cjoseeiC91uQu9BVGfGz08xi3g9Jpt4EBTdBAQM4oQoCVLtWYyis1
ooxRmFVJE5YrOaGcBIgzIhgt+Rzl/VwEGC0gFvQrOVmdjU0y2YE9KGBCQI9wgSlJQtjrgh4G/T7r
EtGRN/YOeBg8hdKm84BIC54OTFXYK9HrxTe3HIXBNrmyatTi30vbWKVNEVlTiHx5k3CFfag1TBqk
ZL3VrDy9svXFa+UusS1o/THXrpWCT5CGuIlpwIHgcF7qWleubGvv/KCK12LPGP5MVUd1ThLEhE0z
6J09LrPRwJLWrN4g63njwMabobfPxTVageNm94t0nlJTU77zyc5n2bif7sCQUY+UIR2Ws4QftVoY
zhX4bdLRzot7XbskI2HzxFIiYAAZ5krR3ZCSMKBYQCpmkSA6wjp+EADhyqTXeyjwrF09Td7WSX5o
ky6lnwvoUtahTtonl/K0libGGmx+WpMz/sCia1tZhvRT0QotfbEChgRr5TXULvLSKZdWupVAPznb
uSgYaCfJM6yiVYoyFasWZWW6693CPZNgl9afZ2Q99eddxCre+Yudjsd2qJcWYMKhtMAj78IChmoB
+d4LHOoHPFph9YA0qy4eDyb2/IgShTGzr9LmbrVUH7yCE8JsyGQV0R1s5UqFP8j5QJnyWjULr1Q3
UZe/IUD8ugDhH8QxWZTOGA9eD4bxVcWzUdTkMDYvtOeP66pyKH3rmNAdiqrFhtXey1bmYKxxGKr8
8Pq7WBsHYklWFWUQAinTXAoLgJhinrs6QqUwUyEg49ed+M9C/skOCz/ZgZB+sgMC9ue7q9Agtv2t
ezuZjq7VaBpYQAyOFsiF8bD71aiwKxZRnPIAO54mRR45BGg+xcwalBqEWqSEm++WjD64RK8z9qAm
M25yIxV7lNXMsZY2KtNoK6dHkxjpnZPiNIY8CuaN0qzXwSjVNLVhCwZKQ8U8K42bMNvYaTaf+sAG
E2n9jBrpJytHHih9dmy7gQnYbtAA1W4w9S4MPL0cWUMX5q0mcMvy784pz6WHuad7jm6HvRQ1KctL
v7mymvV1Qj1mzkrinN1p5sazhIDsPxn0rDNRiSxVA6rNrjMwcODP/VWtR79KpmlObp/TldmrXy+d
Rr48suq7b17PXuzs8GDNq6/QGTLrLRTO9hwzL82uYvN7DlMvZkfxfTJ+OR1cDab3n+4cZubMdPke
3+9nG9BZuv/svMrddau7Hjk/2Ih/jdpcZk5eXpy+rKndiK1Oj0pPlwv/vEvthaMCulnlh1gdHRZE
zjp+FBhO29G6uGdDa5Y4pYAGTBBeTirfCwnlASIChHNv4/Jjsl+FgJPj6OLs5YEe6KSHRFdJnd7W
vE/t6xpGKc86C/rZuUrq9ILmfepYkGw+2z86NywDMy2DSuu4DrNOSxYiywrQueCmlVBpHZdi1slT
g5ftkwbFbbCZplwT+D5spJ4KO48hLinsr+7P7wbT7iW6i+8fQC0rwxuVL1tdFh5i/P3l2y0LOmHo
I023syXROufbtQg+QSxAoLJJIIwDQiCBIWVGa6zA29CTDynVjqwwLxfTzdEIcB5kslUJq1QJIQso
5SrQdohDEGBGwDwEuKoS8mytrUr4QFQCXaVKINtDwsetEVAgRJjD9RR3SSxvmDAM5ScIjCqBblXC
h6QSWBujTU11clKgd1Dr2cHiwKo3g+SfIrLiwqCQB2HIOS2XjEME0ABRoYVVD91nmBU9xMun8Wh5
sPlMWJColkmVrzWvQWEUocvRePDVaDiNryr1xZZ+iWnk3Un2PrOwKl235J8EBW0+iZ+cHJ1EFagk
zXZmxXMx9M7XxjSwpmFLREv81BAEglMB5tYyvBRHnwJ5QMKglAnFMQs4YQKCKtiQzfl8L+USwrdZ
5djgZtoqfDGDm5pNvA4Ld0ZhhrpS27xQcUsPdvjMK/bt9C3pAJqmzz1PA+vzLhDdbtKFGPTiOIak
nyQd2sc9DpKQiT4HECC4+fvBohbBT297g3gIWV7LNsq+3WejcfQi9VtF50/TYrXR02SalFFOzTtK
dUVNmp63EevHJy+Pnx4eP4+UWBpNsK2q3th/YbkzDa59eArZEls5pwGmpRLQzC7YDAacCc4RL5cY
kvchzBmgepUhGypUELpvK6kiiMy4dETPJDBQe2nFUv8607EFkoOS91BSsi7YctiXx6JhN4mml+NE
bmNXPXvYpYHWEIBZQ+WaVGZny0EfYlUfPn48epu+yK0ibK0Ii6U0RVt6JmhWbn7aEdeajGG+Gz7y
vxn6WMVahJ1lQwFdEwnzzID/1IBvbVTZB+qaCJgZgv4MQU8tNKujY1E7s0aNW2iwjJQJXW0jxZMt
ejubENKfj8yrhaz3lZrhQ4sFJGwyGLYMhpsMRiyDkSaDUctgtMlgzDIYazIYtwzGmwwmLIOJJoNB
YBkNgkbDQdtwsNFwyDZcIzmANkGAjSQB2kQBNpIFaBMG2EgaoE0cYCN5gDaBgI0kAtpEAjaSCWgT
Ciha1v+rS7+Jh/fTy8Hw9WGq5Wc+/ub1JHLE5Kxqo9k0RkkgAFZQkxEXPIDyxkSRGdElRA+Th/P/
7F1bkxvHdX7Pr0DxJVUJOTV9n3lckStmw2uRMpM8oQbAYBfhLrABsLwklSrqbkqyZNlRXJLMxFLi
slIVy1TsVKgL5T/DXS6fnJ+Qnhsw091n0NMAuUuHL1vY6dvpy3f6dvo7probbRvIMjvXRWdRIM2G
+Rhq0V6rfPhkHm0JQ6XNq51KvNnhTCWxVnoaXFd4hcRTawvwSqeczM4vfRK6YI8+e1cOOj0JMaoy
fGMiv3BOCPF9EViZsp2Y9FLKnJtyhxZ3Rr3b7cQXYMVH4DLHcN3ru9PaU7h5BH0jqgVZPwSslmqx
5STKY+KtWOYxGgyn2YnR1cHOzNba5u7mVHc0Vm9tfE+2K332W0/W1KPwvPVsOYeA5jIdsy31pO96
fDstZVIDUnDbqScuevvypavr7XPrf3P5Uv1eY57D0qaoIRLc85ngqHoLw4WHREALj7SL8cup/bEa
cKJGLT09uHt4qGNYZsyKYdmNXrn25RjhR/hyrNMZ3TKcJjJdJCVmw1PhPHXT9wRysVFLp1mKYXhD
oIXZ7eXVYi30Nld8RqeHYedynK4nXja709H4/4niLrWfreaGGszkycJvdj5Y6etibJQ/Wr6Mibdl
TVPevu0FJuazqFlx+hMdc7g9O0s1vZUo+uFXxZY4RNB0BeTQsNHKx2OOJ6eNuPTht7tJfP3MEvmG
U8BKTNtjwDRRw8dgaSuBb8CyUKBjnDqkuXxGp5dauElGs1/Lxa8AqoVC82nS3PqZKkLm3sTG1lpY
ANELwOYCiFsBhuMl5Xuj7BiQHXPLjgPZcbfsBJCdcMsuALIL3LILgexCt+xMp65qQLMMEZQhcswQ
Qxk6osV09qoGNMsQggdyxAeCAIIcEYIgiCBHjCAIJMgRJQiCCXLECYKAghyRgiGkYEekYAgp2BEp
GEIKdkQKhpCCHZGCIaRgR6RgCCnYESkYQgp2RAqGkIIdkYIhpGBHpGAIKdgRKQRCCnFECoGQQhyR
QiCkENcVGIQU4ogUAiGFOCKFQEghjkghEFKII1IIhBTiiBQCIYU4IoVASCGOSKEQUqgjUiiEFOqI
FAohhToihUJIoa57E3Bz4ogUCiGFOiKFQkihjkihEFKoI1IohBTqiBQKIYU6IoVBSGGOSGEQUpgj
UhiEFOaIFAYhhTkihUFIYa77eHAj74gUBiGFOSKFQUhhjkhhEFKYI1IYhBTmiBQOIYU7IoVDSOGO
SOEQUrgjUjiEFO6IFA4hhTsihUNI4a5nXuChlyNSOIQU7ogUDiGFOyKFQ0jhjkgREFKEI1IEhBTh
iBQBIUU4IkVASBGOSBEQUoQjUgSEFOGIFAEhRbieD4MHxI5IERBShCNSBIQU4YiUAEJK4IiUAEJK
4IiUAEJK4IiUAEJK4IiUAEJK4IiUAEJKUIcUC89VGzu7UXe6pBXpzLRHcAxyAyDukVCENKNdLrgB
fBF6nDAa5jTNOoUQWbUhqV7lo3X30tCEoLM96l5vT25Gu+1ovFlj9eWD9IdQFrML0fOXTp+7+ldr
l9eunK3zia7ms8yVOlb92c9/ld6s+ycd7t9rbHqSCkxS2lRZCdCupxrL3Jx6uKV9j0EE68vw3LFi
e7CzmfimhyqgRtNZ/YAI9jfkRkka12N6a2pTjyIaWA81QvN6VCSxrsfeJG4PR8N22qmD4aa1Q1kt
oVY1MIZ93czSWVfuRuKvsx4xNa/z9LQGE0c4ki1bDiBiA47yuB8nFmNZLtYVVNMZyMrNEWyJyg1i
2ZsuzvV0L+7s2Q9LLWHdVFKN0YBi0yhdE+fHLyU5XJ0NF4cVDEYerb5xwT60lGEMYw+FNMC0vJRB
JMQe5jygTPhGR5xBsDovxzGL+6FgOBJxQHkHE9zv+qzfC0NCsIhwHAg/EkHw7C00m/omVkZ21c+v
Oq2YQwtlXQ3VxlU12KQrDBlAgZoybeqLWBm0R7oGZQ3XoLIrExd17dFu8rp+UuPbEzTlhLKYYXvt
4rWNM6cvXXxl/a8XkCpU8llmDXpibziQPbXTnkyjYS8aFxQPqHiXXbimwTVL1KQR4mi8jE+XBBLj
lCdiO5rGQ4O9JRhjRi+89sp67Yyi5dCYYiNt9kl3K+7twe4btHjgQNBi2Hs4M4nSuCa5Y/MF9chj
gbVQwu1md5MIzXtiOq5xPqHEgnuhGt5M/rIIjeUfSc23DW/C1GiwQlEiNKtCRQp7LzDjOB6OBhOw
+ecRdI8wWpD90kkp134pH487I1jaIlhfoSsB9pJWSrRv12SWNTuzAZVnOY3e2IZAazc8qjBNlqin
s/F1qTzbubzXZp6oOoCH16kBE9zDjAeEzUmtTqEQEy8UARaIpmTeuotlvwkd581oeCOp4E3jMlUu
qz3mvAYthoOm4StLMU1/KqFzkKgBpQ4FcizUARCcKzwltBjrpRVhy3k5TRq+U61tqtqWghoKbqf6
ZqptJVMjWS2bTUA62rVzQ4qoRa5+CUNH4uqXFIa+0Op46dPW1XEmW8w3C3iTTcQaleatUc6sMKNs
TJDsC98jTFTODTBGWKppggTJ+AR1fuTwBT+yFTtIFR9HqhRww3eh1cfUs5ehlc8LKI8beu3e//T7
x3ff3n/nF4cPHzZw3q1Imvt+w/5ysjenwrkaTy/OHvMt59qeUNA3Fg09TAMJ+JSut7i0FIx6CEHc
NxjVeD3ZHcc3BqO9ycUqWfQzhBtxZl2sNDn0djqPY7ro5MvQXOjjrsqsCPpWqxuH8PxhQys+U/gY
JBYPROB7gcg5xGeMFoGQH7EvGrhWqzlxmn8szqdOFvSyJx1cs5kJRVIiBvIMCERs94a9cXSznZDz
QCuKeQRNaj3IfmWhlNtM3q1o2JvUCpzFMEtcDWsocqnoZjL35bKhVuQ0glniSlBDgeflNpQ3jqf1
8iYRAHnLQU3lnZVr/5h9Ouher3ftXI6iP2k3BFq+vVdLtj+TSe5NUsTWkqGo0fSjGCCCnfxGKRp4
vB2NLbih1WgG/7bmCLaM0EY5GmqUOOrVK5QkAqBPykFN1cmsXAtGGmZipDkjszlXnT6eNzaalWxd
TK1hoppp6ImpoEqEL+cwaCCmpbUhSZ4lWnJn4rRoMdY23ZmIp1I769uNZEPaln0aDyeDKbhWUaPp
txtABMvbDZMU9lZNw+SWHRI9D9UNlqrfG5gplYpbbo94Id4ZjW+fTio/cxmy1E4xAM1bfamAkM/C
3PajOGwPCPZ8QQinmAnT4Q7GaNX2rYZaH+lZSNDQzyxw869qLwIek5ozMBsWLHuKUhxLtx49eOfR
g3cP/vntJ3fuPvnsa/OJivNIPvssTjt8xj0eIsWjIwp54AlBQz/z6qaNYFrj0fF5cCZx1uJYQ4lz
lCeLZAnGOfXUZDY5tggBHWw1p6czvkBoBiy/cqBxYrLXSVn4luLdjaApLNI9n+ucWlHDRoiaGmmC
5ueadMRAiNnU7LyphbbEcJS6UoFss2cRdKtsLcj2yl0pdRUeMHei6daGhRdMC02KfOjYT2DK5JaE
++VjY+z72CM4xFgOf/NNj7+Kmx7kkSX2QkXHR+qtdkf9MO+co7jojlRjTdU21CTd4iukyvA4UkUf
0qWukFRVDy+XVnpA7qTlkf0+z0xanHsbeJqkxYuIgWu9/ZSjANTALoymWsnWMm/Hw034zDEP1SRV
vtsJWS5qSQW+kfTOy+PRzkuRzXPFZTZ0AicbOtXvhdzPEc9HPvhckfhkyYMs4s1e9bsr77zNVQ1e
Gi7PVGUveI6pd+rRPshcxQrbfhldo0JRh/KC8ADcgR5+9sv9B7/a//H7jz954+DOt/L3wUf3m1zo
K+KnC8zAXXzIxMb2wl4CLgy7tagFDWwEDQKPk5Bnpo0z1ArqUcQREQZnzr0SSe+LK3vFjw5iK12E
wCfOR7gIocuuPgg6wtVHtDPaG4L3nXmoJrFhe1uNabnHLRW+5Nx+Jd6No2k6Gaxsdof1BENylxQg
QgUv7dCQYNwTIfMpyc/A9PmdHYf5PW/3I9l3aUXXzu7mbj3S+R35aLU7q/khGj1mm6wGWk13Q4BD
s1pDbnoNLXZGo5PnE98sA3aTAa9uG7K0kpI7CcKEjxmi6XIlX3JR+EwJUQ8x1T0Skqslj0l9hQMB
+OLz6VHqrGOwuzg+mocfe7Pg8nZi/9Pv91//YFnj4LmCXNY4+OmZANfsKBJPl5SxzHdgATpG5I5C
fiI8RNTnph2F/2JHYdxR+KvdUQTzGyx//pO6zMNLQ+dXbz35/MM6i/oFA/rssxjQmCSWCgEJK1tk
uQr2sPziyzWwMN9NHItrXvJMrnlN9650hfeuswu85KbxuNy72qn4TmkuLal4aj7WbmRilaWwVv/p
rH462Y38+SoQg+GFF6Yepyp1HaI4oa5DIQt0x7I5ZIIG13nteDKJh9OBXHRqF3rI85/T9ZfWSUd7
tLtSEAd/DMil6I8YuVTujQgVKPccO0MuCr1QQrc4/tEXb/QFcI8VcBFCz9WlTHIR8+ZXci/16Ju3
9v/9k/37H8pN1ZKXMgZL5ufnUgahgLPMgHBuDsO9UIjQZ1gYLQuJj1/soYzHCA33UCkLQ7zTiXs1
VF2ZFjVNZ6bkVWva9UuJMe36hZfWz9TxxZYzqjsMHMab0XRwI24bBS/Eqo3lJJ8xxzpB5TAfpAnk
kNvZNTwqgyJYu9dVM1iO3mxnyk7durV9Kh52T/V3g3ZMd0h/6E2ifpw8DRiNZzNYpz9zF3hirSXh
NBkNW1KU6WC42RoMJ3IGaEWt3Wh8Pe61utH4ZGu6FSc/WoNJS06Mu9syx+3brck0NcKKxrdPtuLh
5mAYt0b9/snWcNTaGd2Id+TEmf7TGw9uyKzzgCRJqy9rnOZ6I94adLfjk61O1L2ezCjDXksO+VSG
cbwTSXGycrppcilUtL0d3Ur/6cp2HEetyVZ0Pa6UKnOWOW1uSaluDMajYSbJpBtLCWUV+nvbqfSD
7cIn8onDu/91eP/1w7u/ffTg4R++e+/w928ffHpP/nhy7+ODO6/KH4+/fevwndcOvvjs8W/fefTg
RwcP3pQf93/9s/2vP0qi/dv7B7/4Tv549PDn+z9N4//Tt/J39uPJvc/zrH6d/Dj46HePHv50/4MP
H796P/n353f2/+fLw9998eTtD9Ic3p/9/svL62f333/38Xf/cfDlu48/+jgJfvDhk4/fffzJG0lK
+fG7b7LfciJ69PDjxEzg7rsH772dFbz//c+krPu/fJh9f/L6F/r3wzce5N8/erD/8PM859+8uv/l
13nODz+XTTALPXztcyl9Eict6PBffrT/4x/Oqpdk+84XMtqs2gf3Xnv09VdJwtffO/j4N2kV7h7c
++zwzd8nDZ1+fPTNN/vf/1BWISnuzk8e37tz+N/3Tz75z+/2H341Gzyyc5PxmY7HbBSdLEZPabjl
Y2L+IRkdafrxKOrNEs7HUdTtxtu5OaEc6HvjYRp7shvHPZmdHNQ7yejLUxbjZQ6wEzpJ4Obu3jIM
gVI/xUM5GygU4IXaMQerOvHylUsXLqeK8eKZ9SvtBWTf1TybXVInC4vtLCfgoroUQ6uNIczWgFgt
uAkPcHcwqbF3nkcwUf0qQbbiKqXaS2uaJQwyH9F0ZVuN2fxbXw01GrwycK2GURDravzdXiS3g39f
ay5fiaNVwBhqO4j04hvxl/cGk+vtbtTdArGqxDJSlRvCmxGVq2LYv4qW+4IawoIsVH8PXf1u29bl
wprQAb4item63Gb04tNJFXuuhIA0TOhFSBjiEMk/OVNUi2Imd1zpNTFETBJS7Mm9l09Cv8RswxPK
wBK3tU4OuEIOa8FRB/VQiGLm95iUiLOYoF7X71G/3xddFnZQR3T8Y89hXZplqo8QVD2iU0iXhnk1
cD4VKN8VDVsNzcdj9WNFITTl29NGqulupKGV4EAxSatSRoP70EFj+7TBcLkdU5jutI8B4d0itwfN
ye4GFm+gFvn7gYnukM89IUIRKMRZlHqIYB++MfFfUN1ZUd0NjsUbJfYc2LMsvJRvQHPHg6dGcwcZ
mz0LIxfOKfEowQgHldUAQ4GHfRqQ3FhAWw0w8eKA1nhbwVdp5DJnV5Sqd2Y5gAP89IxNzcedF9au
ntPRW/k6o96oRNXKSoPrLlloVxRedkFocxZFHRz6nR7r+n3e7SRG27TDep1OLEcsYnKeYVGPEU77
gQztCxldzjpBn8SRHOre3+7GBQlMyfbedbYvWe/rs73ycqD+ncCiXYfLO4G93VoSl12AxGXXSOKS
DpUfXD5/ae1MHevM1mg0kZgZbMet6ahVlsBmmXJext6Yt0/tOqVDCg/wVd3H/eKhX+BDyi9504ep
YCwo86QTEVBPKkO5ZDFb+OEwXNqsduaZ+vjubbKxpmxcsp603UrMO9K0hBArVZU8eNZKMaVSl423
Z/LTYgq0JLgrpawrPtrrDUY17UFAjq9KwkKotR+c2ahTPVmqOoFSbwDtwbBfJ5WApDKkLkS79hdX
2+m59cbFl+tELGXhtvcrMLw3mY522lvxYHNrOlM8smdG427cHkfTuPQxj5wRKs4/T+JtCal2LBF4
uz1Mg1CRTdrBqf+qbkqdX6RJ5U9XT/HNsqOsaK+0UiyqvzXo9eKh+jW5utjJdGoFnolzo2ia9vNQ
Ansanxn0+yfK5aaHWv1+L4pCSmIR9vv9Du0I1BeYd/qsy3gH9XrdmLKYdPpy4o19LHCf+12OMGWI
JoxXO7sz/onJ9cFuuz8YT0o+B6oNmevrE2cGk0T1FJNNMXukUpWmj8r0949utyc78TRqK+ZQs8sG
Paw8AFOzmAvRUEowrrt3mOdiwkqNn0TjkYC+RLi2tl57INDYI0za+dBRRRpoxmrzw/VSUfako3PM
QXyj8xjqri3QaYsNsS3VsiJIwxrUMqbOYwDyGnlSF7qtUQq2py4sqzSIt7AcRzMt1B+QGeNbchhq
4jStSa7J66uSR9Kor32oLkqCRpUpS9TA2VRl4gA9TlViaZjgwFpFS9FkuVIVyp6OV5skIEJeLaJO
yQtGsSRGNstiXxd1xoeqosbTawLFsKyIUZAm+ipZKlh73cqimxRX+XsDpTUrfckDtGTWTnYg1+az
lcM9mx96jCOq3LMRkEyREZK4jvArJo/UD5BHEPb1u7n8do2tmgzUUPsjNuRNPaP8SVrvxKZkHOUC
pKKei+PdjeE0Hu/EvUG2wi42ntkuoh3J9W6v3bktG2Jm0pvsnqtGvmlmF+QirBdNow1lC3vCx5R7
19avXN24dLHosWwsZH+TTs2y2R3cisajnehsUv1S9jdH4+v97dHNK6lJTDy+Nt9hn8/WPqkEmWvN
fC1f3jFIfZn4sRr2SgmRh0luLq4nLq/wT/RmwyJxgTtJAZwNu1Ny3DHPDygOBU4oO3OiBxKE3BMY
C4o4xn5QHnoTCb5UMC/kNBnjnDIJA7/oqaQHs/4vhvc/KHupIFjLQdMfFYTsCTFoDSd4QbgyHUy3
s7dvSQF5Lp3ExC/zqVugCYUerbK6UIlEb07pUlx8+8IjEpYh9+eHOSTA3AsJI37Z0rh67rBcbbBS
m6vTaDxt7Y4Hw2mrMx5B9QpQoldwccRU1AwRP3E7k1FM5RRpSFCpOgQiAS89/w4E8QJfCBKW+YWh
mpVR26ByRKnc6XEcTRMVc1vWpitHaet///Un9+G+I8hDuOoChfqMeapjHcypjOlXvqEQC4/ikhOe
p1FDqtRwYycz/WwlOE8sCuX+c9aZcoUA1jUxvMBCVOzcEZdjF1OCeKmTEaH5ijIMmcfCMJwdQD6N
CjIVbWfhIYmQFwahoGUEnSJYjslA6oWwzJiCJNI83w9E+d4I+RKYgnHlYdyKa8S1LpufFGuVEkgq
fKw84COCJgrEJzlvwsmCZiEZg5RRFoRlWgYh6yS/CoTSJ99Po05CqdP5ePqnk9bmqHVjMI62wR7D
YeARLjuopC9OYYkjj8jBRTjK2EaL3gmIVDmsbPcjSCBXN6Hwcdkn6IorFzRR+AKlhk2MBkFJdokl
P5CzW9n/KZPwkbsZZR4I5SCWjYGfJqbCJhUKGDc4Y00pYXmVcFsI4QWUFV2Rq0bZHMKXWqKgIphV
KF9JlY9Y0xJxzvohlzqllQ0KUOm/+el2uhTI02VF4krMIl0+a+dvjMqpeB4PG1JhKFU+b6LcqqxI
FZZlPH1+43L72ka6VlNSkzw1MaRGcA1R0TLlmNgni1om16LYL0tbpANbJtdU1fyLO/m8tD9T02Sa
ABNWljBPg4A0QV6OMJST90BheqmkzNoB5yOwSIkXtUd+LV1chBXpaF3NckhhXi0rqE3DDOOikBpK
k7d6ZWQVEkNp8lYPK7JhVJsmy1/OCZU0lbYr7O0vXDqzfl5NHxpKKdKjcvq0B9r5G6ZqJjnzhdSZ
hkxwVYjSQyglk3yUUWHIhJUzKflOKKfHhrpjTOpajxDTyMO1IyinGkCiKidbNFoLLAlmSAdqqJyp
Qa6+DakImCofSaLaq7y2Xjl+lXqJujQ0bz+/Ih2ptEXih8808mjejqEwpK3RnjSPEQaGdGCL5LMQ
quqKPBUFUwmDtiz6BGqTvB1ZVb6Ktrh4/mVjk+RgJMKQtKZJWBGzUiT1bbqBFbBDhrR1ZWJjmdiq
TGKqJ8ULy8yHTFDpjsoCI1URa1pCZtAGszGRJTy/9sq6NgBYrsY5ryQMyoMtc7KmpBMmYND/a+wM
etuGYSh838/oPYMtWpJ1bJdiGFo0Rbeh6ylok3bYpT1s1/33LQlfkOeQTI8B8kUWRZGPtK20d1kH
ibQZbGSdZm0M5dyNUTprYyjlboyiq6/2UfPmMFUVXfV6GPLgRx4z0DjYWmFQL5kY3VM5DOq6vmDw
KYdMpfkI/YIy/MzAhB+JV8vnMOCWZoRYrPyBX83Pv51P0NpZ7pFbrB41g0zcQyk3a1VdXBYEJVQ/
qqIxRTChS1WouWQwjk6F+5XRYEKdqs8+TvRmqacyv2ZUnsvefbTK2N6QmHDqIG0wuObaXteGFUMJ
Fa4GVDA9MY4dUVtVWuMabucxWRakKzUtOMI3aE71RM7Xe4x4qJ+p6lKVgjyocqyorxd3002mMjw1
OYxxlK+MIVsyREKiUnYjGW7vLudTUoy8C1IXbn6/iQhTud0GQyXsFygkUYYWg3QXo+nm6XuD8vIM
TuDgtkEaT4lt/A1CP4rBqV12j5pNOCiMweAGN9/LvmnBXCQURe0HhwPT3lm64UA8ds3E7QfPUXE0
GA/H8ToeXKPMOBq8Dn5xvfh09fX+/Hb7Zjfz6As0ctwWJXYckm8znuNJnwLKdTz0djj2UmVuSk0c
3dRzEd+yV1Bv2ktWPSw96pxi/FDyXb9HpZMMTgIOkrU3uCHgIFc7gxtd+6qbVmt2Xm6TBA0jlnE7
F+sjLLkYqltzKbMfDbRoFlLwiGWOc2sjR6h9JiebgjglW+gipTuVUnFa6XS84USVgT8b4Cvj0W0u
mTbJofzEuY7Tq4zEDA635G9hXH+kalhOwjYp/qZEemYiyYrz7qbjDCGTghm5Xq8NlsQNFrhvkMy0
w4JIgksMja61NKIIM73DVFK0QkxymJGYgRhxmGbMADowe+bL1hxAFZfS5aXuMH5jCKoL0UJYqOMm
3It8WFwvllY61opYqMUn6agRt7y6fLhdGJethqQGCf/amTluJi4Rp8t+nCO1RubJgRIY6fvN/MvN
5+XF4scUb0bZiwDq+GexTALG8U/UhCTfwbhZA60Rku/78O6MJMYcWEweM1b/FOnAY7LxLSxDEPRL
MbliaxG9Jbh7/+gpP6b1uq1nq/HleTakPs+eVt1qVv7Hp1zGbvX0uP1n07PV2+vLr5+4y3nwzlD3
cdjeYXz8/Wf5+rZ+3r3YtLuWs83TSfjeh7//ABy05GCewwIA
