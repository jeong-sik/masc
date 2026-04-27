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
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
      <div className="cb-composer" role="region" aria-label="Command composer">
        <div className="line" aria-live="polite">
          <span className="prompt" aria-hidden="true">masc&gt;</span>
          <span aria-label={`Current input: ${typed}`}>{typed}</span>
          <span className="caret" aria-hidden="true" style={{color:'var(--color-accent-fg)'}}>▌</span>
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
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
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
              <span aria-hidden="true" style={{color:'var(--color-fg-primary)'}}>{s.name}</span>
              <span aria-hidden="true" style={{color:'var(--color-fg-muted)', marginLeft:8}}>{s.desc}</span>
            </div>
          ))}
        </div>
        <div className="line">
          <span className="prompt" aria-hidden="true">masc&gt;</span>
          <span className="fn" aria-label="Current input: keeper.">keeper.</span>
          <span className="caret" aria-hidden="true" style={{color:'var(--color-accent-fg)'}}>▌</span>
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
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
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
            <span className="caret" style={{color:'var(--color-accent-fg)'}}>▌</span>
          </div>
          <div className="line" aria-hidden="true">
            <span>)</span>
          </div>
        </pre>
        <div className="hint" aria-hidden="true">
          <span><span className="kbd">⌘↵</span>run</span>
          <span><span className="kbd">⇧↵</span>newline</span>
          <span style={{marginLeft:'auto', color:'var(--color-fg-disabled)'}}>4 lines · will burn ~1.2s</span>
        </div>
      </div>
    </div>
  );
}

// ─── STATUS BAR variants ───────────────────────────────────────────
function StatusStandard() {
  return (
    <div className="cb-board">
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
      <div className="cb-statusbar" role="status" aria-live="polite" aria-label="System status: connected, build 2604, version 0.42.1, anthropic ok, moonshot ok, openai degraded, xai offline, TPS 1.24s, time 16:32:45 UTC">
        <span className="seg" role="group" aria-label="Connection: connected"><span className="on" aria-hidden="true">●</span>CONNECTED</span>
        <span className="sep" aria-hidden="true" />
        <span className="seg" role="group" aria-label="Build 2604">BUILD <span className="brass">2604</span></span>
        <span className="seg" role="group" aria-label="Version 0.42.1">v0.42.1</span>
        <span className="sep" aria-hidden="true" />
        <span className="seg" aria-hidden="true">PROVIDERS</span>
        <span className="seg" role="group" aria-label="anthropic ok"><span className="on" aria-hidden="true">●</span>anthropic</span>
        <span className="seg" role="group" aria-label="moonshot ok"><span className="on" aria-hidden="true">●</span>moonshot</span>
        <span className="seg" role="group" aria-label="openai degraded" style={{color:'var(--warn-fg)'}}><span aria-hidden="true">●</span>openai</span>
        <span className="seg off" role="group" aria-label="xai offline"><span aria-hidden="true">●</span>xai</span>
        <span className="seg push-right" role="group" aria-label="TPS 1.24 seconds">TPS <span className="brass">1.24s</span></span>
        <span className="sep" aria-hidden="true" />
        <span className="seg" role="group" aria-label="Clock 16:32:45 UTC">16:32:45Z</span>
      </div>
    </div>
  );
}

function StatusCompact() {
  return (
    <div className="cb-board">
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
      <div className="cb-statusbar" role="status" aria-live="polite" aria-label="MASC: 5 of 8 keepers active, 3 providers ok, TPS 1.24s">
        <span className="seg" role="group" aria-label="MASC"><span className="brass" aria-hidden="true">●</span>MASC</span>
        <span className="seg" role="group" aria-label="5 of 8 keepers active">5/8 ACTIVE</span>
        <span className="seg push-right" aria-hidden="true"><span className="on">●●●</span><span className="off">●</span></span>
        <span className="seg" role="group" aria-label="TPS 1.24 seconds">1.24s</span>
      </div>
    </div>
  );
}

function StatusVerbose() {
  return (
    <div className="cb-board">
      <div style={{flex:1, background:'var(--color-bg-page)'}} aria-hidden="true" />
      <div className="cb-statusbar" role="status" aria-live="polite" aria-label="Connected · goal goal-merge-blockers, task t-9f2a, keeper nick0cave, cascade hit at step 2 in 1.24s, suite 3 fail of 47 pass" style={{height:28, flexWrap:'wrap'}}>
        <span className="seg" role="group" aria-label="Connection: connected"><span className="on" aria-hidden="true">●</span>CONNECTED</span>
        <span className="sep" aria-hidden="true" />
        <span className="seg" role="group" aria-label="Goal goal-merge-blockers">goal <span className="brass">goal-merge-blockers</span></span>
        <span className="seg" role="group" aria-label="Task t-9f2a">task <span style={{color:'var(--color-fg-secondary)'}}>t-9f2a</span></span>
        <span className="seg" role="group" aria-label="Keeper nick0cave">keeper <span style={{color:'var(--color-accent-fg)'}}>nick0cave</span></span>
        <span className="sep" aria-hidden="true" />
        <span className="seg" role="group" aria-label="Cascade hit at step 2 in 1.24 seconds">CASCADE hit@2 · <span className="brass">1.24s</span></span>
        <span className="sep" aria-hidden="true" />
        <span className="seg" role="group" aria-label="Suite 3 fail of 47 pass">SUITE <span style={{color:'var(--err-fg)'}}>3 FAIL</span> / 47 PASS</span>
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
        <div className="meta" role="group" aria-label="Task metadata: running, P1, 2 minutes ago">
          <Chip kind="brass"><Dot kind="brass" size="sm" beat /> RUNNING</Chip>
          <Chip kind="ghost">P1</Chip>
          <Chip kind="ghost">2m ago</Chip>
        </div>
      </div>
      <div className="body">
        <section aria-labelledby="drawer-task-details">
          <SectionHeading variant="title" title="DETAILS" id="drawer-task-details" />
          <dl className="kv">
            <dt>KEEPER</dt><dd>nick0cave</dd>
            <dt>TOOL</dt><dd>tool.write_file</dd>
            <dt>DIFF</dt><dd>+18 −4 · keeper.ts</dd>
            <dt>STARTED</dt><dd>16:31:27Z</dd>
            <dt>CASCADE</dt><dd>moonshot @step=2 · 1.24s</dd>
          </dl>
        </section>
        <section aria-labelledby="drawer-task-review">
          <SectionHeading variant="title" title="REVIEW · 3" id="drawer-task-review" />
          <div className="thread" role="log" aria-live="polite" aria-label="Review thread, 3 comments">
            <div className="cmt flag" role="article" aria-label="Flag from sangsu, 3 minutes ago: drift detected at pipeline.ts L187 — signature mismatch">
              <div className="h" aria-hidden="true">
                <span className="kind">FLAG</span>
                <span style={{color:'var(--color-fg-secondary)'}}>sangsu</span>
                <span className="t">3m ago</span>
              </div>
              <div className="body">drift detected at pipeline.ts L187 — signature mismatch</div>
            </div>
            <div className="cmt question" role="article" aria-label="Question from qa-king, 2 minutes ago: is the backport going to re-open suite-merge-blockers?">
              <div className="h" aria-hidden="true">
                <span className="kind">QUESTION</span>
                <span style={{color:'var(--color-fg-secondary)'}}>qa-king</span>
                <span className="t">2m ago</span>
              </div>
              <div className="body">is the backport going to re-open suite-merge-blockers?</div>
            </div>
            <div className="cmt note" role="article" aria-label="Note from nick0cave, 1 minute ago: rebased on release-0.42, re-running CI">
              <div className="h" aria-hidden="true">
                <span className="kind">NOTE</span>
                <span style={{color:'var(--color-fg-secondary)'}}>nick0cave</span>
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
        <div className="meta" role="group" aria-label={`Goal metadata: active, ${g.progress} of ${g.total}`}>
          <Chip kind="brass">ACTIVE</Chip>
          <Chip kind="ghost">{g.progress}/{g.total}</Chip>
          <span className="bar" aria-hidden="true" style={{width:100, alignSelf:'center'}}><span className="fill" style={{width:`${100*g.progress/g.total}%`}} /></span>
        </div>
      </div>
      <div className="body">
        <section aria-labelledby="drawer-goal-tasks">
          <SectionHeading variant="title" title="TASKS · 5" id="drawer-goal-tasks" />
          <div role="list" aria-label="Tasks under this goal" style={{display:'flex', flexDirection:'column', gap:4}}>
            {(() => {
              const seen = new Set();
              return D3.tasks.filter(t=>t.goal==='goal-keeper-clarity').concat(D3.tasks.slice(2,5)).filter(t=>{ if(seen.has(t.id)) return false; seen.add(t.id); return true; }).slice(0,5);
            })().map(t=>(
              <div key={t.id}
                   role="listitem"
                   aria-label={`${t.id} · ${t.title} · ${t.keeper} · ${t.status}`}
                   style={{display:'flex', alignItems:'center', gap:7, padding:'4px 7px', background:'var(--color-bg-surface)', border:'1px solid var(--color-border-default)', borderRadius:3, fontSize:11}}>
                <KeeperBadge id={t.keeper} variant="sigil" size="sm" />
                <span className="cb-mono" aria-hidden="true" style={{color:'var(--color-fg-disabled)'}}>{t.id}</span>
                <span aria-hidden="true" style={{color:'var(--color-fg-primary)', flex:1}}>{t.title}</span>
                <Pill kind={t.status==='running'?'running':t.status==='fail'?'err':t.status==='stalled'?'stalled':'paused'}>{t.status}</Pill>
              </div>
            ))}
          </div>
        </section>
        <section aria-labelledby="drawer-goal-keepers">
          <SectionHeading variant="title" title="KEEPERS" id="drawer-goal-keepers" />
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
        <div className="meta" role="group" aria-label="Keeper metadata: running, 8 tool calls in 60 seconds, anthropic claude-haiku-4-5">
          <Chip kind="brass">RUNNING</Chip>
          <Chip kind="ghost">8 TOOL CALLS / 60s</Chip>
          <Chip kind="ghost">anthropic · claude-haiku-4-5</Chip>
        </div>
      </div>
      <div className="body">
        <section aria-labelledby="drawer-keeper-heartbeat">
          <SectionHeading variant="title" title="HEARTBEAT" id="drawer-keeper-heartbeat" />
          <div aria-label="Heartbeat trace, 60-second window" style={{background:'var(--color-bg-surface)', padding:6, border:'1px solid var(--color-border-default)', borderRadius:3}}>
            <span aria-hidden="true"><Heartbeat width={260} height={40} /></span>
          </div>
        </section>
        <section aria-labelledby="drawer-keeper-current">
          <SectionHeading variant="title" title="CURRENT" id="drawer-keeper-current" />
          <dl className="kv">
            <dt>TASK</dt><dd>t-9f2a</dd>
            <dt>GOAL</dt><dd>goal-merge-blockers</dd>
            <dt>TOOL</dt><dd>tool.write_file</dd>
            <dt>TPS</dt><dd>1.24s</dd>
            <dt>UPTIME</dt><dd>47m 12s</dd>
          </dl>
        </section>
        <section aria-labelledby="drawer-keeper-events">
          <SectionHeading variant="title" title="LAST 3 EVENTS" id="drawer-keeper-events" />
          <div role="log" aria-live="polite" aria-label="Last 3 events from nick0cave" style={{display:'flex', flexDirection:'column', gap:4, fontSize:11}}>
            {D3.events.filter(e=>e.keeper==='nick0cave').slice(0,3).map((e,i)=>(
              <div key={i}
                   role="article"
                   aria-label={`${e.t.slice(0,8)} · ${e.text}`}
                   style={{fontFamily:'var(--font-mono)', fontSize:10, color:'var(--color-fg-secondary)'}}>
                <span aria-hidden="true" style={{color:'var(--color-fg-disabled)'}}>{e.t.slice(0,8)} </span>
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

// ─── BOARD ZONE variants (W04 · DS-Drift Phase 1) ──────────────────
// Mirrors production board.css (dashboard/src/styles/board.css, 59 lines).
// Consumers of board.css in production:
//   - dashboard/src/main.ts            (entry import)
//   - dashboard/src/styles/global.css  (cascade root)
//   - dashboard/src/styles/ui.css      (.board-comment / .vote-btn typography)
// Append-only: existing cb-group-c artboards above are unmodified.

function BoardPostCard() {
  // mirrors production board.css:L5-11
  // @utility board-post { border-color: var(--color-border-default);
  //   transition: border-color, transform, background;
  //   &:hover { border-color: var(--accent-30); background: var(--white-6); transform: translateY(-1px); } }
  // SSOT-token rendering: --accent-30 (legacy alias) → rgb(--color-accent-glow / .30),
  // --white-6 (legacy alias) → rgb(--color-fg-primary / .06).
  const posts = [
    { id: 'p-841', author: 'nick0cave',     t: '2m',  title: 'Cascade weight=0 trial: codex_cli regression?', votes: 12, replies: 4 },
    { id: 'p-842', author: 'masc-improver', t: '14m', title: 'Persona TOML reconcile drift — 2880 redundant writes/day',  votes: 7,  replies: 2 },
    { id: 'p-843', author: 'sangsu',        t: '38m', title: 'OAS pin SHA vs cap range drift checklist', votes: 5,  replies: 1 },
  ];
  return (
    <div className="cb-board" style={{padding:14, gap:8, overflow:'auto'}}>
      <div role="group" aria-label="Board feed · 3 posts" style={{display:'flex', flexDirection:'column', gap:8}}>
        {posts.map(p => (
          <article key={p.id}
            role="article"
            aria-label={`Post ${p.id} by ${p.author}, ${p.t} ago: ${p.title} · ${p.votes} votes · ${p.replies} replies`}
            className="board-post-preview"
            style={{
              display:'grid', gridTemplateColumns:'28px 1fr auto', gap:10,
              padding:'10px 12px',
              background:'var(--color-bg-surface)',
              border:'1px solid var(--color-border-default)',
              borderRadius:3,
              transition:'border-color 0.2s, transform 0.2s, background 0.2s',
              cursor:'pointer',
            }}>
            <div role="group" aria-label={`${p.votes} votes`} style={{display:'flex', flexDirection:'column', alignItems:'center', gap:2, fontFamily:'var(--font-mono)', fontSize:10, color:'var(--color-fg-muted)'}}>
              <span aria-hidden="true">▲</span>
              <span aria-hidden="true" style={{color:'var(--color-fg-secondary)'}}>{p.votes}</span>
              <span aria-hidden="true">▼</span>
            </div>
            <div style={{display:'flex', flexDirection:'column', gap:4, minWidth:0}}>
              <div role="heading" aria-level={3} style={{color:'var(--color-fg-primary)', fontSize:13, fontWeight:500, overflow:'hidden', textOverflow:'ellipsis', whiteSpace:'nowrap'}}>{p.title}</div>
              <div className="cb-mono" aria-hidden="true" style={{fontSize:10, color:'var(--color-fg-muted)', display:'flex', gap:8}}>
                <KeeperBadge id={p.author} variant="full" size="sm" />
                <span>·</span>
                <span>{p.t} ago</span>
                <span>·</span>
                <span>{p.replies} replies</span>
              </div>
            </div>
            <Chip kind="ghost">{p.id}</Chip>
          </article>
        ))}
      </div>
    </div>
  );
}

function BoardVoteColumn() {
  // mirrors production board.css:L13-20
  // @utility vote-btn { transition: color 0.2s;
  //   &:hover { color: #ccc; }
  //   &.upvote:hover, &.upvote.active { color: #ff4500; }
  //   &.downvote:hover, &.downvote.active { color: #7193ff; }
  //   &.animate { animation: votePop 0.3s ease; } }
  // NOTE: production currently hardcodes 3 hex literals (#ccc, #ff4500, #7193ff).
  // Phase 2 candidate table below tracks the drift-to-token migration.
  const items = [
    { state:'idle',     up:'idle',   down:'idle',   label:'idle row' },
    { state:'up-hover', up:'hover',  down:'idle',   label:'upvote hovering' },
    { state:'up-on',    up:'active', down:'idle',   label:'upvote active' },
    { state:'dn-on',    up:'idle',   down:'active', label:'downvote active' },
  ];
  const colorFor = (slot) => slot === 'idle'
    ? 'var(--color-fg-muted)'
    : slot === 'hover'
      ? 'var(--color-fg-secondary)'   // currently #ccc in board.css
      : 'var(--color-accent-fg)';      // currently #ff4500 / #7193ff in board.css
  return (
    <div className="cb-board" style={{padding:14, gap:10, overflow:'auto'}}>
      <SectionHeading variant="title" title="VOTE STATES · 4" />
      <div role="group" aria-label="Vote column states" style={{display:'flex', flexDirection:'column', gap:6}}>
        {items.map((it, i) => (
          <div key={i}
            role="group"
            aria-label={it.label}
            style={{
              display:'grid', gridTemplateColumns:'80px 1fr', gap:12, alignItems:'center',
              padding:'8px 10px',
              background:'var(--color-bg-surface)',
              border:'1px solid var(--color-border-default)',
              borderRadius:3,
            }}>
            <div role="group" aria-label="upvote/downvote pair" style={{display:'flex', flexDirection:'column', alignItems:'center', gap:2, fontFamily:'var(--font-mono)', fontSize:14}}>
              <span aria-hidden="true" style={{color: colorFor(it.up), transition:'color 0.2s'}}>▲</span>
              <span aria-hidden="true" style={{color: colorFor(it.down), transition:'color 0.2s'}}>▼</span>
            </div>
            <span aria-hidden="true" style={{fontFamily:'var(--font-mono)', fontSize:11, color:'var(--color-fg-secondary)'}}>{it.label}</span>
          </div>
        ))}
      </div>
      {/* Phase 2 candidate · raw hex still in board.css that should migrate to tokens */}
      <SectionHeading variant="title" title="PHASE 2 CANDIDATES · 3" />
      <div role="table" aria-label="board.css raw hex tracked for tokenization in Phase 2"
        style={{
          display:'grid', gridTemplateColumns:'auto 1fr auto', gap:'4px 12px',
          padding:'8px 10px',
          background:'var(--color-bg-surface)',
          border:'1px dashed var(--color-border-default)',
          borderRadius:3,
          fontFamily:'var(--font-mono)', fontSize:10,
          color:'var(--color-fg-muted)',
        }}>
        <span role="columnheader" aria-hidden="true" style={{color:'var(--color-fg-secondary)'}}>RAW</span>
        <span role="columnheader" aria-hidden="true" style={{color:'var(--color-fg-secondary)'}}>SELECTOR</span>
        <span role="columnheader" aria-hidden="true" style={{color:'var(--color-fg-secondary)'}}>SUGGESTED TOKEN</span>
        <span role="cell">#ccc</span>
        <span role="cell">vote-btn:hover</span>
        <span role="cell">--color-fg-secondary</span>
        <span role="cell">#ff4500</span>
        <span role="cell">vote-btn.upvote.active</span>
        <span role="cell">--color-accent-fg</span>
        <span role="cell">#7193ff</span>
        <span role="cell">vote-btn.downvote.active</span>
        <span role="cell">--info</span>
      </div>
    </div>
  );
}

function BoardCommentThread() {
  // mirrors production board.css:L22-27
  // .board-comment .comment-text { transition: max-height 0.3s ease; }
  // .board-comment .comment-text.expanded { max-height: none; }
  // .board-comment .comment-expand-btn:hover { text-decoration: underline; }
  const comments = [
    { id:'c-1', author:'qa-king',  t:'4m', body:'Re-running suite-merge-blockers locally — 1 of 47 still red on cascade.run.', expanded:true },
    { id:'c-2', author:'sangsu',   t:'3m', body:'Drift detected at pipeline.ts L187 — signature mismatch. Truncated below.', expanded:false },
    { id:'c-3', author:'nick0cave', t:'1m', body:'Rebased on release-0.42 · re-running CI.', expanded:true },
  ];
  return (
    <div className="cb-board" style={{padding:14, gap:8, overflow:'auto'}}>
      <SectionHeading variant="title" title="THREAD · 3" />
      <div className="board-comment" role="log" aria-label="Comment thread, 3 entries"
        style={{display:'flex', flexDirection:'column', gap:6}}>
        {comments.map(c => (
          <div key={c.id}
            role="article"
            aria-label={`Comment by ${c.author}, ${c.t} ago${c.expanded ? '' : ', collapsed'}`}
            style={{
              padding:'8px 10px',
              background:'var(--color-bg-surface)',
              border:'1px solid var(--color-border-default)',
              borderRadius:3,
              display:'flex', flexDirection:'column', gap:4,
            }}>
            <div className="cb-mono" aria-hidden="true" style={{fontSize:10, display:'flex', gap:6, alignItems:'center', color:'var(--color-fg-muted)'}}>
              <KeeperBadge id={c.author} variant="full" size="sm" />
              <span>·</span>
              <span>{c.t} ago</span>
            </div>
            <div
              className={`comment-text${c.expanded ? ' expanded' : ''}`}
              style={{
                fontSize:12, color:'var(--color-fg-primary)', lineHeight:1.5,
                maxHeight: c.expanded ? 'none' : 32, overflow:'hidden',
                transition:'max-height 0.3s ease',
              }}>
              {c.body}
            </div>
            {!c.expanded && (
              <button type="button"
                className="comment-expand-btn"
                aria-label={`Expand comment ${c.id}`}
                style={{
                  alignSelf:'flex-start',
                  background:'transparent', border:'none', padding:0, cursor:'pointer',
                  fontFamily:'var(--font-mono)', fontSize:10,
                  color:'var(--color-accent-fg)',
                }}>
                expand ▾
              </button>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}

function BoardMarkdownPreview() {
  // mirrors production board.css:L29-58
  // .board-post-preview .markdown-content { overflow-wrap: anywhere; }
  // .board-post-preview .markdown-content > :first-child { margin-top: 0; }
  // .board-post-preview .markdown-content > :last-child { margin-bottom: 0; }
  // .board-post-preview .markdown-content p,ul,ol,blockquote,pre { margin: 0.35rem 0; }
  // .board-post-preview .markdown-content h1,h2,h3 { margin-top: 0; margin-bottom: 0.35rem; }
  // .board-post-preview .markdown-content pre { max-height: 8rem; }
  return (
    <div className="cb-board" style={{padding:14, gap:8, overflow:'auto'}}>
      <SectionHeading variant="title" title="POST · MARKDOWN" />
      <article
        className="board-post-preview"
        role="article"
        aria-label="Markdown preview · cascade weight=0 trial proposal"
        style={{
          padding:'10px 14px',
          background:'var(--color-bg-surface)',
          border:'1px solid var(--color-border-default)',
          borderRadius:3,
          color:'var(--color-fg-primary)',
        }}>
        <div className="markdown-content" style={{overflowWrap:'anywhere', fontSize:12, lineHeight:1.55}}>
          <h3 style={{marginTop:0, marginBottom:'0.35rem', fontFamily:'var(--font-mono)', fontSize:13, color:'var(--color-fg-primary)'}}>
            cascade weight=0 trial · proposal
          </h3>
          <p style={{margin:'0.35rem 0', color:'var(--color-fg-secondary)'}}>
            Drop <code style={{fontFamily:'var(--font-mono)', color:'var(--color-accent-fg)'}}>codex_cli</code>
            from the cascade for 2 hours; measure rollout-thread-not-found rate against
            yesterday&apos;s baseline.
          </p>
          <ul style={{margin:'0.35rem 0', paddingLeft:18, color:'var(--color-fg-secondary)'}}>
            <li>Hypothesis: codex internal 5-model rotation accounts for ~33% of cascade-fallback events.</li>
            <li>Counter-hypothesis: removing it surfaces fallback elsewhere (gemini_cli ReDoS).</li>
          </ul>
          <blockquote
            style={{
              margin:'0.35rem 0',
              paddingLeft:10,
              borderLeft:'2px solid var(--color-border-strong)',
              color:'var(--color-fg-muted)',
              fontStyle:'italic',
            }}>
            "Greedy 하게 빠르게 답을 구하고 만족하지 말자." — manifest.md
          </blockquote>
          <pre
            style={{
              margin:'0.35rem 0',
              maxHeight:'8rem',
              overflow:'auto',
              padding:8,
              background:'var(--color-bg-page)',
              border:'1px solid var(--color-border-default)',
              borderRadius:2,
              fontFamily:'var(--font-mono)', fontSize:10,
              color:'var(--color-fg-secondary)',
            }}>
{`# trial cascade
cascade.run(
  goal="goal-merge-blockers",
  providers=[anthropic, moonshot],   # codex_cli omitted
  dry_run=false,
)
# expected: rollout-thread-not-found  ↓ 30%
# expected: proactive_turn_violation  ↑ TBD`}
          </pre>
          <p style={{margin:'0.35rem 0', marginBottom:0, color:'var(--color-fg-muted)', fontSize:11}}>
            Trial window 2h · roll back if proactive turn rate &gt; baseline + 20%.
          </p>
        </div>
      </article>
    </div>
  );
}

Object.assign(window, {
  ComposerPrompt, ComposerSuggest, ComposerMultiLine,
  StatusStandard, StatusCompact, StatusVerbose,
  DrawerTask, DrawerGoal, DrawerKeeper,
  BoardPostCard, BoardVoteColumn, BoardCommentThread, BoardMarkdownPreview,
});
