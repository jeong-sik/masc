/* MASC v2 — Work surface: Goal store → Tasks, grounded in the real model
   (dashboard src/types/core.ts Goal + Task, RFC-0009 task queue).
   · Goals shown as a Goal→Task tree, ordered by priority (RFC-0294: horizon 폐기).
   · Goal carries phase/status + completion-approval (verifier_policy).
   · Tasks use the real 6-state lifecycle todo→claimed→in_progress→
     awaiting_verification→done|cancelled, an assignee keeper, and a
     completion CONTRACT (gate evidence: satisfied/missing/failed) that
     must pass before done — the signature MASC mechanism.
   · Unclaimed todo tasks form a claimable BACKLOG (keeper_task_claim). */
const { useState: useWkState, useEffect: useWkEffect } = React;

// 칸반 컬럼 — 실제 6-state 생명주기 (cancelled 제외)
const STATUS_COLS = [
  ['todo',                  '백로그', 'todo'],
  ['claimed',               '클레임', 'claimed'],
  ['in_progress',           '진행',   'wip'],
  ['awaiting_verification', '검증',   'verify'],
  ['done',                  '완료',   'done'],
];

function wkKeeper(id) { return (window.KEEPERS || []).find(k => k.id === id); }
function taskMeta(s) { return (window.TASK_STATUS || {})[s] || { lbl: s, cls: 'todo' }; }
function goalMeta(s) { return (window.GOAL_STATUS || {})[s] || { lbl: s, cls: 'ok' }; }

// progress = done / (total − cancelled)
function GoalProgress({ tasks }) {
  const live = tasks.filter(t => t.status !== 'cancelled');
  const n = live.length || 1;
  let done = 0, verify = 0, wip = 0;
  live.forEach(t => {
    if (t.status === 'done') done++;
    else if (t.status === 'awaiting_verification') verify++;
    else if (t.status === 'in_progress' || t.status === 'claimed') wip++;
  });
  const pct = (x) => (x / n) * 100;
  return (
    <div className="wk-prog">
      <span className="wk-seg done" style={{ width: pct(done) + '%' }}></span>
      <span className="wk-seg verify" style={{ width: pct(verify) + '%' }}></span>
      <span className="wk-seg wip" style={{ width: pct(wip) + '%' }}></span>
    </div>
  );
}

// completion contract gate — evidence checklist (the signature MASC mechanism)
function TaskGate({ gate }) {
  const GO = window.GATE_OUTCOME || {};
  const open = gate.filter(g => g.outcome !== 'satisfied').length;
  return (
    <div className="wk-gate">
      <div className="wk-gate-h">완료 계약 · 게이트 증거 {open > 0 ? <span className="wk-gate-open">{open} 미충족</span> : <span className="wk-gate-ok">전부 충족</span>}</div>
      {gate.map((g, i) => (
        <div key={i} className={`wk-gate-row ${g.outcome}`}>
          <span className="wk-gate-mark">{g.outcome === 'satisfied' ? '✓' : g.outcome === 'failed' ? '✕' : '○'}</span>
          <span className="wk-gate-ev">{g.evidence}</span>
          <span className="wk-gate-out">{GO[g.outcome] || g.outcome}</span>
        </div>
      ))}
    </div>
  );
}

const LINEAGE_EV = {
  created:   { lbl: '생성',      glyph: '\u25CB', cls: 'dim' },
  claimed:   { lbl: '클레임',    glyph: '\u25C9', cls: 'claimed' },
  started:   { lbl: '착수',      glyph: '\u25B6', cls: 'wip' },
  handoff:   { lbl: '핸드오프',  glyph: '\u21C4', cls: 'volt' },
  submitted: { lbl: '검증 제출', glyph: '\u25EC', cls: 'verify' },
  approved:  { lbl: '검증 승인', glyph: '\u2713', cls: 'done' },
  rejected:  { lbl: '반려',      glyph: '\u2715', cls: 'bad' },
  blocked:   { lbl: '차단',      glyph: '\u26A0', cls: 'bad' },
  done:      { lbl: '완료',      glyph: '\u2713', cls: 'done' },
  cancelled: { lbl: '취소',      glyph: '\u25CC', cls: 'dim' },
};

// task.lineage 가 없으면 현재 상태에서 최소 흐름을 합성 (assignee 기준)
function taskLineage(t) {
  if (t.lineage) return t.lineage;
  const a = t.assignee || '미배정';
  const ev = [{ actor: a, ev: 'created' }];
  if (t.status === 'claimed') ev.push({ actor: a, ev: 'claimed' });
  else if (t.status === 'in_progress') ev.push({ actor: a, ev: 'claimed' }, { actor: a, ev: 'started' });
  else if (t.status === 'awaiting_verification') ev.push({ actor: a, ev: 'started' }, { actor: a, ev: 'submitted' });
  else if (t.status === 'done') ev.push({ actor: a, ev: 'done' });
  else if (t.status === 'cancelled') ev.push({ actor: a, ev: 'cancelled' });
  return ev;
}
function isKeeperId(id) { return !!(window.KEEPERS || []).find(k => k.id === id); }

function LinActor({ id, onOpenKeeper, cls }) {
  if (isKeeperId(id)) return <button className={`wk-lin-actor ${cls || ''}`} onClick={() => onOpenKeeper && onOpenKeeper(id)} title={`${id} 대화 열기`}>{id}</button>;
  return <span className={`wk-lin-actor none ${cls || ''}`}>{id}</span>;
}

// 활동 흐름 — 누가 → 누구에게 (created→claim→start→handoff→submit→done)
function TaskLineage({ events, assignee, onOpenKeeper }) {
  // 소유권 체인: 첫 행위자 + 모든 handoff 대상, 중복 제거
  const chain = [];
  events.forEach(e => { if (e.actor && !chain.includes(e.actor)) chain.push(e.actor); if (e.to && !chain.includes(e.to)) chain.push(e.to); });
  return (
    <div className="wk-lineage">
      <div className="wk-lin-h">
        <span className="wk-lin-h-lbl">활동 흐름</span>
        <span className="wk-lin-chain">
          {chain.map((id, i) => (
            <React.Fragment key={id}>
              {i > 0 && <span className="wk-lin-chain-arr">{'\u2192'}</span>}
              <LinActor id={id} onOpenKeeper={onOpenKeeper} cls={id === assignee ? 'cur' : ''} />
            </React.Fragment>
          ))}
        </span>
      </div>
      <div className="wk-lin-track">
        {events.map((e, i) => {
          const m = LINEAGE_EV[e.ev] || { lbl: e.ev, glyph: '\u00B7', cls: 'dim' };
          return (
            <div key={i} className={`wk-lin-row ${m.cls}`}>
              <span className="wk-lin-at mono">{e.at || ''}</span>
              <span className="wk-lin-rail"><span className={`wk-lin-dot ${m.cls}`}></span></span>
              <span className="wk-lin-body">
                <span className="wk-lin-line">
                  <span className={`wk-lin-ev ${m.cls}`}>{m.glyph} {m.lbl}</span>
                  <LinActor id={e.actor} onOpenKeeper={onOpenKeeper} />
                  {e.to && <React.Fragment><span className="wk-lin-arr">{'\u2192'}</span><LinActor id={e.to} onOpenKeeper={onOpenKeeper} cls="to" /></React.Fragment>}
                </span>
                {e.note && <span className="wk-lin-note">{e.note}</span>}
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function TaskRow({ t, onOpenKeeper, onClaim, onRequestVerify }) {
  const k = wkKeeper(t.assignee);
  const st = taskMeta(t.status);
  const [open, setOpen] = useWkState(false);
  const lineage = taskLineage(t);
  return (
    <div className={`wk-task ${st.cls} ${open ? 'open' : ''}`}>
      <div className="wk-task-main" onClick={() => setOpen(o => !o)} style={{ cursor: 'pointer' }}>
        <span className={`wk-task-dot ${st.cls}`}></span>
        <span className="wk-task-id mono">{t.id}</span>
        <span className="wk-task-title">{t.title}
          {t.predecessor_task_id && <span className="wk-rerun" title={`RFC-0323 재실행 · predecessor_task_id = ${t.predecessor_task_id}`}>↻ 재실행 ← {t.predecessor_task_id}</span>}
          {t.blocker && <span className="wk-task-block">{'\u26A0'} {t.blocker}</span>}
          <span className="wk-task-chev">{open ? '\u25BE' : '\u25B8'}</span>
        </span>
        <span className="wk-spacer"></span>
        <span className={`wk-task-state ${st.cls}`}>{st.lbl}</span>
        {k
          ? <button className="wk-task-kp" onClick={(e) => { e.stopPropagation(); onOpenKeeper(k.id); }} title={`${k.id} 대화 열기`}><SigilBadge k={k} size={18} /><span className="mono">{k.id}</span></button>
          : t.status === 'todo'
            ? <button className="wk-task-claim" onClick={(e) => { e.stopPropagation(); onClaim(t.id); }} title="operator가 keeper에게 배정 (keeper는 스스로 claim)">{'\uFF0B'} 배정</button>
            : <span className="wk-task-kp none mono">미배정</span>}
      </div>
      {open && (
        <div className="wk-task-detail">
          {t._rejected && <div className="wk-rejected">{'\u2715'} 검증 반려됨 · {t._rejected}</div>}
          <TaskLineage events={lineage} assignee={t.assignee} onOpenKeeper={onOpenKeeper} />
          {t.gate && <TaskGate gate={t.gate} />}
          {(t.status === 'in_progress' || t.status === 'claimed') && onRequestVerify && (
            <button className="wk-reqverify" onClick={(e) => { e.stopPropagation(); onRequestVerify(t.id); }} title="이 task 를 검증 대기 큐로 제출">{'\u25F7'} 검증 요청 · awaiting_verification 으로 제출</button>
          )}
          {t.handoff && (
            <div className="wk-handoff">
              <div className="wk-handoff-h">핸드오프 컨텍스트</div>
              <div className="wk-handoff-row"><span className="k">요약</span>{t.handoff.summary}</div>
              {t.handoff.next_step && <div className="wk-handoff-row"><span className="k">다음</span>{t.handoff.next_step}</div>}
              {t.handoff.failure_mode && <div className="wk-handoff-row"><span className="k">실패</span>{t.handoff.failure_mode}</div>}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// 목표에 task 추가 (inline) — operator/keeper 모두 신규 task 생성 가능
function AddTaskInline({ goalId, onAdd }) {
  const [openA, setOpenA] = useWkState(false);
  const [title, setTitle] = useWkState('');
  const submit = () => { if (!title.trim()) return; onAdd(goalId, { title: title.trim() }); setTitle(''); setOpenA(false); };
  if (!openA) return <button className="wk-addtask" onClick={() => setOpenA(true)}>{'\uFF0B'} task 추가</button>;
  return (
    <div className="wk-addtask-row">
      <input className="wk-addtask-in" autoFocus value={title} placeholder="새 task 제목… (Enter 추가 · todo·미배정으로 생성)"
        onChange={e => setTitle(e.target.value)} onKeyDown={e => { if (e.key === 'Enter') submit(); if (e.key === 'Escape') { setOpenA(false); setTitle(''); } }} />
      <button className="wk-task-claim" onClick={submit} disabled={!title.trim()}>추가</button>
      <button className="sch-act ghost" onClick={() => { setOpenA(false); setTitle(''); }}>취소</button>
    </div>
  );
}

function GoalCard({ g, open, onToggle, onOpenKeeper, onClaim, onAddTask, onRequestVerify }) {
  const lead = wkKeeper(g.lead);
  const live = g.tasks.filter(t => t.status !== 'cancelled');
  const done = live.filter(t => t.status === 'done').length;
  const gm = goalMeta(g.status);
  return (
    <div className={`wk-goal ${open ? 'open' : ''} st-${gm.cls}`} data-goal-id={g.id}>
      <button className="wk-goal-h" onClick={onToggle}>
        <span className="wk-caret">{open ? '\u25BE' : '\u25B8'}</span>
        <span className="wk-prio mono" title={`우선순위 ${g.priority}`}>P{g.priority}</span>
        <span className={`wk-gstatus ${gm.cls}`}>{gm.lbl}</span>
        <span className="wk-goal-title">{g.title}</span>
        <span className="wk-spacer"></span>
        {g.require_completion_approval && <span className="wk-approval" title={`완료 승인 필요 · 검증자 ${(g.verifier || []).join(', ')}`}>{'\u2713'} 완료 승인</span>}
        {g.due_date && <span className="wk-due mono">{g.due_date}</span>}
        {lead && <span className="wk-lead" title={`리드 · ${lead.id}`}><SigilBadge k={lead} size={22} /></span>}
      </button>
      <div className="wk-goal-sub">
        <GoalProgress tasks={g.tasks} />
        <span className="wk-prog-lbl mono">{done}/{live.length}</span>
        <span className="wk-goal-phase mono" title="goal phase">{g.phase}</span>
        {(g.metric || g.target) && <span className="wk-metric mono" title="목표 지표">{g.metric || g.target}</span>}
      </div>
      {open && (
        <div className="wk-tasks">
          {g.note && <div className="wk-note">{g.note}</div>}
          {g.require_completion_approval && (
            <div className="wk-verifier">완료 승인 정책 · 검증자 {(g.verifier || []).map(v => <span key={v} className="wk-vchip mono">{v}</span>)}</div>
          )}
          {g.tasks.map(t => <TaskRow key={t.id} t={t} onOpenKeeper={onOpenKeeper} onClaim={onClaim} onRequestVerify={onRequestVerify} />)}
          <AddTaskInline goalId={g.id} onAdd={onAddTask} />
        </div>
      )}
    </div>
  );
}

// 우측 운영 패널 — 새 데이터 없이 goal·task 상태에서 도출: HUD + 지금 상황 / 해야 할 일 / 최근 한 일.
// 접기(Chat 열 때 공간 확보) + 좌측 모서리 드래그로 폭 조절(persisted).
function WorkAside({ flagged, approvals, verifyTasks, blockers, backlog, recent, counts, onJump, onOpenKeeper }) {
  const needTotal = approvals.length + verifyTasks.length + blockers.length + backlog.length;
  const [collapsed, setCollapsed] = useWkState(() => { try { return localStorage.getItem('v2.wkAsideCollapsed') === '1'; } catch (e) { return false; } });
  const [w, setW] = window.usePersistentW('v2.wkAsideW', 360);
  const setCol = (v) => { setCollapsed(v); try { localStorage.setItem('v2.wkAsideCollapsed', v ? '1' : '0'); } catch (e) {} };
  const startResize = (e) => {
    e.preventDefault();
    const startX = e.clientX, startW = w;
    document.body.classList.add('rail-resizing');
    const move = (ev) => setW(Math.max(312, Math.min(520, startW - (ev.clientX - startX))));
    const up = () => { document.body.classList.remove('rail-resizing'); window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up); };
    window.addEventListener('pointermove', move); window.addEventListener('pointerup', up);
  };

  if (collapsed) {
    return (
      <aside className="ov-aside wka collapsed" onClick={() => setCol(false)} role="button" tabIndex={0} title="클릭하여 운영 상태 패널 펼치기" onKeyDown={(e) => { if (e.key === 'Enter') setCol(false); }}>
        <button className="wka-railbtn" onClick={(e) => { e.stopPropagation(); setCol(false); }} title="운영 상태 패널 펼치기">{'\u00AB'}</button>
        <div className="wka-rail-stats">
          <div className="wka-rail-stat"><b className="mono">{counts.wip}</b><span>진행</span></div>
          <div className={`wka-rail-stat ${counts.verify ? 'volt' : ''}`}><b className="mono">{counts.verify}</b><span>검증</span></div>
          <div className={`wka-rail-stat ${needTotal ? 'volt' : ''}`}><b className="mono">{needTotal}</b><span>할일</span></div>
          <div className={`wka-rail-stat ${flagged.length ? 'bad' : ''}`}><b className="mono">{flagged.length}</b><span>주의</span></div>
        </div>
        <div className="wka-rail-lbl">운영 상태</div>
        <div className="wka-rail-hint">펼치기</div>
      </aside>
    );
  }

  return (
    <aside className="ov-aside wka" style={{ width: w }}>
      <div className="wka-resizer" onPointerDown={startResize} title="드래그하여 폭 조절"></div>
      <div className="wka-bar">
        <span className="wka-bar-t">운영 상태</span>
        <span className="wka-bar-live"><span className="wka-livedot"></span>{counts.active} active</span>
        <button className="wka-collapse" onClick={() => setCol(true)} title="접기 — Chat 열 때 공간 확보">{'\u00BB'}</button>
      </div>
      <div className="wka-hud">
        <div className="wka-hud-c"><span className="wka-hud-k">진행</span><span className="wka-hud-v">{counts.wip}</span></div>
        <div className="wka-hud-c"><span className="wka-hud-k">검증</span><span className={`wka-hud-v ${counts.verify ? 'volt' : ''}`}>{counts.verify}</span></div>
        <div className="wka-hud-c"><span className="wka-hud-k">백로그</span><span className={`wka-hud-v ${counts.backlog ? 'warn' : ''}`}>{counts.backlog}</span></div>
        <div className="wka-hud-c"><span className="wka-hud-k">할 일</span><span className={`wka-hud-v ${needTotal ? 'volt' : ''}`}>{needTotal}</span></div>
      </div>
      <div className="wka-scroll">
        <section className="wka-sec">
          <div className="wka-h">지금 상황{flagged.length > 0 && <span className="wka-h-n bad">{flagged.length}</span>}</div>
          {flagged.length === 0
            ? <div className="wka-calm mono">주의 목표 없음 · 정상 순환</div>
            : <div className="wka-list">
                {flagged.map(g => (
                  <button key={g.id} className={`wka-flag st-${g.cls}`} onClick={() => onJump(g.id)}>
                    <span className={`wka-flag-tag ${g.cls}`}>{g.lbl}</span>
                    <span className="wka-flag-title">{g.title}</span>
                    {g.reason && <span className="wka-flag-reason">{g.reason}</span>}
                  </button>
                ))}
              </div>}
        </section>

        <section className="wka-sec">
          <div className="wka-h">해야 할 일{needTotal > 0 && <span className="wka-h-n">{needTotal}</span>}</div>
          <div className="wka-list">
            {approvals.map(g => (
              <button key={g.id} className="wka-todo approve" onClick={() => onJump(g.id)}>
                <span className="wka-todo-k">완료 승인</span>
                <span className="wka-todo-t">{g.title}</span>
                <span className="wka-todo-m mono">{(g.verifier || []).join(' · ')}</span>
              </button>
            ))}
            {verifyTasks.map(t => (
              <button key={t.id} className="wka-todo verify" onClick={() => onJump(t.goalId)}>
                <span className="wka-todo-k">게이트</span>
                <span className="wka-todo-t">{t.title}</span>
                <span className="wka-todo-m mono">{t.open > 0 ? `${t.open} 미충족` : '검증 대기'}</span>
              </button>
            ))}
            {blockers.map(t => (
              <button key={t.id} className="wka-todo block" onClick={() => onJump(t.goalId)}>
                <span className="wka-todo-k">차단</span>
                <span className="wka-todo-t">{t.title}</span>
                <span className="wka-todo-m">{t.blocker}</span>
              </button>
            ))}
            {backlog.length > 0 && (
              <button className="wka-todo claim" onClick={() => onJump(backlog[0].goalId)}>
                <span className="wka-todo-k">클레임</span>
                <span className="wka-todo-t">미배정 task {backlog.length}건</span>
                <span className="wka-todo-m mono">keeper_task_claim</span>
              </button>
            )}
            {needTotal === 0 && <div className="wka-calm mono">대기 중인 작업 없음</div>}
          </div>
        </section>

        <section className="wka-sec">
          <div className="wka-h">최근 한 일{recent.length > 0 && <span className="wka-h-n dim">{recent.length}</span>}</div>
          <div className="wka-list">
            {recent.length === 0
              ? <div className="wka-calm mono">완료된 task 없음</div>
              : recent.map(t => (
                  <button key={t.id} className="wka-done" onClick={() => onJump(t.goalId)}>
                    <span className="wka-done-mark">{'\u2713'}</span>
                    <span className="wka-done-t">{t.title}</span>
                  </button>
                ))}
          </div>
        </section>
      </div>
    </aside>
  );
}

// 칸반 카드 — 클릭하면 상세 drawer (같은 lineage/gate/handoff)
function KanbanCard({ t, onOpen, onOpenKeeper, onClaim, onJumpGoal }) {
  const k = wkKeeper(t.assignee);
  const st = taskMeta(t.status);
  const hasHandoff = !!(t.lineage && t.lineage.some(e => e.ev === 'handoff'));
  return (
    <div className={`wk-kcard ${st.cls}`} role="button" tabIndex={0} onClick={onOpen} onKeyDown={(e) => { if (e.key === 'Enter') onOpen(); }}>
      <div className="wk-kcard-top">
        <span className="wk-kcard-id mono">{t.id}</span>
        <span className="wk-kcard-prio mono">P{t.priority}</span>
      </div>
      <div className="wk-kcard-title">{t.title}</div>
      {t.predecessor_task_id && <div className="wk-kcard-rerun" title={`predecessor_task_id = ${t.predecessor_task_id}`}>↻ 재실행 ← {t.predecessor_task_id}</div>}
      {t.blocker && <div className="wk-kcard-block">{'\u26A0'} 차단됨</div>}
      <button className="wk-kcard-goal" onClick={(e) => { e.stopPropagation(); onJumpGoal(t._goalId); }} title={`소속 목표로 이동 · ${t._goalTitle}`}>{'\u21B3'} {t._goalTitle}</button>
      <div className="wk-kcard-foot">
        {hasHandoff && <span className="wk-kcard-ho" title="핸드오프 이력">{'\u21C4'}</span>}
        <span className="wk-spacer"></span>
        {k
          ? <button className="wk-kcard-kp" onClick={(e) => { e.stopPropagation(); onOpenKeeper(k.id); }} title={`${k.id} 대화 열기`}><SigilBadge k={k} size={16} /></button>
          : t.status === 'todo'
            ? <button className="wk-kcard-claim" onClick={(e) => { e.stopPropagation(); onClaim(t.id); }} title="operator가 keeper에게 배정">{'\uFF0B'}</button>
            : <span className="wk-kcard-kp none mono">·</span>}
      </div>
    </div>
  );
}

function KanbanView({ tasks, onOpenTask, onOpenKeeper, onClaim, onJumpGoal }) {
  return (
    <div className="wk-kanban">
      {STATUS_COLS.map(([status, lbl, cls]) => {
        const col = tasks.filter(t => t.status === status);
        return (
          <div key={status} className={`wk-kcol ${cls}`}>
            <div className="wk-kcol-h"><span className={`wk-kcol-dot ${cls}`}></span>{lbl}<span className="wk-kcol-n mono">{col.length}</span></div>
            <div className="wk-kcol-body">
              {col.length === 0
                ? <div className="wk-kcol-empty mono">—</div>
                : col.map(t => <KanbanCard key={t.id} t={t} onOpen={() => onOpenTask(t)} onOpenKeeper={onOpenKeeper} onClaim={onClaim} onJumpGoal={onJumpGoal} />)}
            </div>
          </div>
        );
      })}
    </div>
  );
}

// task 상세 drawer — 칸반 카드·운영 패널에서 열림. 호라이즌 뷰의 inline 확장과 동일 내용.
function TaskDrawer({ t, onClose, onOpenKeeper }) {
  const st = taskMeta(t.status);
  const k = wkKeeper(t.assignee);
  const lineage = taskLineage(t);
  useWkEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  return (
    <div className="turn-overlay" onClick={onClose}>
      <div className="turn-drawer wk-tdrawer" onClick={(e) => e.stopPropagation()}>
        <div className="turn-hd">
          <span className={`wk-task-dot ${st.cls}`}></span>
          <h3>{t.id}</h3>
          <span className="wk-td-goal">{t._goalTitle}</span>
          <span style={{ marginLeft: 'auto' }}></span>
          <span className={`wk-task-state ${st.cls}`}>{st.lbl}</span>
          <button className="turn-close" onClick={onClose} title="닫기 (Esc)">{'\u2715'}</button>
        </div>
        <div className="turn-body">
          <div className="wk-td-title">{t.title}</div>
          <div className="wk-td-meta">
            <span className="wk-td-prio mono">P{t.priority}</span>
            {k
              ? <button className="wk-task-kp" onClick={() => onOpenKeeper(k.id)} title={`${k.id} 대화 열기`}><SigilBadge k={k} size={18} /><span className="mono">{k.id}</span></button>
              : <span className="wk-task-kp none mono">미배정</span>}
          </div>
          {t.blocker && <div className="wk-td-block">{'\u26A0'} {t.blocker}</div>}
          <TaskLineage events={lineage} assignee={t.assignee} onOpenKeeper={onOpenKeeper} />
          {t.gate && <TaskGate gate={t.gate} />}
          {t.handoff && (
            <div className="wk-handoff">
              <div className="wk-handoff-h">핸드오프 컨텍스트</div>
              <div className="wk-handoff-row"><span className="k">요약</span>{t.handoff.summary}</div>
              {t.handoff.next_step && <div className="wk-handoff-row"><span className="k">다음</span>{t.handoff.next_step}</div>}
              {t.handoff.failure_mode && <div className="wk-handoff-row"><span className="k">실패</span>{t.handoff.failure_mode}</div>}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

// priority → 위험 tier. RFC-0294로 horizon이 폐기되어 priority 단일 축이
// Safe/Moderate/Dangerous를 정하고, 실행 전 행동 가드(Proceed/Caution/Block)의 입력이 된다.
function goalRisk(priority) {
  const score = priority;
  if (score >= 8) return { cls: 'bad', lbl: 'Dangerous', desc: '실행 전 행동 가드가 Block·Caution 판정 — operator 승인 권장' };
  if (score >= 5) return { cls: 'warn', lbl: 'Moderate', desc: '주의하여 실행 · trajectory에 경고 기록' };
  return { cls: 'ok', lbl: 'Safe', desc: '가드 통과 · 자율 실행' };
}

// 새 목표 작성기 — Goal store에 목표 생성 (제목·우선순위·리드·승인정책).
function NewGoalComposer({ onClose, onCreate }) {
  const [title, setTitle] = useWkState('');
  const [priority, setPriority] = useWkState(5);
  const [lead, setLead] = useWkState('');
  const [approval, setApproval] = useWkState(false);
  const keepers = (window.KEEPERS || []).filter(k => k.role === 'keeper');
  const leadKeeper = keepers.find(k => k.id === lead);
  const risk = goalRisk(+priority);
  useWkEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  const valid = title.trim();
  const submit = () => {
    if (!valid) return;
    onCreate({
      id: 'goal-' + Date.now(), title: title.trim(), lead: lead || undefined,
      priority: +priority, status: 'active', phase: 'planning', metric: null, target: null, due_date: null,
      require_completion_approval: approval, verifier: approval ? ['operator'] : undefined, note: null, tasks: [],
    });
  };
  return (
    <div className="turn-overlay" onClick={onClose}>
      <div className="turn-drawer ngc-drawer" onClick={(e) => e.stopPropagation()}>
        <div className="turn-hd">
          <h3>새 목표</h3>
          <span className="tid mono">goal store · create</span>
          <span style={{ marginLeft: 'auto' }}></span>
          <button className="turn-close" onClick={onClose} title="닫기 (Esc)">{'\u2715'}</button>
        </div>
        <div className="turn-body">
          <div className="turn-sec">
            <h4>제목</h4>
            <input className="ngc-input" value={title} onChange={e => setTitle(e.target.value)} placeholder="예) scheduler p99 SLO 400ms 회복" autoFocus />
          </div>
          <div className="turn-sec">
            <h4>우선순위 · <span className="ngc-prio mono">P{priority}</span></h4>
            <input className="ngc-range" type="range" min="1" max="9" value={priority} onChange={e => setPriority(e.target.value)} />
          </div>
          <div className="turn-sec">
            <h4>예상 위험도 <span className="ngc-risk-note mono">priority</span></h4>
            <div className={`ngc-risk ${risk.cls}`}>
              <span className="ngc-risk-tier">{risk.lbl}</span>
              <span className="ngc-risk-desc">{risk.desc}</span>
            </div>
          </div>
          <div className="turn-sec">
            <h4>리드 keeper</h4>
            <div className="ngc-leads">
              <button className={`ngc-lead ${lead === '' ? 'on' : ''}`} onClick={() => setLead('')}>미지정</button>
              {keepers.map(k => (
                <button key={k.id} className={`ngc-lead ${lead === k.id ? 'on' : ''}`} onClick={() => setLead(k.id)}><SigilBadge k={k} size={16} /><span className="mono">{k.id}</span></button>
              ))}
            </div>
          </div>
          <div className="turn-sec">
            <label className="ngc-check"><input type="checkbox" checked={approval} onChange={e => setApproval(e.target.checked)} /><span>완료 승인 필요 <b>operator 검증 게이트</b></span></label>
            {risk.cls === 'bad' && !approval && <div className="ngc-rec">위험도 높음 — 완료 승인 게이트를 권장합니다</div>}
          </div>
          <div className="turn-sec bcc-actions">
            <button className="bcc-send" disabled={!valid} onClick={submit}>{'\uFF0B'} 목표 생성</button>
            <button className="sch-act ghost" onClick={onClose}>취소</button>
          </div>
        </div>
      </div>
    </div>
  );
}

// operator가 keeper에게 task를 배정하는 드로어. keeper는 자율로 keeper_task_claim 하지만,
// operator 콘솔에서는 특정 keeper에게 직접 배정(override)한다.
function AssignDrawer({ task, onClose, onAssign }) {
  const keepers = (window.KEEPERS || []).filter(k => k.role === 'keeper');
  const rank = (k) => k.status === 'run' ? 0 : k.status === 'pause' ? 1 : 2;
  const sorted = [...keepers].sort((a, b) => rank(a) - rank(b) || a.id.localeCompare(b.id));
  useWkEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  return (
    <div className="turn-overlay" onClick={onClose}>
      <div className="turn-drawer ngc-drawer" onClick={(e) => e.stopPropagation()}>
        <div className="turn-hd">
          <h3>task 배정</h3>
          <span className="tid mono">{task.id}</span>
          <span style={{ marginLeft: 'auto' }}></span>
          <button className="turn-close" onClick={onClose} title="닫기 (Esc)">{'\u2715'}</button>
        </div>
        <div className="turn-body">
          <div className="wk-assign-note">이 task는 원래 keeper가 스스로 <span className="mono">keeper_task_claim</span> 으로 가져갑니다. 여기서는 <b>operator가 대신 특정 keeper에게 배정</b>합니다 — 배정되면 상태가 <span className="mono">claimed</span> 로.</div>
          <div className="turn-sec">
            <h4>keeper 선택 · 실행 중 우선</h4>
            <div className="wk-assign-list">
              {sorted.map(k => (
                <button key={k.id} className="wk-assign-k" onClick={() => onAssign(task.id, k.id)}>
                  <SigilBadge k={k} size={22} />
                  <span className="wk-assign-id mono">{k.id}</span>
                  <span className="wk-assign-phase">{k.phase}</span>
                </button>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function WorkSurface({ onOpenKeeper, onNav, wantGoal }) {
  const baseGoals = window.GOALS || [];
  const [addedGoals, setAddedGoals] = useWkState([]);
  const [addedTasks, setAddedTasks] = useWkState({}); // goalId → [task]  (신규 생성)
  const [assignTask, setAssignTask] = useWkState(null); // operator가 배정할 task
  const goals = addedGoals.concat(baseGoals);
  const [open, setOpen] = useWkState(() => new Set(baseGoals.filter(g => g.priority >= 7 || g.status === 'at_risk' || g.status === 'verifying').map(g => g.id)));
  const [claimed, setClaimed] = useWkState({}); // task id → assignee (operator claim demo)
  const [view, setView] = useWkState('tree'); // tree | kanban
  const [drawerTask, setDrawerTask] = useWkState(null);
  const [composer, setComposer] = useWkState(false);
  // — 검증 요청 큐 상태 —
  const [submittedExtra, setSubmittedExtra] = useWkState(() => new Set()); // 검증 요청으로 올린 taskId
  const [verdicts, setVerdicts] = useWkState({});      // taskId → { decision, reason, at }
  const [gateChecks, setGateChecks] = useWkState({});  // taskId → { idx: bool } operator 확인
  const [reassign, setReassign] = useWkState({});      // taskId → 검증자 id
  const [rerunOf, setRerunOf] = useWkState({});        // RFC-0323 G-8: 반려된 taskId → 생성된 재실행 task id
  const findTaskGoal = (tid) => {
    for (const g of goals) {
      const t = [...g.tasks, ...(addedTasks[g.id] || [])].find(x => x.id === tid);
      if (t) return { t, goalId: g.id };
    }
    return null;
  };
  const [verifyLayout, setVerifyLayout] = useWkState(() => { try { return localStorage.getItem('v2.verifyLayout') || 'stack'; } catch (e) { return 'stack'; } });
  const setVLayout = (v) => { setVerifyLayout(v); try { localStorage.setItem('v2.verifyLayout', v); } catch (e) {} };
  const toggle = (id) => setOpen(prev => { const n = new Set(prev); if (n.has(id)) n.delete(id); else n.add(id); return n; });
  // operator가 keeper에게 task 배정 (keeper 자율 claim의 override). addTask = 신규 task 생성.
  const openAssign = (taskId) => setAssignTask({ id: taskId });
  const doAssign = (taskId, keeperId) => {
    setClaimed(prev => ({ ...prev, [taskId]: keeperId }));
    setAssignTask(null);
    if (window.pushToast) window.pushToast({ tone: 'ok', msg: `${taskId} → ${keeperId} 배정`, sub: 'operator 배정 · keeper_task_claim override', undo: () => setClaimed(prev => { const n = { ...prev }; delete n[taskId]; return n; }) });
  };
  const addTask = (goalId, t) => {
    const task = { id: 'task-' + Date.now(), title: t.title, assignee: null, status: 'todo', priority: t.priority || 5 };
    setAddedTasks(prev => ({ ...prev, [goalId]: [...(prev[goalId] || []), task] }));
    if (window.pushToast) window.pushToast({ tone: 'ok', msg: `task 추가 · ${t.title}`, sub: `${goalId} · todo·미배정`, undo: () => setAddedTasks(prev => ({ ...prev, [goalId]: (prev[goalId] || []).filter(x => x.id !== task.id) })) });
  };
  // keeper 가 진행 중 task 를 검증 대기로 제출 → 큐에 등장
  const requestVerify = (taskId) => {
    setSubmittedExtra(prev => { const n = new Set(prev); n.add(taskId); return n; });
    if (window.pushToast) window.pushToast({ tone: 'ok', msg: `${taskId} 검증 요청`, sub: 'awaiting_verification → 검증 큐', undo: () => setSubmittedExtra(prev => { const n = new Set(prev); n.delete(taskId); return n; }) });
  };
  const toggleGate = (taskId, idx, val) => setGateChecks(prev => ({ ...prev, [taskId]: { ...(prev[taskId] || {}), [idx]: val } }));
  const VERDICT_TOAST = { approved: ['ok', '승인 · 통과', 'task → done'], rejected: ['bad', '반려', 'keeper 에게 반송'], deferred: ['warn', '보류', '재검증 대기'] };
  const resolveVerify = (taskId, decision, opts) => {
    const at = window.nowHM ? window.nowHM() : '';
    setVerdicts(prev => ({ ...prev, [taskId]: { decision, reason: (opts && opts.reason) || null, at } }));
    // RFC-0323 G-8 — a rejected task spawns a linked re-run (predecessor_task_id)
    let rerunId = null;
    if (decision === 'rejected') {
      const found = findTaskGoal(taskId);
      if (found) {
        rerunId = 'task-' + Date.now();
        const rerun = { id: rerunId, title: '재실행 · ' + found.t.title, assignee: found.t.assignee || null, status: found.t.assignee ? 'claimed' : 'todo', priority: found.t.priority || 5, predecessor_task_id: taskId, _rerun: true };
        setAddedTasks(prev => ({ ...prev, [found.goalId]: [...(prev[found.goalId] || []), rerun] }));
        setRerunOf(prev => ({ ...prev, [taskId]: { rerunId, goalId: found.goalId } }));
      }
    }
    const [tone, msg, sub] = VERDICT_TOAST[decision] || VERDICT_TOAST.deferred;
    if (window.pushToast) window.pushToast({ tone, msg: `${taskId} ${msg}`, sub: rerunId ? `${sub} · ↻ ${rerunId} 재실행 생성 (predecessor ${taskId})` : sub, undo: () => undoVerdict(taskId) });
  };
  const undoVerdict = (taskId) => {
    setVerdicts(prev => { const n = { ...prev }; delete n[taskId]; return n; });
    setRerunOf(prev => {
      const r = prev[taskId];
      if (r) setAddedTasks(at => ({ ...at, [r.goalId]: (at[r.goalId] || []).filter(x => x.id !== r.rerunId) }));
      const n = { ...prev }; delete n[taskId]; return n;
    });
  };
  const reassignVerifier = (taskId, who) => {
    setReassign(prev => ({ ...prev, [taskId]: who }));
    if (window.pushToast) window.pushToast({ tone: 'ok', msg: `${taskId} 검증자 재배정`, sub: `→ ${who}`, undo: () => setReassign(prev => { const n = { ...prev }; delete n[taskId]; return n; }) });
  };
  // deep-link from palette: expand + scroll to the wanted goal
  useWkEffect(() => {
    if (!wantGoal || !wantGoal.id) return;
    setOpen(prev => new Set(prev).add(wantGoal.id));
    const el = document.querySelector(`[data-goal-id="${wantGoal.id}"]`);
    if (el) el.scrollIntoView({ block: 'center' });
  }, [wantGoal && wantGoal.at]);

  // apply demo claims onto the goal tree, then verification overrides
  const applyVerify = (t) => {
    const v = verdicts[t.id];
    if (v) {
      if (v.decision === 'approved') return { ...t, status: 'done' };
      if (v.decision === 'rejected') return { ...t, status: 'in_progress', _rejected: v.reason };
      // deferred → stays awaiting_verification (재검증 대기)
    }
    if (submittedExtra.has(t.id) && (t.status === 'in_progress' || t.status === 'claimed')) return { ...t, status: 'awaiting_verification', _requested: true };
    return t;
  };
  const tree = goals.map(g => ({ ...g, tasks: [...g.tasks, ...(addedTasks[g.id] || [])].map(t => claimed[t.id] && !t.assignee ? { ...t, assignee: claimed[t.id], status: 'claimed' } : t).map(applyVerify) }));

  const allTasks = tree.flatMap(g => g.tasks);
  const total = allTasks.filter(t => t.status !== 'cancelled').length;
  const wip = allTasks.filter(t => t.status === 'in_progress' || t.status === 'claimed').length;
  const verify = allTasks.filter(t => t.status === 'awaiting_verification').length;
  const backlog = tree.flatMap(g => g.tasks.filter(t => t.status === 'todo' && !t.assignee).map(t => ({ ...t, goal: g.title, goalId: g.id })));

  // — operator status panel (우측 aside) derived from the same tree —
  const flagged = tree.filter(g => g.status !== 'active').map(g => { const m = goalMeta(g.status); return { id: g.id, cls: m.cls, lbl: m.lbl, title: g.title, reason: g.note }; });
  const approvals = tree.filter(g => g.require_completion_approval && g.status === 'verifying').map(g => ({ id: g.id, title: g.title, verifier: g.verifier }));
  const verifyTasks = tree.flatMap(g => g.tasks.filter(t => t.status === 'awaiting_verification').map(t => ({ id: t.id, title: t.title, goalId: g.id, open: t.gate ? t.gate.filter(x => x.outcome !== 'satisfied').length : 0 })));
  const blockers = tree.flatMap(g => g.tasks.filter(t => t.blocker).map(t => ({ id: t.id, title: t.title, blocker: t.blocker, goalId: g.id })));
  const recent = tree.flatMap(g => g.tasks.filter(t => t.status === 'done').map(t => ({ id: t.id, title: t.title, ns: g.ns, goalId: g.id })));
  const counts = { active: goals.length, wip, verify, backlog: backlog.length };

  const jump = (id) => {
    setOpen(prev => new Set(prev).add(id));
    requestAnimationFrame(() => {
      const sc = document.querySelector('.ov-2col .ov-scroll');
      const el = document.querySelector(`[data-goal-id="${id}"]`);
      if (sc && el) { const r = el.getBoundingClientRect(), sr = sc.getBoundingClientRect(); sc.scrollTo({ top: sc.scrollTop + r.top - sr.top - 80, behavior: 'smooth' }); }
    });
  };

  // goal을 priority 내림차순으로 정렬한 Goal→Task 트리 (RFC-0294: horizon 버킷 제거)
  const treeSorted = [...tree].sort((a, b) => (b.priority || 0) - (a.priority || 0));
  // 칸반·drawer용 평탄 task (goal 메타 주입, cancelled 제외)
  const kanbanTasks = tree.flatMap(g => g.tasks.filter(t => t.status !== 'cancelled').map(t => ({ ...t, _goalNs: g.ns, _goalId: g.id, _goalTitle: g.title })));
  // 검증 대기 큐 — awaiting_verification task 만 모음 (goal 의 검증자 정책 주입)
  const verifyQueue = tree.flatMap(g => g.tasks.filter(t => t.status === 'awaiting_verification').map(t => ({ ...t, _goalId: g.id, _goalTitle: g.title, _verifier: g.verifier || null })));
  const flatAll = goals.flatMap(g => [...g.tasks, ...(addedTasks[g.id] || [])]);
  const resolvedList = Object.keys(verdicts).map(id => ({ task: flatAll.find(t => t.id === id), verdict: verdicts[id] })).filter(x => x.task && x.verdict.decision !== 'deferred');
  const drawerLive = drawerTask ? (kanbanTasks.find(t => t.id === drawerTask.id) || drawerTask) : null;
  // 칸반→트리로 전환 후 해당 목표로 스크롤
  const jumpToGoal = (id) => {
    setView('tree');
    setOpen(prev => new Set(prev).add(id));
    requestAnimationFrame(() => requestAnimationFrame(() => {
      const sc = document.querySelector('.ov-2col .ov-scroll');
      const el = document.querySelector(`[data-goal-id="${id}"]`);
      if (sc && el) { const r = el.getBoundingClientRect(), sr = sc.getBoundingClientRect(); sc.scrollTo({ top: sc.scrollTop + r.top - sr.top - 80, behavior: 'smooth' }); }
    }));
  };
  const createGoal = (g) => {
    setAddedGoals(prev => [g, ...prev]);
    setOpen(prev => new Set(prev).add(g.id));
    setComposer(false);
    setView('tree');
    if (window.pushToast) window.pushToast({ tone: 'ok', msg: `목표 생성 · ${g.title}`, sub: `P${g.priority}`, undo: () => setAddedGoals(prev => prev.filter(x => x.id !== g.id)) });
  };

  return (
    <main className="ov ov-flush ov-2col">
      <div className="ov-scroll">
        <header className="ov-head">
          <div>
            <span className="ov-eyebrow">Goal Store</span>
            <h1>작업 · 목표</h1>
          </div>
          <div className="wk-head-r">
            <div className="wk-viewseg" role="tablist">
              <button className={view === 'tree' ? 'on' : ''} onClick={() => setView('tree')}>트리</button>
              <button className={view === 'kanban' ? 'on' : ''} onClick={() => setView('kanban')}>칸반</button>
              <button className={view === 'verify' ? 'on' : ''} onClick={() => setView('verify')}>검증{verify ? ` ${verify}` : ''}</button>
            </div>
            <button className="set-add wk-newgoal" title="새 목표 생성" onClick={() => setComposer(true)}>{'\uFF0B'} 새 목표</button>
          </div>
        </header>

        <section className="ov-kpis wk-kpis" style={{ gridTemplateColumns: 'repeat(5, 1fr)' }}>
          <div className="ov-kpi"><div className="ov-kpi-k">활성 목표</div><div className="ov-kpi-v volt">{goals.length}</div></div>
          <div className="ov-kpi"><div className="ov-kpi-k">전체 Task</div><div className="ov-kpi-v">{total}</div></div>
          <div className="ov-kpi"><div className="ov-kpi-k">진행 중</div><div className="ov-kpi-v">{wip}</div></div>
          <div className="ov-kpi"><div className="ov-kpi-k">검증 대기</div><div className={`ov-kpi-v ${verify ? 'volt' : ''}`}>{verify}</div></div>
          <div className="ov-kpi"><div className="ov-kpi-k">백로그</div><div className={`ov-kpi-v ${backlog.length ? 'warn' : ''}`}>{backlog.length}</div></div>
        </section>

        {view === 'tree' && backlog.length > 0 && (
          <section className="wk-backlog">
            <div className="wk-backlog-h"><span className="wk-backlog-glyph">⊕</span>아직 안 맡은 task <span className="n">{backlog.length}</span><span className="wk-backlog-sub mono">여러 목표에서 미배정 task만 모음 · keeper_task_claim (아래 트리에도 표시)</span></div>
            <div className="wk-backlog-list">
              {backlog.map(t => (
                <div key={t.id} className="wk-bl-row">
                  <span className="wk-task-id mono">{t.id}</span>
                  <span className="wk-bl-title">{t.title}<span className="wk-bl-goal">{'\u21B3'} {t.goal}</span></span>
                  <span className="wk-spacer"></span>
                  <span className="wk-bl-prio mono">P{t.priority}</span>
                  <button className="wk-task-claim" onClick={() => openAssign(t.id)} title="operator가 keeper에게 배정">{'\uFF0B'} 배정</button>
                </div>
              ))}
            </div>
          </section>
        )}

        {view === 'tree' && (
          <React.Fragment>
            <div className="wk-sec-h">
              <span className="wk-sec-glyph">◈</span>
              <span className="wk-sec-t">목표 트리</span>
              <span className="wk-sec-n mono">{treeSorted.length}</span>
              <span className="wk-sec-sub mono">Goal → Task · priority 순 · 펼쳐서 task·게이트 확인</span>
            </div>
            <div className="wk-list wk-tree">
              {treeSorted.map(g => (
                <GoalCard key={g.id} g={g} open={open.has(g.id)} onToggle={() => toggle(g.id)} onOpenKeeper={onOpenKeeper} onClaim={openAssign} onAddTask={addTask} onRequestVerify={requestVerify} />
              ))}
            </div>
          </React.Fragment>
        )}

        {view === 'kanban' && (
          <React.Fragment>
            <div className="wk-sec-h">
              <span className="wk-sec-glyph">▦</span>
              <span className="wk-sec-t">칸반 · 상태별</span>
              <span className="wk-sec-n mono">{kanbanTasks.length}</span>
              <span className="wk-sec-sub mono">todo → claimed → in_progress → verify → done</span>
            </div>
            <KanbanView tasks={kanbanTasks} onOpenTask={setDrawerTask} onOpenKeeper={onOpenKeeper} onClaim={openAssign} onJumpGoal={jumpToGoal} />
          </React.Fragment>
        )}

        {view === 'verify' && window.VerificationQueue && (
          <VerificationQueue
            queue={verifyQueue} resolvedList={resolvedList}
            layout={verifyLayout} setLayout={setVLayout}
            checks={gateChecks} reassign={reassign} verdicts={verdicts}
            onToggleGate={toggleGate} onResolve={resolveVerify} onReassign={reassignVerifier} onUndo={undoVerdict}
            onOpenKeeper={onOpenKeeper} onJumpGoal={jumpToGoal} />
        )}

        <div className="wk-foot mono">Goal → Task → keeper · priority 순 트리 · 완료는 게이트 증거 충족 후 done · 미배정 task 는 백로그에서 claim</div>
      </div>
      <WorkAside flagged={flagged} approvals={approvals} verifyTasks={verifyTasks} blockers={blockers} backlog={backlog} recent={recent} counts={counts} onJump={jump} onOpenKeeper={onOpenKeeper} />
      {drawerLive && <TaskDrawer t={drawerLive} onClose={() => setDrawerTask(null)} onOpenKeeper={onOpenKeeper} />}
      {composer && <NewGoalComposer onClose={() => setComposer(false)} onCreate={createGoal} />}
      {assignTask && <AssignDrawer task={assignTask} onClose={() => setAssignTask(null)} onAssign={doAssign} />}
    </main>
  );
}

Object.assign(window, { WorkSurface });
