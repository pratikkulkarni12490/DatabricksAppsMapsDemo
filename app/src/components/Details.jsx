import React, { useEffect, useState } from 'react';
import { getJSON, postJSON } from '../api';
import { Bars, HBars, Sparkline } from './Charts';
import { inr, compact, fmtValue, ago } from '../format';
import { categoryColor, toCss, STATUS } from '../colors';

function Stat({ label, value, sub }) {
  return (
    <div className="stat">
      <div className="stat-label">{label}</div>
      <div className="stat-value">{value}</div>
      {sub && <div className="stat-sub">{sub}</div>}
    </div>
  );
}

function StatusPill({ field, value }) {
  const c = toCss(categoryColor(field, value));
  return <span className="pill"><i style={{ background: c }} />{value}</span>;
}

export function DetailsDrawer({ sel, meta, onClose, onCatchment, onPlot, onRefreshLive, time }) {
  if (!sel) return null;
  return (
    <div className="drawer">
      <button className="icon-btn drawer-close" onClick={onClose} aria-label="Close">×</button>
      {sel.entity === 'store' && <StoreDetail id={sel.id} onCatchment={onCatchment} />}
      {sel.entity === 'plot' && <PlotDetail id={sel.id} onPlot={onPlot} />}
      {sel.entity === 'olt' && <OltDetail id={sel.id} />}
      {sel.entity === 'incident' && <IncidentDetail id={sel.id} onRefreshLive={onRefreshLive} />}
      {sel.entity === 'cell' && <CellDetail dataset={sel.dataset} h3={sel.id} meta={meta} time={time} />}
      {sel.entity === 'technician' && <TechDetail t={sel.data} />}
    </div>
  );
}

function useLoad(path, deps) {
  const [d, setD] = useState(null);
  const [err, setErr] = useState(null);
  useEffect(() => {
    let live = true;
    setD(null);
    setErr(null);
    getJSON(path).then((x) => live && setD(x)).catch((e) => live && setErr(String(e)));
    return () => { live = false; };
  }, deps); // eslint-disable-line react-hooks/exhaustive-deps
  return [d, err];
}

function StoreDetail({ id, onCatchment }) {
  const [d, err] = useLoad(`/api/retail/store/${id}`, [id]);
  useEffect(() => { if (d && d.catchment) onCatchment(d.catchment); }, [d]); // eslint-disable-line
  if (err) return <div className="err">{err}</div>;
  if (!d) return <div className="muted pad">Loading store…</div>;
  const s = d.store;
  return (
    <div>
      <div className="drawer-kicker">{s.format} · {s.locality}</div>
      <h3>{s.store_name}</h3>
      <div className="row gap"><StatusPill field="perf_band" value={s.perf_band} /><span className="muted">{s.store_code} · opened {String(s.open_date).slice(0, 4)}</span></div>
      <div className="stats">
        <Stat label="Revenue 12m" value={inr(s.revenue_12m)} sub={`#${s.rank_in_metro_format} ${s.format} in metro`} />
        <Stat label="Revenue / sq ft" value={inr(s.revenue_per_sqft)} sub={`${s.carpet_area_sqft.toLocaleString()} sq ft`} />
        <Stat label="Customers 12m" value={compact(s.customers_12m)} sub={`${compact(s.orders_12m)} orders`} />
        <Stat label="3-month growth" value={`${s.growth_3m_pct > 0 ? '+' : ''}${s.growth_3m_pct}%`} sub={`JioMart ${(100 * s.jiomart_share).toFixed(1)}%`} />
      </div>
      <h4>Monthly revenue</h4>
      <Bars data={d.monthly} x="month" y="revenue" fmt={inr} xfmt={(r) => String(r.month).slice(0, 7)} />
      <h4>Category mix (12m)</h4>
      <HBars rows={d.mix} label="category" value="revenue" fmt={inr} />
      <h4>Catchment</h4>
      <p className="muted">Shown on the map in orange. 80% of revenue comes from {d.cells_for_80pct} res-8 cells (~{(d.cells_for_80pct * 0.74).toFixed(0)} km²).</p>
      <h4>Competition within 3 km</h4>
      {d.competitors_3km.length ? <HBars rows={d.competitors_3km.slice(0, 8)} label="brand" value="n" fmt={(n) => n} colorFor={(r) => toCss(categoryColor('category_group', r.category_group))} /> : <p className="muted">None</p>}
      <h4>Top {s.format} stores in metro</h4>
      <HBars rows={d.peers} label="store_name" value="revenue_12m" fmt={inr} colorFor={(r) => (r.store_code === s.store_code ? 'var(--series-2)' : 'var(--series-1)')} />
    </div>
  );
}

function PlotDetail({ id, onPlot }) {
  const [d, err] = useLoad(`/api/retail/plot/${id}`, [id]);
  const [note, setNote] = useState('');
  const [saved, setSaved] = useState(false);
  useEffect(() => { if (d) onPlot(d.plot); }, [d]); // eslint-disable-line
  if (err) return <div className="err">{err}</div>;
  if (!d) return <div className="muted pad">Loading plot…</div>;
  const p = d.plot;
  const scores = [
    { k: 'Grocery (Smart Bazaar/Point)', v: p.score_grocery },
    { k: 'Fashion (Trends)', v: p.score_fashion },
    { k: 'Electronics (Digital)', v: p.score_electronics },
  ];
  return (
    <div>
      <div className="drawer-kicker">Candidate plot · {p.locality}</div>
      <h3>{p.plot_id}</h3>
      <div className="row gap"><span className="pill">{p.plot_status}</span><span className="muted">{p.zoning} · {p.transaction_type} · {p.road_access}</span></div>
      <div className="stats">
        <Stat label="Recommended" value={p.recommended_format} sub={`score ${p.best_score}/100`} />
        <Stat label="Est. revenue" value={`₹${p.est_annual_revenue_cr} Cr/yr`} sub="vs metro median store" />
        <Stat label="Cannibalisation" value={`${p.cannibalisation_risk_pct}%`} sub={`nearest grocery ${p.near_grocery_km} km`} />
        <Stat label="Land value" value={`₹${p.est_land_value_cr} Cr`} sub={`${Math.round(p.area_sqm).toLocaleString()} m² · ₹${p.ask_price_inr_per_sqft.toLocaleString()}/sq ft`} />
      </div>
      <h4>Site score by format</h4>
      <HBars rows={scores} label="k" value="v" fmt={(v) => v} max={100} />
      <h4>3 km catchment (blue ring)</h4>
      <div className="stats">
        <Stat label="Households" value={compact(p.households_3km)} />
        <Stat label="Affluence" value={p.affluence_3km} />
        <Stat label="Reliance revenue" value={inr(p.reliance_revenue_3km)} />
        <Stat label="Competitors" value={p.comp_grocery_3km + p.comp_fashion_3km + p.comp_electronics_3km} sub={`${p.comp_grocery_3km} grocery · ${p.comp_fashion_3km} fashion`} />
      </div>
      <h4>Shortlist</h4>
      {d.shortlist.map((s, i) => <div key={i} className="note"><b>{s.principal}</b> <span className="muted">{ago(s.created_at)}</span><div>{s.note}</div></div>)}
      <div className="row gap">
        <input className="search" placeholder="Note for the expansion committee…" value={note} onChange={(e) => setNote(e.target.value)} />
        <button className="btn" onClick={() => postJSON('/api/retail/shortlist', { plot_id: p.plot_id, note }).then(() => setSaved(true))}>{saved ? 'Saved ✓' : 'Shortlist'}</button>
      </div>
    </div>
  );
}

function OltDetail({ id }) {
  const [d, err] = useLoad(`/api/fiber/olt/${id}`, [id]);
  if (err) return <div className="err">{err}</div>;
  if (!d) return <div className="muted pad">Loading OLT…</div>;
  const o = d.olt;
  return (
    <div>
      <div className="drawer-kicker">OLT · {o.vendor_model}</div>
      <h3>{o.olt_name}</h3>
      <div className="row gap"><StatusPill field="current_status" value={o.current_status} /><StatusPill field="capacity_status" value={o.capacity_status} /></div>
      <div className="stats">
        <Stat label="Homes connected" value={compact(o.homes_connected)} sub={`${o.pon_ports} PON ports · 1:${o.split_ratio}`} />
        <Stat label="PON fill" value={`${o.pon_fill_pct}%`} sub={o.months_to_exhaustion > 0 ? `${o.months_to_exhaustion} months to 90%` : 'exhausted'} />
        <Stat label="Peak util 7d" value={`${o.peak_util_7d}%`} sub={`uplink ${o.peak_uplink_7d}%`} />
        <Stat label="Health 7d" value={o.health_7d} sub={`${o.open_incidents} open · ${o.incidents_30d} in 30d`} />
      </div>
      <h4>PON utilisation, last 72 h</h4>
      <Sparkline data={d.hourly} x="hour_ts" y="pon_util_pct" fmt={(v) => `${v}%`} height={70} />
      <h4>Recent incidents</h4>
      <div className="list">
        {d.incidents.slice(0, 8).map((i) => (
          <div key={i.incident_id} className="list-row">
            <StatusPill field="severity" value={i.severity} /><span className="ellipsis">{i.incident_type}</span>
            <span className="muted">{String(i.start_ts).slice(5, 16).replace('T', ' ')} · {i.outage_min} min{i.sla_breached ? ' · SLA breach' : ''}</span>
          </div>
        ))}
      </div>
      <h4>FDH cabinets (worst first)</h4>
      <HBars rows={d.fdh.slice(0, 6)} label="fdh_id" value="health_7d" fmt={(v) => v} max={100} />
    </div>
  );
}

function IncidentDetail({ id, onRefreshLive }) {
  const [tick, setTick] = useState(0);
  const [d, err] = useLoad(`/api/fiber/incident/${id}`, [id, tick]);
  const [msg, setMsg] = useState('');
  if (err) return <div className="err">{err}</div>;
  if (!d) return <div className="muted pad">Loading incident…</div>;
  const i = d.incident;
  const dispatch = (t) => postJSON('/api/fiber/dispatch', { incident_id: i.incident_id, technician_id: t.technician_id })
    .then(() => { setMsg(`${t.technician_id} dispatched`); setTick((x) => x + 1); onRefreshLive(); })
    .catch((e) => setMsg(String(e)));
  return (
    <div>
      <div className="drawer-kicker">{i.live ? 'Live incident' : 'NOC incident'} · {i.metro_code}</div>
      <h3>{i.incident_type}</h3>
      <div className="row gap"><StatusPill field="severity" value={i.severity} /><span className="pill">{i.status}</span><span className="muted">{i.incident_id}</span></div>
      <div className="stats">
        <Stat label="Homes impacted" value={compact(i.homes_impacted)} />
        <Stat label="Started" value={ago(i.start_ts)} sub={String(i.start_ts).slice(0, 16).replace('T', ' ')} />
        <Stat label="Root cause" value={i.root_cause || '–'} />
        <Stat label="Assigned" value={i.assigned_technician || 'unassigned'} />
      </div>
      <h4>Nearest available technicians</h4>
      <div className="list">
        {d.nearest_technicians.map((t) => (
          <div key={t.technician_id} className="list-row">
            <span className="ellipsis">{t.technician_id} · {t.skill}</span>
            <span className="muted">{t.dist_km} km</span>
            {i.status === 'Open' && <button className="btn sm" onClick={() => dispatch(t)}>Dispatch</button>}
          </div>
        ))}
        {!d.nearest_technicians.length && <p className="muted">No available technicians in this metro.</p>}
      </div>
      {msg && <div className="ok">{msg}</div>}
    </div>
  );
}

function TechDetail({ t }) {
  return (
    <div>
      <div className="drawer-kicker">Field technician · {t.metro_code}</div>
      <h3>{t.technician_id}</h3>
      <div className="row gap"><span className="pill"><i style={{ background: toCss(categoryColor('status', t.status)) }} />{t.status}</span><span className="muted">{t.skill}</span></div>
      {t.assigned_incident && <p>Assigned to <b>{t.assigned_incident}</b></p>}
      <p className="muted">Position updates are pushed from Lakebase as the job progresses.</p>
    </div>
  );
}

function CellDetail({ dataset, h3, meta, time }) {
  const q = time && time.t0 ? `?t0=${time.t0}&t1=${time.t1}` : '';
  const [d, err] = useLoad(`/api/h3cell/${dataset}/${h3}${q}`, [dataset, h3, q]);
  if (err) return <div className="err">{err}</div>;
  if (!d) return <div className="muted pad">Loading cell…</div>;
  const defs = meta?.datasets?.[dataset]?.metrics || {};
  return (
    <div>
      <div className="drawer-kicker">H3 cell · {d.metro_code}</div>
      <h3 className="mono">{h3}</h3>
      <div className="kv">
        {Object.entries(defs).map(([k, m]) => (
          <div key={k} className="kv-row"><span>{m.label}</span><b>{fmtValue(d[k], m.fmt, m.unit)}</b></div>
        ))}
      </div>
    </div>
  );
}
