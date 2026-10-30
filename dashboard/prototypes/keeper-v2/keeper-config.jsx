/* MASC v2 — Keeper 상세 설정: 풀스크린 surface + 좌측 8탭.
   기존 우측 드로어(organisms-5 KeeperConfigPanel)를 대체한다. 실제 keeper
   상세 화면의 필드 무덤을 8개 카테고리로 재정리:
     정체성 · 프롬프트 · 런타임 · 실행 정책 · 권한·샌드박스 · 목표 · 훅 · 상태
   목표 탭은 70개+ 카탈로그를 검색·horizon 필터 picker로 푼다.
   미구현 필드는 <KcfPlan> '기획' 배지로 표기, 명백히 불필요한 raw 필드는 생략.
   reuse: SigilBadge·StatusDot(messages) · Segmented·Toggle(primitives) · SetRow(molecules). */
const { useState: useKcfS, useMemo: useKcfMemo } = React;

const KCF_TABS = [
  ['identity', '정체성', '◈'],
  ['prompt', '프롬프트', '¶'],
  ['runtime', '런타임', '◷'],
  ['policy', '실행 정책', '⚖'],
  ['access', '권한·샌드박스', '⚿'],
  ['goals', '목표', '◎'],
  ['hooks', '가드', '⬡'],
  ['health', '상태·진단', '◉'],
];
const KCF_IV_LABEL = { escalated: 'Gate', blocked: '차단', passed: '허용', warned: '경고' };

// ── small building blocks ──
function KcfSec({ title, desc, children, right }) {
  return (
    <section className="kcf-sec">
      <div className="kcf-sec-h">
        <h3>{title}</h3>
        {right}
      </div>
      {desc && <p className="kcf-sec-desc">{desc}</p>}
      <div className="kcf-sec-body">{children}</div>
    </section>
  );
}
function KcfFacts({ rows }) {
  return (
    <div className="kcf-facts">
      {rows.filter(r => r && r[1] != null && r[1] !== '').map(([k, v, mono], i) => (
        <div key={i} className="kcf-fact">
          <span className="kcf-fact-k">{k}</span>
          <span className={`kcf-fact-v ${mono ? 'mono' : ''}`}>{v}</span>
        </div>
      ))}
    </div>
  );
}
function KcfPlan({ children }) {
  return <span className="kcf-plan" title="아직 미구현 — 기획 단계">기획<em>{children}</em></span>;
}
function KcfReadonly({ children }) { return <span className="kcf-ro">{children}</span>; }

// single-line editable field (label · hint · input) — for identity attrs the
// keeper actually owns (표시 이름 등). Derived facts stay in KcfFacts.
function KcfField({ label, hint, value, onChange, mono, placeholder }) {
  return (
    <div className="kcf-field">
      <div className="kcf-tf-h"><label>{label}</label>{hint && <span className="kcf-tf-hint">{hint}</span>}</div>
      <input className={`kcf-input ${mono ? 'mono' : ''}`} value={value} placeholder={placeholder}
        onChange={e => onChange(e.target.value)} />
    </div>
  );
}

function KcfTextField({ label, hint, value, onChange, rows = 3 }) {
  return (
    <div className="kcf-textfield">
      <div className="kcf-tf-h"><label>{label}</label>{hint && <span className="kcf-tf-hint">{hint}</span>}</div>
      <textarea className="kcf-text" rows={rows} value={value} onChange={e => onChange(e.target.value)} />
    </div>
  );
}

// ── Goals picker (검색 · horizon 필터) ──
function KcfGoalsPicker({ assigned, onToggle }) {
  const [q, setQ] = useKcfS('');
  const goals = window.KC_GOALS || [];
  const rows = useKcfMemo(() => goals.filter(([id, title]) =>
    (!q || title.toLowerCase().includes(q.toLowerCase()) || id.toLowerCase().includes(q.toLowerCase()))
  ), [q, goals]);
  const aset = new Set(assigned);
  return (
    <div className="kcf-goals">
      <div className="kcf-goals-bar">
        <div className="kcf-search">
          <span className="kcf-search-ic">◌</span>
          <input value={q} onChange={e => setQ(e.target.value)} placeholder="goal 제목·id 검색…" />
        </div>
        <span className="kcf-goals-count mono">{assigned.length} 배정 · {rows.length} 표시</span>
      </div>
      <div className="kcf-goals-list">
        {rows.map(([id, title]) => {
          const on = aset.has(id);
          return (
            <button key={id} className={`kcf-goal ${on ? 'on' : ''}`} onClick={() => onToggle(id)}>
              <span className="kcf-goal-check">{on ? '✓' : ''}</span>
              <span className="kcf-goal-body">
                <span className="kcf-goal-title">{title}</span>
                <span className="kcf-goal-id mono">{id}</span>
              </span>
            </button>
          );
        })}
        {!rows.length && <div className="kcf-goals-empty">검색 결과 없음</div>}
      </div>
    </div>
  );
}

// ── prompt assembly trace (cc-6): the assembled system prompt, segment by
// segment, each tagged with the layer it came from. Layers stack top→bottom
// and live_meta override wins over the manifest. ──
const KASM_SRC = {
  base:     { lbl: '월드 프롬프트', path: '~/.masc/config/prompts/keeper.world.md' },
  manifest: { lbl: '프롬프트 파일',   path: '~/.masc/config/keepers/{id}/AGENT.md' },
  override: { lbl: 'live override', path: '~/.masc/keepers/{id}.json' },
  goals:    { lbl: '배정 목표',      path: 'goal store · 소유 goal' },
  world:    { lbl: '월드 상태',      path: 'runtime · 턴 시작 스냅샷' },
};
function kasmAssignedTitles(ids) {
  const map = Object.fromEntries((window.KC_GOALS || []).map(g => [g[0], g[1]]));
  const list = (ids || []).map(id => '· ' + (map[id] || id));
  return list.length ? list.join('\n') : '—';
}
function KcfAssembly({ f, keeper }) {
  const segs = [
    { src: 'base', text: '너는 MASC 멀티에이전트 코딩 keeper다. namespace 를 공유하고 task 를 소유하며, 브로드캐스트로 다른 keeper 와 협응한다. 모든 턴 출력은 검증 게이트를 통과해야 한다.' },
    { src: 'manifest', label: 'AGENT.md', text: [f.prompt.persona, f.prompt.objective].filter(Boolean).join('\n\n') || '—' },
    { src: 'override', label: 'instructions', text: f.prompt.instructions || '—', win: true },
    { src: 'goals', label: `배정 goal ${f.goals.assigned.length}개`, text: kasmAssignedTitles(f.goals.assigned) },
    { src: 'world', label: 'scope', text: `${f.health.scopeMsg} · running fibers ${f.health.runningFibers} · occupancy not_observed` },
  ];
  return (
    <div className="kasm">
      <div className="kasm-legend">
        {Object.keys(KASM_SRC).map(s => (
          <span key={s} className={`kasm-leg src-${s}`}><i></i>{KASM_SRC[s].lbl}</span>
        ))}
      </div>
      <div className="kasm-stack">
        {segs.map((sg, i) => {
          const meta = KASM_SRC[sg.src];
          return (
            <div key={i} className={`kasm-seg src-${sg.src} ${sg.win ? 'win' : ''}`}>
              <div className="kasm-seg-h">
                <span className="kasm-seg-src">{meta.lbl}</span>
                {sg.label && <span className="kasm-seg-field mono">{sg.label}</span>}
                {sg.win && <span className="kasm-seg-win">파일 위에 덮어씀</span>}
                <span className="kasm-seg-path mono">{meta.path.replace('{id}', keeper.id)}</span>
              </div>
              <div className="kasm-seg-text">{sg.text}</div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// ── Avatar editor (cc): keeper picks its own face — sigil (slot color + 2글자
// 모노그램) or a portrait (12 프리셋 오일페인팅 or 업로드). All four levers live
// here; the identity FACTS below stay read-only. ──
const KCF_PORTRAITS = ['aldric', 'bell', 'brenna', 'cedric', 'dara', 'dust', 'grimja', 'iron', 'luna', 'miso', 'moth', 'songarak'];

function KcfAvatarPreview({ id, av }) {
  const [err, setErr] = useKcfS(false);
  const src = av.avatarMode === 'portrait'
    ? (av.portrait === 'custom' ? av.customPortrait : (typeof PORTRAIT === 'function' ? PORTRAIT(av.portrait) : null))
    : null;
  if (src && !err) return <img className="kav-face is-img" src={src} alt={id} onError={() => setErr(true)} />;
  return (
    <span className="kav-face is-sigil" style={{ background: `var(--kp${av.slot})` }}>
      {(av.sigil || '··').slice(0, 2)}
    </span>
  );
}

function KcfAvatarEditor({ keeper, av, patch }) {
  const fileRef = React.useRef(null);
  const onFile = (e) => {
    const file = e.target.files && e.target.files[0];
    if (!file) return;
    const r = new FileReader();
    r.onload = () => patch({ avatarMode: 'portrait', portrait: 'custom', customPortrait: r.result });
    r.readAsDataURL(file);
    e.target.value = '';
  };
  return (
    <div className="kav">
      {/* live preview */}
      <div className="kav-preview">
        <KcfAvatarPreview id={keeper.id} av={av} />
        <div className="kav-preview-meta">
          <span className="kav-preview-name">{av.name || keeper.id}</span>
          <span className="kav-preview-mode mono">
            {av.avatarMode === 'portrait'
              ? (av.portrait === 'custom' ? '업로드 초상화' : `초상화 · ${av.portrait || '—'}`)
              : `시길 · slot ${av.slot} · ${av.sigil}`}
          </span>
        </div>
        {av.avatarMode === 'portrait' && (
          <button className="kav-clear" onClick={() => patch({ avatarMode: 'sigil' })} title="초상화 해제 → 시길로">시길로 되돌리기</button>
        )}
      </div>

      {/* source toggle */}
      <div className="kav-block">
        <label className="kav-lbl">아바타 소스</label>
        <div className="kav-src">
          <button className={`kav-src-b ${av.avatarMode === 'sigil' ? 'on' : ''}`} onClick={() => patch({ avatarMode: 'sigil' })}>◈ 시길</button>
          <button className={`kav-src-b ${av.avatarMode === 'portrait' ? 'on' : ''}`} onClick={() => patch({ avatarMode: 'portrait', portrait: av.portrait || KCF_PORTRAITS[0] })}>◉ 초상화</button>
        </div>
      </div>

      {/* portrait picker — only when portrait mode */}
      {av.avatarMode === 'portrait' && (
        <div className="kav-block">
          <label className="kav-lbl">초상화 <span className="kav-lbl-hint">프리셋 12종 · 오일페인팅 · 정사각</span></label>
          <div className="kav-portraits">
            <button className={`kav-por kav-upload ${av.portrait === 'custom' ? 'on' : ''}`} onClick={() => fileRef.current && fileRef.current.click()} title="이미지 업로드">
              {av.portrait === 'custom' && av.customPortrait
                ? <img src={av.customPortrait} alt="uploaded" />
                : <span className="kav-upload-ic">＋<em>업로드</em></span>}
            </button>
            <input ref={fileRef} type="file" accept="image/*" hidden onChange={onFile} />
            {KCF_PORTRAITS.map(slug => (
              <button key={slug} className={`kav-por ${av.portrait === slug ? 'on' : ''}`}
                onClick={() => patch({ portrait: slug, customPortrait: null })} title={slug}>
                <img src={typeof PORTRAIT === 'function' ? PORTRAIT(slug) : `assets/portraits/${slug}.png`} alt={slug} loading="lazy" />
              </button>
            ))}
          </div>
        </div>
      )}

      {/* slot color — drives sigil + every chip/accent for this keeper */}
      <div className="kav-block">
        <label className="kav-lbl">슬롯 색 <span className="kav-lbl-hint">시길·칩·강조색 전반에 적용</span></label>
        <div className="kav-swatches">
          {Array.from({ length: 12 }, (_, i) => i + 1).map(n => (
            <button key={n} className={`kav-sw ${av.slot === n ? 'on' : ''}`} style={{ '--sw': `var(--kp${n})` }}
              onClick={() => patch({ slot: n })} title={`slot ${n}`}>
              {av.slot === n && <span className="kav-sw-tick">✓</span>}
            </button>
          ))}
        </div>
      </div>

      {/* sigil monogram */}
      <div className="kav-block kav-block-row">
        <div>
          <label className="kav-lbl">시길 <span className="kav-lbl-hint">2글자 모노그램</span></label>
          <input className="kav-sigil-in mono" maxLength={2} value={av.sigil}
            onChange={e => patch({ sigil: e.target.value.toUpperCase().replace(/\s/g, '') })} placeholder="MS" />
        </div>
        <span className="kav-sigil-prev mono" style={{ background: `var(--kp${av.slot})` }}>{(av.sigil || '··').slice(0, 2)}</span>
      </div>
    </div>
  );
}

// ── Runtime picker (검색 · cloud/local 그룹) — 런타임은 3개 고정이 아니라
// runtime.toml 에 등록된 전체 카탈로그에서 고른다 (KcfGoalsPicker 패턴 재사용). ──
function KcfRuntimePicker({ value, onChange }) {
  const [q, setQ] = useKcfS('');
  const runtimes = window.KC_RUNTIMES || [];
  const rows = useKcfMemo(() => runtimes.filter(r =>
    !q || r.id.toLowerCase().includes(q.toLowerCase()) || r.model.toLowerCase().includes(q.toLowerCase())
  ), [q, runtimes]);
  return (
    <div className="kcf-goals">
      <div className="kcf-goals-bar">
        <div className="kcf-search">
          <span className="kcf-search-ic">◌</span>
          <input value={q} onChange={e => setQ(e.target.value)} placeholder="runtime·model 검색…" />
        </div>
        <span className="kcf-goals-count mono">{rows.length} / {runtimes.length}</span>
      </div>
      <div className="kcf-rt-list">
        {rows.map(r => {
          const on = r.id === value;
          return (
            <button key={r.id} className={`kcf-rt ${on ? 'on' : ''}`} onClick={() => onChange(r.id)}>
              <span className="kcf-rt-radio"></span>
              <span className="kcf-rt-body">
                <span className="kcf-rt-id mono">{r.id}</span>
                <span className="kcf-rt-meta">{r.where === 'cloud' ? '클라우드' : '로컬'} · 최대 {r.ctx} · {r.model}</span>
              </span>
              <span className="kcf-rt-badges">{r.badges.map(b => <span key={b} className="kcf-rt-badge">{b}</span>)}</span>
            </button>
          );
        })}
        {!rows.length && <div className="kcf-goals-empty">검색 결과 없음</div>}
      </div>
    </div>
  );
}

function KeeperConfigFull({ keeper, onClose, onNav }) {
  const [tab, setTab] = useKcfS('identity');
  const init = useKcfMemo(() => (window.keeperConfig ? window.keeperConfig(keeper) : {}), [keeper.id]);
  const [f, setF] = useKcfS(init);
  const upd = (sec, key, val) => setF(p => ({ ...p, [sec]: { ...p[sec], [key]: val } }));
  const patchId = (obj) => setF(p => ({ ...p, identity: { ...p.identity, ...obj } }));
  const tools = window.MASC_TOOLS || [];
  const tone = (window.PHASE_TONE || {})[keeper.phase] || 'idle';
  const interventions = useKcfMemo(() => window.kcfInterventions ? window.kcfInterventions(keeper) : [], [keeper.id]);
  const guardFires = useKcfMemo(() => { const m = {}; interventions.forEach(iv => { m[iv.guard] = (m[iv.guard] || 0) + 1; }); return m; }, [interventions]);

  const toggleGoal = (id) => setF(p => {
    const cur = p.goals.assigned;
    const next = cur.includes(id) ? cur.filter(x => x !== id) : [...cur, id];
    return { ...p, goals: { ...p.goals, assigned: next } };
  });
  const toggleTool = (id) => setF(p => {
    const cur = p.access.tools;
    const next = cur.includes(id) ? cur.filter(x => x !== id) : [...cur, id];
    return { ...p, access: { ...p.access, tools: next } };
  });

  return (
    <div className="kcf-overlay" onClick={onClose}>
      <div className="kcf" onClick={e => e.stopPropagation()}>
        {/* top */}
        <div className="kcf-top">
          <SigilBadge k={keeper} size={34} />
          <div className="kcf-top-id">
            <div className="kcf-top-name">{keeper.id}<span className="kcf-top-kr">{keeper.kr}</span></div>
            <div className="kcf-top-sub mono">{keeper.model}</div>
          </div>
          <span className="kcf-top-phase"><StatusDot status={keeper.status} pulse={keeper.status === 'run'} />{keeper.phase}</span>
          {keeper.sandbox && <span className="kcf-top-sandbox" title="이 keeper 전용 작업 폴더 — git worktree 로 갈라 놔서 다른 keeper 와 파일이 섞이지 않습니다 (OS·컨테이너 샌드박스는 아님)">⬡ {keeper.sandbox}</span>}
          <div className="kcf-top-spacer" />
          <button className="kcf-top-x" onClick={onClose} title="닫기 (Esc)">✕</button>
        </div>

        {/* body */}
        <div className="kcf-body">
          <nav className="kcf-tabs">
            {KCF_TABS.map(([id, lbl, ic]) => (
              <button key={id} className={`kcf-tab ${tab === id ? 'on' : ''}`} onClick={() => setTab(id)}>
                <span className="kcf-tab-ic">{ic}</span><span className="kcf-tab-lbl">{lbl}</span>
              </button>
            ))}
          </nav>

          <div className="kcf-main">
            {tab === 'identity' && (
              <React.Fragment>
                <KcfSec title="아바타" desc="이 keeper 의 얼굴 — 시길(슬롯 색 + 2글자 모노그램) 또는 초상화(프리셋·업로드). 목록·채팅·보드 전반에 즉시 반영됩니다.">
                  <KcfAvatarEditor keeper={keeper} av={f.identity} patch={patchId} />
                </KcfSec>
                <KcfSec title="정체성" desc="이 keeper가 소유한 편집 가능한 속성. 아래 '파생 사실'은 배정·파생된 값이라 여기서 바꾸지 않습니다.">
                  <div className="kcf-idrow">
                    <KcfField label="표시 이름" hint="목록·채팅·보드에 표시" value={f.identity.name} onChange={v => upd('identity', 'name', v)} placeholder={keeper.id} />
                  </div>
                </KcfSec>
                <KcfSec title="파생 사실" desc="배정·파생된 사실 — 읽기 전용. 격리는 git worktree 뿐 (단일 머신 localhost-trust · OS sandbox 없음).">
                  <KcfFacts rows={[
                    ['sandbox', f.identity.sandbox ? `${f.identity.sandbox} 격리` : '— 비활성'],
                    ['생성', f.identity.created],
                    ['runtime profile', f.identity.runtimeProfile, true],
                  ]} />
                </KcfSec>
                <KcfSec title="레지스트리 · 소스" desc="등록 상태와 파일 경로는 읽기 전용입니다.">
                  <KcfFacts rows={[
                    ['레지스트리', f.identity.registry], ['파이버', f.identity.fiber],
                    ['live meta', f.identity.liveMetaPath, true], ['manifest', f.identity.manifestPath, true],
                  ]} />
                </KcfSec>
              </React.Fragment>
            )}

            {tab === 'prompt' && (
              <React.Fragment>
                <KcfSec title="목표" desc="이 keeper 의 목표 — 프롬프트 상단에 조립됩니다.">
                  <KcfTextField label="목표 (objective)" value={f.prompt.objective} onChange={v => upd('prompt', 'objective', v)} rows={3} />
                </KcfSec>
                <KcfSec title="프롬프트" desc="keepers/{id}/AGENT.md 한 장이 이 keeper 프롬프트 전체입니다 — 무대(keeper.world.md) 위에 쌓입니다.">
                  <KcfTextField label="AGENT.md" value={f.prompt.persona} onChange={v => upd('prompt', 'persona', v)} rows={5} />
                  <KcfTextField label="지시사항 (instructions · 라이브 오버라이드)" value={f.prompt.instructions} onChange={v => upd('prompt', 'instructions', v)} rows={4} />
                  <div className="kcf-traits">{(f.prompt.traits || []).map((t, i) => <span key={i} className="kcf-trait">{t}</span>)}</div>
                </KcfSec>
                <KcfSec title="조립 추적" desc="이 keeper 의 시스템 프롬프트가 어느 레이어에서 조립됐는지 — 위에서 아래로 쌓이고, live override(live_meta)가 파일 값을 덮어씁니다.">
                  <KcfAssembly f={f} keeper={keeper} />
                </KcfSec>
              </React.Fragment>
            )}

            {tab === 'runtime' && (
              <React.Fragment>
                <KcfSec title="런타임 선택" desc="runtime.toml [runtime.assignments] 에서 관리. 등록된 전체 런타임에서 검색·선택합니다.">
                  <KcfRuntimePicker value={f.runtime.profile} onChange={v => upd('runtime', 'profile', v)} />
                  <KcfFacts rows={[['runtime_id', f.runtime.runtimeId, true], ['활성 런타임', f.runtime.activeRuntime, true]]} />
                </KcfSec>
                <KcfSec title="라이브 오버라이드">
                  <SetRow label="라이브 오버라이드" hint="live_meta 가 파일 값을 덮어씀">
                    <Toggle on={f.runtime.liveOverride} onChange={v => upd('runtime', 'liveOverride', v)} />
                  </SetRow>
                </KcfSec>
                <KcfSec title="fallback 체인" desc="마지막 runtime을 제외한 항목들에 순서대로 폴백합니다.">
                  <div className="kcf-chain">{f.runtime.fallback.map((r, i) => <span key={i} className="kcf-chain-item mono">{r}</span>)}</div>
                </KcfSec>
              </React.Fragment>
            )}

            {tab === 'policy' && (
              <React.Fragment>
                <KcfSec title="검증 게이트" desc="턴 산출물 검증 on/off. 컨텍스트 비율·메시지·토큰 게이트는 소스에서 삭제되었습니다.">
                  <SetRow label="검증" hint="턴 출력 검증 on/off"><Toggle on={f.policy.verify} onChange={v => upd('policy', 'verify', v)} /></SetRow>
                  <div className="kcf-dead">☠ 제거됨 · <span className="mono">ratio / message / token 게이트</span>와 <span className="mono">context_within_budget</span> FSM 조건은 zero-consumer 로 삭제. 컴팩션 임계치를 설정하는 곳은 이제 없습니다.</div>
                </KcfSec>
                <KcfSec title="컴팩션" desc="typed 컴팩션 런타임은 owner-lane 에서 실행되고 provider overflow 를 복구합니다. 정책 오써링 UI 는 제거됨.">
                  <SetRow label="관측 이벤트" hint="이것만 남았습니다"><KcfReadonly>Compaction_started</KcfReadonly></SetRow>
                  <SetRow label="트리거" hint="provider overflow · operator 수동"><KcfReadonly>자동 임계치 없음</KcfReadonly></SetRow>
                </KcfSec>
                <KcfSec title="핸드오프">
                  <SetRow label="mention targets" hint={<KcfPlan>인계 후보 keeper 지정</KcfPlan>}><KcfReadonly>{f.policy.mentionTargets}</KcfReadonly></SetRow>
                  <div className="kcf-dead">☠ 제거됨 · <span className="mono">Handoff_triggered</span> 이벤트와 중복 handoff generation 키, 자동 핸드오프 임계치, 파생 지표 <span className="mono">handoff_rate</span> 가 삭제됐습니다. HandingOff 상태 자체는 FSM 에 남습니다.</div>
                </KcfSec>
                <KcfSec title="프로액티브" desc="유휴 시 keeper 가 스스로 깨어나는 조건.">
                  <SetRow label="활성"><Toggle on={f.policy.proactive} onChange={v => upd('policy', 'proactive', v)} /></SetRow>
                  <SetRow label="유휴 트리거" hint="초"><Segmented options={[60, 120, 300, 600]} value={f.policy.idleTrigger} onChange={v => upd('policy', 'idleTrigger', v)} /></SetRow>
                  <SetRow label="일시정지"><Toggle on={f.policy.paused} onChange={v => upd('policy', 'paused', v)} /></SetRow>
                  <SetRow label="자동 부팅 등록" hint={<KcfPlan>부팅 시 자동 기동</KcfPlan>}><Toggle on={f.policy.autoBoot} onChange={v => upd('policy', 'autoBoot', v)} /></SetRow>
                </KcfSec>
              </React.Fragment>
            )}

            {tab === 'access' && (
              <React.Fragment>
                <KcfSec title="권한 · 범위" desc="이 keeper가 무엇에 쓸 수 있는가 — 샌드박스 경계보다 위 계층의 행동 권한.">
                  <SetRow label="파일시스템 범위" hint="none 읽기전용 · worktree 자기 워크트리 · namespace 소유 ns 전체">
                    <Segmented options={['none', 'worktree', 'namespace']} value={f.access.fs} onChange={v => upd('access', 'fs', v)} />
                  </SetRow>
                  <SetRow label="git push / merge" hint="원격 브랜치 쓰기"><Toggle on={f.access.git} onChange={v => upd('access', 'git', v)} /></SetRow>
                  <SetRow label="외부 호출" hint="Slack·Discord 발신"><Toggle on={f.access.net} onChange={v => upd('access', 'net', v)} /></SetRow>
                </KcfSec>
                <KcfSec title="샌드박스">
                  <SetRow label="sandbox_profile"><Segmented options={['local', 'docker']} value={f.access.sandbox} onChange={v => upd('access', 'sandbox', v)} /></SetRow>
                  <SetRow label="network_mode"><Segmented options={['none', 'inherit']} value={f.access.network} onChange={v => upd('access', 'network', v)} /></SetRow>
                  <div className="kcf-paths">
                    <span className="kcf-path-eff mono">effective: {f.access.effectivePath}</span>
                  </div>
                </KcfSec>
                <KcfSec title="도구 권한 · masc_*" desc="이 keeper가 호출 가능한 MCP 도구. 서버 노출(설정·MCP)과 둘 다 켜져야 호출됩니다.">
                  <div className="kcf-tools">
                    {tools.map(t => {
                      const on = f.access.tools.includes(t.id);
                      return (
                        <div key={t.id} className={`kcf-tool ${on ? 'on' : ''}`}>
                          <Toggle on={on} onChange={() => toggleTool(t.id)} size="sm" />
                          <span className="kcf-tool-id mono">{t.id}</span>
                          <span className={`kcf-tool-risk ${t.risk}`}>{t.risk === 'read' ? '읽기' : t.risk === 'write' ? '쓰기' : '수명'}</span>
                          <span className="kcf-tool-desc">{t.desc}</span>
                        </div>
                      );
                    })}
                  </div>
                </KcfSec>
                <KcfSec title="가드 · 거부">
                  <KcfFacts rows={[['거부 목록', f.access.denyCount + '개', true], ['파괴 검사 도구', f.access.destructiveTool, true]]} />
                </KcfSec>
              </React.Fragment>
            )}

            {tab === 'goals' && (
              <KcfSec title="배정 목표" desc="goal store 카탈로그에서 이 keeper가 소유할 goal을 고릅니다. 검색하거나 horizon으로 필터하세요.">
                <KcfGoalsPicker assigned={f.goals.assigned} onToggle={toggleGoal} />
              </KcfSec>
            )}

            {tab === 'hooks' && (
              <React.Fragment>
                <KcfSec title="활성 가드" desc="이 keeper의 도구 호출이 통과하는 pre_tool_use 가드. 외부 효과 호출은 Gate(HITL) 큐로 라우팅됩니다.">
                  <div className="kcf-guards">
                    {(window.KC_GUARDS || []).map(g => (
                      <div key={g.id} className="kcf-guard">
                        <span className="kcf-guard-dot"></span>
                        <div className="kcf-guard-main">
                          <div className="kcf-guard-lbl">{g.lbl}<span className="kcf-guard-id mono">{g.id}</span></div>
                          <div className="kcf-guard-desc">{g.desc}</div>
                        </div>
                        <span className="kcf-guard-fires mono" title="최근 발동 횟수">{guardFires[g.id] || 0}<em>회</em></span>
                      </div>
                    ))}
                  </div>
                </KcfSec>
                <KcfSec title="최근 개입" desc="가드가 발동한 최근 이력 — 차단하거나 Gate 큐로 올린 기록. Gate 큐 항목은 Gate surface에서 결재합니다.">
                  {interventions.length ? (
                    <div className="kcf-ivs">
                      {interventions.map((iv, i) => (
                        <div key={i} className="kcf-iv" data-act={iv.action}>
                          <span className="kcf-iv-act">{KCF_IV_LABEL[iv.action] || iv.action}</span>
                          <div className="kcf-iv-main">
                            <div className="kcf-iv-top"><span className="kcf-iv-guard mono">{iv.guard}</span><span className="kcf-iv-at">{iv.at}</span></div>
                            <div className="kcf-iv-note">{iv.note}</div>
                          </div>
                          {iv.ref && <span className="kcf-iv-ref mono">{iv.ref}</span>}
                        </div>
                      ))}
                    </div>
                  ) : <div className="kcf-ivs-empty">최근 발동한 가드 없음 — 이 keeper는 모든 호출이 게이트를 통과했습니다.</div>}
                </KcfSec>
              </React.Fragment>
            )}

            {tab === 'health' && (
              <React.Fragment>
                <KcfSec title="검증 · 신호">
                  <KcfFacts rows={[
                    ['검증', f.health.verifyPass ? '통과' : '미통과'], ['마지막 시도', f.health.lastAttempt],
                    ['최근 검증 이벤트', f.health.lastVerifyEvent], ['최근 신호', f.health.lastSignal],
                  ]} />
                </KcfSec>
                <KcfSec title="월드 상태" desc="이 keeper가 보는 현재 namespace 상태 — 프롬프트에 주입됩니다.">
                  <KcfFacts rows={[
                    ['running fibers', f.health.runningFibers, true], ['컨텍스트 점유율', 'not_observed', true],
                    ['idle', f.health.idleSec + 's', true], ['scope msg', f.health.scopeMsg, true],
                  ]} />
                </KcfSec>
              </React.Fragment>
            )}
          </div>
        </div>

        {/* footer */}
        <div className="kcf-foot">
          <span className="kcf-foot-note mono">{KCF_TABS.find(t => t[0] === tab)[1]} · {keeper.id}</span>
          <div className="kcf-foot-spacer" />
          <button className="kcf-btn ghost" onClick={onClose}>취소</button>
          <button className="kcf-btn save" onClick={onClose}>저장 · 다음 턴부터 적용</button>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { KeeperConfigFull });
