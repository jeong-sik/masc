/* MASC v2 — Registry surface.
   프롬프트 파일 (AGENT.md)  →  Keeper (인스턴스)  →  런타임 (바인딩)
   0.22.0 이후 keeper 프롬프트의 저작 지점은 keepers/<name>/AGENT.md 한 장이다.
   여러 keeper 가 같은 파일을 참조할 수 있고, 파일을 고치면 그 파일을 참조하는
   keeper 전부의 다음 턴에 반영된다 (복제가 아니라 참조).
   Reuses: SigilBadge·StatusDot (messages) · window.KeeperConfigFull (edit) ·
   PHASE_TONE·PHASE_PULSE·phaseStatus (data) · pushToast. Mockup-level state:
   personas + keepers are kept in local surface state so create/deregister feel
   real without disturbing the app-wide keeper roster. */
const { useState: useRgS, useMemo: useRgMemo, useEffect: useRgEffect, useRef: useRgRef } = React;

// ── AGENT.md 라이브러리 — keeper 가 참조하는 프롬프트 파일들 ──
const REG_PERSONAS = [
  { id: 'p-resource', glyph: '⬡', name: '리소스 파수꾼', horizon: 'mid',
    desc: '리소스 수명(Switch)과 fiber 취소를 꼼꼼히 따진다. fd·메모리 누수를 먼저 의심하고, 작은 diff로 고친다.',
    persona: 'OCaml·Eio에 능하고, 리소스 수명(Switch)과 fiber 취소를 꼼꼼히 따진다.',
    traits: ['정확함', 'OCaml/Eio', '리소스안전'] },
  { id: 'p-rootcause', glyph: '◉', name: '근본 추적자', horizon: 'short',
    desc: '집요하고 직설적. 가설은 trace로 검증하고 git blame으로 책임 커밋을 특정할 때까지 파고든다.',
    persona: '집요하고 직설적. 루트 코즈를 잡을 때까지 파고든다.',
    traits: ['집요함', '직설적', '근본추적'] },
  { id: 'p-collab', glyph: '◈', name: '협업 안정자', horizon: 'mid',
    desc: '차분하고 협업적. 변경은 작게 쪼개고, 핸드오프 시 컨텍스트를 충분히 남긴다.',
    persona: '차분하고 협업적. 인계와 문서화를 중시한다.',
    traits: ['협업적', '안정지향', '문서화'] },
  { id: 'p-verify', glyph: '◎', name: '엄격한 검증자', horizon: 'short',
    desc: '꼼꼼하고 회의적. 통과 기준을 엄격히 적용하고, 불확실하면 통과시키지 않는다.',
    persona: '꼼꼼하고 회의적. 통과 기준을 엄격히 적용한다.',
    traits: ['꼼꼼함', '회의적', '엄격함'] },
  { id: 'p-conservative', glyph: '⚖', name: '보수적 승인자', horizon: 'long',
    desc: '신중하고 보수적. 위험한 변경은 항상 operator 승인을 구한다.',
    persona: '신중하고 보수적. 위험한 변경은 operator 승인을 구한다.',
    traits: ['보수적', '안전우선'] },
  { id: 'p-explore', glyph: '✦', name: '탐색 분석가', horizon: 'mid',
    desc: '탐색적이고 폭넓게 본다. 패턴을 먼저 잡고 실패를 빠르게 격리한다.',
    persona: '탐색적이고 폭넓게 본다. 패턴을 먼저 잡는다.',
    traits: ['탐색적', '패턴인식'] },
  { id: 'p-experiment', glyph: '△', name: '빠른 실험가', horizon: 'short',
    desc: '실험적이고 빠르다. 컨텍스트 사용을 자주 점검하고 임계치 전 compact한다.',
    persona: '실험적이고 빠르다. 단, 컨텍스트 관리가 약하다.',
    traits: ['실험적', '빠름'] },
  { id: 'p-base', glyph: '○', name: '기본 프롬프트', horizon: 'mid',
    desc: '작업에 충실하고 모든 행동을 trace로 남기는 기본 keeper 성격.',
    persona: '기본 keeper 성격. 작업에 충실하고 trace를 남긴다.',
    traits: ['기본'] },
];
const REG_GLYPHS = ['⬡', '◉', '◈', '◎', '⚖', '✦', '△', '○', '◇', '⌘'];
const REG_HORIZON = { short: '단기 성향', mid: '중기 성향', long: '장기 성향' };

// existing keeper → the form it was cast from (provenance)
const REG_SEED_MAP = {
  'masc-improver': 'p-resource', 'nick0cave': 'p-rootcause', 'sangsu': 'p-collab',
  'qa-king': 'p-verify', 'rama': 'p-conservative', 'scholar': 'p-collab',
  'analyst': 'p-explore', 'reviewer': 'p-verify', 'herald': 'p-base',
  'drifter': 'p-experiment', 'marshal': 'p-base', 'revenant': 'p-base',
};

// runtime profiles a keeper can be bound to (런타임)
const REG_RUNTIMES = [
  { id: 'ollama_cloud.deepseek-v4-flash', model: 'deepseek-v4-flash', where: 'cloud', ctx: '196k', badges: ['flash', 'multimodal'] },
  { id: 'deepseek.deepseek-v4-pro', model: 'deepseek-v4-pro', where: 'cloud', ctx: '128k', badges: ['pro', 'reasoning'] },
  { id: 'ollama.gemma4-26b-a4b-qat', model: 'gemma4-26b-a4b-qat', where: 'local', ctx: '64k', badges: ['local', 'qat'] },
];

const REG_KGROUPS = [['run', '실행 중', 'run'], ['pause', '대기 · 일시정지', 'pause'], ['off', '중지 · 미기동', 'off']];

// ══════════════════════════════════════════════════════════════
// Persona editor (add / edit) — 이데아
// ══════════════════════════════════════════════════════════════
function RegPersonaEditor({ initial, onClose, onSave }) {
  const isNew = !initial;
  const [f, setF] = useRgS(() => initial ? { ...initial, traits: [...initial.traits] }
    : { id: 'p-' + Math.random().toString(36).slice(2, 7), name: '', desc: '', persona: '', traits: [] });
  const [tagDraft, setTagDraft] = useRgS('');
  useRgEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  const up = (k, v) => setF(p => ({ ...p, [k]: v }));
  const addTag = () => { const t = tagDraft.trim(); if (t && !f.traits.includes(t)) up('traits', [...f.traits, t]); setTagDraft(''); };
  const rmTag = (t) => up('traits', f.traits.filter(x => x !== t));
  const valid = f.name.trim() && f.persona.trim();

  return (
    <div className="reg-overlay" onClick={onClose}>
      <div className="reg-dialog" onClick={e => e.stopPropagation()}>
        <div className="reg-dlg-h idea">
          <span className="rd-layer"></span>
          <div>
            <span className="rd-eyebrow">AGENT.md</span>
            <h3>{isNew ? '새 프롬프트 파일' : '프롬프트 파일 수정'}</h3>
          </div>
          <button className="reg-dlg-x" onClick={onClose} title="닫기 (Esc)">✕</button>
        </div>
        <div className="reg-dlg-body">
          <div className="reg-field">
            <label>이름</label>
            <input className="reg-input" value={f.name} placeholder="예 · 리소스 파수꾼" onChange={e => up('name', e.target.value)} autoFocus />
          </div>
          <div className="reg-field">
            <label>설명</label>
            <textarea className="reg-textarea" rows={2} value={f.desc} placeholder="한 줄 요약…" onChange={e => up('desc', e.target.value)}></textarea>
          </div>
          <div className="reg-field">
            <label>본문 <span className="rf-hint">AGENT.md 로 저장됨</span></label>
            <textarea className="reg-textarea" rows={3} value={f.persona} placeholder="이 keeper 의 성격·태도·규율…" onChange={e => up('persona', e.target.value)}></textarea>
          </div>
          <div className="reg-field">
            <label>특성</label>
            <div className="reg-tags" onClick={e => { if (e.target === e.currentTarget) e.currentTarget.querySelector('input').focus(); }}>
              {f.traits.map(t => (
                <span key={t} className="reg-tag">{t}<button onClick={() => rmTag(t)} title="제거">✕</button></span>
              ))}
              <input className="reg-tag-in" value={tagDraft} placeholder={f.traits.length ? '' : '특성 입력 후 Enter…'}
                onChange={e => setTagDraft(e.target.value)}
                onKeyDown={e => { if (e.key === 'Enter') { e.preventDefault(); addTag(); } else if (e.key === 'Backspace' && !tagDraft && f.traits.length) rmTag(f.traits[f.traits.length - 1]); }} />
            </div>
          </div>
        </div>
        <div className="reg-dlg-foot">
          <span className="rf-spacer"></span>
          <button className="reg-btn" onClick={onClose}>취소</button>
          <button className="reg-btn primary" disabled={!valid} onClick={() => onSave(f, isNew)}>{isNew ? '파일 추가' : '저장'}</button>
        </div>
      </div>
    </div>
  );
}

// ══════════════════════════════════════════════════════════════
// Keeper wizard (3 steps) — IDEAL → 실재 → RUNTIME
// ══════════════════════════════════════════════════════════════
const RW_STEPS = [['idea', '프롬프트', 'AGENT.md', '파일 선택'], ['actual', '정체성', 'KEEPER', '정체성'], ['runtime', '런타임', 'RUNTIME', '바인딩']];

function RegKeeperWizard({ personas, usedSlots, onClose, onCreate }) {
  const [step, setStep] = useRgS(0);
  const [seed, setSeed] = useRgS(null);           // persona id
  const [ident, setIdent] = useRgS({ id: '', name: '', sigil: '', slot: null, sandbox_profile: 'docker' });
  const [rt, setRt] = useRgS(REG_RUNTIMES[0].id);
  useRgEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  const persona = personas.find(p => p.id === seed);
  const freeSlot = useRgMemo(() => { for (let n = 1; n <= 12; n++) if (!usedSlots.has(n)) return n; return 1; }, [usedSlots]);

  // pick persona → seed identity defaults from it
  const pickPersona = (p) => {
    setSeed(p.id);
    setIdent(prev => ({ ...prev, slot: prev.slot || freeSlot }));
  };
  const upId = (k, v) => setIdent(prev => ({ ...prev, [k]: v }));
  const onName = (v) => {
    let slug = v.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
    if (!slug && seed) slug = seed.replace(/^p-/, '');   // 한글 등 ascii 없는 이름 → 파일 이름 기반 id
    setIdent(prev => ({ ...prev, name: v, id: prev.idTouched ? prev.id : slug, sigil: prev.sigilTouched ? prev.sigil : v.trim().slice(0, 2).toUpperCase() }));
  };

  const step2Valid = ident.id.trim() && ident.sigil.trim();
  const canNext = step === 0 ? !!seed : step === 1 ? step2Valid : true;

  const rtDef = REG_RUNTIMES.find(r => r.id === rt);
  const finish = () => {
    onCreate({
      id: ident.id.trim(), kr: ident.name.trim() || ident.id.trim(),
      sigil: (ident.sigil || '··').slice(0, 2).toUpperCase(), slot: ident.slot || freeSlot,
      role: 'keeper', status: 'off', phase: 'Stopped',
      model: rtDef.model, runtime: rtDef.id, seed: seed, sandbox_profile: ident.sandbox_profile,
      att: 0, last: '방금', ctx: 0, tps: 0, tasks: 0, traces: 0, sandbox: null, portrait: null,
    });
  };

  return (
    <div className="reg-overlay" onClick={onClose}>
      <div className="reg-dialog reg-wizard" onClick={e => e.stopPropagation()}>
        <div className="reg-dlg-h actual">
          <span className="rd-layer"></span>
          <div>
            <span className="rd-eyebrow">새 Keeper</span>
            <h3>프롬프트 파일로 새 Keeper 만들기</h3>
          </div>
          <button className="reg-dlg-x" onClick={onClose} title="닫기 (Esc)">✕</button>
        </div>

        <div className="rw-steps">
          {RW_STEPS.map(([k, kr, en, sub], i) => (
            <div key={k} className={`rw-step ${k} ${step === i ? 'on' : ''} ${step > i ? 'done' : ''}`}>
              <div className="rw-s-tag"><span className="rw-s-num"><span>{i + 1}</span></span>{en}</div>
              <div className="rw-s-name">{kr}</div>
            </div>
          ))}
        </div>

        <div className="reg-dlg-body">
          {step === 0 && (
            <React.Fragment>
              <div className="rw-section-lbl">새 keeper 가 이 파일을 참조합니다</div>
              <div className="rw-pick">
                {personas.map(p => (
                  <button key={p.id} className={`rw-pick-card ${seed === p.id ? 'on' : ''}`} onClick={() => pickPersona(p)}>
                    <span className="rw-pick-body">
                      <span className="rw-pick-name">{p.name}</span>
                      <span className="rw-pick-desc">{p.desc}</span>
                    </span>
                    <span className="rw-pick-tick">◈</span>
                  </button>
                ))}
              </div>
            </React.Fragment>
          )}

          {step === 1 && (
            <React.Fragment>
              <div className="rw-idrow">
                <div className="rw-preview">
                  <span className="rw-preview-sig" style={{ background: `var(--kp${ident.slot || freeSlot})` }}>{(ident.sigil || '··').slice(0, 2)}</span>
                  <span className="rw-preview-lbl">시길 미리보기</span>
                </div>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 14, minWidth: 0 }}>
                  <div className="reg-field">
                    <label>표시 이름</label>
                    <input className="reg-input" value={ident.name} placeholder="예 · 아틀라스" onChange={e => onName(e.target.value)} autoFocus />
                  </div>
                  <div className="reg-field">
                    <label>keeper id <span className="rf-hint">소문자·숫자·- 만</span></label>
                    <input className="reg-input mono" value={ident.id} placeholder="atlas" onChange={e => setIdent(prev => ({ ...prev, id: e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, ''), idTouched: true }))} />
                  </div>
                </div>
              </div>
              <div className="reg-field">
                <label>시길 <span className="rf-hint">2글자</span></label>
                <input className="reg-input mono" style={{ maxWidth: 120 }} maxLength={2} value={ident.sigil}
                  onChange={e => setIdent(prev => ({ ...prev, sigil: e.target.value.toUpperCase().replace(/\s/g, ''), sigilTouched: true }))} placeholder="AT" />
              </div>
              <div className="reg-field">
                <label>슬롯 색</label>
                <div className="rw-swatches">
                  {Array.from({ length: 12 }, (_, i) => i + 1).map(n => (
                    <button key={n} className={`rw-sw ${ident.slot === n ? 'on' : ''}`} style={{ background: `var(--kp${n})` }}
                      onClick={() => upId('slot', n)} title={usedSlots.has(n) ? `slot ${n} · 사용 중` : `slot ${n}`}>
                      {ident.slot === n && <span className="tick">✓</span>}
                    </button>
                  ))}
                </div>
              </div>
              <div className="reg-field">
                <label>샌드박스 <span className="rf-hint">sandbox_profile</span></label>
                <Segmented options={[{ value: 'docker', label: 'docker' }, { value: 'local', label: 'local · 호스트' }]} value={ident.sandbox_profile} onChange={v => upId('sandbox_profile', v)} />
              </div>
            </React.Fragment>
          )}

          {step === 2 && (
            <React.Fragment>
              <div className="rw-section-lbl">이 keeper가 돌 런타임을 바인딩</div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 9 }}>
                {REG_RUNTIMES.map(r => (
                  <button key={r.id} className={`rw-rt-opt ${rt === r.id ? 'on' : ''}`} onClick={() => setRt(r.id)}>
                    <span className="rw-rt-radio"></span>
                    <span className="rw-rt-body">
                      <span className="rw-rt-id">{r.id}</span>
                      <span className="rw-rt-meta">{r.where === 'cloud' ? '클라우드' : '로컬'} · 최대 컨텍스트 {r.ctx} · {r.model}</span>
                    </span>
                    <span className="rw-rt-badges">{r.badges.map(b => <span key={b} className="rw-rt-badge">{b}</span>)}</span>
                  </button>
                ))}
              </div>
              <div className="rw-summary">
                <div className="rw-sum-cell idea">
                  <div className="rw-sum-tag"><i></i>AGENT.md</div>
                  <div className="rw-sum-val">{persona ? persona.name : '—'}</div>
                </div>
                <div className="rw-sum-cell actual">
                  <div className="rw-sum-tag"><i></i>Keeper</div>
                  <div className="rw-sum-val">{ident.name || ident.id || '—'}</div>
                  <div className="rw-sum-val mono" style={{ color: 'var(--text-dim)', marginTop: 2 }}>{ident.sigil} · slot {ident.slot || freeSlot}</div>
                </div>
                <div className="rw-sum-cell runtime">
                  <div className="rw-sum-tag"><i></i>런타임</div>
                  <div className="rw-sum-val mono">{rtDef.model}</div>
                </div>
              </div>
            </React.Fragment>
          )}
        </div>

        <div className="reg-dlg-foot">
          {step > 0 ? <button className="reg-btn" onClick={() => setStep(s => s - 1)}>← 이전</button> : <span></span>}
          <span className="rf-spacer"></span>
          <button className="reg-btn" onClick={onClose}>취소</button>
          {step < 2
            ? <button className="reg-btn primary" disabled={!canNext} onClick={() => setStep(s => s + 1)}>다음 →</button>
            : <button className="reg-btn primary" onClick={finish}>◈ Keeper 생성</button>}
        </div>
      </div>
    </div>
  );
}

// ══════════════════════════════════════════════════════════════
// Deregister confirm — 실재를 지운다 (실행 중이면 drain 먼저)
// ══════════════════════════════════════════════════════════════
function RegDeregister({ keeper, onClose, onDone }) {
  const running = keeper.status === 'run';
  const [phase, setPhase] = useRgS(running ? 'idle' : 'ready'); // idle → draining → done
  const timer = useRgRef(null);
  useRgEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => { window.removeEventListener('keydown', onKey); clearTimeout(timer.current); };
  }, []);

  const drainThenRemove = () => {
    setPhase('draining');
    timer.current = setTimeout(() => onDone(keeper), 1500);
  };

  return (
    <div className="reg-overlay" onClick={onClose}>
      <div className="reg-dialog" style={{ maxWidth: 460 }} onClick={e => e.stopPropagation()}>
        <div className="reg-dlg-h">
          <div>
            <span className="rd-eyebrow">등록 해제</span>
            <h3>Keeper 등록 해제</h3>
          </div>
          <button className="reg-dlg-x" onClick={onClose} title="닫기 (Esc)">✕</button>
        </div>
        <div className="reg-dlg-body">
          <div className="reg-confirm-kref">
            <SigilBadge k={keeper} size={34} />
            <div className="ck-meta">
              <div className="ck-name">{keeper.kr || keeper.id}</div>
              <div className="ck-sub">{keeper.id} · {keeper.phase}</div>
            </div>
          </div>
          {running ? (
            <div className="reg-confirm-warn">
              <span className="cw-ico">⚠</span>
              <span className="cw-txt">이 keeper는 <b>실행 중</b>입니다. 소유 태스크를 잃지 않으려면 등록 해제 전에 먼저 <b>drain</b>(정상 종료)해야 합니다.</span>
            </div>
          ) : (
            <div className="reg-confirm-msg">레지스트리에서 <b>{keeper.id}</b>를 제거합니다. worktree와 매니페스트 참조가 해제됩니다. 같은 파일을 참조하는 다른 keeper는 영향받지 않습니다.</div>
          )}
        </div>
        <div className="reg-dlg-foot">
          <span className="rf-spacer"></span>
          <button className="reg-btn" onClick={onClose}>취소</button>
          {running
            ? <button className="reg-btn danger" disabled={phase === 'draining'} onClick={drainThenRemove}>{phase === 'draining' ? 'Draining…' : 'drain 후 등록 해제'}</button>
            : <button className="reg-btn danger" onClick={() => onDone(keeper)}>등록 해제</button>}
        </div>
      </div>
    </div>
  );
}

// ══════════════════════════════════════════════════════════════
// Persona delete confirm
// ══════════════════════════════════════════════════════════════
function RegPersonaDelete({ persona, castCount, onClose, onDone }) {
  useRgEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
  return (
    <div className="reg-overlay" onClick={onClose}>
      <div className="reg-dialog" style={{ maxWidth: 460 }} onClick={e => e.stopPropagation()}>
        <div className="reg-dlg-h idea">
          <span className="rd-layer"></span>
          <div>
            <span className="rd-eyebrow">파일 삭제</span>
            <h3>프롬프트 파일 삭제</h3>
          </div>
          <button className="reg-dlg-x" onClick={onClose} title="닫기 (Esc)">✕</button>
        </div>
        <div className="reg-dlg-body">
          <div className="reg-confirm-msg"><b>{persona.name}</b> 프롬프트 파일을 삭제합니다.</div>
          {castCount > 0 && (
            <div className="reg-confirm-warn">
              <span className="cw-ico">◈</span>
              <span className="cw-txt">이 파일을 참조하는 keeper <b>{castCount}개</b>는 다음 턴에 프롬프트를 잃습니다. keeper 를 지우기 전에 다른 파일로 옮겨 주세요.</span>
            </div>
          )}
        </div>
        <div className="reg-dlg-foot">
          <span className="rf-spacer"></span>
          <button className="reg-btn" onClick={onClose}>취소</button>
          <button className="reg-btn danger" onClick={onDone}>형상 삭제</button>
        </div>
      </div>
    </div>
  );
}

// ══════════════════════════════════════════════════════════════
// Registry surface
// ══════════════════════════════════════════════════════════════
function RegistrySurface({ onNav }) {
  const [personas, setPersonas] = useRgS(() => REG_PERSONAS.map(p => ({ ...p, traits: [...p.traits] })));
  const [keepers, setKeepers] = useRgS(() => (window.KEEPERS || []).map(k => ({ ...k, seed: REG_SEED_MAP[k.id] || 'p-base' })));
  const [personaEdit, setPersonaEdit] = useRgS(null);   // persona obj | {} for new
  const [personaDel, setPersonaDel] = useRgS(null);
  const [wizard, setWizard] = useRgS(false);
  const [dereg, setDereg] = useRgS(null);
  const [configK, setConfigK] = useRgS(null);
  const [menu, setMenu] = useRgS(null);                 // keeper id with open menu

  useRgEffect(() => {
    if (!menu) return;
    const close = () => setMenu(null);
    window.addEventListener('click', close);
    return () => window.removeEventListener('click', close);
  }, [menu]);

  const personaById = useRgMemo(() => Object.fromEntries(personas.map(p => [p.id, p])), [personas]);
  const castCount = useRgMemo(() => {
    const m = {};
    keepers.forEach(k => { m[k.seed] = (m[k.seed] || 0) + 1; });
    return m;
  }, [keepers]);
  const usedSlots = useRgMemo(() => new Set(keepers.map(k => k.slot)), [keepers]);

  const groups = useRgMemo(() => {
    const g = { run: [], pause: [], off: [] };
    keepers.forEach(k => { g[window.phaseStatus ? phaseStatus(k.phase) : k.status].push(k); });
    return g;
  }, [keepers]);

  // persona CRUD
  const savePersona = (p, isNew) => {
    setPersonas(prev => isNew ? [...prev, p] : prev.map(x => x.id === p.id ? p : x));
    setPersonaEdit(null);
    if (window.pushToast) window.pushToast({ tone: 'ok', msg: isNew ? '프롬프트 파일 추가됨' : '프롬프트 파일 저장됨', sub: p.name });
  };
  const deletePersona = () => {
    const p = personaDel;
    setPersonas(prev => prev.filter(x => x.id !== p.id));
    setPersonaDel(null);
    if (window.pushToast) window.pushToast({ tone: 'warn', msg: '프롬프트 파일 삭제됨', sub: p.name });
  };

  // keeper create / deregister
  const createKeeper = (k) => {
    setKeepers(prev => prev.some(x => x.id === k.id) ? prev : [...prev, k]);
    setWizard(false);
    const p = personaById[k.seed];
    if (window.pushToast) window.pushToast({ tone: 'ok', msg: `keeper 인스턴스화 · ${k.id}`, sub: `${p ? p.name + ' → ' : ''}Stopped · 시작하면 기동` });
  };
  const removeKeeper = (k) => {
    setKeepers(prev => prev.filter(x => x.id !== k.id));
    setDereg(null);
    if (window.pushToast) window.pushToast({ tone: 'warn', msg: `등록 해제 · ${k.id}`, sub: '레지스트리에서 제거됨' });
  };

  return (
    <main className="reg">
      <div className="reg-scroll">
        <header className="reg-head">
          <div>
            <span className="reg-eyebrow">레지스트리</span>
            <h1>프롬프트 · Keeper · 런타임</h1>
            <p className="reg-sub">AGENT.md 를 골라 keeper 를 만들고, 런타임에 바인딩합니다.</p>
          </div>
          {window.KV && <window.KV.WireBadge tone="demo" label="목업" title="이 화면의 추가·수정·삭제는 세션 내 상태에만 반영됩니다 (mockup)." />}
        </header>

        {/* concept spine */}
        <div className="reg-spine">
          <div className="reg-station idea">
            <div className="rs-tag"><span className="rs-node"></span>AGENT.md</div>
            <div className="rs-name">프롬프트 파일</div>
            <div className="rs-gloss">keeper 프롬프트 전체가 담긴 한 장. 여러 keeper 가 공유할 수 있다.</div>
          </div>
          <div className="reg-arrow">→</div>
          <div className="reg-station actual">
            <div className="rs-tag"><span className="rs-node"></span>KEEPER</div>
            <div className="rs-name">Keeper</div>
            <div className="rs-gloss">파일을 참조하는 실제 에이전트. TOML 은 운영 설정만.</div>
          </div>
          <div className="reg-arrow">→</div>
          <div className="reg-station runtime">
            <div className="rs-tag"><span className="rs-node"></span>RUNTIME</div>
            <div className="rs-name">런타임</div>
            <div className="rs-gloss">keeper가 도는 모델·파이버. 언제든 교체.</div>
          </div>
        </div>

        <div className="reg-cols">
          {/* ── 이데아 · Personas ── */}
          <section className="reg-panel idea">
            <div className="reg-panel-h">
              <span className="rp-layer"></span>
              <h2>프롬프트 파일</h2>
              <span className="rp-kr">AGENT.md</span>
              <span className="rp-count">{personas.length}</span>
              <span className="rp-spacer"></span>
              <button className="reg-add" onClick={() => setPersonaEdit({})}><span className="plus">+</span> 새 프롬프트 파일</button>
            </div>
            <div className="reg-panel-note">keeper 가 참조합니다 — 고치면 참조하는 keeper 전부에 반영됩니다.</div>
            <div className="reg-personas">
              {personas.map(p => (
                <div key={p.id} className="reg-persona">
                  <div className="rp-main">
                    <div className="rp-name-row">
                      <span className="rp-name">{p.name}</span>
                      <span className="rp-path mono">keepers/{p.id.replace(/^p-/, '')}/AGENT.md</span>
                    </div>
                    <p className="rp-desc">{p.desc}</p>
                    <div className="rp-traits">{p.traits.map(t => <span key={t} className="rp-trait">{t}</span>)}</div>
                    <div className="rp-foot">
                      <span className="rp-cast" title="이 파일을 참조하는 keeper 수">◈ keeper <b>{castCount[p.id] || 0}</b></span>
                      <span className="rp-foot-spacer"></span>
                      <button className="rp-act" onClick={() => setPersonaEdit(p)}>수정</button>
                      <button className="rp-act danger" onClick={() => setPersonaDel(p)}>삭제</button>
                    </div>
                  </div>
                </div>
              ))}
              {!personas.length && <div className="reg-empty">프롬프트 파일이 없습니다. 새로 추가하세요.</div>}
            </div>
          </section>

          {/* ── 실재 · Keepers ── */}
          <section className="reg-panel actual">
            <div className="reg-panel-h">
              <span className="rp-layer"></span>
              <h2>Keeper</h2>
              <span className="rp-kr">에이전트</span>
              <span className="rp-count">{keepers.length}</span>
              <span className="rp-spacer"></span>
              <button className="reg-add" onClick={() => setWizard(true)}><span className="plus">+</span> 새 Keeper</button>
            </div>
            <div className="reg-keepers">
              {REG_KGROUPS.map(([key, label, cls]) => groups[key].length ? (
                <div key={key}>
                  <div className={`reg-kgroup ${cls}`}><span className="rg-dot"></span>{label}<span className="rg-n">{groups[key].length}</span></div>
                  <div className="reg-kgrid">
                    {groups[key].map(k => {
                      const p = personaById[k.seed];
                      const tone = (window.PHASE_TONE || {})[k.phase] || 'idle';
                      const pulse = !!(window.PHASE_PULSE && PHASE_PULSE[k.phase]);
                      return (
                        <div key={k.id} className={`reg-keeper ${k.status === 'off' ? 'is-off' : ''}`}>
                          <div className="rk-top">
                            <SigilBadge k={k} size={34} beat={pulse} />
                            <div className="rk-id">
                              <div className="rk-name">{k.id}</div>
                              <div className="rk-phase"><StatusDot status={k.status} pulse={pulse} />{k.phase}</div>
                            </div>
                            <button className="rk-menu-btn" onClick={e => { e.stopPropagation(); setMenu(menu === k.id ? null : k.id); }} title="명령">⋯</button>
                            {menu === k.id && (
                              <div className="rk-menu" onClick={e => e.stopPropagation()}>
                                <button className="rk-menu-i" onClick={() => { setConfigK(k); setMenu(null); }}><span className="g">⚙</span> keeper 설정</button>
                                <button className="rk-menu-i" onClick={() => { onNav && onNav('keepers'); setMenu(null); }}><span className="g">◈</span> 대화 열기</button>
                                <div className="rk-menu-sep"></div>
                                <button className="rk-menu-i danger" onClick={() => { setDereg(k); setMenu(null); }}><span className="g">⊘</span> 등록 해제</button>
                              </div>
                            )}
                          </div>
                          <div className="rk-facet prov" title="참조하는 프롬프트 파일">
                            <span className="rk-f-lyr"></span>
                            <span className="rk-f-arrow">←</span>
                            <span className="rk-f-val">{p ? p.name : '직접 정의'}</span>
                          </div>
                          <div className="rk-facet rt" title="바인딩된 런타임">
                            <span className="rk-f-lyr"></span>
                            <span className="rk-f-val">{k.runtime && k.runtime !== '—' ? k.runtime : k.model}</span>
                            {k.status === 'run' && k.tps > 0 && <span className="rk-tps"><span className="d"></span>{k.tps} tok/s</span>}
                          </div>
                        </div>
                      );
                    })}
                  </div>
                </div>
              ) : null)}
              {!keepers.length && <div className="reg-empty">등록된 keeper가 없습니다. 프롬프트 파일로 새 keeper를 만드세요.</div>}
            </div>
          </section>
        </div>
      </div>

      {personaEdit && <RegPersonaEditor initial={personaEdit.id ? personaEdit : null} onClose={() => setPersonaEdit(null)} onSave={savePersona} />}
      {personaDel && <RegPersonaDelete persona={personaDel} castCount={castCount[personaDel.id] || 0} onClose={() => setPersonaDel(null)} onDone={deletePersona} />}
      {wizard && <RegKeeperWizard personas={personas} usedSlots={usedSlots} onClose={() => setWizard(false)} onCreate={createKeeper} />}
      {dereg && <RegDeregister keeper={dereg} onClose={() => setDereg(null)} onDone={removeKeeper} />}
      {configK && window.KeeperConfigFull && <window.KeeperConfigFull keeper={configK} onClose={() => setConfigK(null)} onNav={onNav} />}
    </main>
  );
}

Object.assign(window, { RegistrySurface, REG_PERSONAS, RegKeeperWizard, RegPersonaEditor, RegPersonaDelete, RegDeregister });
