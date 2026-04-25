// preview/cb-group-h.jsx
// Track 4 · COGNITION PLANE
// K1 Keeper Inspector v2 · K2 Decisions/Memory · K3 Institution Episodes · K4 Autoresearch

const P2h = window.MASC_P2;

// ═════════════════════════════════════════════════════════════════
// K1 · KEEPER INSPECTOR v2
// ═════════════════════════════════════════════════════════════════

// K1-A · BDI Panel — will / needs / desires + goal horizons, per-keeper selector
function KeeperBDIPanel() {
  const [sel, setSel] = useState('sangsu');
  const k = P2h.keepersFull.find(kp => kp.id === sel);
  return (
    <div style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <div className="ki-tabs">
        {P2h.keepersFull.map(kp => (
          <button key={kp.id} className={sel === kp.id ? 'on' : ''} onClick={() => setSel(kp.id)}>
            <Dot kind={kClass(kp.id)} size="sm" /> {kp.id}
          </button>
        ))}
      </div>
      <div style={{padding:'4px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',display:'flex',alignItems:'center',gap:'8px',fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',color:'var(--fg-3)'}}>
        <Dot kind={kClass(k.id)} beat />
        <span style={{color:'var(--brass-1)'}}>{k.id}</span>
        <span>·</span>
        <span>{k.role}</span>
        <span style={{marginLeft:'auto',color:'var(--fg-4)',fontSize:'var(--fs-9)'}}>social · {k.social_model}</span>
      </div>
      <div className="ki-bdi">
        {[['will', k.will], ['needs', k.needs], ['desires', k.desires]].map(([lbl, v]) => (
          <div key={lbl} className="row">
            <span className="lbl">{lbl}</span>
            <span className="v">{v}</span>
          </div>
        ))}
        <div className="hz">
          <span className="lbl">short</span><span className="v">{k.short_goal}</span>
          <span className="lbl">mid</span>  <span className="v">{k.mid_goal}</span>
          <span className="lbl">long</span> <span className="v">{k.long_goal}</span>
        </div>
      </div>
    </div>
  );
}

// K1-B · Tool access + cascade config — per-keeper comparison table
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
    <div style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <div className="ki-tabs">
        {P2h.keepersFull.map(kp => (
          <button key={kp.id} className={sel === kp.id ? 'on' : ''} onClick={() => setSel(kp.id)}>
            <Dot kind={kClass(kp.id)} size="sm" /> {kp.id}
          </button>
        ))}
      </div>
      <div className="ki-access">
        {rows.map(r => (
          <div key={r.lbl} className="row">
            <span className="lbl">{r.lbl}</span>
            <span className={`v ${r.cls || ''}`}>
              {r.mentions
                ? r.mentions.map(m => <span key={m} className="mention">@{m}</span>)
                : r.v}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}

// K1-C · Token / handoff stats — bar chart across all keepers
function KeeperTokenStats() {
  const keepers = P2h.keepersFull;
  const maxIn  = Math.max(...keepers.map(k => k.tokens.in));
  const maxOut = Math.max(...keepers.map(k => k.tokens.out));
  return (
    <div style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <div style={{padding:'4px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex',gap:'12px'}}>
        <span>token usage · all keepers</span>
        <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>
          {(keepers.reduce((s,k)=>s+k.tokens.in,0)/1e6).toFixed(2)}M in total
        </span>
      </div>
      <div className="ki-stats">
        <div className="hdr">
          <span>keeper</span><span>in tok</span><span>out tok</span><span>in distribution</span>
        </div>
        {[...keepers].sort((a,b) => b.tokens.in - a.tokens.in).map(k => (
          <div key={k.id} className="row">
            <span className="ag"><Dot kind={kClass(k.id)} size="sm" /> {k.id}</span>
            <span className="num">{(k.tokens.in/1000).toFixed(0)}k</span>
            <span className="num">{(k.tokens.out/1000).toFixed(1)}k</span>
            <div className="bar"><i style={{width:`${k.tokens.in/maxIn*100}%`}} /></div>
          </div>
        ))}
      </div>
      <div style={{display:'grid',gridTemplateColumns:'repeat(3,1fr)',gap:'1px',background:'var(--line-1)',border:'1px solid var(--line-2)'}}>
        {[
          { lbl:'Total In', v:`${(keepers.reduce((s,k)=>s+k.tokens.in,0)/1e6).toFixed(2)}M` },
          { lbl:'Total Out', v:`${(keepers.reduce((s,k)=>s+k.tokens.out,0)/1000).toFixed(0)}k` },
          { lbl:'Keepers', v:keepers.length },
        ].map(c => (
          <div key={c.lbl} style={{background:'var(--bg-1)',padding:'6px 10px',display:'flex',flexDirection:'column',gap:'2px'}}>
            <span style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)'}}>{c.lbl}</span>
            <span style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-14)',color:'var(--brass-1)',fontVariantNumeric:'tabular-nums'}}>{c.v}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

// ═════════════════════════════════════════════════════════════════
// K2 · DECISIONS / MEMORY
// ═════════════════════════════════════════════════════════════════

// K2-A · Decisions stream — chronological, belief/desire/intention/blocker
function DecisionsStream() {
  const [filter, setFilter] = useState('all');
  const keepers = ['all', ...new Set(P2h.decisions.map(d => d.keeper))];
  const rows = filter === 'all' ? P2h.decisions : P2h.decisions.filter(d => d.keeper === filter);
  return (
    <div style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <div style={{padding:'4px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex',alignItems:'center',gap:'6px'}}>
        <span>decisions.jsonl</span>
        <span style={{marginLeft:'auto',display:'flex',gap:'2px'}}>
          {keepers.map(k => (
            <button key={k} onClick={() => setFilter(k)}
              style={{padding:'1px 6px',background: filter===k ? 'var(--brass-3)' : 'var(--bg-1)',border:'1px solid var(--line-2)',color: filter===k ? 'var(--brass-1)' : 'var(--fg-3)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',cursor:'pointer'}}>
              {k}
            </button>
          ))}
        </span>
      </div>
      <div style={{background:'var(--bg-0)',border:'1px solid var(--line-1)'}}>
        {rows.map(d => (
          <div key={d.id} className="dec-row">
            <span className="ts">{d.ts.slice(11,19)}</span>
            <span className="kpr">{d.keeper}</span>
            <span className={`out ${d.outcome}`}>{d.outcome}</span>
            <div className="body">
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
    </div>
  );
}

// K2-B · Memory entries — tag-filtered with keeper attribution
function MemoryEntries() {
  const [tag, setTag] = useState('all');
  const tags = ['all', 'verified', 'learned', 'observed', 'plan'];
  const rows = tag === 'all' ? P2h.memoryEntries : P2h.memoryEntries.filter(m => m.tag === tag);
  return (
    <div style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <div style={{padding:'4px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex',alignItems:'center',gap:'6px'}}>
        <span>memory.jsonl</span>
        <span style={{marginLeft:'auto',display:'flex',gap:'2px'}}>
          {tags.map(t => (
            <button key={t} onClick={() => setTag(t)}
              style={{padding:'1px 6px',background: tag===t ? 'var(--brass-3)' : 'var(--bg-1)',border:'1px solid var(--line-2)',color: tag===t ? 'var(--brass-1)' : 'var(--fg-3)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',cursor:'pointer'}}>
              {t}
            </button>
          ))}
        </span>
      </div>
      <div style={{background:'var(--bg-0)',border:'1px solid var(--line-1)'}}>
        {rows.length > 0 ? rows.map((m, i) => (
          <div key={i} className="mem-row">
            <span className="ts">{m.at.slice(11,19)}</span>
            <span className="kpr">{m.keeper}</span>
            <span className={`tag ${m.tag}`}>{m.tag}</span>
            <span className="body">{m.body}</span>
          </div>
        )) : (
          <div style={{padding:'12px 8px',fontFamily:'var(--font-mono)',fontSize:'var(--fs-11)',color:'var(--fg-4)',textAlign:'center'}}>
            no entries for tag "{tag}"
          </div>
        )}
      </div>
    </div>
  );
}

// ═════════════════════════════════════════════════════════════════
// K3 · INSTITUTION EPISODES
// ═════════════════════════════════════════════════════════════════

// K3-A · Turn cards — episode summary + learnings inline
function EpisodeCards() {
  const [open, setOpen] = useState('ep-tm-t5');
  return (
    <div style={{display:'flex',flexDirection:'column',gap:'0'}}>
      <div style={{padding:'4px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex',gap:'8px',marginBottom:'4px'}}>
        <span>institution_episodes.jsonl</span>
        <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>{P2h.episodes.length} episodes</span>
      </div>
      {P2h.episodes.map(ep => {
        const isOpen = open === ep.id;
        return (
          <div key={ep.id} className="ep-card" onClick={() => setOpen(isOpen ? null : ep.id)} style={{cursor:'pointer'}}>
            <div className="h">
              <span className="id">{ep.id}</span>
              <span className="ts">{ep.ts.slice(11,19)}</span>
              <div className="pp">
                {ep.participants.map(p => <span key={p} className="p">{p}</span>)}
              </div>
              <span className="oc">{ep.outcome}</span>
            </div>
            <div className="sm">{ep.summary}</div>
            {isOpen && (
              <div className="lns">
                {ep.learnings.map((l, i) => (
                  <div key={i} className="ln">{l}</div>
                ))}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

// K3-B · Learnings extraction — all learnings grouped by episode
function EpisodeLearnings() {
  return (
    <div className="ep-learn">
      {P2h.episodes.map(ep => (
        <div key={ep.id} className="grp">
          <div className="grp-h">
            <span>{ep.id}</span>
            <span style={{color:'var(--fg-4)'}}>·</span>
            <span>{ep.participants.join(' + ')}</span>
            <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>{ep.learnings.length} learnings</span>
          </div>
          {ep.learnings.map((l, i) => (
            <div key={i} className="item">{l}</div>
          ))}
        </div>
      ))}
    </div>
  );
}

// ═════════════════════════════════════════════════════════════════
// K4 · AUTORESEARCH
// ═════════════════════════════════════════════════════════════════

// K4-A · Loop list — all 6 ar-* loops with status, confidence, branch, owner
function ARLoopList() {
  const confCls = (c) => c >= 0.8 ? 'hi' : c >= 0.5 ? '' : c >= 0.35 ? 'lo' : 'vlo';
  return (
    <div style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <div style={{padding:'4px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex',gap:'8px'}}>
        <span>autoresearch loops</span>
        <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>{P2h.arLoops.filter(l=>l.status==='open').length} open · {P2h.arLoops.filter(l=>l.status==='closed').length} closed</span>
      </div>
      <div style={{background:'var(--bg-0)'}}>
        {P2h.arLoops.map(l => (
          <div key={l.id} className="ar-row">
            <span className="id">{l.id.slice(0,11)}</span>
            <div style={{display:'flex',flexDirection:'column',gap:'2px'}}>
              <span className="topic">{l.topic}</span>
              <span style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',color:'var(--fg-4)'}}>
                owner · {l.owner}
                {l.branch && <span style={{color:'var(--fg-3)'}}> · ⎇ {l.branch}</span>}
                {' · '}{l.hypotheses}H · {l.evidences}E · {l.conclusions}C
              </span>
            </div>
            <span className={`st ${l.status}`}>{l.status}</span>
            <span className={`conf ${confCls(l.confidence)}`}>{(l.confidence*100).toFixed(0)}%</span>
          </div>
        ))}
      </div>
    </div>
  );
}

// K4-B · Finding card — detailed view of a selected finding
function ARFindingCard() {
  const [sel, setSel] = useState('f-001');
  const f = P2h.findings.find(x => x.id === sel);
  return (
    <div style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <div style={{display:'flex',gap:'2px'}}>
        {P2h.findings.map(x => (
          <button key={x.id} onClick={() => setSel(x.id)}
            style={{padding:'3px 10px',background: sel===x.id ? 'var(--brass-3)' : 'var(--bg-2)',border:'1px solid var(--line-2)',color: sel===x.id ? 'var(--brass-1)' : 'var(--fg-3)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',cursor:'pointer'}}>
            {x.id}
          </button>
        ))}
      </div>
      <div className="ar-find">
        <div className="hdr">
          <span className="id">{f.id}</span>
          <span className="loop">loop · {f.loop}</span>
          <span style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',color:'var(--fg-4)'}}>{f.at.slice(11,19)}</span>
          <span className="conf">{(f.confidence*100).toFixed(0)}% confidence</span>
        </div>
        <div>
          <div className="sec-h">hypothesis</div>
          <div className="hy">{f.hypothesis}</div>
        </div>
        <div>
          <div className="sec-h">evidence ({f.evidence.length})</div>
          <div className="ev-list">
            {f.evidence.map((e, i) => <div key={i} className="ev">{e}</div>)}
          </div>
        </div>
        <div>
          <div className="sec-h">conclusion</div>
          <div className="co">{f.conclusion}</div>
        </div>
      </div>
    </div>
  );
}

// K4-C · Hypothesis → evidence → conclusion flow (ar-78d41e9c, closed loop)
function ARHypothesisFlow() {
  const loop = P2h.arLoops.find(l => l.id === 'ar-78d41e9c');
  const finding = P2h.findings.find(f => f.loop === 'ar-78d41e9c');
  return (
    <div style={{display:'flex',flexDirection:'column',gap:'6px'}}>
      <div style={{padding:'4px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex',gap:'8px'}}>
        <span>{loop.id}</span>
        <span style={{color:'var(--fg-3)'}}>· {loop.topic}</span>
        <span style={{marginLeft:'auto',color:'var(--ok-fg)'}}>closed · {(loop.confidence*100).toFixed(0)}% confidence</span>
      </div>
      <div className="ar-flow">
        <div className="step">
          <div className="step-h">
            <span className="step-n">1</span>
            <span className="step-t">Hypothesis</span>
          </div>
          <div className="step-body">{finding.hypothesis}</div>
        </div>
        <div className="connector">↓</div>
        <div className="step">
          <div className="step-h">
            <span className="step-n">2</span>
            <span className="step-t">Evidence ({finding.evidence.length} items)</span>
          </div>
          {finding.evidence.map((e, i) => <div key={i} className="ev">{e}</div>)}
        </div>
        <div className="connector">↓</div>
        <div className="step">
          <div className="step-h">
            <span className="step-n">3</span>
            <span className="step-t">Conclusion</span>
          </div>
          <div className="ar-con">{finding.conclusion}</div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, {
  KeeperBDIPanel, KeeperToolAccess, KeeperTokenStats,
  DecisionsStream, MemoryEntries,
  EpisodeCards, EpisodeLearnings,
  ARLoopList, ARFindingCard, ARHypothesisFlow,
});
