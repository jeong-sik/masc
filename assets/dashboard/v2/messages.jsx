/* MASC v2 — message rendering: blocks, tool traces, feedback, suggestions */
const { useState } = React;

function StatusDot({ status, pulse }) {
  const cls = status === 'run' ? 'ok' : status === 'pause' ? 'warn' : status === 'off' ? '' : status;
  return <span className={`dot2 ${cls} ${pulse ? 'pulse' : ''}`}></span>;
}

// Canonical keeper identity: color slot + 2-letter sigil (keeper-badge.ts).
function SigilBadge({ k, size = 18, beat }) {
  return (
    <span className={`sigil ${beat ? 'heartbeat' : ''}`}
      style={{ '--kc': `var(--kp${k.slot})`, width: size, height: size, fontSize: Math.round(size * 0.46) }}
      title={k.id} aria-label={k.id}>{k.sigil}</span>
  );
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

function jsonHl(obj) {
  const s = JSON.stringify(obj, null, 2);
  return s
    .replace(/("[^"]+"):/g, '<span class="jk">$1</span>:')
    .replace(/: ("[^"]*")/g, ': <span class="js">$1</span>');
}

function ToolTrace({ tool }) {
  const [open, setOpen] = useState(false);
  return (
    <div className={`tool ${open ? 'open' : ''}`}>
      <div className="tool-hd" onClick={() => setOpen(o => !o)}>
        <span className="chev">▶</span>
        <span>도구 호출 · <span className="tname">{tool.name}</span></span>
        <span className="tdot"><StatusDot status={tool.status === 'ok' ? 'run' : 'bad'} /></span>
        <span className="tdur mono">{tool.dur}</span>
      </div>
      <div className="tool-body">
        <div className="tool-kv">
          <span className="tk">args</span>
          <span className="tv"></span>
        </div>
        <pre dangerouslySetInnerHTML={{ __html: jsonHl(tool.args) }}></pre>
        <div className="tool-kv" style={{ paddingTop: '10px' }}>
          <span className="tk">result</span>
          <span className="tv"></span>
        </div>
        <pre dangerouslySetInnerHTML={{ __html: tool.result.replace(/("[^"]+")/g, '<span class="js">$1</span>') }}></pre>
      </div>
    </div>
  );
}

function Block({ b }) {
  if (b.t === 'p') return <p dangerouslySetInnerHTML={{ __html: b.html }}></p>;
  if (b.t === 'h4') return <h4 dangerouslySetInnerHTML={{ __html: b.html }}></h4>;
  if (b.t === 'ul') return <ul>{b.items.map((it, i) => <li key={i} dangerouslySetInnerHTML={{ __html: it }}></li>)}</ul>;
  if (b.t === 'callout') return (
    <div className="callout">
      <span className="ico">{'\u26A0'}</span>
      <span dangerouslySetInnerHTML={{ __html: b.html }}></span>
    </div>
  );
  if (b.t === 'table') {
    const cell = (c) => (typeof c === 'object' ? c : { v: c });
    return (
      <table className="md-table">
        <thead>
          <tr>{b.head.map((h, i) => { const c = cell(h); return <th key={i} className={c.num ? 'num' : ''}>{c.v}</th>; })}</tr>
        </thead>
        <tbody>
          {b.rows.map((row, ri) => (
            <tr key={ri}>{row.map((c0, ci) => { const c = cell(c0); return <td key={ci} className={`${c.num ? 'num' : ''} ${c.muted ? 'muted' : ''}`}>{c.v}</td>; })}</tr>
          ))}
        </tbody>
      </table>
    );
  }
  return null;
}

function Feedback({ verified }) {
  const [vote, setVote] = useState(0);
  const [copied, setCopied] = useState(false);
  return (
    <div className="fbk">
      <button className="fbk-btn" title="복사" onClick={() => { setCopied(true); setTimeout(() => setCopied(false), 1200); }}>
        {copied ? '\u2713 복사됨' : '\u2398 복사'}
      </button>
      <button className={`fbk-btn ${vote === 1 ? 'on' : ''}`} title="좋아요" onClick={() => setVote(v => v === 1 ? 0 : 1)}>{'\u25B3'} 좋음</button>
      <button className={`fbk-btn ${vote === -1 ? 'on' : ''}`} title="별로" onClick={() => setVote(v => v === -1 ? 0 : -1)}>{'\u25BD'} 별로</button>
      <button className="fbk-btn" title="재생성">{'\u21BB'} 재생성</button>
      {verified && <span className="fbk-verify">{'\u25C8'} 검증 통과</span>}
    </div>
  );
}

function Suggestions({ items, onPick }) {
  if (!items || !items.length) return null;
  return (
    <div className="suggest">
      <span className="lbl">추천 후속 질문</span>
      <div className="suggest-row">
        {items.map((s, i) => (
          <button key={i} className="chip" onClick={() => onPick && onPick(s)}>
            <span className="pre">{'\u203A'}</span>{s}
          </button>
        ))}
      </div>
    </div>
  );
}

function SourceBadge({ source }) {
  const label = { dashboard: 'Dashboard', discord: 'Discord', slack: 'Slack' }[source] || source;
  return <span className={`src-badge ${source}`}>{label}</span>;
}

function Message({ m, keeper, onPickSuggestion }) {
  const isUser = m.role === 'user';
  return (
    <div className={`msg ${isUser ? 'from-user' : ''}`}>
      {isUser
        ? <div className="msg-av op">YOU</div>
        : <SigilBadge k={keeper} size={34} beat={keeper.status === 'run'} />}
      <div className="msg-col">
        <div className="msg-hd">
          <span className="who">{isUser ? 'operator' : keeper.kr}</span>
          {!isUser && <span className="whoh">{keeper.id}</span>}
          <SourceBadge source={m.source} />
          <span className="ts mono">{m.ts}</span>
        </div>
        {m.tools && m.tools.map((t, i) => <ToolTrace key={i} tool={t} />)}
        <div className={`bubble ${isUser ? 'user' : ''}`} style={m.tools ? { marginTop: '10px' } : null}>
          {m.blocks.map((b, i) => <Block key={i} b={b} />)}
        </div>
        {!isUser && <Feedback verified={m.verified} />}
        {!isUser && <Suggestions items={m.suggestions} onPick={onPickSuggestion} />}
      </div>
    </div>
  );
}

function TypingMessage({ keeper }) {
  return (
    <div className="msg">
      <SigilBadge k={keeper} size={34} beat={keeper.status === 'run'} />
      <div className="msg-col">
        <div className="msg-hd">
          <span className="who">{keeper.kr}</span>
          <span className="whoh">{keeper.id}</span>
          <span className="ts mono">작성 중…</span>
        </div>
        <div className="bubble">
          <span className="typing"><i></i><i></i><i></i></span>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { StatusDot, SigilBadge, SigilChip, Avatar, ToolTrace, Block, Feedback, Suggestions, SourceBadge, Message, TypingMessage });
