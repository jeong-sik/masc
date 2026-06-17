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
     · useRaf / useThrottledRef       frame-budget helpers
     · useInView(opts)                IntersectionObserver hook
     · useSize()                      ResizeObserver hook
     · useViewTransition()            View Transitions API (graceful)
     · VirtualList                    fixed-row windowing (the real one)
     · CVList                         content-visibility cheap virtualization
     · Dialog                         native <dialog> modal w/ focus + Esc
     · FpsMeter                       live scroll FPS probe (for demos)
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

/* ── IntersectionObserver — lazy mount / infinite scroll sentinels ── */
function useInView({ rootMargin = '200px', threshold = 0, once = false } = {}) {
  const ref = useR(null);
  const [inView, setInView] = useP(false);
  useE(() => {
    const el = ref.current;
    if (!el || typeof IntersectionObserver === 'undefined') { setInView(true); return; }
    const io = new IntersectionObserver(([e]) => {
      setInView(e.isIntersecting);
      if (e.isIntersecting && once) io.disconnect();
    }, { rootMargin, threshold });
    io.observe(el);
    return () => io.disconnect();
  }, [rootMargin, threshold, once]);
  return [ref, inView];
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

/* ── View Transitions API — animate DOM swaps where supported ── */
function useViewTransition() {
  return useC((mutate) => {
    if (document.startViewTransition) {
      try { return document.startViewTransition(() => mutate()); } catch (_) { mutate(); }
    } else { mutate(); }
  }, []);
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

/* ════════════════════════════════════════════════════════════════
   CVList — cheap "virtualization" via CSS content-visibility.
   The browser skips layout+paint for off-screen rows while keeping
   them in the DOM (so Ctrl-F, a11y tree, and variable heights still
   work). Zero JS scroll math. Great default for medium lists and
   variable row heights where true windowing is overkill.
     props: items[], estRow (intrinsic size hint), renderRow, getKey
   ════════════════════════════════════════════════════════════════ */
function CVList({ items = [], estRow = 40, renderRow, getKey, className, style }) {
  return React.createElement('div', { className: 'cv-list ' + (className || ''), style, 'data-cv': '', 'data-cv-total': items.length },
    items.map((item, i) => React.createElement('div', {
      key: getKey ? getKey(item, i) : i,
      className: 'cv-row',
      style: { contentVisibility: 'auto', containIntrinsicSize: `auto ${estRow}px` },
    }, renderRow(item, i))));
}

/* ════════════════════════════════════════════════════════════════
   Dialog — native <dialog> element. Real top-layer, ::backdrop,
   focus-trap and Esc-to-close come free from the platform; we just
   sync the open prop and forward the close event.
   ════════════════════════════════════════════════════════════════ */
function Dialog({ open, onClose, labelledBy, className, style, children }) {
  const ref = useR(null);
  useE(() => {
    const d = ref.current; if (!d) return;
    if (open && !d.open) { try { d.showModal(); } catch (_) {} }
    else if (!open && d.open) { d.close(); }
  }, [open]);
  useE(() => {
    const d = ref.current; if (!d) return;
    const onCancel = (e) => { e.preventDefault(); onClose && onClose(); };
    const onClick = (e) => { if (e.target === d) onClose && onClose(); }; // backdrop click
    d.addEventListener('cancel', onCancel);
    d.addEventListener('click', onClick);
    return () => { d.removeEventListener('cancel', onCancel); d.removeEventListener('click', onClick); };
  }, [onClose]);
  return React.createElement('dialog', { ref, className: 'v2-dialog ' + (className || ''), 'aria-labelledby': labelledBy, style }, children);
}

/* ════════════════════════════════════════════════════════════════
   FpsMeter — samples rAF deltas, shows a live FPS + min over a window.
   For demos only: pass `running` to gate sampling.
   ════════════════════════════════════════════════════════════════ */
function FpsMeter({ running = true, label }) {
  const [fps, setFps] = useP(60);
  const [low, setLow] = useP(60);
  useE(() => {
    if (!running) return;
    let raf, last = performance.now(), acc = 0, n = 0, minF = 999;
    const tick = (t) => {
      const dt = t - last; last = t;
      const f = 1000 / dt; acc += f; n++;
      if (f < minF) minF = f;
      if (n >= 20) { setFps(Math.round(acc / n)); setLow(Math.round(minF)); acc = 0; n = 0; minF = 999; }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [running]);
  const tone = fps >= 55 ? 'ok' : fps >= 30 ? 'warn' : 'bad';
  return React.createElement('span', { className: 'fps-meter ' + tone },
    React.createElement('span', { className: 'fps-dot' }),
    label ? React.createElement('span', { className: 'fps-label' }, label) : null,
    React.createElement('b', null, fps), ' fps',
    React.createElement('span', { className: 'fps-low' }, ' · min ', low));
}

const KVP = {
  useRaf, useInView, useSize, useViewTransition,
  VirtualList, CVList, Dialog, FpsMeter,
};
Object.assign(window, KVP);
window.KVP = KVP;
