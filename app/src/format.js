export function fmtValue(v, fmt, unit) {
  if (v === null || v === undefined || Number.isNaN(v)) return '–';
  const n = Number(v);
  switch (fmt) {
    case 'inr':
      return inr(n);
    case 'pct':
      return `${n.toFixed(1)}%`;
    case 'pct3':
      return `${n.toFixed(2)}%`;
    case 'dec':
      return `${n.toFixed(Math.abs(n) < 10 ? 2 : 1)}${unit && unit !== '%' ? ' ' + unit : ''}`;
    default:
      return compact(n) + (unit && unit !== 'INR' && unit !== '' ? ' ' + unit : '');
  }
}

export function inr(n) {
  if (n === null || n === undefined) return '–';
  const a = Math.abs(n);
  if (a >= 1e7) return `₹${(n / 1e7).toFixed(a >= 1e9 ? 0 : 1)} Cr`;
  if (a >= 1e5) return `₹${(n / 1e5).toFixed(1)} L`;
  if (a >= 1e3) return `₹${(n / 1e3).toFixed(1)}K`;
  return `₹${n.toFixed(0)}`;
}

export function compact(n) {
  if (n === null || n === undefined) return '–';
  const a = Math.abs(n);
  if (a >= 1e7) return `${(n / 1e7).toFixed(2)} Cr`;
  if (a >= 1e5) return `${(n / 1e5).toFixed(1)} L`;
  if (a >= 1e3) return `${(n / 1e3).toFixed(1)}K`;
  if (a < 10 && a % 1) return n.toFixed(2);
  return Math.round(n).toLocaleString('en-IN');
}

export function ago(ts) {
  if (!ts) return '';
  const s = Math.max(0, (Date.now() - new Date(ts).getTime()) / 1000);
  if (s < 60) return `${Math.round(s)}s ago`;
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
}
