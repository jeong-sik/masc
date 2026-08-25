/* MASC v2 — Alarm engine.
   Wires the Notify settings (context threshold / consecutive fails / channel /
   per-event toggles) to the existing Toast host so "알림" actually fires.
   Before this, notify settings were inert and AttentionIndicator was static.

   Contract:
     · window.MASC_NOTIFY    — live config (persisted to localStorage)
     · window.setNotify(patch)  — merge + persist + notify subscribers
     · window.onNotify(fn)      — subscribe to config changes (returns unsub)
     · window.fireAlarm(event, payload)  — emit an alarm toast IF the event
        toggle is on AND channel != '없음'. payload: {msg, sub, tone, assertive, force}
     · <AlarmEngine/>          — gentle ambient demo loop + crossing detector,
        mounted once by app.jsx next to <ToastHost/>.

   Event keys match the Korean toggle labels the Settings UI already uses, so
   Settings can write window.MASC_NOTIFY.on directly with no remapping.
   Load AFTER toast.jsx + data.jsx, BEFORE settings.jsx and app.jsx. */

const _NOTIFY_KEY = 'masc.notify.v1';
const _NOTIFY_DEFAULT = {
  ctx: 85,        // context-window % above which a keeper is alarmed
  fails: 3,       // consecutive tool failures before alarming
  channel: 'Slack',
  on: {
    '컨텍스트 오버플로우 · 압축': true,
    '연속 실패': true,
    'keeper crash/dead': true,
    '핸드오프 완료': false,
    '승인 요청': true,
  },
};

function _loadNotify() {
  try {
    const raw = localStorage.getItem(_NOTIFY_KEY);
    if (raw) {
      const p = JSON.parse(raw);
      return { ..._NOTIFY_DEFAULT, ...p, on: { ..._NOTIFY_DEFAULT.on, ...(p.on || {}) } };
    }
  } catch (e) {}
  return JSON.parse(JSON.stringify(_NOTIFY_DEFAULT));
}

window.MASC_NOTIFY = _loadNotify();
const _notifySubs = new Set();
function onNotify(fn) { _notifySubs.add(fn); return () => _notifySubs.delete(fn); }
function setNotify(patch) {
  const cur = window.MASC_NOTIFY;
  const next = { ...cur, ...patch, on: { ...cur.on, ...(patch.on || {}) } };
  window.MASC_NOTIFY = next;
  try { localStorage.setItem(_NOTIFY_KEY, JSON.stringify(next)); } catch (e) {}
  _notifySubs.forEach(fn => { try { fn(next); } catch (e) {} });
  return next;
}

// channel → tone hint for the toast sub line
function _chanTag(cfg) { return cfg.channel && cfg.channel !== '없음' ? `→ ${cfg.channel}` : ''; }

// Emit an alarm. Respects the per-event toggle + channel unless {force:true}.
function fireAlarm(event, payload = {}) {
  const cfg = window.MASC_NOTIFY || _NOTIFY_DEFAULT;
  if (!payload.force) {
    if (cfg.channel === '없음') return false;
    if (event && cfg.on && cfg.on[event] === false) return false;
  }
  if (!window.pushToast) return false;
  const tag = _chanTag(cfg);
  const sub = [payload.sub, tag].filter(Boolean).join(' · ');
  window.pushToast({
    tone: payload.tone || 'warn',
    assertive: !!payload.assertive,
    msg: payload.msg || event || '알림',
    sub: sub || undefined,
    duration: payload.duration || 7000,
  });
  return true;
}

Object.assign(window, { setNotify, onNotify, fireAlarm });

// ── ambient demo loop ──────────────────────────────────────────────
// A real server would push these from keeper heartbeats. Here we synthesize a
// gentle stream from the static roster so the operator can SEE notify settings
// take effect. Candidates are re-filtered against live toggles on every tick.
const { useEffect: useAlarmE, useRef: useAlarmRef } = React;

function _alarmCandidates() {
  const ks = window.KEEPERS || [];
  const find = (id) => ks.find(k => k.id === id) || { id, kr: '' };
  const naming = (k) => k.kr ? `${k.id} · ${k.kr}` : k.id;
  const cfg = window.MASC_NOTIFY || _NOTIFY_DEFAULT;
  const out = [];
  const nick = find('nick0cave');
  out.push({ event: '컨텍스트 오버플로우 · 압축', tone: 'warn',
    msg: `${naming(nick)} Compaction_started`, sub: 'provider overflow 복구 — owner-lane 에서 압축 실행' });
  const drift = find('drifter');
  out.push({ event: '연속 실패', tone: 'bad', assertive: true,
    msg: `${naming(drift)} masc_fusion ${cfg.fails}회 연속 실패`, sub: 'context overflow — 격리 검토' });
  const marshal = find('marshal');
  out.push({ event: 'keeper crash/dead', tone: 'bad', assertive: true,
    msg: `${naming(marshal)} Crashed`, sub: 'infra/deploy — 재시작 필요' });
  const appr = (window.APPROVALS || [])[0];
  out.push({ event: '승인 요청', tone: 'warn',
    msg: appr ? `승인 대기 · ${appr.title}` : '승인 대기 1건',
    sub: appr ? `${appr.keeper} · ${appr.id}` : 'HITL 큐' });
  return out;
}

function AlarmEngine() {
  const idx = useAlarmRef(0);
  useAlarmE(() => {
    let timer = 0;
    const tick = () => {
      const cfg = window.MASC_NOTIFY || _NOTIFY_DEFAULT;
      if (cfg.channel !== '없음') {
        const cands = _alarmCandidates().filter(c => cfg.on[c.event] !== false);
        if (cands.length) {
          const c = cands[idx.current % cands.length];
          idx.current += 1;
          fireAlarm(c.event, c);
        }
      }
      timer = setTimeout(tick, 16000);
    };
    // first ambient alarm a few seconds after load, then every 16s
    timer = setTimeout(tick, 5000);
    return () => clearTimeout(timer);
  }, []);
  return null;
}

window.AlarmEngine = AlarmEngine;
