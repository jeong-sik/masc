// cb-group-c.jsx — Composer, Status Bar, Drawer
const D3 = window.MASC_DATA;

// ─── COMPOSER variants ─────────────────────────────────────────────
function ComposerPrompt() {
  const typed = useTyping([
    'keeper.claim("t-9f2a")',
    'keeper.retire("t-d551")',
    'cascade.run(goal="goal-merge-blockers")',
    'suite.rerun("suite-merge-blockers")',
  ], 22);
  return (
    <div className="cb-board">
      <div style={{flex:1, background:'var(--bg-0)'}} aria-hidden="true" />
      <div className="cb-composer" role="region" aria-label="Command composer">
        <div className="line" aria-live="polite">
          <span className="prompt" aria-hidden="true">masc&gt;</span>
          <span aria-label={`Current input: ${typed}`}>{typed}</span>
          <span className="caret" aria-hidden="true" style={{color:'var(--brass-1)'}}>▌</span>
        </div>
        <div className="hint" aria-hidden="true">
          <span><span className="kbd">⌘K</span>command</span>
          <span><span className="kbd">⌘↵</span>run</span>
          <span><span className="kbd">↑</span>history</span>
          <span><span className="kbd">esc</span>clear</span>
        </div>
      </div>
    </div>
  );
}

function ComposerSuggest() {
  const [on, setOn] = useState(0);
  const sugs = [
    { kind:'fn',   name:'keeper.claim',      desc:'claim a task for a keeper' },
    { kind:'fn',   name:'keeper.retire',     desc:'retire a stalled keeper' },
    { kind:'fn',   name:'cascade.run',       desc:'run the cascade chain' },
    { kind:'task', name:'t-9f2a',            desc:'Rebase PR #9712 + green CI' },
    { kind:'goal', name:'goal-merge-blockers', desc:'Merge-blocker 해결' },
  ];
  return (
    <div className="cb-board">
      <div style={{flex:1, background:'var(--bg-0)'}} aria-hidden="true" />
      <div className="cb-composer" role="region" aria-label="Command composer with suggestions" style={{position:'relative'}}>
        <div className="sug" role="listbox" aria-label="Command suggestions">
          {sugs.map((s, i) => (
            <div key={i}
                 role="option"
                 aria-selected={on===i}
                 aria-label={`${s.kind} ${s.name}: ${s.desc}`}
                 tabIndex={on===i ? 0 : -1}
                 className={`item ${on===i?'on':''}`}
                 onMouseEnter={()=>setOn(i)}>
              <span className="kind" aria-hidden="true">{s.kind}</span>
              <span aria-hidden="true" style={{color:'var(--fg-1)'}}>{s.name}</span>
              <span aria-hidden="true" style={{color:'var(--fg-3)', marginLeft:8}}>{s.desc}</span>
            </div>
          ))}
        </div>
        <div className="line">
          <span className="prompt" aria-hidden="true">masc&gt;</span>
          <span className="fn" aria-label="Current input: keeper.">keeper.</span>
          <span className="caret" aria-hidden="true" style={{color:'var(--brass-1)'}}>▌</span>
        </div>
        <div className="hint" aria-hidden="true">
          <span><span className="kbd">↑↓</span>move</span>
          <span><span className="kbd">⇥</span>accept</span>
          <span><span className="kbd">esc</span>dismiss</span>
        </div>
      </div>
    </div>
  );
}

function ComposerMultiLine() {
  return (
    <div className="cb-board">
      <div style={{flex:1, background:'var(--bg-0)'}} aria-hidden="true" />
      <div className="cb-composer" role="region" aria-label="Multi-line command composer">
        <pre aria-label="cascade.run(goal=&quot;goal-merge-blockers&quot;, providers=[anthropic, moonshot], dry_run=false)" style={{margin:0, font:'inherit', background:'transparent'}}>
          <div className="line">
            <span className="prompt" aria-hidden="true">masc&gt;</span>
            <span className="fn" aria-hidden="true">cascade.run</span>
            <span aria-hidden="true">(</span>
          </div>
          <div className="line" style={{paddingLeft:18}} aria-hidden="true">
            <span className="arg">goal</span>
            <span>=</span>
            <span className="str">"goal-merge-blockers"</span>
            <span>,</span>
          </div>
          <div className="line" style={{paddingLeft:18}} aria-hidden="true">
            <span className="arg">providers</span>
            <span>=</span>
            <span>[</span>
            <Chip kind="ghost">anthropic</Chip>
            <Chip kind="ghost">moonshot</Chip>
            <span>]</span>
            <span>,</span>
          </div>
          <div className="line" style={{paddingLeft:18}} aria-hidden="true">
            <span className="arg">dry_run</span>
            <span>=</span>
            <span className="fn">false</span>
            <span className="caret" style={{color:'var(--brass-1)'}}>▌</span>
          </div>
          <div className="line" aria-hidden="true">
            <span>)</span>
          </div>
        </pre>
        <div className="hint" aria-hidden="true">
          <span><span className="kbd">⌘↵</span>run</span>
          <span><span className="kbd">⇧↵</span>newline</span>
          <span style={{marginLeft:'auto', color:'var(--fg-4)'}}>4 lines · will burn ~1.2s</span>
        </div>
      </div>
    </div>
  );
}

// ─── STATUS BAR variants ───────────────────────────────────────────
function StatusStandard() {
  return (
    <div className="cb-board">
      <div style={{flex:1, background:'var(--bg-0)'}} aria-hidden="true" />
      <div className="cb-statusbar" role="status" aria-live="polite" aria-label="System status: connected, build 2604, version 0.42.1, anthropic ok, moonshot ok, openai degraded, xai offline, TPS 1.24s, time 16:32:45 UTC">
        <span className="seg"><span className="on" aria-hidden="true">●</span>CONNECTED</span>
        <span className="sep" aria-hidden="true" />
        <span className="seg">BUILD <span className="brass">2604</span></span>
        <span className="seg">v0.42.1</span>
        <span className="sep" aria-hidden="true" />
        <span className="seg">PROVIDERS</span>
        <span className="seg"><span className="on" aria-hidden="true">●</span>anthropic</span>
        <span className="seg"><span className="on" aria-hidden="true">●</span>moonshot</span>
        <span className="seg" style={{color:'var(--warn-fg)'}}><span aria-hidden="true">●</span>openai</span>
        <span className="seg off"><span aria-hidden="true">●</span>xai</span>
        <span className="seg push-right">TPS <span className="brass">1.24s</span></span>
        <span className="sep" aria-hidden="true" />
        <span className="seg">16:32:45Z</span>
      </div>
    </div>
  );
}

function StatusCompact() {
  return (
    <div className="cb-board">
      <div style={{flex:1, background:'var(--bg-0)'}} aria-hidden="true" />
      <div className="cb-statusbar" role="status" aria-live="polite" aria-label="MASC: 5 of 8 keepers active, 3 providers ok, TPS 1.24s">
        <span className="seg"><span className="brass" aria-hidden="true">●</span>MASC</span>
        <span className="seg">5/8 ACTIVE</span>
        <span className="seg push-right" aria-hidden="true"><span className="on">●●●</span><span className="off">●</span></span>
        <span className="seg">1.24s</span>
      </div>
    </div>
  );
}

function StatusVerbose() {
  return (
    <div className="cb-board">
      <div style={{flex:1, background:'var(--bg-0)'}} aria-hidden="true" />
      <div className="cb-statusbar" role="status" aria-live="polite" aria-label="Connected · goal goal-merge-blockers, task t-9f2a, keeper nick0cave, cascade hit at step 2 in 1.24s, suite 3 fail of 47 pass" style={{height:28, flexWrap:'wrap'}}>
        <span className="seg"><span className="on" aria-hidden="true">●</span>CONNECTED</span>
        <span className="sep" aria-hidden="true" />
        <span className="seg">goal <span className="brass">goal-merge-blockers</span></span>
        <span className="seg">task <span style={{color:'var(--fg-2)'}}>t-9f2a</span></span>
        <span className="seg">keeper <span style={{color:'var(--brass-1)'}}>nick0cave</span></span>
        <span className="sep" aria-hidden="true" />
        <span className="seg">CASCADE hit@2 · <span className="brass">1.24s</span></span>
        <span className="sep" aria-hidden="true" />
        <span className="seg">SUITE <span style={{color:'var(--err-fg)'}}>3 FAIL</span> / 47 PASS</span>
        <span className="seg push-right" aria-hidden="true">⌘K for commands</span>
      </div>
    </div>
  );
}

// ─── DRAWER variants ───────────────────────────────────────────────
function DrawerTask() {
  return (
    <div className="cb-drawer" role="dialog" aria-label="Task drawer · t-9f2a · Rebase PR #9712 + green CI · running">
      <div className="head">
        <div className="idrow">
          <span>t-9f2a</span>
          <span aria-hidden="true">·</span>
          <span>goal-merge-blockers</span>
          <button type="button" className="close" aria-label="Close drawer">×</button>
        </div>
        <div className="title" role="heading" aria-level={2}>Rebase PR #9712 + green CI</div>
        <div className="meta">
          <Chip kind="brass"><Dot kind="brass" size="sm" beat /> RUNNING</Chip>
          <Chip kind="ghost">P1</Chip>
          <Chip kind="ghost">2m ago</Chip>
        </div>
      </div>
      <div className="body">
        <section aria-labelledby="drawer-task-details">
          <div className="sec-title" id="drawer-task-details" role="heading" aria-level={3}>DETAILS</div>
          <dl className="kv">
            <dt>KEEPER</dt><dd>nick0cave</dd>
            <dt>TOOL</dt><dd>tool.write_file</dd>
            <dt>DIFF</dt><dd>+18 −4 · keeper.ts</dd>
            <dt>STARTED</dt><dd>16:31:27Z</dd>
            <dt>CASCADE</dt><dd>moonshot @step=2 · 1.24s</dd>
          </dl>
        </section>
        <section aria-labelledby="drawer-task-review">
          <div className="sec-title" id="drawer-task-review" role="heading" aria-level={3}>REVIEW · 3</div>
          <div className="thread" role="log" aria-live="polite" aria-label="Review thread, 3 comments">
            <div className="cmt flag" role="article" aria-label="Flag from sangsu, 3 minutes ago: drift detected at pipeline.ts L187 — signature mismatch">
              <div className="h" aria-hidden="true">
                <span className="kind">FLAG</span>
                <span style={{color:'var(--fg-2)'}}>sangsu</span>
                <span className="t">3m ago</span>
              </div>
              <div className="body">drift detected at pipeline.ts L187 — signature mismatch</div>
            </div>
            <div className="cmt question" role="article" aria-label="Question from qa-king, 2 minutes ago: is the backport going to re-open suite-merge-blockers?">
              <div className="h" aria-hidden="true">
                <span className="kind">QUESTION</span>
                <span style={{color:'var(--fg-2)'}}>qa-king</span>
                <span className="t">2m ago</span>
              </div>
              <div className="body">is the backport going to re-open suite-merge-blockers?</div>
            </div>
            <div className="cmt note" role="article" aria-label="Note from nick0cave, 1 minute ago: rebased on release-0.42, re-running CI">
              <div className="h" aria-hidden="true">
                <span className="kind">NOTE</span>
                <span style={{color:'var(--fg-2)'}}>nick0cave</span>
                <span className="t">1m ago</span>
              </div>
              <div className="body">rebased on release-0.42 · re-running CI</div>
            </div>
          </div>
        </section>
      </div>
      <div className="acts" role="toolbar" aria-label="Task actions">
        <button type="button" className="btn primary">APPROVE</button>
        <button type="button" className="btn">CLAIM</button>
        <button type="button" className="btn">FLAG</button>
        <button type="button" className="btn danger" style={{marginLeft:'auto'}}>RETIRE</button>
      </div>
    </div>
  );
}

function DrawerGoal() {
  const g = D3.goals[1];
  return (
    <div className="cb-drawer" role="dialog" aria-label={`Goal drawer · ${g.id} · ${g.title} · ${g.progress} of ${g.total} · priority ${g.priority}`}>
      <div className="head">
        <div className="idrow">
          <span>{g.id}</span>
          <span aria-hidden="true">·</span>
          <span>P{g.priority}</span>
          <button type="button" className="close" aria-label="Close drawer">×</button>
        </div>
        <div className="title" role="heading" aria-level={2}>{g.title}</div>
        <div className="meta">
          <Chip kind="brass">ACTIVE</Chip>
          <Chip kind="ghost">{g.progress}/{g.total}</Chip>
          <span className="bar" aria-hidden="true" style={{width:100, alignSelf:'center'}}><span className="fill" style={{width:`${100*g.progress/g.total}%`}} /></span>
        </div>
      </div>
      <div className="body">
        <section aria-labelledby="drawer-goal-tasks">
          <div className="sec-title" id="drawer-goal-tasks" role="heading" aria-level={3}>TASKS · 5</div>
          <div role="list" aria-label="Tasks under this goal" style={{display:'flex', flexDirection:'column', gap:4}}>
            {(() => {
              const seen = new Set();
              return D3.tasks.filter(t=>t.goal==='goal-keeper-clarity').concat(D3.tasks.slice(2,5)).filter(t=>{ if(seen.has(t.id)) return false; seen.add(t.id); return true; }).slice(0,5);
            })().map(t=>(
              <div key={t.id}
                   role="listitem"
                   aria-label={`${t.id} · ${t.title} · ${t.keeper} · ${t.status}`}
                   style={{display:'flex', alignItems:'center', gap:7, padding:'4px 7px', background:'var(--bg-1)', border:'1px solid var(--line-1)', borderRadius:3, fontSize:11}}>
                <Dot kind={kClass(t.keeper)} size="sm" />
                <span className="cb-mono" aria-hidden="true" style={{color:'var(--fg-4)'}}>{t.id}</span>
                <span aria-hidden="true" style={{color:'var(--fg-1)', flex:1}}>{t.title}</span>
                <Pill kind={t.status==='running'?'running':t.status==='fail'?'err':t.status==='stalled'?'stalled':'paused'}>{t.status}</Pill>
              </div>
            ))}
          </div>
        </section>
        <section aria-labelledby="drawer-goal-keepers">
          <div className="sec-title" id="drawer-goal-keepers" role="heading" aria-level={3}>KEEPERS</div>
          <dl className="kv">
            <dt>OWNER</dt><dd>masc-improver</dd>
            <dt>CONTRIB</dt><dd>nick0cave · sangsu</dd>
            <dt>OPENED</dt><dd>2026-04-20 09:14Z</dd>
            <dt>TARGET</dt><dd>2026-04-28</dd>
          </dl>
        </section>
      </div>
      <div className="acts" role="toolbar" aria-label="Goal actions">
        <button type="button" className="btn primary">SPAWN TASK</button>
        <button type="button" className="btn">PAUSE GOAL</button>
        <button type="button" className="btn" style={{marginLeft:'auto'}}>PIN</button>
      </div>
    </div>
  );
}

function DrawerKeeper() {
  return (
    <div className="cb-drawer" role="dialog" aria-label="Keeper drawer · nick0cave · captain · running">
      <div className="head">
        <div className="idrow">
          <span>keeper</span>
          <span aria-hidden="true">·</span>
          <span>captain</span>
          <button type="button" className="close" aria-label="Close drawer">×</button>
        </div>
        <div className="title" role="heading" aria-level={2} style={{fontFamily:'var(--font-mono)'}}>
          <Dot kind="brass" beat style={{marginRight:6, verticalAlign:'middle'}} />
          nick0cave
        </div>
        <div className="meta">
          <Chip kind="brass">RUNNING</Chip>
          <Chip kind="ghost">8 TOOL CALLS / 60s</Chip>
          <Chip kind="ghost">anthropic · claude-haiku-4-5</Chip>
        </div>
      </div>
      <div className="body">
        <section aria-labelledby="drawer-keeper-heartbeat">
          <div className="sec-title" id="drawer-keeper-heartbeat" role="heading" aria-level={3}>HEARTBEAT</div>
          <div aria-label="Heartbeat trace, 60-second window" style={{background:'var(--bg-1)', padding:6, border:'1px solid var(--line-1)', borderRadius:3}}>
            <span aria-hidden="true"><Heartbeat width={260} height={40} /></span>
          </div>
        </section>
        <section aria-labelledby="drawer-keeper-current">
          <div className="sec-title" id="drawer-keeper-current" role="heading" aria-level={3}>CURRENT</div>
          <dl className="kv">
            <dt>TASK</dt><dd>t-9f2a</dd>
            <dt>GOAL</dt><dd>goal-merge-blockers</dd>
            <dt>TOOL</dt><dd>tool.write_file</dd>
            <dt>TPS</dt><dd>1.24s</dd>
            <dt>UPTIME</dt><dd>47m 12s</dd>
          </dl>
        </section>
        <section aria-labelledby="drawer-keeper-events">
          <div className="sec-title" id="drawer-keeper-events" role="heading" aria-level={3}>LAST 3 EVENTS</div>
          <div role="log" aria-live="polite" aria-label="Last 3 events from nick0cave" style={{display:'flex', flexDirection:'column', gap:4, fontSize:11}}>
            {D3.events.filter(e=>e.keeper==='nick0cave').slice(0,3).map((e,i)=>(
              <div key={i}
                   role="listitem"
                   aria-label={`${e.t.slice(0,8)} · ${e.text}`}
                   style={{fontFamily:'var(--font-mono)', fontSize:10, color:'var(--fg-2)'}}>
                <span aria-hidden="true" style={{color:'var(--fg-4)'}}>{e.t.slice(0,8)} </span>
                <span aria-hidden="true">{e.text}</span>
              </div>
            ))}
          </div>
        </section>
      </div>
      <div className="acts" role="toolbar" aria-label="Keeper actions">
        <button type="button" className="btn primary">ASSIGN TASK</button>
        <button type="button" className="btn">PAUSE</button>
        <button type="button" className="btn danger" style={{marginLeft:'auto'}}>RETIRE</button>
      </div>
    </div>
  );
}

Object.assign(window, {
  ComposerPrompt, ComposerSuggest, ComposerMultiLine,
  StatusStandard, StatusCompact, StatusVerbose,
  DrawerTask, DrawerGoal, DrawerKeeper,
});
