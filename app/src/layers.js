import { H3HexagonLayer, MVTLayer, ScatterplotLayer, LineLayer, GeoJsonLayer } from 'deck.gl';
import { gridDisk, cellToParent } from 'h3-js';
import { categoryColor, makeScale, SEQ_BLUE, SEQ_ORANGE, DIVERGING, STATUS } from './colors';
import { headers, getScopeKey } from './api';

// Dots only appear once you zoom in; below these zooms the map shows polygons only (declutter).
export const MIN_ZOOM = {
  stores: 11, competitors: 12, plots: 11, olts: 10.5, fdh: 12, incidents_30d: 11, technicians: 11,
};
const hexRgb = (h) => [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)];

function numericColor(field, v, max) {
  if (v === null || v === undefined) return [140, 140, 136];
  if (field === 'health_7d') {
    const i = Math.max(0, Math.min(6, Math.floor((v - 55) / 7)));
    return DIVERGING[i];
  }
  if (field === 'best_score') {
    const i = Math.max(0, Math.min(6, Math.floor((v - 35) / 5)));
    return SEQ_BLUE[i];
  }
  const t = Math.max(0, Math.min(1, v / (max || 1)));
  return SEQ_ORANGE[Math.min(6, Math.floor(t * 7))];
}

export function pointColor(style, d, stats, dark) {
  const f = style.color_by;
  if (!f) return [42, 120, 214];
  const v = d[f];
  if (typeof v === 'number') return numericColor(f, v, stats[f + '_max']);
  return categoryColor(f, v, dark);
}

function sizeFor(style, d, stats) {
  const f = style.size_by;
  if (!f) return 4;
  const max = stats[f + '_max'] || 1;
  return 3 + 10 * Math.sqrt(Math.max(0, d[f] || 0) / max);
}

export function pointStats(rows, style) {
  const s = {};
  for (const f of [style.size_by, style.color_by]) {
    if (!f) continue;
    let m = 0;
    for (const r of rows) if (typeof r[f] === 'number' && r[f] > m) m = r[f];
    s[f + '_max'] = m;
  }
  return s;
}

export function buildLayers(ctx) {
  const { layers, layerData, live, selection, highlight, pulse, dark, versions, zoom, metro, drill } = ctx;
  // inside a drilled hexagon the area is small, so dots are shown even below their usual zoom threshold
  const showDots = (ds, n) => zoom >= (MIN_ZOOM[ds] || 0) || (drill && n < 2500);
  const out = [];
  const surface = dark ? [26, 26, 25] : [252, 252, 251];
  // panel order: first item = top of the map, so draw bottom-up
  for (const L of [...layers].reverse()) {
    if (!L.visible) continue;
    const D = layerData[L.id];
    if (L.kind === 'h3' && D && D.data) {
      const scale = D.scale;
      const [lo, hi] = L.filter || [null, null];
      const inRange = (v) => (lo === null || v >= lo) && (hi === null || v <= hi);
      const maxV = D.max || 1;
      out.push(new H3HexagonLayer({
        id: `h3-${L.id}`,
        data: D.data,
        getHexagon: (d) => d.h,
        getFillColor: (d) => {
          const c = scale.fn(d.v);
          return [c[0], c[1], c[2], inRange(d.v) ? 225 : 28];
        },
        extruded: !!L.extruded,
        getElevation: (d) => (inRange(d.v) ? Math.max(0, d.v) / maxV : 0),
        elevationScale: L.extruded ? 4000 / Math.max(1, zoom - 6) : 0,
        coverage: 0.93,
        stroked: false,
        // fade the surface near street level so roads and buildings stay readable under the dots
        opacity: L.opacity * (zoom > 12.5 ? Math.max(0.3, 1 - (zoom - 12.5) * 0.3) : 1),
        pickable: true,
        autoHighlight: true,
        highlightColor: [255, 255, 255, 90],
        material: false,
        transitions: { getFillColor: 600, getElevation: 600 },
        updateTriggers: { getFillColor: [D.scaleKey, lo, hi], getElevation: [D.scaleKey, lo, hi] },
        meta: L,
      }));
    }
    if (L.kind === 'points' && D && D.rows && showDots(L.dataset, D.rows.length)) {
      const st = L.style || {};
      out.push(new ScatterplotLayer({
        id: `pt-${L.id}`,
        data: D.rows,
        getPosition: (d) => [d.longitude, d.latitude],
        getFillColor: (d) => pointColor(st, d, D.stats, dark),
        getRadius: (d) => sizeFor(st, d, D.stats),
        radiusUnits: 'pixels',
        radiusScale: zoom < 9 ? 0.6 : zoom < 11 ? 0.85 : 1,
        stroked: true,
        getLineColor: surface,
        lineWidthMinPixels: 1,
        opacity: L.opacity,
        pickable: true,
        autoHighlight: true,
        updateTriggers: { getFillColor: [st.color_by, dark], getRadius: [st.size_by] },
        meta: L,
      }));
    }
    if (L.kind === 'mvt') {
      const ver = versions[L.dataset] || 0;
      const url = `/api/mvt/${L.dataset}/{z}/{x}/{y}.pbf?s=${encodeURIComponent(getScopeKey())}&v=${ver}${metro ? `&metro=${metro}` : ''}`;
      const isRoutes = L.dataset === 'routes';
      out.push(new MVTLayer({
        id: `mvt-${L.id}-${ver}-${metro || 'all'}`,
        data: url,
        minZoom: 8,
        maxZoom: 15,
        binary: false,
        loadOptions: { fetch: { headers: headers(), credentials: 'same-origin' } },
        getFillColor: (f) => [...numericColor('best_score', f.properties.best_score), 170],
        getLineColor: (f) => (isRoutes
          ? (f.properties.cuts_30d > 0 ? [...hexRgb(STATUS.critical), 230] : f.properties.route_type === 'Feeder' ? [57, 135, 229, 200] : [150, 150, 145, 120])
          : [24, 79, 149, 255]),
        getLineWidth: (f) => (isRoutes ? (f.properties.route_type === 'Feeder' ? 2.5 : 1) : 1.5),
        lineWidthUnits: 'pixels',
        stroked: true,
        filled: !isRoutes,
        opacity: L.opacity,
        pickable: true,
        autoHighlight: true,
        uniqueIdProperty: isRoutes ? 'route_id' : 'plot_id',
        meta: L,
      }));
    }
    if (L.kind === 'live' && live) {
      if (L.dataset === 'live_incidents') {
        // shown at every zoom from landing; open P1s keep glowing until resolved
        const SEV_DRAW = { P4: 0, P3: 1, P2: 2, P1: 3 };
        const inc = live.incidents.filter((d) => d.status === 'Open' || Date.now() - new Date(d.end_ts || 0).getTime() < 60000)
          .sort((a, b) => (SEV_DRAW[a.severity] ?? 0) - (SEV_DRAW[b.severity] ?? 0)); // P1 drawn on top
        const p1 = inc.filter((d) => d.status === 'Open' && d.severity === 'P1');
        out.push(new ScatterplotLayer({
          id: `glow-${L.id}`,
          data: p1,
          getPosition: (d) => [d.longitude, d.latitude],
          getFillColor: () => [...categoryColor('severity', 'P1'), 90 + Math.round(70 * Math.sin(Math.PI * pulse))],
          getRadius: 14,
          radiusUnits: 'pixels',
          stroked: false,
          updateTriggers: { getFillColor: pulse },
          pickable: false,
        }));
        out.push(new ScatterplotLayer({
          id: `halo-${L.id}`,
          data: p1,
          getPosition: (d) => [d.longitude, d.latitude],
          getFillColor: () => [0, 0, 0, 0],
          getLineColor: () => [...categoryColor('severity', 'P1'), Math.round(230 * (1 - pulse))],
          getRadius: () => 9 + 22 * pulse,
          radiusUnits: 'pixels',
          stroked: true,
          filled: false,
          lineWidthMinPixels: 2.5,
          updateTriggers: { getLineColor: pulse, getRadius: pulse },
          pickable: false,
        }));
        out.push(new ScatterplotLayer({
          id: `inc-${L.id}`,
          data: inc,
          getPosition: (d) => [d.longitude, d.latitude],
          getFillColor: (d) => (d.status === 'Open' ? categoryColor('severity', d.severity) : hexRgb(STATUS.good)),
          getRadius: (d) => (d.severity === 'P1' ? 7 : d.severity === 'P2' ? 6 : 4.5),
          radiusUnits: 'pixels',
          stroked: true,
          getLineColor: surface,
          lineWidthMinPixels: 1.5,
          pickable: true,
          autoHighlight: true,
          transitions: { getFillColor: 800 },
          meta: L,
        }));
      }
      if (L.dataset === 'technicians' && showDots('technicians', live.technicians.length)) {
        const techs = live.technicians;
        out.push(new LineLayer({
          id: `route-${L.id}`,
          data: techs.filter((t) => t.status === 'En route' && t.target_lat),
          getSourcePosition: (t) => [t.longitude, t.latitude],
          getTargetPosition: (t) => [t.target_lon, t.target_lat],
          getColor: [235, 104, 52, 160],
          getWidth: 1.5,
          widthUnits: 'pixels',
        }));
        out.push(new ScatterplotLayer({
          id: `tech-${L.id}`,
          data: techs,
          getPosition: (t) => [t.longitude, t.latitude],
          getFillColor: (t) => categoryColor('status', t.status, dark),
          getRadius: (t) => (t.status === 'Off shift' ? 2.5 : 3.5),
          radiusUnits: 'pixels',
          stroked: true,
          getLineColor: surface,
          lineWidthMinPixels: 1,
          pickable: true,
          transitions: { getPosition: 3500, getFillColor: 600 },
          updateTriggers: { getFillColor: dark },
          meta: L,
        }));
      }
    }
  }
  // drilled hexagon outline
  if (drill) {
    out.push(new H3HexagonLayer({
      id: 'drill-outline', data: [{ h: drill.h }], getHexagon: (d) => d.h, filled: false, stroked: true,
      getLineColor: dark ? [255, 255, 255, 230] : [11, 11, 11, 200], lineWidthMinPixels: 2.5, pickable: false,
    }));
  }
  // selection overlays
  if (selection && selection.catchment) {
    const cs = selection.catchment;
    const max = Math.max(...cs.map((c) => c.share_pct || 0), 0.01);
    out.push(new H3HexagonLayer({
      id: 'catchment',
      data: cs,
      getHexagon: (d) => d.h,
      getFillColor: (d) => [...SEQ_ORANGE[Math.min(6, Math.floor(7 * Math.sqrt((d.share_pct || 0) / max)))], 200],
      stroked: true,
      getLineColor: [255, 255, 255, 120],
      lineWidthMinPixels: 0.5,
      pickable: true,
      meta: { kind: 'catchment', title: 'Store catchment' },
    }));
  }
  if (selection && selection.plot && selection.plot.geometry) {
    const ring = gridDisk(selection.plot.h3_r8_hex, 4).map((h) => ({ h }));
    out.push(new H3HexagonLayer({
      id: 'plot-ring', data: ring, getHexagon: (d) => d.h, filled: true, getFillColor: [57, 135, 229, 35],
      stroked: true, getLineColor: [57, 135, 229, 160], lineWidthMinPixels: 1, pickable: false,
    }));
    out.push(new GeoJsonLayer({
      id: 'plot-sel', data: { type: 'Feature', geometry: selection.plot.geometry, properties: {} },
      filled: true, getFillColor: [235, 104, 52, 140], stroked: true, getLineColor: [235, 104, 52, 255], lineWidthMinPixels: 3,
    }));
  }
  if (highlight && highlight.length) {
    out.push(new H3HexagonLayer({
      id: 'highlight', data: highlight.map((h) => ({ h })), getHexagon: (d) => d.h, filled: true,
      getFillColor: [250, 178, 25, 60], stroked: true, getLineColor: [250, 178, 25, 255], lineWidthMinPixels: 2.5, pickable: false,
    }));
  }
  if (selection && selection.point) {
    out.push(new ScatterplotLayer({
      id: 'sel-point', data: [selection.point], getPosition: (d) => [d.longitude, d.latitude], getRadius: 14,
      radiusUnits: 'pixels', filled: false, stroked: true, getLineColor: dark ? [255, 255, 255] : [11, 11, 11], lineWidthMinPixels: 2.5,
    }));
  }
  return out;
}

// National zoom: res-5 cells are only a few pixels wide, so roll them into parents (sum for counts, mean for rates)
export function rollupRes(zoom) {
  return zoom < 4.8 ? 3 : zoom < 5.6 ? 4 : null;
}

export function rollupCells(data, res, additive) {
  const cells = new Map();
  for (const d of data) {
    if (d.v === null || !Number.isFinite(d.v)) continue;
    const h = cellToParent(d.h, res);
    const c = cells.get(h) || { h, sum: 0, n: 0 };
    c.sum += d.v;
    c.n += 1;
    cells.set(h, c);
  }
  return [...cells.values()].map((c) => ({ h: c.h, v: additive ? c.sum : c.sum / c.n, children: c.n }));
}

export function scaleFor(data, metricDef, metricKey) {
  const values = data.map((d) => d.v);
  const scale = makeScale(values, metricDef?.palette || 'seq', metricDef?.better || 'high', 7, metricKey);
  let max = 0;
  for (const v of values) if (v > max) max = v;
  return { scale, max };
}
