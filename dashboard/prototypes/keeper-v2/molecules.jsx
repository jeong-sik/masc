// @ds-adherence-ignore -- v2 skin molecule library (composes primitives.jsx + the established v2.css/surfaces.css classes by design)
/* ══════════════════════════════════════════════════════════════
   MASC v2 — Molecule component library
   The catalog's "molecules" — shell chrome, the chat scaffold,
   the content blocks a keeper embeds in a reply, the turn-inspector
   viz, and the feedback/attention surfaces — were still raw class
   strings. This turns the rest of the catalog into named, reusable
   React molecules built FROM the atoms in primitives.jsx (KV).

   Same contract as primitives.jsx:
     React + ReactDOM (UMD)  →  babel  →  primitives.jsx  →  this file
   Everything is exported onto window + window.KVM at the bottom.
   ══════════════════════════════════════════════════════════════ */

const { useState, useMemo } = React;
const {
  Dot, Pill, StatePill, Sigil, Button,
} = window.KV;

const cx = (...a) => a.filter(Boolean).join(' ');

/* ════════════════════════════════════════════════════════════════
   FORM ROWS — label + hint on the left, control on the right
   SetRow is the one true reusable form molecule; consumed by the
   Keeper Config drawer (organisms-5) and re-declared locally by the
   Settings surface. (The shell chrome — Wordmark/TopBar/NavRail/… —
   and the chat scaffold that once sat in this library were dead: the
   live app draws its own bespoke versions in shell.jsx / rails.jsx /
   messages.jsx, so they were removed.)
   ════════════════════════════════════════════════════════════════ */
function SetRow({ label, hint, children }) {
  return (
    <div className="set-row">
      <div className="set-row-l"><div className="set-label">{label}</div>{hint ? <div className="set-hint">{hint}</div> : null}</div>
      <div className="set-row-c">{children}</div>
    </div>
  );
}

/* ════════════════════════════════════════════════════════════════
   FSM LIFELINE — the 12-state keeper machine as a vertical lifeline
   ════════════════════════════════════════════════════════════════ */
function FsmLifeline({ steps = [], style }) {
  // steps: [{ label, state: 'done'|'cur'|'' }]
  return (
    <div className="fsm" style={style}>
      {steps.map((s, i) => (
        <div key={i} className={cx('fsm-step', s.state)}><span className="pip" />{s.label}</div>
      ))}
    </div>
  );
}

/* ════════════════════════════════════════════════════════════════
   STREAMING & LIVE — typing, caret, throughput, progress
   ════════════════════════════════════════════════════════════════ */
function Typing() {
  return <div className="typing"><i /><i /><i /></div>;
}
function StreamingCaret() {
  return <span className="dcaret" />;
}
function TpsLive({ rate = 41 }) {
  return (
    <span className="tps-live"><span className="tps-dot" /><span className="mono">{rate} tok/s</span></span>
  );
}
function SegmentedProgress({ done = 0, wip = 0, blocked = 0, total = 100, style }) {
  const rest = Math.max(0, total - done - wip - blocked);
  return (
    <div className="wk-prog" style={{ maxWidth: 'none', ...style }}>
      {done ? <span className="wk-seg done" style={{ flex: done }} /> : null}
      {wip ? <span className="wk-seg wip" style={{ flex: wip }} /> : null}
      {blocked ? <span className="wk-seg blocked" style={{ flex: blocked }} /> : null}
      {rest ? <span style={{ flex: rest }} /> : null}
    </div>
  );
}
function Sparkline({ values, count = 28, label, style }) {
  const heights = useMemo(
    () => values || Array.from({ length: count }, () => 20 + Math.random() * 78),
    [values, count]
  );
  return (
    <div className="tps-spark" style={style}>
      {heights.map((h, i) => <span key={i} style={{ height: h + '%' }} />)}
      {label ? <span className="tps-spark-rt">{label}</span> : null}
    </div>
  );
}
function TelemetryBars({ values, count = 24, hotRate = 0.78, style }) {
  const bars = useMemo(
    () => values || Array.from({ length: count }, () => ({ h: 18 + Math.random() * 80, hot: Math.random() > hotRate })),
    [values, count, hotRate]
  );
  return (
    <div className="ov-bars" style={style}>
      {bars.map((b, i) => <div key={i} className={cx('ov-bar', b.hot && 'hot')} style={{ height: b.h + '%' }} />)}
    </div>
  );
}

/* ════════════════════════════════════════════════════════════════
   MESSAGING — broadcast
   ════════════════════════════════════════════════════════════════ */
const BCAST_ACK = { acked: '확인함', read: '읽음', delivered: '전달됨' };
const BCAST_AUDIENCE = {
  speech: ['발화', '다른 keeper 대화창에도 뜸'],
  record: ['기록', '대화창에는 뜨지 않음 — 기록으로만 남음'],
};
function Broadcast({ scope, via, count, note, recipients = [], tag = 'Broadcast', audience }) {
  // recipients: [{ id, ack: 'acked'|'read'|'delivered', at }]
  const findK = (id) => (window.KEEPERS || []).find(k => k.id === id);
  const ackN = recipients.filter(r => r.ack === 'acked').length;
  const countNode = count != null ? count : (recipients.length ? `${ackN}/${recipients.length} 확인` : null);
  return (
    <div className="bcast">
      <div className="bcast-hd">
        <span className="bcast-tag">{tag}</span>
        {audience && BCAST_AUDIENCE[audience] ? <span className={`bcast-aud ${audience}`} title={BCAST_AUDIENCE[audience][1]}>{BCAST_AUDIENCE[audience][0]}</span> : null}
        {scope ? <span className="bcast-scope mono">{scope}</span> : null}
        {via ? <span className="bcast-via mono">{via}</span> : null}
        {countNode != null ? <span className="bcast-count mono">{countNode}</span> : null}
      </div>
      {note ? <div className="bcast-note">{note}</div> : null}
      {audience && BCAST_AUDIENCE[audience] ? <div className="bcast-aud-note">{BCAST_AUDIENCE[audience][1]}</div> : null}
      {recipients.length ? (
        <div className="bcast-rcpts">
          {recipients.map((r, i) => {
            const k = findK(r.id);
            return (
              <div key={i} className={cx('bcast-rcpt', r.ack)}>
                {k ? <Sigil slot={k.slot} size={16} title={k.id} fontScale={0.46}>{k.sigil}</Sigil> : null}
                <span className="bcast-rcpt-id">{r.id}</span>
                <span className="bcast-ack">{(BCAST_ACK[r.ack] || r.ack)}{r.at ? ` · ${r.at}` : ''}</span>
              </div>
            );
          })}
        </div>
      ) : null}
    </div>
  );
}

/* ════════════════════════════════════════════════════════════════
   CONTENT BLOCKS — what a keeper embeds inside a reply
   ════════════════════════════════════════════════════════════════ */
function Callout({ icon = '⚠', html, children }) {
  return (
    <div className="callout">
      <span className="ico">{icon}</span>
      {html != null ? <span dangerouslySetInnerHTML={{ __html: html }}></span> : <div>{children}</div>}
    </div>
  );
}
function tJsonHl(obj) {
  const s = JSON.stringify(obj, null, 2);
  return s.replace(/("[^"]+"):/g, '<span class="jk">$1</span>:').replace(/: ("[^"]*")/g, ': <span class="js">$1</span>');
}
// One trace step — think / reason(+detail fold) / tool(+args·result fold).
// Drives both the catalog demo (simple steps) and the live transcript (rich).
function TraceStepM({ step }) {
  const [open, setOpen] = useState(false);
  if (step.kind === 'think') {
    return (
      <div className="tstep think"><span className="tnode" /><div className="tstep-main">
        <div className="tstep-row"><span className="tstep-kind">Thinking</span><span className="tstep-text">{step.text}</span></div>
      </div></div>
    );
  }
  if (step.kind === 'reason') {
    const exp = !!step.detail;
    return (
      <div className={cx('tstep', 'reason', open && 'exp')}><span className="tnode" /><div className="tstep-main">
        <div className={cx('tstep-row', exp && 'click')} onClick={() => exp && setOpen(o => !o)}>
          <span className="tstep-kind">Reasoning</span>
          <span className="tstep-text" dangerouslySetInnerHTML={{ __html: step.text }}></span>
          {exp && <span className="chev sm">▶</span>}
        </div>
        {exp && open && <div className="reason-detail" dangerouslySetInnerHTML={{ __html: step.detail }}></div>}
      </div></div>
    );
  }
  // tool
  const hasBody = step.args || step.result;
  const dotState = step.ok != null ? (step.ok ? 'ok' : 'bad') : (step.status === 'bad' ? 'bad' : 'ok');
  return (
    <div className={cx('tstep', 'tool', open && 'exp')}><span className="tnode" /><div className="tstep-main">
      <div className={cx('tstep-row', hasBody && 'click')} onClick={() => hasBody && setOpen(o => !o)}>
        <span className="tstep-kind">Tool</span>
        {step.name && <span className="tname mono">{step.name}</span>}
        <Dot state={dotState} />
        {step.dur && <span className="tdur mono">{step.dur}</span>}
        {hasBody && <span className="chev sm">▶</span>}
      </div>
      {open && hasBody && (
        <div className="tool-body2">
          {step.args && <React.Fragment><div className="tk">args</div><pre dangerouslySetInnerHTML={{ __html: tJsonHl(step.args) }}></pre></React.Fragment>}
          {step.result && <React.Fragment><div className="tk">result</div><pre dangerouslySetInnerHTML={{ __html: String(step.result).replace(/("[^"]+")/g, '<span class="js">$1</span>') }}></pre></React.Fragment>}
        </div>
      )}
    </div></div>
  );
}
function Trace({ label = 'Reasoning', glyph = '◆', count, meta, defaultOpen = true, steps = [] }) {
  // steps: [{ kind:'think'|'reason'|'tool', text, detail?, name?, dur?, ok?|status?, args?, result? }]
  const [open, setOpen] = useState(defaultOpen);
  return (
    <div className={cx('trace', open && 'open')}>
      <div className="trace-hd" onClick={() => setOpen(o => !o)}>
        <span className="chev">▸</span>
        <span className="glyph">{glyph}</span>
        <span className="tlabel">{label}</span>
        {count != null && <span className="tcount">{count}</span>}
        {meta != null && <span className="tmeta">{typeof meta === 'string' ? <span className="mono">{meta}</span> : meta}</span>}
      </div>
      <div className="trace-steps">
        <div className="trace-rail" />
        {steps.map((s, i) => <TraceStepM key={i} step={s} />)}
      </div>
    </div>
  );
}
function CodeBlock({ caption, html, children }) {
  return (
    <div className="code-block">
      {caption ? <div className="code-cap mono">{caption}</div> : null}
      <pre className="mono">{html != null ? <code dangerouslySetInnerHTML={{ __html: html }}></code> : <code>{children}</code>}</pre>
    </div>
  );
}
function ShellBlock({ title = 'keeper@worktree', lines = [], exit, dur }) {
  // lines: [{ kind|t:'cmd'|'ok'|'err'|'dim', text | v(html) }]
  return (
    <div className="shell-block">
      <div className="shell-bar">
        <span className="dot r" /><span className="dot y" /><span className="dot g" />
        {title ? <span className="shell-title mono">{title}</span> : null}
      </div>
      <pre className="mono">
        {lines.map((l, i) => {
          const kind = l.kind || l.t;
          return (
            <div key={i} className={cx('sh-ln', kind)}>
              {kind === 'cmd' ? <span className="sh-prompt">$ </span> : null}
              {l.v != null ? <span dangerouslySetInnerHTML={{ __html: l.v }}></span> : l.text}
            </div>
          );
        })}
      </pre>
      {exit != null ? <div className={cx('shell-exit', exit === 0 ? 'ok' : 'fail')}>exit {exit}{dur ? ` · ${dur}` : ''}</div> : null}
    </div>
  );
}
function MdTable({ head = [], rows = [] }) {
  // head: ['Keeper', {label:'Turns', num:true}]  rows: [['iron-claw', {v:88,num:true}, {v:'running',muted:true}]]
  const cell = c => (typeof c === 'object' ? c : { v: c });
  return (
    <table className="md-table">
      <thead><tr>{head.map((h, i) => { const c = cell(h); return <th key={i} className={c.num ? 'num' : undefined}>{c.v ?? c.label}</th>; })}</tr></thead>
      <tbody>
        {rows.map((r, i) => (
          <tr key={i}>{r.map((c2, j) => { const c = cell(c2); return <td key={j} className={cx(c.num && 'num', c.muted && 'muted')}>{c.v}</td>; })}</tr>
        ))}
      </tbody>
    </table>
  );
}
function Artifact({ icon = '⌬', name, sub, action = 'Open', onAction, actions }) {
  return (
    <div className="artifact">
      <div className="af-ico">{icon}</div>
      <div className="af-meta"><div className="af-name mono">{name}</div><div className="af-sub">{sub}</div></div>
      {actions
        ? actions.map((a, i) => <button key={i} className="af-btn" onClick={a.onClick}>{a.label}</button>)
        : <button className="af-btn" onClick={onAction}>{action}</button>}
    </div>
  );
}
function Attach({ name, dims, src, svg, ph, alt, clip = '◫', tag = 'vision', caption, via, size, imgStyle, mono = true }) {
  const capText = caption != null ? caption : [via, size].filter(Boolean).join(' · ');
  return (
    <div className="attach">
      <div className="attach-hd">
        <span className="attach-clip">{clip}</span>
        <span className={cx('attach-name', mono && 'mono')}>{name}</span>
        {dims ? <span className={cx('attach-dims', mono && 'mono')}>{dims}</span> : null}
      </div>
      <div className="attach-frame">
        {svg ? <span dangerouslySetInnerHTML={{ __html: svg }}></span>
          : src ? <img src={src} alt={alt || name} style={imgStyle} />
          : <div className="img-ph">{ph || '첨부 이미지'}</div>}
      </div>
      {(capText || tag) ? <div className="attach-cap">{tag ? <span className="attach-tag">{tag}</span> : null}{capText}</div> : null}
    </div>
  );
}
// Voice memo — static (catalog: dur/bars/played/stt) OR interactive playback
// (live: pass `secs` + `wave[]` 0..1 and it scrubs a playhead). One source.
function Voice({ dur, secs, wave, bars = 42, played = 17, stt, transcript, sttLabel = 'STT', via, size }) {
  const txt = transcript != null ? transcript : stt;
  const interactive = secs != null;
  const [playing, setPlaying] = useState(false);
  const [prog, setProg] = useState(0);
  React.useEffect(() => {
    if (!interactive || !playing) return;
    const start = performance.now() - prog * secs * 1000;
    let raf;
    const tick = (now) => {
      const p = Math.min(1, (now - start) / (secs * 1000));
      setProg(p);
      if (p >= 1) { setPlaying(false); return; }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [playing]);
  const heights = useMemo(() => Array.from({ length: bars }, () => 22 + Math.random() * 74), [bars]);
  const fmt = (s) => `${Math.floor(s / 60)}:${String(Math.round(s) % 60).padStart(2, '0')}`;
  const toggle = () => { if (prog >= 1) setProg(0); setPlaying(p => !p); };
  const barNodes = wave
    ? wave.map((h, i) => <span key={i} className={cx('vbar', (i + 0.5) / wave.length <= prog && 'on')} style={{ height: `${Math.round(5 + h * 21)}px` }} />)
    : heights.map((h, i) => <span key={i} className={cx('vbar', i < played && 'on')} style={{ height: h + '%' }} />);
  const durLabel = interactive ? fmt((playing || prog > 0) ? prog * secs : secs) : (dur || '0:12');
  return (
    <div className="voice">
      <div className="voice-row">
        <button className={cx('voice-play', playing && 'on')} onClick={interactive ? toggle : undefined} aria-label={playing ? '일시정지' : '재생'}>{playing ? '❙❙' : '▶'}</button>
        <div className="voice-wave">{barNodes}</div>
        <span className="voice-dur mono">{durLabel}</span>
      </div>
      {via ? <div className="voice-meta"><span className="voice-via">{'◌'} {via}</span>{size ? <span className="mono">{size}</span> : null}</div> : null}
      {txt ? <div className="voice-tx"><span className="voice-tx-k">{sttLabel}</span><span className="voice-tx-v">{txt}</span></div> : null}
    </div>
  );
}
function ContextMenu({ slot = 1, mono, name, items = [], style }) {
  // items: [{ label, danger }, 'sep']
  return (
    <div className="kp-menu" style={{ position: 'static', animation: 'none', width: 186, ...style }}>
      {name ? <div className="kp-menu-h"><Sigil slot={slot} size={17}>{mono}</Sigil>{name}</div> : null}
      {items.map((it, i) =>
        it === 'sep'
          ? <div key={i} className="kp-menu-sep" />
          : <button key={i} className={cx('kp-menu-i', it.danger && 'danger')} onClick={it.onClick}>{it.label}</button>
      )}
    </div>
  );
}

/* ════════════════════════════════════════════════════════════════
   INSPECTOR VIZ — turn-level data viz
   ════════════════════════════════════════════════════════════════ */
function StatSummary({ stats = [], cols, style }) {
  // stats: [{ k, v, sub, tone }]
  return (
    <div className="ti-summary" style={{ gridTemplateColumns: cols || `repeat(${stats.length || 1},1fr)`, ...style }}>
      {stats.map((s, i) => (
        <div key={i} className="ti-stat">
          <div className="k">{s.k}</div>
          <div className={cx('v', s.tone)}>{s.v}{s.sub ? <small>{s.sub}</small> : null}</div>
        </div>
      ))}
    </div>
  );
}
function TokenEconomics({ ctxLabel, inPct = 72, outPct = 28, inVal, outVal, style }) {
  return (
    <div className="ti-tok" style={{ padding: 0, ...style }}>
      <div className="ti-tok-top"><span className="lbl">Token mix</span>{ctxLabel ? <span className="ctxpct">{ctxLabel}</span> : null}</div>
      <div className="ti-tok-bar"><span className="seg-in" style={{ width: inPct + '%' }} /><span className="seg-out" style={{ width: outPct + '%' }} /></div>
      <div className="ti-tok-legend"><span className="in">input <b>{inVal}</b></span><span className="out">output <b>{outVal}</b></span></div>
    </div>
  );
}
function Waterfall({ rows = [], total, style }) {
  // rows: [{ kind:'ctx'|'reason'|'tool'|'gen', label, mono, left, width, dur }]
  return (
    <div className="ti-wf" style={style}>
      {rows.map((r, i) => (
        <div key={i} className="ti-wf-row">
          <div className="ti-wf-lbl"><span className={cx('ti-wf-ico', 'ti-k-' + r.kind)} /><span className={cx('nm', r.mono && 'mono')}>{r.label}</span></div>
          <div className="ti-wf-track"><div className={cx('ti-wf-bar', 'ti-k-' + r.kind)} style={{ left: r.left + '%', width: r.width + '%' }} /></div>
          <div className="ti-wf-dur">{r.dur}</div>
        </div>
      ))}
      <div className="ti-wf-foot">
        <span>total <b>{total}</b></span>
        <div className="ti-wf-legend">
          <span><i className="ti-k-ctx" />ctx</span><span><i className="ti-k-reason" />reason</span>
          <span><i className="ti-k-tool" />tool</span><span><i className="ti-k-gen" />gen</span>
        </div>
      </div>
    </div>
  );
}
function InspectorChip({ sub, tone, children }) {
  return <span className={cx('ti-chip', tone)}><span className="sub-k">{sub}</span>{children}</span>;
}

/* ════════════════════════════════════════════════════════════════
   FEEDBACK & ATTENTION
   ════════════════════════════════════════════════════════════════ */
// Response feedback row. Controlled (catalog: value/onChange) OR self-managed
// (live: omit onChange). Optional copy / regenerate buttons + transient "noted".
function FeedbackRow({ value, onChange, onInspect, onRegenerate, onCopy, verified = false, showCopy = false, showRegen = false, showVote = true, ko = false }) {
  const controlled = onChange != null;
  const [internal, setInternal] = useState(null);
  const v = controlled ? value : internal;
  const [copied, setCopied] = useState(false);
  const [noted, setNoted] = useState(false);
  const set = (nv) => {
    const next = v === nv ? null : nv;
    if (controlled) onChange(next); else setInternal(next);
    if (next) { setNoted(true); setTimeout(() => setNoted(false), 2200); }
  };
  const L = ko
    ? { good: '좋음', poor: '별로', inspect: '턴 상세', copy: '복사', copied: '복사됨', verify: '검증 통과', regen: '재생성', noted: '피드백 기록됨', up: '△', down: '▽', vk: '◈' }
    : { good: 'Good', poor: 'Poor', inspect: 'Inspect turn', copy: 'Copy', copied: 'Copied', verify: 'verified', regen: 'Regenerate', noted: 'Noted', up: '▲', down: '▼', vk: '✓' };
  return (
    <div className="fbk">
      {showCopy ? <button className="fbk-btn" onClick={() => { setCopied(true); setTimeout(() => setCopied(false), 1200); onCopy && onCopy(); }}>{copied ? `✓ ${L.copied}` : `⎘ ${L.copy}`}</button> : null}
      {showVote ? <button className={cx('fbk-btn', 'up', v === 'up' && 'on')} onClick={() => set('up')}>{L.up} {L.good}</button> : null}
      {showVote ? <button className={cx('fbk-btn', 'down', v === 'down' && 'on')} onClick={() => set('down')}>{L.down} {L.poor}</button> : null}
      {showRegen ? <button className="fbk-btn" onClick={onRegenerate}>{'↻'} {L.regen}</button> : null}
      <button className="fbk-btn inspect" onClick={onInspect}>{ko ? '⊙ ' : ''}{L.inspect}</button>
      {verified ? <span className="fbk-verify" title="교차 검증 통과 — 다른 모델이 이 응답의 사실성·정합성을 확인했다">{L.vk} {L.verify}</span> : null}
      {noted ? <span className="fbk-noted">{'✓'} {L.noted}</span> : null}
    </div>
  );
}
function AttentionItem({ severity = 'warn', children }) {
  return <div className={cx('att-item', severity)}><span className="att-dot" /><div>{children}</div></div>;
}
// External-context provenance. Pass `detail` (a node) to make `action` a
// fold toggle that reveals it (live CtxFrom); otherwise `action`/`onAction`.
function Provenance({ icon = '#', children, action, onAction, detail }) {
  const [open, setOpen] = useState(false);
  const toggles = detail != null && onAction == null;
  const head = (
    <div className="ctx-from">
      <span className="cf-ico">{icon}</span>
      <div>{children}</div>
      {action ? <button className="cf-view" onClick={toggles ? () => setOpen(o => !o) : onAction}>{toggles && open ? '접기' : action}</button> : null}
    </div>
  );
  if (detail == null) return head;
  return <div className="ctx-from-wrap">{head}{open ? detail : null}</div>;
}
function RegenTag({ children = '재생성됨' }) {
  return <span className="regen-tag">{children}</span>;
}
function Noted({ children = '기록됨 ✓' }) {
  return <span className="fbk-noted">{children}</span>;
}
// Manual context-compaction trigger. state: 'idle' | 'busy' | 'done'.
// Shared by the live ContextRail and the catalog so both render one button.
function CompactButton({ state = 'idle', onClick, labels, title }) {
  const L = labels || { idle: '지금 컴팩트', busy: '컴팩트 실행 중…', done: '컴팩트 완료' };
  return (
    <button className={cx('cmp-run', state === 'busy' && 'busy')} onClick={onClick} disabled={state === 'busy'}
      title={title || '컨텍스트를 지금 즉시 압축 — 임계치 도달을 기다리지 않고 operator가 수동 실행'}>
      {state === 'busy'
        ? <React.Fragment><span className="cmp-spin"></span> {L.busy}</React.Fragment>
        : state === 'done'
          ? <React.Fragment>{'\u2713'} {L.done}</React.Fragment>
          : <React.Fragment>{'\u25C9'} {L.idle}</React.Fragment>}
    </button>
  );
}

/* ── export every molecule to window so the demo babel script can
   use these as JSX globals ── */
const KVM = {
  // form rows
  SetRow,
  // fsm
  FsmLifeline,
  // streaming
  Typing, StreamingCaret, TpsLive, SegmentedProgress, Sparkline, TelemetryBars,
  // messaging
  Broadcast,
  // content blocks
  Callout, Trace, CodeBlock, ShellBlock, MdTable, Artifact, Attach, Voice, ContextMenu,
  // inspector viz
  StatSummary, TokenEconomics, Waterfall, InspectorChip,
  // feedback
  FeedbackRow, AttentionItem, Provenance, RegenTag, Noted, CompactButton,
};
Object.assign(window, KVM);
window.KVM = KVM;
