// code-mode.jsx — 4 code-mode artboards: Tree · Editor · Review · Activity
// Plus combined Split + L2 Layers showcase.

/* global React */
const { useState, useEffect, useMemo, useRef } = React;

// ─────────────────────────────────────────────────────────────
// TREE — file tree with keeper dots & diff counts
// ─────────────────────────────────────────────────────────────
const TREE_DATA = [
  { t: 'dir', name: '.masc', lvl: 0, open: true },
  { t: 'dir', name: 'fleet', lvl: 1, open: true },
  { t: 'f', name: 'nick0cave.md', lvl: 2, k: 'nick', count: 3 },
  { t: 'f', name: 'masc-improver.md', lvl: 2, k: 'masc', count: 1 },
  { t: 'f', name: 'qa-king.md', lvl: 2, k: 'qa' },
  { t: 'dir', name: 'src', lvl: 0, open: true },
  { t: 'dir', name: 'keeper', lvl: 1, open: true },
  { t: 'f', name: 'keeper.ts', lvl: 2, k: 'nick', active: true, plus: 18, minus: 4 },
  { t: 'f', name: 'heartbeat.ts', lvl: 2, k: 'multi', count: 2, plus: 6 },
  { t: 'f', name: 'cascade.ts', lvl: 2, k: 'sangsu', minus: 2 },
  { t: 'dir', name: 'fleet', lvl: 1, open: false },
  { t: 'dir', name: 'cockpit', lvl: 1, open: true },
  { t: 'f', name: 'Topbar.tsx', lvl: 2, k: 'masc', plus: 2 },
  { t: 'f', name: 'Swimlanes.tsx', lvl: 2 },
  { t: 'f', name: 'Composer.tsx', lvl: 2, k: 'rama', count: 1 },
  { t: 'dir', name: 'tests', lvl: 0, open: true },
  { t: 'f', name: 'merge-blockers.spec.ts', lvl: 1, k: 'qa', minus: 3 },
  { t: 'f', name: 'heartbeat.spec.ts', lvl: 1 },
  { t: 'f', name: 'README.md', lvl: 0 },
  { t: 'f', name: 'package.json', lvl: 0 },
];

function Tree() {
  return (
    <div className="code-tree" style={{ height: 520 }}>
      <div className="tree-head">
        <span>EXPLORER</span>
        <span className="count">38</span>
      </div>
      <div className="tree-body">
        {TREE_DATA.map((n, i) => (
          <div key={i} className={`tree-item ${n.t === 'dir' ? 'tree-dir' : ''} ${n.active ? 'is-active' : ''}`}>
            {Array.from({ length: n.lvl }).map((_, j) => <span key={j} className="tw-indent" />)}
            <span className="tw-chev">{n.t === 'dir' ? (n.open ? '▾' : '▸') : ''}</span>
            <span className="tw-icon">{n.t === 'dir' ? '▣' : '·'}</span>
            <span className="tw-name">{n.name}</span>
            <span className="tw-badges">
              {n.plus ? <span className="tw-diff-plus">+{n.plus}</span> : null}
              {n.minus ? <span className="tw-diff-minus">−{n.minus}</span> : null}
              {n.count ? <span className="tw-count">{n.count}</span> : null}
              {n.k ? <span className={`tw-keeper-dot ${n.k === 'multi' ? 'is-multi' : ''}`} /> : null}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// EDITOR — file with line gutter, blame, cursors, comments
// ─────────────────────────────────────────────────────────────
const EDITOR_LINES = [
  { n: 1, blame: { k: 'nick', text: 'nick · 2m' }, code: <><span className="tok-key">import</span> {'{ '}<span className="tok-var">Heartbeat</span>{' }'} <span className="tok-key">from</span> <span className="tok-str">'./heartbeat'</span>;</> },
  { n: 2, blame: { k: 'nick', text: 'nick · 2m' }, code: <><span className="tok-key">import</span> {'{ '}<span className="tok-var">emit</span>{' }'} <span className="tok-key">from</span> <span className="tok-str">'./bus'</span>;</> },
  { n: 3, code: <>&nbsp;</> },
  { n: 4, blame: { k: 'masc', text: 'masc · 4h' }, com: 'com', code: <><span className="tok-com">{'// Keeper: daemon loop that heartbeats + pulls tasks'}</span></> },
  { n: 5, blame: { k: 'masc', text: 'masc · 4h' }, anchor: true, code: <><span className="tok-key">export class</span> <span className="tok-type">Keeper</span> {'{'}</> },
  { n: 6, blame: { k: 'nick', text: 'nick · 2m' }, cursor: { k: 'nick' }, anchor: true, diff: 'add', code: <>&nbsp;&nbsp;<span className="tok-prop">id</span>: <span className="tok-type">string</span>;</> },
  { n: 7, blame: { k: 'nick', text: 'nick · 2m' }, anchor: true, diff: 'add', code: <>&nbsp;&nbsp;<span className="tok-prop">goal</span>: <span className="tok-type">GoalRef</span>;</> },
  { n: 8, blame: { k: 'nick', text: 'nick · 2m' }, anchor: true, diff: 'add', code: <>&nbsp;&nbsp;<span className="tok-prop">cascade</span>?: <span className="tok-type">CascadeHandle</span>;</> },
  { n: 9, blame: { k: 'masc', text: 'masc · 4h' }, anchor: true, code: <>&nbsp;&nbsp;</> },
  { n: 10, blame: { k: 'masc', text: 'masc · 4h' }, flag: true, code: <>&nbsp;&nbsp;<span className="tok-key">async</span> <span className="tok-fn">tick</span>() {'{'}</> },
  { n: 11, blame: { k: 'masc', text: 'masc · 4h' }, diff: 'del', code: <>&nbsp;&nbsp;&nbsp;&nbsp;<span className="tok-key">if</span> (<span className="tok-key">this</span>.<span className="tok-prop">paused</span>) <span className="tok-key">return</span>;</> },
  { n: 12, blame: { k: 'sangsu', text: 'sangsu · 1h' }, cursor: { k: 'sangsu' }, diff: 'add', code: <>&nbsp;&nbsp;&nbsp;&nbsp;<span className="tok-key">if</span> (<span className="tok-key">this</span>.<span className="tok-prop">state</span> !== <span className="tok-str">'running'</span>) <span className="tok-key">return</span>;</> },
  { n: 13, blame: { k: 'sangsu', text: 'sangsu · 1h' }, code: <>&nbsp;&nbsp;&nbsp;&nbsp;<span className="tok-fn">emit</span>(<span className="tok-str">'heartbeat'</span>, {'{'} <span className="tok-prop">id</span>: <span className="tok-key">this</span>.<span className="tok-prop">id</span>, <span className="tok-prop">ts</span>: <span className="tok-type">Date</span>.<span className="tok-fn">now</span>() {'}'});</> },
  { n: 14, blame: { k: 'sangsu', text: 'sangsu · 1h' }, code: <>&nbsp;&nbsp;&nbsp;&nbsp;<span className="tok-key">await</span> <span className="tok-key">this</span>.<span className="tok-fn">pullTasks</span>();</> },
  { n: 15, blame: { k: 'masc', text: 'masc · 4h' }, note: true, code: <>&nbsp;&nbsp;&nbsp;&nbsp;<span className="tok-key">await</span> <span className="tok-key">this</span>.<span className="tok-fn">runCascade</span>(<span className="tok-str">'moonshot'</span>);</> },
  { n: 16, blame: { k: 'masc', text: 'masc · 4h' }, code: <>&nbsp;&nbsp;{'}'}</> },
  { n: 17, code: <>{'}'}</> },
];

function Editor({ height = 520 }) {
  return (
    <div className="code-editor" style={{ height }}>
      <div className="editor-tabs">
        <div className="editor-tab is-active"><span>keeper.ts</span><span className="t-dirty" /><span className="t-close">×</span></div>
        <div className="editor-tab"><span>heartbeat.ts</span><span className="t-close">×</span></div>
        <div className="editor-tab"><span>cascade.ts</span><span className="t-close">×</span></div>
      </div>
      <div className="editor-breadcrumbs">
        <span className="bc-seg">src</span><span className="bc-sep">/</span>
        <span className="bc-seg">keeper</span><span className="bc-sep">/</span>
        <span className="bc-seg">keeper.ts</span><span className="bc-sep">:</span>
        <span className="bc-seg">Keeper.tick</span>
      </div>
      <div className="editor-body">
        <div className="editor-scroll">
          {EDITOR_LINES.map((ln) => (
            <div key={ln.n} className={`code-line ${ln.diff === 'add' ? 'is-diff-add' : ''} ${ln.diff === 'del' ? 'is-diff-del' : ''} ${ln.anchor ? 'is-anchor-hover' : ''}`}>
              <span className="cl-gutter">
                {ln.com && <span className="cl-gutter-icon k-note">◆</span>}
                {ln.flag && <span className="cl-gutter-icon k-flag">⚑</span>}
                {ln.note && <span className="cl-gutter-icon k-suggest">✦</span>}
                {!ln.com && !ln.flag && !ln.note && <span className="cl-add-btn">+</span>}
              </span>
              <span className="cl-markers">
                {ln.diff && <span className="cl-diff-mark">{ln.diff === 'add' ? '+' : '−'}</span>}
                {ln.cursor && <span className="cl-cursor"><span className={`cl-cursor-dot ${ln.cursor.k === 'sangsu' ? 'is-blue' : ln.cursor.k === 'masc' ? 'is-green' : ''}`} /></span>}
              </span>
              <span className="cl-lineno">{ln.n}</span>
              <span className={`cl-blame ${ln.blame ? `is-keeper-${ln.blame.k}` : ''}`}>{ln.blame?.text || ''}</span>
              <span className="cl-code">{ln.code}</span>
            </div>
          ))}
        </div>
        <div className="editor-minimap">
          <svg viewBox="0 0 60 520" width="100%" height="100%">
            {EDITOR_LINES.map((ln, i) => (
              <rect key={i} x="6" y={i * 14 + 8} width={Math.random() * 40 + 6} height="2" fill={ln.diff === 'add' ? 'var(--ok)' : ln.diff === 'del' ? 'var(--err)' : 'var(--color-fg-disabled)'} opacity={ln.diff ? 0.7 : 0.3} />
            ))}
            <rect className="minimap-viewport" x="0" y="40" width="60" height="140" />
          </svg>
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// REVIEW RAIL — threads, filters
// ─────────────────────────────────────────────────────────────
const THREADS = [
  { kind: 'flag', anchor: 'keeper.ts:10', author: 'qa-king', ts: '2m', body: '`tick()` has no error handler — if `pullTasks` throws we silently swallow it and the heartbeat loop continues forever.', replies: 3 },
  { kind: 'question', anchor: 'keeper.ts:12', author: 'sangsu', ts: '1h', body: 'Should this also bail when `state === \'draining\'`? We have a draining state now from goal-merge-blockers.', replies: 1 },
  { kind: 'suggest', anchor: 'keeper.ts:15', author: 'nick0cave', ts: '14m', body: 'Consider gating `runCascade(\'moonshot\')` behind the goal priority. P1 goals only? We cascade too eagerly.', replies: 2 },
  { kind: 'note', anchor: 'keeper.ts:5–9', author: 'masc-improver', ts: '4h', body: 'Interface change — GoalRef replaces the old string goal id. Downstream: composer, deck, and drawer.', replies: 0 },
  { kind: 'approve', anchor: 'heartbeat.ts:44', author: 'nick0cave', ts: '22m', body: 'LGTM. Matches the spec from goal-cockpit-polish.', replies: 0, resolved: true, drift: true },
];

function Review({ height = 520 }) {
  const [filter, setFilter] = useState('open');
  const [activeIdx, setActiveIdx] = useState(0);
  return (
    <div className="code-review" style={{ height }}>
      <div className="review-head">
        <span>REVIEW</span>
        <span className="count">{THREADS.filter(t => !t.resolved).length} OPEN</span>
      </div>
      <div className="review-filter">
        {['all', 'open', 'mine', 'flag', 'resolved'].map(f => (
          <button key={f} className={filter === f ? 'is-active' : ''} onClick={() => setFilter(f)}>{f}</button>
        ))}
      </div>
      <div className="review-list">
        {THREADS.map((t, i) => (
          <div key={i} className={`thread ${activeIdx === i ? 'is-active' : ''} ${t.resolved ? 'is-resolved' : ''}`} onClick={() => setActiveIdx(i)}>
            <div className="thread-head">
              <span className={`thread-kind k-${t.kind}`}>{t.kind}</span>
              <span className="thread-anchor">{t.anchor}</span>
              <span className="thread-ts">{t.ts}</span>
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <span className="thread-author">{t.author}</span>
              {t.drift && <span className="thread-drift-badge">DRIFTED</span>}
            </div>
            <div className="thread-body">{t.body}</div>
            <div className="thread-meta">
              {t.replies > 0 && <span className="thread-reply-count">{t.replies}</span>}
              <span style={{ marginLeft: 'auto' }}>click to jump</span>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// ACTIVITY — timeline feed for this file
// ─────────────────────────────────────────────────────────────
const ACTS = [
  { ts: 'NOW', kind: 'edit', now: true, who: 'nick0cave', what: 'editing', where: 'line 12', detail: 'moved guard from paused→state' },
  { ts: '2m', kind: 'flag', who: 'qa-king', what: 'flagged', where: 'line 10', detail: 'no error handler' },
  { ts: '4m', kind: 'edit', who: 'sangsu', what: 'refactored', where: 'tick()', detail: 'extracted pullTasks' },
  { ts: '8m', kind: 'comment', who: 'sangsu', what: 'asked', where: 'line 12', detail: 'about draining state' },
  { ts: '14m', kind: 'comment', who: 'nick0cave', what: 'suggested', where: 'line 15', detail: 'gate cascade on priority' },
  { ts: '22m', kind: 'approve', who: 'nick0cave', what: 'approved', where: 'heartbeat.ts', detail: 'matches spec' },
  { ts: '44m', kind: 'commit', who: 'masc-improver', what: 'commit', where: '7f2a9c', detail: '+18 −4 · keeper.ts' },
  { ts: '1h', kind: 'refactor', who: 'sangsu', what: 'renamed', where: 'id→keeperId', detail: '18 refs' },
  { ts: '4h', kind: 'commit', who: 'masc-improver', what: 'commit', where: 'c99012', detail: 'initial Keeper class' },
];

function Activity({ height = 520 }) {
  return (
    <div className="code-activity" style={{ height }}>
      <div className="activity-head">
        <span>ACTIVITY</span>
        <span className="scope-pill">keeper.ts</span>
      </div>
      <div className="activity-list">
        {ACTS.map((a, i) => (
          <div key={i} className={`act-row ${a.now ? 'is-now' : ''}`}>
            <span className="act-ts">{a.ts}</span>
            <span className={`act-dot k-${a.kind}`} />
            <div className="act-body">
              <div><span className="who">{a.who}</span> <span className="what">{a.what}</span> <span className="where">{a.where}</span></div>
              <div className="detail">{a.detail}</div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// TOOLBAR
// ─────────────────────────────────────────────────────────────
function Toolbar() {
  return (
    <div className="code-toolbar" style={{ height: 32, border: '1px solid var(--color-border-default)', borderRadius: 'var(--r-1)', background: 'var(--color-bg-surface)' }}>
      <span className="code-repo-select">masc-cockpit <span className="arrow">▾</span></span>
      <span className="code-wc-select">main <span className="arrow">▾</span></span>
      <div className="wc-chips">
        <span className="wc-chip is-active"><span className="dot" style={{ background: 'var(--color-accent-fg)', width: 5, height: 5, borderRadius: '50%' }} />keeper.ts<span className="wc-close">×</span></span>
        <span className="wc-chip">heartbeat.ts<span className="wc-close">×</span></span>
        <span className="wc-chip">cascade.ts<span className="wc-close">×</span></span>
      </div>
      <input className="code-search" placeholder="filter · symbol · regex" />
      <div className="code-view-tabs">
        <button className="is-active">CODE</button>
        <button>DIFF</button>
        <button>BLAME</button>
        <button>HIST</button>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// LAYERS OVERLAY DEMO — compressed preview of L2 overlay stack
// ─────────────────────────────────────────────────────────────
function LayerBar() {
  const [on, setOn] = useState({ time: true, parallel: true, tools: false, approve: true, notes: true });
  const [explode, setExplode] = useState(false);
  return (
    <div className="layer-bar" style={{ borderRadius: 'var(--r-1)', border: '1px solid var(--color-border-default)', height: 30 }}>
      <span className="layer-bar-label">LAYERS</span>
      {[
        { id: 'time', label: 'TIME' },
        { id: 'parallel', label: 'PARALLEL' },
        { id: 'tools', label: 'TOOLS' },
        { id: 'approve', label: 'APPROVE' },
        { id: 'notes', label: 'NOTES' },
      ].map(l => (
        <span key={l.id} data-layer={l.id} className={`layer-toggle ${on[l.id] ? 'is-on' : ''}`} onClick={() => setOn(o => ({ ...o, [l.id]: !o[l.id] }))}>
          <span className="glyph" /> {l.label}
        </span>
      ))}
      <div style={{ flex: 1 }} />
      <span className={`layer-explode ${explode ? 'is-on' : ''}`} onClick={() => setExplode(!explode)}>◎ EXPLODE</span>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// SPLIT MODE PREVIEW — cockpit top (180px) + code bottom
// ─────────────────────────────────────────────────────────────
function SplitMode({ w = 1400, h = 680 }) {
  return (
    <div style={{ display: 'grid', gridTemplateRows: '32px 26px 52px 180px minmax(0,1fr) 28px', width: w, height: h, background: 'var(--color-bg-page)', border: '1px solid var(--color-border-default)', borderRadius: 'var(--r-1)', overflow: 'hidden' }}>
      {/* topbar */}
      <div style={{ display: 'flex', alignItems: 'center', padding: '0 12px', gap: 10, background: 'var(--color-bg-surface)', borderBottom: '1px solid var(--color-border-strong)', fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--color-fg-secondary)' }}>
        <div style={{ width: 14, height: 14, borderRadius: 2, background: 'linear-gradient(135deg, var(--color-accent-fg), var(--color-accent-fg-dim))' }} />
        <b style={{ color: 'var(--color-fg-primary)', letterSpacing: '.04em' }}>MASC</b>
        <span style={{ color: 'var(--color-fg-disabled)' }}>v0.42.1</span>
        <span style={{ width: 1, height: 14, background: 'var(--color-border-strong)' }} />
        <span>goal-merge-blockers <span style={{ color: 'var(--color-fg-disabled)' }}>▾</span></span>
        <div className="mode-switch" style={{ marginLeft: 12 }}>
          <button>COCKPIT</button>
          <button className="is-active">SPLIT</button>
          <button>CODE</button>
        </div>
        <div style={{ marginLeft: 'auto', color: 'var(--color-fg-disabled)', fontSize: 10 }}>16:32:45Z · 5 keepers live</div>
      </div>
      {/* ticker */}
      <div style={{ display: 'flex', alignItems: 'center', padding: '0 12px', gap: 16, background: 'linear-gradient(to bottom, var(--color-bg-surface), var(--color-bg-page))', borderBottom: '1px solid var(--color-border-default)', fontFamily: 'var(--font-mono)', fontSize: 10, color: 'var(--color-fg-muted)', whiteSpace: 'nowrap', overflow: 'hidden' }}>
        <span>16:32:40 <span style={{ color: 'var(--color-accent-fg)' }}>nick0cave</span> edit keeper.ts:12</span>
        <span>16:32:38 <span style={{ color: 'var(--err)' }}>qa-king</span> flag keeper.ts:10</span>
        <span>16:32:33 <span style={{ color: 'var(--ok)' }}>sangsu</span> refactor tick()</span>
        <span>16:32:29 <span style={{ color: 'var(--info)' }}>masc</span> commit c99012</span>
      </div>
      {/* kpi mini */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(6,1fr)', gap: 1, background: 'var(--color-border-default)', borderBottom: '1px solid var(--color-border-strong)' }}>
        {[
          { l: 'keepers', v: '5', s: 'brass' },
          { l: 'running', v: '3' },
          { l: 'heartbeat', v: '1.4s', s: 'ok' },
          { l: 'tok/s', v: '2.8k', s: 'brass' },
          { l: 'cascade', v: '@2 · 1.24s' },
          { l: 'flags', v: '3', s: 'err' },
        ].map((k, i) => (
          <div key={i} style={{ background: k.s === 'brass' ? 'rgb(var(--color-accent-glow)/.06)' : 'var(--color-bg-surface)', padding: '8px 10px', display: 'flex', flexDirection: 'column', gap: 2, boxShadow: k.s === 'err' ? 'inset 2px 0 0 var(--err)' : k.s === 'ok' ? 'inset 2px 0 0 var(--ok)' : k.s === 'brass' ? 'inset 2px 0 0 var(--color-accent-fg)' : 'none' }}>
            <div style={{ fontSize: 9, letterSpacing: '.08em', color: 'var(--color-fg-muted)', textTransform: 'uppercase', fontWeight: 600 }}>{k.l}</div>
            <div style={{ fontFamily: 'var(--font-mono)', fontSize: 15, color: k.s === 'err' ? 'var(--err-fg)' : k.s === 'ok' ? 'var(--ok-fg)' : k.s === 'brass' ? 'var(--color-accent-fg)' : 'var(--color-fg-primary)' }}>{k.v}</div>
          </div>
        ))}
      </div>
      {/* cockpit strip (180px): lifeline + mini swimlanes */}
      <div style={{ display: 'grid', gridTemplateColumns: '280px minmax(0,1fr) 220px', background: 'var(--color-bg-page)', borderBottom: '2px solid var(--color-accent-fg-dim)', minHeight: 0, overflow: 'hidden' }}>
        <div style={{ padding: 8, borderRight: '1px solid var(--color-border-default)', display: 'flex', flexDirection: 'column', gap: 4 }}>
          <div style={{ fontSize: 9, letterSpacing: '.08em', color: 'var(--color-fg-muted)', textTransform: 'uppercase', fontWeight: 600 }}>FLEET</div>
          {['nick0cave', 'masc-improver', 'sangsu', 'qa-king', 'rama'].map((k, i) => (
            <div key={k} style={{ display: 'flex', alignItems: 'center', gap: 6, fontFamily: 'var(--font-mono)', fontSize: 10, color: 'var(--color-fg-secondary)' }}>
              <span style={{ width: 5, height: 5, borderRadius: '50%', background: ['var(--color-accent-fg)', 'var(--ok)', 'var(--info)', 'var(--err)', 'var(--stalled)'][i], boxShadow: i === 0 ? '0 0 5px rgb(var(--color-accent-glow)/.7)' : 'none' }} />
              {k}
              <span style={{ marginLeft: 'auto', color: 'var(--color-fg-disabled)', fontSize: 9 }}>t-{(0x9f2a + i).toString(16)}</span>
            </div>
          ))}
        </div>
        <div style={{ position: 'relative', padding: 8 }}>
          <div style={{ fontSize: 9, letterSpacing: '.08em', color: 'var(--color-fg-muted)', textTransform: 'uppercase', fontWeight: 600, marginBottom: 6 }}>SWIMLANES · 60s</div>
          {[0, 1, 2, 3, 4].map(i => (
            <div key={i} style={{ position: 'relative', height: 22, borderBottom: '1px solid var(--color-border-default)' }}>
              {[...Array(6)].map((_, j) => (
                <span key={j} style={{ position: 'absolute', left: `${(j * 14 + Math.random() * 8)}%`, top: '50%', transform: 'translateY(-50%)', width: 8, height: 4, background: j === 5 ? 'var(--brass-2)' : ['var(--color-fg-secondary)', 'var(--info)', 'var(--ok)'][j % 3], borderRadius: 1 }} />
              ))}
            </div>
          ))}
          <div style={{ position: 'absolute', top: 24, bottom: 8, left: '82%', width: 1, background: 'linear-gradient(to bottom, transparent, rgb(var(--color-accent-glow)/.7) 20%, rgb(var(--color-accent-glow)/.7) 80%, transparent)', boxShadow: '0 0 8px 1px rgb(var(--color-accent-glow)/.4)' }} />
        </div>
        <div style={{ padding: 8, borderLeft: '1px solid var(--color-border-default)' }}>
          <div style={{ fontSize: 9, letterSpacing: '.08em', color: 'var(--color-fg-muted)', textTransform: 'uppercase', fontWeight: 600, marginBottom: 4 }}>NOW · keeper.ts</div>
          <div style={{ fontFamily: 'var(--font-mono)', fontSize: 10, color: 'var(--color-fg-secondary)', lineHeight: 1.6 }}>
            nick0cave @ line 12<br />
            qa-king flag line 10<br />
            sangsu @ tick()<br />
            <span style={{ color: 'var(--color-accent-fg)' }}>3 threads open</span>
          </div>
        </div>
      </div>
      {/* code zone (full width, fills rest) */}
      <div style={{ display: 'grid', gridTemplateColumns: '180px minmax(0,1fr) 260px 220px', minHeight: 0, overflow: 'hidden' }}>
        <Tree />
        <Editor />
        <Review />
        <Activity />
      </div>
      {/* status bar */}
      <div style={{ display: 'flex', alignItems: 'center', padding: '0 12px', gap: 14, background: 'var(--color-bg-surface)', borderTop: '1px solid var(--color-border-strong)', fontFamily: 'var(--font-mono)', fontSize: 10, color: 'var(--color-fg-muted)' }}>
        <span><span style={{ color: 'var(--ok-fg)' }}>●</span> SPLIT MODE</span>
        <span style={{ width: 1, height: 10, background: 'var(--color-border-strong)' }} />
        <span>keeper.ts · 47 LOC · +18 −4</span>
        <span style={{ width: 1, height: 10, background: 'var(--color-border-strong)' }} />
        <span>cascade: <span style={{ color: 'var(--color-accent-fg)' }}>moonshot@2 · 1.24s</span></span>
        <span style={{ marginLeft: 'auto' }}>⌘K palette · ⇥ focus · esc drawer</span>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// 3D EXPLODE — z-layer preview of the observational overlays
// ─────────────────────────────────────────────────────────────
function ExplodeLayers({ w = 900, h = 560 }) {
  const [pose, setPose] = useState(1); // 0 = flat, 1 = exploded, 2 = tilted

  const poses = {
    0: 'rotateX(0deg) rotateZ(0deg) translateY(0px) scale(1)',
    1: 'rotateX(58deg) rotateZ(-4deg) translateY(-20px) scale(.82)',
    2: 'rotateX(32deg) rotateZ(-8deg) translateY(-10px) scale(.9)',
  };

  const layers = [
    { id: 'base', label: 'SOURCE · keeper.ts', z: 0, bg: 'var(--color-bg-page)', render: () => (
      <div style={{ padding: 12, fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--color-fg-secondary)', lineHeight: 1.6 }}>
        <div><span style={{ color: '#c195e8' }}>export class</span> <span style={{ color: '#88b5d8' }}>Keeper</span> {'{'}</div>
        <div style={{ paddingLeft: 18 }}>id: <span style={{ color: '#88b5d8' }}>string</span>;</div>
        <div style={{ paddingLeft: 18 }}>goal: <span style={{ color: '#88b5d8' }}>GoalRef</span>;</div>
        <div style={{ paddingLeft: 18 }}>cascade?: <span style={{ color: '#88b5d8' }}>CascadeHandle</span>;</div>
        <div style={{ paddingLeft: 18 }}><span style={{ color: '#c195e8' }}>async</span> <span style={{ color: '#e8c976' }}>tick</span>() {'{'}</div>
        <div style={{ paddingLeft: 36 }}><span style={{ color: '#c195e8' }}>if</span> (this.state !== <span style={{ color: '#a8c97a' }}>'running'</span>) return;</div>
        <div style={{ paddingLeft: 36 }}><span style={{ color: '#e8c976' }}>emit</span>(<span style={{ color: '#a8c97a' }}>'heartbeat'</span>);</div>
        <div style={{ paddingLeft: 36 }}><span style={{ color: '#c195e8' }}>await</span> this.<span style={{ color: '#e8c976' }}>runCascade</span>(<span style={{ color: '#a8c97a' }}>'moonshot'</span>);</div>
        <div style={{ paddingLeft: 18 }}>{'}'}</div>
        <div>{'}'}</div>
      </div>
    ) },
    { id: 'time', label: 'L1 · TIME · recency stripe', z: 100, bg: 'rgb(201 162 74 / .08)', render: () => (
      <div style={{ padding: 12 }}>
        {[1, .85, .65, .4, .3, .7, .55, .95, .8].map((o, i) => (
          <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 8, height: 18 }}>
            <span style={{ width: 3, height: 12, background: 'var(--warn)', opacity: o, boxShadow: o > 0.9 ? '0 0 6px rgb(var(--warn-glow)/.7)' : 'none', borderRadius: 1 }} />
            <span style={{ fontFamily: 'var(--font-mono)', fontSize: 10, color: o > 0.7 ? 'var(--warn)' : 'var(--color-fg-muted)' }}>{o > 0.9 ? '2m' : o > 0.7 ? '8m' : o > 0.4 ? '1h' : '4h'} · {['nick', 'nick', 'masc', 'sangsu', 'masc', 'sangsu', 'sangsu', 'nick', 'masc'][i]}</span>
          </div>
        ))}
      </div>
    ) },
    { id: 'parallel', label: 'L2 · PARALLEL · keeper cursors', z: 200, bg: 'rgb(106 142 176 / .08)', render: () => (
      <svg viewBox={`0 0 ${w} ${h}`} style={{ width: '100%', height: '100%' }}>
        <path d={`M 40 40 Q ${w / 2} 60 ${w - 40} 120`} fill="none" stroke="var(--color-accent-fg)" strokeWidth="1.5" opacity=".7" />
        <path d={`M 40 120 Q ${w / 2} 180 ${w - 40} 80`} fill="none" stroke="var(--ok)" strokeWidth="1.5" opacity=".6" />
        <path d={`M 40 200 Q ${w / 2} 160 ${w - 40} 220`} fill="none" stroke="var(--info)" strokeWidth="1.5" opacity=".6" strokeDasharray="3 3" />
        <circle cx={w - 40} cy={120} r="4" fill="var(--color-accent-fg)" />
        <circle cx={w - 40} cy={80} r="4" fill="var(--ok)" />
        <circle cx={w - 40} cy={220} r="4" fill="var(--info)" />
      </svg>
    ) },
    { id: 'tools', label: 'L3 · TOOLS · frequency glyphs', z: 300, bg: 'rgb(var(--color-accent-glow) / .06)', render: () => (
      <div style={{ padding: 12 }}>
        {[['◈', 12, 'emit'], ['⌘', 8, 'run'], ['⟳', 5, 'tick'], ['∎', 3, 'guard']].map(([g, n, lab], i) => (
          <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 8, height: 24 }}>
            <span style={{ color: 'var(--color-accent-fg)', fontSize: 12, textShadow: '0 0 4px rgb(var(--color-accent-glow)/.6)' }}>{g}</span>
            <span style={{ width: n * 6, height: 2, background: 'linear-gradient(90deg, var(--color-accent-fg), transparent)', borderRadius: 1 }} />
            <span style={{ fontFamily: 'var(--font-mono)', fontSize: 9, color: 'var(--color-fg-disabled)' }}>{n}×</span>
            <span style={{ fontFamily: 'var(--font-mono)', fontSize: 9, color: 'var(--color-accent-fg)' }}>{lab}</span>
          </div>
        ))}
      </div>
    ) },
    { id: 'approve', label: 'L4 · APPROVE · block stamp', z: 400, bg: 'rgb(107 158 107 / .05)', render: () => (
      <div style={{ padding: 12, position: 'relative' }}>
        <div style={{ padding: '8px 16px', background: 'rgb(107 158 107 / .08)', borderLeft: '2px solid var(--ok)', borderRadius: 2, display: 'flex', alignItems: 'center', height: 60 }}>
          <span style={{ marginLeft: 'auto', fontFamily: 'var(--font-mono)', fontSize: 36, color: 'var(--ok)', opacity: 0.15, letterSpacing: '.08em', fontWeight: 700, transform: 'rotate(-12deg)' }}>LGTM</span>
        </div>
        <div style={{ marginTop: 8, padding: '8px 16px', background: 'rgb(196 106 90 / .08)', borderLeft: '2px solid var(--err)', borderRadius: 2, display: 'flex', alignItems: 'center', height: 60 }}>
          <span style={{ marginLeft: 'auto', fontFamily: 'var(--font-mono)', fontSize: 36, color: 'var(--err)', opacity: 0.15, letterSpacing: '.08em', fontWeight: 700, transform: 'rotate(-12deg)' }}>FLAG</span>
        </div>
      </div>
    ) },
    { id: 'notes', label: 'L5 · NOTES · pinned cards', z: 500, bg: 'rgb(138 106 160 / .08)', render: () => (
      <div style={{ padding: 12 }}>
        <div style={{ width: 240, background: 'linear-gradient(180deg, rgb(138 106 160 / .20), rgb(138 106 160 / .08))', border: '1px solid rgb(var(--stalled-glow)/.4)', borderRadius: 'var(--r-1)', padding: '6px 10px', fontSize: 11, color: 'var(--color-fg-primary)', boxShadow: '0 4px 16px rgb(0 0 0 / .5)', backdropFilter: 'blur(4px)' }}>
          <div style={{ fontFamily: 'var(--font-mono)', fontSize: 9, color: 'var(--stalled)', letterSpacing: '.06em', textTransform: 'uppercase', marginBottom: 4 }}>NOTE · sangsu · 2h</div>
          <div style={{ fontSize: 11, lineHeight: 1.4 }}>GoalRef changed the shape of goal from string to {'{'}id,priority{'}'}. Check downstream emit() contracts.</div>
        </div>
      </div>
    ) },
  ];

  return (
    <div style={{ width: w, height: h, background: 'var(--color-bg-page)', border: '1px solid var(--color-border-default)', borderRadius: 'var(--r-1)', position: 'relative', overflow: 'hidden' }}>
      {/* pose controls */}
      <div style={{ position: 'absolute', top: 10, left: 10, zIndex: 10, display: 'flex', gap: 0, border: '1px solid var(--color-border-strong)', borderRadius: 'var(--r-1)', overflow: 'hidden' }}>
        {['flat', 'exploded', 'tilt'].map((p, i) => (
          <button key={p} onClick={() => setPose(i)} style={{ padding: '4px 10px', fontSize: 10, background: pose === i ? 'var(--color-bg-elevated)' : 'transparent', color: pose === i ? 'var(--color-accent-fg)' : 'var(--color-fg-muted)', border: 'none', borderRight: i < 2 ? '1px solid var(--color-border-strong)' : 'none', fontFamily: 'var(--font-mono)', letterSpacing: '.08em', textTransform: 'uppercase', fontWeight: 600, cursor: 'pointer' }}>{p}</button>
        ))}
      </div>
      {/* z-axis legend */}
      <div style={{ position: 'absolute', top: 10, right: 10, zIndex: 10, fontFamily: 'var(--font-mono)', fontSize: 9, color: 'var(--color-fg-disabled)', letterSpacing: '.08em', textTransform: 'uppercase', textAlign: 'right', lineHeight: 1.6 }}>
        Z-AXIS STACK<br />
        <span style={{ color: 'var(--color-fg-muted)' }}>5 observational layers</span>
      </div>
      {/* stage */}
      <div style={{ position: 'absolute', inset: 0, perspective: '1800px', perspectiveOrigin: '50% 25%' }}>
        <div style={{ position: 'relative', width: '100%', height: '100%', transformStyle: 'preserve-3d', transform: poses[pose], transition: 'transform .7s cubic-bezier(.2,.7,.3,1)', willChange: 'transform' }}>
          {layers.map((L, i) => (
            <div key={L.id} style={{
              position: 'absolute', top: 80, left: 60, right: 60, bottom: 60,
              transform: `translateZ(${L.z * (pose === 0 ? 0 : pose === 2 ? .5 : 1)}px)`,
              background: L.bg,
              border: `1px ${pose === 0 ? 'solid' : 'dashed'} rgb(var(--color-accent-glow)/.25)`,
              borderRadius: 'var(--r-1)',
              opacity: pose === 0 ? (i === 0 ? 1 : 0.35) : 1,
              transition: 'transform .7s cubic-bezier(.2,.7,.3,1), opacity .4s',
              willChange: 'transform, opacity',
              overflow: 'hidden',
            }}>
              <div style={{ position: 'absolute', top: 4, left: 8, fontFamily: 'var(--font-mono)', fontSize: 8, color: 'var(--color-accent-fg)', letterSpacing: '.08em', textTransform: 'uppercase', opacity: pose === 0 ? 0 : 1, transition: 'opacity .4s' }}>{L.label}</div>
              {L.render()}
            </div>
          ))}
        </div>
      </div>
      {/* caption */}
      <div style={{ position: 'absolute', bottom: 10, left: 10, right: 10, display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontFamily: 'var(--font-mono)', fontSize: 9, color: 'var(--color-fg-disabled)', letterSpacing: '.04em' }}>
        <span>editor-scroll · perspective: 1800px · preserve-3d</span>
        <span>body[data-explode=1] .lyr {'{'} translateZ(40·80·120·160·200px) {'}'}</span>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// ROOT
// ─────────────────────────────────────────────────────────────
function CodeModeRoot() {
  return (
    <DesignCanvas title="MASC · Code Mode" subtitle="Tree · Editor · Review · Activity · Layers">

      <DCSection id="toolbar" title="Code toolbar">
        <DCArtboard id="tb-default" label="default · file chips + search + view tabs" width={1120} height={60}><Toolbar /></DCArtboard>
      </DCSection>

      <DCSection id="tree" title="File tree">
        <DCArtboard id="tree-default" label="default · keeper dots + diff counts" width={300} height={560}><Tree /></DCArtboard>
      </DCSection>

      <DCSection id="editor" title="Editor">
        <DCArtboard id="ed-default" label="default · blame + cursors + diff + minimap" width={900} height={560}><Editor /></DCArtboard>
      </DCSection>

      <DCSection id="review" title="Review rail">
        <DCArtboard id="rv-default" label="default · 5 threads, kinds + drift + resolved" width={360} height={560}><Review /></DCArtboard>
      </DCSection>

      <DCSection id="activity" title="Activity timeline">
        <DCArtboard id="ac-default" label="default · this file, NOW at top" width={300} height={560}><Activity /></DCArtboard>
      </DCSection>

      <DCSection id="layers" title="L2 Observational Layers (bar)">
        <DCArtboard id="lb-default" label="5 toggles · opacity control · EXPLODE" width={720} height={60}><LayerBar /></DCArtboard>
      </DCSection>

      <DCSection id="full" title="Full Code Mode · 4-column composite">
        <DCArtboard id="code-full" label="toolbar · tree · editor · review · activity" width={1800} height={620}>
          <div style={{ display: 'grid', gridTemplateColumns: '220px minmax(0,1fr) 320px 260px', gridTemplateRows: '32px minmax(0,1fr)', height: 620, background: 'var(--color-bg-page)', border: '1px solid var(--color-border-default)' }}>
            <div style={{ gridColumn: '1 / -1' }}><Toolbar /></div>
            <Tree />
            <Editor height={588} />
            <Review height={588} />
            <Activity height={588} />
          </div>
        </DCArtboard>
      </DCSection>

      <DCSection id="split" title="Split mode · cockpit + code">
        <DCArtboard id="split-default" label="180px cockpit strip · brass NOW divider · full code zone" width={1400} height={680}><SplitMode /></DCArtboard>
      </DCSection>

      <DCSection id="explode" title="3D Explode · z-axis observational stack">
        <DCArtboard id="explode-default" label="source + L1–L5 on z-axis · flat / exploded / tilt poses" width={900} height={560}><ExplodeLayers /></DCArtboard>
      </DCSection>

    </DesignCanvas>
  );
}

window.CodeModeRoot = CodeModeRoot;
