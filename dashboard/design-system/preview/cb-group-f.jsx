// preview/cb-group-f.jsx
// Track 3 · OBSERVABILITY PLANE
// O1 Cascade Inspector · O2 Audit Ledger · O3 Safe Autonomy · O4 Cost · O5 Heuristic + Stress

const P2f = window.MASC_P2;

// helper — format ms as human-readable
function fmtMs(ms) {
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  const m = Math.floor(ms / 60000);
  const s = Math.floor((ms % 60000) / 1000);
  return `${m}m${s.toString().padStart(2, '0')}`;
}

// ═════════════════════════════════════════════════════════════════
// O1 · CASCADE INSPECTOR
// ═════════════════════════════════════════════════════════════════

// O1-A · Cascade list (compact view of multiple runs)
function CascadeList() {
  return (
    <div className="csc-list">
      {P2f.cascadeAudit.map(c => (
        <div key={c.id} className={`csc-card outcome-${c.outcome}`}>
          <div className="h">
            <span className="id">{c.id}</span>
            <span className="nm">{c.cascade}</span>
            <span className="tg">· {c.trigger} · {c.at}</span>
            <span className={`out ${c.outcome}`}>{c.outcome === 'error' ? c.error_category : 'ok'}</span>
          </div>
          <div className="hops">
            {c.hops.map(h => (
              <div key={h.i} className="hop">
                <span className="step">{h.i}</span>
                <span className="mdl">{h.model}</span>
                <span className={`st ${h.status}`}>{h.status}</span>
                <span className="ms">{fmtMs(h.ms)}</span>
                <span className="reason">↳ {h.reason}</span>
              </div>
            ))}
          </div>
          <div className="ft">
            <span>HOPS · {c.hops.length}</span>
            <span>TOTAL · <span className="ms">{fmtMs(c.total_ms)}</span></span>
            {c.selected && <span>SELECTED · {c.selected}</span>}
          </div>
        </div>
      ))}
    </div>
  );
}

// O1-B · Single cascade deep-dive (the failed one) with configured pool
function CascadeDeepDive() {
  const c = P2f.cascadeAudit[0];  // ca-7f29 the failed one
  const triedSet = new Set(c.hops.map(h => h.model));
  const hitModel = c.hops.find(h => h.status === 'hit')?.model;
  return (
    <div className="csc-card outcome-error" style={{borderLeftWidth:'3px'}}>
      <div className="h">
        <span className="id">{c.id}</span>
        <span className="nm">{c.cascade}</span>
        <span className="tg">· {c.trigger} · {c.at}</span>
        <span className="out error">{c.error_category}</span>
      </div>
      <div className="csc-pool">
        <span style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',color:'var(--fg-4)',letterSpacing:'.08em',textTransform:'uppercase',marginRight:'4px'}}>configured pool ({c.configured.length}):</span>
        {c.configured.map(m => {
          const cls = m === hitModel ? 'hit' : triedSet.has(m) ? 'tried' : '';
          return <span key={m} className={`mp ${cls}`}>{m}</span>;
        })}
      </div>
      <div className="hops">
        {c.hops.map(h => (
          <div key={h.i} className="hop">
            <span className="step">{h.i}</span>
            <span className="mdl">{h.model}</span>
            <span className={`st ${h.status}`}>{h.status}</span>
            <span className="ms">{fmtMs(h.ms)}</span>
            <span className="reason">↳ {h.reason}</span>
          </div>
        ))}
      </div>
      <div className="ft">
        <span>PRIMARY · {c.primary}</span>
        <span>HOPS · {c.hops.length}/{c.configured.length}</span>
        <span>TOTAL · <span className="ms">{fmtMs(c.total_ms)}</span></span>
      </div>
    </div>
  );
}

// O1-C · Side-by-side compare (success vs failure pattern)
function CascadeCompare() {
  const failed = P2f.cascadeAudit.find(c => c.outcome === 'error');
  const ok = P2f.cascadeAudit.find(c => c.outcome === 'ok');
  return (
    <div style={{display:'grid', gridTemplateColumns:'1fr 1fr', gap:'8px'}}>
      {[failed, ok].map(c => (
        <div key={c.id} className={`csc-card outcome-${c.outcome}`}>
          <div className="h">
            <span className="id">{c.id}</span>
            <span className="nm">{c.cascade}</span>
            <span className={`out ${c.outcome}`}>{c.outcome === 'error' ? c.error_category : 'ok'}</span>
          </div>
          <div className="hops">
            {c.hops.map(h => (
              <div key={h.i} className="hop">
                <span className="step">{h.i}</span>
                <span className="mdl">{h.model.length > 24 ? h.model.slice(0,24)+'…' : h.model}</span>
                <span className={`st ${h.status}`}>{h.status}</span>
                <span className="ms">{fmtMs(h.ms)}</span>
              </div>
            ))}
          </div>
          <div className="ft">
            <span>TOTAL · <span className="ms">{fmtMs(c.total_ms)}</span></span>
          </div>
        </div>
      ))}
    </div>
  );
}

// ═════════════════════════════════════════════════════════════════
// O2 · AUDIT LEDGER
// ═════════════════════════════════════════════════════════════════

// O2-A · Streaming ledger (all event types)
function AuditLedger() {
  return (
    <div style={{background:'var(--bg-1)',border:'1px solid var(--line-2)'}}>
      <div style={{padding:'5px 8px',borderBottom:'1px solid var(--line-2)',display:'flex',gap:'8px',background:'var(--bg-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)'}}>
        <span>tail · audit.jsonl</span>
        <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>{P2f.auditEvents.length} events</span>
      </div>
      {P2f.auditEvents.map((e, i) => {
        const [cat] = e.kind.split('.');
        return (
          <div key={i} className="aud-row">
            <span className="ts">{e.ts.replace('Z','')}</span>
            <span className={`kn ${cat}`}>{e.kind}</span>
            <span className="ac">{e.actor}</span>
            <span className="sb">
              {e.subject}
              {Object.keys(e.payload).length > 0 && (
                <span className="pl">↳ {Object.entries(e.payload).map(([k,v]) => `${k}=${v}`).join(' · ')}</span>
              )}
            </span>
            <span className="du">{e.duration > 0 ? fmtMs(e.duration) : '—'}</span>
          </div>
        );
      })}
    </div>
  );
}

// O2-B · Filtered by actor (focus on one keeper)
function AuditByActor() {
  const actor = 'sangsu';
  const filtered = P2f.auditEvents.filter(e => e.actor === actor || e.subject.includes(actor));
  return (
    <div style={{background:'var(--bg-1)',border:'1px solid var(--line-2)'}}>
      <div style={{padding:'5px 8px',borderBottom:'1px solid var(--line-2)',display:'flex',gap:'8px',background:'var(--bg-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)'}}>
        <span>filter · actor={actor}</span>
        <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>{filtered.length} matches</span>
      </div>
      {filtered.map((e, i) => {
        const [cat] = e.kind.split('.');
        return (
          <div key={i} className="aud-row">
            <span className="ts">{e.ts.replace('Z','')}</span>
            <span className={`kn ${cat}`}>{e.kind}</span>
            <span className="ac">{e.actor}</span>
            <span className="sb">{e.subject}</span>
            <span className="du">{e.duration > 0 ? fmtMs(e.duration) : '—'}</span>
          </div>
        );
      })}
    </div>
  );
}

// O2-C · Event-kind summary (counts + costs roll-up)
function AuditSummary() {
  const counts = {};
  P2f.auditEvents.forEach(e => {
    counts[e.kind] = (counts[e.kind] || 0) + 1;
  });
  const sorted = Object.entries(counts).sort((a,b) => b[1] - a[1]);
  const total = P2f.auditEvents.length;
  return (
    <div style={{display:'flex',flexDirection:'column',gap:'2px'}}>
      <div style={{padding:'5px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex'}}>
        <span>summary · last 12 events</span>
        <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>{total} total</span>
      </div>
      {sorted.map(([kind, n]) => {
        const [cat] = kind.split('.');
        const pct = (n / total * 100).toFixed(0);
        return (
          <div key={kind} style={{display:'grid',gridTemplateColumns:'140px 30px 1fr',gap:'6px',alignItems:'center',padding:'3px 8px',background:'var(--bg-1)',border:'1px solid var(--line-1)'}}>
            <span className={`kn ${cat}`} style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',padding:'1px 5px',border:'1px solid var(--line-2)',justifySelf:'flex-start'}}>{kind}</span>
            <span style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-11)',color:'var(--brass-1)',fontVariantNumeric:'tabular-nums',textAlign:'right'}}>{n}</span>
            <div style={{height:'10px',background:'var(--bg-2)',border:'1px solid var(--line-1)',position:'relative'}}>
              <div style={{height:'100%',width:`${pct}%`,background:'linear-gradient(90deg, var(--brass-3), var(--brass-1))'}}></div>
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ═════════════════════════════════════════════════════════════════
// O3 · SAFE AUTONOMY DASHBOARD
// ═════════════════════════════════════════════════════════════════

function SafeAutoHero() {
  const sa = P2f.safeAutonomy;
  return (
    <div className="sa-hero">
      <div className="gauge">
        <span className="lbl">Safe Autonomy Score</span>
        <span className={`v ${sa.status}`}>{sa.global_score}</span>
        <span className="st">{sa.status}</span>
      </div>
      <div className="meta">
        <span className="k">findings</span><span className="v">{sa.findings_total} ({sa.findings.filter(f=>f.sev==='high').length} high)</span>
        <span className="k">keepers audited</span><span className="v">{sa.keeper_count}</span>
        <span className="k">last run</span><span className="v">{sa.last_run.replace('Z','')}</span>
        <span className="k">trend</span><span className="v" style={{color:'var(--err-fg)'}}>−4 vs 24h ago</span>
      </div>
      <div className="spark">
        <Spark data={sa.history.map(h => h - 70)} bars={sa.history.length} color="brass" />
      </div>
    </div>
  );
}

// O3-A · Score hero + finding list
function SafeAutoDashboard() {
  const sa = P2f.safeAutonomy;
  return (
    <div style={{display:'flex',flexDirection:'column',gap:'8px'}}>
      <SafeAutoHero />
      <div style={{background:'var(--bg-1)',border:'1px solid var(--line-2)'}}>
        <div style={{padding:'5px 8px',borderBottom:'1px solid var(--line-2)',display:'flex',gap:'8px',background:'var(--bg-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)'}}>
          <span>findings ({sa.findings.length})</span>
          <span style={{marginLeft:'auto'}}>severity ↓</span>
        </div>
        {sa.findings.map((f, i) => (
          <div key={i} className="sa-find">
            <span className={`sev ${f.sev}`}>{f.sev}</span>
            <span className="kpr">{f.keeper}</span>
            <span className="rule">{f.rule}</span>
            <span className="loc">{f.file}<span className="ln">:{f.line}</span></span>
          </div>
        ))}
      </div>
    </div>
  );
}

// O3-B · By-keeper rollup (matrix view)
function SafeAutoByKeeper() {
  const sa = P2f.safeAutonomy;
  const byKeeper = {};
  sa.findings.forEach(f => {
    if (!byKeeper[f.keeper]) byKeeper[f.keeper] = { high:0, medium:0, low:0, items:[] };
    byKeeper[f.keeper][f.sev]++;
    byKeeper[f.keeper].items.push(f);
  });
  const sorted = Object.entries(byKeeper).sort((a,b) => (b[1].high*9 + b[1].medium*3 + b[1].low) - (a[1].high*9 + a[1].medium*3 + a[1].low));
  return (
    <div style={{display:'flex',flexDirection:'column',gap:'4px'}}>
      <div style={{padding:'5px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex'}}>
        <span>findings by keeper</span>
        <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>{sorted.length} keepers</span>
      </div>
      {sorted.map(([k, v]) => (
        <div key={k} style={{display:'grid',gridTemplateColumns:'120px 60px 60px 60px 1fr',gap:'6px',alignItems:'center',padding:'4px 8px',background:'var(--bg-1)',border:'1px solid var(--line-1)'}}>
          <span style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-11)',color:'var(--brass-1)'}}>{k}</span>
          <span className="sev high"   style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',padding:'1px 5px',textAlign:'center',opacity: v.high?1:0.15}}>{v.high}</span>
          <span className="sev medium" style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',padding:'1px 5px',textAlign:'center',opacity: v.medium?1:0.15}}>{v.medium}</span>
          <span className="sev low"    style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',padding:'1px 5px',textAlign:'center',opacity: v.low?1:0.15}}>{v.low}</span>
          <span style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',color:'var(--fg-3)'}}>{v.items.map(i=>i.rule.split(' ')[0]).join(' · ')}</span>
        </div>
      ))}
    </div>
  );
}

// O3-C · Trend (history chart)
function SafeAutoTrend() {
  const sa = P2f.safeAutonomy;
  const min = Math.min(...sa.history);
  const max = Math.max(...sa.history);
  return (
    <div style={{background:'var(--bg-1)',border:'1px solid var(--line-2)',padding:'12px'}}>
      <div style={{display:'flex',gap:'12px',alignItems:'baseline',marginBottom:'8px',fontFamily:'var(--font-mono)'}}>
        <span style={{fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)'}}>autonomy score · last 15 runs</span>
        <span style={{marginLeft:'auto',fontSize:'var(--fs-10)',color:'var(--fg-3)'}}>min {min} · current <span style={{color:'var(--err-fg)'}}>{sa.global_score}</span> · max {max}</span>
      </div>
      <div style={{display:'flex',alignItems:'flex-end',height:'80px',gap:'3px'}}>
        {sa.history.map((v, i) => {
          const pct = ((v - 70) / 15) * 100;
          const bad = v < 78;
          return (
            <div key={i} style={{flex:1,display:'flex',flexDirection:'column',alignItems:'center',gap:'2px'}}>
              <div style={{width:'100%',height:`${pct}%`,background: bad ? 'linear-gradient(180deg, var(--err), var(--err-border))' : 'linear-gradient(180deg, var(--brass-1), var(--brass-3))'}}></div>
            </div>
          );
        })}
      </div>
      <div style={{display:'flex',justifyContent:'space-between',marginTop:'4px',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',color:'var(--fg-4)'}}>
        <span>−15</span><span>now</span>
      </div>
    </div>
  );
}

// ═════════════════════════════════════════════════════════════════
// O4 · COST DASHBOARD
// ═════════════════════════════════════════════════════════════════

// O4-A · Per-agent token + cost table (sorted by cost desc)
function CostPerAgent() {
  const rows = [...P2f.costs.perAgent].sort((a,b) => b.cost - a.cost);
  const maxCost = Math.max(...rows.map(r => r.cost));
  const maxLat = Math.max(...rows.map(r => r.p95_ms));
  return (
    <div style={{display:'flex',flexDirection:'column',gap:'8px'}}>
      <div className="cs-tot">
        <div className="cell">
          <span className="lbl">Total Cost</span>
          <span className="v">${P2f.costs.total_cost_usd.toFixed(2)}</span>
          <span className="sub">last 24h</span>
        </div>
        <div className="cell">
          <span className="lbl">Tokens In</span>
          <span className="v">{(rows.reduce((s,r)=>s+r.in_tok,0)/1e6).toFixed(2)}M</span>
          <span className="sub">9 agents</span>
        </div>
        <div className="cell">
          <span className="lbl">p50 Latency</span>
          <span className="v">{P2f.costs.p50}<span style={{fontSize:'12px',color:'var(--fg-3)'}}>ms</span></span>
          <span className="sub">global</span>
        </div>
        <div className="cell">
          <span className="lbl">p95 Latency</span>
          <span className="v" style={{color:'var(--err-fg)'}}>{P2f.costs.p95}<span style={{fontSize:'12px',color:'var(--fg-3)'}}>ms</span></span>
          <span className="sub">over budget</span>
        </div>
      </div>
      <table className="cb-table cs-tbl">
        <thead>
          <tr>
            <th>Agent</th>
            <th>In Tok</th>
            <th>Out Tok</th>
            <th>$ Cost</th>
            <th>Cost</th>
            <th>p50</th>
            <th>p95</th>
            <th>p95 trend</th>
          </tr>
        </thead>
        <tbody>
          {rows.map(r => (
            <tr key={r.agent}>
              <td style={{color:'var(--brass-1)'}}>{r.agent}</td>
              <td className="lat-num">{(r.in_tok/1000).toFixed(0)}k</td>
              <td className="lat-num">{(r.out_tok/1000).toFixed(1)}k</td>
              <td className="lat-num" style={{color:'var(--brass-1)'}}>${r.cost.toFixed(2)}</td>
              <td className="bar"><i style={{width:`${r.cost/maxCost*100}%`}}></i></td>
              <td className="lat-num">{r.p50_ms}</td>
              <td className={`lat-num ${r.p95_ms > 8000 ? 'bad' : ''}`}>{r.p95_ms}</td>
              <td className="bar lat"><i style={{width:`${r.p95_ms/maxLat*100}%`}}></i></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// O4-B · Provider × model heatmap
function CostMatrix() {
  const m = P2f.costs.matrix;
  const flat = m.grid.flat().filter(v => v > 0);
  const max = Math.max(...flat);
  const zone = (v) => {
    if (v === 0) return 'z0';
    const p = v / max;
    if (p < 0.1) return 'z1';
    if (p < 0.3) return 'z2';
    if (p < 0.7) return 'z3';
    return 'z4';
  };
  return (
    <div style={{display:'flex',flexDirection:'column',gap:'8px'}}>
      <div style={{padding:'5px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex'}}>
        <span>provider × model · $ spent (24h)</span>
        <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>${P2f.costs.total_cost_usd.toFixed(2)}</span>
      </div>
      <table className="cs-mat">
        <thead>
          <tr>
            <th></th>
            {m.models.map(md => <th key={md}>{md}</th>)}
          </tr>
        </thead>
        <tbody>
          {m.providers.map((p, i) => (
            <tr key={p}>
              <th className="row-h">{p}</th>
              {m.grid[i].map((v, j) => (
                <td key={j} className={zone(v)}>{v > 0 ? `$${v.toFixed(2)}` : '—'}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// O4-C · Latency histogram + p50/p95 markers
function CostLatency() {
  const buckets = P2f.costs.latencyBuckets;
  const max = Math.max(...buckets.map(b => b.n));
  const total = buckets.reduce((s,b) => s+b.n, 0);
  return (
    <div style={{display:'flex',flexDirection:'column',gap:'8px'}}>
      <div style={{padding:'5px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex',gap:'12px'}}>
        <span>latency distribution · {total} calls</span>
        <span style={{marginLeft:'auto'}}>p50 · <span style={{color:'var(--brass-1)'}}>{P2f.costs.p50}ms</span></span>
        <span>p95 · <span style={{color:'var(--err-fg)'}}>{P2f.costs.p95}ms</span></span>
      </div>
      <div className="cs-hist">
        {buckets.map((b, i) => {
          const pct = b.n / max * 100;
          const bad = b.lo >= 8000;
          return (
            <div key={i} className="col">
              <div className={`b ${bad ? 'bad' : ''}`} style={{height:`${pct}%`}}></div>
              <span className="lab">{b.lo < 1000 ? `${b.lo}` : b.lo < 60000 ? `${b.lo/1000}k` : `${b.lo/60000}m`}</span>
            </div>
          );
        })}
      </div>
      <div style={{display:'grid',gridTemplateColumns:'repeat(4, 1fr)',gap:'1px',background:'var(--line-2)',border:'1px solid var(--line-2)'}}>
        {[
          { l:'< 1s',  v: buckets.filter(b=>b.hi<=1000).reduce((s,b)=>s+b.n,0), c:'var(--ok-fg)' },
          { l:'1–4s',  v: buckets.filter(b=>b.lo>=1000&&b.hi<=4000).reduce((s,b)=>s+b.n,0), c:'var(--brass-1)' },
          { l:'4–16s', v: buckets.filter(b=>b.lo>=4000&&b.hi<=16000).reduce((s,b)=>s+b.n,0), c:'var(--warn)' },
          { l:'> 16s', v: buckets.filter(b=>b.lo>=16000).reduce((s,b)=>s+b.n,0), c:'var(--err-fg)' },
        ].map(b => (
          <div key={b.l} style={{background:'var(--bg-1)',padding:'6px 10px',display:'flex',flexDirection:'column',gap:'2px'}}>
            <span style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)'}}>{b.l}</span>
            <span style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-13)',color:b.c,fontVariantNumeric:'tabular-nums'}}>{b.v}<span style={{fontSize:'var(--fs-10)',color:'var(--fg-4)',marginLeft:'4px'}}>· {(b.v/total*100).toFixed(0)}%</span></span>
          </div>
        ))}
      </div>
    </div>
  );
}

// ═════════════════════════════════════════════════════════════════
// O5 · HEURISTIC + STRESS
// ═════════════════════════════════════════════════════════════════

// O5-A · Heuristic firing log
function HeuristicLog() {
  return (
    <div style={{background:'var(--bg-1)',border:'1px solid var(--line-2)'}}>
      <div style={{padding:'5px 8px',borderBottom:'1px solid var(--line-2)',display:'flex',gap:'8px',background:'var(--bg-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)'}}>
        <span>tail · keeper_hooks_oas.heuristics.jsonl</span>
        <span style={{marginLeft:'auto',color:'var(--err-fg)'}}>{P2f.heuristics.filter(h=>h.triggered).length}/{P2f.heuristics.length} fired</span>
      </div>
      {P2f.heuristics.map((h, i) => (
        <div key={i} className={`hr-row ${h.triggered ? 'fired' : ''}`}>
          <span className="ts">{h.ts.replace('Z','')}</span>
          <span className="mod">{h.module}</span>
          <span className="site">{h.site}<span className="det" style={{display:'block'}}>↳ {h.detail}</span></span>
          <span className="num">value · <span className={h.triggered?'over':''}>{h.value}</span></span>
          <span className="num">thr · {h.threshold}</span>
          <span className={`fl ${h.triggered ? 't' : 'f'}`}>{h.triggered ? 'fire' : 'ok'}</span>
        </div>
      ))}
    </div>
  );
}

// O5-B · Stress board (per-agent stressors)
function StressBoard() {
  return (
    <div style={{display:'flex',flexDirection:'column',gap:'8px'}}>
      <div style={{padding:'5px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex'}}>
        <span>agent stress · agent_stress.jsonl</span>
        <span style={{marginLeft:'auto',color:'var(--err-fg)'}}>{P2f.stress.length} active</span>
      </div>
      <div className="st-grid">
        {P2f.stress.map((s, i) => (
          <div key={i} className={`scard ${s.kind}`}>
            <div className="h">
              <span className="ag">{s.agent}</span>
              <span className="at">{s.at.replace('Z','')}</span>
            </div>
            <span className="kind">{s.kind}</span>
            <span className="cn">count · <span className="v">{s.count}</span> · room {s.room}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

// O5-C · Module-grouped firing rate
function HeuristicByModule() {
  const byMod = {};
  P2f.heuristics.forEach(h => {
    if (!byMod[h.module]) byMod[h.module] = { fired: 0, total: 0, sites: new Set() };
    byMod[h.module].total++;
    if (h.triggered) byMod[h.module].fired++;
    byMod[h.module].sites.add(h.site);
  });
  const rows = Object.entries(byMod).sort((a,b) => b[1].fired - a[1].fired);
  return (
    <div style={{display:'flex',flexDirection:'column',gap:'4px'}}>
      <div style={{padding:'5px 8px',background:'var(--bg-2)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--fg-4)',display:'flex'}}>
        <span>heuristic firing rate · by module</span>
      </div>
      {rows.map(([mod, v]) => {
        const pct = v.total > 0 ? v.fired / v.total * 100 : 0;
        return (
          <div key={mod} style={{display:'grid',gridTemplateColumns:'160px 80px 1fr 60px',gap:'8px',alignItems:'center',padding:'5px 8px',background:'var(--bg-1)',border:'1px solid var(--line-1)'}}>
            <span style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-11)',color:'var(--fg-1)'}}>{mod}</span>
            <span style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',color:'var(--fg-3)'}}>{v.fired}/{v.total} fired</span>
            <div style={{height:'10px',background:'var(--bg-2)',border:'1px solid var(--line-1)'}}>
              <div style={{height:'100%',width:`${pct}%`,background: pct > 50 ? 'linear-gradient(90deg, var(--warn), var(--err))' : 'linear-gradient(90deg, var(--brass-3), var(--brass-1))'}}></div>
            </div>
            <span style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-11)',color: pct > 50 ? 'var(--err-fg)' : 'var(--brass-1)',fontVariantNumeric:'tabular-nums',textAlign:'right'}}>{pct.toFixed(0)}%</span>
            <span style={{gridColumn:'1 / -1',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',color:'var(--fg-4)',letterSpacing:'.04em'}}>sites · {[...v.sites].join(' · ')}</span>
          </div>
        );
      })}
    </div>
  );
}

Object.assign(window, {
  CascadeList, CascadeDeepDive, CascadeCompare,
  AuditLedger, AuditByActor, AuditSummary,
  SafeAutoDashboard, SafeAutoByKeeper, SafeAutoTrend,
  CostPerAgent, CostMatrix, CostLatency,
  HeuristicLog, StressBoard, HeuristicByModule,
});
