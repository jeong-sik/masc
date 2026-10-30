/* MASC v2 — Command surface · Actions (2026-08 소스 정합, 2차)
   · command?section=operations           → components/operations-panel.ts
       view = default(All) · ops(Intervene) · gate(Gate/HITL) · inspector
   레거시: command:intervene→operations · command:gate→operations&view=gate ·
           command:inspector→operations&view=inspector
   정식 IA 에서 Command 는 rail 밖 surface 다. Gate view 는 Gate surface 와 같은
   컴포넌트를 재사용하므로 mock 은 중복 렌더 대신 Gate 로 라우팅한다. */
const { useState: useStateCmd } = React;

const CMD_VIEWS = [['default', 'All'], ['ops', 'Intervene'], ['gate', 'Gate / HITL'], ['inspector', 'Inspector']];
const CMD_ROOT = { paused: false, pause_reason: null, paused_by: null };
const CMD_NOT_OBSERVED = [
  { source: 'keeper', name: 'sangsu', kind: 'not_observed' },
  { source: 'persistent_agent', name: 'analyst', kind: 'not_observed' },
];
const CMD_ACTIONS = [
  ['broadcast', '브로드캐스트 · 전체'], ['message', 'keeper 직접 메시지'],
  ['pause', '일시정지'], ['resume', '재개'], ['handoff', '태스크 인계 요청'],
];
const CMD_LOG = [
  { id: 'act-9912', at: '14:34', actor: 'operator', action_type: 'message', target: 'Keeper · masc-improver', outcome: 'confirmed', message: 'scheduler 재진입 패치 먼저 올려주세요' },
  { id: 'act-9911', at: '14:30', actor: 'operator', action_type: 'pause', target: 'Keeper · nick0cave', outcome: 'confirmed', message: '비용 원장 정리 전까지 정지' },
  { id: 'act-9910', at: '14:12', actor: 'operator', action_type: 'broadcast', target: 'Fleet · 실행 중 5', outcome: 'preview', message: '오늘 18:00 배포 창 — 되돌릴 수 없는 작업은 Gate 를 거치세요' },
  { id: 'act-9908', at: '13:51', actor: 'automation', action_type: 'handoff', target: 'Task · task-7741', outcome: 'error', message: '대상 keeper 가 스냅샷에 없음 — 수동으로 대상 지정 필요' },
];
const CMD_TONE = { confirmed: 'ok', preview: 'warn', error: 'bad' };

function CmdOps({ onNav }) {
  const [action, setAction] = useStateCmd('message');
  const [target, setTarget] = useStateCmd('masc-improver');
  const [msg, setMsg] = useStateCmd('');
  const keepers = window.KEEPERS || [];
  const send = () => {
    if (!msg.trim()) return;
    if (window.pushToast) window.pushToast({ tone: 'ok', msg: `${action} 실행`, sub: `${target} · operator action log 에 기록` });
    setMsg('');
  };
  return (
    <div className="cmd-cols">
      <section className="lab-panel">
        <h4>개입 · Intervene</h4>
        <div className="cmd-form">
          <label className="lab-f"><span>action</span>
            <select value={action} onChange={e => setAction(e.target.value)}>{CMD_ACTIONS.map(([id, lbl]) => <option key={id} value={id}>{lbl}</option>)}</select>
          </label>
          <label className="lab-f"><span>target</span>
            <select value={target} onChange={e => setTarget(e.target.value)}>
              <option value="fleet">Fleet · 전체</option>
              {keepers.map(k => <option key={k.id} value={k.id}>{k.id}</option>)}
            </select>
          </label>
          <textarea className="cmd-text" rows={4} placeholder="대상에게 전달할 내용…" value={msg} onChange={e => setMsg(e.target.value)}></textarea>
          <div className="cmd-actions">
            <button className="lab-run" disabled={!msg.trim()} onClick={send}>실행</button>
            <span className="mono dim">되돌릴 수 없는 행동 지시는 Gate 로 라우팅됩니다</span>
          </div>
        </div>
      </section>
      <section className="lab-panel">
        <h4>최근 operator 활동</h4>
        <p className="ia-note">개입과 검토 결과가 최신순으로 남습니다. Gate/HITL 요청은 Gate view 에 있습니다. 3일 이전 기록은 이 타임라인에서 사라집니다.</p>
        <div className="cmd-log">
          {CMD_LOG.map(e => (
            <article key={e.id} className="cmd-log-row">
              <div className="cmd-log-h">
                <span className={`ai-b ${CMD_TONE[e.outcome] === 'ok' ? 'ok' : CMD_TONE[e.outcome] === 'bad' ? 'bad' : ''}`}>{e.action_type}</span>
                <span className="mono dim">{e.target}</span>
                <span className="mono dim">{e.actor}</span>
                <span className="mono dim">{e.at}</span>
              </div>
              <div className="cmd-log-b">{e.message}</div>
            </article>
          ))}
        </div>
      </section>
    </div>
  );
}

function CommandSurface({ onNav, openApprovals }) {
  const [view, setView] = useStateCmd('default');
  return (
    <div className="fl-shell">
      <div className="fl-top">
        <div className="fl-brand">
          <span className="ov-eyebrow">비 rail surface · route 접근</span>
          <span className="fl-title">Command · Actions</span>
        </div>
        <div className="fl-health">
          <span className={`fl-hpill ${CMD_ROOT.paused ? 'warn' : 'ok'}`}>namespace {CMD_ROOT.paused ? '일시정지' : '가동'}</span>
          {openApprovals > 0 && <span className="fl-hpill warn">Gate 대기 {openApprovals}</span>}
        </div>
        <div className="fl-spacer"></div>
        <div className="fl-meta">
          <span className="mono">command?section=operations{view === 'default' ? '' : `&view=${view}`}</span>
          <span>{window.FL_VERSION || ''}</span>
        </div>
      </div>
      <div className="fl-secs">
        {CMD_VIEWS.map(([id, lbl]) => (
          <button key={id} className={`fl-sec ${view === id ? 'on' : ''}`} onClick={() => setView(id)}>{lbl}</button>
        ))}
      </div>

      <div className="ia-wrap">
        <p className="ia-lede">브로드캐스트 · keeper 메시지 · Gate/HITL · 인스펙터 컨트롤이 모이는 운영 표면입니다. 개입은 모두 operator action log 에 남고, 결과는 <span className="mono">confirmed · preview · error</span> 세 상태로 표시됩니다.</p>

        {CMD_NOT_OBSERVED.length > 0 && (
          <div className="cmd-banner">
            <b>Context metrics unavailable</b>
            <ul>
              {CMD_NOT_OBSERVED.map(d => (
                <li key={d.name}><span className="mono">{d.source === 'keeper' ? 'Keeper' : 'Persistent agent'} {d.name}</span> — context measurement <span className="mono">not_observed</span></li>
              ))}
            </ul>
            <span className="mono dim">스냅샷은 occupancy 를 관측하지 않습니다 — 잘못된 kind/reason 은 별도 진단으로 표시됩니다.</span>
          </div>
        )}

        {(view === 'default' || view === 'ops') && <CmdOps onNav={onNav} />}

        {(view === 'default' || view === 'gate') && (
          <section className="lab-panel">
            <h4>Gate / HITL</h4>
            <p className="ia-note">이 view 는 Gate surface 와 같은 컴포넌트입니다. 비계층 3모드(Always Allow · LLM Auto Judge · HITL)와 exact Always 규칙은 Gate 에서 관리합니다.</p>
            <div className="cmd-gatelinks">
              <button className="tm-lane" onClick={() => onNav && onNav('approvals')}>
                <span className="tm-lane-t">Gate 열기{openApprovals > 0 ? ` · 대기 ${openApprovals}` : ''}</span>
                <span className="tm-lane-m">approvals · nonblocking HITL 큐 + exact Always 규칙</span>
                <span className="tm-lane-o mono">Open</span>
              </button>
            </div>
          </section>
        )}

        {view === 'inspector' && (
          <section className="lab-panel">
            <h4>Inspector</h4>
            <p className="ia-note">턴 단위 프롬프트 · 도구 · 판정 증거를 여는 인스펙터입니다. mock 에서는 Keepers 대화의 메시지에서 턴 인스펙터를 직접 열도록 두었습니다 — 같은 turn record 를 씁니다.</p>
            <div className="cmd-gatelinks">
              <button className="tm-lane" onClick={() => onNav && onNav('keepers')}>
                <span className="tm-lane-t">Keepers 대화 열기</span>
                <span className="tm-lane-m">메시지 → 턴 인스펙터 · 프롬프트/도구/판정</span>
                <span className="tm-lane-o mono">Open</span>
              </button>
            </div>
          </section>
        )}
      </div>
    </div>
  );
}

Object.assign(window, { CommandSurface });
