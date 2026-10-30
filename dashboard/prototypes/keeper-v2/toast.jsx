/* MASC v2 — global Toast + undo (mirrors dashboard Toast RFC-0007 +
   TaskQueue.announceStateChange: text + assertive). Ephemeral confirmations
   for consequential operator actions (approve/deny/claim/lifecycle/compact),
   each optionally carrying an undo. Module-level store so any surface can
   call window.pushToast(...) without prop threading. Load BEFORE app.jsx;
   app.jsx renders <ToastHost/>. */
const { useState: useToastS, useEffect: useToastE } = React;

const _toastSubs = new Set();
let _toasts = [];
let _toastSeq = 0;
function _emitToasts() { _toastSubs.forEach(fn => fn(_toasts)); }

function pushToast(opts) {
  const id = ++_toastSeq;
  const t = { id, tone: 'info', duration: 6000, ...opts };
  _toasts = [..._toasts, t];
  _emitToasts();
  if (t.duration) t._timer = setTimeout(() => dismissToast(id), t.duration);
  return id;
}
function dismissToast(id) {
  const t = _toasts.find(x => x.id === id);
  if (t && t._timer) clearTimeout(t._timer);
  _toasts = _toasts.filter(x => x.id !== id);
  _emitToasts();
}

const TOAST_GLYPH = { ok: '\u2713', warn: '\u26A0', bad: '\u2715', info: '\u25C8' };

function ToastHost() {
  const [list, setList] = useToastS(_toasts);
  useToastE(() => {
    const fn = (x) => setList(x);
    _toastSubs.add(fn);
    setList(_toasts);
    return () => _toastSubs.delete(fn);
  }, []);
  if (!list.length) return null;
  return (
    <div className="toast-host" aria-live="polite">
      {list.map(t => (
        <div key={t.id} className={`toast tone-${t.tone}`} role={t.assertive ? 'alert' : 'status'}>
          <span className="toast-glyph">{TOAST_GLYPH[t.tone] || TOAST_GLYPH.info}</span>
          <div className="toast-body">
            <span className="toast-msg">{t.msg}</span>
            {t.sub && <span className="toast-sub">{t.sub}</span>}
          </div>
          {t.undo && (
            <button className="toast-undo" onClick={() => { t.undo(); dismissToast(t.id); }}>되돌리기</button>
          )}
          <button className="toast-x" onClick={() => dismissToast(t.id)} aria-label="닫기">{'\u2715'}</button>
        </div>
      ))}
    </div>
  );
}

Object.assign(window, { pushToast, dismissToast, ToastHost });
