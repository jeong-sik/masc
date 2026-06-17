// @ds-adherence-ignore -- v2 skin organisms (batch 2): inspector drawer, settings, logs, connectors — composed from molecules.jsx/primitives.jsx
/* ══════════════════════════════════════════════════════════════
   MASC v2 — Organisms, batch 2
   Turn Inspector · Settings · Logs · Connectors — the remaining
   page-level surfaces, each built from the atoms + molecules.
   Exported onto window + window.KVO2.
   ══════════════════════════════════════════════════════════════ */

const { useState: use2 } = React;
const K2 = window.KV, KM2 = window.KVM;
const {
  Dot, Pill, Sigil, Button, FilterChip, LogFilter, Toggle, Segmented, Stepper, StatCell,
} = K2;
const {
  SurfaceHead, StatSummary, TokenEconomics, Waterfall, InspectorChip,
  TpsLive, Callout,
} = KM2;

const o2 = (...a) => a.filter(Boolean).join(' ');

/* ════════════════════════════════════════════════════════════════
   TABS — tiny shared tab shell (turn-tabs)
   ════════════════════════════════════════════════════════════════ */
function Tabs({ tabs = [], value, onChange }) {
  return (
    <div className="turn-tabs">
      {tabs.map(t => (
        <button key={t.id} className={o2('turn-tab', value === t.id && 'on')} onClick={() => onChange(t.id)}>{t.label}</button>
      ))}
    </div>
  );
}

/* ════════════════════════════════════════════════════════════════
   TURN INSPECTOR — the per-turn detail drawer (rendered inline here)
   ════════════════════════════════════════════════════════════════ */
function TurnInspectorPanel({ traceId = 'trc_iron_0142', model = 'sonnet-4.5', runtime = 'oas·seoul-1',
  summary, tokIn = 168000, tokOut = 980, ctxPct = 68, waterfall = [], total = '2.4s', meta = [], asOverlay = false, onClose, style }) {
  const [tab, setTab] = use2('timeline');
  const inner = (
    <div className={o2('turn-drawer', 'ti-drawer')} onClick={e => e.stopPropagation()} style={{ ...(asOverlay ? {} : { position: 'static', width: '100%', height: '100%', boxShadow: 'none', borderRadius: 0 }), ...style }}>
      <div className="turn-hd">
        <h3>턴 상세</h3>
        <span className="tid mono">{traceId}</span>
        {onClose ? <button className="turn-close" onClick={onClose} title="닫기 (Esc)" style={{ marginLeft: 8 }}>✕</button> : null}
      </div>
      <div className="ti-sub">
        <InspectorChip sub="model">{model}</InspectorChip>
        <InspectorChip sub="finish" tone="ok">stop</InspectorChip>
        <InspectorChip sub="runtime">{runtime}</InspectorChip>
      </div>
      <StatSummary stats={summary} cols="repeat(5,1fr)" />
      <TokenEconomics ctxLabel={`컨텍스트 ${ctxPct}% / 200K`}
        inPct={tokIn / (tokIn + tokOut) * 100} outPct={tokOut / (tokIn + tokOut) * 100}
        inVal={tokIn.toLocaleString()} outVal={tokOut.toLocaleString()} />
      <Tabs value={tab} onChange={setTab} tabs={[
        { id: 'timeline', label: '타임라인' }, { id: 'context', label: '컨텍스트' }, { id: 'meta', label: '메타' },
      ]} />
      <div className="turn-body">
        {tab === 'timeline' ? (
          <div className="turn-sec">
            <div className="ti-sec-h"><h4>턴 워터폴</h4><span className="n">{waterfall.length} 단계 · {total}</span></div>
            <Waterfall rows={waterfall} total={total} />
          </div>
        ) : null}
        {tab === 'context' ? (
          <div className="turn-sec">
            <div className="ti-ctx-card">
              <div className="ti-ctx-h"><span className="t">주입 컨텍스트 · namespace · tasks · traces</span><span className="tok">~{Math.round(tokIn / 3.6 / 1000)}k tok</span></div>
              <pre>{`# namespace snapshot
namespace   = ns:masc-core
fsm.state   = Compacting
ctx.window  = ${ctxPct}%   (${tokIn.toLocaleString()} / 200,000 tok)
owned.tasks = 3

# recent traces (last 30m)
  - edit_file        0.3s  (2m ago)
  - masc_git_blame   0.4s  (8m ago)`}</pre>
            </div>
          </div>
        ) : null}
        {tab === 'meta' ? (
          <div className="turn-sec">
            <div className="ti-sec-h"><h4>실행 메타데이터</h4></div>
            <div className="turn-kv">
              {meta.map((m, i) => <React.Fragment key={i}><span className="k">{m.k}</span><span className="v">{m.v}</span></React.Fragment>)}
            </div>
          </div>
        ) : null}
      </div>
    </div>
  );
  if (asOverlay) return <div className="turn-overlay" onClick={onClose}>{inner}</div>;
  return inner;
}

/* ════════════════════════════════════════════════════════════════
   SETTINGS — category rail + sectioned rows
   ════════════════════════════════════════════════════════════════ */
function SetRow({ label, hint, children }) {
  return (
    <div className="set-row">
      <div className="set-row-l"><div className="set-label">{label}</div>{hint ? <div className="set-hint">{hint}</div> : null}</div>
      <div className="set-row-c">{children}</div>
    </div>
  );
}
function SetNav({ groups = [], value, onChange }) {
  return (
    <nav className="set-nav" style={{ width: 210, flex: 'none', borderRight: '1px solid var(--border-main)', padding: '14px 10px', overflowY: 'auto' }}>
      {groups.map((g, gi) => (
        <div key={gi} style={{ marginBottom: 14 }}>
          <div style={{ fontSize: 9, letterSpacing: '0.18em', textTransform: 'uppercase', color: 'var(--text-dim)', padding: '0 8px 6px' }}>{g.label}</div>
          {g.items.map(it => (
            <button key={it.id} className={o2('set-nav-i', value === it.id && 'on')} onClick={() => onChange(it.id)}
              style={{ display: 'block', width: '100%', textAlign: 'left', padding: '6px 9px', borderRadius: 'var(--radius-sm)', border: 0, background: value === it.id ? 'var(--bg-card)' : 'transparent', color: value === it.id ? 'var(--volt-strong)' : 'var(--text-mid)', fontSize: 12.5, cursor: 'pointer', borderLeft: '2px solid ' + (value === it.id ? 'var(--volt)' : 'transparent') }}>
              {it.label}
            </button>
          ))}
        </div>
      ))}
    </nav>
  );
}
function SettingsSurface({ style }) {
  const [sec, setSec] = use2('runtime');
  const [autoCompact, setAuto] = use2(true);
  const [compactAt, setCompactAt] = use2(85);
  const [maxPar, setMaxPar] = use2(6);
  const [model, setModel] = use2('claude-sonnet-4');
  const [reply, setReply] = use2('mention');
  const [followIde, setFollowIde] = use2(true);
  const groups = [
    { label: '계정', items: [{ id: 'account', label: 'Account' }] },
    { label: 'Keeper 운영', items: [{ id: 'runtime', label: 'Runtime 기본값' }, { id: 'routing', label: '모델 라우팅' }, { id: 'policy', label: '승인 정책' }] },
    { label: '연결 · 통합', items: [{ id: 'mcp', label: 'MCP 서버' }, { id: 'gate', label: '커넥터 게이트' }] },
    { label: '관측 · 표시', items: [{ id: 'display', label: '표시' }] },
  ];
  return (
    <div className="set" style={{ display: 'flex', height: '100%', minHeight: 0, ...style }}>
      <SetNav groups={groups} value={sec} onChange={setSec} />
      <div className="set-body surf-scroll" style={{ flex: 1, padding: 22, overflowY: 'auto' }}>
        <SurfaceHead eyebrow="Operator" title="런타임 기본값"
          sub={<>새 keeper 생성 시 적용되는 기본값 · <span className="mono">12-FSM</span></>} />
        <div className="set-card" style={{ background: 'var(--bg-panel)', border: '1px solid var(--border-main)', borderRadius: 'var(--radius-md)', padding: '4px 16px', marginBottom: 16 }}>
          <SetRow label="자동 컴팩션" hint="컨텍스트 임계치 초과 시 compact() 자동 호출">
            <Toggle on={autoCompact} onChange={setAuto} />
          </SetRow>
          <SetRow label="컴팩션 임계치" hint={`${compactAt}% 도달 시`}>
            <div className="set-slider"><input type="range" min="50" max="95" value={compactAt} onChange={e => setCompactAt(+e.target.value)} /><span className="mono">{compactAt}%</span></div>
          </SetRow>
          <SetRow label="최대 동시 실행" hint="namespace당 running keeper 상한">
            <Stepper value={maxPar} min={1} max={16} onChange={setMaxPar} />
          </SetRow>
          <SetRow label="기본 모델" hint="라우팅 미지정 시">
            <Segmented options={[{ value: 'claude-haiku-4', label: 'haiku' }, { value: 'claude-sonnet-4', label: 'sonnet' }, { value: 'claude-opus-4', label: 'opus' }]} value={model} onChange={setModel} />
          </SetRow>
          <SetRow label="기본 응답 모드" hint="커넥터 바인딩 미재정의 시">
            <Segmented options={['mention', 'all', 'manual']} value={reply} onChange={setReply} />
          </SetRow>
          <SetRow label="IDE 커서 따라가기" hint="co-view 패널이 keeper 포커스를 추적">
            <Toggle on={followIde} onChange={setFollowIde} />
          </SetRow>
        </div>
        <Callout icon="ℹ">로컬 상태입니다 — 실제 저장·정책 집행은 백엔드 연동이 필요합니다.</Callout>
      </div>
    </div>
  );
}

/* ════════════════════════════════════════════════════════════════
   LOGS — level filters + live stream
   ════════════════════════════════════════════════════════════════ */
const LOG_SEV = { ok: '✓', fail: '✕', warn: '⚠', run: '·', info: '·' };
function LogViewer({ rows = [], filters = ['전체', '도구', '성공', '실패'], live = 'tail -f', style }) {
  const [f, setF] = use2(filters[0]);
  const shown = rows.filter(r =>
    f === '전체' || (f === '도구' && /masc_|edit_|file/.test(r.msg)) ||
    (f === '성공' && r.sev === 'ok') || (f === '실패' && r.sev === 'fail'));
  return (
    <div className="log-view" style={{ display: 'flex', flexDirection: 'column', height: '100%', minHeight: 0, ...style }}>
      <div className="log-filters" style={{ display: 'flex', gap: 6, alignItems: 'center', padding: 12, borderBottom: '1px solid var(--border-main)' }}>
        {filters.map(x => <LogFilter key={x} active={f === x} onClick={() => setF(x)}>{x}</LogFilter>)}
        <span className="log-live" style={{ marginLeft: 'auto' }}><span className="tps-dot" />{live}</span>
      </div>
      <div className="log-stream mono" style={{ flex: 1, overflowY: 'auto', padding: '8px 12px' }}>
        {shown.map((r, i) => (
          <div key={i} className={o2('log-line', r.level)} style={{ contentVisibility: 'auto', containIntrinsicSize: 'auto 22px' }}>
            <span className="lt">{r.t}</span>
            <span className={o2('ll', r.level)}>{r.level}</span>
            <span className="lk">{r.keeper}</span>
            <span className="lm">{r.msg}</span>
            <span className={o2('ls', r.sev)}>{LOG_SEV[r.sev] || '·'}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

/* ════════════════════════════════════════════════════════════════
   CONNECTORS — gate strip + connector cards + audit
   ════════════════════════════════════════════════════════════════ */
function GateStrip({ healthy = true, base = 'https://gate.masc.local', checked = '14:29:14', source = 'store + runtime', generated }) {
  return (
    <div className="gate-strip">
      <span><Dot state={healthy ? 'ok' : 'bad'} pulse /> gate <b>{healthy ? 'healthy' : 'down'}</b></span>
      <span className="sep" />
      <span className="mono">base {base}</span>
      <span className="sep" />
      <span>health check <b className="mono" style={{ fontWeight: 500 }}>{checked}</b></span>
      <span className="sep" />
      <span>binding source <b>{source}</b></span>
      {generated ? <span style={{ marginLeft: 'auto' }} className="mono">generated_at {generated}</span> : null}
    </div>
  );
}
function CnCard({ c }) {
  const tone = c.stale ? 'warn' : c.status === 'connected' ? 'ok' : 'neutral';
  const label = c.stale ? 'Stale' : c.status === 'connected' ? 'Connected' : 'Down';
  return (
    <article className={o2('cn-card', c.stale && 'stale')}>
      <div className="cn-h">
        <span className="cn-glyph">{c.glyph}</span>
        <div className="meta"><div className="nm">{c.name}</div><div className="ch">{c.id} · channel: {c.channel}</div></div>
        <Pill tone={tone} dot={tone === 'neutral' ? 'idle' : tone} dotPulse={tone === 'ok'}>{label}</Pill>
        <button className="cn-config" title="설정">⚙</button>
      </div>
      <div className="cn-kv">
        {c.kv.map((cell, i) => <div key={i} className="cell"><div className="k">{cell.k}</div><div className={o2('v', cell.hl && 'hl')}>{cell.v}</div></div>)}
      </div>
      <div className="cn-caps">{c.caps.map((cap, i) => <span key={i} className="cn-cap">{cap}</span>)}</div>
      <div className="cn-bind">
        <h5>바인딩 — 채널 → keeper ({c.bindings.length})</h5>
        {c.bindings.length ? c.bindings.map((b, i) => (
          <div key={i} className="cn-bind-row">
            <span className="chn">{b.channel}</span><span className="arr">→</span>
            <Sigil slot={b.slot} size={16}>{b.mono}</Sigil>
            <span style={{ color: 'var(--text-bright)' }}>{b.keeper}</span>
          </div>
        )) : <div className="cn-bind-none">바인딩 없음 — 알림 전용 게이트</div>}
        {c.error ? <Callout icon="⚠">{c.error}</Callout> : null}
      </div>
    </article>
  );
}
function ConnectorsSurface({ connectors = [], audit = [], gate = {} }) {
  const active = connectors.filter(c => c.status === 'connected' && !c.stale).length;
  return (
    <div className="surf-scroll" style={{ padding: 22, height: '100%', overflowY: 'auto' }}>
      <SurfaceHead eyebrow="Gate" title="커넥터"
        sub={<>외부 게이트 {connectors.length}개 · <b>{active} active</b> · <span className="mono">GET /api/v1/gate/connectors</span></>}
        action={<Button>게이트 새로고침 ↻</Button>} />
      <GateStrip {...gate} />
      <div className="cn-grid">{connectors.map((c, i) => <CnCard key={i} c={c} />)}</div>
      {audit.length ? (
        <section className="cn-audit">
          <div className="ov-card-h"><h3>최근 감사 로그</h3><span className="ov-legend mono">recent_audit · last {audit.length}</span></div>
          <table>
            <thead><tr><th>시각</th><th>액션</th><th>대상</th><th>Keeper</th><th>Actor</th></tr></thead>
            <tbody>{audit.map((a, i) => <tr key={i}><td>{a[0]}</td><td className="act">{a[1]}</td><td>{a[2]}</td><td>{a[3]}</td><td>{a[4]}</td></tr>)}</tbody>
          </table>
        </section>
      ) : null}
    </div>
  );
}

/* ── export ── */
const KVO2 = {
  Tabs, TurnInspectorPanel, SetRow, SetNav, SettingsSurface, LogViewer,
  GateStrip, CnCard, ConnectorsSurface,
};
Object.assign(window, KVO2);
window.KVO2 = KVO2;
