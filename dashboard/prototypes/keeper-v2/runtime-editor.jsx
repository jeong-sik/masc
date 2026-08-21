/* MASC v2 — Runtime config editor (full-screen overlay, opened from Settings).
   Grounded in config/runtime.toml + runtime_schema.mli: Provider × Model ×
   Binding, routing lanes, keeper assignments. Editable local state, live
   runtime.toml preview, capability validation (librarian/cross_verifier need a
   JSON-capable model). A runtime id is a binding key "provider.model". */
const { useState: useRtS, useEffect: useRtE, useMemo: useRtMemo } = React;

const RT_SECS = [
  ['routing', '라우팅', '◷'],
  ['failover', '페일오버 · 후보 (수동)', '⇄'],
  ['providers', '프로바이더', '◇'],
  ['models', '모델', '▤'],
  ['bindings', '바인딩 · 런타임 id', '◈'],
  ['assignments', 'keeper 배정', '⊙'],
  ['toml', 'runtime.toml', '{ }'],
];

// provider 호출 테스트 결과 (mock) — openai-compatible /v1/models GET 흉내.
const PROVIDER_TEST = {
  ollama_cloud: { ok: true,  ms: 142, detail: 'GET /v1/models · 인증 OK · 6 models' },
  deepseek:     { ok: true,  ms: 88,  detail: 'GET /models · 인증 OK · 3 models' },
  'glm-coding': { ok: true,  ms: 213, detail: 'GET /paas/v4/models · 인증 OK · 4 models' },
  ollama:       { ok: false, error: '연결 거부 · localhost:11434 (ollama serve 미기동?)' },
};

function rtCapChip(on, label) {
  return <span className={`rt-cap ${on ? 'on' : ''}`}>{on ? '✓' : '·'} {label}</span>;
}

function RtSelect({ value, options, onChange, idObjs }) {
  return (
    <select className="rt-select mono" value={value} onChange={e => onChange(e.target.value)}>
      {options.map(o => <option key={o} value={o}>{o}</option>)}
    </select>
  );
}

// live runtime.toml from editor state
function rtToml(st) {
  const L = [];
  L.push('[runtime]');
  L.push(`default = "${st.routing.default}"`);
  L.push(`librarian = "${st.routing.librarian}"`);
  L.push(`cross_verifier = "${st.routing.cross_verifier}"`);
  L.push('');
  st.providers.forEach(p => {
    L.push(`[providers.${p.id}]`);
    L.push(`display-name = "${p.display_name}"`);
    L.push(`protocol = "${p.protocol}"`);
    L.push(`endpoint = "${p.endpoint}"`);
    if (p.credential) {
      L.push(`[providers.${p.id}.credentials]`);
      L.push(`type = "${p.credential.type}"`);
      L.push(`key = "${p.credential.key}"`);
    }
    L.push('');
  });
  st.bindings.forEach(b => {
    const key = `${b.provider_id}.${b.model_id}`;
    L.push(`[${key}]`);
    if (b.max_concurrent != null) L.push(`max-concurrent = ${b.max_concurrent}`);
    if (b.num_ctx != null) L.push(`num-ctx = ${b.num_ctx}`);
    L.push('');
  });
  if (st.rotation) {
    L.push('[runtime.failover]');
    L.push('# configured candidate preference per lane. 자동 failover 미구현(❌):');
    L.push('# provider 실패 시 이 값(또는 [runtime].default/assignment) 수정 + 서버 재시작.');
    Object.keys(st.rotation).forEach(lane => {
      L.push(`${lane} = [${st.rotation[lane].order.map(o => `"${o}"`).join(', ')}]`);
    });
    L.push(`expand_on_transient = ${!!(st.rotation.default && st.rotation.default.expand_on_transient)}   # 턴 내 transient 오류만 카탈로그로 확장 재시도`);
    L.push('# capacity_backpressure 는 관측 신호 — 실행을 막거나 keeper 를 pause 하지 않음');
    L.push('');
  }
  L.push('[runtime.assignments]');
  Object.keys(st.assignments).forEach(k => {
    if (st.assignments[k] && st.assignments[k] !== st.routing.default) L.push(`${k} = "${st.assignments[k]}"`);
  });
  return L.join('\n');
}

function RuntimeEditor({ onClose }) {
  const ids = window.rtRuntimeIds();
  const [sec, setSec] = useRtS('routing');
  const [modelQ, setModelQ] = useRtS('');
  const [tests, setTests] = useRtS({}); // provider id → { status:'testing'|'ok'|'fail', ... }
  const runTest = (p) => {
    setTests(prev => ({ ...prev, [p.id]: { status: 'testing' } }));
    const r = PROVIDER_TEST[p.id] || { ok: true, ms: 120, detail: 'GET /v1/models · OK' };
    setTimeout(() => setTests(prev => ({ ...prev, [p.id]: r.ok ? { status: 'ok', detail: r.detail, ms: r.ms } : { status: 'fail', error: r.error } })), 500 + Math.round(Math.random() * 500));
  };
  const [st, setSt] = useRtS(() => ({
    routing: { ...window.RT_ROUTING },
    providers: window.RT_PROVIDERS.map(p => ({ ...p, credential: p.credential ? { ...p.credential } : null, caps: { ...p.caps } })),
    bindings: window.RT_BINDINGS.map(b => ({ ...b })),
    assignments: Object.fromEntries((window.KEEPERS || []).map(k => [k.id, k.runtime && k.runtime !== '—' ? k.runtime : window.RT_ROUTING.default])),
    rotation: JSON.parse(JSON.stringify(window.RT_ROTATION || {})),
  }));
  useRtE(() => {
    const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  const setRouting = (lane, v) => setSt(s => ({ ...s, routing: { ...s.routing, [lane]: v } }));
  const setProvider = (i, patch) => setSt(s => ({ ...s, providers: s.providers.map((p, j) => j === i ? { ...p, ...patch } : p) }));
  const setBinding = (i, patch) => setSt(s => ({ ...s, bindings: s.bindings.map((b, j) => j === i ? { ...b, ...patch } : b) }));
  const setDefaultBinding = (i) => setSt(s => ({
    ...s,
    bindings: s.bindings.map((b, j) => ({ ...b, is_default: j === i })),
    routing: { ...s.routing, default: `${s.bindings[i].provider_id}.${s.bindings[i].model_id}` },
  }));
  const setAssign = (kid, v) => setSt(s => ({ ...s, assignments: { ...s.assignments, [kid]: v } }));
  // failover rotation edits — reorder / add / remove candidates, toggle transient expand
  const moveRot = (lane, i, dir) => setSt(s => {
    const order = s.rotation[lane].order.slice();
    const j = i + dir; if (j < 0 || j >= order.length) return s;
    [order[i], order[j]] = [order[j], order[i]];
    return { ...s, rotation: { ...s.rotation, [lane]: { ...s.rotation[lane], order } } };
  });
  const dropRot = (lane, i) => setSt(s => {
    if (s.rotation[lane].order.length <= 1) return s;
    const order = s.rotation[lane].order.filter((_, j) => j !== i);
    return { ...s, rotation: { ...s.rotation, [lane]: { ...s.rotation[lane], order } } };
  });
  const addRot = (lane, id) => setSt(s => {
    if (!id || s.rotation[lane].order.includes(id)) return s;
    return { ...s, rotation: { ...s.rotation, [lane]: { ...s.rotation[lane], order: [...s.rotation[lane].order, id] } } };
  });
  const toggleExpand = (lane) => setSt(s => ({ ...s, rotation: { ...s.rotation, [lane]: { ...s.rotation[lane], expand_on_transient: !s.rotation[lane].expand_on_transient } } }));

  const tomlText = useRtMemo(() => rtToml(st), [st]);

  // ── routing ──
  const laneRow = (lane, label, hint, needJson) => {
    const cap = window.rtCaps(st.routing[lane]);
    const bad = needJson && cap && !cap.json;
    return (
      <div className="rt-lane">
        <div className="rt-lane-l"><div className="rt-lane-lbl">{label}</div><div className="rt-lane-hint">{hint}</div></div>
        <div className="rt-lane-c">
          <RtSelect value={st.routing[lane]} options={ids} onChange={v => setRouting(lane, v)} />
          {bad ? <span className="rt-warn">⚠ JSON 미지원 모델</span> : cap && needJson ? <span className="rt-ok">✓ JSON</span> : null}
        </div>
      </div>
    );
  };

  const filteredModels = window.RT_MODELS.filter(m => !modelQ || m.id.includes(modelQ) || m.api_name.toLowerCase().includes(modelQ.toLowerCase()));

  return (
    <div className="rt-overlay">
      <div className="rt-shell">
        <nav className="rt-nav">
          <div className="rt-nav-h">
            <div className="eyebrow">Operator</div>
            <div className="rt-nav-title">런타임 편집기</div>
            <div className="rt-nav-sub mono">config/runtime.toml</div>
          </div>
          {RT_SECS.map(([id, lbl, gl]) => (
            <button key={id} className={`rt-nav-item ${sec === id ? 'on' : ''}`} onClick={() => setSec(id)}>
              <span className="rt-nav-gl mono">{gl}</span><span>{lbl}</span>
            </button>
          ))}
          <div className="rt-nav-foot mono">{ids.length} 런타임 · {st.providers.length} 프로바이더</div>
        </nav>

        <div className="rt-content">
          <header className="rt-head">
            <h1>{(RT_SECS.find(s => s[0] === sec) || [])[1]}</h1>
            <div className="rt-head-actions">
              <button className="rt-save">변경사항 저장</button>
              <button className="rt-close" onClick={onClose} title="닫기 (Esc)">{'\u2715'}</button>
            </div>
          </header>

          <div className="rt-body">
            {sec === 'routing' && (
              <React.Fragment>
                <div className="rt-note">런타임 id = <span className="mono">provider.model</span> (binding key). 레인은 등록된 바인딩 중에서 고릅니다.</div>
                {laneRow('default', '기본 런타임', '[runtime].default — 배정 없는 keeper가 사용', false)}
                {laneRow('librarian', 'memory-os 라이브러리안', '[runtime].librarian — 턴 후 에피소드 추출, JSON 모드 필요', true)}
                {laneRow('cross_verifier', 'cross-verifier', '[runtime].cross_verifier — 반-합리화 평가, JSON 모드 필요', true)}
              </React.Fragment>
            )}

            {sec === 'failover' && (
              <React.Fragment>
                <div className="rt-note"><b style={{ color: 'var(--status-bad)' }}>자동 페일오버 미구현 (❌)</b> — provider 실패 시 아래 후보 순서로 자동 전환하지 <b>않습니다</b>. 이 값은 runtime.toml 의 <span className="mono">구성된 후보 선호</span>일 뿐, 실제 페일오버는 값 수정 + 서버 재시작이 필요합니다. 턴 내 <span className="mono">transient</span> 오류만 카탈로그로 확장해 재시도하며, <span className="mono">capacity_backpressure</span> 는 관측 신호일 뿐 keeper 를 pause 하지 않습니다.</div>
                {Object.keys(st.rotation).map(lane => {
                  const r = st.rotation[lane];
                  const spare = ids.filter(id => !r.order.includes(id));
                  return (
                    <div key={lane} className="rt-fo">
                      <div className="rt-fo-h">
                        <span className="rt-fo-lane">{r.label}</span>
                        <span className="rt-fo-lane-id mono">[runtime].{lane}</span>
                      </div>
                      <div className="rt-fo-note">{r.note}</div>
                      <div className="rt-fo-chain">
                        {r.order.map((id, i) => (
                          <div key={id} className={`rt-fo-cand ${i === 0 ? 'head' : ''}`}>
                            <span className="rt-fo-rank mono">{i === 0 ? '1차' : `${i + 1}`}</span>
                            <span className="rt-fo-id mono">{id}</span>
                            <span className="rt-fo-cand-acts">
                              <button className="rt-fo-mv" disabled={i === 0} onClick={() => moveRot(lane, i, -1)} title="위로">▲</button>
                              <button className="rt-fo-mv" disabled={i === r.order.length - 1} onClick={() => moveRot(lane, i, 1)} title="아래로">▼</button>
                              <button className="rt-fo-mv del" disabled={r.order.length <= 1} onClick={() => dropRot(lane, i)} title="후보에서 제거">✕</button>
                            </span>
                          </div>
                        ))}
                      </div>
                      <div className="rt-fo-foot">
                        {spare.length > 0 && (
                          <select className="rt-select mono rt-fo-add" value="" onChange={e => { if (e.target.value) addRot(lane, e.target.value); }}>
                            <option value="">＋ 후보 추가…</option>
                            {spare.map(id => <option key={id} value={id}>{id}</option>)}
                          </select>
                        )}
                        <label className="rt-fo-toggle" title="transient 인프라 오류 시 후보를 전체 런타임 카탈로그로 확장">
                          <input type="checkbox" checked={!!r.expand_on_transient} onChange={() => toggleExpand(lane)} />
                          <span>transient 오류 시 카탈로그 확장</span>
                        </label>
                        <span className="rt-fo-cap mono" title="capacity_backpressure 는 관측 신호 — 실행 차단·pause 아님">관측 · {r.cap}</span>
                      </div>
                    </div>
                  );
                })}

                <div className="rt-fo-log">
                  <div className="rt-fo-log-h">최근 런타임 시도 <span className="mono">턴 내 재시도 · 수동 페일오버</span></div>
                  {(window.ROTATION_EVENTS || []).map((e, i) => (
                    <div key={i} className={`rt-fo-ev out-${e.outcome}`}>
                      <span className="rt-fo-ev-at mono">{e.at}</span>
                      <span className={`rt-fo-ev-out ${e.outcome}`}>{e.outcome === 'recovered' ? '↻ 재시도' : '⚠ backpressure'}</span>
                      <span className="rt-fo-ev-kp mono">{e.keeper}</span>
                      <span className="rt-fo-ev-lane mono">{e.lane}</span>
                      <span className="rt-fo-ev-hop mono">
                        {e.from}{e.to && e.to !== e.from ? <React.Fragment> <span className="rt-fo-arr">→</span> {e.to} <span className="rt-fo-arr">(턴 내)</span></React.Fragment> : e.to === e.from ? ' · 재시도' : ' · 관측 신호'}
                      </span>
                      <span className="rt-fo-ev-reason">{e.reason}{e.expanded ? ' · 카탈로그 확장' : ''}</span>
                    </div>
                  ))}
                </div>
              </React.Fragment>
            )}

            {sec === 'providers' && (
              <div className="rt-cards">
                {st.providers.map((p, i) => (
                  <div key={p.id} className="rt-card">
                    <div className="rt-card-h">
                      <span className="rt-card-id mono">{p.id}</span>
                      <span className="rt-card-name">{p.display_name}</span>
                      <span className="rt-proto mono">{p.protocol}</span>
                    </div>
                    <div className="rt-field"><span className="sub-k">endpoint</span><input className="rt-input mono" value={p.endpoint} onChange={e => setProvider(i, { endpoint: e.target.value })} /></div>
                    <div className="rt-field"><span className="sub-k">credential</span>{p.credential
                      ? <span className="rt-cred"><span className="rt-cred-type mono">{p.credential.type}</span><input className="rt-input mono" value={p.credential.key} onChange={e => setProvider(i, { credential: { ...p.credential, key: e.target.value } })} /></span>
                      : <span className="rt-cred-none mono">없음 (로컬)</span>}</div>
                    <div className="rt-caps">
                      {rtCapChip(p.caps.mcpTools, 'mcp-tools')}
                      {rtCapChip(p.caps.toolEvents, 'tool-events')}
                      {rtCapChip(p.caps.mcpHeaders, 'mcp-http-headers')}
                    </div>
                    <div className="rt-test">
                      <button className="rt-test-btn" onClick={() => runTest(p)} disabled={tests[p.id] && tests[p.id].status === 'testing'}>
                        {tests[p.id] && tests[p.id].status === 'testing' ? '연결 중…' : '⚡ 호출 테스트'}
                      </button>
                      {tests[p.id] && tests[p.id].status === 'testing' && <span className="rt-test-r pending mono">◌ {p.credential ? 'GET /v1/models · 인증' : 'GET /v1/models'} …</span>}
                      {tests[p.id] && tests[p.id].status === 'ok' && <span className="rt-test-r ok mono">✓ {tests[p.id].detail} · {tests[p.id].ms}ms</span>}
                      {tests[p.id] && tests[p.id].status === 'fail' && <span className="rt-test-r fail mono">✕ {tests[p.id].error}</span>}
                    </div>
                  </div>
                ))}
              </div>
            )}

            {sec === 'models' && (
              <React.Fragment>
                <input className="rt-search mono" placeholder="모델 검색 — id / api-name" value={modelQ} onChange={e => setModelQ(e.target.value)} />
                <div className="rt-models">
                  {filteredModels.map(m => (
                    <div key={m.id} className="rt-model">
                      <div className="rt-model-h">
                        <span className="rt-model-id mono">{m.id}</span>
                        <span className="rt-model-api mono">{m.api_name}</span>
                        <span className="rt-model-ctx mono">{(m.max_context / 1000).toFixed(0)}k ctx</span>
                      </div>
                      <div className="rt-caps">
                        {rtCapChip(m.tools, 'tools')}
                        {rtCapChip(m.thinking, 'thinking')}
                        {rtCapChip(m.caps.toolChoice, 'tool-choice')}
                        {rtCapChip(m.caps.json, 'json')}
                        {rtCapChip(m.caps.structured, 'structured')}
                        {rtCapChip(m.caps.multimodal || m.caps.image, 'multimodal')}
                        <span className="rt-cap tcf mono">effort: {window.RT_TCF[m.caps.tcf] || m.caps.tcf}</span>
                      </div>
                    </div>
                  ))}
                </div>
              </React.Fragment>
            )}

            {sec === 'bindings' && (
              <div className="rt-binds">
                <div className="rt-note">바인딩 = 런타임 id <span className="mono">provider.model</span>. 라디오로 기본 런타임 지정.</div>
                {st.bindings.map((b, i) => {
                  const key = `${b.provider_id}.${b.model_id}`;
                  const m = window.rtModelOf(b.model_id);
                  return (
                    <div key={key} className={`rt-bind ${b.is_default ? 'is-default' : ''}`}>
                      <button className={`rt-radio ${b.is_default ? 'on' : ''}`} onClick={() => setDefaultBinding(i)} title="기본 런타임으로">{b.is_default ? '◉' : '○'}</button>
                      <div className="rt-bind-main">
                        <div className="rt-bind-key mono">{key}{b.is_default && <span className="rt-default-tag">default</span>}</div>
                        <div className="rt-bind-sub mono">{m ? `${(m.max_context / 1000).toFixed(0)}k ctx · ${window.RT_TCF[m.caps.tcf]}` : '—'}{b.price_in != null ? ` · $${b.price_in}/$${b.price_out} per M` : ''}</div>
                      </div>
                      <div className="rt-bind-fields">
                        <label className="rt-mini"><span>max-conc</span><input className="rt-input-sm mono" value={b.max_concurrent == null ? '' : b.max_concurrent} placeholder="∞" onChange={e => setBinding(i, { max_concurrent: e.target.value === '' ? null : +e.target.value })} /></label>
                        <label className="rt-mini"><span>num-ctx</span><input className="rt-input-sm mono" value={b.num_ctx == null ? '' : b.num_ctx} placeholder="—" onChange={e => setBinding(i, { num_ctx: e.target.value === '' ? null : +e.target.value })} /></label>
                      </div>
                    </div>
                  );
                })}
              </div>
            )}

            {sec === 'assignments' && (
              <div className="rt-assigns">
                <div className="rt-note">[runtime.assignments] — keeper → 런타임 id. <span className="mono">default</span>와 같으면 toml에서 생략(폴백).</div>
                {(window.KEEPERS || []).map(k => {
                  const cur = st.assignments[k.id];
                  const isDefault = cur === st.routing.default;
                  return (
                    <div key={k.id} className="rt-assign">
                      <span className="rt-assign-k"><StatusDot status={k.status === 'run' ? 'run' : k.status === 'pause' ? 'idle' : 'bad'} /><span className="mono">{k.id}</span></span>
                      <RtSelect value={cur} options={ids} onChange={v => setAssign(k.id, v)} />
                      {isDefault ? <span className="rt-assign-tag mono">↳ default 폴백</span> : <span className="rt-assign-tag pin mono">고정</span>}
                    </div>
                  );
                })}
              </div>
            )}

            {sec === 'toml' && (
              <div className="rt-toml-wrap">
                <div className="rt-toml-bar">
                  <span className="mono">config/runtime.toml</span>
                  <span className="rt-toml-ro">읽기 전용 · 위 섹션에서 편집</span>
                  <button className="rt-copy" onClick={() => { navigator.clipboard && navigator.clipboard.writeText(tomlText); }}>복사</button>
                </div>
                <pre className="rt-toml"><code>{tomlText}</code></pre>
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { RuntimeEditor });
