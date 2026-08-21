/* MASC v2 — Fusion surface (RFC-0252): panel + judge 심의 가시화.
   Master-detail — left = 심의 런 목록(run queue), main = 선택된 런의 전체 심의:
   prompt → 패널 fan-out(N 모델 병렬) → 심판 종합(5필드) → 결론(decision) → sink(chat lane + board).
   Fills the RFC's named dashboard gap (§8.2 meta 뷰어 부재). Load AFTER fusion-data.jsx
   + messages.jsx (SigilBadge) + shell.jsx; BEFORE app.jsx. */
const { useState: useFusState, useEffect: useFusEffect } = React;

function fusKeeper(id) { return (window.KEEPERS || []).find(k => k.id === id) || null; }

function FusKeeperLink({ id, onOpen, size = 22 }) {
  const k = fusKeeper(id);
  if (!k) return <span className="fus-who static">{id}</span>;
  const badge = <SigilBadge k={k} size={size} />;
  return (
    <button type="button" className="fus-who" title={`${id} 대화 열기`}
      onClick={(e) => { e.stopPropagation(); onOpen && onOpen(id); }}>
      {badge}<span className="nm">{id}</span>
    </button>
  );
}

function StatusGlyph({ status }) {
  if (status === 'running') return <span className="fus-rdot run" title="심의 진행 중"></span>;
  if (status === 'denied')  return <span className="fus-rdot deny" title="게이트 거부">✕</span>;
  return <span className="fus-rdot done" title="완료">✓</span>;
}

function fmtTok(u) {
  if (!u) return '—';
  const t = (u.in || 0) + (u.out || 0);
  return t >= 1000 ? (t / 1000).toFixed(1) + 'k' : String(t);
}

// ── one panel model's outcome ──
function PanelCard({ p }) {
  const failed = !!p.reason;
  const running = p.status === 'running';
  const [open, setOpen] = useFusState(false);
  return (
    <div className={`fus-pcard ${failed ? 'failed' : ''} ${running ? 'running' : ''}`}>
      <div className="fus-pcard-h">
        <span className="fus-pmodel mono">{p.model}</span>
        {running && <span className="fus-pstate run">응답 중<span className="dots"><i></i><i></i><i></i></span></span>}
        {failed && <span className="fus-pstate fail">{(window.PANEL_FAIL || {})[p.reason] || p.reason}</span>}
        {!running && !failed && p.conf != null && (
          <span className="fus-conf" title={`자기 확신도 ${Math.round(p.conf * 100)}%`}>
            <span className="fus-conf-bar"><i style={{ width: (p.conf * 100) + '%' }}></i></span>
            <span className="mono">{Math.round(p.conf * 100)}%</span>
          </span>
        )}
        {!running && !failed && <span className="fus-ptok mono" title="입력+출력 토큰">{fmtTok(p.usage)} tok</span>}
      </div>
      {!running && !failed && (
        <div className={`fus-pans ${open ? 'open' : ''}`} onClick={() => setOpen(o => !o)} title={open ? '접기' : '펼치기'}>
          <FusText text={p.answer} />
        </div>
      )}
      {running && <div className="fus-pans skeleton"><span></span><span></span><span></span></div>}
    </div>
  );
}

// ── judge synthesis: the 5 structured fields ──
function ModelChips({ models }) {
  return <span className="fus-mchips">{models.map(m => <span key={m} className="fus-mchip mono">{m}</span>)}</span>;
}

function JudgeSynthesis({ j }) {
  return (
    <div className="fus-judge-body">
      {j.consensus.length > 0 && (
        <section className="fus-jsec consensus">
          <h5><span className="fus-jglyph">≡</span>합의 <span className="n">{j.consensus.length}</span></h5>
          {j.consensus.map((c, i) => (
            <div key={i} className="fus-claim"><p>{c.text}</p><ModelChips models={c.models} /></div>
          ))}
        </section>
      )}
      {j.contradictions.length > 0 && (
        <section className="fus-jsec contra">
          <h5><span className="fus-jglyph">⇄</span>상충 <span className="n">{j.contradictions.length}</span></h5>
          {j.contradictions.map((c, i) => (
            <div key={i} className="fus-contra">
              <div className="fus-contra-topic">{c.topic}</div>
              {c.positions.map(([m, stance], k) => (
                <div key={k} className="fus-pos"><span className="fus-pos-m mono">{m}</span><span className="fus-pos-s">{stance}</span></div>
              ))}
            </div>
          ))}
        </section>
      )}
      {j.partial_coverage.length > 0 && (
        <section className="fus-jsec coverage">
          <h5><span className="fus-jglyph">◑</span>부분 커버리지 <span className="n">{j.partial_coverage.length}</span></h5>
          {j.partial_coverage.map((g, i) => (
            <div key={i} className="fus-gap">
              <div className="fus-gap-topic">{g.topic}</div>
              <div className="fus-gap-row"><span className="k">다룸</span><ModelChips models={g.addressed_by} /></div>
              <div className="fus-gap-row"><span className="k">누락</span><span className="fus-gap-miss">{g.missing}</span></div>
            </div>
          ))}
        </section>
      )}
      {j.unique_insights.length > 0 && (
        <section className="fus-jsec insight">
          <h5><span className="fus-jglyph">✦</span>고유 통찰 <span className="n">{j.unique_insights.length}</span></h5>
          {j.unique_insights.map((u, i) => (
            <div key={i} className="fus-insight"><p>{u.text}</p><span className="fus-mchip mono">{u.model}</span></div>
          ))}
        </section>
      )}
      {j.blind_spots.length > 0 && (
        <section className="fus-jsec blind">
          <h5><span className="fus-jglyph">⚠</span>사각지대 <span className="n">{j.blind_spots.length}</span></h5>
          <ul className="fus-blind">{j.blind_spots.map((b, i) => <li key={i}>{b}</li>)}</ul>
        </section>
      )}
    </div>
  );
}

// ── derived deliberation shape (fusion_types.ml §judge_role / RFC-0284 §4):
//    the dashboard reads STRUCTURE from the judge-array shape, NOT a topology
//    name. First-role judges + a Meta judge ⇒ judge-of-judges; a single judge
//    ⇒ simple. run.topology survives only to tell refine↔conditional apart
//    (a runtime escalation policy — not a structural fact you can see in the record). ──
function fusionShape(run) {
  const panelN = (run.panel || []).length
    || (((window.FUSION_PRESETS[run.preset] || {}).panel) || []).length || 0;
  const firsts = (run.judges || []).filter(j => (j.role || 'first') === 'first');
  const dropped = firsts.filter(j => j.status === 'failed').map(j => ({ id: j.identity, fail: j.fail }));
  const okN = firsts.length - dropped.length;
  const hasMeta = !!(run.judge && run.judge.role === 'meta');
  let key;
  if (firsts.length >= 1 && hasMeta) key = 'judge_of_judges';
  else if (run.topology === 'refine' || run.topology === 'conditional') key = run.topology;
  else key = 'simple';
  return {
    key, panelN, firstN: firsts.length, okN, dropped,
    isJoj: key === 'judge_of_judges',
    isRefine: key === 'refine' || key === 'conditional',
    conditional: key === 'conditional',
  };
}

// ── pipeline strip: shape-derived (no hardcoded topology branch) ──
function PipeStrip({ run }) {
  const sh = fusionShape(run);
  const denied = run.status === 'denied';
  const running = run.status === 'running';
  const off = denied || running;
  return (
    <div className="fus-pipe">
      <span className="fus-pipe-node kp">키퍼 턴</span>
      <span className="fus-pipe-arr">→</span>
      <span className={`fus-pipe-node gate ${denied ? 'deny' : 'ok'}`}>게이트</span>
      <span className="fus-pipe-arr">→</span>
      <span className={`fus-pipe-node panel ${denied ? 'off' : ''}`}>패널{sh.panelN ? ` ×${sh.panelN}` : ''}</span>
      <span className="fus-pipe-arr">→</span>
      {sh.isJoj ? (
        <React.Fragment>
          <span className={`fus-pipe-node judge ${off ? 'off' : ''}`}>1차 심판 ×{sh.firstN}{sh.dropped.length > 0 && <em className="fus-pipe-iso"> {sh.dropped.length} 격리</em>}</span>
          <span className="fus-pipe-arr">→</span>
          <span className={`fus-pipe-node meta ${off ? 'off' : ''}`}>meta</span>
        </React.Fragment>
      ) : sh.isRefine ? (
        <React.Fragment>
          <span className={`fus-pipe-node judge ${off ? 'off' : ''}`}>심판</span>
          <span className="fus-pipe-arr">→</span>
          <span className={`fus-pipe-node meta ${off ? 'off' : ''}`}>재검토{sh.conditional ? '?' : ''}</span>
        </React.Fragment>
      ) : (
        <span className={`fus-pipe-node judge ${off ? 'off' : ''}`}>심판</span>
      )}
      <span className="fus-pipe-arr">→</span>
      <span className={`fus-pipe-node sink ${off ? 'off' : ''}`}>chat · board</span>
    </div>
  );
}

// ── inline rich text (markdown → blocks) for prompt + panel answers (design 2026-06-24) ──
function FusText({ text }) {
  const blocks = (typeof mdToBlocks === 'function')
    ? mdToBlocks(String(text || ''))
    : [{ t: 'p', html: String(text || '').replace(/&/g, '&amp;').replace(/</g, '&lt;') }];
  return <div className="fus-rich">{blocks.map((b, i) => <Block key={i} b={b} />)}</div>;
}

// ── derived JOJ counts — a first-tier judge's 합의/상충 수는 meta의 consensus[]/
//    contradictions[] 에서 세어서 나온다(별도 저장 안 함 — 단일 진실원천). ──
function jojConsensusCount(meta, identity) {
  if (!meta || !Array.isArray(meta.consensus)) return null;
  return meta.consensus.filter(c => (c.models || []).includes(identity)).length;
}
function jojContraCount(meta, identity) {
  if (!meta || !Array.isArray(meta.contradictions)) return null;
  return meta.contradictions.filter(c => (c.positions || []).some(p => p[0] === identity)).length;
}

// ── JOJ first-tier judges: N independent syntheses before meta reconcile.
//    심판 수(N)는 패널 수와 무관(RFC-0283 §1.1) · 실패한 1차 심판은 격리되어 meta 제외(§2.3). ──
function FirstJudges({ judges, meta }) {
  return (
    <div className="fus-jnodes">
      {judges.map((j, i) => {
        if (j.status === 'failed') {
          const fl = (window.PANEL_FAIL || {})[j.fail] || j.fail || '실패';
          return (
            <div key={i} className="fus-jnode failed">
              <div className="fus-jnode-h">
                <span className="fus-jnode-id">{j.identity}</span>
                <span className="fus-jnode-model mono">{j.model}</span>
                <span className="fus-jnode-fail">✗ {fl}</span>
              </div>
              {j.lens && <div className="fus-jnode-lens">{j.lens}</div>}
              <p className="fus-jnode-isolated">격리됨 — meta reconcile에서 제외. 나머지 종합으로 진행(§2.3 격리).</p>
            </div>
          );
        }
        const dec = (window.FUSION_DECISION || {})[j.decision];
        const consensusN = jojConsensusCount(meta, j.identity);
        const contraN = jojContraCount(meta, j.identity);
        return (
          <div key={i} className="fus-jnode">
            <div className="fus-jnode-h">
              <span className="fus-jnode-id">{j.identity}</span>
              <span className="fus-jnode-model mono">{j.model}</span>
              {dec && <span className={`fus-dec-badge sm ${dec.cls}`}>{dec.glyph} {dec.lbl}</span>}
            </div>
            {j.lens && <div className="fus-jnode-lens">{j.lens}</div>}
            <p className="fus-jnode-sum">{j.summary}</p>
            <div className="fus-jnode-f">
              {consensusN != null && <span className="fus-jnode-stat">합의 {consensusN}</span>}
              {contraN != null && <span className="fus-jnode-stat">상충 {contraN}</span>}
              <span className="fus-jnode-tok mono">{fmtTok(j.usage)} tok</span>
            </div>
          </div>
        );
      })}
    </div>
  );
}

// ── generation parameters block (design 2026-06-24 §3) — hidden when all null ──
function ParamsBlock({ params }) {
  if (!params) return null;
  const rows = [['temperature', params.temperature], ['top_p', params.top_p], ['top_k', params.top_k], ['max_tokens', params.max_tokens]]
    .filter(([, v]) => v != null);
  if (!rows.length) return null;
  return (
    <div className="fus-block">
      <div className="fus-block-lbl">생성 파라미터 <span className="fus-sub-note">board meta_json · 있을 때만 표시</span></div>
      <div className="fus-params">
        {rows.map(([k, v]) => (
          <span key={k} className="fus-param"><span className="k">{k}</span><span className="v mono">{v}</span></span>
        ))}
      </div>
    </div>
  );
}

// ── master list row ──
function RunRow({ run, sel, onSel, onOpenKeeper }) {
  const trig = (window.FUSION_TRIGGER || {})[run.trigger] || { lbl: run.trigger, glyph: '◈' };
  const dec = run.judge && (window.FUSION_DECISION || {})[run.judge.decision];
  return (
    <div className={`fus-row ${sel ? 'sel' : ''} st-${run.status}`} role="button" tabIndex={0} onClick={() => onSel(run.run_id)} onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onSel(run.run_id); } }}>
      <div className="fus-row-h">
        <StatusGlyph status={run.status} />
        <span className="fus-run-id mono">{run.run_id}</span>
        {fusionShape(run).isJoj && <span className="fus-row-topo" title="judge-of-judges">JoJ</span>}
        <span className="fus-row-ts">{run.age}</span>
      </div>
      <div className="fus-row-prompt">{run.prompt}</div>
      <div className="fus-row-f">
        <FusKeeperLink id={run.keeper} onOpen={onOpenKeeper} size={18} />
        <span className="fus-trig" title={`발동: ${trig.lbl}`}>{trig.lbl}</span>
        <span className="spacer"></span>
        {run.status === 'denied' && <span className="fus-dec-badge bad">거부</span>}
        {run.status === 'running' && <span className="fus-dec-badge run">심의 중</span>}
        {dec && <span className={`fus-dec-badge ${dec.cls}`}>{dec.glyph} {dec.lbl}</span>}
      </div>
    </div>
  );
}

// ── resolved_answer as rich text ──
// judge.resolved_answer 는 한 줄~긴 문서까지 올 수 있다. 채팅 버블과 같은
// 마크다운→블록 파이프라인(mdToBlocks + Block, 전역)으로 렌더해 제목·강조·
// 목록·코드펜스·표를 살린다. 길면 클램프 + 전문 펼치기.
function FusResolved({ text }) {
  const [open, setOpen] = useFusState(false);
  const blocks = (typeof mdToBlocks === 'function')
    ? mdToBlocks(text)
    : [{ t: 'p', html: String(text || '').replace(/&/g, '&amp;').replace(/</g, '&lt;') }];
  const long = String(text || '').length > 540 || blocks.length > 5;
  return (
    <React.Fragment>
      <div className={`fus-rich ${long && !open ? 'clamp' : ''}`}>
        {blocks.map((b, i) => <Block key={i} b={b} />)}
      </div>
      {long && (
        <button type="button" className="fus-rich-more" onClick={() => setOpen(o => !o)}>
          {open ? '접기 \u25B4' : '전문 펼치기 \u25BE'}
        </button>
      )}
    </React.Fragment>
  );
}

// ── main canvas ──
function FusionRun({ run, onOpenKeeper, onNav }) {
  const preset = window.FUSION_PRESETS[run.preset] || {};
  const trig = (window.FUSION_TRIGGER || {})[run.trigger] || { lbl: run.trigger };
  const dec = run.judge && (window.FUSION_DECISION || {})[run.judge.decision];
  const panelTok = (run.panel || []).reduce((s, p) => s + (p.usage ? (p.usage.in + p.usage.out) : 0), 0);
  const judgeTok = run.judge && run.judge.usage ? run.judge.usage.in + run.judge.usage.out : 0;

  return (
    <div className="fus-run-scroll">
      {/* header */}
      <div className="fus-run-head">
        <div className="fus-run-id-row">
          <StatusGlyph status={run.status} />
          <h1 className="mono">{run.run_id}</h1>
          <span className="fus-preset" title="runtime.toml [fusion.presets.*]">preset · {run.preset}</span>
          {(() => { const t = (window.FUSION_TOPOLOGY || {})[fusionShape(run).key]; return t && (
            <span className="fus-topo" title={t.desc}>{t.lbl}</span>
          ); })()}
          <span className="fus-trig-chip">{trig.lbl}</span>
        </div>
        <div className="fus-run-by">
          <FusKeeperLink id={run.keeper} onOpen={onOpenKeeper} size={24} />
          <span className="fus-run-meta">심의 요청 · {run.ts}{run.latency_ms ? ` · 지연 ${(run.latency_ms / 1000).toFixed(1)}s` : ''}</span>
        </div>
      </div>

      <PipeStrip run={run} />

      <ParamsBlock params={run.params} />

      {/* kpi strip */}
      <div className="fus-kpis">
        <div className="fus-kpi"><div className="k">패널</div><div className="v">{run.panel ? run.panel.length : preset.panel?.length || '—'}<small> 모델</small></div></div>
        <div className="fus-kpi"><div className="k">토큰 (패널+심판)</div><div className="v">{run.status === 'done' ? ((panelTok + judgeTok) / 1000).toFixed(1) + 'k' : '—'}</div></div>
        <div className="fus-kpi"><div className="k">비용 (관측)</div><div className="v">{run.cost_usd != null ? '$' + run.cost_usd.toFixed(4) : '—'}</div></div>
        <div className="fus-kpi"><div className="k">결정</div><div className={`v ${dec ? dec.cls : run.status === 'denied' ? 'bad' : ''}`}>{dec ? dec.lbl : run.status === 'denied' ? '거부' : '대기'}</div></div>
      </div>

      {/* prompt */}
      <div className="fus-block">
        <div className="fus-block-lbl">심의 프롬프트</div>
        <div className="fus-prompt"><FusText text={run.prompt} /></div>
        {run.contested_post && <a className="fus-link" onClick={() => onNav && onNav('board')}>논쟁 보드 포스트 #{run.contested_post} 에서 발동 →</a>}
      </div>

      {/* denied path */}
      {run.status === 'denied' && (
        <div className="fus-deny">
          <div className="fus-deny-h"><span className="fus-deny-glyph">✕</span>게이트 거부 — <span className="mono">{run.deny}</span></div>
          <p className="fus-deny-lbl">{(window.DENY_REASON || {})[run.deny] || run.deny}</p>
          <p className="fus-deny-detail">{run.deny_detail}</p>
          <div className="fus-sink denied"><span className="fus-sink-glyph">◈</span>사유 1줄을 <b>{run.keeper}</b> chat lane 에 남기고 종료 — 패널/심판은 띄우지 않음.</div>
        </div>
      )}

      {/* panel */}
      {run.panel && (
        <div className="fus-block">
          <div className="fus-block-lbl">패널 · {run.panel.length}개 모델 병렬 <span className="fus-sub-note">Async_agent.all · 실패 격리</span></div>
          <div className="fus-panel-grid">
            {run.panel.map((p, i) => <PanelCard key={i} p={p} />)}
          </div>
        </div>
      )}

      {/* JOJ 1차 심판 — N개 독립 종합 (meta 앞). N은 패널 수와 무관 · 실패는 격리. */}
      {(() => { const sh = fusionShape(run); return sh.isJoj && (
        <div className="fus-block">
          <div className="fus-block-lbl">1차 심판 · {sh.firstN}개 lens 병렬 <span className="fus-sub-note">패널 {sh.panelN}개와 독립 구성(judges: judge_spec list){sh.dropped.length > 0 && ` · ${sh.dropped.length}개 격리`}</span></div>
          <FirstJudges judges={run.judges} meta={run.judge} />
        </div>
      ); })()}

      {/* judge */}
      {run.status === 'running' && (
        <div className="fus-block">
          <div className="fus-block-lbl">심판 종합</div>
          <div className="fus-judge-wait"><span className="fus-rdot run"></span>패널 응답 대기 중 — 전원 도착 후 심판(Structured.extract)이 1회 호출됩니다.</div>
        </div>
      )}
      {run.judge && (() => { const sh = fusionShape(run); return (
        <div className="fus-block">
          <div className="fus-block-lbl">{sh.isJoj ? 'meta 심판 · reconcile' : '심판 종합'} <span className="fus-judge-model mono">{run.judge.model}</span> <span className="fus-sub-note">{sh.isJoj ? `1차 종합 ${sh.okN}개 reconcile` : 'Structured.extract · 닫힌 타입 schema'}</span></div>
          {sh.dropped.length > 0 && (
            <div className="fus-meta-drop">⚠ 격리됨: {sh.dropped.map(d => `${d.id} (${(window.PANEL_FAIL || {})[d.fail] || d.fail})`).join(', ')} — meta는 살아남은 종합만으로 reconcile</div>
          )}
          {run.judge.degraded && (
            <div className="fus-meta-drop degrade">⚠ meta 실패 — 첫 성공 1차 종합으로 fallback(§5.1)</div>
          )}
          <div className="fus-judge">
            <JudgeSynthesis j={run.judge} />
          </div>
        </div>
      ); })()}

      {/* resolved answer + decision */}
      {run.judge && (
        <div className={`fus-resolved dec-${dec.cls}`}>
          <div className="fus-resolved-h">
            <span className={`fus-dec-badge big ${dec.cls}`}>{dec.glyph} {dec.lbl}</span>
            {run.judge.recommend && <span className="fus-rec-action">권고 · {run.judge.recommend.action}</span>}
          </div>
          <div className="fus-resolved-lbl">resolved_answer</div>
          <div className="fus-resolved-body"><FusResolved text={run.judge.resolved_answer} /></div>
          {run.judge.recommend && <p className="fus-rec-rationale"><span className="k">근거</span>{run.judge.recommend.rationale}</p>}
          {run.judge.missing && (
            <div className="fus-missing">
              <span className="k">부족한 입력</span>
              <ul>{run.judge.missing.map((m, i) => <li key={i}>{m}</li>)}</ul>
            </div>
          )}
        </div>
      )}

      {/* sink / visibility — where the conclusion lands (fusion_sink.mli, RFC-0252 §8) */}
      {run.status === 'done' && (
        <div className="fus-sink">
          <div className="fus-sink-h">결과 도착 · sink <span className="fus-sub-note">judge 결론이 키퍼 흐름에 녹는 경로</span></div>
          <div className="fus-sink-tracks">
            <div className="fus-sink-track">
              <span className="fus-sink-ico chat">▭</span>
              <div className="fus-sink-tx">
                <button className="fus-sink-to" onClick={() => onOpenKeeper && onOpenKeeper(run.keeper)}>{run.keeper} chat lane →</button>
                <span className="fus-sink-d">resolved_answer 1줄 append → 다음 턴 observation · librarian이 memory-os fact로 추출</span>
              </div>
            </div>
            <div className="fus-sink-track">
              <span className="fus-sink-ico board">▦</span>
              <div className="fus-sink-tx">
                {run.board_post
                  ? <button className="fus-sink-to" onClick={() => onNav && onNav('board')}>보드 포스트 #{run.board_post} →</button>
                  : <span className="fus-sink-to static">보드 포스트</span>}
                <span className="fus-sink-d">패널 N + 심판 종합을 meta_json 증거로 발행 · run_id로 쿼리</span>
              </div>
            </div>
            <div className="fus-sink-track">
              <span className="fus-sink-ico wake">◉</span>
              <div className="fus-sink-tx">
                <span className="fus-sink-to static">키퍼 wake · Fusion_completed</span>
                <span className="fus-sink-d">RFC-0266 typed stimulus로 호출 키퍼를 깨워 결론을 actionable 입력으로 전달</span>
              </div>
            </div>
          </div>
          <div className="fus-corr">correlation · <span className="mono">{run.run_id}</span></div>
        </div>
      )}
    </div>
  );
}

// ── active [fusion] policy, lifted 1:1 from runtime.toml — the RFC's named
//    config that was invisible in the v1 dashboard. ──
function FusionPolicy() {
  const p = window.FUSION_POLICY || {};
  const fmtT = (s) => (s == null ? '—' : (s >= 60 ? (s / 60) + '분' : s + 's'));
  return (
    <div className="fus-policy">
      <div className="fus-policy-h">
        활성 정책 <span className="fus-policy-src mono">[fusion]</span>
        <span className={`fus-policy-en ${p.enabled ? 'on' : 'off'}`}>{p.enabled ? 'enabled' : 'off'}</span>
      </div>
      <div className="fus-policy-grid">
        <div className="fus-pol"><span className="k">preset</span><span className="v mono">{p.default_preset}</span></div>
        <div className="fus-pol"><span className="k">동시 패널</span><span className="v mono">{p.max_concurrent_panels}</span></div>
        <div className="fus-pol"><span className="k">패널 timeout</span><span className="v mono">{fmtT(p.panel_timeout_s)}</span></div>
        <div className="fus-pol"><span className="k">심판 timeout</span><span className="v mono">{fmtT(p.judge_timeout_s)}</span></div>
        <div className="fus-pol"><span className="k">web tools</span><span className={`v mono ${p.web_tools ? '' : 'dim'}`}>{p.web_tools ? 'on' : 'off'}</span></div>
        <div className="fus-pol"><span className="k">tool/패널</span><span className="v mono">{p.max_tool_calls_per_panel === 0 ? '무제한' : p.max_tool_calls_per_panel}</span></div>
      </div>
    </div>
  );
}

function FusionSurface({ onOpenKeeper, onNav, wantRun }) {
  const runs = window.FUSION_RUNS || [];
  const [selId, setSelId] = useFusState(runs[0] ? runs[0].run_id : null);
  useFusEffect(() => { if (wantRun && runs.some(r => r.run_id === wantRun)) setSelId(wantRun); }, [wantRun]);
  const sel = runs.find(r => r.run_id === selId) || runs[0];
  const openCt = runs.filter(r => r.status === 'running').length;

  return (
    <main className="surf fus" data-screen-label="Fusion">
      <div className="fus-body">
        <aside className="fus-list">
          <div className="fus-list-h">
            <h4>심의 런</h4>
            {openCt > 0 && <span className="fus-list-live"><span className="fus-rdot run"></span>{openCt} 진행</span>}
            <window.KV.WireBadge tone="partial" label="데모 데이터" title="표시는 데모 심의 레코드 — live JoJ는 judges 패널 없어 fail-closed" />
          </div>
          <div className="fus-list-scroll">
            {runs.map(r => <RunRow key={r.run_id} run={r} sel={r.run_id === selId} onSel={setSelId} onOpenKeeper={onOpenKeeper} />)}
          </div>
          <FusionPolicy />
        </aside>
        {sel ? <FusionRun run={sel} onOpenKeeper={onOpenKeeper} onNav={onNav} /> : <div className="ov-empty">심의 런이 없습니다</div>}
      </div>
    </main>
  );
}

Object.assign(window, { FusionSurface });
