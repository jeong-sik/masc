// preview/cb-group-h.jsx
// Track 4 · COGNITION PLANE
// K1 Keeper Inspector v2 · K2 Decisions/Memory · K3 Institution Episodes · K4 Autoresearch

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
          <Dot kind={kClass(kp.id)} size="sm" /> <span aria-hidden="true">{kp.id}</span>
        </button>
      ))}
    </div>
  );
}

// K1-A · BDI Panel
function KeeperBDIPanel() {
  const [sel, setSel] = useState('sangsu');
  const k = P2h.keepersFull.find(kp => kp.id === sel);
  return (
    <section aria-label="Keeper BDI panel · will, needs, desires" style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <KeeperTabs keepers={P2h.keepersFull} sel={sel} onSelect={setSel} label="Select keeper for BDI panel" />
      <div role="tabpanel" aria-label={`BDI panel for ${k.id}`}>
        <div role="region" aria-label={`${k.id} · ${k.role} · social model ${k.social_model}`} style={{padding:'4px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',display:'flex',alignItems:'center',gap:'8px',fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',color:'var(--fg-3)'}}>
          <Dot kind={kClass(k.id)} beat />
          <span aria-hidden="true" style={{color:'var(--brass-1)'}}>{k.id}</span>
          <span aria-hidden="true">·</span>
          <span aria-hidden="true">{k.role}</span>
          <span aria-hidden="true" style={{marginLeft:'auto',color:'var(--fg-4)',fontSize:'var(--fs-9)'}}>social · {k.social_model}</span>
        </div>
        <dl className="ki-bdi" aria-label="BDI attributes">
          {[['will', k.will], ['needs', k.needs], ['desires', k.desires]].map(([lbl, v]) => (
            <div key={lbl} className="row">
              <dt className="lbl">{lbl}</dt>
              <dd className="v">{v}</dd>
            </div>
          ))}
          <div className="hz">
            <dt className="lbl">short</dt><dd className="v">{k.short_goal}</dd>
            <dt className="lbl">mid</dt>  <dd className="v">{k.mid_goal}</dd>
            <dt className="lbl">long</dt> <dd className="v">{k.long_goal}</dd>
          </div>
        </dl>
      </div>
    </section>
  );
}

// K1-B · Tool access + cascade config
function KeeperToolAccess() {
  const [sel, setSel] = useState('sangsu');
  const k = P2h.keepersFull.find(kp => kp.id === sel);
  const rows = [
    { lbl: 'cascade',         v: k.cascade },
    { lbl: 'tools_preset',    v: k.tools_preset },
    { lbl: 'sandbox',         v: k.sandbox },
    { lbl: 'network',         v: k.network },
    { lbl: 'auto_handoff',    v: String(k.auto_handoff), cls: k.auto_handoff ? 'on' : 'off' },
    { lbl: 'handoff_threshold', v: `${(k.handoff_threshold * 100).toFixed(0)}%` },
    { lbl: 'proactive_idle',  v: `${k.proactive_idle_sec}s` },
    { lbl: 'mention targets', v: null, mentions: k.mention },
  ];
  return (
    <section aria-label="Keeper tool access and cascade config" style={{display:'flex',flexDirection:'column',gap:'6px'}}>
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

// K1-C · Token / handoff stats
function KeeperTokenStats() {
  const keepers = P2h.keepersFull;
  const maxIn  = Math.max(...keepers.map(k => k.tokens.in));
  return (
    <section aria-label={`Token usage across ${keepers.length} keepers · ${(keepers.reduce((s,k)=>s+k.tokens.in,0)/1e6).toFixed(2)}M total in`} style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <div role="heading" aria-level={3} style={{padding:'4px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex',gap:'12px'}}>
        <span>token usage · all keepers</span>
        <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>
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
              <th scope="row" className="ag"><Dot kind={kClass(k.id)} size="sm" /> <span aria-hidden="true">{k.id}</span></th>
              <td className="num">{(k.tokens.in/1000).toFixed(0)}k</td>
              <td className="num">{(k.tokens.out/1000).toFixed(1)}k</td>
              <td className="bar" aria-hidden="true"><i style={{width:`${k.tokens.in/maxIn*100}%`}} /></td>
            </tr>
          ))}
        </tbody>
      </table>
      <div role="list" aria-label="Token totals" style={{display:'grid',gridTemplateColumns:'repeat(3,1fr)',gap:'1px',background:'var(--line-1)',border:'1px solid var(--line-2)'}}>
        {[
          { lbl:'Total In', v:`${(keepers.reduce((s,k)=>s+k.tokens.in,0)/1e6).toFixed(2)}M` },
          { lbl:'Total Out', v:`${(keepers.reduce((s,k)=>s+k.tokens.out,0)/1000).toFixed(0)}k` },
          { lbl:'Keepers', v:keepers.length },
        ].map(c => (
          <div key={c.lbl} role="listitem" aria-label={`${c.lbl}: ${c.v}`} style={{background:'var(--bg-1)',padding:'6px 10px',display:'flex',flexDirection:'column',gap:'2px'}}>
            <span aria-hidden="true" style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)'}}>{c.lbl}</span>
            <span aria-hidden="true" style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-14)',color:'var(--brass-1)',fontVariantNumeric:'tabular-nums'}}>{c.v}</span>
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
      <div role="toolbar" aria-label="Decisions filter" style={{padding:'4px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex',alignItems:'center',gap:'6px'}}>
        <span aria-hidden="true">decisions.jsonl</span>
        <span role="radiogroup" aria-label="Filter by keeper" style={{marginLeft:'auto',display:'flex',gap:'2px'}}>
          {keepers.map(k => (
            <button key={k} type="button" role="radio" aria-checked={filter===k} onClick={() => setFilter(k)}
              style={{padding:'1px 6px',background: filter===k ? 'var(--brass-3)' : 'var(--bg-1)',border:'1px solid var(--line-2)',color: filter===k ? 'var(--brass-1)' : 'var(--fg-3)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',cursor:'pointer'}}>
              {k}
            </button>
          ))}
        </span>
      </div>
      <div role="log" aria-live="polite" aria-label={`${rows.length} decisions`} style={{background:'var(--bg-0)',border:'1px solid var(--line-1)'}}>
        {rows.map(d => (
          <div key={d.id} className="dec-row" role="listitem" aria-label={`${d.ts.slice(11,19)} · ${d.keeper} · ${d.outcome} · ${d.speech_act} via ${d.channel}${d.intention ? ' → ' + d.intention : ''}${d.blocker ? ' · blocker ' + d.blocker : ''}${d.belief ? ' · belief ' + d.belief : ''} · ${(d.latency_ms/1000).toFixed(1)}s`}>
            <span className="ts" aria-hidden="true">{d.ts.slice(11,19)}</span>
            <span className="kpr" aria-hidden="true">{d.keeper}</span>
            <span className={`out ${d.outcome}`} aria-hidden="true">{d.outcome}</span>
            <div className="body" aria-hidden="true">
              <span className="act">
                {d.speech_act} · {d.channel}
                {d.intention && <span style={{color:'var(--fg-2)'}}> → {d.intention}</span>}
              </span>
              {d.blocker && <span className="blk">⚠ {d.blocker}</span>}
              {d.belief  && <span className="bel">↳ {d.belief}</span>}
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
      <div role="toolbar" aria-label="Memory tag filter" style={{padding:'4px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex',alignItems:'center',gap:'6px'}}>
        <span aria-hidden="true">memory.jsonl</span>
        <span role="radiogroup" aria-label="Filter by tag" style={{marginLeft:'auto',display:'flex',gap:'2px'}}>
          {tags.map(t => (
            <button key={t} type="button" role="radio" aria-checked={tag===t} onClick={() => setTag(t)}
              style={{padding:'1px 6px',background: tag===t ? 'var(--brass-3)' : 'var(--bg-1)',border:'1px solid var(--line-2)',color: tag===t ? 'var(--brass-1)' : 'var(--fg-3)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',cursor:'pointer'}}>
              {t}
            </button>
          ))}
        </span>
      </div>
      <div role="list" aria-label={`${rows.length} memory entries`} style={{background:'var(--bg-0)',border:'1px solid var(--line-1)'}}>
        {rows.length > 0 ? rows.map((m, i) => (
          <div key={i} className="mem-row" role="listitem" aria-label={`${m.at.slice(11,19)} · ${m.keeper} · ${m.tag} · ${m.body}`}>
            <span className="ts" aria-hidden="true">{m.at.slice(11,19)}</span>
            <span className="kpr" aria-hidden="true">{m.keeper}</span>
            <span className={`tag ${m.tag}`} aria-hidden="true">{m.tag}</span>
            <span className="body" aria-hidden="true">{m.body}</span>
          </div>
        )) : (
          <div role="status" style={{padding:'12px 8px',fontFamily:'var(--font-mono)',fontSize:'var(--fs-11)',color:'var(--fg-4)',textAlign:'center'}}>
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
      <div role="heading" aria-level={3} style={{padding:'4px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex',gap:'8px',marginBottom:'4px'}}>
        <span>institution_episodes.jsonl</span>
        <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>{P2h.episodes.length} episodes</span>
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
            <span aria-hidden="true" style={{color:'var(--fg-4)'}}>·</span>
            <span aria-hidden="true">{ep.participants.join(' + ')}</span>
            <span aria-hidden="true" style={{marginLeft:'auto',color:'var(--brass-1)'}}>{ep.learnings.length} learnings</span>
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

// ═════════════════════════════════════════════════════════════════
// K4 · AUTORESEARCH
// ═════════════════════════════════════════════════════════════════

function ARLoopList() {
  const confCls = (c) => c >= 0.8 ? 'hi' : c >= 0.5 ? '' : c >= 0.35 ? 'lo' : 'vlo';
  return (
    <section aria-label={`Autoresearch loops · ${P2h.arLoops.filter(l=>l.status==='open').length} open · ${P2h.arLoops.filter(l=>l.status==='closed').length} closed`} style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <div role="heading" aria-level={3} style={{padding:'4px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex',gap:'8px'}}>
        <span>autoresearch loops</span>
        <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>{P2h.arLoops.filter(l=>l.status==='open').length} open · {P2h.arLoops.filter(l=>l.status==='closed').length} closed</span>
      </div>
      <div role="list" aria-label={`${P2h.arLoops.length} autoresearch loops`} style={{background:'var(--bg-0)'}}>
        {P2h.arLoops.map(l => (
          <div key={l.id} className="ar-row" role="listitem" aria-label={`${l.id} · ${l.topic} · owner ${l.owner}${l.branch ? ' · branch ' + l.branch : ''} · ${l.hypotheses}H ${l.evidences}E ${l.conclusions}C · ${l.status} · ${(l.confidence*100).toFixed(0)}% confidence`}>
            <span className="id" aria-hidden="true">{l.id.slice(0,11)}</span>
            <div aria-hidden="true" style={{display:'flex',flexDirection:'column',gap:'2px'}}>
              <span className="topic">{l.topic}</span>
              <span style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',color:'var(--fg-4)'}}>
                owner · {l.owner}
                {l.branch && <span style={{color:'var(--fg-3)'}}> · ⎇ {l.branch}</span>}
                {' · '}{l.hypotheses}H · {l.evidences}E · {l.conclusions}C
              </span>
            </div>
            <span className={`st ${l.status}`} aria-hidden="true">{l.status}</span>
            <span className={`conf ${confCls(l.confidence)}`} aria-hidden="true">{(l.confidence*100).toFixed(0)}%</span>
          </div>
        ))}
      </div>
    </section>
  );
}

function ARFindingCard() {
  const [sel, setSel] = useState('f-001');
  const f = P2h.findings.find(x => x.id === sel);
  return (
    <section aria-label="Autoresearch finding card" style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <div role="tablist" aria-label="Select finding" style={{display:'flex',gap:'2px'}}>
        {P2h.findings.map(x => (
          <button key={x.id} type="button" role="tab" aria-selected={sel===x.id} aria-controls="ar-finding-panel" tabIndex={sel===x.id ? 0 : -1} onClick={() => setSel(x.id)}
            style={{padding:'3px 10px',background: sel===x.id ? 'var(--brass-3)' : 'var(--bg-2)',border:'1px solid var(--line-2)',color: sel===x.id ? 'var(--brass-1)' : 'var(--fg-3)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',cursor:'pointer'}}>
            {x.id}
          </button>
        ))}
      </div>
      <article className="ar-find" id="ar-finding-panel" role="tabpanel" aria-label={`Finding ${f.id} · loop ${f.loop} · ${(f.confidence*100).toFixed(0)}% confidence`}>
        <div className="hdr" aria-hidden="true">
          <span className="id">{f.id}</span>
          <span className="loop">loop · {f.loop}</span>
          <span style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',color:'var(--fg-4)'}}>{f.at.slice(11,19)}</span>
          <span className="conf">{(f.confidence*100).toFixed(0)}% confidence</span>
        </div>
        <section aria-labelledby={`ar-${f.id}-hyp`}>
          <SectionHeading title="hypothesis" level={4} id={`ar-${f.id}-hyp`} />
          <div className="hy">{f.hypothesis}</div>
        </section>
        <section aria-labelledby={`ar-${f.id}-ev`}>
          <SectionHeading title={`evidence (${f.evidence.length})`} level={4} id={`ar-${f.id}-ev`} />
          <ul className="ev-list" role="list" style={{listStyle:'none', margin:0, padding:0}}>
            {f.evidence.map((e, i) => <li key={i} className="ev">{e}</li>)}
          </ul>
        </section>
        <section aria-labelledby={`ar-${f.id}-co`}>
          <SectionHeading title="conclusion" level={4} id={`ar-${f.id}-co`} />
          <div className="co">{f.conclusion}</div>
        </section>
      </article>
    </section>
  );
}

function ARHypothesisFlow() {
  const loop = P2h.arLoops.find(l => l.id === 'ar-78d41e9c');
  const finding = P2h.findings.find(f => f.loop === 'ar-78d41e9c');
  return (
    <section aria-label={`${loop.id} · ${loop.topic} · closed · ${(loop.confidence*100).toFixed(0)}% confidence`} style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <div role="heading" aria-level={3} style={{padding:'4px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex',gap:'8px'}}>
        <span>{loop.id}</span>
        <span style={{color:'var(--fg-3)'}}>· {loop.topic}</span>
        <span style={{marginLeft:'auto',color:'var(--ok-fg)'}}>closed · {(loop.confidence*100).toFixed(0)}% confidence</span>
      </div>
      <ol className="ar-flow" aria-label="Hypothesis to evidence to conclusion flow" style={{listStyle:'none', margin:0, padding:0}}>
        <li className="step">
          <div className="step-h" role="heading" aria-level={4}>
            <span className="step-n" aria-hidden="true">1</span>
            <span className="step-t">Hypothesis</span>
          </div>
          <div className="step-body">{finding.hypothesis}</div>
        </li>
        <li className="connector" aria-hidden="true">↓</li>
        <li className="step">
          <div className="step-h" role="heading" aria-level={4}>
            <span className="step-n" aria-hidden="true">2</span>
            <span className="step-t">Evidence ({finding.evidence.length} items)</span>
          </div>
          <ul role="list" style={{listStyle:'none', margin:0, padding:0}}>
            {finding.evidence.map((e, i) => <li key={i} className="ev">{e}</li>)}
          </ul>
        </li>
        <li className="connector" aria-hidden="true">↓</li>
        <li className="step">
          <div className="step-h" role="heading" aria-level={4}>
            <span className="step-n" aria-hidden="true">3</span>
            <span className="step-t">Conclusion</span>
          </div>
          <div className="ar-con">{finding.conclusion}</div>
        </li>
      </ol>
    </section>
  );
}

Object.assign(window, {
  KeeperBDIPanel, KeeperToolAccess, KeeperTokenStats,
  DecisionsStream, MemoryEntries,
  EpisodeCards, EpisodeLearnings,
  ARLoopList, ARFindingCard, ARHypothesisFlow,
});
