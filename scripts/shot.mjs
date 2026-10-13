// Headless Chrome via CDP with a bearer token header: screenshot the deployed app and collect console errors.
// Usage: node scripts/shot.mjs <url> <token> <out.png> [waitMs] [jsToRunBeforeShot]
import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';

const [url, token, out, waitMs = '14000', js = ''] = process.argv.slice(2);
const port = 9333 + Math.floor(Math.random() * 600); // unique per run so parallel shots don't share a browser
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=/tmp/geolens-chrome-${port}`, '--window-size=1680,1000',
  '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--no-first-run', 'about:blank',
], { stdio: 'ignore' });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let target;
for (let i = 0; i < 40 && !target; i++) {
  await sleep(250);
  try {
    const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
    target = list.find((t) => t.type === 'page');
  } catch {}
}
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let id = 0;
const pending = new Map();
const logs = [];
ws.onmessage = (m) => {
  const d = JSON.parse(m.data);
  if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); }
  if (d.method === 'Fetch.requestPaused') {
    const h = Object.entries(d.params.request.headers).map(([name, value]) => ({ name, value }));
    h.push({ name: 'Authorization', value: `Bearer ${token}` });
    ws.send(JSON.stringify({ id: ++id, method: 'Fetch.continueRequest', params: { requestId: d.params.requestId, headers: h } }));
  }
  if (d.method === 'Runtime.consoleAPICalled' && ['error', 'warning'].includes(d.params.type))
    logs.push(`${d.params.type}: ${d.params.args.map((a) => a.value ?? a.description).join(' ').slice(0, 300)}`);
  if (d.method === 'Runtime.exceptionThrown') logs.push(`exception: ${d.params.exceptionDetails.exception?.description?.slice(0, 400)}`);
  if (d.method === 'Network.loadingFailed' && !d.params.canceled) logs.push(`netfail: ${d.params.errorText}`);
  if (d.method === 'Network.responseReceived' && d.params.response.status >= 400)
    logs.push(`http ${d.params.response.status}: ${d.params.response.url.slice(0, 160)}`);
};
const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });

await send('Network.enable');
await send('Runtime.enable');
// add the bearer only to app requests (adding it to the basemap CDN breaks CORS)
await send('Fetch.enable', { patterns: [{ urlPattern: '*databricksapps.com*' }] });
await send('Emulation.setDeviceMetricsOverride', { width: 1680, height: 1000, deviceScaleFactor: 1, mobile: false });
await send('Page.navigate', { url });
await sleep(Number(waitMs));
if (js) {
  const r = await send('Runtime.evaluate', { expression: js, awaitPromise: true, returnByValue: true });
  logs.push(`js: ${JSON.stringify(r.result?.result?.value ?? r.result?.exceptionDetails?.text).slice(0, 500)}`);
  await sleep(6000);
}
// CLICKS="x,y;x,y" → real mouse clicks (page coords), 7 s apart, after the JS step
for (const pt of (process.env.CLICKS || '').split(';').filter(Boolean)) {
  const [x, y] = pt.split(',').map(Number);
  await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
  await send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', clickCount: 1 });
  await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', clickCount: 1 });
  await sleep(7000);
}
const shot = await send('Page.captureScreenshot', { format: 'png' });
writeFileSync(out, Buffer.from(shot.result.data, 'base64'));
console.log(logs.slice(0, 40).join('\n') || 'no console errors');
ws.close();
chrome.kill();
process.exit(0);
