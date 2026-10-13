import React, { useRef, useState, useEffect } from 'react';
import { postJSON } from '../api';

const SUGGESTIONS = {
  retail: [
    'Where should we open the next Trends store in Bengaluru?',
    'Which Mumbai stores are underperforming on revenue per sq ft?',
    'Show me high-affluence pockets in Delhi NCR with low Reliance penetration',
  ],
  fiber: [
    'Which OLTs will run out of capacity first and where are they?',
    'Where is network health worst this week and why?',
    'Show open P1 incidents and the homes impacted',
  ],
};

export function ChatPanel({ solution, getState, applyActions, beside = false }) {
  const [open, setOpen] = useState(false);
  const [msgs, setMsgs] = useState([]);
  const [q, setQ] = useState('');
  const [busy, setBusy] = useState(false);
  const endRef = useRef(null);
  useEffect(() => { endRef.current?.scrollIntoView({ behavior: 'smooth' }); }, [msgs, busy]);
  useEffect(() => { setMsgs([]); }, [solution]);

  const ask = async (text) => {
    const question = (text ?? q).trim();
    if (!question || busy) return;
    setQ('');
    const history = msgs.map((m) => ({ role: m.role, content: m.text }));
    setMsgs((m) => [...m, { role: 'user', text: question }]);
    setBusy(true);
    try {
      const r = await postJSON('/api/agent', { question, solution, state: getState(), history });
      setMsgs((m) => [...m, { role: 'assistant', text: r.answer, actions: r.actions, trace: r.trace }]);
      applyActions(r.actions || []);
    } catch (e) {
      setMsgs((m) => [...m, { role: 'assistant', text: `Sorry, that failed: ${String(e).slice(0, 200)}` }]);
    } finally {
      setBusy(false);
    }
  };

  if (!open) {
    return <button className="chat-fab" onClick={() => setOpen(true)}>✦ Ask GeoLens</button>;
  }
  return (
    <div className={`chat-panel ${beside ? 'beside-drawer' : ''}`} role="dialog" aria-label="Ask GeoLens">
      <div className="chat-head">
        <span>✦ Ask GeoLens <span className="muted">· {solution === 'retail' ? 'Retail' : 'Jio Fiber'}</span></span>
        <button className="icon-btn" onClick={() => setOpen(false)} aria-label="Close chat">×</button>
      </div>
      <div className="chat-body">
        {!msgs.length && (
          <div className="chat-suggest">
            <div className="muted">Ask in plain language. GeoLens queries Lakebase within your access scope and updates the map.</div>
            {SUGGESTIONS[solution].map((s) => <button key={s} className="suggest" onClick={() => ask(s)}>{s}</button>)}
          </div>
        )}
        {msgs.map((m, i) => (
          <div key={i} className={`msg ${m.role}`}>
            <div>{m.text}</div>
            {m.actions && m.actions.length > 0 && (
              <div className="msg-actions">{m.actions.map((a, j) => <span key={j} className="chip static">{describe(a)}</span>)}</div>
            )}
            {m.trace && m.trace.length > 0 && <div className="muted small">{m.trace.map((t) => t.tool).join(' → ')}</div>}
          </div>
        ))}
        {busy && <div className="msg assistant"><span className="spinner" /> analysing…</div>}
        <div ref={endRef} />
      </div>
      <form className="chat-input" onSubmit={(e) => { e.preventDefault(); ask(); }}>
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Ask about the map…" />
        <button className="btn" disabled={busy}>Ask</button>
      </form>
    </div>
  );
}

function describe(a) {
  switch (a.type) {
    case 'add_layer': return `+ ${a.layer_key}${a.metric ? ` (${a.metric})` : ''}`;
    case 'set_metric': return `metric → ${a.metric}`;
    case 'fly_to': return `fly to ${a.metro || `${a.lat?.toFixed?.(2)}, ${a.lon?.toFixed?.(2)}`}`;
    case 'highlight_cells': return `highlight ${a.h3?.length || 0} cells`;
    case 'select_entity': return `open ${a.entity} ${a.id}`;
    case 'remove_layer': return `− ${a.layer_key}`;
    default: return a.type;
  }
}
