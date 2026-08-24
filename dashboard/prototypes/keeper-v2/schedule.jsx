/* MASC v2 — Scheduler surface: keeper-scheduled deferred automation.
   Grounded in lib/schedule/ — a keeper schedules future intent; operator
   approves before the runner fires at due time. Cards → list; row click →
   detail overlay (.turn-* shell). Operator actions (approve/reject/cancel)
   lift to App via onSchedule so the topbar chip + nav badge stay in sync. */
const { useState: useScS, useEffect: useScE, useMemo: useScMemo } = React;

function schKeeper(id) { return (window.KEEPERS || []).find(k => k.id === id); }
function schNow() { const d = new Date(); return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`; }

const SCH_TABS = [
  ['pending', '승인 대기', ['Pending_approval']],
  ['scheduled', '예약됨', ['Scheduled']],
  ['active', 'due · 실행', ['Due', 'Running']],
  ['done', '완료 · 종료', window.SCHED_TERMINAL],
  ['all', '전체', null],
];

function SchStatusPill({ status }) {
  const d = window.SCHED_STATUS[status] || { lbl: status, cls: 'dim', glyph: '·' };
  return <span className={`sch-pill ${d.cls}`}>{d.glyph} {d.lbl}</span>;
}

function SchCadenceTag({ cad, full }) {
  const d = window.SCHED_CADENCE[cad] || window.SCHED_CADENCE.oneshot;
  return <span className={`sch-cad ${d.cls}`} title={d.hint}>{d.glyph} {full ? d.lbl : d.short}</span>;
}

function SchCard({ s, onOpen, onAct, onOpenKeeper }) {
  const k = schKeeper(s.scheduled_by.id);
  const pl = window.SCHED_PAYLOAD[s.payload.kind] || { glyph: '◈', lbl: s.payload.kind };
  const [rejecting, setRejecting] = useScS(false);
  const [reason, setReason] = useScS('');
  const pending = s.status === 'Pending_approval';
  const cancellable = ['Pending_approval', 'Scheduled', 'Due'].includes(s.status);
  return (
    <article className={`sch-card st-${(window.SCHED_STATUS[s.status] || {}).cls || 'dim'}`}>
      <div className="sch-card-rail"></div>
      <div className="sch-card-main">
        <button className="sch-card-head" onClick={() => onOpen(s)}>
          <span className="sch-kind">{pl.glyph} {pl.lbl}</span>
          <span className="sch-id mono">{s.schedule_id}</span>
          <SchCadenceTag cad={window.schedCadence(s)} />
          
          <span className="sch-rec mono" title="recurrence">{'↻'} {window.schedRecurrenceText(s.recurrence)}</span>
          <span className="sch-head-sp"></span>
          <SchStatusPill status={s.status} />
        </button>
        <button className="sch-summary" onClick={() => onOpen(s)}>{s.summary}</button>
        <div className="sch-meta">
          <span className="sch-by">
            {k && <SigilBadge k={k} size={22} />}
            <button className="sch-klink" onClick={() => onOpenKeeper(s.scheduled_by.id)} title={`${s.scheduled_by.id} 대화 열기`}>{s.scheduled_by.id}</button>
            <span className="sch-actor-kind mono">예약</span>
          </span>
          <span className="sch-due" title="due_at"><span className="sub-k">due</span>{s.due_rel}</span>
          {s.approval_required && pending && <span className="sch-need mono" title="별도 사람(operator) 승인 필요">⊙ 승인 필요</span>}
          {s.grant && <span className="sch-grant mono" title={`승인: ${s.grant.by} · ${s.grant.at}`}>✓ {s.grant.by}</span>}
        </div>

        {(pending || cancellable) && (
          <div className="sch-actions">
            {pending && <button className="sch-act approve" onClick={() => onAct(s.schedule_id, 'approve')}>승인</button>}
            {pending && <button className="sch-act deny" onClick={() => setRejecting(v => !v)}>거부</button>}
            {cancellable && <button className="sch-act ghost" onClick={() => onAct(s.schedule_id, 'cancel')}>취소</button>}
            <button className="sch-act ghost" onClick={() => onOpen(s)}>상세 →</button>
          </div>
        )}
        {rejecting && (
          <div className="sch-reject">
            <input className="sch-reject-in mono" placeholder="거부 사유 (operator 결정)" value={reason}
              onChange={e => setReason(e.target.value)} onKeyDown={e => { if (e.key === 'Enter' && reason.trim()) { onAct(s.schedule_id, 'reject', reason.trim()); } }} autoFocus />
            <button className="sch-act deny" disabled={!reason.trim()} onClick={() => onAct(s.schedule_id, 'reject', reason.trim())}>거부 확정</button>
            <button className="sch-act ghost" onClick={() => { setRejecting(false); setReason(''); }}>취소</button>
          </div>
        )}
      </div>
    </article>
  );
}

// cadence summary — "어떤 종류의 예약이 있나"를 한눈에. 클릭 시 필터.
function SchCadenceSummary({ list, filter, onFilter }) {
  const counts = window.schedCadenceCounts(list);
  return (
    <div className="sch-cadsum">
      {['daily', 'interval', 'oneshot'].map(key => {
        const d = window.SCHED_CADENCE[key];
        const on = filter === key;
        return (
          <button key={key} className={`sch-cadsum-i ${d.cls} ${on ? 'on' : ''} ${filter && !on ? 'off' : ''}`}
            onClick={() => onFilter(on ? null : key)} title={d.hint}>
            <span className="sch-cadsum-gl">{d.glyph}</span>
            <span className="sch-cadsum-n mono">{counts[key]}</span>
            <span className="sch-cadsum-l">{d.lbl}</span>
          </button>
        );
      })}
    </div>
  );
}

// 상시 폴링(Interval) — 특정 시각이 아니라 고정 간격으로 계속 돎 → 캘린더 상단 별도 스트립.
function SchPollingStrip({ list, onOpen }) {
  const now = window.schedNow();
  const polls = list.filter(s => window.schedCadence(s) === 'interval' && !window.SCHED_TERMINAL.includes(s.status));
  return (
    <section className="sch-poll">
      <div className="sch-poll-h">
        <span className="sch-cad volt">{'↻'} 상시 폴링</span>
        <span className="sch-poll-sub">고정 간격 반복 — 특정 시각이 아니라 계속 돎</span>
      </div>
      {polls.length === 0
        ? <div className="sch-day-empty mono">활성 폴링 없음</div>
        : <div className="sch-poll-list">
            {polls.map(s => {
              const k = schKeeper(s.scheduled_by.id);
              const pl = window.SCHED_PAYLOAD[s.payload.kind] || { glyph: '◈', lbl: s.payload.kind };
              const st = window.SCHED_STATUS[s.status] || {};
              const next = window.schedNextTick(s.recurrence.interval_sec, now);
              const hh = String(next.getHours()).padStart(2, '0'), mm = String(next.getMinutes()).padStart(2, '0');
              return (
                <button key={s.schedule_id} className={`sch-poll-card st-${st.cls || 'dim'}`} onClick={() => onOpen(s)}>
                  <div className="sch-poll-top">
                    <span className="sch-poll-int mono">{'↻'} {window.schedRecurrenceText(s.recurrence)}</span>
                    <span className={`sch-pill ${st.cls}`}>{st.glyph} {st.lbl}</span>
                  </div>
                  <div className="sch-poll-title">{pl.glyph} {s.summary}</div>
                  <div className="sch-poll-foot">
                    {k && <SigilBadge k={k} size={18} />}
                    <span className="mono sch-poll-by">{s.scheduled_by.id}</span>
                    
                    <span className="sch-poll-next mono" title="다음 tick 예상 시각">다음 ~{hh}:{mm}</span>
                  </div>
                </button>
              );
            })}
          </div>}
    </section>
  );
}

const SCH_WD = ['일', '월', '화', '수', '목', '금', '토'];
// 캘린더(아젠다) — 하루씩 묶어 "누가·언제·뭘"을 시간순으로. daily+oneshot만; interval은 폴링 스트립.
function SchAgenda({ list, filter, onOpen }) {
  const cols = window.schedAgenda(list, 7);
  const now = window.schedNow();
  const fmt = (dt) => `${String(dt.getHours()).padStart(2, '0')}:${String(dt.getMinutes()).padStart(2, '0')}`;
  const rel = (o) => o === 0 ? '오늘' : o === 1 ? '내일' : `+${o}일`;
  const rows = cols.map(col => {
    const evs = filter ? col.events.filter(e => e.cad === filter) : col.events;
    return { col, evs };
  }).filter(r => r.evs.length || r.col.offset <= 1);
  const hasAny = rows.some(r => r.evs.length);
  return (
    <div className="sch-agenda">
      {!hasAny && <div className="sch-empty">다가오는 7일에 예정된 {filter ? (window.SCHED_CADENCE[filter] || {}).lbl + ' ' : ''}예약이 없습니다.</div>}
      {rows.map(({ col, evs }) => {
        const isToday = col.offset === 0;
        return (
          <div key={col.offset} className={`sch-day ${isToday ? 'today' : ''}`}>
            <div className="sch-day-h">
              <span className="sch-day-rel">{rel(col.offset)}</span>
              <span className="sch-day-date mono">{col.date.getMonth() + 1}/{col.date.getDate()} ({SCH_WD[col.date.getDay()]})</span>
              {isToday && <span className="sch-day-now mono">지금 {fmt(now)}</span>}
              <span className="sch-day-n mono">{evs.length ? `${evs.length}건` : ''}</span>
            </div>
            {evs.length === 0
              ? <div className="sch-day-empty mono">예정 없음</div>
              : <div className="sch-day-evs">
                  {evs.map((e, i) => {
                    const s = e.s; const k = schKeeper(s.scheduled_by.id);
                    const pl = window.SCHED_PAYLOAD[s.payload.kind] || { glyph: '◈', lbl: s.payload.kind };
                    const st = window.SCHED_STATUS[s.status] || {};
                    const pending = s.status === 'Pending_approval';
                    return (
                      <button key={s.schedule_id + '@' + i} className={`sch-ev st-${st.cls || 'dim'} ${pending ? 'pending' : ''}`} onClick={() => onOpen(s)}>
                        <span className="sch-ev-time mono">{fmt(e.at)}</span>
                        <SchCadenceTag cad={e.cad} />
                        <span className="sch-ev-body">
                          <span className="sch-ev-title">{pl.glyph} {s.summary}</span>
                          <span className="sch-ev-meta">
                            {k && <SigilBadge k={k} size={16} />}
                            <span className="mono sch-ev-by">{s.scheduled_by.id}</span>
                            
                            {pending && <span className="sch-ev-need mono">⊙ 승인 필요</span>}
                          </span>
                        </span>
                        <span className={`sch-pill ${st.cls}`}>{st.glyph} {st.lbl}</span>
                      </button>
                    );
                  })}
                </div>}
          </div>
        );
      })}
    </div>
  );
}

function SchDetail({ s, onClose, onAct, onOpenKeeper }) {
  useScE(() => {
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  const pl = window.SCHED_PAYLOAD[s.payload.kind] || { glyph: '◈', lbl: s.payload.kind };
  const pending = s.status === 'Pending_approval';
  const cancellable = ['Pending_approval', 'Scheduled', 'Due'].includes(s.status);
  const kv = (k, v) => (<div className="sch-kv"><span className="k">{k}</span><span className="v mono">{v}</span></div>);
  return (
    <div className="turn-overlay" onClick={onClose}>
      <div className="turn-drawer sch-drawer" onClick={(e) => e.stopPropagation()}>
        <div className="turn-hd">
          <h3>예약 상세</h3>
          <span className="tid">{s.schedule_id}</span>
          <span className="sch-hd-sp" style={{ marginLeft: 'auto' }}></span>
          <SchStatusPill status={s.status} />
          <button className="turn-close" onClick={onClose} title="닫기 (Esc)">{'\u2715'}</button>
        </div>
        <div className="turn-body">
          <div className="turn-sec">
            <h4>{pl.glyph} {pl.lbl}</h4>
            <p className="sch-d-summary">{s.summary}</p>
            <div className="sch-badges">
              
              <span className="sch-rec mono">{'↻'} {window.schedRecurrenceText(s.recurrence)}</span>
              <span className="sch-src mono">{s.source}</span>
            </div>
          </div>

          <div className="turn-sec">
            <h4>주체 · 직무분리</h4>
            <div className="sch-kvs">
              {kv('requested_by', `${s.requested_by.id} · ${s.requested_by.kind}`)}
              {kv('scheduled_by', `${s.scheduled_by.id} · ${s.scheduled_by.kind}`)}
              {kv('approval_required', String(s.approval_required))}
            </div>
            <div className="sch-sod">승인자(operator)는 요청자·예약자와 달라야 실행 grant가 발급됩니다 — 예약 주체는 keeper(<b>{s.scheduled_by.id}</b>), 승인 주체는 operator.</div>
          </div>

          <div className="turn-sec">
            <h4>타이밍</h4>
            <div className="sch-kvs">
              {kv('생성', s.at)}
              {kv('due', s.due_rel)}
              {kv('만료', s.expires_rel)}
              {kv('recurrence', s.recurrence.kind)}
            </div>
          </div>

          <div className="turn-sec">
            <h4>payload 봉투</h4>
            <pre className="turn-pre">{JSON.stringify({ kind: s.payload.kind, schema_version: s.payload.schema_version, body: s.payload.body }, null, 2)}</pre>
          </div>

          {(s.grant || s.rejected || s.cancelled) && (
            <div className="turn-sec">
              <h4>결정</h4>
              {s.grant && <div className="sch-decision ok">✓ 승인 — {s.grant.by} · {s.grant.at}</div>}
              {s.rejected && <div className="sch-decision bad">⊘ 거부 — {s.rejected.by} · {s.rejected.at}<div className="sch-reason">“{s.rejected.reason}”</div></div>}
              {s.cancelled && <div className="sch-decision dim">◌ 취소 — {s.cancelled.by} · {s.cancelled.at}</div>}
            </div>
          )}

          {s.exec && (
            <div className="turn-sec">
              <h4>최근 실행 기록</h4>
              <div className="sch-kvs">
                {kv('status', s.exec.status)}
                {s.exec.started && kv('시작', s.exec.started)}
                {s.exec.finished && kv('종료', s.exec.finished)}
              </div>
              {s.exec.detail && <div className="sch-exec ok">{s.exec.detail}</div>}
              {s.exec.error && <div className="sch-exec bad">{s.exec.error}</div>}
            </div>
          )}

          {(pending || cancellable) && (
            <div className="turn-sec sch-detail-actions">
              {pending && <button className="sch-act approve" onClick={() => { onAct(s.schedule_id, 'approve'); onClose(); }}>승인 — grant 발급</button>}
              {pending && <button className="sch-act deny" onClick={() => { const r = (window.prompt && window.prompt('거부 사유 (operator 결정)')) || ''; if (r.trim()) { onAct(s.schedule_id, 'reject', r.trim()); onClose(); } }}>거부</button>}
              {cancellable && <button className="sch-act ghost" onClick={() => { onAct(s.schedule_id, 'cancel'); onClose(); }}>취소</button>}
              <button className="sch-act ghost" onClick={() => onOpenKeeper(s.scheduled_by.id)}>{s.scheduled_by.id} 대화 →</button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

// 우측 운영 aside — schedule 그라운딩 (지금 상황 / 해야 할 일 / 최근 실행)
function SchAside({ list, sum, onOpen }) {
  const stMeta = (s) => window.SCHED_STATUS[s] || { cls: 'dim', lbl: s };
  const failed = list.filter(s => s.status === 'Failed');
  const pending = list.filter(s => s.status === 'Pending_approval');
  const due = list.filter(s => s.status === 'Due');
  const recent = list.filter(s => window.SCHED_TERMINAL.includes(s.status)).slice(0, 6);
  const needTotal = pending.length + due.length;
  return (
    <aside className="ov-aside">
      <section className="wka-sec">
        <div className="wka-h">지금 상황 <span className="n mono">{sum.total} 예약</span></div>
        <div className="wka-pulse">
          <span className="wka-pulse-i"><b className="mono">{sum.scheduled}</b> 예약됨</span>
          <span className="wka-pulse-i"><b className={`mono ${sum.due + sum.running ? 'volt' : ''}`}>{sum.due + sum.running}</b> due·실행</span>
          <span className="wka-pulse-i"><b className={`mono ${sum.pending ? 'warn' : ''}`}>{sum.pending}</b> 승인대기</span>
        </div>
        {failed.length === 0
          ? <div className="wka-calm mono">실패한 실행 없음</div>
          : <div className="wka-list">
              {failed.map(s => (
                <button key={s.schedule_id} className="wka-flag st-bad" onClick={() => onOpen(s)}>
                  <span className="wka-flag-tag bad">실패</span>
                  <span className="wka-flag-title">{s.summary}</span>
                  {s.exec && s.exec.error && <span className="wka-flag-reason">{s.exec.error}</span>}
                </button>
              ))}
            </div>}
      </section>

      <section className="wka-sec">
        <div className="wka-h">해야 할 일 <span className="n mono">{needTotal}</span></div>
        <div className="wka-list">
          {pending.map(s => (
            <button key={s.schedule_id} className="wka-todo approve" onClick={() => onOpen(s)}>
              <span className="wka-todo-k">승인</span>
              <span className="wka-todo-t">{s.summary}</span>
              <span className="wka-todo-m mono">{s.due_rel}</span>
            </button>
          ))}
          {due.map(s => (
            <button key={s.schedule_id} className="wka-todo verify" onClick={() => onOpen(s)}>
              <span className="wka-todo-k">due</span>
              <span className="wka-todo-t">{s.summary}</span>
              <span className="wka-todo-m mono">{window.schedRecurrenceText(s.recurrence)} · 실행 대기</span>
            </button>
          ))}
          {needTotal === 0 && <div className="wka-calm mono">승인·실행 대기 없음</div>}
        </div>
      </section>

      <section className="wka-sec">
        <div className="wka-h">최근 실행 <span className="n mono">{recent.length}</span></div>
        <div className="wka-list">
          {recent.length === 0
            ? <div className="wka-calm mono">종료된 예약 없음</div>
            : recent.map(s => { const m = stMeta(s.status); return (
                <button key={s.schedule_id} className="wka-done" onClick={() => onOpen(s)}>
                  <span className={`wka-done-mark ${m.cls}`}>{m.glyph}</span>
                  <span className="wka-done-t">{s.summary}</span>
                  <span className="wka-done-ns mono">{m.lbl}</span>
                </button>
              ); })}
        </div>
      </section>
    </aside>
  );
}

// keeper 자율 백그라운드 — 폴링 루프 + 비동기(deferred) 도구 호출. 예약 큐와
// 별개 origin. 행 클릭 → 해당 keeper 대화로.
function SchKeeperBg({ onOpenKeeper }) {
  const bg = window.KEEPER_BG || [];
  const polls = bg.filter(b => b.kind === 'poll');
  const asyncs = bg.filter(b => b.kind === 'async_tool');
  const row = (b) => {
    const k = schKeeper(b.keeper);
    const st = window.SCHED_BG_STATUS[b.status] || {};
    return (
      <button key={b.id} className={`sch-bg-row st-${st.cls || 'dim'}`} onClick={() => onOpenKeeper(b.keeper)} title={`${b.keeper} 대화 열기`}>
        <span className="sch-bg-when mono">{b.kind === 'poll' ? ('↻ ' + window.schedBgCadence(b.cadence_sec)) : ('◷ ' + b.issued)}</span>
        <span className="sch-bg-body">
          <span className="sch-bg-title">{b.label}</span>
          <span className="sch-bg-meta">
            {k && <SigilBadge k={k} size={16} />}
            <span className="mono sch-bg-by">{b.keeper}</span>
            
            {b.kind === 'poll' ? <span className="sch-bg-since mono">since {b.since}</span> : <span className="sch-bg-since mono">{b.eta}</span>}
          </span>
        </span>
        <span className={`sch-pill ${st.cls}`}>{st.glyph} {st.lbl}</span>
      </button>
    );
  };
  return (
    <section className="sch-bg">
      <div className="sch-bg-h">
        <h3>Keeper 자율 백그라운드</h3>
        <span className="sch-bg-sub">operator 승인 없이 keeper가 자기 turn에서 도는 폴링 · 비동기 도구 호출 — 예약 큐와 별개 origin</span>
      </div>
      <div className="sch-bg-grps">
        <div className="sch-bg-grp">
          <div className="sch-bg-grp-h"><span className="sch-cad volt">{'↻'} 폴링 루프</span><span className="sch-bg-grp-n mono">{polls.length}</span></div>
          <div className="sch-bg-list">{polls.map(row)}</div>
        </div>
        <div className="sch-bg-grp">
          <div className="sch-bg-grp-h"><span className="sch-cad info">{'⇢'} 비동기 도구 호출</span><span className="sch-bg-grp-n mono">{asyncs.length}</span></div>
          <div className="sch-bg-list">{asyncs.map(row)}</div>
        </div>
      </div>
    </section>
  );
}

function ScheduleSurface({ statusMap, onSchedule, onOpenKeeper, onNav }) {
  const [view, setView] = useScS('calendar');
  const [cadFilter, setCadFilter] = useScS(null);
  const [tab, setTab] = useScS('pending');
  const [detail, setDetail] = useScS(null);
  const [banner, setBanner] = useScS(null);
  const list = useScMemo(() => window.schedEffective(statusMap), [statusMap]);
  // wrap the operator action so the surface can show where the item went
  const act = (id, action, reason) => {
    onSchedule(id, action, reason);
    const map = { approve: { lbl: '예약됨', toTab: 'scheduled', tabLbl: '예약됨' }, reject: { lbl: '거부됨', toTab: 'done', tabLbl: '완료·종료' }, cancel: { lbl: '취소됨', toTab: 'done', tabLbl: '완료·종료' } };
    const m = map[action]; if (!m) return;
    setBanner({ id, action, ...m });
    clearTimeout(window.__schBannerT);
    window.__schBannerT = setTimeout(() => setBanner(null), 7000);
  };
  const sum = window.schedSummary(statusMap);
  const tabDef = SCH_TABS.find(t => t[0] === tab) || SCH_TABS[0];
  let filtered = tabDef[2] ? list.filter(s => tabDef[2].includes(s.status)) : list;
  if (cadFilter) filtered = filtered.filter(s => window.schedCadence(s) === cadFilter);
  // keep detail in sync with overlay updates
  const detailLive = detail ? (list.find(s => s.schedule_id === detail.schedule_id) || detail) : null;

  return (
    <main className="ov ov-flush ov-2col sch-surf" data-screen-label="예약">
      <div className="ov-scroll">
        <header className="ov-head">
          <div>
            <span className="ov-eyebrow">Schedule</span>
            <h1>예약 · 자동화 큐</h1>
            <p className="ov-sub">예약된 미래 작업 · due 전 승인</p>
          </div>
          <window.KV.WireBadge tone="demo" label="보기 · 수동" title="예약이 스스로 턴을 돌리지 않습니다 — 보기와 수동 승인만" />
        </header>

        <div className="sch-nodelivery">예약이 깨운 턴의 결과는 <b>자동으로 전달되지 않습니다</b> — keeper 가 발화 도구로 보낸 것만 채널에 나갑니다.</div>

        <section className="ov-kpis" style={{ gridTemplateColumns: 'repeat(4, 1fr)' }}>
          <div className="ov-kpi"><div className="ov-kpi-k">승인 대기</div><div className={`ov-kpi-v ${sum.pending ? 'warn' : 'ok'}`}>{sum.pending}</div></div>
          <div className="ov-kpi"><div className="ov-kpi-k">예약됨</div><div className="ov-kpi-v">{sum.scheduled}</div></div>
          <div className="ov-kpi"><div className="ov-kpi-k">due · 실행</div><div className={`ov-kpi-v ${sum.due ? 'warn' : ''}`}>{sum.due + sum.running}</div></div>
          <div className="ov-kpi"><div className="ov-kpi-k">총 예약</div><div className="ov-kpi-v volt">{sum.total}</div></div>
        </section>

        <div className="sch-viewbar">
          <div className="sch-viewseg">
            <button className={`sch-viewbtn ${view === 'calendar' ? 'on' : ''}`} onClick={() => setView('calendar')}>{'\u25A6'} 캘린더</button>
            <button className={`sch-viewbtn ${view === 'list' ? 'on' : ''}`} onClick={() => setView('list')}>{'\u2261'} 목록</button>
          </div>
          <SchCadenceSummary list={list} filter={cadFilter} onFilter={setCadFilter} />
        </div>

        {banner && (
          <div className={`sch-banner ${banner.action}`}>
            <span className="sch-banner-ico">{banner.action === 'approve' ? '✓' : banner.action === 'reject' ? '✕' : '◌'}</span>
            <span className="sch-banner-txt"><b className="mono">{banner.id}</b> {banner.lbl}{banner.action === 'approve' ? ' · grant 발급 — due 시각에 runner가 실행' : ''}</span>
            {banner.toTab && <button className="sch-banner-go" onClick={() => { setView('list'); setTab(banner.toTab); setBanner(null); }}>{banner.tabLbl} 탭 보기 →</button>}
            <button className="sch-banner-x" onClick={() => setBanner(null)} title="닫기">{'\u2715'}</button>
          </div>
        )}

        {view === 'calendar' ? (
          <React.Fragment>
            {cadFilter !== 'daily' && cadFilter !== 'oneshot' && <SchPollingStrip list={list} onOpen={setDetail} />}
            {cadFilter !== 'interval' && <SchAgenda list={list} filter={cadFilter} onOpen={setDetail} />}
            <SchKeeperBg onOpenKeeper={onOpenKeeper} />
          </React.Fragment>
        ) : (
          <React.Fragment>
            <div className="sch-tabs">
              {SCH_TABS.map(([id, lbl, statuses]) => {
                const n = statuses ? list.filter(s => statuses.includes(s.status)).length : list.length;
                return <button key={id} className={`sch-tab ${tab === id ? 'on' : ''}`} onClick={() => setTab(id)}>{lbl}<span className="sch-tab-n mono">{n}</span></button>;
              })}
            </div>
            {filtered.length === 0 ? (
              <div className="sch-empty">이 필터에 해당하는 예약이 없습니다.</div>
            ) : (
              <div className="sch-list">
                {filtered.map(s => <SchCard key={s.schedule_id} s={s} onOpen={setDetail} onAct={act} onOpenKeeper={onOpenKeeper} />)}
              </div>
            )}
          </React.Fragment>
        )}

        <section className="sch-signals">
          <div className="ov-card-h"><h3>wake signal 피드 · schedule_runner.tick</h3></div>
          <div className="sch-sig-list">
            {(window.SCHED_SIGNALS || []).map(sig => {
              const d = window.SCHED_SIGNAL_KIND[sig.kind] || { lbl: sig.kind, cls: 'dim' };
              return (
                <div key={sig.signal_id} className="sch-sig">
                  <span className="sch-sig-at mono">{sig.at}</span>
                  <span className={`sch-sig-kind ${d.cls}`}>{d.lbl}</span>
                  <button className="sch-sig-id mono" onClick={() => { const s = list.find(x => x.schedule_id === sig.schedule_id); if (s) setDetail(s); }}>{sig.schedule_id}</button>
                  
                </div>
              );
            })}
          </div>
        </section>
      </div>
      <SchAside list={list} sum={sum} onOpen={setDetail} />
      {detailLive && <SchDetail s={detailLive} onClose={() => setDetail(null)} onAct={act} onOpenKeeper={onOpenKeeper} />}
    </main>
  );
}

Object.assign(window, { ScheduleSurface });
