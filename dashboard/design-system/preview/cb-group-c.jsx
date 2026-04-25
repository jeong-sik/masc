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
      <div style={{flex:1, background:'var(--bg-0)'}} />
      <div className="cb-composer">
        <div className="line">
          <span className="prompt">masc&gt;</span>
          <span>{typed}</span>
          <span className="caret" style={{color:'var(--brass-1)'}}>▌</span>
        </div>
        <div className="hint">
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
      <div style={{flex:1, background:'var(--bg-0)'}} />
      <div className="cb-composer" style={{position:'relative'}}>
        <div className="sug">
          {sugs.map((s, i) => (
            <div key={i} className={`item ${on===i?'on':''}`} onMouseEnter={()=>setOn(i)}>
              <span className="kind">{s.kind}</span>
              <span style={{color:'var(--fg-1)'}}>{s.name}</span>
              <span style={{color:'var(--fg-3)', marginLeft:8}}>{s.desc}</span>
            </div>
          ))}
        </div>
        <div className="line">
          <span className="prompt">masc&gt;</span>
          <span className="fn">keeper.</span>
          <span className="caret" style={{color:'var(--brass-1)'}}>▌</span>
        </div>
        <div className="hint">
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
      <div style={{flex:1, background:'var(--bg-0)'}} />
      <div className="cb-composer">
        <div className="line">
          <span className="prompt">masc&gt;</span>
          <span className="fn">cascade.run</span>
          <span>(</span>
        </div>
        <div className="line" style={{paddingLeft:18}}>
          <span className="arg">goal</span>
          <span>=</span>
          <span className="str">"goal-merge-blockers"</span>
          <span>,</span>
        </div>
        <div className="line" style={{paddingLeft:18}}>
          <span className="arg">providers</span>
          <span>=</span>
          <span>[</span>
          <Chip kind="ghost">anthropic</Chip>
          <Chip kind="ghost">moonshot</Chip>
          <span>]</span>
          <span>,</span>
        </div>
        <div className="line" style={{paddingLeft:18}}>
          <span className="arg">dry_run</span>
          <span>=</span>
          <span className="fn">false</span>
          <span className="caret" style={{color:'var(--brass-1)'}}>▌</span>
        </div>
        <div className="line">
          <span>)</span>
        </div>
        <div className="hint">
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
      <div style={{flex:1, background:'var(--bg-0)'}} />
      <div className="cb-statusbar">
        <span className="seg"><span className="on">●</span>CONNECTED</span>
        <span className="sep" />
        <span className="seg">BUILD <span className="brass">2604</span></span>
        <span className="seg">v0.42.1</span>
        <span className="sep" />
        <span className="seg">PROVIDERS</span>
        <span className="seg"><span className="on">●</span>anthropic</span>
        <span className="seg"><span className="on">●</span>moonshot</span>
        <span className="seg" style={{color:'var(--warn-fg)'}}>●openai</span>
        <span className="seg off">●xai</span>
        <span className="seg push-right">TPS <span className="brass">1.24s</span></span>
        <span className="sep" />
        <span className="seg">16:32:45Z</span>
      </div>
    </div>
  );
}

function StatusCompact() {
  return (
    <div className="cb-board">
      <div style={{flex:1, background:'var(--bg-0)'}} />
      <div className="cb-statusbar">
        <span className="seg"><span className="brass">●</span>MASC</span>
        <span className="seg">5/8 ACTIVE</span>
        <span className="seg push-right"><span className="on">●●●</span><span className="off">●</span></span>
        <span className="seg">1.24s</span>
      </div>
    </div>
  );
}

function StatusVerbose() {
  return (
    <div className="cb-board">
      <div style={{flex:1, background:'var(--bg-0)'}} />
      <div className="cb-statusbar" style={{height:28, flexWrap:'wrap'}}>
        <span className="seg"><span className="on">●</span>CONNECTED</span>
        <span className="sep" />
        <span className="seg">goal <span className="brass">goal-merge-blockers</span></span>
        <span className="seg">task <span style={{color:'var(--fg-2)'}}>t-9f2a</span></span>
        <span className="seg">keeper <span style={{color:'var(--brass-1)'}}>nick0cave</span></span>
        <span className="sep" />
        <span className="seg">CASCADE hit@2 · <span className="brass">1.24s</span></span>
        <span className="sep" />
        <span className="seg">SUITE <span style={{color:'var(--err-fg)'}}>3 FAIL</span> / 47 PASS</span>
        <span className="seg push-right">⌘K for commands</span>
      </div>
    </div>
  );
}

// ─── DRAWER variants ───────────────────────────────────────────────
function DrawerTask() {
  return (
    <div className="cb-drawer">
      <div className="head">
        <div className="idrow">
          <span>t-9f2a</span>
          <span>·</span>
          <span>goal-merge-blockers</span>
          <button className="close">×</button>
        </div>
        <div className="title">Rebase PR #9712 + green CI</div>
        <div className="meta">
          <Chip kind="brass"><Dot kind="brass" size="sm" beat /> RUNNING</Chip>
          <Chip kind="ghost">P1</Chip>
          <Chip kind="ghost">2m ago</Chip>
        </div>
      </div>
      <div className="body">
        <div>
          <div className="sec-title">DETAILS</div>
          <dl className="kv">
            <dt>KEEPER</dt><dd>nick0cave</dd>
            <dt>TOOL</dt><dd>tool.write_file</dd>
            <dt>DIFF</dt><dd>+18 −4 · keeper.ts</dd>
            <dt>STARTED</dt><dd>16:31:27Z</dd>
            <dt>CASCADE</dt><dd>moonshot @step=2 · 1.24s</dd>
          </dl>
        </div>
        <div>
          <div className="sec-title">REVIEW · 3</div>
          <div className="thread">
            <div className="cmt flag">
              <div className="h">
                <span className="kind">FLAG</span>
                <span style={{color:'var(--fg-2)'}}>sangsu</span>
                <span className="t">3m ago</span>
              </div>
              <div className="body">drift detected at pipeline.ts L187 — signature mismatch</div>
            </div>
            <div className="cmt question">
              <div className="h">
                <span className="kind">QUESTION</span>
                <span style={{color:'var(--fg-2)'}}>qa-king</span>
                <span className="t">2m ago</span>
              </div>
              <div className="body">is the backport going to re-open suite-merge-blockers?</div>
            </div>
            <div className="cmt note">
              <div className="h">
                <span className="kind">NOTE</span>
                <span style={{color:'var(--fg-2)'}}>nick0cave</span>
                <span className="t">1m ago</span>
              </div>
              <div className="body">rebased on release-0.42 · re-running CI</div>
            </div>
          </div>
        </div>
      </div>
      <div className="acts">
        <button className="btn primary">APPROVE</button>
        <button className="btn">CLAIM</button>
        <button className="btn">FLAG</button>
        <button className="btn danger" style={{marginLeft:'auto'}}>RETIRE</button>
      </div>
    </div>
  );
}

function DrawerGoal() {
  const g = D3.goals[1];
  return (
    <div className="cb-drawer">
      <div className="head">
        <div className="idrow">
          <span>{g.id}</span>
          <span>·</span>
          <span>P{g.priority}</span>
          <button className="close">×</button>
        </div>
        <div className="title">{g.title}</div>
        <div className="meta">
          <Chip kind="brass">ACTIVE</Chip>
          <Chip kind="ghost">{g.progress}/{g.total}</Chip>
          <span className="bar" style={{width:100, alignSelf:'center'}}><span className="fill" style={{width:`${100*g.progress/g.total}%`}} /></span>
        </div>
      </div>
      <div className="body">
        <div>
          <div className="sec-title">TASKS · 5</div>
          <div style={{display:'flex', flexDirection:'column', gap:4}}>
            {(() => {
              const seen = new Set();
              return D3.tasks.filter(t=>t.goal==='goal-keeper-clarity').concat(D3.tasks.slice(2,5)).filter(t=>{ if(seen.has(t.id)) return false; seen.add(t.id); return true; }).slice(0,5);
            })().map(t=>(
              <div key={t.id} style={{display:'flex', alignItems:'center', gap:7, padding:'4px 7px', background:'var(--bg-1)', border:'1px solid var(--line-1)', borderRadius:3, fontSize:11}}>
                <Dot kind={kClass(t.keeper)} size="sm" />
                <span className="cb-mono" style={{color:'var(--fg-4)'}}>{t.id}</span>
                <span style={{color:'var(--fg-1)', flex:1}}>{t.title}</span>
                <Pill kind={t.status==='running'?'running':t.status==='fail'?'err':t.status==='stalled'?'stalled':'paused'}>{t.status}</Pill>
              </div>
            ))}
          </div>
        </div>
        <div>
          <div className="sec-title">KEEPERS</div>
          <dl className="kv">
            <dt>OWNER</dt><dd>masc-improver</dd>
            <dt>CONTRIB</dt><dd>nick0cave · sangsu</dd>
            <dt>OPENED</dt><dd>2026-04-20 09:14Z</dd>
            <dt>TARGET</dt><dd>2026-04-28</dd>
          </dl>
        </div>
      </div>
      <div className="acts">
        <button className="btn primary">SPAWN TASK</button>
        <button className="btn">PAUSE GOAL</button>
        <button className="btn" style={{marginLeft:'auto'}}>PIN</button>
      </div>
    </div>
  );
}

function DrawerKeeper() {
  return (
    <div className="cb-drawer">
      <div className="head">
        <div className="idrow">
          <span>keeper</span>
          <span>·</span>
          <span>captain</span>
          <button className="close">×</button>
        </div>
        <div className="title" style={{fontFamily:'var(--font-mono)'}}>
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
        <div>
          <div className="sec-title">HEARTBEAT</div>
          <div style={{background:'var(--bg-1)', padding:6, border:'1px solid var(--line-1)', borderRadius:3}}>
            <Heartbeat width={260} height={40} />
          </div>
        </div>
        <div>
          <div className="sec-title">CURRENT</div>
          <dl className="kv">
            <dt>TASK</dt><dd>t-9f2a</dd>
            <dt>GOAL</dt><dd>goal-merge-blockers</dd>
            <dt>TOOL</dt><dd>tool.write_file</dd>
            <dt>TPS</dt><dd>1.24s</dd>
            <dt>UPTIME</dt><dd>47m 12s</dd>
          </dl>
        </div>
        <div>
          <div className="sec-title">LAST 3 EVENTS</div>
          <div style={{display:'flex', flexDirection:'column', gap:4, fontSize:11}}>
            {D3.events.filter(e=>e.keeper==='nick0cave').slice(0,3).map((e,i)=>(
              <div key={i} style={{fontFamily:'var(--font-mono)', fontSize:10, color:'var(--fg-2)'}}>
                <span style={{color:'var(--fg-4)'}}>{e.t.slice(0,8)} </span>
                {e.text}
              </div>
            ))}
          </div>
        </div>
      </div>
      <div className="acts">
        <button className="btn primary">ASSIGN TASK</button>
        <button className="btn">PAUSE</button>
        <button className="btn danger" style={{marginLeft:'auto'}}>RETIRE</button>
      </div>
    </div>
  );
}

Object.assign(window, {
  ComposerPrompt, ComposerSuggest, ComposerMultiLine,
  StatusStandard, StatusCompact, StatusVerbose,
  DrawerTask, DrawerGoal, DrawerKeeper,
});
