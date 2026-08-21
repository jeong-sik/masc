/* MASC v2 — Verification queue (검증 대기 큐).
   Renders tasks a keeper submitted to `awaiting_verification`. The operator
   reviews the completion-contract gate evidence item by item, then
   승인(통과)→done · 반려(reject)→keeper 반송 · 보류/재검증 · 검증자 재배정.
   Three layouts: stack · split · triage. Driven entirely by props from
   WorkSurface (state + mutations live there). */
const { useState: useVqState } = React;

function vqKeeper(id) { return (window.KEEPERS || []).find(k => k.id === id); }
function vqTaskMeta(s) { return (window.TASK_STATUS || {})[s] || { lbl: s, cls: 'todo' }; }
const VQ_GATE_LBL = () => window.GATE_OUTCOME || { satisfied: '충족', missing: '누락', failed: '실패', unsupported: '미지원' };

// operator confirmation state for one gate row — explicit check wins, else
// auto-confirmed when the evidence is already satisfied.
function vqConfirmed(checks, taskId, idx, outcome) {
  const c = checks[taskId];
  if (c && idx in c) return c[idx];
  return outcome === 'satisfied';
}
function vqGateStats(task, checks) {
  const gate = task.gate || [];
  const confirmed = gate.filter((g, i) => vqConfirmed(checks, task.id, i, g.outcome)).length;
  const satisfied = gate.filter(g => g.outcome === 'satisfied').length;
  return { total: gate.length, confirmed, satisfied, allConfirmed: gate.length > 0 && confirmed === gate.length };
}

// canonical submit event (last lineage 'submitted' entry) → who + when
function vqSubmit(task) {
  const ev = (task.lineage || []).filter(e => e.ev === 'submitted').pop();
  return ev ? { actor: ev.actor || task.assignee, at: ev.at, note: ev.note } : { actor: task.assignee, at: null, note: null };
}

// ── interactive gate checklist ────────────────────────────────
function VqGate({ task, checks, onToggleGate }) {
  const L = VQ_GATE_LBL();
  const st = vqGateStats(task, checks);
  const openN = st.total - st.confirmed;
  return (
    <div className="vq-gate">
      <div className="vq-gate-h">
        완료 계약 · 게이트 증거
        <span className={`n ${openN > 0 ? 'open' : 'ok'}`}>{st.confirmed}/{st.total} 확인</span>
      </div>
      {(task.gate || []).map((g, i) => {
        const conf = vqConfirmed(checks, task.id, i, g.outcome);
        const auto = !(checks[task.id] && i in checks[task.id]) && g.outcome === 'satisfied';
        return (
          <div key={i} className={`vq-gate-row ${conf ? 'confirmed' : ''} ${auto ? 'auto' : ''}`}
            role="checkbox" aria-checked={conf} tabIndex={0}
            onClick={() => onToggleGate(task.id, i, !conf)}
            onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onToggleGate(task.id, i, !conf); } }}
            title={conf ? 'operator 확인됨 — 클릭하여 해제' : (g.outcome === 'satisfied' ? '클릭하여 확인' : 'operator 판단으로 강제 확인 (미충족 증거)')}>
            <span className="vq-gate-box">{'\u2713'}</span>
            <span className="vq-gate-ev">{g.evidence}</span>
            <span className={`vq-gate-out ${g.outcome}`}>{L[g.outcome] || g.outcome}</span>
          </div>
        );
      })}
    </div>
  );
}

const VQ_REASONS = ['게이트 증거 미충족', '회귀 테스트 부족', '측정치 재현 필요', '범위 벗어남 · 분할 필요'];

// ── action bar (승인 / 반려 / 보류 / 검증자 재배정) ───────────
function VqActions({ task, checks, verifier, reassign, onResolve, onReassign, compact }) {
  const [mode, setMode] = useVqState(null); // null | 'reject' | 'reassign'
  const [reason, setReason] = useVqState('');
  const st = vqGateStats(task, checks);
  const keepers = (window.KEEPERS || []).filter(k => k.role === 'keeper');
  const doReject = () => { onResolve(task.id, 'rejected', { reason: reason.trim() || '사유 미기재' }); setMode(null); setReason(''); };
  return (
    <React.Fragment>
      <div className="vq-actions">
        <button className="vq-act approve" disabled={!st.allConfirmed}
          title={st.allConfirmed ? '모든 게이트 확인됨 — 통과 처리 (task → done)' : `게이트 ${st.total - st.confirmed}건 미확인 — 통과 불가`}
          onClick={() => onResolve(task.id, 'approved', {})}>{'\u2713'} 승인 · 통과</button>
        <button className={`vq-act reject ${compact ? 'mini' : ''}`} onClick={() => setMode(m => m === 'reject' ? null : 'reject')}>{'\u2715'} 반려</button>
        <button className={`vq-act defer ${compact ? 'mini' : ''}`} onClick={() => onResolve(task.id, 'deferred', {})} title="보류 — 재검증 대기로 남김">{'\u23F8'} 보류</button>
        <span className="vq-act-spacer"></span>
        <button className={`vq-act ${compact ? 'mini' : ''}`} onClick={() => setMode(m => m === 'reassign' ? null : 'reassign')} title="다른 keeper·operator에게 검증 재배정">{'\u21C4'} 검증자</button>
      </div>

      {mode === 'reject' && (
        <div className="vq-form">
          <div className="vq-form-h">반려 사유 · keeper 에게 반송됩니다</div>
          <div className="vq-reasons">
            {VQ_REASONS.map(r => <button key={r} className="vq-reason-chip" onClick={() => setReason(p => p ? p + ' · ' + r : r)}>{r}</button>)}
          </div>
          <textarea value={reason} autoFocus placeholder="무엇이 부족한지, 무엇을 다시 해야 하는지…" onChange={e => setReason(e.target.value)} />
          <div className="vq-form-row">
            <button className="vq-act reject mini" onClick={doReject}>{'\u2715'} 반려하고 반송</button>
            <button className="vq-act mini" onClick={() => { setMode(null); setReason(''); }}>취소</button>
          </div>
        </div>
      )}

      {mode === 'reassign' && (
        <div className="vq-form">
          <div className="vq-form-h">검증자 재배정 · 현재 {(verifier && verifier.length) ? verifier.join(' · ') : 'operator'}</div>
          <div className="vq-kpick">
            <button className={`vq-kpick-b ${reassign === 'operator' ? 'on' : ''}`} onClick={() => { onReassign(task.id, 'operator'); setMode(null); }}>operator</button>
            {keepers.filter(k => k.id !== task.assignee).map(k => (
              <button key={k.id} className={`vq-kpick-b ${reassign === k.id ? 'on' : ''}`} onClick={() => { onReassign(task.id, k.id); setMode(null); }}>
                <SigilBadge k={k} size={16} /><span className="mono">{k.id}</span>
              </button>
            ))}
          </div>
        </div>
      )}
    </React.Fragment>
  );
}

// keeper sub-badge (submitter)
function VqSubmitter({ task, onOpenKeeper }) {
  const sub = vqSubmit(task);
  const k = vqKeeper(sub.actor);
  return (
    <React.Fragment>
      {k
        ? <button className="vq-sub" onClick={() => onOpenKeeper(k.id)} title={`${k.id} 대화 열기`}><SigilBadge k={k} size={16} /><span className="mono">{k.id}</span></button>
        : <span className="vq-submitted mono">{sub.actor || '미배정'}</span>}
      {sub.at && <span className="vq-submitted">{sub.at} 제출</span>}
    </React.Fragment>
  );
}

// full review body shared by stack card + split detail
function VqReview({ task, checks, reassign, onToggleGate, onResolve, onReassign, onOpenKeeper, onJumpGoal }) {
  const sub = vqSubmit(task);
  return (
    <React.Fragment>
      {task.predecessor_task_id && <div className="vq-note rerun">{'\u21BB'} 재실행 제출 · predecessor <b>{task.predecessor_task_id}</b> — 반려 후 재검증</div>}
      {sub.note && <div className="vq-note"><b>제출 메모</b> · {sub.note}</div>}
      <VqGate task={task} checks={checks} onToggleGate={onToggleGate} />
      {task.handoff && (
        <div className="vq-note"><b>핸드오프</b> · {task.handoff.summary}{task.handoff.next_step ? ` → ${task.handoff.next_step}` : ''}</div>
      )}
      {task._verifier && task._verifier.length > 0 && (
        <div className="vq-verifier">완료 승인 정책 · 검증자
          {(reassign ? [reassign] : task._verifier).map(v => <span key={v} className="vq-verifier-chip">{v}</span>)}
        </div>
      )}
      <VqActions task={task} checks={checks} verifier={task._verifier} reassign={reassign}
        onResolve={onResolve} onReassign={onReassign} />
    </React.Fragment>
  );
}

// ── LAYOUT A: stack ──────────────────────────────────────────
function VqStack(props) {
  const { queue, checks, reassign } = props;
  return (
    <div className="vq-list">
      {queue.map(task => (
        <article key={task.id} className={`vq-card ${vqGateStats(task, checks).allConfirmed ? 'pinned' : ''}`}>
          <div className="vq-card-top">
            <div className="grow">
              <div className="vq-req-id mono">{task.id} · P{task.priority}</div>
              <div className="vq-req-title">{task.title}</div>
              <button className="vq-req-goal" onClick={() => props.onJumpGoal(task._goalId)} title="소속 목표로 이동">{'\u21B3'} {task._goalTitle}</button>
            </div>
            <div className="vq-card-meta"><VqSubmitter task={task} onOpenKeeper={props.onOpenKeeper} /></div>
          </div>
          <VqReview task={task} checks={checks} reassign={reassign[task.id]}
            onToggleGate={props.onToggleGate} onResolve={props.onResolve} onReassign={props.onReassign}
            onOpenKeeper={props.onOpenKeeper} onJumpGoal={props.onJumpGoal} />
        </article>
      ))}
    </div>
  );
}

// ── LAYOUT B: split (master-detail) ──────────────────────────
function VqSplit(props) {
  const { queue, checks, reassign } = props;
  const [selId, setSel] = useVqState(queue.length ? queue[0].id : null);
  const sel = queue.find(t => t.id === selId) || queue[0];
  React.useEffect(() => { if (!queue.find(t => t.id === selId) && queue.length) setSel(queue[0].id); }, [queue.map(t => t.id).join(',')]);
  return (
    <div className="vq-split">
      <div className="vq-splitlist">
        {queue.map(task => {
          const st = vqGateStats(task, checks);
          const k = vqKeeper(vqSubmit(task).actor);
          return (
            <button key={task.id} className={`vq-splitrow ${task.id === (sel && sel.id) ? 'on' : ''}`} onClick={() => setSel(task.id)}>
              <span className="vq-splitrow-t">{task.title}</span>
              <span className="vq-splitrow-b">
                {k && <SigilBadge k={k} size={14} />}
                <span className="vq-mini-prog"><span style={{ width: (st.total ? st.confirmed / st.total * 100 : 0) + '%' }}></span></span>
                <span className="mono">{st.confirmed}/{st.total}</span>
              </span>
            </button>
          );
        })}
      </div>
      <div className="vq-detail">
        {sel ? (
          <React.Fragment>
            <div className="vq-req-head">
              <div style={{ flex: 1 }}>
                <div className="vq-req-id mono">{sel.id} · P{sel.priority}</div>
                <div className="vq-req-title">{sel.title}</div>
                <button className="vq-req-goal" onClick={() => props.onJumpGoal(sel._goalId)}>{'\u21B3'} {sel._goalTitle}</button>
              </div>
              <VqSubmitter task={sel} onOpenKeeper={props.onOpenKeeper} />
            </div>
            <VqReview task={sel} checks={checks} reassign={reassign[sel.id]}
              onToggleGate={props.onToggleGate} onResolve={props.onResolve} onReassign={props.onReassign}
              onOpenKeeper={props.onOpenKeeper} onJumpGoal={props.onJumpGoal} />
          </React.Fragment>
        ) : <div className="vq-detail-empty">검토할 요청을 선택하세요</div>}
      </div>
    </div>
  );
}

// ── LAYOUT C: triage board ───────────────────────────────────
function VqTriage(props) {
  const { queue, checks, reassign } = props;
  const [expandId, setExpand] = useVqState(null);
  return (
    <div className="vq-grid">
      {queue.map(task => {
        const st = vqGateStats(task, checks);
        const k = vqKeeper(vqSubmit(task).actor);
        const open = st.total - st.confirmed;
        const expanded = expandId === task.id;
        return (
          <article key={task.id} className="vq-tri">
            <div className="vq-tri-top">
              <span className="vq-req-id mono">{task.id}</span>
              <span className="vq-req-prio mono" style={{ marginLeft: 'auto' }}>P{task.priority}</span>
              {k && <SigilBadge k={k} size={16} />}
            </div>
            <div className="vq-tri-title" onClick={() => setExpand(id => id === task.id ? null : task.id)}>{task.title}</div>
            <div className="vq-tri-meta">
              <button className="vq-req-goal" onClick={() => props.onJumpGoal(task._goalId)}>{'\u21B3'} {task._goalTitle}</button>
            </div>
            <div className="vq-tri-gate">
              <span className="vq-tri-gate-bar"><span style={{ width: (st.total ? st.confirmed / st.total * 100 : 0) + '%' }}></span></span>
              <span className={`vq-tri-gate-n ${open ? 'open' : ''}`}>{st.confirmed}/{st.total}</span>
            </div>
            {!expanded ? (
              <React.Fragment>
                <div className="vq-tri-actions">
                  <button className="vq-act approve mini" disabled={!st.allConfirmed} onClick={() => props.onResolve(task.id, 'approved', {})}>{'\u2713'} 통과</button>
                  <button className="vq-act reject mini" onClick={() => setExpand(task.id)}>{'\u2715'} 반려</button>
                </div>
                <button className="vq-tri-more" onClick={() => setExpand(task.id)}>게이트 증거 검토 {'\u2192'}</button>
              </React.Fragment>
            ) : (
              <React.Fragment>
                <VqGate task={task} checks={checks} onToggleGate={props.onToggleGate} />
                <VqActions task={task} checks={checks} verifier={task._verifier} reassign={reassign[task.id]}
                  onResolve={props.onResolve} onReassign={props.onReassign} compact />
                <button className="vq-tri-more" onClick={() => setExpand(null)}>{'\u2191'} 접기</button>
              </React.Fragment>
            )}
          </article>
        );
      })}
    </div>
  );
}

const VQ_VERDICT = {
  approved: { cls: 'approved', mark: '\u2713', lbl: '승인 · 통과', tail: 'task → done' },
  rejected: { cls: 'rejected', mark: '\u2715', lbl: '반려', tail: 'keeper 에게 반송 · in_progress' },
  deferred: { cls: 'deferred', mark: '\u23F8', lbl: '보류', tail: '재검증 대기' },
};

function VerificationQueue({ queue, resolvedList, layout, setLayout, checks, reassign, verdicts,
  onToggleGate, onResolve, onReassign, onUndo, onOpenKeeper, onJumpGoal }) {
  const LAYOUTS = [['stack', '검토 스택'], ['split', '분할 검토'], ['triage', '트리아지']];
  const bad = queue.filter(t => (t.gate || []).some(g => g.outcome === 'failed')).length;
  const ready = queue.filter(t => vqGateStats(t, checks).allConfirmed).length;
  const Body = layout === 'split' ? VqSplit : layout === 'triage' ? VqTriage : VqStack;

  return (
    <div className={`vq vq-lay-${layout}`}>
      <div className="vq-bar">
        <span className="vq-bar-t">검증 요청 큐</span>
        <span className="vq-bar-lane mono" title="done 은 검증 레인(probe)을 통과해야 확정됩니다 (state-keyed done)">검증 레인</span>
        <div className="vq-bar-stats">
          <span className="vq-bar-stat volt"><b>{queue.length}</b> 대기</span>
          <span className="vq-bar-stat"><b>{ready}</b> 통과 준비</span>
          {bad > 0 && <span className="vq-bar-stat bad"><b>{bad}</b> 증거 실패</span>}
        </div>
        <span className="vq-bar-spacer"></span>
        <div className="vq-layseg" role="tablist" aria-label="레이아웃">
          {LAYOUTS.map(([v, lbl]) => (
            <button key={v} className={layout === v ? 'on' : ''} onClick={() => setLayout(v)}>{lbl}</button>
          ))}
        </div>
      </div>

      {resolvedList.length > 0 && (
        <div className="vq-list">
          {resolvedList.map(({ task, verdict }) => {
            const m = VQ_VERDICT[verdict.decision] || VQ_VERDICT.deferred;
            return (
              <div key={task.id} className={`vq-verdict ${m.cls}`}>
                <span className="vq-verdict-mark">{m.mark}</span>
                <span className="vq-verdict-body"><b>{task.id}</b> {task.title} — {m.lbl} · {m.tail}{verdict.reason ? ` · “${verdict.reason}”` : ''}</span>
                <button className="vq-verdict-undo" onClick={() => onUndo(task.id)}>되돌리기</button>
              </div>
            );
          })}
        </div>
      )}

      {queue.length === 0 ? (
        <div className="vq-clear">
          <div className="ico">{'\u2713'}</div>
          <h3>검증 대기 요청이 없습니다</h3>
          <div className="vq-clear-sub">keeper 가 task 를 <span className="mono">awaiting_verification</span> 으로 제출하면 여기에 모입니다 — 트리·칸반에서 진행 중 task 의 <b>검증 요청</b> 으로도 올릴 수 있습니다.</div>
        </div>
      ) : (
        <Body queue={queue} checks={checks} reassign={reassign}
          onToggleGate={onToggleGate} onResolve={onResolve} onReassign={onReassign}
          onOpenKeeper={onOpenKeeper} onJumpGoal={onJumpGoal} />
      )}
    </div>
  );
}

Object.assign(window, { VerificationQueue });
