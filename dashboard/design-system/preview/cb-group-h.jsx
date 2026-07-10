// preview/cb-group-h.jsx
// Track 4 · COGNITION PLANE
// K1 Keeper Inspector v2 · K2 Decisions/Memory · K3 Institution Episodes

const P2h = window.MASC_P2;

function KeeperTabs({ keepers, sel, onSelect, label }) {
  return (
    <div className="ki-tabs" role="tablist" aria-label={label}>
      {keepers.map(kp => (
        <button key={kp.id}
                type="button"
                role="tab"
                aria-selected={sel === kp.id}
                tabIndex={sel === kp.id ? 0 : -1}
                aria-label={`Keeper ${kp.id}`}
                className={sel === kp.id ? 'on' : ''}
                onClick={() => onSelect(kp.id)}>
          <KeeperBadge id={kp.id} variant="sigil" size="sm" /> <span aria-hidden="true">{kp.id}</span>
        </button>
      ))}
    </div>
  );
}

// K1-A · Tool access + runtime config
function KeeperToolAccess() {
  const [sel, setSel] = useState('sangsu');
  const k = P2h.keepersFull.find(kp => kp.id === sel);
  const rows = [
    { lbl: 'runtime',         v: k.runtime },
    { lbl: 'tools_preset',    v: k.tools_preset },
    { lbl: 'sandbox',         v: k.sandbox },
    { lbl: 'network',         v: k.network },
    { lbl: 'auto_handoff',    v: String(k.auto_handoff), cls: k.auto_handoff ? 'on' : 'off' },
    { lbl: 'handoff_threshold', v: `${(k.handoff_threshold * 100).toFixed(0)}%` },
    { lbl: 'proactive_idle',  v: `${k.proactive_idle_sec}s` },
    { lbl: 'mention targets', v: null, mentions: k.mention },
  ];
  return (
    <section aria-label="Keeper tool access and runtime config" style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <KeeperTabs keepers={P2h.keepersFull} sel={sel} onSelect={setSel} label="Select keeper for tool access" />
      <dl className="ki-access" role="tabpanel" aria-label={`Tool access for ${k.id}`}>
        {rows.map(r => (
          <div key={r.lbl} className="row">
            <dt className="lbl">{r.lbl}</dt>
            <dd className={`v ${r.cls || ''}`}>
              {r.mentions
                ? r.mentions.map(m => <span key={m} className="mention">@{m}</span>)
                : r.v}
            </dd>
          </div>
        ))}
      </dl>
    </section>
  );
}

// K1-B · Token / handoff stats
function KeeperTokenStats() {
  const keepers = P2h.keepersFull;
  const maxIn  = Math.max(...keepers.map(k => k.tokens.in));
  return (
    <section aria-label={`Token usage across ${keepers.length} keepers · ${(keepers.reduce((s,k)=>s+k.tokens.in,0)/1e6).toFixed(2)}M total in`} style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <div role="heading" aria-level={3} style={{padding:'4px 8px',background:'var(--color-bg-panel-alt)',border:'1px solid var(--color-border-strong)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--color-fg-disabled)',display:'flex',gap:'12px'}}>
        <span>token usage · all keepers</span>
        <span style={{marginLeft:'auto',color:'var(--color-accent-fg)'}}>
          {(keepers.reduce((s,k)=>s+k.tokens.in,0)/1e6).toFixed(2)}M in total
        </span>
      </div>
      <table className="ki-stats" aria-label="Per-keeper token usage">
        <thead>
          <tr className="hdr">
            <th scope="col">keeper</th><th scope="col">in tok</th><th scope="col">out tok</th><th scope="col">in distribution</th>
          </tr>
        </thead>
        <tbody>
          {[...keepers].sort((a,b) => b.tokens.in - a.tokens.in).map(k => (
            <tr key={k.id} className="row">
              <th scope="row" className="ag"><KeeperBadge id={k.id} variant="sigil" size="sm" /> <span aria-hidden="true">{k.id}</span></th>
              <td className="num">{(k.tokens.in/1000).toFixed(0)}k</td>
              <td className="num">{(k.tokens.out/1000).toFixed(1)}k</td>
              <td className="bar" aria-hidden="true"><i style={{width:`${k.tokens.in/maxIn*100}%`}} /></td>
            </tr>
          ))}
        </tbody>
      </table>
      <div role="list" aria-label="Token totals" style={{display:'grid',gridTemplateColumns:'repeat(3,1fr)',gap:'1px',background:'var(--color-border-default)',border:'1px solid var(--color-border-strong)'}}>
        {[
          { lbl:'Total In', v:`${(keepers.reduce((s,k)=>s+k.tokens.in,0)/1e6).toFixed(2)}M` },
          { lbl:'Total Out', v:`${(keepers.reduce((s,k)=>s+k.tokens.out,0)/1000).toFixed(0)}k` },
          { lbl:'Keepers', v:keepers.length },
        ].map(c => (
          <div key={c.lbl} role="listitem" aria-label={`${c.lbl}: ${c.v}`} style={{background:'var(--color-bg-surface)',padding:'6px 10px',display:'flex',flexDirection:'column',gap:'2px'}}>
            <span aria-hidden="true" style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--color-fg-disabled)'}}>{c.lbl}</span>
            <span aria-hidden="true" style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-14)',color:'var(--color-accent-fg)',fontVariantNumeric:'tabular-nums'}}>{c.v}</span>
          </div>
        ))}
      </div>
    </section>
  );
}

// ═════════════════════════════════════════════════════════════════
// K2 · DECISIONS / MEMORY
// ═════════════════════════════════════════════════════════════════

function DecisionsStream() {
  const [filter, setFilter] = useState('all');
  const keepers = ['all', ...new Set(P2h.decisions.map(d => d.keeper))];
  const rows = filter === 'all' ? P2h.decisions : P2h.decisions.filter(d => d.keeper === filter);
  return (
    <section aria-label={`Decisions stream · ${rows.length} entries${filter !== 'all' ? ` · filtered by ${filter}` : ''}`} style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <div role="toolbar" aria-label="Decisions filter" style={{padding:'4px 8px',background:'var(--color-bg-panel-alt)',border:'1px solid var(--color-border-strong)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--color-fg-disabled)',display:'flex',alignItems:'center',gap:'6px'}}>
        <span aria-hidden="true">decisions.jsonl</span>
        <span role="radiogroup" aria-label="Filter by keeper" style={{marginLeft:'auto',display:'flex',gap:'2px'}}>
          {keepers.map(k => (
            <button key={k} type="button" role="radio" aria-checked={filter===k} onClick={() => setFilter(k)}
              style={{padding:'1px 6px',background: filter===k ? 'var(--color-accent-fg-dim)' : 'var(--color-bg-surface)',border:'1px solid var(--color-border-strong)',color: filter===k ? 'var(--color-accent-fg)' : 'var(--color-fg-muted)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',cursor:'pointer'}}>
              {k}
            </button>
          ))}
        </span>
      </div>
      <div role="log" aria-live="polite" aria-label={`${rows.length} decisions`} style={{background:'var(--color-bg-page)',border:'1px solid var(--color-border-default)'}}>
        {rows.map(d => (
          <div key={d.id} className="dec-row" role="listitem" aria-label={`${d.ts.slice(11,19)} · ${d.keeper} · ${d.outcome} · ${d.channel} via ${d.surface}${d.blocker ? ' · blocker ' + d.blocker : ''} · ${d.summary} · ${(d.latency_ms/1000).toFixed(1)}s`}>
            <span className="ts" aria-hidden="true">{d.ts.slice(11,19)}</span>
            <span className="kpr" aria-hidden="true">{d.keeper}</span>
            <span className={`out ${d.outcome}`} aria-hidden="true">{d.outcome}</span>
            <div className="body" aria-hidden="true">
              <span className="act">
                {d.channel} · {d.surface}
              </span>
              {d.blocker && <span className="blk">⚠ {d.blocker}</span>}
              <span className="summary">↳ {d.summary}</span>
              <span className="lat">{(d.latency_ms/1000).toFixed(1)}s</span>
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

function MemoryEntries() {
  const [tag, setTag] = useState('all');
  const tags = ['all', 'verified', 'learned', 'observed', 'plan'];
  const rows = tag === 'all' ? P2h.memoryEntries : P2h.memoryEntries.filter(m => m.tag === tag);
  return (
    <section aria-label={`Memory entries · ${rows.length} rows${tag !== 'all' ? ` · tag ${tag}` : ''}`} style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <div role="toolbar" aria-label="Memory tag filter" style={{padding:'4px 8px',background:'var(--color-bg-panel-alt)',border:'1px solid var(--color-border-strong)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--color-fg-disabled)',display:'flex',alignItems:'center',gap:'6px'}}>
        <span aria-hidden="true">memory.jsonl</span>
        <span role="radiogroup" aria-label="Filter by tag" style={{marginLeft:'auto',display:'flex',gap:'2px'}}>
          {tags.map(t => (
            <button key={t} type="button" role="radio" aria-checked={tag===t} onClick={() => setTag(t)}
              style={{padding:'1px 6px',background: tag===t ? 'var(--color-accent-fg-dim)' : 'var(--color-bg-surface)',border:'1px solid var(--color-border-strong)',color: tag===t ? 'var(--color-accent-fg)' : 'var(--color-fg-muted)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',cursor:'pointer'}}>
              {t}
            </button>
          ))}
        </span>
      </div>
      <div role="list" aria-label={`${rows.length} memory entries`} style={{background:'var(--color-bg-page)',border:'1px solid var(--color-border-default)'}}>
        {rows.length > 0 ? rows.map((m, i) => (
          <div key={i} className="mem-row" role="listitem" aria-label={`${m.at.slice(11,19)} · ${m.keeper} · ${m.tag} · ${m.body}`}>
            <span className="ts" aria-hidden="true">{m.at.slice(11,19)}</span>
            <span className="kpr" aria-hidden="true">{m.keeper}</span>
            <span className={`tag ${m.tag}`} aria-hidden="true">{m.tag}</span>
            <span className="body" aria-hidden="true">{m.body}</span>
          </div>
        )) : (
          <div role="status" style={{padding:'12px 8px',fontFamily:'var(--font-mono)',fontSize:'var(--fs-11)',color:'var(--color-fg-disabled)',textAlign:'center'}}>
            no entries for tag "{tag}"
          </div>
        )}
      </div>
    </section>
  );
}

// ═════════════════════════════════════════════════════════════════
// K3 · INSTITUTION EPISODES
// ═════════════════════════════════════════════════════════════════

function EpisodeCards() {
  const [open, setOpen] = useState('ep-tm-t5');
  return (
    <section aria-label={`Institution episodes · ${P2h.episodes.length} episodes`} style={{display:'flex',flexDirection:'column',gap:'0'}}>
      <div role="heading" aria-level={3} style={{padding:'4px 8px',background:'var(--color-bg-panel-alt)',border:'1px solid var(--color-border-strong)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--color-fg-disabled)',display:'flex',gap:'8px',marginBottom:'4px'}}>
        <span>institution_episodes.jsonl</span>
        <span style={{marginLeft:'auto',color:'var(--color-accent-fg)'}}>{P2h.episodes.length} episodes</span>
      </div>
      <div role="list" aria-label="Episode cards">
        {P2h.episodes.map(ep => {
          const isOpen = open === ep.id;
          return (
            <article key={ep.id}
                     role="listitem"
                     aria-label={`${ep.id} · ${ep.ts.slice(11,19)} · ${ep.participants.join(', ')} · ${ep.outcome} · ${ep.summary}`}
                     aria-expanded={isOpen}
                     tabIndex={0}
                     onClick={() => setOpen(isOpen ? null : ep.id)}
                     onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); setOpen(isOpen ? null : ep.id); } }}
                     className="ep-card"
                     style={{cursor:'pointer'}}>
              <div className="h" aria-hidden="true">
                <span className="id">{ep.id}</span>
                <span className="ts">{ep.ts.slice(11,19)}</span>
                <div className="pp">
                  {ep.participants.map(p => <span key={p} className="p">{p}</span>)}
                </div>
                <span className="oc">{ep.outcome}</span>
              </div>
              <div className="sm" aria-hidden="true">{ep.summary}</div>
              {isOpen && (
                <div className="lns" role="list" aria-label="Learnings">
                  {ep.learnings.map((l, i) => (
                    <div key={i} className="ln" role="listitem">{l}</div>
                  ))}
                </div>
              )}
            </article>
          );
        })}
      </div>
    </section>
  );
}

function EpisodeLearnings() {
  return (
    <section aria-label="Episode learnings · grouped by episode" className="ep-learn">
      {P2h.episodes.map(ep => (
        <div key={ep.id} className="grp" role="group" aria-label={`${ep.id} · ${ep.participants.join(' + ')} · ${ep.learnings.length} learnings`}>
          <div className="grp-h" role="heading" aria-level={4}>
            <span aria-hidden="true">{ep.id}</span>
            <span aria-hidden="true" style={{color:'var(--color-fg-disabled)'}}>·</span>
            <span aria-hidden="true">{ep.participants.join(' + ')}</span>
            <span aria-hidden="true" style={{marginLeft:'auto',color:'var(--color-accent-fg)'}}>{ep.learnings.length} learnings</span>
          </div>
          <ul role="list" aria-label={`Learnings from ${ep.id}`} style={{listStyle:'none', margin:0, padding:0}}>
            {ep.learnings.map((l, i) => (
              <li key={i} className="item">{l}</li>
            ))}
          </ul>
        </div>
      ))}
    </section>
  );
}

Object.assign(window, {
  KeeperToolAccess, KeeperTokenStats,
  DecisionsStream, MemoryEntries,
  EpisodeCards, EpisodeLearnings,
});
