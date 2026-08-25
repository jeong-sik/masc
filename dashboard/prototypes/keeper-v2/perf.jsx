// @ds-adherence-ignore -- v2 skin performance layer: windowing, content-visibility, modern Web API hooks
/* ══════════════════════════════════════════════════════════════
   MASC v2 — Performance & platform layer (perf.jsx)

   The component library is composable but, by default, eager: every
   list renders every row. This layer adds the production-grade
   primitives the surfaces compose WITH — windowing, content-
   visibility, and thin wrappers over modern Web APIs — so the same
   atoms/molecules scale to tens of thousands of rows.

   Load AFTER React + babel, BEFORE the demo/app scripts.
   Exports onto window + window.KVP.

   Contents
     · useRaf                          frame-budget helper
     · useSize()                       ResizeObserver hook (windowing math)
     · VirtualList                     fixed/variable-row windowing
   ══════════════════════════════════════════════════════════════ */

const { useState: useP, useRef: useR, useEffect: useE, useCallback: useC, useMemo: useM, useLayoutEffect: useL } = React;

/* ── frame-budget: a ref that only updates on rAF, never faster ── */
function useRaf(callback) {
  const cb = useR(callback); cb.current = callback;
  const raf = useR(0);
  return useC((...args) => {
    if (raf.current) return;
    raf.current = requestAnimationFrame(() => { raf.current = 0; cb.current(...args); });
  }, []);
}

/* ── ResizeObserver — measure a node so windowing math is exact ── */
function useSize() {
  const ref = useR(null);
  const [size, setSize] = useP({ width: 0, height: 0 });
  useL(() => {
    const el = ref.current;
    if (!el) return;
    // synchronous first measurement — don't wait for RO's async first callback
    setSize({ width: Math.round(el.clientWidth), height: Math.round(el.clientHeight) });
    if (typeof ResizeObserver === 'undefined') return;
    const ro = new ResizeObserver(entries => {
      const cr = entries[0].contentRect;
      setSize({ width: Math.round(cr.width), height: Math.round(cr.height) });
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return [ref, size];
}

/* ════════════════════════════════════════════════════════════════
   VirtualList — true windowing. Renders only the visible slice
   (+overscan); total height is faked with a spacer so the scrollbar
   stays honest. Uses ResizeObserver for the viewport height and an
   rAF-throttled scroll handler.

   rowHeight may be:
     · a Number              — uniform fixed-height rows (fast path)
     · a fn(item,index)→px   — VARIABLE heights; offsets are memoised
                                as a prefix-sum and the first visible
                                row is found by binary search.
     props: items[], rowHeight, renderRow(item,index), overscan,
            height (optional fixed; else fills parent), className,
            onEndReached, getKey(item,index)
   ════════════════════════════════════════════════════════════════ */
function VirtualList({ items = [], rowHeight = 40, renderRow, overscan = 6, height, className, style, onEndReached, getKey }) {
  const [measureRef, size] = useSize();
  const scrollerRef = useR(null);
  const [scrollTop, setScrollTop] = useP(0);
  const viewportH = height || size.height || 360;
  const total = items.length;
  const variable = typeof rowHeight === 'function';

  // prefix-sum offsets for variable rows (offsets[i] = top of row i; last = totalH)
  const offsets = useM(() => {
    if (!variable) return null;
    const o = new Array(total + 1); o[0] = 0;
    for (let i = 0; i < total; i++) o[i + 1] = o[i] + (rowHeight(items[i], i) || 0);
    return o;
  }, [variable, total, items, rowHeight]);

  const totalH = variable ? offsets[total] : total * rowHeight;

  // first visible index
  let first, last;
  if (variable) {
    // binary search for the last offset <= scrollTop
    let lo = 0, hi = total;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (offsets[mid + 1] <= scrollTop) lo = mid + 1; else hi = mid; }
    first = Math.max(0, lo - overscan);
    last = first;
    const bottom = scrollTop + viewportH;
    while (last < total && offsets[last] < bottom) last++;
    last = Math.min(total, last + overscan);
  } else {
    first = Math.max(0, Math.floor(scrollTop / rowHeight) - overscan);
    last = Math.min(total, first + Math.ceil(viewportH / rowHeight) + overscan * 2);
  }

  const onScroll = useRaf(() => {
    const el = scrollerRef.current; if (!el) return;
    setScrollTop(el.scrollTop);
    if (onEndReached && el.scrollHeight - el.scrollTop - el.clientHeight < (variable ? 200 : rowHeight * 4)) onEndReached();
  });

  const slice = [];
  for (let i = first; i < last; i++) {
    const item = items[i];
    const top = variable ? offsets[i] : i * rowHeight;
    const h = variable ? offsets[i + 1] - offsets[i] : rowHeight;
    slice.push(
      React.createElement('div', {
        key: getKey ? getKey(item, i) : i,
        className: 'vl-row',
        style: { position: 'absolute', top, left: 0, right: 0, height: h },
      }, renderRow(item, i))
    );
  }

  const setRefs = (el) => { scrollerRef.current = el; measureRef.current = el; };
  return React.createElement('div', {
    ref: setRefs, onScroll, className: 'vl-scroller ' + (className || ''),
    style: { position: 'relative', overflowY: 'auto', height: height || '100%', ...style },
    'data-vl': '', 'data-vl-rendered': slice.length, 'data-vl-total': total,
  }, React.createElement('div', { className: 'vl-sizer', style: { height: totalH, position: 'relative' } }, slice));
}

const KVP = { useRaf, useSize, VirtualList };
Object.assign(window, KVP);
window.KVP = KVP;
