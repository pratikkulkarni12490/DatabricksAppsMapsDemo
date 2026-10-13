import { polygonToCells, gridDisk, latLngToCell } from 'h3-js';
import { WebMercatorViewport } from 'deck.gl';
import { headers, getScopeKey } from './api';

// Zoom -> H3 display resolution. Tiles are parents at (res - 3): at most 343 hexes per tile request.
export function resForZoom(z) {
  if (z < 6.3) return 5;
  if (z < 8.2) return 6;
  if (z < 9.8) return 7;
  if (z < 11.4) return 8;
  return 9;
}

export function viewportBounds(viewState, size) {
  const vp = new WebMercatorViewport({ ...viewState, width: size.width || 1200, height: size.height || 800 });
  const [w, s, e, n] = vp.getBounds();
  return { w, s, e, n };
}

export function tilesForViewport(viewState, size, res) {
  const tileRes = res - 3;
  const b = viewportBounds(viewState, size);
  const pad = 0.15;
  const dx = (b.e - b.w) * pad, dy = (b.n - b.s) * pad;
  const poly = [[b.s - dy, b.w - dx], [b.s - dy, b.e + dx], [b.n + dy, b.e + dx], [b.n + dy, b.w - dx], [b.s - dy, b.w - dx]];
  let cells = [];
  try {
    cells = polygonToCells(poly, tileRes);
  } catch (e) {
    cells = [];
  }
  const set = new Set(cells);
  // edge tiles whose centres fall outside the viewport still overlap it
  const ring = cells.length < 400 ? cells : [];
  for (const c of ring) for (const d of gridDisk(c, 1)) set.add(d);
  if (!set.size) for (const d of gridDisk(latLngToCell(viewState.latitude, viewState.longitude, tileRes), 2)) set.add(d);
  return [...set].slice(0, 600);
}

// Browser-side tile cache shared by all layers (keyed by full URL, which includes scope key + dataset version)
const tileCache = new Map();
const inflight = new Map();
const MAX_TILES = 4000;

async function fetchTile(url) {
  if (tileCache.has(url)) return tileCache.get(url);
  if (inflight.has(url)) return inflight.get(url);
  const p = fetch(url, { headers: headers(), credentials: 'same-origin' })
    .then((r) => (r.ok ? r.json() : { h: [], v: [] }))
    .catch(() => ({ h: [], v: [] }))
    .then((j) => {
      inflight.delete(url);
      if (tileCache.size > MAX_TILES) tileCache.delete(tileCache.keys().next().value);
      tileCache.set(url, j);
      return j;
    });
  inflight.set(url, p);
  return p;
}

export function tileUrl(layer, res, tile, time, version, metro) {
  const q = new URLSearchParams({ metric: layer.metric, s: getScopeKey(), v: String(version || 0) });
  if (metro) q.set('metro', metro);
  if (time && time.t0) q.set('t0', time.t0);
  if (time && time.t1) q.set('t1', time.t1);
  return `/api/h3/${layer.dataset}/${res}/${tile}?${q}`;
}

// Loads every tile for the viewport and resolves once all are in, so the map swaps in one frame (no flicker).
export async function loadH3(layer, tiles, res, time, version, metro) {
  const results = await Promise.all(tiles.map((t) => fetchTile(tileUrl(layer, res, t, time, version, metro))));
  const data = [];
  for (const r of results) {
    const { h, v } = r;
    for (let i = 0; i < h.length; i++) data.push({ h: h[i], v: v[i] });
  }
  return data;
}
