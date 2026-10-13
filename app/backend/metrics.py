"""Rolling server-side latency per route family (last 2,000 requests each), exposed on /api/health."""
import threading
from collections import defaultdict, deque

_lock = threading.Lock()
_lat: dict = defaultdict(lambda: deque(maxlen=2000))


def record(route: str, ms: float):
    with _lock:
        _lat[route].append(ms)


def summary() -> dict:
    out = {}
    with _lock:
        for k, v in _lat.items():
            s = sorted(v)
            if s:
                out[k] = {"n": len(s), "p50": round(s[len(s) // 2], 1), "p95": round(s[int(len(s) * 0.95)], 1),
                          "p99": round(s[min(len(s) - 1, int(len(s) * 0.99))], 1)}
    return out
