/* MASC v2 — Keeper Fleet (monitoring / agents) surface.
   Improved roster: tone-rail per row, real varied phase chips, context
   pressure, hover-only actions, attention-first sort, slim detail aside. */
const { useState: useStateFl, useMemo: useMemoFl, useEffect: useEffectFl } = React;

// keeper identity badge: color slot + 2-letter sigil (keeper-badge.ts).
// Defined locally so this surface only needs primitives.jsx + data.jsx.
function SigilBadge({ k, size = 18, beat }) {
  return React.createElement(window.KV.Sigil, { slot: k.slot, size, heartbeat: beat, title: k.id, fontScale: 0.46 }, k.sigil);
}

// path into the conversation console — deep-links the chat app to this keeper
const CHAT_HREF = (k) => `Keeper Agent v2.html?keeper=${encodeURIComponent(k.id)}`;
const ChatGlyph = ({ s = 14 }) => (
  <svg viewBox="0 0 24 24" width={s} height={s} fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
    <path d="M4 5.5h16v10H9.5L5 19v-3.5H4z" /><path d="M8.5 10.2h7M8.5 13h4.5" />
  </svg>
);

// Attention reasons come from the canonical store (data.jsx → window.ATTENTION)
// so Fleet, the chat context rail and the topbar indicator never drift.
const FL_ATTN_LIST = (id) => (window.ATTENTION || {})[id] || [];
const FL_ATTN_TOP = (id) => {
  const list = FL_ATTN_LIST(id);
  if (!list.length) return null;
  return (list.find(a => a.sev === 'bad') || list[0]).text;
};
const FL_VERSION = 'v0.23.0';

// provider 가 보고한 마지막 턴 usage. 현재 점유율(occupancy) 은 소스에서 관측되지
// 않으므로(typed not_observed) 게이지·임계선 없이 이 값만 표기한다.
function flUsage(k) {
  const u = window.KEEPER_MEMORY && window.KEEPER_MEMORY[k.id] && window.KEEPER_MEMORY[k.id].usage;
  if (u && u.input_tokens) return u;
  if (k.status === 'off' || !k.ctx) return null;
  return { input_tokens: Math.round(k.ctx * 200000), context_window: 200000 };
}
const flTok = (n) => (n / 1000).toFixed(1) + 'k';

const FL_TONE_LABEL = { ok: '실행', warn: '대기', bad: '주의', busy: '전이', idle: '정지' };

function phaseTone(phase) { return PHASE_TONE[phase] || 'idle'; }

// global nav rail — shared with the main app (Keeper Agent v2.html).
// Items cross-link into the SPA surfaces; Monitor is this page (active).
const FN_ICON = {
  grid: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7"><rect x="3" y="3" width="7" height="7" rx="1.4"/><rect x="14" y="3" width="7" height="7" rx="1.4"/><rect x="3" y="14" width="7" height="7" rx="1.4"/><rect x="14" y="14" width="7" height="7" rx="1.4"/></svg>),
  target: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="4"/><circle cx="12" cy="12" r="0.6" fill="currentColor"/></svg>),
  users: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><circle cx="9" cy="8" r="3.2"/><path d="M3.5 19c0-3 2.6-5 5.5-5s5.5 2 5.5 5"/><path d="M16.5 6.2a3 3 0 0 1 0 5.6"/><path d="M18.5 19c0-2-.8-3.6-2-4.6"/></svg>),
  monitor: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M3 12h3.5l2-6 4 13 2.2-7H21"/></svg>),
  logs: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M4 6h10M4 10h16M4 14h13M4 18h9"/></svg>),
  board: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinejoin="round"><rect x="3" y="4" width="5" height="16" rx="1.2"/><rect x="10" y="4" width="5" height="11" rx="1.2"/><rect x="17" y="4" width="4" height="14" rx="1.2"/></svg>),
  code: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M8 6l-5 6 5 6"/><path d="M16 6l5 6-5 6"/><path d="M13.5 4l-3 16"/></svg>),
  plug: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><path d="M9 3v5M15 3v5"/><path d="M6 8h12v3a6 6 0 0 1-12 0z"/><path d="M12 17v4"/></svg>),
  gear: (<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="3"/><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.1 5.1l2.1 2.1M16.8 16.8l2.1 2.1M18.9 5.1l-2.1 2.1M7.2 16.8l-2.1 2.1"/></svg>),
};
const FN_APP = 'Keeper Agent v2.html';
const FN_ITEMS = [
  ['overview', '개요', FN_ICON.grid, `${FN_APP}?surface=overview`],
  ['work', '작업', FN_ICON.target, `${FN_APP}?surface=work`],
  ['keepers', 'Keepers', FN_ICON.users, `${FN_APP}?surface=keepers`],
  ['monitor', 'Monitor', FN_ICON.monitor, null],
  ['logs', '로그', FN_ICON.logs, `${FN_APP}?surface=logs`],
  ['board', '보드', FN_ICON.board, `${FN_APP}?surface=board`],
  ['ide', 'IDE', FN_ICON.code, `${FN_APP}?surface=ide`],
  ['connectors', '커넥터', FN_ICON.plug, `${FN_APP}?surface=connectors`],
];
function FleetNav() {
  return (
    <nav className="v2-nav">
      <a className="nav-brand" href={FN_APP} title="MASC — Multi-Agent Streaming Coordination" style={{ textDecoration: 'none' }}>
        <div className="nav-home">M</div>
        <span className="nlbl">MASC</span>
      </a>
      {FN_ITEMS.map(([id, lbl, ic, href]) => (
        href
          ? <a key={id} className="nav-item" href={href} title={lbl}>{ic}<span className="nlbl">{lbl}</span></a>
          : <span key={id} className="nav-item on" title={lbl} aria-current="page">{ic}<span className="nlbl">{lbl}</span></span>
      ))}
      <div className="nav-spacer"></div>
      <a className="nav-item" href={FN_APP} title="설정">{FN_ICON.gear}<span className="nlbl">설정</span></a>
    </nav>
  );
}

function FleetRow({ k, selected, onSelect, onAction }) {
  const tone = phaseTone(k.phase);
  const usage = flUsage(k);
  const acts = (FSM_ACTIONS[k.phase] || []).slice(0, 3);
  return (
    <div className={`fl-row ${selected ? 'sel' : ''}`} data-tone={tone} onClick={() => onSelect(k.id)} role="button" tabIndex={0}>
      <div className="fl-id">
        <SigilBadge k={k} size={30} beat={PHASE_PULSE[k.phase]} />
        <div className="fl-id-txt">
          <div className="fl-name">
            <b>{k.id}</b>
            {k.att > 0 && <span className="fl-att">▲ {k.att}</span>}
          </div>
          {k.cwd && <div className="fl-ns" title="이 keeper 전용 작업 폴더 — git worktree 로 갈라 놔서 다른 keeper 와 파일이 섞이지 않습니다 (OS·컨테이너 샌드박스는 아님)"><span className="fl-sandbox">⬡</span>{k.cwd}</div>}
        </div>
      </div>

      <div className="fl-state">
        <span className="fl-chip" data-tone={tone}><Dot state={tone} pulse={PHASE_PULSE[k.phase]} />{k.phase}</span>
        <span className="fl-gloss">{FL_ATTN_TOP(k.id) || (PHASE_INFO[k.phase] || '')}</span>
      </div>

      <div className="fl-ctx">
        {usage
          ? <span className="fl-ctx-val mono" title="마지막 턴에 쓴 입력 토큰 · 지금 쓰는 양은 알 수 없음 (not_observed)">{flTok(usage.input_tokens)} <i className="fl-ctx-win">/ {flTok(usage.context_window)}</i></span>
          : <span className="fl-ctx-val zero mono" title="이 keeper 는 아직 쓴 기록이 없음 (not_observed)">알 수 없음</span>}
      </div>

      <div className={`fl-tool ${k.lastTool ? '' : 'none'}`}>{k.lastTool || '—'}</div>

      <div className="fl-actcell" onClick={(e) => e.stopPropagation()}>
        <div className="fl-actions">
          {acts.length ? acts.map(a => (
            <button key={a.id} className={`fl-act ${a.danger ? 'danger' : ''}`} title={a.label} onClick={() => onAction(k.id, a)}>{a.glyph}</button>
          )) : null}
        </div>
        <a className="fl-chat" href={CHAT_HREF(k)} title={`${k.id} 대화 콘솔 열기`}><ChatGlyph s={13} /></a>
      </div>
    </div>
  );
}

// per-keeper event queue + heartbeat poll (Keeper_event_queue + wake cadence)
function AsideQueue({ k }) {
  const q = window.keeperQueue ? window.keeperQueue(k.id) : null;
  const EK = window.EVENT_KIND || {};
  const draining = k.phase === 'Draining';
  const list = q ? (draining ? (q.draining || []) : (q.pending || [])) : [];
  if (!q && k.hb == null) return null;
  return (
    <div className="fl-as-sec">
      <h4>{draining ? '드레인 대기' : '들어온 이벤트'}</h4>
      <div className="fl-q">
        {q && (
          <div className="fl-q-acct">
            <span className="fl-q-c ok"><b>{q.admitted}</b> 받음</span>
            <span className="fl-q-c"><b>{q.deferred}</b> 미룸</span>
            <span className="fl-q-c dim"><b>{q.dropped}</b> 버림</span>
          </div>
        )}
        {list.length > 0 && (
          <div className="fl-q-list">
            {list.map((e, i) => { const m = EK[e.kind] || { lbl: e.kind, glyph: '\u00B7' }; return (
              <div key={i} className={`fl-q-item ${draining ? 'drain' : ''}`}>
                <span className="fl-q-gl mono">{m.glyph}</span>
                <span className="fl-q-kind mono">{m.lbl}</span>
                <span className="fl-q-from">{e.from}</span>
                <span className="fl-q-at mono">{e.at}</span>
              </div>
            ); })}
          </div>
        )}
        {k.hb != null
          ? <div className="fl-q-hb"><span className="fl-q-hb-dot"></span>{k.hb}초마다 깨어남 · 다음 ~{k.hbNext}초</div>
          : <div className="fl-q-hb off">깨어나지 않음 · {k.phase}</div>}
      </div>
    </div>
  );
}

// per-keeper provider rotation candidates + failover events touching this keeper
function AsideRotation({ k }) {
  const rot = window.rotationForRuntime ? window.rotationForRuntime(k.runtime) : null;
  const evs = (window.ROTATION_EVENTS || []).filter(e => e.keeper === k.id);
  if (!rot && evs.length === 0) return null;
  return (
    <div className="fl-as-sec">
      <h4>런타임 후보 <span className="fl-as-tag bad" title="자동 전환은 구현되어 있지 않습니다">수동 전환</span></h4>
      {rot ? (
        <div className="fl-rot">
          <div className="fl-rot-chain">
            {rot.order.map((id, i) => (
              <React.Fragment key={id}>
                {i > 0 && <span className="fl-rot-arr">→</span>}
                <span className={`fl-rot-cand mono ${i === 0 ? 'head' : ''} ${id === k.runtime ? 'cur' : ''}`}>{id}</span>
              </React.Fragment>
            ))}
          </div>
          <div className="fl-rot-note mono">공급자가 죽으면 자동으로 안 넘어갑니다 — runtime.toml 을 고치고 재시작해야 합니다. 턴 중에 난 일시적 오류만 {rot.expand_on_transient ? '다른 후보까지 넓혀' : '같은 후보로'} 재시도합니다.</div>
        </div>
      ) : <div className="fl-rot-na">이 런타임은 기본 후보 순서를 따릅니다.</div>}
      {evs.map((e, i) => (
        <div key={i} className={`fl-rot-ev ${e.outcome}`}>
          <span className="fl-rot-ev-out">{e.outcome === 'recovered' ? '\u21BB' : '\u26A0'}</span>
          <span className="fl-rot-ev-t">{e.at} · {e.reason === 'capacity_backpressure' ? '붐빔' : e.reason}{e.to && e.to !== e.from ? ` → ${e.to.split('.')[1]} (턴 내 재시도)` : e.outcome === 'backpressure' ? ' · 표시만 됨 (자동으로 멈추지 않음)' : ''}</span>
        </div>
      ))}
    </div>
  );
}

// fleet-wide admission — WFQ over runtime slots, with capacity_backpressure
function FleetLanes() {
  const lanes = window.ADMISSION_LANES || [];
  const sum = window.admissionSummary ? window.admissionSummary() : { active: 0, waiting: 0, slots: 0, backpressure: 0 };
  const [open, setOpen] = useStateFl(true);
  return (
    <div className={`fl-lanes ${open ? 'open' : ''}`}>
      <button className="fl-lanes-h" onClick={() => setOpen(o => !o)}>
        <span className="fl-lanes-t">실행 슬롯</span>
        <span className="fl-lanes-sum mono" title="WFQ — 런타임별 가중 공정 큐로 슬롯을 배분">{sum.slots}개 중 {sum.active}개 실행 · {sum.waiting} 대기</span>
        {sum.backpressure > 0 && <span className="fl-lanes-bp" title="대기가 길어졌다는 표시 (capacity_backpressure) — 실행을 막지는 않습니다">{'\u26A0'} 붐빔 {sum.backpressure}</span>}
        <span className="fl-lanes-spacer"></span>
        <span className="fl-lanes-chev">{open ? '\u25BE' : '\u25B8'}</span>
      </button>
      {open && (
        <div className="fl-lanes-row">
          <div className="fl-lanes-note" title="capacity_backpressure">‘붐빔’은 대기가 길어졌다는 표시입니다 — 새 실행은 그대로 받습니다</div>
          {lanes.map(l => {
            const pctA = Math.min(100, l.active / Math.max(l.slots, 1) * 100);
            const pctW = Math.min(100, l.waiting / Math.max(l.slots, 1) * 100);
            return (
              <div key={l.id} className={`fl-lane ${l.backpressure ? 'bp' : ''}`}>
                <div className="fl-lane-top"><span className="fl-lane-lbl">{l.label}</span><span className="fl-lane-w mono" title="이 런타임에 주는 몫 (WFQ 가중치)">몫 {l.weight}</span></div>
                <div className="fl-lane-id mono">{l.id}</div>
                <div className="fl-lane-bar" title={`${l.active} 실행 · ${l.waiting} 대기 · ${l.slots} 슬롯`}>
                  <span className="fl-lane-active" style={{ width: pctA + '%' }}></span>
                  <span className="fl-lane-wait" style={{ width: pctW + '%' }}></span>
                </div>
                <div className="fl-lane-foot">
                  <span className="mono">{l.active}/{l.slots}</span>
                  <span className={`fl-lane-waiting mono ${l.waiting ? 'on' : ''}`}>{l.waiting} 대기</span>
                  {l.backpressure ? <span className="fl-lane-bpf mono" title="capacity_backpressure · 대기 시간 p95">붐빔 · 대기 {(l.wait_p95 / 1000).toFixed(1)}s</span> : <span className="fl-lane-okf mono">여유</span>}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

function FleetAside({ k, onAction }) {
  if (!k) return <aside className="fl-aside"></aside>;
  const tone = phaseTone(k.phase);
  const usage = flUsage(k);
  const acts = FSM_ACTIONS[k.phase] || [];
  const tools = (k.tools && k.tools.length ? k.tools : [k.lastTool].filter(Boolean));
  return (
    <aside className="fl-aside">
      <div className="fl-as-head">
        <span className="fl-as-ey">선택한 keeper</span>
        <span className="fl-as-state"><Dot state={tone} pulse={PHASE_PULSE[k.phase]} />{FL_TONE_LABEL[tone]}</span>
      </div>
      <div className="fl-as-id">
        <SigilBadge k={k} size={46} beat={PHASE_PULSE[k.phase]} />
        <div>
          <div className="fl-as-name">{k.id}</div>
          <div className="fl-as-kr">{k.kr}</div>
          <div className="fl-as-runtime mono" title="바인딩된 런타임">{k.runtime && k.runtime !== '—' ? k.runtime : k.model}</div>
        </div>
      </div>

      <div className="fl-as-cta">
        <a className="fl-open-chat" href={CHAT_HREF(k)}>
          <ChatGlyph s={15} /><span>대화 콘솔 열기</span><span className="arr">▸</span>
        </a>
      </div>

      <div className="fl-as-sec">
        <div className="fl-as-phase">
          <span className="fl-chip" data-tone={tone}><Dot state={tone} pulse={PHASE_PULSE[k.phase]} />{k.phase}</span>
        </div>
        <div className="fl-as-gloss">{FL_ATTN_TOP(k.id) || (PHASE_INFO[k.phase] || '')}</div>
      </div>

      {FL_ATTN_LIST(k.id).length > 0 && (
        <div className="fl-as-sec">
          <h4>주의 · {FL_ATTN_LIST(k.id).length}</h4>
          <div className="fl-attn-list">
            {FL_ATTN_LIST(k.id).map((a, i) => (
              <div key={i} className="fl-attn-item" data-sev={a.sev}><span className="fl-attn-dot"></span>{a.text}</div>
            ))}
          </div>
        </div>
      )}

      <div className="fl-as-sec">
        <h4>컨텍스트</h4>
        <div className="fl-ctxbig">
          <div className="fl-ctxbig-top"><span className="v">{usage ? flTok(usage.input_tokens) : '—'}</span><span className="l">마지막 턴 입력 토큰</span></div>
          <div className="fl-notobs">지금 쓰는 양은 <b>알 수 없음</b> — 마지막 턴 기준입니다</div>
        </div>
      </div>

      <div className="fl-as-sec">
        <h4>활동</h4>
        <div className="fl-as-mini">
          <div className="fl-mini"><span className="k">초당 토큰</span><span className="v">{k.tps}</span></div>
          <div className="fl-mini"><span className="k">트레이스</span><span className="v">{k.traces}</span></div>
          <div className="fl-mini"><span className="k">맡은 작업</span><span className="v">{k.tasks}</span></div>
        </div>
      </div>

      <AsideQueue k={k} />
      <AsideRotation k={k} />

      {tools.length > 0 && (
        <div className="fl-as-sec">
          <h4>최근 도구</h4>
          <div className="fl-tools">
            {tools.map((t, i) => <div key={i} className="fl-toolrow">{t}</div>)}
          </div>
        </div>
      )}

      <div className="fl-as-sec">
        <h4>액션</h4>
        {acts.length ? (
          <div className="fl-actbar">
            {acts.map(a => (
              <button key={a.id} className={`fl-btn ${a.danger ? 'danger' : ''}`} onClick={() => onAction(k.id, a)} title={a.hint}>
                <span className="g">{a.glyph}</span>{a.label}
              </button>
            ))}
          </div>
        ) : <div className="fl-noact">이 단계에서는 할 수 있는 조작이 없습니다.</div>}
      </div>
    </aside>
  );
}

// Persona library modal — the persona feature lives in Fleet now (operator manages
// personas + casts keepers where the fleet is watched). Reuses reg-* dialog styles
// and the registry's RegPersonaEditor for the actual add/edit form.
function FleetPersonaLib({ personas, onSave, onDelete, onClose }) {
  const [edit, setEdit] = useStateFl(null);   // {} = new · persona = edit
  useEffectFl(() => {
    const onKey = (e) => { if (e.key === 'Escape' && !edit) { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [edit]);
  return (
    <React.Fragment>
      <div className="reg-overlay" onClick={onClose}>
        <div className="reg-dialog" style={{ maxWidth: 560 }} onClick={e => e.stopPropagation()}>
          <div className="reg-dlg-h idea">
            <span className="rd-layer"></span>
            <div><span className="rd-eyebrow">AGENT.md</span><h3>프롬프트 파일</h3></div>
            <button className="reg-dlg-x" onClick={onClose} title="닫기 (Esc)">✕</button>
          </div>
          <div className="reg-dlg-body">
            <div className="reg-panel-note">keeper 프롬프트는 <code>keepers/&lt;name&gt;/AGENT.md</code> 한 장입니다. 여러 keeper 가 같은 파일을 참조할 수 있고, 고치면 참조하는 keeper 전부에 반영됩니다.</div>
            <div className="reg-personas">
              {personas.map(p => (
                <div key={p.id} className="reg-persona">
                  <div className="rp-main">
                    <div className="rp-name-row"><span className="rp-name">{p.name}</span><span className="rp-path mono">keepers/{p.id.replace(/^p-/, '')}/AGENT.md</span></div>
                    <p className="rp-desc">{p.desc}</p>
                    <div className="rp-traits">{(p.traits || []).map(t => <span key={t} className="rp-trait">{t}</span>)}</div>
                    <div className="rp-foot">
                      <span className="rp-foot-spacer"></span>
                      <button className="rp-act" onClick={() => setEdit(p)}>수정</button>
                      <button className="rp-act danger" onClick={() => onDelete(p)}>삭제</button>
                    </div>
                  </div>
                </div>
              ))}
              {!personas.length && <div className="reg-empty">프롬프트 파일이 없습니다. 새로 추가하세요.</div>}
            </div>
          </div>
          <div className="reg-dlg-foot">
            <span className="rf-spacer"></span>
            <button className="reg-btn" onClick={onClose}>닫기</button>
            <button className="reg-btn primary" onClick={() => setEdit({})}>＋ 새 프롬프트 파일</button>
          </div>
        </div>
      </div>
      {edit && window.RegPersonaEditor &&
        <window.RegPersonaEditor initial={edit.id ? edit : null} onClose={() => setEdit(null)}
          onSave={(p, isNew) => { onSave(p, isNew); setEdit(null); }} />}
    </React.Fragment>
  );
}

function FleetSurface() {
  // seed each keeper with a recent tool + small tool history for signal
  const seed = useMemoFl(() => {
    const pool = ['keeper_board_list', 'keeper_tasks_list', 'keeper_board_get', 'keeper_board_comment', 'keeper_context_status', 'keeper_broadcast', 'masc_status', 'tool_execute'];
    return KEEPERS.map((k, i) => ({
      ...k,
      lastTool: k.status === 'off' ? null : pool[i % pool.length],
      tools: k.status === 'off' ? [] : [pool[i % pool.length], pool[(i + 3) % pool.length], pool[(i + 5) % pool.length]],
    }));
  }, []);

  const [fleet, setFleet] = useStateFl(seed);
  const [sel, setSel] = useStateFl(null);
  const [sec, setSec] = useStateFl('agents');   // monitoring 섹션: agents · internal-agents · (lab)audit-integrity

  // persona + keeper creation now lives here (moved from Registry).
  const [personas, setPersonas] = useStateFl(() => (window.REG_PERSONAS || []).map(p => ({ ...p, traits: [...(p.traits || [])] })));
  const [wizard, setWizard] = useStateFl(false);
  const [personaLib, setPersonaLib] = useStateFl(false);
  const usedSlots = useMemoFl(() => new Set(fleet.map(k => k.slot)), [fleet]);
  const createKeeper = (k) => {
    setFleet(prev => prev.some(x => x.id === k.id) ? prev : [...prev, { ...k, lastTool: null, tools: [] }]);
    setWizard(false);
    setSel(k.id);
    if (window.pushToast) window.pushToast({ tone: 'ok', msg: `keeper 만들어짐 · ${k.id}`, sub: 'Stopped · 시작 누르면 기동합니다' });
  };
  const savePersona = (p, isNew) => {
    setPersonas(prev => isNew ? [...prev, p] : prev.map(x => x.id === p.id ? p : x));
    if (window.pushToast) window.pushToast({ tone: 'ok', msg: isNew ? '프롬프트 파일 추가됨' : '프롬프트 파일 저장됨', sub: p.name });
  };
  const deletePersona = (p) => {
    setPersonas(prev => prev.filter(x => x.id !== p.id));
    if (window.pushToast) window.pushToast({ tone: 'warn', msg: '프롬프트 파일 삭제됨', sub: p.name, undo: () => setPersonas(prev => prev.some(x => x.id === p.id) ? prev : [...prev, p]) });
  };

  // sort: attention desc → context pressure desc → running first → name
  const rows = useMemoFl(() => {
    const order = { run: 0, pause: 1, off: 2 };
    return fleet.slice().sort((a, b) =>
      (b.att - a.att) || (b.ctx - a.ctx) || (order[phaseStatus(a.phase)] - order[phaseStatus(b.phase)]) || a.id.localeCompare(b.id)
    );
  }, [fleet]);

  const attnRows = rows.filter(k => k.att > 0);
  const steadyRows = rows.filter(k => k.att === 0);

  const selId = sel || (attnRows[0] && attnRows[0].id) || (rows[0] && rows[0].id);
  const selKeeper = fleet.find(k => k.id === selId);

  const stats = useMemoFl(() => ({
    run: fleet.filter(k => phaseStatus(k.phase) === 'run').length,
    pause: fleet.filter(k => phaseStatus(k.phase) === 'pause').length,
    off: fleet.filter(k => phaseStatus(k.phase) === 'off').length,
    att: fleet.reduce((a, k) => a + (k.att > 0 ? 1 : 0), 0),
    hot: fleet.filter(k => k.ctx >= 0.85).length,
    total: fleet.length,
  }), [fleet]);

  // FSM action: apply transient `via` phase, then settle to `to`
  function runAction(id, a) {
    const settle = (phase) => setFleet(f => f.map(k => k.id === id ? { ...k, phase, att: 0 } : k));
    if (a.via && a.ms) {
      setFleet(f => f.map(k => k.id === id ? { ...k, phase: a.via } : k));
      setTimeout(() => settle(a.to), a.ms);
    } else {
      settle(a.to);
    }
    setSel(id);
  }

  return (
      <div className="fl-shell">
      <div className="fl-top">
        <div className="fl-brand">
          <span className="fl-title">Keeper 모니터</span>
        </div>
        <div className="fl-health">
          <span className="fl-hpill ok">런타임 가동 <b>{stats.run}</b></span>
          <span className="fl-hpill warn">일시정지 <b>{stats.pause}</b></span>
          <span className="fl-hpill">오프라인 <b>{stats.off}</b></span>
          {stats.att > 0 && <span className="fl-hpill bad">주의 <b>{stats.att}</b></span>}
        </div>
        <div className="fl-spacer"></div>
        <div className="fl-top-actions">
          <button className="fl-top-btn" onClick={() => setPersonaLib(true)} title="프롬프트 파일 (AGENT.md)">프롬프트</button>
          <button className="fl-top-btn primary" onClick={() => setWizard(true)} title="프롬프트 파일로 새 keeper 만들기">＋ 새 Keeper</button>
        </div>
        <div className="fl-meta">
          <span><span className="live">●</span> 실시간 연결됨</span>
          <span>{FL_VERSION}</span>
        </div>
      </div>

      <div className="fl-secs">
        <button className={`fl-sec ${sec === 'agents' ? 'on' : ''}`} onClick={() => setSec('agents')}>Keeper 목록</button>
        <button className={`fl-sec ${sec === 'internal' ? 'on' : ''}`} onClick={() => setSec('internal')}>내부 에이전트</button>
        <button className={`fl-sec ${sec === 'lanes' ? 'on' : ''}`} onClick={() => setSec('lanes')}>실행 슬롯 · 대기</button>
        <button className={`fl-sec ${sec === 'journey' ? 'on' : ''}`} onClick={() => setSec('journey')}>턴 진행</button>
        <button className={`fl-sec ${sec === 'tools' ? 'on' : ''}`} onClick={() => setSec('tools')}>도구 실행</button>
        <button className={`fl-sec ${sec === 'runtime' ? 'on' : ''}`} onClick={() => setSec('runtime')}>비용 원장</button>
        <button className={`fl-sec ${sec === 'observatory' ? 'on' : ''}`} onClick={() => setSec('observatory')}>관측</button>
      </div>

      {sec === 'internal' && window.InternalAgentsPanel && <window.InternalAgentsPanel />}
      {sec === 'lanes' && window.LaneQueuePanel && <window.LaneQueuePanel />}
      {sec === 'journey' && window.JourneyPanel && <window.JourneyPanel />}
      {sec === 'tools' && window.ToolMonitorPanel && <window.ToolMonitorPanel />}
      {sec === 'observatory' && window.ObservatoryPanel && <window.ObservatoryPanel />}
      {sec === 'runtime' && window.CostLedgerPanel && <window.CostLedgerPanel />}

      {sec === 'agents' && <React.Fragment>
      <FleetLanes />

      <div className="fl-body">
        <div className="fl-main">
          <div className="fl-rhead">
            <span>Keeper</span>
            <span>상태 · 단계</span>
            <span>마지막 턴 입력</span>
            <span>최근 도구</span>
            <span className="r">액션</span>
          </div>
          <div className="fl-roster">
            {attnRows.length > 0 && <div className="fl-group attn">주의 필요 · {attnRows.length}</div>}
            {attnRows.map(k => <FleetRow key={k.id} k={k} selected={k.id === selId} onSelect={setSel} onAction={runAction} />)}
            {steadyRows.length > 0 && <div className="fl-group">정상 · {steadyRows.length}</div>}
            {steadyRows.map(k => <FleetRow key={k.id} k={k} selected={k.id === selId} onSelect={setSel} onAction={runAction} />)}
          </div>
        </div>
        <FleetAside k={selKeeper} onAction={runAction} />
      </div>
      </React.Fragment>}

      <div className="fl-foot">
        <span className="fl-tick"><span className="k">가동</span><span className="v">{stats.run} / {stats.total}</span></span>
        <span className="fl-tick"><span className="k">실행 대기</span><span className={`v ${(window.admissionSummary && window.admissionSummary().waiting) ? 'warn' : 'ok'}`}>{window.admissionSummary ? window.admissionSummary().waiting : 0}</span></span>
        <span className="fl-tick"><span className="k">주의</span><span className={`v ${stats.att ? 'warn' : 'ok'}`}>{stats.att}</span></span>
      </div>

      {wizard && window.RegKeeperWizard &&
        <window.RegKeeperWizard personas={personas} usedSlots={usedSlots} onClose={() => setWizard(false)} onCreate={createKeeper} />}
      {personaLib &&
        <FleetPersonaLib personas={personas} onSave={savePersona} onDelete={deletePersona} onClose={() => setPersonaLib(false)} />}
      </div>
  );
}

// Standalone shell — the separate Keeper Fleet.html page wraps the surface
// with its own global nav rail. Inside the SPA, app.jsx renders <FleetSurface/>
// directly into the Monitor surface slot (NavRail already provided by the app).
function KeeperFleet() {
  return (
    <div className="v2-app fl-root">
      <FleetNav />
      <FleetSurface />
    </div>
  );
}

Object.assign(window, { FleetSurface, KeeperFleet });

// Only auto-mount on the dedicated standalone page; in the SPA the app owns the root.
if (document.documentElement.dataset.fleet === 'standalone') {
  ReactDOM.createRoot(document.getElementById('root')).render(React.createElement(KeeperFleet));
}
