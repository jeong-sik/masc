// cb-shared.jsx — shared primitives used across component artboards
// Components published on window so other Babel scripts can use them.

const { useState, useEffect, useMemo, useRef } = React;

// Status dot — decorative; meaning lives in the adjacent text.
function Dot({ kind = 'idle', size = 'md', beat = false, style }) {
  return <span className={`cb-dot ${kind} ${size === 'sm' ? 'sm' : size === 'lg' ? 'lg' : ''} ${beat ? 'beat' : ''}`} style={style} aria-hidden="true" />;
}

// Mini sparkline (random but seeded bars) — used in KPI + lifeline
function Spark({ data, color = 'brass', bars = 14 }) {
  const d = data || Array.from({ length: bars }, (_, i) => 30 + Math.sin(i * 0.7) * 20 + Math.random() * 30);
  return (
    <span className={`spark is-${color}`} style={{ height: 16 }} aria-hidden="true">
      {d.map((h, i) => <i key={i} style={{ height: `${Math.max(5, Math.min(100, h))}%` }} />)}
    </span>
  );
}

// Lifeline-style sine+spike svg path
function Heartbeat({ height = 32, width = 320, phase = 0 }) {
  const points = [];
  const segs = 60;
  for (let i = 0; i <= segs; i++) {
    const t = i / segs;
    const x = t * width;
    // mostly flat with a spike every ~12 samples
    let y = height / 2 + Math.sin((t + phase) * 6) * 1.5;
    const s = (i + Math.floor(phase * 60)) % 12;
    if (s === 3) y -= height * 0.35;
    if (s === 4) y += height * 0.4;
    if (s === 5) y -= height * 0.15;
    points.push(`${x.toFixed(1)},${y.toFixed(1)}`);
  }
  return (
    <svg viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none" aria-hidden="true" focusable="false">
      <polyline points={points.join(' ')} fill="none" stroke="var(--brass-1)" strokeWidth="1.2" />
      <circle cx={width - 2} cy={height / 2} r="2" fill="var(--brass-1)">
        <animate attributeName="r" values="2;3.5;2" dur="1.4s" repeatCount="indefinite" />
      </circle>
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

// Utility — get keeper color var name from id
function kClass(id) {
  return ({
    'nick0cave': 'brass',
    'masc-improver': 'ok',
    'sangsu': 'info',
    'qa-king': 'err',
    'rama': 'stalled',
  })[id] || 'idle';
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

Object.assign(window, { Dot, Spark, Heartbeat, Chip, Pill, Vhead, kClass, useTyping, getTheme, setTheme });
