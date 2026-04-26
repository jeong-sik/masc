/* eslint-disable react/no-danger */
const { useState } = React;

/* ─── Snippets ────────────────────────────────────────────────────────────
 * Each: { id, group, title, desc, src, html }
 *   src  → which CSS file the classes come from
 *   html → copy-paste markup (also rendered via dangerouslySetInnerHTML)
 * ────────────────────────────────────────────────────────────────────── */

const SNIPPETS = [
  // ───── Atoms ─────
  {
    id: 'chip-states', group: 'atoms', src: 'source_styles/primitives.css',
    title: 'Chip — status variants',
    desc: 'Inline status chip with optional dot. 6 tones + ghost. Append .sm / .lg for size.',
    html:
`<span class="chip is-brass"><span class="dot"></span>brass</span>
<span class="chip is-ok"><span class="dot"></span>ok</span>
<span class="chip is-warn"><span class="dot"></span>warn</span>
<span class="chip is-err"><span class="dot"></span>err</span>
<span class="chip is-info"><span class="dot"></span>info</span>
<span class="chip is-stalled"><span class="dot"></span>stalled</span>
<span class="chip is-ghost">ghost</span>`,
  },
  {
    id: 'pill-states', group: 'atoms', src: 'source_styles/primitives.css',
    title: 'Pill — runtime state',
    desc: 'Higher-contrast badge for run state. No border, fills with tinted bg.',
    html:
`<span class="pill is-running">RUNNING</span>
<span class="pill is-paused">PAUSED</span>
<span class="pill is-ok">OK</span>
<span class="pill is-warn">WARN</span>
<span class="pill is-err">ERR</span>
<span class="pill is-info">INFO</span>
<span class="pill is-stalled">STALLED</span>`,
  },
  {
    id: 'bar-fill', group: 'atoms', src: 'source_styles/primitives.css',
    title: 'Bar — single fill',
    desc: 'Linear progress / utilisation bar. Status modifiers: .is-ok / .is-warn / .is-err.',
    html:
`<div style="display:flex;flex-direction:column;gap:6px;width:240px">
  <div class="bar"><div class="fill" style="width:72%"></div></div>
  <div class="bar is-warn"><div class="fill" style="width:54%"></div></div>
  <div class="bar is-err"><div class="fill" style="width:88%"></div></div>
</div>`,
  },
  {
    id: 'bar-segmented', group: 'atoms', src: 'source_styles/primitives.css',
    title: 'Bar — segmented',
    desc: 'Composition bar — proportional segments. Use .seg-ok / .seg-err / .seg-warn / .seg-idle.',
    html:
`<div class="bar-seg" style="width:240px">
  <span class="seg-ok"   style="width:62%"></span>
  <span class="seg-warn" style="width:18%"></span>
  <span class="seg-err"  style="width:8%"></span>
  <span class="seg-idle" style="width:12%"></span>
</div>`,
  },
  {
    id: 'spark-line', group: 'atoms', src: 'source_styles/primitives.css',
    title: 'Sparkline — bar style',
    desc: 'Compact mini-chart from inline <i> bars. Last bar always brass.',
    html:
`<div class="spark is-brass" style="width:80px;height:14px">
  <i style="height:30%"></i><i style="height:55%"></i><i style="height:42%"></i>
  <i style="height:68%"></i><i style="height:50%"></i><i style="height:75%"></i>
  <i style="height:60%"></i><i style="height:90%"></i>
</div>`,
  },
  {
    id: 'buttons-variants', group: 'atoms', src: 'source_styles/primitives.css',
    title: 'Button — variants',
    desc: 'Default / primary / danger / ghost. Mono caps, hairline border.',
    html:
`<button class="btn">default</button>
<button class="btn primary">primary</button>
<button class="btn danger">danger</button>
<button class="btn ghost">ghost</button>`,
  },
  {
    id: 'buttons-sizes', group: 'atoms', src: 'source_styles/primitives.css',
    title: 'Button — sizes',
    desc: 'Append .sm / .xs for compact. .icon variant is square.',
    html:
`<button class="btn">md</button>
<button class="btn sm">sm</button>
<button class="btn xs">xs</button>
<button class="btn icon" aria-label="more">⋯</button>`,
  },
  {
    id: 'kbd-keys', group: 'atoms', src: 'source_styles/primitives.css',
    title: 'Keyboard hint',
    desc: 'Inline keycap. Combine with text for shortcut docs.',
    html:
`<span style="font-family:var(--font-mono);font-size:11px;color:var(--color-fg-muted)">
  open palette
  <span class="kbd">⌘</span><span class="kbd">K</span>
  · run cell
  <span class="kbd">⇧</span><span class="kbd">↵</span>
</span>`,
  },
  {
    id: 'inline-token', group: 'atoms', src: 'source_styles/primitives.css',
    title: 'Inline code token (.tk)',
    desc: 'Inline mono token for IDs / values inside body text. Brass and err variants.',
    html:
`<p style="font-family:var(--font-sans);font-size:12px;color:var(--color-fg-secondary);line-height:1.5;max-width:320px">
  Keeper <span class="tk is-brass">@nick0cave</span> claimed task
  <span class="tk">t-4012</span> on branch <span class="tk">feat/cascade-v3</span>;
  drift score <span class="tk is-err">0.84</span> exceeded threshold.
</p>`,
  },
  {
    id: 'kv-row', group: 'atoms', src: 'source_styles/primitives.css',
    title: 'Key/value row',
    desc: 'Two-col label/value strip for inspectors and drawers. .is-wide for wider key column.',
    html:
`<div style="display:flex;flex-direction:column;gap:1px;width:280px">
  <div class="kv-row"><span class="k">claim_holder</span><span class="v">@nick0cave</span></div>
  <div class="kv-row"><span class="k">branch</span><span class="v">feat/cascade-v3</span></div>
  <div class="kv-row"><span class="k">drift</span><span class="v">0.84</span></div>
  <div class="kv-row"><span class="k">tok/sec</span><span class="v">142</span></div>
</div>`,
  },
  {
    id: 'band-states', group: 'atoms', src: 'source_styles/primitives.css',
    title: 'Status band',
    desc: '2px running indicator strip. Use as left-edge accent on cards or full-width section markers.',
    html:
`<div style="display:flex;flex-direction:column;gap:6px;width:240px">
  <div class="band is-running"></div>
  <div class="band is-ok"></div>
  <div class="band is-warn"></div>
  <div class="band is-err"></div>
  <div class="band is-stalled"></div>
</div>`,
  },

  // ───── Phase 2 row primitives ─────
  {
    id: 'board-post', group: 'phase2', src: 'preview/components.css',
    title: 'Board post — direct',
    desc: 'Hearth post card. Modifier: .direct / .automation / .hot for left edge accent.',
    html:
`<article class="bd-post direct">
  <div class="vote">
    <span class="up">▲</span>
    <span class="net">7</span>
    <span class="dn">▼</span>
  </div>
  <div class="main">
    <div class="h">
      <span class="au">@nick0cave</span>
      <span class="kk direct">DIRECT</span>
      <span class="he">cascade-v3</span>
      <span class="at">12:04</span>
    </div>
    <div class="ttl">Drift threshold tripped on t-4012 — handing off.</div>
    <div class="body">Claim released. Holding evidence in episode ep-882. @sangsu can you take from here? Branch is clean.</div>
    <div class="ft"><button>reply 3</button><button>thread</button><button>copy</button></div>
  </div>
  <div class="meta-r">EP-882<br/>3 RPL</div>
</article>`,
  },
  {
    id: 'decision-row', group: 'phase2', src: 'preview/components.css',
    title: 'Decision row',
    desc: 'decisions.jsonl entry. Outcome chip: .success / .error / .failure.',
    html:
`<div style="display:flex;flex-direction:column">
  <div class="dec-row">
    <span class="ts">12:04:07</span>
    <span class="kpr">@nick0cave</span>
    <span class="out success">OK</span>
    <div class="body">
      <span class="act">claim · t-4012 · cascade-v3</span>
      <span class="bel">belief: drift &lt; 0.5 · plan: extend probe</span>
      <span class="lat">latency 142ms</span>
    </div>
  </div>
  <div class="dec-row">
    <span class="ts">12:05:21</span>
    <span class="kpr">@sangsu</span>
    <span class="out failure">FAIL</span>
    <div class="body">
      <span class="act">probe · k-merge-blockers</span>
      <span class="blk">blocked: cascade hop 3 missed</span>
      <span class="lat">latency 880ms</span>
    </div>
  </div>
</div>`,
  },
  {
    id: 'memory-row', group: 'phase2', src: 'preview/components.css',
    title: 'Memory row',
    desc: 'memory.jsonl entry. Tag chip: .verified / .learned / .observed / .plan.',
    html:
`<div style="display:flex;flex-direction:column">
  <div class="mem-row">
    <span class="ts">11:58</span>
    <span class="kpr">@nick0cave</span>
    <span class="tag verified">VERIFIED</span>
    <span class="body">cascade-v3 hop 4 returns null when probe times out — confirmed across 6 runs.</span>
  </div>
  <div class="mem-row">
    <span class="ts">12:02</span>
    <span class="kpr">@sangsu</span>
    <span class="tag learned">LEARNED</span>
    <span class="body">drift_score above 0.8 reliably predicts handoff within 3 turns.</span>
  </div>
  <div class="mem-row">
    <span class="ts">12:08</span>
    <span class="kpr">@keeper-merge</span>
    <span class="tag plan">PLAN</span>
    <span class="body">extend probe window to 4s before falling back to cascade hop 5.</span>
  </div>
</div>`,
  },
  {
    id: 'ar-loop-row', group: 'phase2', src: 'preview/components.css',
    title: 'Autoresearch loop row',
    desc: 'ar-loop summary line. State: .open / .closed. Confidence: .hi / .lo / .vlo.',
    html:
`<div style="display:flex;flex-direction:column">
  <div class="ar-row">
    <span class="id">ar-2025-04-11</span>
    <span class="topic">Why does cascade hop 4 return null on probe timeout?</span>
    <span class="st closed">CLOSED</span>
    <span class="conf hi">0.92</span>
  </div>
  <div class="ar-row">
    <span class="id">ar-2025-04-18</span>
    <span class="topic">Drift threshold calibration vs claim_holder churn</span>
    <span class="st open">OPEN</span>
    <span class="conf lo">0.41</span>
  </div>
  <div class="ar-row">
    <span class="id">ar-2025-04-22</span>
    <span class="topic">Operator nudge cooldown effect on stalled tasks</span>
    <span class="st open">OPEN</span>
    <span class="conf vlo">0.18</span>
  </div>
</div>`,
  },
  {
    id: 'ar-finding-card', group: 'phase2', src: 'preview/components.css',
    title: 'Autoresearch finding card',
    desc: 'Hypothesis · evidence · conclusion. Three styled blocks with brass / muted / ok accents.',
    html:
`<div class="ar-find">
  <div class="hdr">
    <span class="id">f-002</span>
    <span class="loop">ar-2025-04-11</span>
    <span class="conf">conf 0.92</span>
  </div>
  <div>
    <div class="sec-h">Hypothesis</div>
    <div class="hy">Cascade hop 4 returns null when upstream probe exceeds 1.8s.</div>
  </div>
  <div>
    <div class="sec-h">Evidence</div>
    <div class="ev-list">
      <div class="ev">6/6 runs above 1.8s probe → null hop 4</div>
      <div class="ev">0/12 runs below 1.5s probe → null hop 4</div>
      <div class="ev">tracebacks consistent at cascade.py:412</div>
    </div>
  </div>
  <div>
    <div class="sec-h">Conclusion</div>
    <div class="co">Hop 4 lacks timeout-aware fallback. Patch with 4s probe window.</div>
  </div>
</div>`,
  },
  {
    id: 'episode-card', group: 'phase2', src: 'preview/components.css',
    title: 'Episode card',
    desc: 'Per-turn episode card with participant pills and outcome chip.',
    html:
`<div class="ep-card">
  <div class="h">
    <span class="id">ep-882</span>
    <span class="ts">12:04 → 12:11</span>
    <div class="pp">
      <span class="p">@nick0cave</span>
      <span class="p">@sangsu</span>
      <span class="p">@keeper-merge</span>
    </div>
    <span class="oc">RESOLVED</span>
  </div>
  <div class="sm">Drift on t-4012 escalated to handoff. Probe timeout root-caused; patch queued.</div>
  <div class="lns">
    <div class="ln">claim released by @nick0cave at 12:05</div>
    <div class="ln">probe extended to 4s by @sangsu at 12:08</div>
    <div class="ln">decision logged: extend window in cascade-v3</div>
  </div>
</div>`,
  },
  {
    id: 'audit-row', group: 'phase2', src: 'preview/components.css',
    title: 'Audit ledger row',
    desc: 'Streaming audit entry. Kind chip: .board / .cascade / .keeper / .message / .operator / .suite / .task / .tool / .verdict.',
    html:
`<div style="display:flex;flex-direction:column">
  <div class="aud-row">
    <span class="ts">12:04</span>
    <span class="ac">@nick0cave</span>
    <span class="kn cascade">CASCADE</span>
    <div class="sb">probe timeout on hop 4<span class="pl">cascade-v3 · run r-7782</span></div>
    <span class="du">1.84s</span>
  </div>
  <div class="aud-row">
    <span class="ts">12:05</span>
    <span class="ac">@sangsu</span>
    <span class="kn operator">OPERATOR</span>
    <div class="sb">nudge: extend probe window<span class="pl">target: keeper-merge · cooldown 30s</span></div>
    <span class="du">—</span>
  </div>
  <div class="aud-row">
    <span class="ts">12:08</span>
    <span class="ac">@keeper-merge</span>
    <span class="kn verdict">VERDICT</span>
    <div class="sb">approve patch<span class="pl">decision id d-9921</span></div>
    <span class="du">220ms</span>
  </div>
</div>`,
  },
  {
    id: 'cascade-hop', group: 'phase2', src: 'preview/components.css',
    title: 'Cascade hop list',
    desc: 'Per-hop step list. Hit / miss / skip modifiers on .step.',
    html:
`<div class="cb-cascade">
  <div class="id">cascade-v3 · r-7782</div>
  <div class="step hit"><span class="ix">1</span><span class="name">parse_intent</span><span class="ms">42ms</span></div>
  <div class="step hit"><span class="ix">2</span><span class="name">resolve_holder</span><span class="ms">88ms</span></div>
  <div class="step hit"><span class="ix">3</span><span class="name">probe_branch</span><span class="ms">1.84s</span></div>
  <div class="step miss"><span class="ix">4</span><span class="name">extract_diff</span><span class="ms">timeout</span></div>
  <div class="step skip"><span class="ix">5</span><span class="name">apply_patch</span><span class="ms">—</span></div>
  <div class="total">total <span class="n">2.04s</span> · 3 hit · 1 miss · 1 skip</div>
</div>`,
  },
  {
    id: 'heuristic-row', group: 'phase2', src: 'preview/components.css',
    title: 'Heuristic firing row',
    desc: 'Stress / heuristic firing entry. Add .fired class for left-accent + soft red bg.',
    html:
`<div style="display:flex;flex-direction:column">
  <div class="hr-row fired">
    <span class="ts">12:04</span>
    <span class="mod">drift_threshold</span>
    <span class="det">claim_holder churn &gt; 3 in 5min on t-4012</span>
    <span class="site">cascade.py:412</span>
    <span class="num over">0.84</span>
    <span class="fl t">FIRED</span>
  </div>
  <div class="hr-row">
    <span class="ts">12:06</span>
    <span class="mod">probe_latency</span>
    <span class="det">p95 above 1.5s on hop 4</span>
    <span class="site">cascade.py:380</span>
    <span class="num">1.62</span>
    <span class="fl f">arm</span>
  </div>
</div>`,
  },
  {
    id: 'nudge-row', group: 'phase2', src: 'preview/components.css',
    title: 'Operator nudge row',
    desc: 'Operator → keeper nudge log entry.',
    html:
`<div style="display:flex;flex-direction:column">
  <div class="nd-row">
    <span class="ts">12:05</span>
    <span style="font-family:var(--font-mono);font-size:11px;color:var(--color-accent-fg)">@sangsu</span>
    <span style="font-family:var(--font-mono);font-size:9px;padding:1px 5px;border:1px solid var(--color-accent-fg-dim);color:var(--color-accent-fg);background:rgb(var(--color-accent-glow)/.08);text-transform:uppercase;letter-spacing:.06em">→ keeper-merge</span>
    <span style="font-family:var(--font-mono);font-size:11px;color:var(--color-fg-primary);line-height:1.4">extend probe window to 4s before fallback — see ar-2025-04-11/f-002</span>
    <span style="font-family:var(--font-mono);font-size:9px;color:var(--color-fg-disabled);text-transform:uppercase;letter-spacing:.06em">cooldown 30s</span>
  </div>
</div>`,
  },
  {
    id: 'keeper-bdi-row', group: 'phase2', src: 'preview/components.css',
    title: 'Keeper BDI row',
    desc: 'Belief / Desire / Intention panel rows for the keeper inspector.',
    html:
`<div class="ki-bdi">
  <div class="row"><span class="lbl">will</span><div class="v">resolve t-4012 by EOD without ceding claim to drift &gt; 0.5</div></div>
  <div class="row"><span class="lbl">needs</span><div class="v">stable probe latency on cascade-v3 hop 4 · operator approval for window extension</div></div>
  <div class="row"><span class="lbl">desires</span><div class="v">verified patch in trunk · ep-882 closed · drift heuristic re-armed</div></div>
  <div class="hz">
    <span class="lbl">horizon</span><span class="v">3 turns</span>
    <span class="lbl">commit</span><span class="v">soft</span>
  </div>
</div>`,
  },
  {
    id: 'branch-row', group: 'phase2', src: 'preview/components.css',
    title: 'Branch list row',
    desc: 'Branch picker row with tag, status, ahead/behind, head SHA, keeper avatars. Add .on for selected.',
    html:
`<div class="br-list">
  <div class="row on">
    <span class="glyph">⎇</span>
    <span class="nm">feat/cascade-v3</span>
    <span class="tag PRIMARY">PRIMARY</span>
    <span class="st dirty">dirty</span>
    <span class="ahbh"><span class="ah">+12</span><span class="bh">−2</span></span>
    <span class="head">a1b2c3d</span>
  </div>
  <div class="row">
    <span class="glyph">⎇</span>
    <span class="nm">fix/probe-timeout</span>
    <span class="tag FIX">FIX</span>
    <span class="st clean">clean</span>
    <span class="ahbh"><span class="ah">+3</span></span>
    <span class="head">9f0e1d2</span>
  </div>
  <div class="row">
    <span class="glyph">⎇</span>
    <span class="nm">ar/drift-calibration</span>
    <span class="tag AUTORESEARCH">AUTORESEARCH</span>
    <span class="st research">research</span>
    <span class="ahbh"><span class="ah">+0</span><span class="bh">−18</span></span>
    <span class="head">7c5b4a3</span>
  </div>
</div>`,
  },

  // ───── Forms ─────
  {
    id: 'input-text', group: 'forms', src: 'preview/forms.html',
    title: 'Text input — labelled field',
    desc: 'Standard text field. Label above, hint below. Add .is-err / .is-ok for state.',
    html:
`<div class="field" style="width:240px">
  <span class="field-label">goal id</span>
  <input class="input" value="goal-merge-blockers" />
  <span class="field-hint">kebab-case · max 40ch</span>
</div>`,
  },
  {
    id: 'checkbox-list', group: 'forms', src: 'preview/forms.html',
    title: 'Checkbox list',
    desc: 'Stack of .check items. Hidden input + visual .box for the checkmark.',
    html:
`<div style="display:flex;flex-direction:column;gap:8px">
  <label class="check"><input type="checkbox" checked /><span class="box"></span>auto-claim stale tasks</label>
  <label class="check"><input type="checkbox" checked /><span class="box"></span>broadcast nudges to channel</label>
  <label class="check"><input type="checkbox" /><span class="box"></span>open episodes by default</label>
  <label class="check"><input type="checkbox" /><span class="box"></span>verbose cascade logs</label>
</div>`,
  },
  {
    id: 'toggle-row', group: 'forms', src: 'preview/forms.html',
    title: 'Toggle switch',
    desc: 'Compact switch — track + thumb. Brass glow when on.',
    html:
`<div style="display:flex;flex-direction:column;gap:10px">
  <label class="toggle"><input type="checkbox" checked /><span class="track"></span>safe autonomy</label>
  <label class="toggle"><input type="checkbox" checked /><span class="track"></span>broadcast to #ops</label>
  <label class="toggle"><input type="checkbox" /><span class="track"></span>experimental cascade-v3</label>
</div>`,
  },
  {
    id: 'segmented-control', group: 'forms', src: 'preview/forms.html',
    title: 'Segmented control',
    desc: 'Mutually exclusive button group. .is-active marks the selected segment.',
    html:
`<div class="segmented">
  <button>1d</button>
  <button class="is-active">7d</button>
  <button>30d</button>
  <button>all</button>
</div>`,
  },
];

const GROUPS = [
  { id: 'atoms',  name: 'Atoms',                  desc: 'Smallest reusable building blocks — chips, bars, sparks, buttons.' },
  { id: 'phase2', name: 'Phase 2 row primitives', desc: 'Reusable rows from board, decisions, memory, autoresearch, audit, cascade, heuristic, nudge, keeper, branch.' },
  { id: 'forms',  name: 'Form controls',          desc: 'Inputs, checkboxes, toggles, segmented controls.' },
];

/* ─── components ──────────────────────────────────────────────────────── */

function CodePanel({ html, src }) {
  const [tab, setTab] = useState('html');
  const [copied, setCopied] = useState(false);

  const cssNote =
`/* Markup uses classes from:
 *   ${src}
 *
 * Make sure that file is loaded on your page, then the HTML above
 * renders styled. CSS variables live in colors_and_type.css and
 * source_styles/tokens.css — load those first.
 */`;

  const text = tab === 'html' ? html : cssNote;

  const onCopy = async () => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    } catch (e) {
      // fallback: select + execCommand
      const ta = document.createElement('textarea');
      ta.value = text; document.body.appendChild(ta); ta.select();
      try { document.execCommand('copy'); setCopied(true); setTimeout(() => setCopied(false), 1200); }
      finally { document.body.removeChild(ta); }
    }
  };

  return (
    <div className="sn-code">
      <div className="tabs">
        <button className={tab === 'html' ? 'on' : ''} onClick={() => setTab('html')}>html</button>
        <button className={tab === 'css'  ? 'on' : ''} onClick={() => setTab('css')}>css source</button>
        <button className={'copy' + (copied ? ' ok' : '')} onClick={onCopy}>
          {copied ? 'copied ✓' : 'copy'}
        </button>
      </div>
      <pre><code>{text}</code></pre>
    </div>
  );
}

function SnippetCard({ s }) {
  return (
    <div className="sn-card" id={s.id}>
      <div className="hd">
        <span className="id">{s.id}</span>
        <span className="ti">{s.title}</span>
        <div className="tags"><span className="tag">{s.group}</span></div>
      </div>
      {s.desc ? <div className="desc">{s.desc}</div> : null}
      <div className="sn-body">
        <div className="sn-prev">
          <div className="wrap" dangerouslySetInnerHTML={{ __html: s.html }} />
        </div>
        <CodePanel html={s.html} src={s.src} />
      </div>
      <div className="sn-foot">
        <span className="lbl">classes from</span>
        <span className="css">{s.src}</span>
      </div>
    </div>
  );
}

function App() {
  const grouped = GROUPS.map(g => ({ ...g, items: SNIPPETS.filter(s => s.group === g.id) }));
  const total = SNIPPETS.length;

  return (
    <div className="sn-page">
      <div className="sn-head">
        <h1>Snippets</h1>
        <span className="sub">copy-paste ready · {total} blocks</span>
      </div>
      <p className="sn-intro">
        Each snippet is plain HTML using classes from the cockpit design system. Load
        {' '}<code>colors_and_type.css</code>, <code>source_styles/tokens.css</code>,
        {' '}<code>source_styles/primitives.css</code>, and <code>preview/components.css</code> on your page,
        then drop the markup in. Click <strong>copy</strong> to grab the HTML.
      </p>

      <nav className="sn-toc">
        {grouped.map(g => (
          <React.Fragment key={g.id}>
            <span className="gh">{g.name}</span>
            {g.items.map(s => <a key={s.id} href={'#' + s.id}>{s.id}</a>)}
          </React.Fragment>
        ))}
      </nav>

      {grouped.map(g => (
        <section key={g.id} id={'g-' + g.id}>
          <div className="sn-grouph">
            <span className="nm">{g.name}</span>
            <span className="desc">{g.desc}</span>
          </div>
          {g.items.map(s => <SnippetCard key={s.id} s={s} />)}
        </section>
      ))}
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
