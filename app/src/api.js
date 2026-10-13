// Thin API client. The persona header (demo impersonation) and scope key travel with every request; the scope key is also
// in data URLs so the browser HTTP cache never serves one scope's tiles to another.
let persona = '';
let scopeKey = '';

export function setPersona(p) {
  persona = p || '';
}
export function setScopeKey(k) {
  scopeKey = k || '';
}
export function getPersona() {
  return persona;
}
export function getScopeKey() {
  return scopeKey;
}

export function headers(extra = {}) {
  return persona ? { 'X-GeoLens-Persona': persona, ...extra } : extra;
}

export async function getJSON(path) {
  const r = await fetch(path, { headers: headers(), credentials: 'same-origin' });
  if (!r.ok) throw new Error(`${r.status} ${await r.text()}`);
  return r.json();
}

export async function postJSON(path, body) {
  const r = await fetch(path, {
    method: 'POST',
    headers: headers({ 'Content-Type': 'application/json' }),
    body: JSON.stringify(body),
    credentials: 'same-origin',
  });
  if (!r.ok) throw new Error(`${r.status} ${await r.text()}`);
  return r.json();
}

export function columnar(payload) {
  if (!payload || !payload.cols) return [];
  const { cols, rows } = payload;
  return rows.map((r) => {
    const o = {};
    for (let i = 0; i < cols.length; i++) o[cols[i]] = r[i];
    return o;
  });
}
