// preview/cb-group-i.jsx
// I0 · IDE BACKBONE — game-changer cross-cutting infrastructure.
// Operator just observes & nudges; the cockpit is the IDE for the keepers.
//   I0-A · Branch selector (header bar + branch list)
//   I0-B · Keeper multi-select (chip filter)
//   I0-C · Operator nudge log + compose

const P2i = window.MASC_P2;

// keeper color helper (uses kClass from cb-shared)
function keeperColor(id) {
  return ({
    'nick0cave':     'var(--brass-1)',
    'masc-improver': 'var(--ok)',
    'sangsu':        'var(--info)',
    'qa-king':       'var(--err)',
    'rama':          'var(--stalled)',
    'ramarama':      'var(--stalled)',
    'scholar':       '#9aa6b8',
    'janitor':       '#7a8290',
    'taskmaster':    'var(--brass-3)',
    'velvet-hammer': '#c97070',
    'verdict':       '#b89070',
    'sojin':         '#8aa890',
    'verifier':      '#6a8a9a',
    'executor':      '#a08070',
    'adversary':     '#a06060',
    'issue_king':    '#b08840',
    'codex-mcp-client': '#6a7080',
    'ollama-local':  '#7a9080',
    'scholar2':      '#9aa6b8',
  })[id] || 'var(--idle)';
}

// ═════════════════════════════════════════════════════════════════
// I0-A · BRANCH SELECTOR
// ═════════════════════════════════════════════════════════════════

function BranchSelector() {
  const [sel, setSel] = useState('main');
  const cur = P2i.branches.find(b => b.name === sel);
  return (
    <div style={{display:'flex',flexDirection:'column',gap:'8px'}}>
      {/* header bar — looks like topbar branch widget */}
      <div className="br-bar">
        <span className="lbl">branch</span>
        <span className="sel">
          <span className="nm">{cur.name}</span>
          <span className="ca">▾</span>
        </span>
        <span className="meta">
          <span className="ah">↑{cur.ahead}</span>
          <span className="bh">↓{cur.behind}</span>
          <span>·</span>
          <span className="head">HEAD {cur.head}</span>
          <span>·</span>
          <span style={{color:'var(--fg-3)'}}>{cur.keepers.length} keepers</span>
        </span>
      </div>

      {/* full branch list */}
      <div style={{padding:'4px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex',gap:'8px'}}>
        <span>switch branch · {P2i.branches.length} known</span>
        <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>active · {sel}</span>
      </div>
      <div className="br-list">
        {P2i.branches.map(b => (
          <div key={b.name} className={`row ${b.name === sel ? 'on' : ''}`} onClick={() => setSel(b.name)}>
            <span className="glyph">⎇</span>
            <span className="nm">
              {b.name}
              <span className={`tag ${b.tag}`}>{b.tag}</span>
            </span>
            <span className={`st ${b.status}`}>{b.status}</span>
            <span className="ahbh">
              <span className="ah">↑{b.ahead}</span>
              <span className="bh">↓{b.behind}</span>
            </span>
            <span className="head">{b.head}</span>
            <span style={{display:'none'}} />
          </div>
        ))}
      </div>
      <div style={{padding:'5px 10px',background:'var(--bg-1)',border:'1px solid var(--line-1)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',color:'var(--fg-3)',display:'flex',gap:'8px',alignItems:'center'}}>
        <span style={{color:'var(--fg-4)'}}>active branch keepers ·</span>
        {cur.keepers.map(k => (
          <span key={k} style={{display:'inline-flex',alignItems:'center',gap:'4px'}}>
            <span style={{display:'inline-block',width:'8px',height:'8px',borderRadius:'50%',background:keeperColor(k)}}/>
            <span style={{color:'var(--brass-1)'}}>{k}</span>
          </span>
        ))}
      </div>
    </div>
  );
}

// ═════════════════════════════════════════════════════════════════
// I0-B · KEEPER MULTI-SELECT
// ═════════════════════════════════════════════════════════════════

function KeeperMultiSelect() {
  const allKeepers = P2i.keepersFull.map(k => ({ id: k.id, role: k.role }));
  const [sel, setSel] = useState(new Set(['nick0cave','sangsu']));
  const toggle = (id) => {
    const next = new Set(sel);
    next.has(id) ? next.delete(id) : next.add(id);
    setSel(next);
  };
  return (
    <div className="km-bar">
      <div className="h">
        <span className="lbl">keeper filter</span>
        <span className="cnt">{sel.size} of {allKeepers.length} selected</span>
        <button className="clr" onClick={() => setSel(new Set())}>clear</button>
        <button className="clr" onClick={() => setSel(new Set(allKeepers.map(k => k.id)))}>all</button>
      </div>
      <div className="km-chips">
        {allKeepers.map(k => {
          const on = sel.has(k.id);
          return (
            <span key={k.id} className={`km-chip ${on ? 'on' : ''}`} onClick={() => toggle(k.id)}>
              <span style={{display:'inline-block',width:'7px',height:'7px',borderRadius:'50%',background:keeperColor(k.id)}}/>
              <span>{k.id}</span>
              <span className="role">· {k.role}</span>
              <span className="x">{on ? '×' : '+'}</span>
            </span>
          );
        })}
      </div>
      {/* echo: where this filter applies */}
      <div style={{padding:'5px 10px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',color:'var(--fg-3)',display:'flex',flexWrap:'wrap',gap:'4px',alignItems:'center'}}>
        <span style={{color:'var(--fg-4)'}}>filter applied to ·</span>
        {['Swimlanes','Activity','Audit','Decisions','Memory','Cost','Stress','Episodes'].map(z => (
          <span key={z} style={{padding:'1px 5px',background:'var(--bg-1)',border:'1px solid var(--line-1)',color:'var(--fg-2)'}}>{z}</span>
        ))}
        <span style={{marginLeft:'auto',color: sel.size === 0 ? 'var(--err-fg)' : 'var(--brass-1)'}}>
          {sel.size === 0 ? '⚠ all hidden' : `→ ${sel.size}-way scope`}
        </span>
      </div>
    </div>
  );
}

// ═════════════════════════════════════════════════════════════════
// I0-C · OPERATOR NUDGE LOG (+ compose)
// ═════════════════════════════════════════════════════════════════

function OperatorNudgeLog() {
  const [channel, setChannel] = useState('hint');
  const [body, setBody] = useState('');
  const [targets] = useState(['sangsu']);
  return (
    <div style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <div style={{padding:'4px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex',gap:'8px'}}>
        <span>operator · nudge log</span>
        <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>{P2i.nudges.length} nudges · {P2i.nudges.filter(n => !n.ack).length} pending ack</span>
      </div>
      <div style={{background:'var(--bg-0)'}}>
        {P2i.nudges.map(n => (
          <div key={n.id} className="nd-row">
            <span className="ts">{n.at.replace('Z','')}</span>
            <span className={`ch ${n.channel}`}>{n.channel}</span>
            <span className="to">
              {n.to.map(k => <span key={k} className="k">@{k}</span>)}
            </span>
            <span className="body">{n.body}</span>
            <span className={`ack ${n.ack ? 'y' : 'n'}`}>{n.ack ? '✓ ack' : '… pending'}</span>
          </div>
        ))}
      </div>
      <div className="nd-compose">
        <div className="h">
          <span className="lbl">new nudge</span>
          <div className="channels">
            {['hint','approve','reject','redirect'].map(c => (
              <button key={c} className={channel === c ? 'on' : ''} onClick={() => setChannel(c)}>{c}</button>
            ))}
          </div>
        </div>
        <textarea
          placeholder="훈수만 두세요 — '실행은 keeper들이 알아서…'"
          value={body}
          onChange={e => setBody(e.target.value)}
        />
        <div className="ft">
          <span className="targets">to · {targets.map(t => `@${t}`).join(', ') || '<none>'}</span>
          <button className="send" disabled={!body.trim()}>send nudge ⏎</button>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { BranchSelector, KeeperMultiSelect, OperatorNudgeLog });
