// cb-group-g.jsx — Foundational primitives missing from inventory:
//   G1 · Empty state            (no-data, search-no-results)
//   G2 · Loading skeleton       (rows, panel, kpi)
//   G3 · Error boundary banner  (recoverable, fatal)
//   G4 · Pagination             (numeric, cursor)
//   G5 · Breadcrumb             (path, with-overflow)
//
// All variants are self-contained — no MASC_DATA dependency. Demo data
// is inlined so cb-group-g.html (preview only) renders standalone.
// SPEC §5 a11y patterns: empty=role=status, loading=aria-busy+role=status,
// error=role=alert, pagination=nav[aria-label], breadcrumb=nav+ol.

const { useState, useMemo } = React;

// ═════════════════════════════════════════════════════════════════
// G1 · EMPTY STATE
// ═════════════════════════════════════════════════════════════════
//
// Use when a section has no data to show. NOT for errors (use G3) and
// NOT for loading (use G2). The element gets role="status" so SR users
// hear the message; visual glyph is decorative.

const G_EMPTY_PANEL = {
  display: 'flex', flexDirection: 'column', alignItems: 'center',
  justifyContent: 'center', gap: '10px',
  padding: '40px 24px',
  background: 'var(--color-bg-surface)',
  border: '1px dashed var(--color-border-strong)',
  borderRadius: '3px',
  color: 'var(--color-fg-muted)',
  fontFamily: 'var(--font-mono)',
  textAlign: 'center',
};

function EmptyNoData({
  title = 'No swimlane events yet',
  hint = 'Keepers will populate this lane once branch activity begins.',
  action,
}) {
  return (
    <section role="status" aria-live="polite" style={G_EMPTY_PANEL}>
      <span aria-hidden="true" style={{
        fontSize: '24px', lineHeight: 1, color: 'var(--color-fg-disabled)',
        letterSpacing: '.15em',
      }}>· · ·</span>
      <span style={{
        fontFamily: 'var(--font-mono)', fontSize: 'var(--fs-13)',
        color: 'var(--color-fg-secondary)', letterSpacing: '-.005em',
      }}>{title}</span>
      <span style={{
        fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)',
        maxWidth: '36ch',
      }}>{hint}</span>
      {action && (
        <button type="button" style={{
          marginTop: '6px',
          padding: '4px 12px',
          background: 'transparent',
          color: 'var(--color-accent-fg)',
          border: '1px solid var(--color-accent-fg-dim)',
          fontFamily: 'var(--font-mono)', fontSize: 'var(--fs-11)',
          letterSpacing: 'var(--track-caps)', textTransform: 'uppercase',
          cursor: 'pointer',
        }}>{action}</button>
      )}
    </section>
  );
}

// Variant: search-no-results — same skeleton, different copy + glyph.
// Carries the query so SR users hear what was searched.
function EmptySearchNoResults({ query = 'lifeline' }) {
  return (
    <section role="status" aria-live="polite"
             aria-label={`No matches for ${query}`} style={G_EMPTY_PANEL}>
      <span aria-hidden="true" style={{
        fontSize: '20px', color: 'var(--color-fg-disabled)',
        fontFamily: 'var(--font-mono)',
      }}>⌕ ∅</span>
      <span style={{
        fontFamily: 'var(--font-mono)', fontSize: 'var(--fs-13)',
        color: 'var(--color-fg-secondary)',
      }}>
        no matches for <span style={{color: 'var(--color-accent-fg)'}}>"{query}"</span>
      </span>
      <span style={{fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)'}}>
        Try a different keeper, branch, or tool name.
      </span>
    </section>
  );
}

// ═════════════════════════════════════════════════════════════════
// G2 · LOADING SKELETON
// ═════════════════════════════════════════════════════════════════
//
// Skeletons set aria-busy="true" + role="status" with an aria-label
// announcing what's loading. The shimmer bars themselves are
// aria-hidden (they're a visual placeholder, not data).

const G_SHIMMER_KEY = '@keyframes cbg-shimmer { 0% { background-position: -200px 0; } 100% { background-position: 200px 0; } }';
const G_SHIMMER_BG = `linear-gradient(90deg, var(--color-bg-surface) 0%, var(--color-bg-panel-alt) 50%, var(--color-bg-surface) 100%)`;
const G_SHIMMER_STYLE = {
  background: G_SHIMMER_BG,
  backgroundSize: '400px 100%',
  animation: 'cbg-shimmer 1.4s ease-in-out infinite',
};

function SkeletonRows({ rows = 5, label = 'Loading swimlane rows' }) {
  return (
    <section role="status" aria-busy="true" aria-label={label}
             style={{
               display: 'flex', flexDirection: 'column', gap: '6px',
               padding: '14px',
               background: 'var(--color-bg-surface)',
               border: '1px solid var(--color-border-default)',
               borderRadius: '3px',
             }}>
      <style>{G_SHIMMER_KEY}</style>
      {Array.from({length: rows}).map((_, i) => (
        <div key={i} aria-hidden="true" style={{
          display: 'flex', alignItems: 'center', gap: '10px',
          height: '22px',
        }}>
          <span style={{
            ...G_SHIMMER_STYLE,
            width: '8px', height: '8px', borderRadius: '50%',
          }}/>
          <span style={{
            ...G_SHIMMER_STYLE,
            width: `${30 + (i*7) % 35}%`, height: '10px',
          }}/>
          <span style={{
            ...G_SHIMMER_STYLE,
            width: `${15 + (i*5) % 20}%`, height: '10px',
            marginLeft: 'auto',
          }}/>
        </div>
      ))}
      <span style={{position: 'absolute', left: '-9999px'}}>{label}…</span>
    </section>
  );
}

function SkeletonKpi({ count = 4 }) {
  return (
    <section role="status" aria-busy="true" aria-label="Loading KPI strip"
             style={{
               display: 'grid', gridTemplateColumns: `repeat(${count}, 1fr)`,
               gap: '10px',
             }}>
      <style>{G_SHIMMER_KEY}</style>
      {Array.from({length: count}).map((_, i) => (
        <div key={i} aria-hidden="true" style={{
          padding: '12px 14px',
          background: 'var(--color-bg-surface)',
          border: '1px solid var(--color-border-default)',
          borderRadius: '3px',
          display: 'flex', flexDirection: 'column', gap: '8px',
        }}>
          <span style={{...G_SHIMMER_STYLE, width: '40%', height: '8px'}}/>
          <span style={{...G_SHIMMER_STYLE, width: '70%', height: '20px'}}/>
          <span style={{...G_SHIMMER_STYLE, width: '50%', height: '6px'}}/>
        </div>
      ))}
    </section>
  );
}

function SkeletonPanel({ height = 180 }) {
  return (
    <section role="status" aria-busy="true" aria-label="Loading panel"
             style={{
               position: 'relative', height: `${height}px`,
               background: 'var(--color-bg-surface)',
               border: '1px solid var(--color-border-default)',
               borderRadius: '3px',
               overflow: 'hidden',
             }}>
      <style>{G_SHIMMER_KEY}</style>
      <div aria-hidden="true" style={{
        position: 'absolute', inset: 0, ...G_SHIMMER_STYLE,
      }}/>
      <div aria-hidden="true" style={{
        position: 'absolute', left: '14px', top: '14px',
        display: 'flex', flexDirection: 'column', gap: '8px',
      }}>
        <span style={{
          width: '80px', height: '8px',
          background: 'var(--color-border-strong)',
        }}/>
        <span style={{
          width: '140px', height: '14px',
          background: 'var(--color-border-strong)',
        }}/>
      </div>
    </section>
  );
}

// ═════════════════════════════════════════════════════════════════
// G3 · ERROR BOUNDARY BANNER
// ═════════════════════════════════════════════════════════════════
//
// Two surface kinds:
//   - Recoverable: role=alert + soft tone + retry action
//   - Fatal:       role=alert + err tone + reload action
//
// Inline tone (1px ring + soft tinted bg) — never neon.

function ErrorRecoverable({
  title = 'Cascade failed at provider · openai',
  detail = 'The request bounced through 2 fallback providers and timed out at 12.4s.',
  onRetry,
}) {
  return (
    <section role="alert" aria-labelledby="g3a-title" style={{
      display: 'flex', flexDirection: 'column', gap: '8px',
      padding: '12px 14px',
      background: 'var(--color-status-warn-soft, rgb(201 162 74 / .12))',
      border: '1px solid var(--color-status-warn-border, rgb(201 162 74 / .35))',
      borderLeft: '3px solid var(--color-status-warn-fg, #d9b764)',
      borderRadius: '3px',
      fontFamily: 'var(--font-mono)',
    }}>
      <div style={{display: 'flex', alignItems: 'center', gap: '8px'}}>
        <span aria-hidden="true" style={{
          color: 'var(--color-status-warn-fg, #d9b764)',
          fontSize: 'var(--fs-13)', fontWeight: 600,
        }}>⚠</span>
        <span id="g3a-title" style={{
          fontSize: 'var(--fs-12)',
          color: 'var(--color-status-warn-fg, #d9b764)',
          letterSpacing: 'var(--track-caps)', textTransform: 'uppercase',
          fontWeight: 600,
        }}>recoverable · cascade fallback</span>
        <button type="button" onClick={onRetry} style={{
          marginLeft: 'auto',
          padding: '3px 10px',
          background: 'transparent',
          color: 'var(--color-status-warn-fg, #d9b764)',
          border: '1px solid var(--color-status-warn-border, rgb(201 162 74 / .35))',
          fontFamily: 'var(--font-mono)', fontSize: 'var(--fs-10)',
          letterSpacing: 'var(--track-caps)', textTransform: 'uppercase',
          cursor: 'pointer',
        }}>↻ retry</button>
      </div>
      <div style={{
        fontSize: 'var(--fs-12)', color: 'var(--color-fg-primary)',
      }}>{title}</div>
      <div style={{
        fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)',
      }}>{detail}</div>
    </section>
  );
}

function ErrorFatal({
  title = 'Cockpit lost connection',
  detail = 'WebSocket closed at 14:32:18Z. Reconnect attempts: 3/3 exhausted.',
  onReload,
}) {
  return (
    <section role="alert" aria-labelledby="g3b-title" style={{
      display: 'flex', flexDirection: 'column', gap: '8px',
      padding: '12px 14px',
      background: 'var(--color-status-err-soft, rgb(196 106 90 / .12))',
      border: '1px solid var(--color-status-err-border, rgb(196 106 90 / .4))',
      borderLeft: '3px solid var(--color-status-err-fg, #d8806f)',
      borderRadius: '3px',
      fontFamily: 'var(--font-mono)',
    }}>
      <div style={{display: 'flex', alignItems: 'center', gap: '8px'}}>
        <span aria-hidden="true" style={{
          color: 'var(--color-status-err-fg, #d8806f)',
          fontSize: 'var(--fs-13)', fontWeight: 600,
        }}>✕</span>
        <span id="g3b-title" style={{
          fontSize: 'var(--fs-12)',
          color: 'var(--color-status-err-fg, #d8806f)',
          letterSpacing: 'var(--track-caps)', textTransform: 'uppercase',
          fontWeight: 600,
        }}>fatal · session lost</span>
        <button type="button" onClick={onReload} style={{
          marginLeft: 'auto',
          padding: '3px 10px',
          background: 'var(--color-status-err-fg, #d8806f)',
          color: 'var(--color-bg-page)',
          border: '1px solid var(--color-status-err-fg, #d8806f)',
          fontFamily: 'var(--font-mono)', fontSize: 'var(--fs-10)',
          letterSpacing: 'var(--track-caps)', textTransform: 'uppercase',
          cursor: 'pointer', fontWeight: 600,
        }}>⟳ reload session</button>
      </div>
      <div style={{
        fontSize: 'var(--fs-12)', color: 'var(--color-fg-primary)',
      }}>{title}</div>
      <div style={{
        fontSize: 'var(--fs-11)', color: 'var(--color-fg-muted)',
      }}>{detail}</div>
    </section>
  );
}

// ═════════════════════════════════════════════════════════════════
// G4 · PAGINATION
// ═════════════════════════════════════════════════════════════════
//
// Numeric: nav[aria-label] + role=list of buttons, current uses
// aria-current="page". Cursor: prev/next anchors with aria-disabled
// when at boundary.

function PaginationNumeric({ total = 18, initial = 4 }) {
  const [page, setPage] = useState(initial);
  // Compute window: always show first, last, current ±1, ellipses for gaps
  const pages = useMemo(() => {
    const out = [];
    const push = (v) => out.push(v);
    push(1);
    if (page > 3) push('…');
    for (let p = Math.max(2, page-1); p <= Math.min(total-1, page+1); p++) push(p);
    if (page < total-2) push('…');
    if (total > 1) push(total);
    return out;
  }, [page, total]);

  const btn = (active, disabled) => ({
    minWidth: '28px', height: '24px', padding: '0 8px',
    background: active
      ? 'var(--color-accent-fg)'
      : 'var(--color-bg-surface)',
    color: active
      ? 'var(--color-bg-page)'
      : disabled
        ? 'var(--color-fg-disabled)'
        : 'var(--color-fg-secondary)',
    border: `1px solid ${active
      ? 'var(--color-accent-fg)'
      : 'var(--color-border-default)'}`,
    fontFamily: 'var(--font-mono)', fontSize: 'var(--fs-11)',
    fontWeight: active ? 600 : 400,
    cursor: disabled ? 'default' : 'pointer',
    fontVariantNumeric: 'tabular-nums',
  });

  return (
    <nav aria-label="Pagination" style={{
      display: 'flex', alignItems: 'center', gap: '4px',
    }}>
      <button type="button"
              aria-label="Previous page"
              disabled={page === 1}
              onClick={() => setPage(p => Math.max(1, p-1))}
              style={btn(false, page === 1)}>←</button>
      {pages.map((p, i) => p === '…' ? (
        <span key={`g${i}`} aria-hidden="true" style={{
          color: 'var(--color-fg-disabled)', fontFamily: 'var(--font-mono)',
          fontSize: 'var(--fs-11)', padding: '0 4px',
        }}>…</span>
      ) : (
        <button key={p} type="button"
                aria-label={`Page ${p}${p === page ? ', current' : ''}`}
                aria-current={p === page ? 'page' : undefined}
                onClick={() => setPage(p)}
                style={btn(p === page, false)}>{p}</button>
      ))}
      <button type="button"
              aria-label="Next page"
              disabled={page === total}
              onClick={() => setPage(p => Math.min(total, p+1))}
              style={btn(false, page === total)}>→</button>
      <span aria-hidden="true" style={{
        marginLeft: '12px',
        fontFamily: 'var(--font-mono)', fontSize: 'var(--fs-10)',
        color: 'var(--color-fg-muted)', letterSpacing: 'var(--track-wide)',
      }}>page {page} / {total}</span>
    </nav>
  );
}

function PaginationCursor({
  cursor = 'evt-2604-a3f9',
  hasPrev = true,
  hasNext = true,
}) {
  return (
    <nav aria-label="Cursor pagination" style={{
      display: 'flex', alignItems: 'center', gap: '8px',
      padding: '8px 12px',
      background: 'var(--color-bg-surface)',
      border: '1px solid var(--color-border-default)',
      borderRadius: '3px',
      fontFamily: 'var(--font-mono)',
    }}>
      <button type="button"
              aria-label="Previous batch"
              aria-disabled={!hasPrev}
              disabled={!hasPrev}
              style={{
                padding: '3px 10px',
                background: 'transparent',
                color: hasPrev ? 'var(--color-fg-secondary)' : 'var(--color-fg-disabled)',
                border: '1px solid var(--color-border-default)',
                fontFamily: 'var(--font-mono)', fontSize: 'var(--fs-11)',
                cursor: hasPrev ? 'pointer' : 'default',
                letterSpacing: 'var(--track-caps)', textTransform: 'uppercase',
              }}>← older</button>
      <span style={{
        flex: 1, textAlign: 'center',
        fontSize: 'var(--fs-10)', color: 'var(--color-fg-muted)',
        letterSpacing: 'var(--track-wide)',
      }}>
        cursor · <span style={{color: 'var(--color-accent-fg)'}}>{cursor}</span>
      </span>
      <button type="button"
              aria-label="Next batch"
              aria-disabled={!hasNext}
              disabled={!hasNext}
              style={{
                padding: '3px 10px',
                background: 'transparent',
                color: hasNext ? 'var(--color-fg-secondary)' : 'var(--color-fg-disabled)',
                border: '1px solid var(--color-border-default)',
                fontFamily: 'var(--font-mono)', fontSize: 'var(--fs-11)',
                cursor: hasNext ? 'pointer' : 'default',
                letterSpacing: 'var(--track-caps)', textTransform: 'uppercase',
              }}>newer →</button>
    </nav>
  );
}

// ═════════════════════════════════════════════════════════════════
// G5 · BREADCRUMB
// ═════════════════════════════════════════════════════════════════
//
// nav[aria-label="Breadcrumb"] + ol > li. Last item carries
// aria-current="page". Separator is decorative (aria-hidden).
// The "with overflow" variant collapses middle segments behind a
// menu trigger when path > 3 levels.

const G_CRUMB_LI = {
  display: 'inline-flex', alignItems: 'center', gap: '6px',
};
const G_CRUMB_LINK = {
  color: 'var(--color-fg-muted)', textDecoration: 'none',
  padding: '2px 4px', borderRadius: '2px',
  fontFamily: 'var(--font-mono)', fontSize: 'var(--fs-11)',
};
const G_CRUMB_SEP = {
  color: 'var(--color-fg-disabled)', fontFamily: 'var(--font-mono)',
  fontSize: 'var(--fs-11)',
};

function BreadcrumbPath({
  path = ['cockpit', 'branch · main', 'keeper · sangsu', 'lifeline'],
}) {
  return (
    <nav aria-label="Breadcrumb">
      <ol style={{
        listStyle: 'none', display: 'flex', alignItems: 'center',
        gap: '6px', padding: 0, margin: 0,
      }}>
        {path.map((seg, i) => {
          const last = i === path.length - 1;
          return (
            <li key={i} style={G_CRUMB_LI}>
              {last ? (
                <span aria-current="page" style={{
                  ...G_CRUMB_LINK,
                  color: 'var(--color-accent-fg)',
                  fontWeight: 600,
                }}>{seg}</span>
              ) : (
                <a href="#" style={G_CRUMB_LINK}>{seg}</a>
              )}
              {!last && <span aria-hidden="true" style={G_CRUMB_SEP}>›</span>}
            </li>
          );
        })}
      </ol>
    </nav>
  );
}

function BreadcrumbWithOverflow({
  path = ['cockpit', 'branch · main', 'keeper · sangsu', 'tool · grpc.call', 'frame · 47', 'lifeline'],
}) {
  const [expanded, setExpanded] = useState(false);
  // Always show first + last; middle collapses unless expanded.
  const showAll = expanded || path.length <= 4;
  const head = path[0];
  const tail = path[path.length - 1];
  const middle = path.slice(1, -1);

  return (
    <nav aria-label="Breadcrumb">
      <ol style={{
        listStyle: 'none', display: 'flex', alignItems: 'center',
        gap: '6px', padding: 0, margin: 0,
      }}>
        <li style={G_CRUMB_LI}>
          <a href="#" style={G_CRUMB_LINK}>{head}</a>
          <span aria-hidden="true" style={G_CRUMB_SEP}>›</span>
        </li>
        {showAll ? middle.map((seg, i) => (
          <li key={i} style={G_CRUMB_LI}>
            <a href="#" style={G_CRUMB_LINK}>{seg}</a>
            <span aria-hidden="true" style={G_CRUMB_SEP}>›</span>
          </li>
        )) : (
          <li style={G_CRUMB_LI}>
            <button type="button"
                    aria-label={`Show ${middle.length} hidden levels`}
                    aria-expanded={expanded}
                    onClick={() => setExpanded(true)}
                    style={{
                      ...G_CRUMB_LINK,
                      background: 'var(--color-bg-surface)',
                      border: '1px solid var(--color-border-default)',
                      cursor: 'pointer',
                    }}>… <span aria-hidden="true">+{middle.length}</span></button>
            <span aria-hidden="true" style={G_CRUMB_SEP}>›</span>
          </li>
        )}
        <li style={G_CRUMB_LI}>
          <span aria-current="page" style={{
            ...G_CRUMB_LINK,
            color: 'var(--color-accent-fg)',
            fontWeight: 600,
          }}>{tail}</span>
        </li>
      </ol>
    </nav>
  );
}

Object.assign(window, {
  EmptyNoData, EmptySearchNoResults,
  SkeletonRows, SkeletonKpi, SkeletonPanel,
  ErrorRecoverable, ErrorFatal,
  PaginationNumeric, PaginationCursor,
  BreadcrumbPath, BreadcrumbWithOverflow,
});
