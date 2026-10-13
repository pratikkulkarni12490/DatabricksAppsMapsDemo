import React, { useState } from 'react';
import { inr, compact, ago } from '../format';
import { Sparkline } from './Charts';
import { categoryColor, toCss } from '../colors';

export function TopBar({ solution, setSolution, me, persona, setPersona, metros, onMetro, metro, time, setTime, meta, onSave, maps, onOpenMap, connected }) {
  const months = meta?.months || [];
  const days = meta?.days || [];
  return (
    <header className="topbar">
      <div className="brand">
        <span className="logo">⬡</span>
        <span className="brand-name">GeoLens</span>
        <span className="brand-sub">Reliance spatial intelligence</span>
      </div>
      <nav className="tabs" role="tablist">
        <button role="tab" className={solution === 'retail' ? 'on' : ''} onClick={() => setSolution('retail')}>Retail Intelligence</button>
        <button role="tab" className={solution === 'fiber' ? 'on' : ''} onClick={() => setSolution('fiber')}>Jio Fiber Control Center</button>
      </nav>
      <div className="controls">
        <select aria-label="Jump to metro" className={metro ? 'focused' : ''} value={metro || 'IN'} onChange={(e) => onMetro(e.target.value)}>
          <option value="IN">{metros.length === 8 ? 'All India' : 'All metros in my scope'}</option>
          {metros.map((m) => <option key={m.code} value={m.code}>{m.name}</option>)}
        </select>
        {solution === 'retail' ? (
          <span className="range">
            <select value={time.t0} onChange={(e) => setTime({ ...time, t0: e.target.value })} aria-label="From month">
              {months.map((m) => <option key={m} value={m}>{m.slice(0, 7)}</option>)}
            </select>
            <span className="muted">→</span>
            <select value={time.t1} onChange={(e) => setTime({ ...time, t1: e.target.value })} aria-label="To month">
              {months.map((m) => <option key={m} value={m}>{m.slice(0, 7)}</option>)}
            </select>
          </span>
        ) : (
          <span className="range seg-group">
            {[['1d', 1], ['7d', 7], ['30d', 30]].map(([l, n]) => {
              const t0 = days[days.length - n];
              return <button key={l} className={`seg ${time.t0 === t0 ? 'on' : ''}`} onClick={() => setTime({ t0, t1: days[days.length - 1] })}>{l}</button>;
            })}
          </span>
        )}
        <button className="btn ghost" onClick={onSave}>Save view</button>
        {maps.length > 0 && (
          <select aria-label="Open saved view" onChange={(e) => { onOpenMap(e.target.value); e.target.value = ''; }} defaultValue="">
            <option value="" disabled>Saved views…</option>
            {maps.map((m) => <option key={m.map_id} value={m.map_id}>{m.name} · {m.owner.split('@')[0]}</option>)}
          </select>
        )}
        <span className={`live-dot ${connected ? 'on' : ''}`} title={connected ? 'Live: pushed from Lakebase' : 'Reconnecting… (polling)'}>{connected ? 'LIVE' : 'POLL'}</span>
        {me && (
          <span className="persona">
            {me.is_presenter ? (
              <select value={persona} onChange={(e) => setPersona(e.target.value)} aria-label="View as persona">
                <option value="">{me.principal.split('@')[0]} · National</option>
                {me.personas.map((p) => <option key={p.principal} value={p.principal}>{p.persona} ({p.scopes})</option>)}
              </select>
            ) : <span>{me.persona_label}</span>}
          </span>
        )}
      </div>
    </header>
  );
}

function Kpi({ label, value, sub, tone }) {
  return (
    <div className={`kpi ${tone || ''}`}>
      <div className="kpi-label">{label}</div>
      <div className="kpi-value">{value}</div>
      {sub && <div className="kpi-sub">{sub}</div>}
    </div>
  );
}

export function RetailStrip({ k }) {
  if (!k) return <div className="kpi-strip"><span className="muted">Loading KPIs…</span></div>;
  const pen = (100 * k.customers) / Math.max(1, k.households);
  return (
    <div className="kpi-strip">
      <Kpi label="Stores in scope" value={compact(k.stores)} sub={`${k.watch_stores} on watch list`} />
      <Kpi label="Revenue (12m)" value={inr(k.revenue_12m)} sub={`${k.growth_3m_pct > 0 ? '+' : ''}${Number(k.growth_3m_pct).toFixed(1)}% last 3m vs prior`} />
      <Kpi label="Reliance One customers" value={compact(k.customers)} sub={`${pen.toFixed(1)} per 100 households`} />
      <Kpi label="JioMart share" value={`${(100 * k.jiomart_share).toFixed(1)}%`} sub="online, store-fulfilled" />
      <Kpi label="Strong candidate plots" value={compact(k.strong_plots)} sub={`score ≥ 65 · ₹${Number(k.strong_plot_rev_cr || 0).toFixed(0)} Cr/yr potential`} />
      <div className="kpi spark-kpi">
        <div className="kpi-label">Monthly revenue trend</div>
        <Sparkline data={k.trend} x="month" y="revenue" fmt={inr} height={34} />
      </div>
    </div>
  );
}

export function FiberStrip({ k }) {
  if (!k) return <div className="kpi-strip"><span className="muted">Loading network KPIs…</span></div>;
  const last = k.trend[k.trend.length - 1] || {};
  const L = k.live || {};
  return (
    <div className="kpi-strip">
      <Kpi label="Homes connected" value={compact(k.olts.subscribers)} sub={`${compact(k.olts.olts)} OLTs · ${(100 * k.olts.subscribers / Math.max(1, k.olts.homes_passed)).toFixed(1)}% of homes passed`} />
      <Kpi label="Network health" value={`${last.health_score}`} sub={`uptime ${last.uptime_pct}% · ${String(k.day)}`} tone={last.health_score < 75 ? 'warn' : ''} />
      <Kpi label="Open incidents" value={compact(L.open_incidents)} sub={`${L.open_p1} P1 open`} tone={L.open_p1 > 0 ? 'crit' : ''} />
      <Kpi label="Homes impacted now" value={compact(L.homes_impacted_now)} sub="by open incidents" tone="crit" />
      <Kpi label="Field force" value={`${compact(L.techs_busy)} busy`} sub={`${compact(L.techs_available)} available`} />
      <Kpi label="Capacity" value={`${k.olts.exhausted} exhausted`} sub={`${k.olts.augment} need augment <6m · ${k.olts.down_now} down now`} tone={k.olts.exhausted > 0 ? 'warn' : ''} />
      <div className="kpi spark-kpi">
        <div className="kpi-label">Uptime, 30 days</div>
        <Sparkline data={k.trend} x="day" y="uptime_pct" fmt={(v) => `${Number(v).toFixed(2)}%`} height={34} />
      </div>
    </div>
  );
}

export function LiveTicker({ incidents, onSelect }) {
  const [open, setOpen] = useState(false);
  const openCount = incidents.filter((i) => i.status === 'Open').length;
  const p1 = incidents.filter((i) => i.status === 'Open' && i.severity === 'P1').length;
  const rows = [...incidents].filter((i) => i.live || i.incident_id?.startsWith('LIVE'))
    .sort((a, b) => new Date(b.updated_at || b.start_ts) - new Date(a.updated_at || a.start_ts)).slice(0, 5);
  if (!rows.length) return null;
  if (!open) {
    return (
      <button className="ticker-pill" onClick={() => setOpen(true)} aria-label="Show live feed">
        <span className="dot-live" /> Live feed · {openCount} open{p1 ? ` · ${p1} P1` : ''}
      </button>
    );
  }
  return (
    <div className="ticker" aria-live="polite">
      <button className="ticker-head" onClick={() => setOpen(false)}>Live feed · {openCount} open <span className="muted">▾ hide</span></button>
      {rows.map((i) => (
        <button key={i.incident_id} className={`ticker-row ${i.status === 'Resolved' ? 'resolved' : ''}`} onClick={() => onSelect(i)}>
          <i style={{ background: toCss(categoryColor('severity', i.severity)) }} />
          <span className="sev">{i.severity}</span>
          <span className="ellipsis">{i.incident_type} · {i.metro_code}</span>
          <span className="muted">{i.status === 'Resolved' ? 'resolved' : i.assigned_technician ? 'tech en route' : ago(i.start_ts)}</span>
        </button>
      ))}
    </div>
  );
}
