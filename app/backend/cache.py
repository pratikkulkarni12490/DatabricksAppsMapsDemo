"""Scope-keyed TTL caches with single-flight, so a burst of identical requests runs one query."""
import threading
import time

from cachetools import TTLCache


class SharedCache:
    def __init__(self, maxsize: int, ttl: float):
        self._cache = TTLCache(maxsize=maxsize, ttl=ttl)
        self._lock = threading.Lock()
        self._inflight: dict = {}
        self.hits = 0
        self.misses = 0

    def get_or_compute(self, key, fn):
        with self._lock:
            if key in self._cache:
                self.hits += 1
                return self._cache[key]
            ev = self._inflight.get(key)
            leader = ev is None
            if leader:
                ev = self._inflight[key] = threading.Event()
        if not leader:
            ev.wait(timeout=20)
            with self._lock:
                if key in self._cache:
                    self.hits += 1
                    return self._cache[key]
        try:
            self.misses += 1
            value = fn()
            with self._lock:
                self._cache[key] = value
            return value
        finally:
            if leader:
                with self._lock:
                    self._inflight.pop(key, None)
                ev.set()

    def clear(self):
        with self._lock:
            self._cache.clear()


tiles = SharedCache(maxsize=60_000, ttl=1800)       # H3 tiles, MVT tiles
entities = SharedCache(maxsize=5_000, ttl=300)      # point layers, details, lists
live = SharedCache(maxsize=500, ttl=2.5)            # live incidents / technicians
scopes = SharedCache(maxsize=10_000, ttl=60)        # (principal, persona) -> scope key


class DataVersion:
    """Current data_version from Lakebase, re-read at most once a minute. Part of every cache key and ETag."""

    def __init__(self):
        self.value = "init"
        self._ts = 0.0
        self._lock = threading.Lock()

    def get(self, loader) -> str:
        if time.time() - self._ts > 60:
            with self._lock:
                if time.time() - self._ts > 60:
                    try:
                        self.value = loader()
                    finally:
                        self._ts = time.time()
        return self.value


data_version = DataVersion()


def stats() -> dict:
    return {name: {"hits": c.hits, "misses": c.misses, "size": len(c._cache)}
            for name, c in (("tiles", tiles), ("entities", entities), ("live", live), ("scopes", scopes))}
