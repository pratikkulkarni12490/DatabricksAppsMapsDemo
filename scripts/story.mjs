// Scripted end-to-end walkthrough of the deployed app in one headless Chrome session (bearer token injected for app URLs only).
// Usage: node scripts/story.mjs <steps.json> <token> <outDir>
// Steps: {name, pre?:ms, js?, click?:[x,y], findClick?:{points,until}, exec?:"shell cmd", wait?:ms, shot?:"file.png", expect?:"js returning true"}
// findClick hovers each candidate point until the `until` js is true (e.g. a hexagon tooltip), then clicks there.
import { spawn, execSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
// VIDEO=<dir> records the session (CDP screencast) and writes <dir>/frames + concat.txt for ffmpeg.
// Step extras for recordings: caption:"text" (bottom caption bar), card:{title,sub,ms} (full-screen title card).
const VIDEO = process.env.VIDEO;
const frames = [];

const [stepsFile, token, outDir] = process.argv.slice(2);
const { url, steps } = JSON.parse(readFileSync(stepsFile, 'utf8'));
mkdirSync(outDir, { recursive: true });
const port = 9333 + Math.floor(Math.random() * 600);
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=/tmp/geolens-story-${port}`, '--window-size=1680,1000',
  '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--no-first-run', 'about:blank',
], { stdio: 'ignore' });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let target;
for (let i = 0; i < 40 && !target; i++) {
  await sleep(250);
  try { target = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find((t) => t.type === 'page'); } catch {}
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let id = 0;
const pending = new Map();
let errors = [];
const appRequests = { n: 0, failed: 0, ms: [] };
const started = new Map();
ws.onmessage = (m) => {
  const d = JSON.parse(m.data);
  if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); }
  if (d.method === 'Page.screencastFrame') {
    const f = `${VIDEO}/frames/${String(frames.length).padStart(6, '0')}.jpg`;
    writeFileSync(f, Buffer.from(d.params.data, 'base64'));
    frames.push({ f, t: d.params.metadata.timestamp });
    ws.send(JSON.stringify({ id: ++id, method: 'Page.screencastFrameAck', params: { sessionId: d.params.sessionId } }));
  }
  if (d.method === 'Fetch.requestPaused') {
    const h = Object.entries(d.params.request.headers).map(([name, value]) => ({ name, value }));
    h.push({ name: 'Authorization', value: `Bearer ${token}` });
    ws.send(JSON.stringify({ id: ++id, method: 'Fetch.continueRequest', params: { requestId: d.params.requestId, headers: h } }));
  }
  if (d.method === 'Network.requestWillBeSent' && d.params.request.url.includes('/api/')) started.set(d.params.requestId, d.params.timestamp);
  if (d.method === 'Network.loadingFinished' && started.has(d.params.requestId)) {
    appRequests.n++; appRequests.ms.push(1000 * (d.params.timestamp - started.get(d.params.requestId))); started.delete(d.params.requestId);
  }
  if (d.method === 'Runtime.consoleAPICalled' && d.params.type === 'error')
    errors.push(`console.error: ${d.params.args.map((a) => a.value ?? a.description).join(' ').slice(0, 300)}`);
  if (d.method === 'Runtime.exceptionThrown') errors.push(`exception: ${d.params.exceptionDetails.exception?.description?.slice(0, 300)}`);
  if (d.method === 'Network.loadingFailed' && !d.params.canceled && started.has(d.params.requestId)) { appRequests.failed++; errors.push(`netfail: ${d.params.errorText}`); }
  if (d.method === 'Network.responseReceived' && d.params.response.status >= 400 && d.params.response.url.includes('databricksapps'))
    errors.push(`http ${d.params.response.status}: ${d.params.response.url.slice(0, 140)}`);
};
const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const evalJs = async (expr) => {
  const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
  return r.result?.exceptionDetails ? `EXCEPTION ${r.result.exceptionDetails.exception?.description || r.result.exceptionDetails.text}` : r.result?.result?.value;
};
const PRELUDE = `window.sleep=(ms)=>new Promise(r=>setTimeout(r,ms));
window.tick=(t)=>{const r=[...document.querySelectorAll('.layer-row')].find(x=>x.querySelector('.layer-title').textContent.startsWith(t)); r.querySelector('input[type=checkbox]').click(); return true;};
window.setSel=(sel,v)=>{const s=document.querySelector(sel); Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value').set.call(s,v); s.dispatchEvent(new Event('change',{bubbles:true})); return s.selectedOptions[0]?.text;};
window.byText=(sel,t)=>[...document.querySelectorAll(sel)].find(e=>e.textContent.includes(t));
window.clickText=(sel,t)=>{const e=byText(sel,t); if(!e) return 'missing '+t; e.click(); return true;};
window.txt=(sel)=>document.querySelector(sel)?.textContent?.trim();
window.caption=(t)=>{let c=document.getElementById('__cap'); if(!c){c=document.createElement('div'); c.id='__cap'; c.style.cssText='position:fixed;left:50%;bottom:22px;transform:translateX(-50%);z-index:99999;background:rgba(17,17,16,.88);color:#fff;font:600 19px/1.35 Inter,system-ui,sans-serif;padding:10px 20px;border-radius:12px;max-width:1100px;text-align:center;box-shadow:0 6px 24px rgba(0,0,0,.4);pointer-events:none'; document.body.appendChild(c);} c.textContent=t; c.style.display=t?'block':'none'; return true;};
window.cursorAt=(x,y)=>{let c=document.getElementById('__cur'); if(!c){c=document.createElement('div'); c.id='__cur'; c.style.cssText='position:fixed;z-index:99998;width:22px;height:22px;margin:-11px 0 0 -11px;border-radius:50%;border:3px solid #fff;background:rgba(42,120,214,.85);box-shadow:0 0 0 2px rgba(0,0,0,.35);pointer-events:none;transition:left .6s ease,top .6s ease'; document.body.appendChild(c);} c.style.left=x+'px'; c.style.top=y+'px'; const r=document.createElement('div'); r.style.cssText='position:fixed;z-index:99997;left:'+x+'px;top:'+y+'px;width:16px;height:16px;margin:-8px 0 0 -8px;border-radius:50%;border:3px solid rgba(42,120,214,.9);pointer-events:none;transition:all .7s ease-out'; document.body.appendChild(r); setTimeout(()=>{r.style.transform='scale(4)';r.style.opacity='0';},700); setTimeout(()=>r.remove(),1600); return true;};
window.cursorTo=(el)=>{const b=el.getBoundingClientRect(); cursorAt(b.left+b.width/2,b.top+b.height/2); return el;};
window.card=(title,sub)=>{let c=document.getElementById('__card'); if(!c){c=document.createElement('div'); c.id='__card'; document.body.appendChild(c);} c.style.cssText='position:fixed;inset:0;z-index:100000;display:flex;flex-direction:column;align-items:center;justify-content:center;background:#1b3139;color:#fff;font-family:Inter,system-ui,sans-serif;text-align:center;padding:60px'; c.innerHTML='<div style="font-size:15px;letter-spacing:3px;text-transform:uppercase;color:#86b6ef;margin-bottom:18px">GeoLens · Jio Fiber Control Center</div><div style="font-size:46px;font-weight:700;max-width:1200px;line-height:1.15">'+title+'</div><div style="font-size:22px;margin-top:20px;color:#c3c2b7;max-width:1100px">'+(sub||'')+'</div>'; return true;};
window.uncard=()=>{document.getElementById('__card')?.remove(); return true;};`;

await send('Network.enable');
await send('Runtime.enable');
await send('Fetch.enable', { patterns: [{ urlPattern: '*databricksapps.com*' }] });
await send('Emulation.setDeviceMetricsOverride', { width: 1680, height: 1000, deviceScaleFactor: 1, mobile: false });
const t0 = Date.now();
if (VIDEO) { mkdirSync(`${VIDEO}/frames`, { recursive: true }); await send('Page.startScreencast', { format: 'jpeg', quality: 82, maxWidth: 1680, maxHeight: 1000, everyNthFrame: 1 }); }
await send('Page.navigate', { url });
const results = [];
for (const s of steps) {
  const st = Date.now();
  errors = [];
  let value = null;
  try {
    if (s.pre) await sleep(s.pre);
    if (s.reload) { await send('Page.navigate', { url }); }
    if (s.exec) value = execSync(s.exec, { encoding: 'utf8', timeout: 600000 }).trim().slice(-300);
    if (s.card) { await evalJs(PRELUDE); await evalJs(`card(${JSON.stringify(s.card.title)}, ${JSON.stringify(s.card.sub || '')})`); await sleep(s.card.ms || 4000); if (!s.card.keep) await evalJs('uncard()'); }
    if (s.caption !== undefined) { await evalJs(PRELUDE); await evalJs(`caption(${JSON.stringify(s.caption)})`); }
    if (s.js) { await evalJs(PRELUDE); value = await evalJs(s.js); }
    if (s.click) {
      const [x, y] = s.click;
      if (VIDEO) { await evalJs(PRELUDE); await evalJs(`cursorAt(${x},${y})`); await sleep(700); }
      await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
      await send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1 });
      await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1 });
    }
    if (s.findClick) {
      let hit = null;
      for (const [x, y] of s.findClick.points) {
        await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
        await sleep(350);
        await evalJs(PRELUDE);
        if ((await evalJs(s.findClick.until)) === true) { hit = [x, y]; break; }
      }
      if (hit) {
        if (VIDEO) { await evalJs(`cursorAt(${hit[0]},${hit[1]})`); await sleep(700); }
        await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: hit[0], y: hit[1], button: 'left', clickCount: 1 });
        await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: hit[0], y: hit[1], button: 'left', clickCount: 1 });
      }
      value = { ...(typeof value === 'object' && value ? value : { js: value }), clickedAt: hit };
    }
    if (s.wait) await sleep(s.wait);
  } catch (e) { value = `ERROR ${e.message}`; }
  let pass = true;
  if (s.expect) { await evalJs(PRELUDE); const ok = await evalJs(s.expect); pass = ok === true; if (!pass) value = { value, expectResult: ok }; }
  if (s.shot) {
    const shot = await send('Page.captureScreenshot', { format: 'png' });
    writeFileSync(`${outDir}/${s.shot}`, Buffer.from(shot.result.data, 'base64'));
  }
  const r = { step: s.name, pass: pass && !String(value ?? '').startsWith('ERROR') && !String(value ?? '').startsWith('EXCEPTION'), secs: ((Date.now() - st) / 1000).toFixed(1), value, errors: [...errors], shot: s.shot || null };
  results.push(r);
  console.log(`${r.pass ? 'PASS' : 'FAIL'} ${r.step} (${r.secs}s) ${JSON.stringify(value ?? '').slice(0, 220)}${errors.length ? '  errors=' + JSON.stringify(errors).slice(0, 300) : ''}`);
}
if (VIDEO) {
  await send('Page.stopScreencast');
  // frames arrive only when the screen changes: hold each one until the next (ffmpeg concat demuxer)
  const lines = [];
  for (let i = 0; i < frames.length; i++) {
    const dur = i + 1 < frames.length ? Math.max(0.01, frames[i + 1].t - frames[i].t) : 2;
    lines.push(`file '${frames[i].f}'`, `duration ${dur.toFixed(3)}`);
  }
  if (frames.length) lines.push(`file '${frames[frames.length - 1].f}'`);
  writeFileSync(`${VIDEO}/concat.txt`, lines.join('\n'));
  console.log(`VIDEO frames=${frames.length}`);
}
const ms = appRequests.ms.sort((a, b) => a - b);
const pct = (p) => (ms.length ? Math.round(ms[Math.min(ms.length - 1, Math.floor(p * ms.length))]) : null);
const summary = { total_secs: (Date.now() - t0) / 1000, api_requests: appRequests.n, api_failed: appRequests.failed, api_p50_ms: pct(0.5), api_p95_ms: pct(0.95) };
console.log('SUMMARY ' + JSON.stringify(summary));
writeFileSync(`${outDir}/results.json`, JSON.stringify({ summary, results }, null, 2));
ws.close();
chrome.kill();
process.exit(0);
