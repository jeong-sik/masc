// @ds-adherence-ignore -- v2 skin primitive library (wraps the established v2.css classes by design)
/* ══════════════════════════════════════════════════════════════
   MASC v2 — Primitive component library
   Turns the raw v2.css class strings into named, reusable React
   primitives. The big win: the SEVEN forked badge classes
   (.state-pill / .fsm-chip / .wk-pri / .src-badge / .kc-trait /
   .att-count / .set-rolepill) converge into ONE <Pill> component
   with a `tone` prop. Visual identity is preserved 1:1 — tone tints
   are driven by the same design tokens the classes used.

   Load order (in the host HTML):
     React + ReactDOM (UMD)  →  babel  →  this file (text/babel)
   Everything is exported onto window + window.KV at the bottom.
   ══════════════════════════════════════════════════════════════ */

const { useState } = React;

/* ── token-driven tone table (the converged badge palette) ───────── */
const PILL_TONES = {
  neutral: { color: 'var(--text-mid)',     border: 'var(--border-main)',                                   bg: 'var(--bg-card)' },
  ok:      { color: 'var(--status-ok)',    border: 'color-mix(in oklab, var(--status-ok) 45%, transparent)',   bg: 'color-mix(in oklab, var(--status-ok) 10%, var(--bg-card))' },
  warn:    { color: 'var(--status-warn)',  border: 'color-mix(in oklab, var(--status-warn) 45%, transparent)', bg: 'color-mix(in oklab, var(--status-warn) 9%, var(--bg-card))' },
  bad:     { color: 'var(--status-bad)',   border: 'color-mix(in oklab, var(--status-bad) 42%, transparent)',  bg: 'color-mix(in oklab, var(--status-bad) 10%, var(--bg-card))' },
  volt:    { color: 'var(--volt-strong)',  border: 'var(--volt-dim)',                                      bg: 'var(--volt-wash)' },
  info:    { color: 'var(--info)',         border: 'color-mix(in oklab, var(--info) 38%, transparent)',        bg: 'color-mix(in oklab, var(--info) 9%, var(--bg-card))' },
};

/* ════════════════════════════════════════════════════════════════
   Dot — the status pip (.dot2)
   ════════════════════════════════════════════════════════════════ */
function Dot({ state = 'idle', pulse = false }) {
  const cls = ['dot2'];
  if (state && state !== 'idle') cls.push(state); // ok | warn | bad | busy
  if (pulse) cls.push('pulse');
  return React.createElement('span', { className: cls.join(' ') });
}

/* ════════════════════════════════════════════════════════════════
   Pill — the CONVERGED badge. One component, seven former classes.
     tone : neutral | ok | warn | bad | volt | info
     mono : monospace face (former .fsm-chip)
     dot  : true → neutral pip, or a state string ('ok'|'warn'|…)
     soft : transparent ground, hairline (former .kc-trait)
     count: numeric tally styling (former .att-count / .kp-att)
   ════════════════════════════════════════════════════════════════ */
function Pill({ tone = 'neutral', mono = false, dot = false, dotPulse = false, soft = false, count = false, children, style, ...rest }) {
  const t = PILL_TONES[tone] || PILL_TONES.neutral;
  const base = {
    display: 'inline-flex', alignItems: 'center', gap: 6,
    fontFamily: mono ? 'var(--font-mono)' : 'var(--font-ui)',
    fontSize: count ? 10 : 11,
    fontWeight: count ? 600 : 400,
    letterSpacing: mono ? '0.04em' : '0.05em',
    lineHeight: 1.2,
    padding: count ? '1px 7px' : '4px 10px',
    borderRadius: 'var(--radius-pill)',
    border: '1px solid ' + t.border,
    color: t.color,
    background: soft ? 'transparent' : t.bg,
    whiteSpace: 'nowrap',
    ...style,
  };
  const dotState = dot === true ? (tone === 'neutral' ? 'idle' : tone) : dot;
  // belt-and-braces: keep component props off the DOM node (the in-browser
  // babel rest-spread can let named props slip through into `rest`)
  const SKIP = { tone: 1, mono: 1, dot: 1, dotPulse: 1, soft: 1, count: 1 };
  const domRest = {};
  for (const k in rest) if (!SKIP[k]) domRest[k] = rest[k];
  return React.createElement(
    'span',
    { style: base, ...domRest },
    dot ? React.createElement(Dot, { state: dotState, pulse: dotPulse }) : null,
    children
  );
}

/* ── thin presets that PROVE the convergence: every former badge is
   now one <Pill> call. Kept as named exports so call-sites read
   semantically, but they all funnel through the single component. ── */
const STATE_TONE = { running: 'ok', paused: 'warn', offline: 'neutral', blocked: 'bad', compacting: 'warn' };
function StatePill({ state = 'running', children }) {
  return React.createElement(Pill, { tone: STATE_TONE[state] || 'neutral', dot: true }, children || state);
}
function FsmChip({ children }) {
  return React.createElement(Pill, { tone: 'neutral', mono: true }, children);
}
const PRI_TONE = { high: 'bad', normal: 'volt', low: 'neutral' };
function PriorityPill({ level = 'normal', children }) {
  return React.createElement(Pill, { tone: PRI_TONE[level] || 'neutral', soft: level === 'low',
    style: { fontSize: 9.5, letterSpacing: '0.08em', textTransform: 'uppercase', padding: '2px 7px' } }, children || level);
}
const SOURCE_TONE = { dashboard: 'volt', discord: 'info', slack: 'ok', imessage: 'info' };
function SourceBadge({ source = 'dashboard' }) {
  return React.createElement(Pill, { tone: SOURCE_TONE[source] || 'neutral',
    style: { fontSize: 9, letterSpacing: '0.1em', textTransform: 'uppercase', padding: '2px 6px', borderRadius: 'var(--radius-xs)' } }, source);
}
function TraitPill({ children, ...rest }) {
  return React.createElement(Pill, { tone: 'volt',
    style: { fontSize: 10.5, padding: '2px 9px' }, ...rest }, children);
}
function CountBadge({ tone = 'bad', children, ...rest }) {
  return React.createElement(Pill, { tone, count: true, mono: true, ...rest }, children);
}
function RolePill({ children, ...rest }) {
  return React.createElement(Pill, { tone: 'volt', mono: true, style: { fontSize: 11, padding: '3px 10px' }, ...rest }, children);
}

/* ════════════════════════════════════════════════════════════════
   Sigil — slot-colored monogram identity (.sigil)
   ════════════════════════════════════════════════════════════════ */
function Sigil({ slot = 1, size = 32, heartbeat = false, title, fontScale = 0.4, style, children }) {
  const kc = typeof slot === 'number' ? `var(--kp${slot})` : slot;
  return React.createElement('span', {
    className: 'sigil' + (heartbeat ? ' heartbeat' : ''),
    title, 'aria-label': title,
    style: { '--kc': kc, width: size, height: size, fontSize: Math.round(size * fontScale), ...style },
  }, children);
}
function SigilChip({ slot = 1, mono, children }) {
  const kc = typeof slot === 'number' ? `var(--kp${slot})` : slot;
  return React.createElement('span', { className: 'sigil-chip', style: { '--kc': kc } },
    React.createElement(Sigil, { slot, size: 17 }, mono),
    children);
}

/* ════════════════════════════════════════════════════════════════
   Buttons — .act / .send / .ctool / .rfilter
   ════════════════════════════════════════════════════════════════ */
function Button({ variant = 'action', danger = false, icon = false, children, ...rest }) {
  if (variant === 'primary') return React.createElement('button', { className: 'send', ...rest }, children);
  if (variant === 'tool')    return React.createElement('button', { className: 'ctool', ...rest }, children);
  const cls = ['act']; if (danger) cls.push('danger'); if (icon) cls.push('icon');
  return React.createElement('button', { className: cls.join(' '), ...rest }, children);
}
function FilterChip({ active = false, count, children, ...rest }) {
  return React.createElement('button', { className: 'rfilter' + (active ? ' on' : ''), ...rest },
    children, count != null ? React.createElement('span', { className: 'n' }, count) : null);
}
// LogFilter — the flatter, label-only filter used in the log/level strips
// (.log-f). Distinct from FilterChip (.rfilter, pill + count) by design.
function LogFilter({ active = false, children, ...rest }) {
  return React.createElement('button', { className: 'log-f' + (active ? ' on' : ''), ...rest }, children);
}
// SuggestionChip — a keeper's proposed next action (.chip), with a leading
// arrow affordance (.pre). Used under streamed replies and in the dock.
function SuggestionChip({ pre = '\u2192', children, ...rest }) {
  return React.createElement('button', { className: 'chip', ...rest },
    pre ? React.createElement('span', { className: 'pre' }, pre) : null, children);
}

/* ════════════════════════════════════════════════════════════════
   Form controls — toggle / segmented / stepper / slider
   ════════════════════════════════════════════════════════════════ */
function Toggle({ on = false, onChange, size }) {
  const cls = 'set-toggle' + (on ? ' on' : '') + (size === 'sm' ? ' sm' : '');
  return React.createElement('button', {
    className: cls, role: 'switch', 'aria-checked': on,
    onClick: () => onChange && onChange(!on),
  }, React.createElement('span', { className: 'knob' }));
}
function Segmented({ options = [], value, onChange }) {
  return React.createElement('div', { className: 'set-seg' },
    options.map(opt => {
      const v = typeof opt === 'object' ? opt.value : opt;
      const label = typeof opt === 'object' ? opt.label : opt;
      return React.createElement('button', {
        key: v, className: 'set-seg-b' + (v === value ? ' on' : ''),
        onClick: () => onChange && onChange(v),
      }, label);
    }));
}
function Stepper({ value = 0, min = -Infinity, max = Infinity, onChange }) {
  return React.createElement('div', { className: 'set-stepper' },
    React.createElement('button', { onClick: () => onChange && onChange(Math.max(min, value - 1)) }, '−'),
    React.createElement('span', { className: 'mono' }, value),
    React.createElement('button', { onClick: () => onChange && onChange(Math.min(max, value + 1)) }, '+'));
}
function Slider({ value = 0, min = 0, max = 100, step = 1, onChange, format }) {
  return React.createElement('div', { className: 'set-slider' },
    React.createElement('input', {
      type: 'range', min, max, step, value,
      onChange: e => onChange && onChange(Number(e.target.value)),
    }),
    React.createElement('span', { className: 'mono' }, format ? format(value) : value));
}

/* ════════════════════════════════════════════════════════════════
   Data viz — meter / spinner / stat cell / vital
   ════════════════════════════════════════════════════════════════ */
function Meter({ pct = 0, hot = false }) {
  return React.createElement('div', { className: 'meter' + (hot ? ' hot' : '') },
    React.createElement('span', { style: { width: Math.max(0, Math.min(100, pct)) + '%' } }));
}
function Spinner({ size }) {
  const cls = 'spinner' + (size === 'sm' ? ' sm' : size === 'lg' ? ' lg' : '');
  return React.createElement('span', { className: cls });
}
function LoadingRow({ children }) {
  return React.createElement('div', { className: 'loading-row' },
    React.createElement(Spinner, { size: 'sm' }), children);
}
// LoadingBar — indeterminate sweeping bar (.loading-bar) for waits with no
// known duration. The horizontal companion to Spinner/LoadingRow.
function LoadingBar(props) {
  return React.createElement('div', { className: 'loading-bar', ...props });
}
const STAT_TONE = { ok: 'ok', bad: 'bad', warn: 'warn', volt: 'volt' };
function StatCell({ label, value, sub, tone }) {
  return React.createElement('div', { className: 'ov-kpi' },
    React.createElement('div', { className: 'ov-kpi-k' }, label),
    React.createElement('div', { className: 'ov-kpi-v' + (STAT_TONE[tone] ? ' ' + STAT_TONE[tone] : '') },
      value, sub ? React.createElement('small', null, ' ' + sub) : null));
}
function Vital({ k, v, tone }) {
  return React.createElement('div', { className: 'vital' },
    React.createElement('div', { className: 'vk' }, k),
    React.createElement('div', { className: 'vv' + (tone === 'volt' ? ' volt' : '') }, v));
}
function Vitals({ items = [] }) {
  return React.createElement('div', { className: 'vitals' },
    items.map((it, i) => React.createElement(Vital, { key: i, ...it })));
}

/* ── export everything to window so the (separate) app babel script
   can use these as JSX globals ── */
const KV = {
  Dot, Pill, StatePill, FsmChip, PriorityPill, SourceBadge, TraitPill, CountBadge, RolePill,
  Sigil, SigilChip, Button, FilterChip, LogFilter, SuggestionChip,
  Toggle, Segmented, Stepper, Slider,
  Meter, Spinner, LoadingRow, LoadingBar, StatCell, Vital, Vitals,
  PILL_TONES,
};
Object.assign(window, KV);
window.KV = KV;
