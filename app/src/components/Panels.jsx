import React, { useState } from 'react';
import { legendCategories, toCss, FIXED_BREAKS } from '../colors';
import { fmtValue } from '../format';
import { MIN_ZOOM } from '../layers';

export const POINT_FIELDS = {
  stores: { color_by: ['format', 'perf_band'], size_by: ['revenue_12m', 'carpet_area_sqft', 'growth_3m_pct'] },
  competitors: { color_by: ['category_group'], size_by: [] },
  olts: { color_by: ['capacity_status', 'current_status', 'health_7d'], size_by: ['homes_connected', 'open_incidents', 'pon_fill_pct'] },
  fdh: { color_by: ['health_7d'], size_by: ['homes_connected', 'open_incidents'] },
  incidents_30d: { color_by: ['incident_type', 'severity'], size_by: ['homes_impacted', 'outage_min'] },
};

const KIND_ICON = { h3: '⬡', points: '•', mvt: '▱', live: '◉' };

export function CatalogPanel({ catalog, activeKeys, hiddenKeys, onAdd }) {
  const [q, setQ] = useState('');
  const groups = {};
  for (const c of catalog) {
    if (q && !(`${c.title} ${c.description}`.toLowerCase().includes(q.toLowerCase()))) continue;
    (groups[c.group_name] = groups[c.group_name] || []).push(c);
  }
  return (
    <div className="panel catalog">
      <div className="panel-head">
        <span>Data catalog</span>
        <span className="hint">drag onto the map</span>
      </div>
      <input className="search" placeholder="Search datasets…" value={q} onChange={(e) => setQ(e.target.value)} />
      <div className="catalog-list">
        {Object.entries(groups).map(([g, items]) => (
          <div key={g} className="cat-group">
            <div className="cat-group-title">{g}</div>
            {items.map((c) => (
              <div
                key={c.layer_key}
                className={`cat-card ${activeKeys.has(c.layer_key) ? 'active' : hiddenKeys?.has(c.layer_key) ? 'listed' : ''}`}
                draggable
                onDragStart={(e) => {
                  e.dataTransfer.setData('application/x-geolens-layer', c.layer_key);
                  e.dataTransfer.effectAllowed = 'copy';
                }}
                onDoubleClick={() => onAdd(c.layer_key)}
                title="Drag onto the map, or double-click to add"
              >
                <span className="cat-icon">{KIND_ICON[c.kind] || '•'}</span>
                <span className="cat-text">
                  <span className="cat-title">{c.title}</span>
                  <span className="cat-desc">{c.description}</span>
                </span>
                <button className="icon-btn" onClick={() => onAdd(c.layer_key)} aria-label={`Add ${c.title}`}>+</button>
              </div>
            ))}
          </div>
        ))}
      </div>
    </div>
  );
}

export function LayersPanel({ layers, layerData, meta, dispatch, zoom = 0 }) {
  const [open, setOpen] = useState(null);
  const [dragOver, setDragOver] = useState(null);
  return (
    <div className="panel layers">
      <div className="panel-head">
        <span>Layers</span>
        <span className="hint">{layers.length} on map · drag to reorder</span>
      </div>
      {!layers.length && <div className="empty">Drag a dataset here or onto the map.</div>}
      {layers.map((L, idx) => {
        const D = layerData[L.id] || {};
        const ds = meta?.datasets?.[L.dataset];
        const mdef = ds?.metrics?.[L.metric];
        return (
          <div
            key={L.id}
            className={`layer-row ${dragOver === idx ? 'drag-over' : ''}`}
            draggable
            onDragStart={(e) => e.dataTransfer.setData('application/x-geolens-move', String(idx))}
            onDragOver={(e) => { e.preventDefault(); setDragOver(idx); }}
            onDragLeave={() => setDragOver(null)}
            onDrop={(e) => {
              e.preventDefault();
              setDragOver(null);
              const from = e.dataTransfer.getData('application/x-geolens-move');
              if (from !== '') dispatch({ type: 'moveLayer', from: Number(from), to: idx });
              const key = e.dataTransfer.getData('application/x-geolens-layer');
              if (key) dispatch({ type: 'addLayerKey', key, at: idx });
            }}
          >
            <div className="layer-line">
              <span className="drag-handle" aria-hidden>⋮⋮</span>
              <input type="checkbox" checked={L.visible} onChange={() => dispatch({ type: 'updateLayer', id: L.id, patch: { visible: !L.visible } })} aria-label="visible" />
              <button className="layer-title" onClick={() => setOpen(open === L.id ? null : L.id)}>
                {L.title}
                {L.kind === 'h3' && mdef && <span className="layer-sub">{mdef.label}</span>}
                {D.loading && <span className="spinner" aria-label="loading" />}
              </button>
              <button className="icon-btn" onClick={() => dispatch({ type: 'removeLayer', id: L.id })} aria-label="Remove layer">×</button>
            </div>
            {L.kind !== 'h3' && L.kind !== 'mvt' && MIN_ZOOM[L.dataset] && zoom < MIN_ZOOM[L.dataset] && (
              <div className="zoom-note">
                Hidden to keep the map clean · dots from zoom {MIN_ZOOM[L.dataset]}
              </div>
            )}
            {open === L.id && <LayerEditor L={L} D={D} ds={ds} dispatch={dispatch} />}
            <Legend L={L} D={D} mdef={mdef} />
          </div>
        );
      })}
    </div>
  );
}

function LayerEditor({ L, D, ds, dispatch }) {
  const up = (patch) => dispatch({ type: 'updateLayer', id: L.id, patch });
  const pf = POINT_FIELDS[L.dataset];
  return (
    <div className="layer-editor">
      {L.kind === 'h3' && ds && (
        <>
          <label>Metric</label>
          <select value={L.metric} onChange={(e) => up({ metric: e.target.value, filter: null })}>
            {Object.entries(ds.metrics).map(([k, m]) => <option key={k} value={k}>{m.label}</option>)}
          </select>
          <div className="chips">
            {Object.entries(ds.metrics).slice(0, 8).map(([k, m]) => (
              <span
                key={k}
                className="chip"
                draggable
                onDragStart={(e) => e.dataTransfer.setData('application/x-geolens-metric', JSON.stringify({ layerId: L.id, metric: k }))}
                title="Drag to the widget rail"
              >{m.label}</span>
            ))}
          </div>
          <label className="row"><input type="checkbox" checked={!!L.extruded} onChange={() => up({ extruded: !L.extruded })} /> 3D extrusion</label>
          {L.filter && <button className="link" onClick={() => up({ filter: null })}>Clear range filter</button>}
        </>
      )}
      {pf && (
        <>
          <label>Colour by</label>
          <select value={L.style?.color_by || ''} onChange={(e) => up({ style: { ...L.style, color_by: e.target.value } })}>
            {pf.color_by.map((f) => <option key={f} value={f}>{f.replace(/_/g, ' ')}</option>)}
          </select>
          {!!pf.size_by.length && (
            <>
              <label>Size by</label>
              <select value={L.style?.size_by || ''} onChange={(e) => up({ style: { ...L.style, size_by: e.target.value || null } })}>
                <option value="">fixed</option>
                {pf.size_by.map((f) => <option key={f} value={f}>{f.replace(/_/g, ' ')}</option>)}
              </select>
            </>
          )}
        </>
      )}
      <label>Opacity</label>
      <input type="range" min="0.1" max="1" step="0.05" value={L.opacity} onChange={(e) => up({ opacity: Number(e.target.value) })} />
    </div>
  );
}

function Legend({ L, D, mdef }) {
  if (L.kind === 'h3' && D.scale && mdef) {
    const { breaks, colors } = D.scale;
    return (
      <div className="legend">
        <div className="legend-ramp">
          {colors.slice(0, breaks.length + 1).map((c, i) => <span key={i} style={{ background: toCss(c) }} />)}
        </div>
        <div className="legend-labels">
          <span>{breaks.length ? fmtValue(breaks[0], mdef.fmt, mdef.unit) : ''}</span>
          <span>{breaks.length ? fmtValue(breaks[breaks.length - 1], mdef.fmt, mdef.unit) : ''}</span>
        </div>
        <div className="legend-note">{(D.data || []).length.toLocaleString()} cells in view · {FIXED_BREAKS[L.metric] ? 'fixed operational bands' : 'quantiles'}</div>
      </div>
    );
  }
  const field = L.style?.color_by;
  if (field && L.kind !== 'h3') {
    const cats = legendCategories(field);
    if (cats.length) {
      return (
        <div className="legend cats">
          {cats.map((c) => <span key={c.label} className="legend-cat"><i style={{ background: c.color }} />{c.label}</span>)}
        </div>
      );
    }
    return <div className="legend-note">{field.replace(/_/g, ' ')}: low → high</div>;
  }
  return null;
}
