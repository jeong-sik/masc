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
  const [open, setOpen] = useState(true);
  const cur = P2i.branches.find(b => b.name === sel);
  return (
    <section aria-label="Branch selector" style={{display:'flex',flexDirection:'column',gap:'8px'}}>
      <button
        type="button"
        className="br-bar"
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={`Switch branch: ${cur.name}`}
        onClick={() => setOpen(o => !o)}
      >
        <span className="lbl" aria-hidden="true">branch</span>
        <span className="sel" aria-hidden="true">
          <span className="nm">{cur.name}</span>
          <span className="ca">▾</span>
        </span>
        <span className="meta" aria-hidden="true">
          <span className="ah">↑{cur.ahead}</span>
          <span className="bh">↓{cur.behind}</span>
          <span>·</span>
          <span className="head">HEAD {cur.head}</span>
          <span>·</span>
          <span style={{color:'var(--fg-3)'}}>{cur.keepers.length} keepers</span>
        </span>
      </button>

      <div role="heading" aria-level={3} style={{padding:'4px 8px',background:'var(--color-bg-panel-alt)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex',gap:'8px'}}>
        <span aria-hidden="true">switch branch · {P2i.branches.length} known</span>
        <span aria-hidden="true" style={{marginLeft:'auto',color:'var(--brass-1)'}}>active · {sel}</span>
      </div>
      <div className="br-list" role="listbox" aria-label="Available branches">
        {P2i.branches.map(b => {
          const isCurrent = b.name === sel;
          return (
            <div key={b.name}
                 role="option"
                 aria-selected={isCurrent}
                 aria-label={`${b.name} · ${b.tag} · ${b.status} · ${b.ahead} ahead, ${b.behind} behind · HEAD ${b.head}`}
                 tabIndex={0}
                 onClick={() => setSel(b.name)}
                 onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); setSel(b.name); } }}
                 className={`row ${isCurrent ? 'on' : ''}`}>
              <span className="glyph" aria-hidden="true">⎇</span>
              <span className="nm" aria-hidden="true">
                {b.name}
                <span className={`tag ${b.tag}`}>{b.tag}</span>
              </span>
              <span className={`st ${b.status}`} aria-hidden="true">{b.status}</span>
              <span className="ahbh" aria-hidden="true">
                <span className="ah">↑{b.ahead}</span>
                <span className="bh">↓{b.behind}</span>
              </span>
              <span className="head" aria-hidden="true">{b.head}</span>
              <span style={{display:'none'}} aria-hidden="true" />
            </div>
          );
        })}
      </div>
      <div role="list" aria-label={`Active branch keepers · ${cur.keepers.length}`} style={{padding:'5px 10px',background:'var(--color-bg-surface)',border:'1px solid var(--line-1)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',color:'var(--fg-3)',display:'flex',gap:'8px',alignItems:'center'}}>
        <span aria-hidden="true" style={{color:'var(--fg-4)'}}>active branch keepers ·</span>
        {cur.keepers.map(k => (
          <span key={k} role="listitem" aria-label={k} style={{display:'inline-flex',alignItems:'center',gap:'4px'}}>
            <span aria-hidden="true" style={{display:'inline-block',width:'8px',height:'8px',borderRadius:'50%',background:keeperColor(k)}}/>
            <span aria-hidden="true" style={{color:'var(--brass-1)'}}>{k}</span>
          </span>
        ))}
      </div>
    </section>
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
    <section className="km-bar" role="group" aria-label="Keeper filter">
      <div className="h" role="toolbar" aria-label="Keeper filter controls">
        <span className="lbl" aria-hidden="true">keeper filter</span>
        <span className="cnt" aria-live="polite">{sel.size} of {allKeepers.length} selected</span>
        <button type="button" className="clr" aria-label="Clear all keepers" onClick={() => setSel(new Set())}>clear</button>
        <button type="button" className="clr" aria-label="Select all keepers" onClick={() => setSel(new Set(allKeepers.map(k => k.id)))}>all</button>
      </div>
      <div className="km-chips" role="group" aria-label={`${allKeepers.length} keepers · multi-select`}>
        {allKeepers.map(k => {
          const on = sel.has(k.id);
          return (
            <button key={k.id}
                    type="button"
                    role="checkbox"
                    aria-checked={on}
                    aria-label={k.id}
                    onClick={() => toggle(k.id)}
                    className={`km-chip ${on ? 'on' : ''}`}>
              <span aria-hidden="true" style={{display:'inline-block',width:'7px',height:'7px',borderRadius:'50%',background:keeperColor(k.id)}}/>
              <span aria-hidden="true">{k.id}</span>
              <span className="role" aria-hidden="true">· {k.role}</span>
              <span className="x" aria-hidden="true">{on ? '×' : '+'}</span>
            </button>
          );
        })}
      </div>
      <div role="status" aria-live="polite" aria-label={`Filter applied to 8 zones · ${sel.size === 0 ? 'all hidden' : sel.size + '-way scope'}`} style={{padding:'5px 10px',background:'var(--color-bg-panel-alt)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',color:'var(--fg-3)',display:'flex',flexWrap:'wrap',gap:'4px',alignItems:'center'}}>
        <span aria-hidden="true" style={{color:'var(--fg-4)'}}>filter applied to ·</span>
        {['Swimlanes','Activity','Audit','Decisions','Memory','Cost','Stress','Episodes'].map(z => (
          <span key={z} aria-hidden="true" style={{padding:'1px 5px',background:'var(--color-bg-surface)',border:'1px solid var(--line-1)',color:'var(--fg-2)'}}>{z}</span>
        ))}
        <span aria-hidden="true" style={{marginLeft:'auto',color: sel.size === 0 ? 'var(--err-fg)' : 'var(--brass-1)'}}>
          {sel.size === 0 ? '⚠ all hidden' : `→ ${sel.size}-way scope`}
        </span>
      </div>
    </section>
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
    <section aria-label={`Operator nudge log · ${P2i.nudges.length} total · ${P2i.nudges.filter(n => !n.ack).length} pending ack`} style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <div role="heading" aria-level={3} style={{padding:'4px 8px',background:'var(--color-bg-panel-alt)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex',gap:'8px'}}>
        <span>operator · nudge log</span>
        <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>{P2i.nudges.length} nudges · {P2i.nudges.filter(n => !n.ack).length} pending ack</span>
      </div>
      <div role="log" aria-live="polite" aria-label="Operator nudge history" style={{background:'var(--color-bg-page)'}}>
        {P2i.nudges.map(n => (
          <article key={n.id} className="nd-row" aria-label={`${n.at.replace('Z','')} · ${n.channel} · to ${n.to.map(k => '@' + k).join(', ')} · ${n.body} · ${n.ack ? 'acknowledged' : 'pending acknowledgment'}`}>
            <span className="ts" aria-hidden="true">{n.at.replace('Z','')}</span>
            <span className={`ch ${n.channel}`} aria-hidden="true">{n.channel}</span>
            <span className="to" aria-hidden="true">
              {n.to.map(k => <span key={k} className="k">@{k}</span>)}
            </span>
            <span className="body" aria-hidden="true">{n.body}</span>
            <span className={`ack ${n.ack ? 'y' : 'n'}`} aria-hidden="true">{n.ack ? '✓ ack' : '… pending'}</span>
          </article>
        ))}
      </div>
      <form className="nd-compose" aria-label="Compose new nudge" onSubmit={(e) => e.preventDefault()}>
        <div className="h">
          <span className="lbl" id="nudge-compose-label" role="heading" aria-level={4}>new nudge</span>
          <div className="channels" role="radiogroup" aria-label="Nudge channel">
            {['hint','approve','reject','redirect'].map(c => (
              <button key={c} type="button" role="radio" aria-checked={channel === c} className={channel === c ? 'on' : ''} onClick={() => setChannel(c)}>{c}</button>
            ))}
          </div>
        </div>
        <textarea
          aria-label="Compose nudge"
          aria-labelledby="nudge-compose-label"
          aria-multiline="true"
          placeholder="훈수만 두세요 — '실행은 keeper들이 알아서…'"
          value={body}
          onChange={e => setBody(e.target.value)}
        />
        <div className="ft">
          <span className="targets" aria-label={`Sending to ${targets.map(t => '@' + t).join(', ') || 'no targets'}`}>
            <span aria-hidden="true">to · </span>
            <span aria-hidden="true">{targets.map(t => `@${t}`).join(', ') || '<none>'}</span>
          </span>
          <button type="submit" className="send" disabled={!body.trim()} aria-label="Send nudge">send nudge ⏎</button>
        </div>
      </form>
    </section>
  );
}

Object.assign(window, { BranchSelector, KeeperMultiSelect, OperatorNudgeLog });
