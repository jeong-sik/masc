/* MASC v2 — Gate surface: 외부 효과(external effect) 결재 게이트.
   keeper 가 외부 효과(파일 쓰기·실행·발신·전이 등)를 청하면 Gate 가 세 가지
   비계층(non-hierarchical) 처분 중 하나로 보낸다:
     · Always Allow   — 정확일치(exact) 규칙에 맞으면 즉시 통과, 1회 소비
     · LLM Auto Judge — 설정된 심판 모델이 비동기로 판정
     · HITL           — 요청을 그대로 영속하고 operator 가 여기서 결정
   HITL 은 nonblocking: keeper 는 다른 일을 계속하고, 결정이 도착하면 그 keeper
   레인만 깨운다(Hitl_resolved wake). 위험도(risk) 등급·거부 바닥·직무분리 같은
   거버넌스 계층은 소스에서 제거됨 — Gate 는 세 처분의 평면 선택이다.

   상태는 app 이 들고 있고(statusMap + onResolve) — nav 배지·overview·topbar 가
   동일한 처리 결과를 반영하도록 단일 소스로 끌어올렸다. */
const { useState: useApS, useMemo: useApMemo, useEffect: useApE } = React;

function apKeeper(id) { return (window.KEEPERS || []).find(k => k.id === id); }

// opened(초) → "Nm Ns 대기"
function apAge(sec) {
  const m = Math.floor(sec / 60), s = sec % 60;
  return m ? `${m}분 ${s}초 대기` : `${s}초 대기`;
}

const AP_RESOLVED = {
  approved: { lbl: '승인됨', cls: 'ok',  glyph: '\u2713' },
  denied:   { lbl: '거부됨', cls: 'bad', glyph: '\u2715' },
  deferred: { lbl: '보류됨', cls: 'warn', glyph: '\u23F8' },
};

// Gate 처분 모드 — 비계층. 새 외부효과 요청의 기본 처분을 정한다.
const GATE_MODES = [
  ['hitl',   'HITL',            '요청 영속 · operator 결정 (nonblocking)'],
  ['judge',  'LLM Auto Judge',  '설정된 심판 모델이 비동기 판정'],
  ['always', 'Always Allow',    '정확일치 규칙에 맞으면 즉시 통과 · 1회 소비'],
];

// decided_by → 배지
const AP_BY = {
  operator: { lbl: 'operator', glyph: '' },
  judge:    { lbl: 'auto judge', glyph: '⚖' },
  always:   { lbl: 'always', glyph: '✓' },
};

// Always Allow — 활성 정확일치 규칙(exact one-use rule)의 데모 목록.
// 규칙은 (tool · keeper · 범위) 정확일치에만 grant 되고 매칭 시 1회 소비된다.
const GATE_ALWAYS_RULES = [
  { tool: 'tool_read_file',  keeper: 'masc-improver', scope: 'worktree' },
  { tool: 'masc_web_search', keeper: 'scholar',       scope: 'net' },
  { tool: 'keeper_board_post', keeper: 'qa-king',     scope: 'board' },
];

// RFC-0320 — keeper 턴을 촉발한 자극의 출처(origin). 해소 시 keeper 는 (Hitl_resolved wake)
// 그 출처로 재개된다. chat=대화형(그 대화에 회신) · 비-chat=복귀/회신/턴 계속.
const AP_ORIGIN = {
  dashboard: { lbl: '대시보드 챗', glyph: '▤', chat: true,  resume: '대시보드 대화에서 재개' },
  discord:   { lbl: 'Discord', glyph: '◈', chat: true,  resume: 'Discord 채널에서 재개' },
  slack:     { lbl: 'Slack', glyph: '⌗', chat: true,  resume: 'Slack 채널에서 재개' },
  telegram:  { lbl: 'Telegram', glyph: '◂', chat: true,  resume: 'Telegram 채널에서 재개' },
  imessage:  { lbl: 'iMessage', glyph: '◉', chat: true,  resume: 'iMessage 대화에서 재개' },
  schedule:  { lbl: '예약', glyph: '◷', chat: false, resume: '예약 러너로 복귀 (wake signal)' },
  board:     { lbl: '보드', glyph: '▧', chat: false, resume: 'board 에 회신 posting' },
  heartbeat: { lbl: 'heartbeat', glyph: '○', chat: false, resume: '자율 heartbeat 턴 계속' },
};

function ApprovalCard({ a, onResolve, onOpenKeeper, onNav }) {
  const k = apKeeper(a.keeper);
  const kind = (window.APPROVAL_KIND || {})[a.kind] || { lbl: a.kind, glyph: '\u25C8' };
  return (
    <article className="ap-card">
      <div className="ap-rail"></div>
      <div className="ap-main">
        <div className="ap-h">
          <span className="ap-kind">{kind.glyph} {kind.lbl}</span>
          <span className="ap-tool mono">{a.tool}</span>
          <span className="ap-id mono">{a.id}</span>
          {a.origin && AP_ORIGIN[a.origin] && <span className={`ap-origin ${a.origin !== 'dashboard' ? 'remote' : ''}`} title={AP_ORIGIN[a.origin].lbl + ' 에서 청함' + (a.origin !== 'dashboard' ? ' — 해소 시 그 대화로 재개' : '')}>{AP_ORIGIN[a.origin].glyph} {AP_ORIGIN[a.origin].lbl}</span>}
          <span className="ap-age">{apAge(a.opened)}</span>
        </div>
        <h3 className="ap-title">{a.title}</h3>
        <p className="ap-detail">{a.detail}</p>
        <div className="ap-req">
          {k && <SigilBadge k={k} size={26} />}
          <div className="ap-req-body">
            <div className="ap-req-who">
              <button className="ap-klink" onClick={() => onOpenKeeper(a.keeper)} title={`${a.keeper} 대화 열기`}>{a.keeper}</button>
              <span className="ap-req-goal mono" onClick={() => onNav('work')} title="작업 보기">{a.goal}{a.job ? ` · ${a.job}` : ''}</span>
            </div>
            <div className="ap-req-quote">“{a.req}”</div>
          </div>
        </div>
        {a.origin && a.origin !== 'dashboard' && AP_ORIGIN[a.origin] && (
          <div className="ap-cont">{'\u21A9'} 해소되면 <b>{a.keeper}</b> · {AP_ORIGIN[a.origin].resume}</div>
        )}
        <div className="ap-actions">
          <button className="ap-act approve" onClick={() => onResolve(a.id, 'approved')}>승인</button>
          <button className="ap-act deny" onClick={() => onResolve(a.id, 'denied')}>거부</button>
          <button className="ap-act defer" onClick={() => onResolve(a.id, 'deferred')}>보류</button>
          <button className="ap-act ghost" onClick={() => onOpenKeeper(a.keeper)} title="맥락 보기">대화에서 검토 →</button>
        </div>
      </div>
    </article>
  );
}

// 우측 운영 aside — Gate 처분 모드 + Always 규칙 + 지금 상황 + 최근 처리
function ApAside({ mode, setMode, judgeCount, open, deferred, resolved, statusMap, onOpenKeeper }) {
  const recent = [...resolved, ...deferred].slice(0, 6);
  const modeDef = GATE_MODES.find(m => m[0] === mode) || GATE_MODES[0];
  return (
    <aside className="ov-aside">
      <section className="wka-sec">
        <div className="wka-h">Gate 처분 모드</div>
        <div className="wka-auto on">
          <div className="wka-mode wka-mode-3">
            {GATE_MODES.map(([id, lbl]) => (
              <button key={id} className={`wka-mode-b ${mode === id ? 'on' : ''}`} onClick={() => setMode(id)} aria-pressed={mode === id}><b>{lbl}</b></button>
            ))}
          </div>
          <div className="wka-auto-note">{modeDef[2]}</div>
          {mode === 'judge' && judgeCount > 0 && <div className="wka-auto-stat">{judgeCount}건 LLM 판정 처리됨</div>}
          <div className="wka-auto-note dim">세 모드는 비계층(non-hierarchical) — 위험 등급·거부 바닥·직무분리 계층은 없음.</div>
        </div>
      </section>

      {mode === 'always' && (
        <section className="wka-sec">
          <div className="wka-h">Always 규칙 <span className="n mono">{GATE_ALWAYS_RULES.length}</span></div>
          <div className="wka-hint mono">정확일치(tool · keeper · 범위) — 매칭 시 1회 소비</div>
          <div className="wka-list">
            {GATE_ALWAYS_RULES.map((r, i) => (
              <div key={i} className="wka-rule">
                <span className="wka-rule-tool mono">{r.tool}</span>
                <span className="wka-rule-kpr mono">{r.keeper}</span>
                <span className="wka-rule-scope">{r.scope}</span>
              </div>
            ))}
          </div>
        </section>
      )}

      <section className="wka-sec">
        <div className="wka-h">지금 상황 <span className="n mono">{open.length} 열림</span></div>
        <div className="wka-pulse">
          <span className="wka-pulse-i"><b className={`mono ${open.length ? 'warn' : ''}`}>{open.length}</b> 열린 요청</span>
          <span className="wka-pulse-i"><b className="mono">{deferred.length}</b> 보류</span>
          <span className="wka-pulse-i"><b className="mono">{resolved.length}</b> 처리</span>
        </div>
        <div className="wka-calm mono">HITL 은 nonblocking — 대기 중에도 keeper 는 다른 일을 계속합니다.</div>
      </section>

      <section className="wka-sec">
        <div className="wka-h">최근 처리 <span className="n mono">{recent.length}</span></div>
        <div className="wka-list">
          {recent.length === 0
            ? <div className="wka-calm mono">처리된 결재 없음</div>
            : recent.map(a => { const r = AP_RESOLVED[statusMap[a.id]] || AP_RESOLVED.deferred; return (
                <button key={a.id} className="wka-done" onClick={() => onOpenKeeper(a.keeper)}>
                  <span className={`wka-done-mark ${r.cls}`}>{r.glyph}</span>
                  <span className="wka-done-t">{a.title}</span>
                  <span className="wka-done-ns mono">{r.lbl}</span>
                </button>
              ); })}
        </div>
      </section>
    </aside>
  );
}

// Gate 결정 이력 (감사 로그) — 과거 결재 결정을 시간역으로. 필터: 결정·처분자.
function apLatency(sec) {
  if (sec === 0) return '즉시';
  const m = Math.floor(sec / 60), s = sec % 60;
  return m ? `${m}분 ${s}초 만에` : `${s}초 만에`;
}
const AP_HIST_FILTERS = [
  ['all', '전체', () => true],
  ['approved', '승인', (h) => h.decision === 'approved'],
  ['denied', '거부', (h) => h.decision === 'denied'],
  ['deferred', '보류', (h) => h.decision === 'deferred'],
  ['operator', 'HITL 수동', (h) => h.decided_by === 'operator'],
  ['judge', 'Auto Judge', (h) => h.decided_by === 'judge'],
  ['always', 'Always', (h) => h.decided_by === 'always'],
];
function ApHistory({ session }) {
  const [filt, setFilt] = useApS('all');
  const base = window.APPROVAL_HISTORY || [];
  // session-resolved(이번 턴에 operator가 처리한 건)을 이력 맨 위에 병합
  const rows = [...session, ...base];
  const def = AP_HIST_FILTERS.find(f => f[0] === filt) || AP_HIST_FILTERS[0];
  const shown = rows.filter(def[2]);
  const counts = {
    approved: rows.filter(r => r.decision === 'approved').length,
    denied: rows.filter(r => r.decision === 'denied').length,
    judge: rows.filter(r => r.decided_by === 'judge').length,
  };
  const okLat = rows.filter(r => r.decided_by === 'operator' && r.latency_s > 0);
  const medLat = okLat.length ? okLat.map(r => r.latency_s).sort((a, b) => a - b)[Math.floor(okLat.length / 2)] : 0;
  return (
    <div className="ap-hist">
      <div className="ap-hist-summary">
        <div className="ap-hist-stat"><b className="mono ok">{counts.approved}</b> 승인</div>
        <div className="ap-hist-stat"><b className="mono bad">{counts.denied}</b> 거부</div>
        <div className="ap-hist-stat"><b className="mono">{counts.judge}</b> Auto Judge</div>
        <div className="ap-hist-stat"><b className="mono">{apLatency(medLat)}</b> 중간 결정시간</div>
      </div>
      <div className="ap-hist-filters">
        {AP_HIST_FILTERS.map(([id, lbl]) => (
          <button key={id} className={`ap-hist-f ${filt === id ? 'on' : ''}`} onClick={() => setFilt(id)}>{lbl}</button>
        ))}
      </div>
      <div className="ap-hist-list">
        {shown.map(h => {
          const k = apKeeper(h.keeper);
          const r = AP_RESOLVED[h.decision] || AP_RESOLVED.deferred;
          const kind = (window.APPROVAL_KIND || {})[h.kind] || { lbl: h.kind, glyph: '\u25C8' };
          const by = AP_BY[h.decided_by] || AP_BY.operator;
          return (
            <div key={h.id} className={`ap-hist-row dec-${r.cls}`}>
              <span className="ap-hist-at mono">{h.at}</span>
              <span className={`ap-hist-dec ${r.cls}`}>{r.glyph} {r.lbl}</span>
              <div className="ap-hist-body">
                <div className="ap-hist-top">
                  <span className="ap-hist-kind">{kind.glyph} {kind.lbl}</span>
                  <span className="ap-hist-id mono">{h.id}</span>
                  {k && <SigilBadge k={k} size={16} />}
                  <span className="ap-hist-keeper mono">{h.keeper}</span>
                  <span className="ap-hist-tool mono">{h.tool}</span>
                </div>
                <div className="ap-hist-reason">{h.reason}</div>
              </div>
              <span className={`ap-hist-by ${h.decided_by !== 'operator' ? 'auto' : ''}`} title={h.decided_by === 'judge' ? 'LLM Auto Judge' : h.decided_by === 'always' ? 'Always Allow 정확일치 규칙' : 'HITL operator 수동 결재'}>
                {by.glyph ? `${by.glyph} ${by.lbl}` : by.lbl}
                <span className="ap-hist-lat mono">{apLatency(h.latency_s)}</span>
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}

function ApprovalsSurface({ statusMap, onResolve, onOpenKeeper, onNav }) {
  const [view, setView] = useApS('queue');
  const all = window.APPROVALS || [];
  const open = all.filter(a => (statusMap[a.id] || 'open') === 'open');
  const deferred = all.filter(a => statusMap[a.id] === 'deferred');
  const resolved = all.filter(a => statusMap[a.id] === 'approved' || statusMap[a.id] === 'denied');
  // session-resolved → 이력 행 형식으로 매핑(이번 턴 처리를 감사 로그 맨 위에)
  const sessionHist = resolved.map(a => ({
    id: a.id, kind: a.kind, keeper: a.keeper, tool: a.tool,
    at: '지금', decided_by: 'operator', decision: statusMap[a.id], latency_s: 0,
    reason: a.title,
  }));

  // Gate 처분 모드 — LLM Auto Judge 로 전환하면 열린 요청을 심판이 비동기 판정(데모: 자동 승인)
  const [mode, setMode] = useApS('hitl');
  const [judgeCount, setJudgeCount] = useApS(0);
  useApE(() => {
    if (mode !== 'judge') return;
    if (open.length === 0) return;
    const hits = [...open];
    hits.forEach(a => onResolve(a.id, 'approved'));
    setJudgeCount(c => c + hits.length);
    if (window.pushToast) window.pushToast({ tone: 'ok', msg: `${hits.length}건 LLM Auto Judge 처리`, sub: '심판 모델 비동기 판정' });
  }, [mode, open.length]);

  return (
    <main className="ov ov-flush ov-2col" data-screen-label="Gate 큐">
      <div className="ov-scroll">
        <header className="ov-head">
          <div>
            <span className="ov-eyebrow">GATE</span>
            <h1>Gate · 외부 효과 결재</h1>
            <p className="ov-sub">Always Allow · LLM Auto Judge · HITL — 비계층 처분</p>
          </div>
          <div className="ap-viewseg">
            <button className={`ap-viewbtn ${view === 'queue' ? 'on' : ''}`} onClick={() => setView('queue')}>큐{open.length > 0 ? <span className="ap-viewbtn-n mono">{open.length}</span> : null}</button>
            <button className={`ap-viewbtn ${view === 'history' ? 'on' : ''}`} onClick={() => setView('history')}>이력</button>
          </div>
          {view === 'queue' && open.length > 0 && <span className="ap-sla mono" title="가장 오래 대기 중인 건">최장 대기 {apAge(Math.max(...open.map(a => a.opened)))}</span>}
        </header>

        {view === 'history' ? (
          <ApHistory session={sessionHist} />
        ) : (
        <React.Fragment>

        <section className="ov-kpis" style={{ gridTemplateColumns: 'repeat(4, 1fr)' }}>
          <div className="ov-kpi"><div className="ov-kpi-k">열린 요청</div><div className={`ov-kpi-v ${open.length ? 'warn' : 'ok'}`}>{open.length}</div></div>
          <div className="ov-kpi"><div className="ov-kpi-k">보류</div><div className="ov-kpi-v">{deferred.length}</div></div>
          <div className="ov-kpi"><div className="ov-kpi-k">처리 완료</div><div className="ov-kpi-v volt">{resolved.length}</div></div>
          <div className="ov-kpi"><div className="ov-kpi-k">Always 규칙</div><div className="ov-kpi-v">{GATE_ALWAYS_RULES.length}</div></div>
        </section>

        {open.length === 0 && deferred.length === 0 ? (
          <div className="ap-clear">
            <div className="ico">{'\u2713'}</div>
            <h3>열린 요청이 없습니다</h3>
            <div className="ap-clear-sub">Gate 큐가 비어 있습니다 — keeper 들이 결재 대기 없이 진행 중입니다.</div>
          </div>
        ) : (
          <div className="ap-queue">
            {open.map(a => <ApprovalCard key={a.id} a={a} onResolve={onResolve} onOpenKeeper={onOpenKeeper} onNav={onNav} />)}
            {deferred.length > 0 && (
              <React.Fragment>
                <div className="ap-divider"><span>보류 중 · 재검토 대기</span></div>
                {deferred.map(a => <ApprovalCard key={a.id} a={a} onResolve={onResolve} onOpenKeeper={onOpenKeeper} onNav={onNav} />)}
              </React.Fragment>
            )}
          </div>
        )}

        {resolved.length > 0 && (
          <section className="ap-log">
            <div className="ov-card-h"><h3>최근 처리</h3><span className="ov-count" style={{ color: 'var(--text-dim)', background: 'transparent', borderColor: 'var(--border-main)' }}>{resolved.length}</span></div>
            {resolved.map(a => {
              const r = AP_RESOLVED[statusMap[a.id]];
              const k = apKeeper(a.keeper);
              return (
                <div key={a.id} className="ap-log-row">
                  <span className={`ap-log-status ${r.cls}`}>{r.glyph} {r.lbl}</span>
                  <span className="ap-log-id mono">{a.id}</span>
                  {k && <SigilBadge k={k} size={18} />}
                  <span className="ap-log-title">{a.title}</span>
                  <span className="ap-spacer"></span>
                  <button className="ap-log-undo" onClick={() => onResolve(a.id, 'open')}>되돌리기</button>
                </div>
              );
            })}
          </section>
        )}
        </React.Fragment>
        )}
      </div>
      <ApAside mode={mode} setMode={setMode} judgeCount={judgeCount} open={open} deferred={deferred} resolved={resolved} statusMap={statusMap} onOpenKeeper={onOpenKeeper} />
    </main>
  );
}

Object.assign(window, { ApprovalsSurface });
