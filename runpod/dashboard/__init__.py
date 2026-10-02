import os

from aiohttp import web

import folder_paths
from server import PromptServer

PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "page", "index.html")
VIDEO_EXT = (".mp4", ".webm", ".mov", ".mkv", ".gif")
routes = PromptServer.instance.routes


@routes.get("/reels")
async def reels_page(request):
    # A plain in-memory response; streamed file responses can be rejected by the RunPod proxy.
    with open(PAGE, encoding="utf-8") as f:
        html = f.read()
    return web.Response(text=html, content_type="text/html", headers={"Cache-Control": "no-store"})


routes.get("/reels/")(reels_page)


@routes.get("/reels/api/outputs")
async def reels_outputs(request):
    root = folder_paths.get_output_directory()
    items = []
    for dirpath, _, files in os.walk(root):
        for name in files:
            if not name.lower().endswith(VIDEO_EXT):
                continue
            path = os.path.join(dirpath, name)
            try:
                st = os.stat(path)
            except OSError:
                continue
            sub = os.path.relpath(dirpath, root)
            items.append({"filename": name, "subfolder": "" if sub == "." else sub,
                          "mtime": st.st_mtime, "size": st.st_size})
    items.sort(key=lambda x: x["mtime"], reverse=True)
    return web.json_response(items[:60])


NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}
