import React, { useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react';
import { DeckGL, FlyToInterpolator, WebMercatorViewport } from 'deck.gl';
import { Map } from 'react-map-gl/maplibre';
import 'maplibre-gl/dist/maplibre-gl.css';
import { cellToLatLng, cellToBoundary, cellToParent, getResolution, latLngToCell } from 'h3-js';

import { getJSON, postJSON, setPersona as apiSetPersona, setScopeKey, getScopeKey, columnar } from './api';
import { resForZoom, tilesForViewport, viewportBounds, loadH3 } from './tiles';
import { buildLayers, scaleFor, pointStats, rollupRes, rollupCells } from './layers';
import { fmtValue, inr, compact } from './format';
import { TopBar, RetailStrip, FiberStrip, LiveTicker } from './components/TopBar';
import { CatalogPanel, LayersPanel } from './components/Panels';
import { WidgetRail } from './components/Widgets';
import { DetailsDrawer } from './components/Details';
import { ChatPanel } from './components/Chat';

const BASEMAPS = {
  retail: 'https://basemaps.cartocdn.com/gl/positron-gl-style/style.json',
  fiber: 'https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json',
};
// zoom limits live in the view state so deck.gl enforces them without interrupting fly-to transitions
const INDIA = { latitude: 21.5, longitude: 79.5, zoom: 4.4, pitch: 0, bearing: 0, minZoom: 3.8, maxZoom: 16, maxPitch: 60 };
const DEFAULT_LAYERS = {
  retail: ['retail_stores', 'retail_revenue'],
  fiber: ['fiber_live_incidents', 'fiber_technicians', 'fiber_health'],
};
// Listed in the Layers panel on landing but unticked until the user turns them on
const DEFAULT_HIDDEN = {
  retail: [],
  fiber: ['fiber_technicians', 'fiber_health'],
};
const DEFAULT_WIDGETS = {
  retail: [['retail_revenue', 'kpi'], ['retail_revenue', 'hist'], ['retail_stores', 'top']],
  fiber: [['fiber_health', 'hist'], ['fiber_health', 'top'], ['fiber_technicians', 'hist']],
};
const DEFAULT_TIME = { retail: { t0: '2025-10-01', t1: '2026-09-01' }, fiber: { t0: '2026-10-03', t1: '2026-10-09' } };

let _id = 0;
const uid = (p) => `${p}${Date.now().toString(36)}${(_id++).toString(36)}`;

function layerFromCatalog(c, metric) {
  return {
    id: uid('L'), layer_key: c.layer_key, kind: c.kind, dataset: c.dataset, metric: metric || c.default_metric,
    title: c.title, visible: true, opacity: c.kind === 'h3' ? 0.82 : 1, extruded: false, filter: null,
    style: { ...(c.default_style || {}) },
  };
}

function reducer(state, a) {
  const s = state[a.solution];
  const put = (patch) => ({ ...state, [a.solution]: { ...s, ...patch } });
  switch (a.type) {
    case 'init': return put({ layers: a.layers, widgets: a.widgets });
    case 'addLayer': {
      const layers = [...s.layers];
      layers.splice(a.at ?? 0, 0, a.layer);
      return put({ layers });
    }
    case 'removeLayer': return put({ layers: s.layers.filter((l) => l.id !== a.id), widgets: s.widgets.filter((w) => w.layerId !== a.id) });
    case 'updateLayer': return put({ layers: s.layers.map((l) => (l.id === a.id ? { ...l, ...a.patch } : l)) });
    case 'moveLayer': {
      const layers = [...s.layers];
      const [m] = layers.splice(a.from, 1);
      layers.splice(a.to, 0, m);
      return put({ layers });
    }
    case 'addWidget': return put({ widgets: [{ id: uid('W'), layerId: a.layerId, metric: a.metric || null, kind: a.kind || 'hist' }, ...s.widgets] });
    case 'updateWidget': return put({ widgets: s.widgets.map((w) => (w.id === a.id ? { ...w, ...a.patch } : w)) });
    case 'removeWidget': return put({ widgets: s.widgets.filter((w) => w.id !== a.id) });
    default: return state;
  }
}

export default function App() {
  const [me, setMe] = useState(null);
  const [meta, setMeta] = useState(null);
  const [persona, setPersonaState] = useState('');
  const [solution, setSolution] = useState('fiber');
  const [metro, setMetro] = useState(''); // '' = All India (within the user's scope)
  const metroRef = useRef('');
  metroRef.current = metro;
  const [catalogs, setCatalogs] = useState({ retail: [], fiber: [] });
  const [maps, setMaps] = useState([]);
  const [state, rawDispatch] = useReducer(reducer, { retail: { layers: [], widgets: [] }, fiber: { layers: [], widgets: [] } });
  const [time, setTimes] = useState(DEFAULT_TIME);
  const [viewState, setViewState] = useState(INDIA);
  const [vp, setVp] = useState({ res: 5, tiles: [], bounds: null });
  const [versions, setVersions] = useState({});
  const [sources, setSources] = useState({});
  const [points, setPoints] = useState({});
  const [live, setLive] = useState({ incidents: [], technicians: [], server_ts: null });
  const [kpis, setKpis] = useState({});
  const [selection, setSelection] = useState(null);
  const [overlay, setOverlay] = useState({});
  const [highlight, setHighlight] = useState([]);
  const [drill, setDrill] = useState([]); // stack of { h, res, prev } for hexagon drill-down
  const [pulse, setPulse] = useState(0);
  const [connected, setConnected] = useState(false);
  const [dropHover, setDropHover] = useState(false);
  const [size, setSize] = useState({ width: 1200, height: 800 });
  const mapRef = useRef(null);
  const liveRef = useRef(live);
  liveRef.current = live;

  const { layers, widgets } = state[solution];
  const catalog = catalogs[solution];
  const dark = solution === 'fiber';
  const dispatch = useCallback((a) => rawDispatch({ solution, ...a }), [solution]);
  const curTime = time[solution];

  // ---------- bootstrap ----------
  const loadMe = useCallback(async () => {
    const m = await getJSON('/api/me');
    setScopeKey(m.scope_key);
    setMe(m);
    return m;
  }, []);

  useEffect(() => {
    (async () => {
      const [m, mt] = await Promise.all([loadMe(), getJSON('/api/meta')]);
      setMeta(mt);
      setVersions(m.versions || {});
      const [r, f] = await Promise.all([getJSON('/api/catalog?solution=retail'), getJSON('/api/catalog?solution=fiber')]);
      setCatalogs({ retail: r, fiber: f });
      const home = homeView(m, mt);
      setViewState({ ...home, transitionDuration: 1200, transitionInterpolator: new FlyToInterpolator() });
      const mapId = new URLSearchParams(window.location.search).get('map');
      if (mapId) openMap(mapId, { retail: r, fiber: f });
    })().catch((e) => console.error(e));
  }, []); // eslint-disable-line

  // default layers + widgets once the catalog is known
  useEffect(() => {
    for (const sol of ['retail', 'fiber']) {
      const cat = catalogs[sol];
      if (!cat.length || state[sol].layers.length) continue;
      const ls = DEFAULT_LAYERS[sol].map((k) => cat.find((c) => c.layer_key === k)).filter(Boolean)
        .map((c) => ({ ...layerFromCatalog(c), visible: !DEFAULT_HIDDEN[sol].includes(c.layer_key) }));
      const ws = DEFAULT_WIDGETS[sol].map(([k, kind]) => {
        const l = ls.find((x) => x.layer_key === k);
        return l && { id: uid('W'), layerId: l.id, metric: null, kind };
      }).filter(Boolean);
      rawDispatch({ type: 'init', solution: sol, layers: ls, widgets: ws });
    }
  }, [catalogs]); // eslint-disable-line

  useEffect(() => { getJSON(`/api/maps?solution=${solution}`).then(setMaps).catch(() => setMaps([])); }, [solution, persona]);

  // ---------- viewport -> H3 resolution + tile set (debounced) ----------
  useEffect(() => {
    const t = setTimeout(() => {
      const res = resForZoom(viewState.zoom);
      setVp({ res, tiles: tilesForViewport(viewState, size, res), bounds: viewportBounds(viewState, size) });
    }, 160);
    return () => clearTimeout(t);
  }, [viewState.latitude, viewState.longitude, viewState.zoom, size]);

  useEffect(() => {
    const el = mapRef.current;
    if (!el) return;
    const ro = new ResizeObserver(([e]) => setSize({ width: e.contentRect.width, height: e.contentRect.height }));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // ---------- H3 sources (layers + widgets), double-buffered ----------
  const neededSources = useMemo(() => {
    const keys = new Set();
    for (const l of layers) if (l.kind === 'h3' && l.visible) keys.add(`${l.dataset}|${l.metric}`);
    for (const w of widgets) {
      const l = layers.find((x) => x.id === w.layerId);
      if (l && l.kind === 'h3') keys.add(`${l.dataset}|${w.metric || l.metric}`);
    }
    return [...keys];
  }, [layers, widgets]);

  const reqSeq = useRef({});
  useEffect(() => {
    if (!vp.tiles.length || !meta) return;
    for (const key of neededSources) {
      const [dataset, metric] = key.split('|');
      const ds = meta.datasets[dataset];
      const t = ds?.time ? curTime : null;
      const seq = (reqSeq.current[key] = (reqSeq.current[key] || 0) + 1);
      setSources((s) => ({ ...s, [key]: { ...(s[key] || {}), loading: true } }));
      loadH3({ dataset, metric }, vp.tiles, vp.res, t, versions[dataset], metro).then((data) => {
        if (reqSeq.current[key] !== seq) return; // a newer request superseded this one
        setSources((s) => ({ ...s, [key]: { data, loading: false, res: vp.res } }));
      });
    }
  }, [neededSources.join(','), vp, curTime.t0, curTime.t1, meta, versions.retail_demand, versions.retail_market, versions.fiber_health, versions.fiber_coverage, me?.scope_key, metro]); // eslint-disable-line

  // ---------- point layers ----------
  const pointDatasets = useMemo(() => [...new Set(layers.filter((l) => l.kind === 'points').map((l) => l.dataset))], [layers]);
  useEffect(() => {
    for (const ds of pointDatasets) {
      const v = versions[ds] || 0;
      const url = `/api/points/${ds}?s=${encodeURIComponent(getScopeKey())}&v=${v}${metro ? `&metro=${metro}` : ''}`;
      if (points[ds]?.url === url) continue;
      getJSON(url).then((p) => setPoints((s) => ({ ...s, [ds]: { url, rows: columnar(p) } })));
    }
  }, [pointDatasets.join(','), versions, me?.scope_key, metro]); // eslint-disable-line

  // ---------- live feed: initial load + SSE-driven deltas ----------
  const liveBusy = useRef(false);
  const fetchLive = useCallback(async (full = false) => {
    if (liveBusy.current) return;
    liveBusy.current = true;
    try {
      const q = new URLSearchParams();
      if (!full && liveRef.current.server_ts) q.set('since', liveRef.current.server_ts);
      if (metroRef.current) q.set('metro', metroRef.current);
      const d = await getJSON(`/api/live?${q}`);
      setLive((cur) => {
        const inc = new globalThis.Map(d.full ? [] : cur.incidents.map((i) => [i.incident_id, i]));
        for (const i of d.noc || []) inc.set(i.incident_id, { ...i, live: false });
        for (const i of d.live || []) inc.set(i.incident_id, { ...i, live: true });
        const tech = new globalThis.Map(d.full ? [] : cur.technicians.map((t) => [t.technician_id, t]));
        for (const t of d.technicians || []) tech.set(t.technician_id, t);
        const cutoff = Date.now() - 10 * 60 * 1000;
        return {
          incidents: [...inc.values()].filter((i) => i.status === 'Open' || new Date(i.end_ts || i.updated_at || 0).getTime() > cutoff),
          technicians: [...tech.values()],
          server_ts: d.server_ts,
        };
      });
    } catch (e) {
      console.warn('live fetch failed', e);
    } finally {
      liveBusy.current = false;
    }
  }, []);

  const hasLive = layers.some((l) => l.kind === 'live' && l.visible);
  useEffect(() => { if (hasLive) { liveBusy.current = false; setLive({ incidents: [], technicians: [], server_ts: null }); fetchLive(true); } }, [hasLive, me?.scope_key, metro]); // eslint-disable-line

  const loadKpis = useCallback(() => {
    const path = (solution === 'retail' ? '/api/retail/kpis' : '/api/fiber/kpis') + (metroRef.current ? `?metro=${metroRef.current}` : '');
    getJSON(path).then((k) => setKpis((s) => ({ ...s, [solution]: k }))).catch(() => {});
  }, [solution]);
  // keep showing the previous KPIs until the new ones arrive: blanking the strip resizes the map and cancels fly-to
  useEffect(() => { loadKpis(); }, [solution, me?.scope_key, versions.fiber_kpis, versions.retail_kpis, metro]); // eslint-disable-line

  const lastKpi = useRef(0);
  useEffect(() => {
    const es = new EventSource('/api/stream');
    es.addEventListener('hello', (e) => { setConnected(true); setVersions((v) => ({ ...v, ...JSON.parse(e.data).versions })); });
    es.addEventListener('dataset', (e) => {
      const d = JSON.parse(e.data);
      setVersions((v) => ({ ...v, [d.dataset]: d.version }));
      if (d.dataset === 'scope') loadMe();
    });
    es.addEventListener('live', () => {
      fetchLive(false);
      if (Date.now() - lastKpi.current > 8000) { lastKpi.current = Date.now(); loadKpis(); }
    });
    es.onerror = () => setConnected(false);
    es.onopen = () => setConnected(true);
    return () => es.close();
  }, [loadKpis]); // eslint-disable-line

  useEffect(() => { // fallback polling only while SSE is down
    if (connected || !hasLive) return;
    const t = setInterval(() => fetchLive(false), 10000);
    return () => clearInterval(t);
  }, [connected, hasLive]); // eslint-disable-line

  useEffect(() => { // pulse animation for live incidents (~20 fps)
    if (!hasLive) return;
    let raf, last = 0;
    const loop = (ts) => {
      if (ts - last > 50) { setPulse(((ts / 1600) % 1)); last = ts; }
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(raf);
  }, [hasLive]);

  // ---------- derived layer data ----------
  const focus = drill.length ? drill[drill.length - 1] : null;
  const inFocusCell = useCallback((lat, lng) => !focus || latLngToCell(lat, lng, focus.res) === focus.h, [focus]);
  const viewSources = useMemo(() => {
    if (!focus) return sources;
    const out = {};
    for (const [k, src] of Object.entries(sources)) {
      if (!src?.data) { out[k] = src; continue; }
      out[k] = { ...src, data: src.data.filter((d) => getResolution(d.h) > focus.res ? cellToParent(d.h, focus.res) === focus.h : d.h === focus.h) };
    }
    return out;
  }, [sources, focus]);

  const rollRes = rollupRes(viewState.zoom);
  const layerData = useMemo(() => {
    const out = {};
    for (const l of layers) {
      if (l.kind === 'h3') {
        const src = viewSources[`${l.dataset}|${l.metric}`];
        if (!src || !src.data) { out[l.id] = { loading: true }; continue; }
        const mdef = meta?.datasets?.[l.dataset]?.metrics?.[l.metric];
        const data = rollRes && !focus ? rollupCells(src.data, rollRes, mdef?.additive) : src.data;
        const { scale, max } = scaleFor(data, mdef, l.metric);
        out[l.id] = { data, scale, max, loading: src.loading, scaleKey: `${l.metric}|${rollRes}|${data.length}|${scale.breaks.join(',')}` };
      } else if (l.kind === 'points') {
        const p = points[l.dataset];
        const rows = p ? (focus ? p.rows.filter((r) => inFocusCell(r.latitude, r.longitude)) : p.rows) : null;
        out[l.id] = rows ? { rows, stats: pointStats(rows, l.style || {}) } : { loading: true };
      } else if (l.kind === 'live') {
        const rows = l.dataset === 'technicians'
          ? live.technicians.map((t) => ({ ...t, id: t.technician_id, name: `${t.technician_id} · ${t.skill}` }))
          : live.incidents.filter((i) => i.status === 'Open').map((i) => ({ ...i, id: i.incident_id, name: `${i.severity} ${i.incident_type} · ${i.metro_code}` }));
        if (focus) rows.splice(0, rows.length, ...rows.filter((r) => inFocusCell(r.latitude, r.longitude)));
        out[l.id] = { rows, stats: pointStats(rows, l.style || {}) };
      }
    }
    return out;
  }, [layers, viewSources, points, meta, live, focus, inFocusCell, rollRes]);

  const liveView = useMemo(() => (focus ? {
    ...live,
    incidents: live.incidents.filter((i) => inFocusCell(i.latitude, i.longitude)),
    technicians: live.technicians.filter((t) => inFocusCell(t.latitude, t.longitude)),
  } : live), [live, focus, inFocusCell]);

  const deckLayers = useMemo(() => buildLayers({
    layers, layerData, live: liveView, drill: focus, selection: { ...overlay, point: overlay.point }, highlight, pulse, dark, versions, zoom: viewState.zoom, metro,
  }), [layers, layerData, liveView, focus, overlay, highlight, pulse, dark, versions, viewState.zoom, metro]);

  // ---------- interactions ----------
  const addLayerKey = useCallback((key, at = 0, metric) => {
    const c = catalog.find((x) => x.layer_key === key);
    if (!c) return null;
    const existing = layers.find((l) => l.layer_key === key);
    if (existing) {
      // adding a layer that is already listed but unticked turns it on
      if (metric || !existing.visible) dispatch({ type: 'updateLayer', id: existing.id, patch: { ...(metric ? { metric } : {}), visible: true } });
      return existing.id;
    }
    const layer = layerFromCatalog(c, metric);
    dispatch({ type: 'addLayer', layer, at });
    return layer.id;
  }, [catalog, layers, dispatch]);

  const smartDispatch = useCallback((a) => {
    if (a.type === 'addLayerKey') return addLayerKey(a.key, a.at);
    if (a.type === 'addWidgetForKey') {
      const id = addLayerKey(a.key);
      const c = catalog.find((x) => x.layer_key === a.key);
      if (id) dispatch({ type: 'addWidget', layerId: id, kind: c?.kind === 'h3' ? 'hist' : 'top' });
      return null;
    }
    return dispatch(a);
  }, [addLayerKey, catalog, dispatch]);

  const flyTo = useCallback((v, cells) => {
    setViewState((cur) => ({ ...cur, ...v, transitionDuration: 1400, transitionInterpolator: new FlyToInterpolator() }));
    if (cells) setHighlight(cells);
  }, []);

  // Hexagon drill-down: fit the clicked cell, show only what is inside it, remember where we came from
  const drillInto = useCallback((h) => {
    const res = getResolution(h);
    // rolled-up national cells are far larger than the city inside them: fit the loaded child cells instead
    let ring = cellToBoundary(h);
    if (res < 5) {
      const kids = new Set();
      for (const src of Object.values(viewSources)) for (const d of src?.data || []) if (cellToParent(d.h, res) === h) kids.add(d.h);
      if (kids.size) ring = [...kids].flatMap((k) => cellToBoundary(k));
    }
    const lats = ring.map((p) => p[0]), lngs = ring.map((p) => p[1]);
    const vp = new WebMercatorViewport({ width: size.width, height: size.height });
    // leave room for the details drawer (right) and the breadcrumb (top) so the whole drilled cell stays in sight
    const fit = vp.fitBounds([[Math.min(...lngs), Math.min(...lats)], [Math.max(...lngs), Math.max(...lats)]],
      { padding: { top: 70, bottom: 50, left: 50, right: Math.min(430, size.width * 0.35) } });
    const { latitude, longitude, zoom, pitch, bearing } = viewState;
    setDrill((d) => [...d, { h, res, prev: { latitude, longitude, zoom, pitch, bearing } }]);
    setHighlight([]);
    flyTo({ latitude: fit.latitude, longitude: fit.longitude, zoom: Math.min(16, fit.zoom) });
  }, [size, viewState, flyTo, viewSources]);

  const drillBack = useCallback((all = false) => {
    setDrill((d) => {
      if (!d.length) return d;
      const target = all ? d[0] : d[d.length - 1];
      flyTo(target.prev);
      return all ? [] : d.slice(0, -1);
    });
    setSelection(null);
    setOverlay({});
  }, [flyTo]);

  const metrosInScope = useMemo(() => scopeMetros(me, meta), [me, meta]);
  // Metro focus: every request is filtered to that metro in Lakebase; '' = all metros in the user's scope
  const onMetro = (code) => {
    setDrill([]);
    setSelection(null);
    setOverlay({});
    setHighlight([]);
    if (code === 'IN' || !code) {
      setMetro('');
      return flyTo(homeView(me, meta));
    }
    const m = meta.metros.find((x) => x.code === code);
    if (m) {
      setMetro(code);
      flyTo({ latitude: m.lat, longitude: m.lon, zoom: m.zoom });
    }
  };

  const select = useCallback((sel, pt) => {
    setSelection(sel);
    setOverlay(pt ? { point: pt } : {});
  }, []);

  const onSelectPoint = useCallback((L, d) => {
    const ent = { stores: 'store', plots: 'plot', olts: 'olt', incidents_30d: 'incident', live_incidents: 'incident', technicians: 'technician' }[L.dataset];
    if (ent) select({ entity: ent, id: d.id, data: d }, d);
    flyTo({ latitude: d.latitude, longitude: d.longitude, zoom: Math.max(viewState.zoom, 12) });
  }, [select, flyTo, viewState.zoom]);

  const onClick = useCallback((info) => {
    const L = info.layer?.props?.meta;
    const o = info.object;
    if (!o || !L) return;
    if (L.kind === 'h3') {
      // rolled-up national cells have no metrics endpoint; they only drill
      if (getResolution(o.h) >= 5) select({ entity: 'cell', dataset: L.dataset, id: o.h });
      if (getResolution(o.h) < 9) drillInto(o.h);
      return;
    }
    if (L.kind === 'points') {
      const ent = { stores: 'store', plots: 'plot', olts: 'olt', incidents_30d: 'incident' }[L.dataset];
      if (ent) select({ entity: ent, id: o.id }, o);
      return;
    }
    if (L.kind === 'mvt' && o.properties?.plot_id) return select({ entity: 'plot', id: o.properties.plot_id });
    if (L.kind === 'live') {
      if (o.incident_id) return select({ entity: 'incident', id: o.incident_id }, o);
      if (o.technician_id) return select({ entity: 'technician', id: o.technician_id, data: o }, o);
    }
  }, [select, flyTo, viewState.zoom, drillInto]);

  const getTooltip = useCallback(({ object, layer }) => {
    if (!object || !layer) return null;
    const L = layer.props.meta;
    if (!L) return null;
    let html = '';
    if (L.kind === 'h3') {
      const m = meta?.datasets?.[L.dataset]?.metrics?.[L.metric];
      html = `<div class="tt-title">${m?.label || L.title}</div><div class="tt-value">${fmtValue(object.v, m?.fmt, m?.unit)}</div><div class="tt-sub">res ${getResolution(object.h)} cell${object.children ? ` · ${object.children} res-5 cells${m?.additive ? '' : ' averaged'}` : ''} · ${getResolution(object.h) < 9 ? 'click to drill into this hexagon' : 'click for all metrics'}</div>`;
    } else if (L.kind === 'points') {
      const st = L.style || {};
      const c = st.color_by ? `${st.color_by.replace(/_/g, ' ')}: <b>${object[st.color_by]}</b>` : '';
      const sz = st.size_by ? `${st.size_by.replace(/_/g, ' ')}: <b>${st.size_by.includes('revenue') ? inr(object[st.size_by]) : compact(object[st.size_by])}</b>` : '';
      html = `<div class="tt-title">${object.name}</div><div class="tt-sub">${c}</div><div class="tt-sub">${sz}</div>`;
    } else if (L.kind === 'mvt') {
      const p = object.properties || {};
      html = p.plot_id
        ? `<div class="tt-title">${p.plot_id}</div><div class="tt-sub">${p.recommended_format} · score <b>${p.best_score}</b></div><div class="tt-sub">${Math.round(p.area_sqm).toLocaleString()} m² · ${p.plot_status}</div>`
        : `<div class="tt-title">${p.route_type} route</div><div class="tt-sub">${p.route_km} km · laid ${p.laid_year}</div><div class="tt-sub">fiber cuts 30d: <b>${p.cuts_30d}</b></div>`;
    } else if (L.kind === 'live') {
      html = object.incident_id
        ? `<div class="tt-title">${object.severity} · ${object.incident_type}</div><div class="tt-sub">${compact(object.homes_impacted)} homes · ${object.status}</div><div class="tt-sub">${object.root_cause || ''}</div>`
        : `<div class="tt-title">${object.technician_id}</div><div class="tt-sub">${object.status} · ${object.skill}</div>`;
    }
    return { html, className: 'deck-tooltip' };
  }, [meta, vp.res]);

  const applyActions = useCallback((actions) => {
    for (const a of actions) {
      if (a.type === 'add_layer' && a.layer_key) addLayerKey(a.layer_key, 0, a.metric);
      if (a.type === 'set_metric' && a.layer_key) addLayerKey(a.layer_key, 0, a.metric);
      if (a.type === 'remove_layer') {
        const l = layers.find((x) => x.layer_key === a.layer_key);
        if (l) dispatch({ type: 'removeLayer', id: l.id });
      }
      if (a.type === 'fly_to') {
        const m = a.metro && meta.metros.find((x) => x.code === a.metro);
        if (m) { setMetro(m.code); flyTo({ latitude: m.lat, longitude: m.lon, zoom: a.zoom || m.zoom }); }
        else if (a.lat && a.lon) flyTo({ latitude: a.lat, longitude: a.lon, zoom: a.zoom || 12 });
      }
      if (a.type === 'highlight_cells' && a.h3?.length) {
        setHighlight(a.h3);
        if (!actions.some((x) => x.type === 'fly_to')) {
          const [lat, lng] = cellToLatLng(a.h3[0]);
          flyTo({ latitude: lat, longitude: lng, zoom: 11.5 });
        }
      }
      if (a.type === 'select_entity' && a.entity && a.id) select({ entity: a.entity, id: a.id });
    }
  }, [addLayerKey, layers, dispatch, meta, flyTo, select]);

  const agentState = useCallback(() => ({
    solution, zoom: Number(viewState.zoom.toFixed(1)), center: [Number(viewState.latitude.toFixed(3)), Number(viewState.longitude.toFixed(3))],
    focus_metro: metro || null, nearest_metro: nearestMetro(meta, viewState), time: curTime,
    layers: layers.map((l) => ({ layer_key: l.layer_key, metric: l.metric, visible: l.visible })),
  }), [solution, viewState, meta, curTime, layers, metro]);

  const saveView = async () => {
    const name = window.prompt('Name this view', `${solution === 'retail' ? 'Retail' : 'Fiber'} view ${new Date().toLocaleDateString()}`);
    if (!name) return;
    const { latitude, longitude, zoom, pitch, bearing } = viewState;
    const r = await postJSON('/api/maps', { solution, name, shared: true, config: { layers, widgets, viewState: { latitude, longitude, zoom, pitch, bearing }, time: curTime } });
    window.history.replaceState(null, '', `?map=${r.map_id}`);
    getJSON(`/api/maps?solution=${solution}`).then(setMaps);
  };

  const openMap = async (id, cats) => {
    const m = await getJSON(`/api/maps/${id}`);
    const c = m.config;
    setSolution(m.solution);
    rawDispatch({ type: 'init', solution: m.solution, layers: c.layers || [], widgets: c.widgets || [] });
    if (c.time) setTimes((t) => ({ ...t, [m.solution]: c.time }));
    if (c.viewState) flyTo(c.viewState);
    window.history.replaceState(null, '', `?map=${id}`);
  };

  const changePersona = async (p) => {
    apiSetPersona(p);
    setPersonaState(p);
    setSelection(null);
    setOverlay({});
    setHighlight([]);
    setLive({ incidents: [], technicians: [], server_ts: null });
    setMetro('');
    setDrill([]);
    const m = await loadMe();
    flyTo(homeView(m, meta));
  };

  const activeKeys = useMemo(() => new Set(layers.filter((l) => l.visible).map((l) => l.layer_key)), [layers]);
  const hiddenKeys = useMemo(() => new Set(layers.filter((l) => !l.visible).map((l) => l.layer_key)), [layers]);

  return (
    <div className={`app ${dark ? 'theme-dark' : 'theme-light'}`} data-theme={dark ? 'dark' : 'light'}>
      <TopBar solution={solution} setSolution={(s) => { setSolution(s); setSelection(null); setOverlay({}); setHighlight([]); setDrill([]); }}
              me={me} persona={persona} setPersona={changePersona} metros={metrosInScope} onMetro={onMetro} metro={metro}
              time={curTime} setTime={(t) => setTimes((x) => ({ ...x, [solution]: t }))} meta={meta}
              onSave={saveView} maps={maps} onOpenMap={(id) => openMap(id)} connected={connected} />
      {solution === 'retail' ? <RetailStrip k={kpis.retail} /> : <FiberStrip k={kpis.fiber} />}
      <div className="main">
        <aside className="left">
          <CatalogPanel catalog={catalog} activeKeys={activeKeys} hiddenKeys={hiddenKeys} onAdd={(k) => addLayerKey(k)} />
          <LayersPanel layers={layers} layerData={layerData} meta={meta} dispatch={smartDispatch} zoom={viewState.zoom} />
        </aside>
        <section
          ref={mapRef}
          className={`map ${dropHover ? 'drop-hover' : ''}`}
          onDragOver={(e) => { if (e.dataTransfer.types.includes('application/x-geolens-layer')) { e.preventDefault(); setDropHover(true); } }}
          onDragLeave={() => setDropHover(false)}
          onDrop={(e) => { e.preventDefault(); setDropHover(false); const k = e.dataTransfer.getData('application/x-geolens-layer'); if (k) addLayerKey(k); }}
        >
          <DeckGL
            viewState={viewState}
            onViewStateChange={({ viewState: v }) => setViewState(v)}
            controller={{ dragRotate: true, touchRotate: true }}
            layers={deckLayers}
            getTooltip={getTooltip}
            onClick={onClick}
            useDevicePixels={1.5}
          >
            <Map reuseMaps mapStyle={BASEMAPS[solution]} attributionControl={{ compact: true }} />
          </DeckGL>
          {dropHover && <div className="drop-overlay">Drop to add layer</div>}
          {drill.length > 0 && (
            <div className={`drill-bar ${selection ? 'with-drawer' : ''}`}>
              <button className="btn sm" onClick={() => drillBack(false)}>◀ Back</button>
              <span className="crumbs">
                <button className="link" onClick={() => drillBack(true)}>{metro ? meta?.metros.find((m) => m.code === metro)?.name : 'All'}</button>
                {drill.map((d, i) => (
                  <span key={d.h}> › <span className={i === drill.length - 1 ? 'crumb-on' : ''}>res-{d.res} cell {nearestName(meta, d.h)}</span></span>
                ))}
              </span>
              <button className="icon-btn" onClick={() => drillBack(true)} aria-label="Exit drill-down">×</button>
            </div>
          )}
          {metro && !drill.length && (
            <button className="focus-chip" onClick={() => onMetro('IN')} title="Show all metros">
              Showing {meta?.metros.find((m) => m.code === metro)?.name} only <span aria-hidden>×</span>
            </button>
          )}
          <div className="map-badge">H3 res {vp.res} · {vp.tiles.length} tiles · zoom {viewState.zoom.toFixed(1)}</div>
          {solution === 'fiber' && <LiveTicker incidents={live.incidents} onSelect={(i) => { select({ entity: 'incident', id: i.incident_id }, i); flyTo({ latitude: i.latitude, longitude: i.longitude, zoom: 13 }); }} />}
          <DetailsDrawer sel={selection} meta={meta} time={curTime} onClose={() => { setSelection(null); setOverlay({}); }}
                         onCatchment={(c) => setOverlay((o) => ({ ...o, catchment: c }))}
                         onPlot={(p) => setOverlay((o) => ({ ...o, plot: p, point: { latitude: p.centroid_lat, longitude: p.centroid_lon } }))}
                         onRefreshLive={() => fetchLive(false)} />
          <ChatPanel solution={solution} getState={agentState} applyActions={applyActions} beside={!!selection} />
        </section>
        <aside className="right">
          <WidgetRail widgets={widgets} layers={layers} sources={viewSources} layerData={layerData} meta={meta} bounds={vp.bounds}
                      dispatch={smartDispatch} onFly={flyTo} onSelectPoint={onSelectPoint} dark={dark} metros={meta?.metros || []} />
        </aside>
      </div>
    </div>
  );
}

function scopeMetros(me, meta) {
  if (!me || !meta) return [];
  if (me.scopes.some((s) => s.scope_level === 'NATIONAL')) return meta.metros;
  return meta.metros.filter((m) => me.scopes.some((s) => (s.scope_level === 'REGION' && s.scope_value === m.region) || (s.scope_level === 'METRO' && s.scope_value === m.code)));
}

function homeView(me, meta) {
  const ms = scopeMetros(me, meta);
  if (!ms.length || ms.length === (meta?.metros || []).length) return INDIA;
  if (ms.length === 1) return { latitude: ms[0].lat, longitude: ms[0].lon, zoom: ms[0].zoom, pitch: 0, bearing: 0 };
  const lat = ms.reduce((a, m) => a + m.lat, 0) / ms.length;
  const lon = ms.reduce((a, m) => a + m.lon, 0) / ms.length;
  const span = Math.max(...ms.map((m) => Math.max(Math.abs(m.lat - lat), Math.abs(m.lon - lon))));
  return { latitude: lat, longitude: lon, zoom: span > 6 ? 4.6 : span > 2 ? 5.6 : 7, pitch: 0, bearing: 0 };
}

function nearestName(meta, h) {
  if (!meta) return '';
  const [lat, lng] = cellToLatLng(h);
  let best = null, bd = 1e9;
  for (const m of meta.metros) {
    const d = (m.lat - lat) ** 2 + (m.lon - lng) ** 2;
    if (d < bd) { bd = d; best = m; }
  }
  return best ? `· ${best.name} ${Math.round(111 * Math.sqrt(bd))} km` : '';
}

function nearestMetro(meta, v) {
  if (!meta) return null;
  let best = null, bd = 1e9;
  for (const m of meta.metros) {
    const d = (m.lat - v.latitude) ** 2 + (m.lon - v.longitude) ** 2;
    if (d < bd) { bd = d; best = m.code; }
  }
  return bd < 1 ? best : null;
}
