import asyncio
import logging
import os
import time
from contextlib import asynccontextmanager

import anyio
from fastapi import FastAPI
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from backend import api, metrics, realtime, simulator

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")


@asynccontextmanager
async def lifespan(app: FastAPI):
    # sync endpoints run in the threadpool; raise its size so a burst of tile requests doesn't queue
    anyio.to_thread.current_default_thread_limiter().total_tokens = int(os.environ.get("THREADPOOL_SIZE", "64"))
    realtime.start(asyncio.get_running_loop())
    simulator.start()
    yield


class SelectiveGZip(GZipMiddleware):
    """GZip everything except the SSE stream, which must flush event by event."""

    async def __call__(self, scope, receive, send):
        if scope.get("type") == "http" and scope.get("path") == "/api/stream":
            await self.app(scope, receive, send)
            return
        await super().__call__(scope, receive, send)


app = FastAPI(title="GeoLens", lifespan=lifespan)


@app.middleware("http")
async def server_timing(request, call_next):
    t0 = time.perf_counter()
    response = await call_next(request)
    ms = 1000 * (time.perf_counter() - t0)
    response.headers["Server-Timing"] = f"app;dur={ms:.1f}"
    metrics.record(request.url.path.split("/")[2] if request.url.path.startswith("/api/") else "static", ms)
    return response


app.add_middleware(SelectiveGZip, minimum_size=800)
app.include_router(api.router)

DIST = os.path.join(os.path.dirname(__file__), "dist")
if os.path.isdir(os.path.join(DIST, "assets")):
    app.mount("/assets", StaticFiles(directory=os.path.join(DIST, "assets")), name="assets")


@app.get("/{full_path:path}")
def spa(full_path: str):
    index = os.path.join(DIST, "index.html")
    if os.path.exists(index):
        return FileResponse(index, headers={"Cache-Control": "no-cache"})
    return {"status": "frontend not built"}
