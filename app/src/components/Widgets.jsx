import React, { useMemo, useState } from 'react';
import { cellToLatLng } from 'h3-js';
import { Bars } from './Charts';
import { fmtValue, compact, inr } from '../format';
import { pointColor } from '../layers';
import { toCss } from '../colors';

const SUM_FMTS = new Set(['inr', 'num']);

function inBoundsH3(data, b) {
  if (!b) return data;
  const out = [];
  for (const d of data) {
    const [lat, lng] = cellToLatLng(d.h);
    if (lat >= b.s && lat <= b.n && lng >= b.w && lng <= b.e) out.push(d);
  }
  return out;
}

function inBoundsPts(rows, b) {
  if (!b) return rows;
  return rows.filter((d) => d.latitude >= b.s && d.latitude <= b.n && d.longitude >= b.w && d.longitude <= b.e);
}

function cellPlace(h, metros) {
  const [lat, lng] = cellToLatLng(h);
  let best = null, bd = 1e9;
  for (const m of metros || []) {
    const d = (m.lat - lat) ** 2 + (m.lon - lng) ** 2;
    if (d < bd) { bd = d; best = m; }
  }
  const km = best ? Math.round(111 * Math.sqrt(bd)) : 0;
  return best ? `${best.name} · ${km} km from centre` : `${lat.toFixed(2)}, ${lng.toFixed(2)}`;
}

function histogram(values, bins = 10) {
  const v = values.filter((x) => Number.isFinite(x)).sort((a, b) => a - b);
  if (!v.length) return [];
  // clip the long tail at p98 so a few outliers don't flatten the distribution
  const lo = v[0], hi = v[Math.floor(v.length * 0.98)] ?? v[v.length - 1];
  const step = (hi - lo) / bins || 1;
  const out = Array.from({ length: bins }, (_, i) => ({ lo: lo + i * step, hi: i === bins - 1 ? Infinity : lo + (i + 1) * step, n: 0 }));
  for (const x of v) out[Math.min(bins - 1, Math.floor((x - lo) / step))].n += 1;
  return out;
}

export function WidgetRail({ widgets, layers, sources, layerData, meta, bounds, dispatch, onFly, onSelectPoint, dark, metros }) {
  const [over, setOver] = useState(false);
  return (
    <div
      className={`widget-rail ${over ? 'drop-hover' : ''}`}
      onDragOver={(e) => { e.preventDefault(); setOver(true); }}
      onDragLeave={() => setOver(false)}
      onDrop={(e) => {
        e.preventDefault();
        setOver(false);
        const m = e.dataTransfer.getData('application/x-geolens-metric');
        if (m) {
          const { layerId, metric } = JSON.parse(m);
          dispatch({ type: 'addWidget', layerId, metric, kind: 'hist' });
          return;
        }
        const key = e.dataTransfer.getData('application/x-geolens-layer');
        if (key) dispatch({ type: 'addWidgetForKey', key });
      }}
    >
      <div className="panel-head"><span>Widgets</span><span className="hint">viewport · drop metrics here</span></div>
      {widgets.map((w) => (
        <Widget key={w.id} w={w} layers={layers} sources={sources} layerData={layerData} meta={meta} bounds={bounds}
                dispatch={dispatch} onFly={onFly} onSelectPoint={onSelectPoint} dark={dark} metros={metros} />
      ))}
      <div className="drop-zone">Drop a metric chip or dataset to add a widget</div>
    </div>
  );
}

function Widget({ w, layers, sources, layerData, meta, bounds, dispatch, onFly, onSelectPoint, dark, metros }) {
  const L = layers.find((l) => l.id === w.layerId);
  const kind = w.kind;
  const isH3 = L && L.kind === 'h3';
  const metric = w.metric || L?.metric;
  const mdef = isH3 ? meta?.datasets?.[L.dataset]?.metrics?.[metric] : null;
  const src = isH3 ? sources[`${L.dataset}|${metric}`] : layerData[L?.id];

  const view = useMemo(() => {
    if (!src) return null;
    if (isH3) return inBoundsH3(src.data || [], bounds);
    return inBoundsPts(src.rows || [], bounds);
  }, [src, bounds, isH3]);

  if (!L) return null;
  const head = (
    <div className="widget-head">
      <span className="widget-title">{isH3 ? mdef?.label : L.title}</span>
      <span className="widget-tools">
        {['kpi', 'hist', 'top'].map((k) => (
          <button key={k} className={`seg ${kind === k ? 'on' : ''}`} onClick={() => dispatch({ type: 'updateWidget', id: w.id, patch: { kind: k } })}>
            {k === 'kpi' ? '#' : k === 'hist' ? '▥' : '≡'}
          </button>
        ))}
        <button className="icon-btn" onClick={() => dispatch({ type: 'removeWidget', id: w.id })} aria-label="Remove widget">×</button>
      </span>
    </div>
  );
  if (!view) return <div className="widget">{head}<div className="muted">loading…</div></div>;

  if (isH3) {
    const vals = view.map((d) => d.v).filter((x) => x !== null && Number.isFinite(x));
    const isSum = SUM_FMTS.has(mdef?.fmt) && !/per|avg|share|index/i.test(mdef?.label || '');
    const agg = isSum ? vals.reduce((a, b) => a + b, 0) : vals.reduce((a, b) => a + b, 0) / (vals.length || 1);
    if (kind === 'kpi') {
      return (
        <div className="widget">
          {head}
          <div className="kpi-big">{fmtValue(agg, mdef?.fmt, mdef?.unit)}</div>
          <div className="muted">{isSum ? 'total' : 'mean of cells'} · {vals.length.toLocaleString()} cells in view</div>
        </div>
      );
    }
    if (kind === 'hist') {
      const h = histogram(vals);
      const sameMetric = metric === L.metric;
      return (
        <div className="widget">
          {head}
          <Bars
            data={h}
            x="lo"
            y="n"
            fmt={(n) => `${compact(n)} cells`}
            xfmt={(d) => `${fmtValue(d.lo, mdef?.fmt, mdef?.unit)} – ${Number.isFinite(d.hi) ? fmtValue(d.hi, mdef?.fmt, mdef?.unit) : 'max'}`}
            activeRange={sameMetric ? L.filter : null}
            onClick={sameMetric ? (d) => {
              const cur = L.filter;
              const next = cur && cur[0] === d.lo ? null : [d.lo, Number.isFinite(d.hi) ? d.hi : 1e18];
              dispatch({ type: 'updateLayer', id: L.id, patch: { filter: next } });
            } : null}
          />
          {!sameMetric && <div className="muted">Different metric from the layer: shown for context, not linked.</div>}
        </div>
      );
    }
    const top = [...view].filter((d) => d.v !== null).sort((a, b) => (mdef?.better === 'low' ? a.v - b.v : b.v - a.v)).slice(0, 7);
    return (
      <div className="widget">
        {head}
        <ol className="toplist">
          {top.map((d) => (
            <li key={d.h} onClick={() => { const [lat, lng] = cellToLatLng(d.h); onFly({ latitude: lat, longitude: lng, zoom: 13 }, [d.h]); }}>
              <span className="ellipsis">{cellPlace(d.h, metros)}</span><b>{fmtValue(d.v, mdef?.fmt, mdef?.unit)}</b>
            </li>
          ))}
        </ol>
        <div className="muted">{mdef?.better === 'low' ? 'worst' : 'top'} cells in view · click to fly</div>
      </div>
    );
  }

  // point layers
  const size = L.style?.size_by;
  if (kind === 'kpi') {
    const total = size ? view.reduce((a, d) => a + (Number(d[size]) || 0), 0) : null;
    return (
      <div className="widget">
        {head}
        <div className="kpi-big">{view.length.toLocaleString()}</div>
        <div className="muted">in view{total !== null ? ` · ${size.replace(/_/g, ' ')} ${size.includes('revenue') ? inr(total) : compact(total)}` : ''}</div>
      </div>
    );
  }
  const field = L.style?.color_by;
  if (kind === 'hist' && field) {
    const counts = {};
    for (const d of view) counts[d[field]] = (counts[d[field]] || 0) + 1;
    const rows = Object.entries(counts).sort((a, b) => b[1] - a[1]).slice(0, 8);
    const max = Math.max(...rows.map((r) => r[1]), 1);
    return (
      <div className="widget">
        {head}
        <div className="hbars">
          {!rows.length && <div className="muted small">None in this area</div>}
          {rows.map(([k, n]) => (
            <div key={k} className="hbar">
              <span className="hbar-label">{String(k)}</span>
              <span className="hbar-track"><span className="hbar-fill" style={{ width: `${(100 * n) / max}%`, background: toCss(pointColor(L.style, { [field]: isNaN(k) ? k : Number(k) }, {}, dark)) }} /></span>
              <span className="hbar-value">{n.toLocaleString()}</span>
            </div>
          ))}
        </div>
      </div>
    );
  }
  const key = size || 'name';
  const top = [...view].sort((a, b) => (Number(b[key]) || 0) - (Number(a[key]) || 0)).slice(0, 7);
  return (
    <div className="widget">
      {head}
      {!top.length && <div className="muted small">None in this area</div>}
      <ol className="toplist">
        {top.map((d) => (
          <li key={d.id} onClick={() => onSelectPoint(L, d)}>
            <span className="ellipsis">{d.name}</span>
            <b>{size ? (size.includes('revenue') ? inr(d[size]) : compact(d[size])) : ''}</b>
          </li>
        ))}
      </ol>
    </div>
  );
}
