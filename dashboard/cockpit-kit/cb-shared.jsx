// cb-shared.jsx — shared primitives used across component artboards
// Components published on window so other Babel scripts can use them.

const { useState, useEffect, useMemo, useRef } = React;

// Status dot — decorative; meaning lives in the adjacent text.
function Dot({ kind = 'idle', size = 'md', beat = false, style }) {
  return <span className={`cb-dot ${kind} ${size === 'sm' ? 'sm' : size === 'lg' ? 'lg' : ''} ${beat ? 'beat' : ''}`} style={style} aria-hidden="true" />;
}

// Mini sparkline — renders supplied bar heights (0..100). When `data`
// is absent we render an empty container instead of fabricating bars,
// so missing telemetry is visible rather than hidden behind noise.
function Spark({ data, color = 'brass', bars = 14 }) {
  if (!Array.isArray(data) || data.length === 0) {
    return <span className={`spark is-${color} is-empty`} style={{ height: 16 }} aria-label="no data" data-empty="true" />;
  }
  return (
    <span className={`spark is-${color}`} style={{ height: 16 }} aria-hidden="true">
      {data.map((h, i) => <i key={i} style={{ height: `${Math.max(5, Math.min(100, h))}%` }} />)}
    </span>
  );
}

// Lifeline-style svg path. Caller passes `data` (array of y-samples in
// 0..100) plus optional `min`/`max` bounds. Without data we render a
// dashed baseline so the indicator visibly reflects "no signal" rather
// than animating a fake heartbeat.
function Heartbeat({ height = 32, width = 320, data, min = 0, max = 100 }) {
  if (!Array.isArray(data) || data.length === 0) {
    return (
      <svg viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none" aria-label="no data" data-empty="true" focusable="false">
        <line x1="0" y1={height / 2} x2={width} y2={height / 2} stroke="var(--color-fg-muted)" strokeWidth="1" strokeDasharray="3 3" />
      </svg>
    );
  }
  const span = Math.max(1, max - min);
  const segs = data.length - 1 || 1;
  const points = data.map((v, i) => {
    const x = (i / segs) * width;
    const clamped = Math.max(min, Math.min(max, v));
    const y = height - ((clamped - min) / span) * height;
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  });
  return (
    <svg viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none" aria-hidden="true" focusable="false">
      <polyline points={points.join(' ')} fill="none" stroke="var(--color-accent-fg)" strokeWidth="1.2" />
    </svg>
  );
}

// Small chip using design-system class names
function Chip({ kind, children, ...rest }) {
  return <span className={`chip ${kind ? `is-${kind}` : ''}`} {...rest}>{children}</span>;
}

// Pill
function Pill({ kind, children }) {
  return <span className={`pill ${kind ? `is-${kind}` : ''}`}>{children}</span>;
}

// Variant caption that sits above an artboard
function Vhead({ children }) { return <div className="cb-vhead">{children}</div>; }

// Section heading — replaces inline `sec-h` / `sec-title` divs.
// `variant` selects the className ('h' → .sec-h, 'title' → .sec-title).
// `title` + `count` + `right` cover the common structured cases; `children`
// overrides them for ad-hoc markup. `id` enables aria-labelledby cross-refs.
function SectionHeading({
  variant = 'h',
  level = 3,
  id,
  title,
  count,
  right,
  className,
  style,
  children,
}) {
  const base = variant === 'title' ? 'sec-title' : 'sec-h';
  const cls = base + (className ? ' ' + className : '');
  return (
    <div
      className={cls}
      role="heading"
      aria-level={level}
      {...(id ? { id } : {})}
      {...(style ? { style } : {})}
    >
      {children ?? (
        <>
          {title}
          {count != null && <> <span className="count">{count}</span></>}
          {right != null && <> <span className="right" aria-hidden="true">{right}</span></>}
        </>
      )}
    </div>
  );
}

// v0.4: kClass() removed. Use kSlot(id) → 1..12 + <KeeperBadge> instead.

// ─── v0.3 Keeper attribution ──────────────────────────────────────────
// SPEC §3.6 v0.3: color alone never identifies a keeper. Always emit
// color + sigil. <KeeperBadge> is the canonical attribution unit.
//
// kSlot(id)  → optional runtime override, else deterministic hash → palette slot
// kSigil(id) → optional runtime override, else 2-letter monogram
//
// 12-slot mapping uses skip-3 stride so adjacent IDs in a list land on
// hues ≥90° apart, preserving discriminability up to ~10 active keepers.

const KEEPER_REGISTRY = Object.freeze({});

function _keeperRegistryEntry(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const slot = Number(raw.slot);
  const sigil = String(raw.sigil || '').replace(/[^a-z0-9]/gi, '').slice(0, 2).toUpperCase();
  if (!Number.isInteger(slot) || slot < 1 || slot > 12 || sigil.length !== 2) return null;
  return { slot, sigil };
}

function _keeperRegistry() {
  const data = window.MASC_DATA || {};
  const raw = data.keeper_registry || data.keeperRegistry || KEEPER_REGISTRY;
  if (!raw || typeof raw !== 'object') return {};
  const resolved = {};
  Object.entries(raw).forEach(([id, entry]) => {
    const normalized = _keeperRegistryEntry(entry);
    if (normalized) resolved[id] = normalized;
  });
  return resolved;
}

function _keeperRegistryLookup(id) {
  return _keeperRegistry()[String(id)] || null;
}

// FNV-1a 32-bit hash → 1..12 (avoid 0)
function _hash12(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return ((h >>> 0) % 12) + 1;
}

function kSlot(id) {
  const reg = _keeperRegistryLookup(id);
  if (reg) return reg.slot;
  return _hash12(String(id));
}

function kSigil(id) {
  const reg = _keeperRegistryLookup(id);
  if (reg) return reg.sigil;
  // Auto-derive: first letter + first letter after hyphen, else first 2.
  const s = String(id).replace(/[^a-z0-9-]/gi, '');
  const parts = s.split('-').filter(Boolean);
  if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
  return s.slice(0, 2).toUpperCase();
}

// KeeperBadge — sigil square + optional name. The single source of
// truth for "who did this" anywhere in the dashboard.
//
// size: 'sm' (14px) | 'md' (18px) | 'lg' (24px)
// variant: 'sigil' (square only) | 'full' (sigil + name) | 'name' (colored name only — discouraged, only when sigil is shown adjacent)
// beat: optional running indicator — adds a soft glow + subtle pulse on the sigil
//       (SPEC §3.6 v0.3: color = identity, animation = state — kept on the same
//        element only because running keepers benefit from one glanceable cue.)
function KeeperBadge({ id, name, size = 'md', variant = 'full', title, beat = false }) {
  const slot = kSlot(id);
  const sigil = kSigil(id);
  const display = name || id;
  const sizePx = size === 'sm' ? 14 : size === 'lg' ? 24 : 18;
  const fontPx = size === 'sm' ? 8 : size === 'lg' ? 11 : 9;
  const radius = size === 'lg' ? 3 : 2;
  const sigilEl = (
    <span
      className={`kb-sigil k-${slot}${beat ? ' kb-beat' : ''}`}
      style={{
        display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
        width: sizePx, height: sizePx, fontSize: fontPx, borderRadius: radius,
        background: `var(--k-${slot})`, color: 'var(--bg-0)',
        fontFamily: 'var(--font-mono)', fontWeight: 700, letterSpacing: 0,
        flex: 'none',
        boxShadow: beat ? `0 0 6px var(--k-${slot}-glow, var(--k-${slot}))` : undefined,
        animation: beat ? 'anim-heartbeat 1.4s var(--ease-inout) infinite' : undefined,
      }}
      aria-hidden={variant === 'full' ? 'true' : 'false'}
    >{sigil}</span>
  );
  if (variant === 'sigil') {
    return <span className="kb" title={title || display} aria-label={display}>{sigilEl}</span>;
  }
  if (variant === 'name') {
    return <span className="kb-name" style={{ color: `var(--k-${slot})`, fontWeight: 500 }}>{display}</span>;
  }
  return (
    <span className="kb" style={{ display: 'inline-flex', alignItems: 'center', gap: 6, verticalAlign: 'middle' }} title={title}>
      {sigilEl}
      <span className="kb-name" style={{ color: `var(--k-${slot})`, fontFamily: 'var(--font-sans)', fontSize: 11, fontWeight: 500 }}>{display}</span>
    </span>
  );
}

// KeeperStack — presence/avatar stack with hard cap + "+N" overflow.
// SPEC §3.6 v0.3: never render >4 raw sigils stacked; collapse the rest.
function KeeperStack({ ids = [], cap = 4, size = 'md' }) {
  const visible = ids.slice(0, cap);
  const overflow = ids.length - visible.length;
  const sizePx = size === 'sm' ? 14 : size === 'lg' ? 24 : 18;
  return (
    <span className="kb-stack" style={{ display: 'inline-flex', alignItems: 'center' }}>
      {visible.map((id, i) => (
        <span key={id} style={{ marginLeft: i === 0 ? 0 : -4, border: '2px solid var(--color-bg-surface)', borderRadius: 3, display: 'inline-flex' }}>
          <KeeperBadge id={id} variant="sigil" size={size} />
        </span>
      ))}
      {overflow > 0 && (
        <span
          aria-label={`${overflow} more`}
          style={{
            marginLeft: -4, width: sizePx, height: sizePx,
            display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
            background: 'var(--color-bg-surface-2)', color: 'var(--color-fg-secondary)',
            border: '2px solid var(--color-bg-surface)', borderRadius: 3,
            fontFamily: 'var(--font-mono)', fontSize: 10, fontWeight: 600,
          }}
        >+{overflow}</span>
      )}
    </span>
  );
}

// Theme — read/write the active data-theme on <html>.
// Persists to localStorage under "masc-ds-theme" so a reload survives the
// choice. Pass null to clear and fall back to prefers-color-scheme.
const THEME_STORAGE_KEY = 'masc-ds-theme';

function getTheme() {
  return document.documentElement.dataset.theme || null;
}

function setTheme(theme) {
  if (theme === null || theme === undefined) {
    delete document.documentElement.dataset.theme;
    try { localStorage.removeItem(THEME_STORAGE_KEY); } catch (_) {}
    return;
  }
  document.documentElement.dataset.theme = theme;
  try { localStorage.setItem(THEME_STORAGE_KEY, theme); } catch (_) {}
}

// Restore persisted theme on first script load. Safe to call from
// any page that imports cb-shared.jsx; subsequent calls are no-ops
// because dataset.theme is already set.
(function restoreTheme() {
  if (document.documentElement.dataset.theme) return;
  let saved = null;
  try { saved = localStorage.getItem(THEME_STORAGE_KEY); } catch (_) {}
  if (saved === 'light' || saved === 'dark') {
    document.documentElement.dataset.theme = saved;
  }
})();

// Typing hook — types a string into state, char by char, looping
function useTyping(strings, cps = 18) {
  const [text, setText] = useState('');
  const [strIdx, setStrIdx] = useState(0);
  useEffect(() => {
    const cur = strings[strIdx];
    let i = 0;
    const t = setInterval(() => {
      i++;
      setText(cur.slice(0, i));
      if (i >= cur.length) {
        clearInterval(t);
        setTimeout(() => {
          setText('');
          setStrIdx((s) => (s + 1) % strings.length);
        }, 2200);
      }
    }, 1000 / cps);
    return () => clearInterval(t);
  }, [strIdx, strings, cps]);
  return text;
}

Object.assign(window, {
  Dot, Spark, Heartbeat, Chip, Pill, Vhead, SectionHeading,
  kSlot, kSigil, KeeperBadge, KeeperStack, KEEPER_REGISTRY,
  useTyping, getTheme, setTheme,
});
