// preview/cb-group-f.jsx
// Track 3 · OBSERVABILITY PLANE
// O1 Cascade Inspector · O2 Audit Ledger · O3 Safe Autonomy · O4 Cost · O5 Heuristic + Stress

const P2f = window.MASC_P2;

function fmtMs(ms) {
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  const m = Math.floor(ms / 60000);
  const s = Math.floor((ms % 60000) / 1000);
  return `${m}m${s.toString().padStart(2, '0')}`;
}

// shared cascade card sub-component
function CascadeCard({ c, hitModel, triedSet, showPool, compactModel = false }) {
  return (
    <article className={`csc-card outcome-${c.outcome}`} aria-label={`${c.id} · ${c.cascade} · ${c.outcome === 'error' ? c.error_category : 'ok'} · ${c.hops.length} hops · ${fmtMs(c.total_ms)}`}>
      <div className="h" aria-hidden="true">
        <span className="id">{c.id}</span>
        <span className="nm">{c.cascade}</span>
        {c.trigger && <span className="tg">· {c.trigger} · {c.at}</span>}
        <span className={`out ${c.outcome}`}>{c.outcome === 'error' ? c.error_category : 'ok'}</span>
      </div>
      {showPool && (
        <div className="csc-pool" role="list" aria-label={`Configured pool · ${c.configured.length} models`}>
          <span aria-hidden="true" style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',color:'var(--color-fg-disabled)',letterSpacing:'.08em',textTransform:'uppercase',marginRight:'4px'}}>configured pool ({c.configured.length}):</span>
          {c.configured.map(m => {
            const cls = m === hitModel ? 'hit' : triedSet.has(m) ? 'tried' : '';
            return <span key={m} role="listitem" aria-label={`${m}${cls === 'hit' ? ' (hit)' : cls === 'tried' ? ' (tried)' : ''}`} className={`mp ${cls}`}>{m}</span>;
          })}
        </div>
      )}
      <ol className="hops" aria-label={`${c.hops.length} cascade hops`}>
        {c.hops.map(h => (
          <li key={h.i} className="hop" aria-label={`Step ${h.i} · ${h.model} · ${h.status} · ${fmtMs(h.ms)}${h.reason ? ' · ' + h.reason : ''}`}>
            <span className="step" aria-hidden="true">{h.i}</span>
            <span className="mdl" aria-hidden="true">{compactModel && h.model.length > 24 ? h.model.slice(0,24)+'…' : h.model}</span>
            <span className={`st ${h.status}`} aria-hidden="true">{h.status}</span>
            <span className="ms" aria-hidden="true">{fmtMs(h.ms)}</span>
            {h.reason && <span className="reason" aria-hidden="true">↳ {h.reason}</span>}
          </li>
        ))}
      </ol>
      <div className="ft" aria-hidden="true">
        {showPool ? <span>PRIMARY · {c.primary}</span> : null}
        <span>HOPS · {c.hops.length}{showPool ? `/${c.configured.length}` : ''}</span>
        <span>TOTAL · <span className="ms">{fmtMs(c.total_ms)}</span></span>
        {c.selected && <span>SELECTED · {c.selected}</span>}
      </div>
    </article>
  );
}

// O1-A · Cascade list
function CascadeList() {
  return (
    <div className="csc-list" role="list" aria-label={`${P2f.cascadeAudit.length} cascade runs`}>
      {P2f.cascadeAudit.map(c => (
        <div key={c.id} role="listitem"><CascadeCard c={c} /></div>
      ))}
    </div>
  );
}

// O1-B · Cascade deep-dive
function CascadeDeepDive() {
  const c = P2f.cascadeAudit[0];
  const triedSet = new Set(c.hops.map(h => h.model));
  const hitModel = c.hops.find(h => h.status === 'hit')?.model;
  return (
    <section aria-label={`Cascade deep dive · ${c.id} · ${c.error_category}`} style={{borderLeftWidth:'3px'}}>
      <CascadeCard c={c} hitModel={hitModel} triedSet={triedSet} showPool />
    </section>
  );
}

// O1-C · Cascade compare
function CascadeCompare() {
  const failed = P2f.cascadeAudit.find(c => c.outcome === 'error');
  const ok = P2f.cascadeAudit.find(c => c.outcome === 'ok');
  return (
    <div role="group" aria-label="Cascade comparison · success vs failure" style={{display:'grid', gridTemplateColumns:'1fr 1fr', gap:'8px'}}>
      {[failed, ok].map(c => (
        <CascadeCard key={c.id} c={c} compactModel />
      ))}
    </div>
  );
}

// ═════════════════════════════════════════════════════════════════
// O2 · AUDIT LEDGER
// ═════════════════════════════════════════════════════════════════

function AuditLedgerHeader({ left, right }) {
  return (
    <div role="heading" aria-level={3} style={{padding:'5px 8px',borderBottom:'1px solid var(--line-2)',display:'flex',gap:'8px',background:'var(--color-bg-panel-alt)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--color-fg-disabled)'}}>
      <span>{left}</span>
      <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>{right}</span>
    </div>
  );
}

function AuditRow({ e }) {
  const [cat] = e.kind.split('.');
  return (
    <div className="aud-row" role="listitem" aria-label={`${e.ts.replace('Z','')} · ${e.kind} · ${e.actor} · ${e.subject}${e.duration > 0 ? ' · ' + fmtMs(e.duration) : ''}`}>
      <span className="ts" aria-hidden="true">{e.ts.replace('Z','')}</span>
      <span className={`kn ${cat}`} aria-hidden="true">{e.kind}</span>
      <span className="ac" aria-hidden="true">{e.actor}</span>
      <span className="sb" aria-hidden="true">
        {e.subject}
        {Object.keys(e.payload || {}).length > 0 && (
          <span className="pl">↳ {Object.entries(e.payload).map(([k,v]) => `${k}=${v}`).join(' · ')}</span>
        )}
      </span>
      <span className="du" aria-hidden="true">{e.duration > 0 ? fmtMs(e.duration) : '—'}</span>
    </div>
  );
}

function AuditLedger() {
  return (
    <section aria-label="Audit ledger" style={{background:'var(--color-bg-surface)',border:'1px solid var(--line-2)'}}>
      <AuditLedgerHeader left="tail · audit.jsonl" right={`${P2f.auditEvents.length} events`} />
      <div role="log" aria-live="polite" aria-label={`${P2f.auditEvents.length} audit events`}>
        {P2f.auditEvents.map((e, i) => <AuditRow key={i} e={e} />)}
      </div>
    </section>
  );
}

function AuditByActor() {
  const actor = 'sangsu';
  const filtered = P2f.auditEvents.filter(e => e.actor === actor || e.subject.includes(actor));
  return (
    <section aria-label={`Audit ledger filtered by actor ${actor}`} style={{background:'var(--color-bg-surface)',border:'1px solid var(--line-2)'}}>
      <AuditLedgerHeader left={`filter · actor=${actor}`} right={`${filtered.length} matches`} />
      <div role="list" aria-label={`${filtered.length} matching audit events`}>
        {filtered.map((e, i) => <AuditRow key={i} e={e} />)}
      </div>
    </section>
  );
}

function AuditSummary() {
  const counts = {};
  P2f.auditEvents.forEach(e => {
    counts[e.kind] = (counts[e.kind] || 0) + 1;
  });
  const sorted = Object.entries(counts).sort((a,b) => b[1] - a[1]);
  const total = P2f.auditEvents.length;
  return (
    <section aria-label={`Audit summary · ${sorted.length} kinds · ${total} events`} style={{display:'flex',flexDirection:'column',gap:'2px'}}>
      <div role="heading" aria-level={3} style={{padding:'5px 8px',background:'var(--color-bg-panel-alt)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--color-fg-disabled)',display:'flex'}}>
        <span>summary · last 12 events</span>
        <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>{total} total</span>
      </div>
      <div role="list" aria-label="Event kind summary rows">
        {sorted.map(([kind, n]) => {
          const [cat] = kind.split('.');
          const pct = (n / total * 100).toFixed(0);
          return (
            <div key={kind} role="listitem" aria-label={`${kind}: ${n} events (${pct}%)`} style={{display:'grid',gridTemplateColumns:'140px 30px 1fr',gap:'6px',alignItems:'center',padding:'3px 8px',background:'var(--color-bg-surface)',border:'1px solid var(--line-1)'}}>
              <span className={`kn ${cat}`} aria-hidden="true" style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',padding:'1px 5px',border:'1px solid var(--line-2)',justifySelf:'flex-start'}}>{kind}</span>
              <span aria-hidden="true" style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-11)',color:'var(--brass-1)',fontVariantNumeric:'tabular-nums',textAlign:'right'}}>{n}</span>
              <div aria-hidden="true" style={{height:'10px',background:'var(--color-bg-panel-alt)',border:'1px solid var(--line-1)',position:'relative'}}>
                <div style={{height:'100%',width:`${pct}%`,background:'linear-gradient(90deg, var(--brass-3), var(--brass-1))'}}></div>
              </div>
            </div>
          );
        })}
      </div>
    </section>
  );
}

// ═════════════════════════════════════════════════════════════════
// O3 · SAFE AUTONOMY DASHBOARD
// ═════════════════════════════════════════════════════════════════

function SafeAutoHero() {
  const sa = P2f.safeAutonomy;
  return (
    <div className="sa-hero" role="region" aria-label={`Safe Autonomy Score: ${sa.global_score}, status ${sa.status}, ${sa.findings_total} findings (${sa.findings.filter(f=>f.sev==='high').length} high), ${sa.keeper_count} keepers audited, last run ${sa.last_run.replace('Z','')}, trend −4 vs 24h ago`}>
      <div className="gauge" aria-hidden="true">
        <span className="lbl">Safe Autonomy Score</span>
        <span className={`v ${sa.status}`}>{sa.global_score}</span>
        <span className="st">{sa.status}</span>
      </div>
      <div className="meta" aria-hidden="true">
        <span className="k">findings</span><span className="v">{sa.findings_total} ({sa.findings.filter(f=>f.sev==='high').length} high)</span>
        <span className="k">keepers audited</span><span className="v">{sa.keeper_count}</span>
        <span className="k">last run</span><span className="v">{sa.last_run.replace('Z','')}</span>
        <span className="k">trend</span><span className="v" style={{color:'var(--err-fg)'}}>−4 vs 24h ago</span>
      </div>
      <div className="spark" aria-hidden="true">
        <Spark data={sa.history.map(h => h - 70)} bars={sa.history.length} color="brass" />
      </div>
    </div>
  );
}

function SafeAutoDashboard() {
  const sa = P2f.safeAutonomy;
  return (
    <section aria-label="Safe Autonomy dashboard · score and findings" style={{display:'flex',flexDirection:'column',gap:'8px'}}>
      <SafeAutoHero />
      <div style={{background:'var(--color-bg-surface)',border:'1px solid var(--line-2)'}}>
        <div role="heading" aria-level={3} style={{padding:'5px 8px',borderBottom:'1px solid var(--line-2)',display:'flex',gap:'8px',background:'var(--color-bg-panel-alt)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--color-fg-disabled)'}}>
          <span>findings ({sa.findings.length})</span>
          <span style={{marginLeft:'auto'}}>severity ↓</span>
        </div>
        <div role="list" aria-label={`${sa.findings.length} findings`}>
          {sa.findings.map((f, i) => (
            <div key={i} role="listitem" aria-label={`${f.sev} · ${f.keeper} · ${f.rule} · ${f.file}:${f.line}`} className="sa-find">
              <span className={`sev ${f.sev}`} aria-hidden="true">{f.sev}</span>
              <span className="kpr" aria-hidden="true">{f.keeper}</span>
              <span className="rule" aria-hidden="true">{f.rule}</span>
              <span className="loc" aria-hidden="true">{f.file}<span className="ln">:{f.line}</span></span>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

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
    <section aria-label={`Safe Autonomy findings · by keeper · ${sorted.length} keepers`} style={{display:'flex',flexDirection:'column',gap:'4px'}}>
      <div role="heading" aria-level={3} style={{padding:'5px 8px',background:'var(--color-bg-panel-alt)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--color-fg-disabled)',display:'flex'}}>
        <span>findings by keeper</span>
        <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>{sorted.length} keepers</span>
      </div>
      <div role="list">
        {sorted.map(([k, v]) => (
          <div key={k} role="listitem" aria-label={`${k} · ${v.high} high, ${v.medium} medium, ${v.low} low`} style={{display:'grid',gridTemplateColumns:'120px 60px 60px 60px 1fr',gap:'6px',alignItems:'center',padding:'4px 8px',background:'var(--color-bg-surface)',border:'1px solid var(--line-1)'}}>
            <span aria-hidden="true" style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-11)',color:'var(--brass-1)'}}>{k}</span>
            <span className="sev high"   aria-hidden="true" style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',padding:'1px 5px',textAlign:'center',opacity: v.high?1:0.15}}>{v.high}</span>
            <span className="sev medium" aria-hidden="true" style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',padding:'1px 5px',textAlign:'center',opacity: v.medium?1:0.15}}>{v.medium}</span>
            <span className="sev low"    aria-hidden="true" style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',padding:'1px 5px',textAlign:'center',opacity: v.low?1:0.15}}>{v.low}</span>
            <span aria-hidden="true" style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',color:'var(--color-fg-muted)'}}>{v.items.map(i=>i.rule.split(' ')[0]).join(' · ')}</span>
          </div>
        ))}
      </div>
    </section>
  );
}

function SafeAutoTrend() {
  const sa = P2f.safeAutonomy;
  const min = Math.min(...sa.history);
  const max = Math.max(...sa.history);
  return (
    <section aria-label={`Safe Autonomy trend · last 15 runs · min ${min}, current ${sa.global_score}, max ${max}`} style={{background:'var(--color-bg-surface)',border:'1px solid var(--line-2)',padding:'12px'}}>
      <div role="heading" aria-level={3} style={{display:'flex',gap:'12px',alignItems:'baseline',marginBottom:'8px',fontFamily:'var(--font-mono)'}}>
        <span style={{fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--color-fg-disabled)'}}>autonomy score · last 15 runs</span>
        <span style={{marginLeft:'auto',fontSize:'var(--fs-10)',color:'var(--color-fg-muted)'}}>min {min} · current <span style={{color:'var(--err-fg)'}}>{sa.global_score}</span> · max {max}</span>
      </div>
      <div aria-hidden="true" style={{display:'flex',alignItems:'flex-end',height:'80px',gap:'3px'}}>
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
      <div aria-hidden="true" style={{display:'flex',justifyContent:'space-between',marginTop:'4px',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',color:'var(--color-fg-disabled)'}}>
        <span>−15</span><span>now</span>
      </div>
    </section>
  );
}

// ═════════════════════════════════════════════════════════════════
// O4 · COST DASHBOARD
// ═════════════════════════════════════════════════════════════════

function CostPerAgent() {
  const rows = [...P2f.costs.perAgent].sort((a,b) => b.cost - a.cost);
  const maxCost = Math.max(...rows.map(r => r.cost));
  const maxLat = Math.max(...rows.map(r => r.p95_ms));
  return (
    <section aria-label={`Cost dashboard · per agent · total $${P2f.costs.total_cost_usd.toFixed(2)}`} style={{display:'flex',flexDirection:'column',gap:'8px'}}>
      <div className="cs-tot" role="list" aria-label="Cost totals">
        <div className="cell" role="listitem" aria-label={`Total Cost: $${P2f.costs.total_cost_usd.toFixed(2)}, last 24h`}>
          <span className="lbl" aria-hidden="true">Total Cost</span>
          <span className="v" aria-hidden="true">${P2f.costs.total_cost_usd.toFixed(2)}</span>
          <span className="sub" aria-hidden="true">last 24h</span>
        </div>
        <div className="cell" role="listitem" aria-label={`Tokens In: ${(rows.reduce((s,r)=>s+r.in_tok,0)/1e6).toFixed(2)}M, 9 agents`}>
          <span className="lbl" aria-hidden="true">Tokens In</span>
          <span className="v" aria-hidden="true">{(rows.reduce((s,r)=>s+r.in_tok,0)/1e6).toFixed(2)}M</span>
          <span className="sub" aria-hidden="true">9 agents</span>
        </div>
        <div className="cell" role="listitem" aria-label={`p50 Latency: ${P2f.costs.p50}ms, global`}>
          <span className="lbl" aria-hidden="true">p50 Latency</span>
          <span className="v" aria-hidden="true">{P2f.costs.p50}<span style={{fontSize:'12px',color:'var(--color-fg-muted)'}}>ms</span></span>
          <span className="sub" aria-hidden="true">global</span>
        </div>
        <div className="cell" role="listitem" aria-label={`p95 Latency: ${P2f.costs.p95}ms, over budget`}>
          <span className="lbl" aria-hidden="true">p95 Latency</span>
          <span className="v" aria-hidden="true" style={{color:'var(--err-fg)'}}>{P2f.costs.p95}<span style={{fontSize:'12px',color:'var(--color-fg-muted)'}}>ms</span></span>
          <span className="sub" aria-hidden="true">over budget</span>
        </div>
      </div>
      <table className="cb-table cs-tbl" aria-label={`Per-agent cost table · ${rows.length} agents`}>
        <thead>
          <tr>
            <th scope="col">Agent</th>
            <th scope="col">In Tok</th>
            <th scope="col">Out Tok</th>
            <th scope="col">$ Cost</th>
            <th scope="col">Cost</th>
            <th scope="col">p50</th>
            <th scope="col">p95</th>
            <th scope="col">p95 trend</th>
          </tr>
        </thead>
        <tbody>
          {rows.map(r => (
            <tr key={r.agent}>
              <th scope="row" style={{color:'var(--brass-1)'}}>{r.agent}</th>
              <td className="lat-num">{(r.in_tok/1000).toFixed(0)}k</td>
              <td className="lat-num">{(r.out_tok/1000).toFixed(1)}k</td>
              <td className="lat-num" style={{color:'var(--brass-1)'}}>${r.cost.toFixed(2)}</td>
              <td className="bar" aria-hidden="true"><i style={{width:`${r.cost/maxCost*100}%`}}></i></td>
              <td className="lat-num">{r.p50_ms}</td>
              <td className={`lat-num ${r.p95_ms > 8000 ? 'bad' : ''}`} aria-label={`${r.p95_ms}ms${r.p95_ms > 8000 ? ' · over budget' : ''}`}>{r.p95_ms}</td>
              <td className="bar lat" aria-hidden="true"><i style={{width:`${r.p95_ms/maxLat*100}%`}}></i></td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}

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
    <section aria-label={`Cost matrix · provider × model · total $${P2f.costs.total_cost_usd.toFixed(2)} over 24h`} style={{display:'flex',flexDirection:'column',gap:'8px'}}>
      <div role="heading" aria-level={3} style={{padding:'5px 8px',background:'var(--color-bg-panel-alt)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--color-fg-disabled)',display:'flex'}}>
        <span>provider × model · $ spent (24h)</span>
        <span style={{marginLeft:'auto',color:'var(--brass-1)'}}>${P2f.costs.total_cost_usd.toFixed(2)}</span>
      </div>
      <table className="cs-mat" aria-label="Provider × model cost matrix">
        <thead>
          <tr>
            <th scope="col"></th>
            {m.models.map(md => <th key={md} scope="col">{md}</th>)}
          </tr>
        </thead>
        <tbody>
          {m.providers.map((p, i) => (
            <tr key={p}>
              <th className="row-h" scope="row">{p}</th>
              {m.grid[i].map((v, j) => (
                <td key={j} className={zone(v)} aria-label={`${p} × ${m.models[j]}: ${v > 0 ? '$' + v.toFixed(2) : 'no spend'}`}>{v > 0 ? `$${v.toFixed(2)}` : '—'}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}

function CostLatency() {
  const buckets = P2f.costs.latencyBuckets;
  const max = Math.max(...buckets.map(b => b.n));
  const total = buckets.reduce((s,b) => s+b.n, 0);
  return (
    <section aria-label={`Cost latency distribution · ${total} calls · p50 ${P2f.costs.p50}ms · p95 ${P2f.costs.p95}ms`} style={{display:'flex',flexDirection:'column',gap:'8px'}}>
      <div role="heading" aria-level={3} style={{padding:'5px 8px',background:'var(--color-bg-panel-alt)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--color-fg-disabled)',display:'flex',gap:'12px'}}>
        <span>latency distribution · {total} calls</span>
        <span style={{marginLeft:'auto'}}>p50 · <span style={{color:'var(--brass-1)'}}>{P2f.costs.p50}ms</span></span>
        <span>p95 · <span style={{color:'var(--err-fg)'}}>{P2f.costs.p95}ms</span></span>
      </div>
      <div className="cs-hist" role="img" aria-label={`Latency histogram · ${buckets.length} buckets`}>
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
      <div role="list" aria-label="Latency band totals" style={{display:'grid',gridTemplateColumns:'repeat(4, 1fr)',gap:'1px',background:'var(--line-2)',border:'1px solid var(--line-2)'}}>
        {[
          { l:'< 1s',  v: buckets.filter(b=>b.hi<=1000).reduce((s,b)=>s+b.n,0), c:'var(--ok-fg)' },
          { l:'1–4s',  v: buckets.filter(b=>b.lo>=1000&&b.hi<=4000).reduce((s,b)=>s+b.n,0), c:'var(--brass-1)' },
          { l:'4–16s', v: buckets.filter(b=>b.lo>=4000&&b.hi<=16000).reduce((s,b)=>s+b.n,0), c:'var(--warn)' },
          { l:'> 16s', v: buckets.filter(b=>b.lo>=16000).reduce((s,b)=>s+b.n,0), c:'var(--err-fg)' },
        ].map(b => (
          <div key={b.l} role="listitem" aria-label={`${b.l}: ${b.v} calls (${(b.v/total*100).toFixed(0)}%)`} style={{background:'var(--color-bg-surface)',padding:'6px 10px',display:'flex',flexDirection:'column',gap:'2px'}}>
            <span aria-hidden="true" style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--color-fg-disabled)'}}>{b.l}</span>
            <span aria-hidden="true" style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-13)',color:b.c,fontVariantNumeric:'tabular-nums'}}>{b.v}<span style={{fontSize:'var(--fs-10)',color:'var(--color-fg-disabled)',marginLeft:'4px'}}>· {(b.v/total*100).toFixed(0)}%</span></span>
          </div>
        ))}
      </div>
    </section>
  );
}

// ═════════════════════════════════════════════════════════════════
// O5 · HEURISTIC + STRESS
// ═════════════════════════════════════════════════════════════════

function HeuristicLog() {
  return (
    <section aria-label={`Heuristic firing log · ${P2f.heuristics.filter(h=>h.triggered).length} fired of ${P2f.heuristics.length}`} style={{background:'var(--color-bg-surface)',border:'1px solid var(--line-2)'}}>
      <div role="heading" aria-level={3} style={{padding:'5px 8px',borderBottom:'1px solid var(--line-2)',display:'flex',gap:'8px',background:'var(--color-bg-panel-alt)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--color-fg-disabled)'}}>
        <span>tail · keeper_hooks_oas.heuristics.jsonl</span>
        <span style={{marginLeft:'auto',color:'var(--err-fg)'}}>{P2f.heuristics.filter(h=>h.triggered).length}/{P2f.heuristics.length} fired</span>
      </div>
      <div role="log" aria-live="polite" aria-label={`${P2f.heuristics.length} heuristic rows`}>
        {P2f.heuristics.map((h, i) => (
          <div key={i} role="listitem" aria-label={`${h.ts.replace('Z','')} · ${h.module} · ${h.site} · value ${h.value} threshold ${h.threshold} · ${h.triggered ? 'fire' : 'ok'}${h.detail ? ' · ' + h.detail : ''}`} className={`hr-row ${h.triggered ? 'fired' : ''}`}>
            <span className="ts" aria-hidden="true">{h.ts.replace('Z','')}</span>
            <span className="mod" aria-hidden="true">{h.module}</span>
            <span className="site" aria-hidden="true">{h.site}<span className="det" style={{display:'block'}}>↳ {h.detail}</span></span>
            <span className="num" aria-hidden="true">value · <span className={h.triggered?'over':''}>{h.value}</span></span>
            <span className="num" aria-hidden="true">thr · {h.threshold}</span>
            <span className={`fl ${h.triggered ? 't' : 'f'}`} aria-hidden="true">{h.triggered ? 'fire' : 'ok'}</span>
          </div>
        ))}
      </div>
    </section>
  );
}

function StressBoard() {
  return (
    <section aria-label={`Agent stress board · ${P2f.stress.length} active stressors`} style={{display:'flex',flexDirection:'column',gap:'8px'}}>
      <div role="heading" aria-level={3} style={{padding:'5px 8px',background:'var(--color-bg-panel-alt)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--color-fg-disabled)',display:'flex'}}>
        <span>agent stress · agent_stress.jsonl</span>
        <span style={{marginLeft:'auto',color:'var(--err-fg)'}}>{P2f.stress.length} active</span>
      </div>
      <div className="st-grid" role="list" aria-label="Stress cards">
        {P2f.stress.map((s, i) => (
          <article key={i} role="listitem" aria-label={`${s.agent} · ${s.kind} · count ${s.count} · room ${s.room} · ${s.at.replace('Z','')}`} className={`scard ${s.kind}`}>
            <div className="h" aria-hidden="true">
              <span className="ag">{s.agent}</span>
              <span className="at">{s.at.replace('Z','')}</span>
            </div>
            <span className="kind" aria-hidden="true">{s.kind}</span>
            <span className="cn" aria-hidden="true">count · <span className="v">{s.count}</span> · room {s.room}</span>
          </article>
        ))}
      </div>
    </section>
  );
}

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
    <section aria-label={`Heuristic firing rate by module · ${rows.length} modules`} style={{display:'flex',flexDirection:'column',gap:'4px'}}>
      <div role="heading" aria-level={3} style={{padding:'5px 8px',background:'var(--color-bg-panel-alt)',border:'1px solid var(--line-2)',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',letterSpacing:'.12em',textTransform:'uppercase',color:'var(--color-fg-disabled)',display:'flex'}}>
        <span>heuristic firing rate · by module</span>
      </div>
      <div role="list">
        {rows.map(([mod, v]) => {
          const pct = v.total > 0 ? v.fired / v.total * 100 : 0;
          return (
            <div key={mod} role="listitem" aria-label={`${mod} · ${v.fired} of ${v.total} fired (${pct.toFixed(0)}%) · sites ${[...v.sites].join(', ')}`} style={{display:'grid',gridTemplateColumns:'160px 80px 1fr 60px',gap:'8px',alignItems:'center',padding:'5px 8px',background:'var(--color-bg-surface)',border:'1px solid var(--line-1)'}}>
              <span aria-hidden="true" style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-11)',color:'var(--color-fg-primary)'}}>{mod}</span>
              <span aria-hidden="true" style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-10)',color:'var(--color-fg-muted)'}}>{v.fired}/{v.total} fired</span>
              <div aria-hidden="true" style={{height:'10px',background:'var(--color-bg-panel-alt)',border:'1px solid var(--line-1)'}}>
                <div style={{height:'100%',width:`${pct}%`,background: pct > 50 ? 'linear-gradient(90deg, var(--warn), var(--err))' : 'linear-gradient(90deg, var(--brass-3), var(--brass-1))'}}></div>
              </div>
              <span aria-hidden="true" style={{fontFamily:'var(--font-mono)',fontSize:'var(--fs-11)',color: pct > 50 ? 'var(--err-fg)' : 'var(--brass-1)',fontVariantNumeric:'tabular-nums',textAlign:'right'}}>{pct.toFixed(0)}%</span>
              <span aria-hidden="true" style={{gridColumn:'1 / -1',fontFamily:'var(--font-mono)',fontSize:'var(--fs-9)',color:'var(--color-fg-disabled)',letterSpacing:'.04em'}}>sites · {[...v.sites].join(' · ')}</span>
            </div>
          );
        })}
      </div>
    </section>
  );
}

Object.assign(window, {
  CascadeList, CascadeDeepDive, CascadeCompare,
  AuditLedger, AuditByActor, AuditSummary,
  SafeAutoDashboard, SafeAutoByKeeper, SafeAutoTrend,
  CostPerAgent, CostMatrix, CostLatency,
  HeuristicLog, StressBoard, HeuristicByModule,
});
