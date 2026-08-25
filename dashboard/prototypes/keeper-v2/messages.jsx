/* MASC v2 — message rendering: blocks, tool traces, feedback, suggestions */
const { useState } = React;

// Identity + status leaves now DELEGATE to the shared library (window.KV)
// so the live app and the component catalog render from one source.
// Signatures are kept (k-object in, status-string in) so call-sites are
// untouched; the library atoms do the actual drawing.
function StatusDot({ status, pulse }) {
  const state = status === 'run' ? 'ok' : status === 'pause' ? 'warn' : status === 'off' ? 'idle' : status;
  return React.createElement(window.KV.Dot, { state, pulse });
}

// Canonical keeper identity: color slot + 2-letter sigil (keeper-badge.ts).
function SigilBadge({ k, size = 18, beat }) {
  return React.createElement(window.KV.Sigil,
    { slot: k.slot, size, heartbeat: beat, title: k.id, fontScale: 0.46 }, k.sigil);
}

function SigilChip({ k }) {
  return (
    <span className="sigil-chip" style={{ '--kc': `var(--kp${k.slot})` }}>
      <SigilBadge k={k} size={17} /><span>{k.id}</span>
    </span>
  );
}

// Portrait when present, else the sigil badge. Used for the large chat hero.
function Avatar({ k, baseClass, size }) {
  const [err, setErr] = useState(false);
  const src = PORTRAIT(k.portrait);
  if (!src || err) {
    return <span className={baseClass} style={{ '--kc': `var(--kp${k.slot})` }} data-sigil><SigilBadge k={k} size={size} /></span>;
  }
  return <img className={baseClass} src={src} onError={() => setErr(true)} alt={k.id} />;
}

// total tool duration across the trace → "X.Xs"
function traceDur(trace) {
  let sum = 0, has = false;
  trace.forEach(st => {
    const m = st.kind === 'tool' && st.dur && st.dur.match(/([\d.]+)s/);
    if (m) { sum += parseFloat(m[1]); has = true; }
  });
  return has ? (Math.round(sum * 10) / 10) + 's' : null;
}

// Thin adapter → shared KVM.Trace (rich steps live in the library now).
function TraceGroup({ trace }) {
  const toolN = trace.filter(s => s.kind === 'tool').length;
  const dur = traceDur(trace);
  const meta = (<React.Fragment>{toolN > 0 && <span>도구 {toolN}</span>}{dur && <span className="mono">{dur}</span>}</React.Fragment>);
  return <window.KVM.Trace label="작업 과정" glyph="◈" count={`${trace.length}단계`} meta={meta} steps={trace} />;
}

// VoiceMemo / AttachCard / Broadcast moved into the shared library (window.KVM
// .Voice / .Attach / .Broadcast). Block() below maps the `b` block → those.

function linkifyHtml(html) {
  if (!html || html.indexOf('http') === -1 || html.indexOf('<a ') !== -1) return html;
  return html.replace(/(^|[\s(>])(https?:\/\/[^\s<)]+[^\s<).,!?:;])/g, '$1<a class="inline-link" href="$2" target="_blank" rel="noopener noreferrer">$2</a>');
}

// Web link unfurl — compact preview card (favicon · title · desc · source)
function LinkCard({ b }) {
  let host = b.meta;
  try { host = new URL(b.url).hostname.replace(/^www\./, ''); } catch (e) {}
  return (
    <a className={`linkcard ${b.kind || ''}`} href={b.url} target="_blank" rel="noopener noreferrer">
      <span className="linkcard-fav">{b.fav || (host ? host[0].toUpperCase() : '\u2197')}</span>
      <span className="linkcard-body">
        <span className="linkcard-title">{b.title}</span>
        {b.desc && <span className="linkcard-desc">{b.desc}</span>}
        <span className="linkcard-meta mono">{b.meta || host}</span>
      </span>
      <span className="linkcard-go">{'\u2197'}</span>
    </a>
  );
}

function Block({ b }) {
  const KVM = window.KVM;
  if (b.t === 'broadcast') return <KVM.Broadcast tag="⊚ 브로드캐스트" scope={b.scope} via={b.via} note={b.note} recipients={b.recipients} audience={b.audience || 'speech'} />;
  if (b.t === 'link') return <LinkCard b={b} />;
  if (b.t === 'p') return <p dangerouslySetInnerHTML={{ __html: linkifyHtml(b.html) }}></p>;
  if (b.t === 'h4') return <h4 dangerouslySetInnerHTML={{ __html: b.html }}></h4>;
  if (b.t === 'ul') return <ul>{b.items.map((it, i) => <li key={i} dangerouslySetInnerHTML={{ __html: linkifyHtml(it) }}></li>)}</ul>;
  if (b.t === 'callout') return <KVM.Callout html={b.html} />;
  if (b.t === 'table') return <KVM.MdTable head={b.head} rows={b.rows} />;
  if (b.t === 'code') return <KVM.CodeBlock caption={b.cap} html={b.html} />;
  if (b.t === 'shell') return <KVM.ShellBlock title={b.title} lines={b.lines} exit={b.exit} dur={b.dur} />;
  if (b.t === 'artifact') {
    const icon = b.kind === 'md' ? '⌹' : b.kind === 'svg' ? '◫' : b.kind === 'json' ? '{ }' : '⎙';
    const sub = `${(b.kind || 'file').toUpperCase()}${b.size ? ` · ${b.size}` : ''}${b.note ? ` · ${b.note}` : ''}`;
    return <KVM.Artifact icon={icon} name={b.name} sub={sub} actions={[{ label: '열기' }, { label: '다운로드' }]} />;
  }
  if (b.t === 'attach') return <KVM.Attach clip="◫" name={b.name} dims={b.dims} svg={b.svg} src={b.src} ph={b.ph} tag="이미지 첨부" via={b.via} size={b.size} />;
  if (b.t === 'voice') return <KVM.Voice secs={b.secs} wave={b.wave} via={b.via} size={b.size} transcript={b.transcript} sttLabel="받아쓰기" />;
  if (b.t === 'image') return (
    <figure className="img-out">
      <div className="img-frame">{b.src ? <img src={b.src} alt={b.cap || ''} /> : <div className="img-ph">{b.ph || '실행 화면'}</div>}</div>
      {b.cap && <figcaption>{b.cap}</figcaption>}
    </figure>
  );
  if (b.t === 'svg') return (
    <figure className="svg-out">
      <div className="svg-frame" dangerouslySetInnerHTML={{ __html: b.svg }}></div>
      {b.cap && <figcaption>{b.cap}</figcaption>}
    </figure>
  );
  if (b.t === 'fusion') {
    const dec = (window.FUSION_DECISION || {})[b.decision] || { lbl: b.decision, cls: '', glyph: '◈' };
    return (
      <div className={`msg-fusion dec-${dec.cls}`}>
        <div className="msg-fusion-h">
          <span className="msg-fusion-tag">◈ Fusion 심의</span>
          <span className="msg-fusion-run mono">{b.run_id}</span>
          <span className={`fus-dec-badge ${dec.cls}`}>{dec.glyph} {dec.lbl}</span>
        </div>
        <p className="msg-fusion-ans">{b.resolved}</p>
        <div className="msg-fusion-foot">
          <span>패널 {b.panel}개 · 심판 종합</span>
          <button type="button" className="msg-fusion-link" onClick={() => window.__navFusion && window.__navFusion(b.run_id)}>전체 패널·심판 보기 →</button>
        </div>
      </div>
    );
  }
  return null;
}

// Thin adapter → shared FeedbackRow (self-managed, KO, with copy + regenerate).
function Feedback({ verified, onInspect, onRegenerate }) {
  return <window.KVM.FeedbackRow verified={verified} onInspect={onInspect} showCopy showVote={false} ko />;
}

function Suggestions({ items, onPick }) {
  if (!items || !items.length) return null;
  return (
    <div className="suggest">
      <span className="lbl">추천 후속 질문</span>
      <div className="suggest-row">
        {items.map((s, i) => (
          <SuggestionChip key={i} pre={'\u203A'} onClick={() => onPick && onPick(s)}>{s}</SuggestionChip>
        ))}
      </div>
    </div>
  );
}

function SourceBadge({ source }) {
  const label = { dashboard: 'Dashboard', discord: 'Discord', slack: 'Slack', imessage: 'iMessage' }[source] || source;
  return <span className={`src-badge ${source}`}>{label}</span>;
}

// Thin adapter → shared Provenance with an expandable scope preview.
function CtxFrom({ cf }) {
  const detail = cf.preview ? (
    <div className="cf-detail">
      <div className="cf-detail-h">{cf.guild} · {cf.channel} · {cf.via} 가 가져온 {cf.msgs}개 중 일부</div>
      {cf.preview.map((m, i) => (
        <div key={i} className="cf-msg">
          <span className="cf-ts mono">{m[0]}</span>
          <span className="cf-who">{m[1]}</span>
          <span className="cf-text">{m[2]}</span>
        </div>
      ))}
    </div>
  ) : null;
  return (
    <window.KVM.Provenance icon={'\u2318'} action="범위 보기" detail={detail}>
      <span><b>{cf.channel}</b> 맥락 포함 · 메시지 {cf.msgs}개 · {cf.range}</span>
    </window.KVM.Provenance>
  );
}

const Message = React.memo(function Message({ m, keeper, onPickSuggestion, onRegenerate }) {
  const isUser = m.role === 'user';
  const [inspect, setInspect] = useState(false);
  const trace = m.trace || (m.tools ? m.tools.map(t => ({ kind: 'tool', ...t })) : null);
  const senderName = isUser ? (m.nick || m.who || 'operator') : keeper.id;
  const handle = isUser && m.nick && m.who ? m.who : null;
  const avLabel = (m.nick || m.who) ? (m.nick || m.who).replace(/^@/, '').slice(0, 2).toUpperCase() : 'YOU';
  return (
    <div className={`msg ${isUser ? 'from-user' : ''}`} style={{ contentVisibility: 'auto', containIntrinsicSize: 'auto 120px' }}>
      {isUser
        ? <div className="msg-av op" title={senderName}>{avLabel}</div>
        : <SigilBadge k={keeper} size={34} beat={keeper.status === 'run'} />}
      <div className="msg-col">
        <div className="msg-hd">
          <span className="who">{senderName}</span>
          {handle && <span className="whoh">{handle}</span>}
          <SourceBadge source={m.source} />
          <span className="ts mono">{m.ts}</span>
        </div>
        {m.ctxFrom && <CtxFrom cf={m.ctxFrom} />}
        {trace && <TraceGroup trace={trace} />}
        <div className={`bubble ${isUser ? 'user' : ''}`} style={trace ? { marginTop: '10px' } : null}>
          {m.blocks.map((b, i) => <Block key={i} b={b} />)}
        </div>
        {!isUser && <Feedback verified={m.verified} onInspect={() => setInspect(true)} onRegenerate={onRegenerate} />}
        {!isUser && <Suggestions items={m.suggestions} onPick={onPickSuggestion} />}
      </div>
      {inspect && <TurnInspector keeper={keeper} m={m} onClose={() => setInspect(false)} />}
    </div>
  );
}, (a, b) => (
  // the message object is immutable once pushed; skip re-render on parent
  // churn (typing indicator, sibling appends) when this turn is unchanged
  a.m === b.m && a.m.regen === b.m.regen &&
  a.keeper.id === b.keeper.id && a.keeper.status === b.keeper.status
));

function TypingMessage({ keeper }) {
  return (
    <div className="msg">
      <SigilBadge k={keeper} size={34} beat={keeper.status === 'run'} />
      <div className="msg-col">
        <div className="msg-hd">
          <span className="who">{keeper.id}</span>
          <span className="ts mono">작성 중…</span>
        </div>
        <div className="bubble">
          <span className="typing"><i></i><i></i><i></i></span>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { StatusDot, SigilBadge, SigilChip, Avatar, TraceGroup, Block, Feedback, Suggestions, SourceBadge, Message, TypingMessage });
