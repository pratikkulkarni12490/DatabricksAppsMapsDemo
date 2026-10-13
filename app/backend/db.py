"""Lakebase connection pools (psycopg2) with OAuth credentials and per-transaction scope context.

Reads go to the read replica through its PgBouncer host, writes to the primary. Every query runs inside a transaction
that first sets app.principal / app.persona, which the secure.* views and app.* RLS policies use.
"""
import logging
import os
import queue
import threading
import time
from contextlib import contextmanager

import psycopg2
import psycopg2.extras

from . import config

log = logging.getLogger("geolens.db")

TOKEN_TTL_S = 40 * 60
CONN_MAX_AGE_S = 45 * 60  # recycle before the 1-hour OAuth token expiry


class _TokenCache:
    def __init__(self):
        self._lock = threading.Lock()
        self._tokens: dict[str, tuple[str, float]] = {}

    def get(self, endpoint: str) -> str:
        with self._lock:
            tok, ts = self._tokens.get(endpoint, (None, 0.0))
            if tok and time.time() - ts < TOKEN_TTL_S:
                return tok
            tok = config.workspace_client().postgres.generate_database_credential(endpoint=endpoint).token
            self._tokens[endpoint] = (tok, time.time())
            return tok


_tokens = _TokenCache()


class LakebasePool:
    def __init__(self, name: str, host: str, endpoint: str, max_size: int = 20):
        self.name, self.host, self.endpoint, self.max_size = name, host, endpoint, max_size
        self._idle: queue.LifoQueue = queue.LifoQueue()
        self._created = 0
        self._born: dict[int, float] = {}
        self._lock = threading.Lock()

    def _connect(self):
        conn = psycopg2.connect(
            host=self.host, dbname=config.PG_DATABASE, user=config.pg_user(), password=_tokens.get(self.endpoint),
            sslmode="require", connect_timeout=10, application_name=f"geolens-{self.name}",
        )
        conn.autocommit = False
        self._born[id(conn)] = time.time()
        return conn

    def _acquire(self):
        while True:
            try:
                conn = self._idle.get_nowait()
            except queue.Empty:
                with self._lock:
                    if self._created < self.max_size:
                        self._created += 1
                        try:
                            return self._connect()
                        except Exception:
                            self._created -= 1
                            raise
                conn = self._idle.get(timeout=15)
            if conn.closed or time.time() - self._born.get(id(conn), 0) > CONN_MAX_AGE_S:
                self._discard(conn)
                continue
            return conn

    def _discard(self, conn):
        self._born.pop(id(conn), None)
        try:
            conn.close()
        except Exception:
            pass
        with self._lock:
            self._created -= 1

    @contextmanager
    def connection(self):
        conn = self._acquire()
        ok = True
        try:
            yield conn
        except (psycopg2.OperationalError, psycopg2.InterfaceError):
            ok = False
            raise
        finally:
            if ok and not conn.closed:
                try:
                    conn.rollback()
                except Exception:
                    ok = False
            if ok and not conn.closed:
                self._idle.put(conn)
            else:
                self._discard(conn)

    def stats(self) -> dict:
        return {"created": self._created, "idle": self._idle.qsize(), "max": self.max_size}


ro_pool = LakebasePool("ro", config.PG_RO_HOST, config.RO_ENDPOINT, max_size=int(os.environ.get("PG_POOL_MAX", "8")))
rw_pool = LakebasePool("rw", config.PG_RW_HOST, config.RW_ENDPOINT, max_size=8)

_SET_SCOPE = "SELECT set_config('app.principal', %s, true), set_config('app.persona', %s, true);"


def query(sql: str, params=(), principal: str = "", persona: str = "", write: bool = False, dict_rows: bool = False):
    """Run one statement in a scoped transaction. Returns (columns, rows)."""
    pool = rw_pool if write else ro_pool
    for attempt in (1, 2):
        try:
            with pool.connection() as conn:
                factory = psycopg2.extras.RealDictCursor if dict_rows else None
                with conn.cursor(cursor_factory=factory) as cur:
                    cur.execute(_SET_SCOPE, (principal, persona or ""))
                    cur.execute(sql, params)
                    cols = [d[0] for d in cur.description] if cur.description else []
                    rows = cur.fetchall() if cur.description else []
                if write:
                    conn.commit()
                return cols, rows
        except (psycopg2.OperationalError, psycopg2.InterfaceError) as e:
            log.warning("pool %s connection error (attempt %s): %s", pool.name, attempt, e)
            if attempt == 2:
                raise


def query_dicts(sql: str, params=(), principal: str = "", persona: str = "", write: bool = False) -> list[dict]:
    _, rows = query(sql, params, principal, persona, write, dict_rows=True)
    return [dict(r) for r in rows]


def direct_primary_connection():
    """Non-pooled session on the primary, for session-level advisory locks (simulator leader election)."""
    conn = psycopg2.connect(host=config.PG_RW_DIRECT_HOST, dbname=config.PG_DATABASE, user=config.pg_user(),
                            password=_tokens.get(config.RW_ENDPOINT), sslmode="require", connect_timeout=10,
                            application_name="geolens-simulator")
    conn.autocommit = True
    return conn
