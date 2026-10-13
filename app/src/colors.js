// Palettes from the validated reference instance (dataviz skill): sequential blue, sequential orange (second context),
// diverging blue<->red with gray midpoint, fixed-order categorical slots, reserved status colours.
const hex = (h) => [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)];

export const SEQ_BLUE = ['#cde2fb', '#9ec5f4', '#6da7ec', '#3987e5', '#256abf', '#184f95', '#0d366b'].map(hex);
export const SEQ_ORANGE = ['#fde3d6', '#f9c2a6', '#f39a72', '#eb6834', '#c9501f', '#9e3c15', '#722a0e'].map(hex);
// low (bad) -> high (good): red arm, gray midpoint, blue arm
export const DIVERGING = ['#b8302f', '#e34948', '#f0a09f', '#c9c8c3', '#86b6ef', '#3987e5', '#184f95'].map(hex);

export const CATEGORICAL = ['#2a78d6', '#eb6834', '#1baf7a', '#eda100', '#e87ba4', '#008300', '#6250d6', '#e34948'];
export const CATEGORICAL_DARK = ['#3987e5', '#d95926', '#199e70', '#c98500', '#d55181', '#008300', '#9085e9', '#e66767'];
export const NEUTRAL = '#8f8e88';

export const STATUS = { good: '#0ca30c', warning: '#fab219', serious: '#ec835a', critical: '#d03b3b' };

// Fixed category orders: colour follows the entity, never its rank
export const CATEGORY_ORDERS = {
  format_group: ['Grocery', 'Fashion', 'Electronics', 'Jewellery', 'Beauty'],
  category_group: ['Grocery', 'Fashion', 'Electronics', 'Jewellery', 'Beauty'],
  recommended_format: ['Smart Bazaar', 'Trends', 'Reliance Digital', 'Smart Point'],
  incident_type: ['Distribution fiber cut', 'LOS alarm cluster', 'Power failure', 'FDH damage', 'Feeder fiber cut', 'OLT card failure', 'Planned maintenance'],
  status: ['Available', 'En route', 'On job', 'Off shift'],
};

export const STATUS_MAPS = {
  severity: { P1: STATUS.critical, P2: STATUS.serious, P3: STATUS.warning, P4: NEUTRAL },
  capacity_status: { Exhausted: STATUS.critical, 'Augment <6m': STATUS.warning, Healthy: STATUS.good },
  current_status: { Down: STATUS.critical, Degraded: STATUS.warning, Up: STATUS.good },
  perf_band: { Watch: STATUS.serious, Core: NEUTRAL, Top: STATUS.good },
};

export const FORMAT_GROUP = {
  'Smart Bazaar': 'Grocery', 'Smart Point': 'Grocery', 'Fresh Signature': 'Grocery',
  Trends: 'Fashion', Azorte: 'Fashion', Centro: 'Fashion',
  'Reliance Digital': 'Electronics', 'Reliance Jewels': 'Jewellery', Tira: 'Beauty',
};

export function categoryColor(field, value, dark = false) {
  if (STATUS_MAPS[field]) return hex(STATUS_MAPS[field][value] || NEUTRAL);
  const key = field === 'format' ? 'format_group' : field;
  const v = field === 'format' ? FORMAT_GROUP[value] : value;
  const order = CATEGORY_ORDERS[key] || [];
  const i = order.indexOf(v);
  const pal = dark ? CATEGORICAL_DARK : CATEGORICAL;
  return hex(i >= 0 && i < pal.length ? pal[i] : NEUTRAL);
}

export function legendCategories(field) {
  if (STATUS_MAPS[field]) return Object.entries(STATUS_MAPS[field]).map(([k, c]) => ({ label: k, color: c }));
  const key = field === 'format' ? 'format_group' : field;
  return (CATEGORY_ORDERS[key] || []).map((k, i) => ({ label: k, color: CATEGORICAL[i] || NEUTRAL }));
}

export function rampFor(palette) {
  return palette === 'div' ? DIVERGING : palette === 'heat' ? SEQ_ORANGE : SEQ_BLUE;
}

// Quantile breaks over the visible values (k classes). Returns k-1 thresholds.
export function quantileBreaks(values, k = 7) {
  const v = values.filter((x) => x !== null && Number.isFinite(x)).sort((a, b) => a - b);
  if (!v.length) return [];
  const out = [];
  for (let i = 1; i < k; i++) out.push(v[Math.min(v.length - 1, Math.floor((i * v.length) / k))]);
  return out;
}

// Fixed operational thresholds for network-health metrics (6 breaks -> 7 classes, low/bad -> high/good after inversion).
// Absolute bands keep healthy areas calm and make real problems stand out, instead of stretching noise across quantiles.
export const FIXED_BREAKS = {
  health_score: [60, 68, 75, 80, 85, 90],
  health_7d: [60, 68, 75, 80, 85, 90],
  uptime_pct: [97, 98.5, 99.2, 99.6, 99.8, 99.9],
  pct_ont_low_power: [2, 4, 7, 10, 15, 22],
  avg_latency_ms: [6, 7, 8, 10, 13, 18],
  packet_loss_pct: [0.08, 0.12, 0.18, 0.25, 0.4, 0.7],
  throughput_pct: [70, 80, 86, 90, 93, 96],
  tickets_per_1k: [1.2, 1.6, 2.0, 2.6, 3.5, 5],
  avg_rx_power_dbm: [-26, -24.5, -23, -22, -21, -20],
};

export function makeScale(values, palette, better = 'high', k = 7, metricKey = null) {
  const ramp = rampFor(palette);
  const breaks = (metricKey && FIXED_BREAKS[metricKey]) || quantileBreaks(values, k);
  const invert = palette === 'div' && better === 'low';
  const colors = invert ? [...ramp].reverse() : ramp;
  const fn = (x) => {
    if (x === null || x === undefined || !Number.isFinite(x)) return [0, 0, 0, 0];
    let i = 0;
    while (i < breaks.length && x >= breaks[i]) i++;
    return colors[i];
  };
  return { fn, breaks, colors };
}

export const toCss = (c, a = 1) => `rgba(${c[0]},${c[1]},${c[2]},${a})`;
