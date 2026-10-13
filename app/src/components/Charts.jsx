import React, { useState } from 'react';

// Small SVG charts following the mark specs: 2px lines, rounded bar ends on the baseline, 2px gaps, hover tooltips,
// text in ink tokens (never series colour), recessive axes.

export function Sparkline({ data, x, y, fmt, height = 56, color = 'var(--series-1)', label }) {
  const [hover, setHover] = useState(null);
  if (!data || data.length < 2) return null;
  const w = 260, h = height, pad = 4;
  const ys = data.map((d) => Number(d[y]));
  const lo = Math.min(...ys), hi = Math.max(...ys);
  const sx = (i) => pad + (i * (w - 2 * pad)) / (data.length - 1);
  const sy = (v) => h - pad - ((v - lo) / (hi - lo || 1)) * (h - 2 * pad);
  const path = ys.map((v, i) => `${i ? 'L' : 'M'}${sx(i).toFixed(1)},${sy(v).toFixed(1)}`).join('');
  const onMove = (e) => {
    const r = e.currentTarget.getBoundingClientRect();
    const i = Math.round(((e.clientX - r.left) / r.width) * (data.length - 1));
    setHover(Math.max(0, Math.min(data.length - 1, i)));
  };
  return (
    <div className="spark" aria-label={label}>
      <svg viewBox={`0 0 ${w} ${h}`} width="100%" height={h} onMouseMove={onMove} onMouseLeave={() => setHover(null)}>
        <path d={path} fill="none" stroke={color} strokeWidth="2" strokeLinejoin="round" />
        {hover !== null && (
          <g>
            <line x1={sx(hover)} x2={sx(hover)} y1={0} y2={h} stroke="var(--text-muted)" strokeWidth="1" strokeDasharray="2 2" />
            <circle cx={sx(hover)} cy={sy(ys[hover])} r="4" fill={color} stroke="var(--surface-1)" strokeWidth="2" />
          </g>
        )}
      </svg>
      <div className="spark-tip">
        {hover !== null ? (
          <><span className="muted">{String(data[hover][x]).slice(0, 10)}</span> <b>{fmt(ys[hover])}</b></>
        ) : (
          <><span className="muted">latest</span> <b>{fmt(ys[ys.length - 1])}</b></>
        )}
      </div>
    </div>
  );
}

export function Bars({ data, x, y, fmt, height = 90, color = 'var(--series-1)', onClick, activeRange, xfmt }) {
  const [hover, setHover] = useState(null);
  if (!data || !data.length) return null;
  const w = 260, h = height, gap = 2;
  const max = Math.max(...data.map((d) => Number(d[y]) || 0), 1);
  const bw = (w - gap * (data.length - 1)) / data.length;
  return (
    <div className="bars">
      <svg viewBox={`0 0 ${w} ${h + 2}`} width="100%" height={h + 2} onMouseLeave={() => setHover(null)}>
        {data.map((d, i) => {
          const bh = Math.max(1, ((Number(d[y]) || 0) / max) * h);
          const xpos = i * (bw + gap);
          const dim = activeRange && !(d.lo >= activeRange[0] - 1e-9 && d.hi <= activeRange[1] + 1e-9);
          return (
            <g key={i} onMouseEnter={() => setHover(i)} onClick={() => onClick && onClick(d, i)} style={{ cursor: onClick ? 'pointer' : 'default' }}>
              <rect x={xpos} y={0} width={bw} height={h} fill="transparent" />
              <path d={roundedTop(xpos, h - bh, bw, bh, Math.min(4, bw / 2))} fill={d.color || color} opacity={dim ? 0.3 : 1} />
            </g>
          );
        })}
        <line x1="0" x2={w} y1={h + 1} y2={h + 1} stroke="var(--grid)" strokeWidth="1" />
      </svg>
      <div className="spark-tip">
        {hover !== null ? (
          <><span className="muted">{xfmt ? xfmt(data[hover]) : data[hover][x]}</span> <b>{fmt(data[hover][y])}</b></>
        ) : (
          <span className="muted">{onClick ? 'click a bar to filter the map' : ' '}</span>
        )}
      </div>
    </div>
  );
}

function roundedTop(x, y, w, h, r) {
  r = Math.min(r, h);
  return `M${x},${y + h}V${y + r}Q${x},${y} ${x + r},${y}H${x + w - r}Q${x + w},${y} ${x + w},${y + r}V${y + h}Z`;
}

export function HBars({ rows, label, value, fmt, colorFor, max: maxIn }) {
  const [hover, setHover] = useState(null);
  if (!rows || !rows.length) return null;
  const max = maxIn || Math.max(...rows.map((r) => Number(r[value]) || 0), 1);
  return (
    <div className="hbars" onMouseLeave={() => setHover(null)}>
      {rows.map((r, i) => (
        <div key={i} className={`hbar ${hover === i ? 'hover' : ''}`} onMouseEnter={() => setHover(i)}>
          <span className="hbar-label">{r[label]}</span>
          <span className="hbar-track">
            <span className="hbar-fill" style={{ width: `${Math.max(1.5, (100 * (Number(r[value]) || 0)) / max)}%`, background: colorFor ? colorFor(r) : 'var(--series-1)' }} />
          </span>
          <span className="hbar-value">{fmt(r[value])}</span>
        </div>
      ))}
    </div>
  );
}
