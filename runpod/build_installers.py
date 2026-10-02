"""Builds install_reels_studio.sh and install_dashboard.sh from the sources in this folder."""
import base64
import gzip
import io
import os
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))


def wrap(data):
    s = base64.b64encode(data).decode()
    return "\n".join(s[i:i + 76] for i in range(0, len(s), 76)) + "\n"


def dashboard_tar():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        for f in ("__init__.py", "page/index.html"):
            t.add(os.path.join(HERE, "dashboard", f), arcname=f)
    return buf.getvalue()


FIND_COMFY = r'''COMFY="${COMFY_DIR:-}"
if [ -z "$COMFY" ]; then
  for d in /workspace/runpod-slim/ComfyUI /workspace/ComfyUI /ComfyUI /root/ComfyUI; do [ -f "$d/main.py" ] && COMFY="$d" && break; done
fi
'''

# The frontend's static folder is served live at "/", so /reels.html works without restarting ComfyUI.
COPY_STATIC = r'''copy_static_page(){
  local py=python3 p static
  for p in "$COMFY"/.venv*/bin/python "$COMFY"/venv/bin/python; do [ -x "$p" ] && py="$p" && break; done
  static=$("$py" -c "import comfyui_frontend_package as m, os; print(os.path.join(os.path.dirname(m.__file__), 'static'))" 2>/dev/null) || return 0
  [ -d "$static" ] && cp "$COMFY/custom_nodes/ComfyUI-ReelsStudio/page/index.html" "$static/reels.html" && echo "Dashboard also served at /reels.html (no restart needed)"
}
'''

DASH_HEADER = "#!/usr/bin/env bash\n# Installs the Reels Studio dashboard into ComfyUI. Open /reels.html right away, or /reels after a ComfyUI restart.\nset -uo pipefail\n" + FIND_COMFY + r'''[ -n "$COMFY" ] || { echo "ComfyUI not found. Run with COMFY_DIR=/path/to/ComfyUI"; exit 1; }
DEST="$COMFY/custom_nodes/ComfyUI-ReelsStudio"
mkdir -p "$DEST"
sed -n '/^__PAYLOAD__$/,$p' "$0" | tail -n +2 | base64 -d | tar -xz -C "$DEST" || { echo "Unpacking failed"; exit 1; }
echo "Reels Studio installed in $DEST"
''' + COPY_STATIC + r'''copy_static_page
if [ -n "${RUNPOD_POD_ID:-}" ]; then
  echo "Open now:            https://${RUNPOD_POD_ID}-8188.proxy.runpod.net/reels.html"
  echo "After a restart too: https://${RUNPOD_POD_ID}-8188.proxy.runpod.net/reels"
fi
exit 0
__PAYLOAD__
'''

MAIN_HEADER = r'''#!/usr/bin/env bash
# One-file installer: unpacks the workflow, setup script and dashboard next to itself, then runs the setup.
HERE="$(cd "$(dirname "$0")" && pwd)"
exec 9>/tmp/reels_install.lock
flock -n 9 || { echo "An install is already running. Watch it with: tail -f $HERE/install_log.txt"; exit 1; }
# write to temp files and rename, so a script that is still being read is never overwritten in place
sed -n '/^__WORKFLOW_B64__$/,$p' "$0" | tail -n +2 | base64 -d | gunzip > "$HERE/wan_animate_runpod.json.tmp" && mv -f "$HERE/wan_animate_runpod.json.tmp" "$HERE/wan_animate_runpod.json"
sed -n '2,/^__SETUP_END__$/p' "$0" | sed '1,/^__SETUP_START__$/d;$d' > "$HERE/setup_reels_studio.sh.tmp" && mv -f "$HERE/setup_reels_studio.sh.tmp" "$HERE/setup_reels_studio.sh"
''' + FIND_COMFY + r'''if [ -n "$COMFY" ]; then
  mkdir -p "$COMFY/custom_nodes/ComfyUI-ReelsStudio"
  sed -n '/^__DASHBOARD_B64__$/,/^__WORKFLOW_B64__$/p' "$0" | sed '1d;$d' | base64 -d | tar -xz -C "$COMFY/custom_nodes/ComfyUI-ReelsStudio"
fi
bash "$HERE/setup_reels_studio.sh" 2>&1 | tee "$HERE/install_log.txt"
''' + COPY_STATIC + r'''[ -n "$COMFY" ] && copy_static_page | tee -a "$HERE/install_log.txt"
echo; echo "Log saved to $HERE/install_log.txt"
[ -n "${RUNPOD_POD_ID:-}" ] && echo "Dashboard: https://${RUNPOD_POD_ID}-8188.proxy.runpod.net/reels.html" | tee -a "$HERE/install_log.txt"
exit 0
__SETUP_START__
'''


def main():
    dash = dashboard_tar()
    with open(os.path.join(HERE, "install_dashboard.sh"), "w") as f:
        f.write(DASH_HEADER + wrap(dash))
    setup = open(os.path.join(HERE, "setup_reels_studio.sh")).read()
    wf = gzip.compress(open(os.path.join(HERE, "wan_animate_runpod.json"), "rb").read(), 9)
    with open(os.path.join(HERE, "install_reels_studio.sh"), "w") as f:
        f.write(MAIN_HEADER + setup + "__SETUP_END__\n__DASHBOARD_B64__\n" + wrap(dash) + "__WORKFLOW_B64__\n" + wrap(wf))


if __name__ == "__main__":
    main()
