/* MASC v2 — Settings surface: sectioned operator console.
   Grounded in real MASC concepts (README): /mcp endpoint, operator role, masc_* tools,
   /api/v1/gate, 12-state FSM, namespace. Controls hold local state — persistence is mock. */
const { useState: useSet } = React;

function SetToggle({ on, onChange }) {
  return <button className={`set-toggle ${on ? 'on' : ''}`} onClick={() => onChange(!on)} role="switch" aria-checked={on}><span className="knob"></span></button>;
}
function SetSeg({ value, options, onChange }) {
  return <div className="set-seg">{options.map(o => <button key={o} className={`set-seg-b ${value === o ? 'on' : ''}`} onClick={() => onChange(o)}>{o}</button>)}</div>;
}
function SetRow({ label, hint, children }) {
  return (
    <div className="set-row">
      <div className="set-row-l"><div className="set-label">{label}</div>{hint && <div className="set-hint">{hint}</div>}</div>
      <div className="set-row-c">{children}</div>
    </div>
  );
}
function SetStepper({ v, set, min, max }) {
  return <div className="set-stepper"><button onClick={() => set(Math.max(min, v - 1))}>−</button><span className="mono">{v}</span><button onClick={() => set(Math.min(max, v + 1))}>+</button></div>;
}
function VerifyBtn({ label }) {
  const [st, setSt] = useSet('idle');
  return <button className={`set-verify ${st}`} onClick={(e) => { e.stopPropagation(); setSt('checking'); setTimeout(() => setSt('ok'), 700); }}>{st === 'idle' ? (label || '확인') : st === 'checking' ? '확인 중…' : '✓ 정상'}</button>;
}

const SET_SECTIONS = [
  ['account', 'Account', '계정'],
  ['mcp', 'MCP', 'MCP 서버'],
  ['runtime', 'Runtime', '런타임 기본값'],
  ['runtimes', 'Runtimes', '런타임 관리'],
  ['routing', 'Routing', '모델 라우팅'],
  ['prompts', 'Prompts', '기본 프롬프트'],
  ['policy', 'Policy', '승인 정책'],
  ['lifecycle', 'Lifecycle', 'keeper 수명'],
  ['sandbox', 'Sandbox', '샌드박스'],
  ['ide', 'IDE', 'IDE · 편집기'],
  ['gate', 'Gate', '커넥터 게이트'],
  ['paths', 'Paths', '경로 · Basepath'],
  ['logs', 'Logs', '관측 · 시스템 로그'],
  ['notify', 'Notify', '알림'],
  ['display', 'Display', '표시'],
];

const SET_GROUPS = [
  ['계정', ['account']],
  ['Keeper 운영', ['runtime', 'routing', 'prompts', 'lifecycle', 'policy']],
  ['인프라 · 실행', ['runtimes', 'sandbox', 'paths']],
  ['연결 · 통합', ['mcp', 'gate', 'ide']],
  ['관측 · 표시', ['logs', 'notify', 'display']],
];

const MCP_TOOLS = ['masc_start', 'masc_handoff', 'masc_compact', 'masc_amplitude_query', 'masc_trace_window', 'masc_board_metrics', 'masc_git_blame'];
const RUNTIMES = [
  { name: 'oas·seoul-1', endpoint: 'oas://seoul-1.masc.run', region: 'ap-northeast-2', kind: 'OAS', keepers: 3 },
  { name: 'oas·tokyo-2', endpoint: 'oas://tokyo-2.masc.run', region: 'ap-northeast-1', kind: 'OAS', keepers: 2 },
  { name: 'local·docker', endpoint: 'unix:///var/run/masc.sock', region: 'local', kind: 'Docker', keepers: 1 },
];
const APPROVAL_ACTIONS = [
  ['git push / merge', 'always', '원격 브랜치에 쓰기'],
  ['배포 (infra/deploy)', 'always', 'deploy 트리거'],
  ['외부 호출 (Slack·Discord 발신)', 'risky', '외부로 메시지 전송'],
  ['파일 쓰기 (worktree)', 'auto', 'keeper 워크트리 내 편집'],
  ['읽기 전용 도구', 'auto', 'query·trace·blame 등'],
];
const SYS_LOG = [
  ['16:24:51', 'info', 'masc-improver', 'masc_amplitude_query 완료', 'ok'],
  ['16:24:48', 'info', 'masc-improver', 'masc_amplitude_query 호출 (D0–D3)', 'run'],
  ['16:23:10', 'warn', 'nick0cave', '컨텍스트 91% — compact 예약', 'warn'],
  ['16:22:55', 'info', 'sangsu', 'masc_git_blame 완료', 'ok'],
  ['16:21:02', 'error', 'drifter', 'masc_trace_window 실패 — context overflow', 'fail'],
  ['16:20:40', 'info', 'qa-king', 'HandingOff → sangsu 인계 시작', 'run'],
  ['16:19:33', 'info', 'nick0cave', 'masc_compact 완료 (−64%)', 'ok'],
  ['16:18:12', 'error', 'drifter', 'masc_start 재시작 실패 (3/3)', 'fail'],
  ['16:17:50', 'info', 'scholar', 'masc_board_metrics 완료', 'ok'],
  ['16:16:04', 'warn', 'analyst', 'search/index 색인 실패 1건', 'warn'],
];

function LogViewer() {
  const [f, setF] = useSet('전체');
  const rows = SYS_LOG.filter(r => f === '전체' || (f === '도구' && /masc_/.test(r[3])) || (f === '성공' && r[4] === 'ok') || (f === '실패' && r[4] === 'fail'));
  return (
    <div className="log-view">
      <div className="log-filters">
        {['전체', '도구', '성공', '실패'].map(x => <LogFilter key={x} active={f === x} onClick={() => setF(x)}>{x}</LogFilter>)}
        <span className="log-live"><span className="tps-dot"></span>tail -f</span>
      </div>
      <div className="log-stream mono">
        {rows.map((r, i) => (
          <div key={i} className={`log-line ${r[1]}`}>
            <span className="lt">{r[0]}</span>
            <span className={`ll ${r[1]}`}>{r[1]}</span>
            <span className="lk">{r[2]}</span>
            <span className="lm">{r[3]}</span>
            <span className={`ls ${r[4]}`}>{r[4] === 'ok' ? '✓' : r[4] === 'fail' ? '✕' : r[4] === 'warn' ? '⚠' : '·'}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function SettingsSurface({ onNav }) {
  const [sec, setSec] = useSet(() => { const s = window.__nextSettingsSec; window.__nextSettingsSec = null; return s || 'account'; });
  // account
  const [tokenShown, setTokenShown] = useSet(false);
  // mcp
  const [mcpUrl, setMcpUrl] = useSet('https://masc.local/mcp');
  const [transport, setTransport] = useSet('http');
  const [tools, setTools] = useSet(Object.fromEntries(MCP_TOOLS.map(t => [t, true])));
  // runtime defaults
  const [defRuntime, setDefRuntime] = useSet('oas·seoul-1');
  const [defModel, setDefModel] = useSet('claude-sonnet-4');
  const [maxPar, setMaxPar] = useSet(6);
  const [compactAt, setCompactAt] = useSet(85);
  const [autoCompact, setAutoCompact] = useSet(true);
  // routing / policy
  const [routing, setRouting] = useSet({ analysis: 'claude-sonnet-4', heavy: 'claude-opus-4', cheap: 'claude-haiku-4' });
  const [approve, setApprove] = useSet(Object.fromEntries(APPROVAL_ACTIONS.map(a => [a[0], a[1]])));
  // lifecycle
  const [idleDrain, setIdleDrain] = useSet(30);
  const [autoRestart, setAutoRestart] = useSet(true);
  const [restartMax, setRestartMax] = useSet(3);
  const [onOverflow, setOnOverflow] = useSet('자동 compact');
  // gate / paths
  const [gateBase, setGateBase] = useSet('https://gate.masc.local');
  const [gateOn, setGateOn] = useSet({ Slack: true, Discord: true, Amplitude: true, GitHub: false });
  const [wtBase, setWtBase] = useSet('~/wt');
  const [storeUrl, setStoreUrl] = useSet('postgres://masc.local:5432/masc');
  // sandbox
  const [isolation, setIsolation] = useSet('container');
  const [egress, setEgress] = useSet('허용목록');
  const [allowlist, setAllowlist] = useSet('github.com, opam.ocaml.org, *.masc.local');
  const [fsScope, setFsScope] = useSet('worktree');
  const [shellOn, setShellOn] = useSet(true);
  const [blockRisky, setBlockRisky] = useSet(true);
  const [memLimit, setMemLimit] = useSet('2GB');
  const [cpuLimit, setCpuLimit] = useSet(2);
  const [execTimeout, setExecTimeout] = useSet(120);
  // ide
  const [ideView, setIdeView] = useSet('split-diff');
  const [diffStyle, setDiffStyle] = useSet('side-by-side');
  const [tabWidth, setTabWidth] = useSet(2);
  const [formatOnSave, setFormatOnSave] = useSet(true);
  const [wrapLines, setWrapLines] = useSet(false);
  const [liveCursors, setLiveCursors] = useSet(true);
  const [ideOwnership, setIdeOwnership] = useSet(true);
  const [convRail, setConvRail] = useSet(true);
  const [contextLens, setContextLens] = useSet(true);
  const [blameGutter, setBlameGutter] = useSet(true);
  const [ideAnnos, setIdeAnnos] = useSet(true);
  const [annoAutoLink, setAnnoAutoLink] = useSet(true);
  const [embedTerminal, setEmbedTerminal] = useSet(true);
  const [searchIndex, setSearchIndex] = useSet(true);
  const [ideRepo, setIdeRepo] = useSet('masc/masc-mcp');
  // prompts (shared keeper base)
  const _kb = (window.KEEPER_BASE || { system: '', world: '' });
  const [sysPrompt, setSysPrompt] = useSet(_kb.system);
  const [worldPrompt, setWorldPrompt] = useSet(_kb.world);
  // logs
  const [traceKeep, setTraceKeep] = useSet('30일');
  const [logLevel, setLogLevel] = useSet('info');
  const [sampling, setSampling] = useSet(100);
  // notify / display
  const [notifyCtx, setNotifyCtx] = useSet(85);
  const [notifyFails, setNotifyFails] = useSet(3);
  const [notifyCh, setNotifyCh] = useSet('Slack');
  const [notifyOn, setNotifyOn] = useSet({ '컨텍스트 임계치 초과': true, '연속 실패': true, 'keeper crash/dead': true, '핸드오프 완료': false, '승인 요청': true });
  const [density, setDensity] = useSet('regular');
  const [tz, setTz] = useSet('Asia/Seoul');
  const [locale, setLocale] = useSet('KO');
  const [clock24, setClock24] = useSet(true);

  const cur = SET_SECTIONS.find(s => s[0] === sec);

  return (
    <main className="surf settings-surf" data-screen-label="설정">
      <div className="set-shell">
        <nav className="set-nav">
          <div className="set-nav-h">
            <div className="eyebrow">Operator</div>
            <div className="set-nav-title">설정</div>
            <div className="set-nav-sub mono">@operator · masc-mcp</div>
          </div>
          {SET_GROUPS.map(([glabel, ids]) => (
            <div key={glabel} className="set-nav-group">
              <div className="set-nav-glabel">{glabel}</div>
              {ids.map(id => {
                const s = SET_SECTIONS.find(x => x[0] === id);
                if (!s) return null;
                return (
                  <button key={id} className={`set-nav-item ${sec === id ? 'on' : ''}`} onClick={() => setSec(id)}>
                    <span className="ko">{s[2]}</span><span className="en mono">{s[1]}</span>
                  </button>
                );
              })}
            </div>
          ))}
          <div className="set-nav-note">프로토타입 — 변경은 로컬에만 적용됩니다.</div>
        </nav>

        <div className="set-content">
          <header className="set-content-h">
            <h1>{cur[2]}</h1>
            <button className="act">변경사항 저장</button>
          </header>

          <div className="set-card-b">
            {sec === 'account' && (
              <React.Fragment>
                <SetRow label="운영자" hint="현재 로그인한 operator"><span className="mono" style={{ color: 'var(--text-bright)' }}>@operator</span></SetRow>
                <SetRow label="역할" hint="MASC 역할 — DM / player / keeper / operator"><RolePill>operator</RolePill></SetRow>
                <SetRow label="API 토큰" hint="MCP·게이트 인증에 사용">
                  <div className="set-path">
                    <input className="set-input mono" readOnly value={tokenShown ? 'msc_live_8a4f2c71e0' : '••••••••••••••'} />
                    <button className="set-verify idle" onClick={() => setTokenShown(s => !s)}>{tokenShown ? '숨기기' : '표시'}</button>
                    <button className="set-verify idle">재발급</button>
                  </div>
                </SetRow>
                <SetRow label="세션 만료" hint="자동 로그아웃까지"><SetSeg value="8시간" options={['1시간', '8시간', '안 함']} onChange={() => {}} /></SetRow>
                <button className="set-add" style={{ borderColor: 'color-mix(in oklab, var(--status-bad) 40%, transparent)', color: 'var(--status-bad)' }}>로그아웃</button>
              </React.Fragment>
            )}

            {sec === 'mcp' && (
              <React.Fragment>
                <div className="set-hint" style={{ marginBottom: 12 }}>이 namespace를 외부 에이전트/클라이언트에 노출하는 MCP 서버 설정.</div>
                <SetRow label="MCP 엔드포인트" hint="GET/POST /mcp"><div className="set-path"><input className="set-input mono" value={mcpUrl} onChange={e => setMcpUrl(e.target.value)} /><VerifyBtn /></div></SetRow>
                <SetRow label="전송 방식" hint="transport"><SetSeg value={transport} options={['http', 'stdio', 'sse']} onChange={setTransport} /></SetRow>
                <div className="set-mcp-detail mono">
                  {transport === 'http' && <span>POST {mcpUrl}  ·  Content-Type: application/json  ·  Authorization: Bearer ••••</span>}
                  {transport === 'stdio' && <span>spawn: masc-mcp serve --stdio  ·  framing: ndjson  ·  pid 8421</span>}
                  {transport === 'sse' && <span>GET {mcpUrl}/sse  ·  keep-alive 15s  ·  event: message</span>}
                </div>
                <div className="set-sub-h">노출 도구 ({Object.values(tools).filter(Boolean).length}/{MCP_TOOLS.length})</div>
                {MCP_TOOLS.map(t => (
                  <SetRow key={t} label={<span className="mono" style={{ fontSize: 12.5 }}>{t}</span>}><SetToggle on={tools[t]} onChange={(v) => setTools(p => ({ ...p, [t]: v }))} /></SetRow>
                ))}
              </React.Fragment>
            )}

            {sec === 'runtime' && (
              <React.Fragment>
                <SetRow label="기본 런타임" hint="새 keeper가 시작될 위치"><SetSeg value={defRuntime} options={['oas·seoul-1', 'oas·tokyo-2', 'local·docker']} onChange={setDefRuntime} /></SetRow>
                <SetRow label="기본 모델" hint="라우팅 규칙이 없을 때"><SetSeg value={defModel} options={['claude-haiku-4', 'claude-sonnet-4', 'claude-opus-4']} onChange={setDefModel} /></SetRow>
                <SetRow label="최대 동시 keeper" hint="이 namespace에서 동시에 실행"><SetStepper v={maxPar} set={setMaxPar} min={1} max={12} /></SetRow>
                <SetRow label="자동 컴팩션" hint={`컨텍스트 ${compactAt}% 도달 시 compact() 자동 실행`}><SetToggle on={autoCompact} onChange={setAutoCompact} /></SetRow>
                {autoCompact && <SetRow label="컴팩션 임계치" hint="윈도우 사용량 기준"><div className="set-slider"><input type="range" min="60" max="95" value={compactAt} onChange={e => setCompactAt(+e.target.value)} /><span className="mono">{compactAt}%</span></div></SetRow>}
              </React.Fragment>
            )}

            {sec === 'runtimes' && (
              <React.Fragment>
                <div className="set-hint" style={{ marginBottom: 12 }}>등록된 런타임 타깃. keeper는 이 중 하나에서 구동됩니다.</div>
                {RUNTIMES.map(rt => (
                  <div key={rt.name} className="set-rt">
                    <div className="set-rt-top">
                      <span className="set-rt-name mono">{rt.name}</span>
                      <span className="set-rt-kind">{rt.kind}</span>
                      <span className="set-rt-keepers">keeper {rt.keepers}</span>
                      <VerifyBtn label="연결 확인" />
                    </div>
                    <div className="set-rt-row"><span className="sub-k">endpoint</span><input className="set-input mono" defaultValue={rt.endpoint} /></div>
                    <div className="set-rt-row"><span className="sub-k">region</span><span className="mono" style={{ fontSize: 12, color: 'var(--text-mid)' }}>{rt.region}</span></div>
                  </div>
                ))}
                <button className="set-add">＋ 런타임 추가</button>
              </React.Fragment>
            )}

            {sec === 'routing' && (
              <React.Fragment>
                <div className="set-hint" style={{ marginBottom: 12 }}>작업 유형(task.kind)에 따라 keeper가 사용할 모델을 자동 선택합니다.</div>
                {[['analysis', '분석 · 리서치'], ['heavy', '복잡한 추론 · 대규모 리팩터'], ['cheap', '단순 작업 · 분류']].map(([k, lbl]) => (
                  <SetRow key={k} label={lbl} hint={`task.kind = ${k}`}><SetSeg value={routing[k]} options={['claude-haiku-4', 'claude-sonnet-4', 'claude-opus-4']} onChange={(v) => setRouting(p => ({ ...p, [k]: v }))} /></SetRow>
                ))}
              </React.Fragment>
            )}

            {sec === 'prompts' && (
              <React.Fragment>
                <div className="set-hint" style={{ marginBottom: 12 }}>모든 keeper가 상속하는 공유 프롬프트 베이스. keeper 설정의 persona·instructions는 이 위에 얹힙니다. <span className="mono">{'{{keeper}}'} · {'{{namespace}}'} · {'{{runtime}}'} · {'{{model}}'}</span> 는 keeper별로 치환됩니다.</div>
                <div className="set-sub-h">① System (base) — keeper란 무엇인가</div>
                <textarea className="set-input mono" style={{ width: '100%', minHeight: 150, resize: 'vertical', lineHeight: 1.6, padding: '10px 12px', whiteSpace: 'pre' }} value={sysPrompt} onChange={e => setSysPrompt(e.target.value)} />
                <div className="set-sub-h" style={{ marginTop: 14 }}>② World 프롬프트 — 공유 세계·규칙</div>
                <textarea className="set-input mono" style={{ width: '100%', minHeight: 150, resize: 'vertical', lineHeight: 1.6, padding: '10px 12px', whiteSpace: 'pre' }} value={worldPrompt} onChange={e => setWorldPrompt(e.target.value)} />
                <div className="set-mcp-detail mono" style={{ marginTop: 12 }}>유효 프롬프트 = ① System + ② World + ③ persona + ④ instructions · 합성 결과는 턴 인스펙터에서 확인</div>
              </React.Fragment>
            )}

            {sec === 'policy' && (
              <React.Fragment>
                <div className="set-policy-legend"><span><b className="mono">always</b> 항상 승인 필요</span><span><b className="mono">risky</b> 위험 시에만</span><span><b className="mono">auto</b> 자동 허용</span></div>
                {APPROVAL_ACTIONS.map(([action, , hint]) => (
                  <SetRow key={action} label={action} hint={hint}><SetSeg value={approve[action]} options={['always', 'risky', 'auto']} onChange={(v) => setApprove(p => ({ ...p, [action]: v }))} /></SetRow>
                ))}
              </React.Fragment>
            )}

            {sec === 'lifecycle' && (
              <React.Fragment>
                <SetRow label="유휴 자동 drain" hint="활동 없을 때 정상 종료까지 (분)"><div className="set-slider"><input type="range" min="0" max="120" step="5" value={idleDrain} onChange={e => setIdleDrain(+e.target.value)} /><span className="mono">{idleDrain ? idleDrain + '분' : '안 함'}</span></div></SetRow>
                <SetRow label="crash 자동 재시작" hint="Crashed → Restarting 시도"><SetToggle on={autoRestart} onChange={setAutoRestart} /></SetRow>
                {autoRestart && <SetRow label="최대 재시작 횟수" hint="초과 시 Dead 로 전이"><SetStepper v={restartMax} set={setRestartMax} min={1} max={10} /></SetRow>}
                <SetRow label="Overflowed 시 동작" hint="컨텍스트 윈도우 초과했을 때"><SetSeg value={onOverflow} options={['자동 compact', '자동 종료', 'operator 대기']} onChange={setOnOverflow} /></SetRow>
              </React.Fragment>
            )}

            {sec === 'sandbox' && (
              <React.Fragment>
                <div className="set-hint" style={{ marginBottom: 12 }}>keeper가 코드를 실행하는 격리 환경. 도구 권한(승인 정책)보다 낮은 계층의 OS·네트워크 경계입니다.</div>
                <SetRow label="격리 수준" hint="keeper 실행 격리 방식"><SetSeg value={isolation} options={['worktree', 'container', 'microVM']} onChange={setIsolation} /></SetRow>
                <SetRow label="파일시스템 범위" hint="keeper가 접근 가능한 경로"><SetSeg value={fsScope} options={['worktree', 'namespace', '전체']} onChange={setFsScope} /></SetRow>
                <SetRow label="네트워크 송신 (egress)" hint="외부 네트워크 접근"><SetSeg value={egress} options={['차단', '허용목록', '전체']} onChange={setEgress} /></SetRow>
                {egress === '허용목록' && <SetRow label="허용 도메인" hint="쉼표로 구분"><input className="set-input mono" style={{ width: 260 }} value={allowlist} onChange={e => setAllowlist(e.target.value)} /></SetRow>}
                <SetRow label="셸 명령 허용" hint="keeper가 셸 명령 실행"><SetToggle on={shellOn} onChange={setShellOn} /></SetRow>
                {shellOn && <SetRow label="위험 명령 차단" hint="rm -rf, curl | sh 등 차단"><SetToggle on={blockRisky} onChange={setBlockRisky} /></SetRow>}
                <div className="set-sub-h">리소스 한도</div>
                <SetRow label="메모리" hint="keeper당 최대"><SetSeg value={memLimit} options={['1GB', '2GB', '4GB', '8GB']} onChange={setMemLimit} /></SetRow>
                <SetRow label="CPU" hint="vCPU 코어"><SetStepper v={cpuLimit} set={setCpuLimit} min={1} max={16} /></SetRow>
                <SetRow label="실행 타임아웃" hint="단일 명령 최대 실행 시간 (초)"><div className="set-slider"><input type="range" min="10" max="600" step="10" value={execTimeout} onChange={e => setExecTimeout(+e.target.value)} /><span className="mono">{execTimeout}s</span></div></SetRow>
              </React.Fragment>
            )}

            {sec === 'ide' && (
              <React.Fragment>
                <div className="set-hint" style={{ marginBottom: 12 }}>모든 keeper가 공유하는 IDE 화면의 동작. 편집기·협업·코드 인사이트·버전 관리 기본값입니다.</div>

                <div className="set-sub-h">편집기</div>
                <SetRow label="기본 보기" hint="파일 열 때 시작 뷰"><SetSeg value={ideView} options={['source', 'unified', 'split-diff']} onChange={setIdeView} /></SetRow>
                <SetRow label="diff 스타일" hint="변경 비교 방식"><SetSeg value={diffStyle} options={['inline', 'side-by-side']} onChange={setDiffStyle} /></SetRow>
                <SetRow label="탭 폭" hint="들여쓰기 칸 수"><SetStepper v={tabWidth} set={setTabWidth} min={2} max={8} /></SetRow>
                <SetRow label="저장 시 포맷" hint="format-on-save"><SetToggle on={formatOnSave} onChange={setFormatOnSave} /></SetRow>
                <SetRow label="긴 줄 줄바꿈" hint="wrap long lines"><SetToggle on={wrapLines} onChange={setWrapLines} /></SetRow>

                <div className="set-sub-h">협업 (presence)</div>
                <SetRow label="다른 keeper 커서" hint="실시간 커서·선택 영역·focus_mode 표시"><SetToggle on={liveCursors} onChange={setLiveCursors} /></SetRow>
                <SetRow label="소유권 색상" hint="파일·영역별 담당 keeper 색상 표시"><SetToggle on={ideOwnership} onChange={setIdeOwnership} /></SetRow>
                <SetRow label="컨버세이션 레일" hint="편집 옆 대화 맥락 패널"><SetToggle on={convRail} onChange={setConvRail} /></SetRow>
                <SetRow label="컨텍스트 렌즈" hint="해당 코드의 turn·tool 이벤트 오버레이"><SetToggle on={contextLens} onChange={setContextLens} /></SetRow>

                <div className="set-sub-h">코드 인사이트</div>
                <SetRow label="blame 거터" hint="줄별 마지막 변경 keeper·turn"><SetToggle on={blameGutter} onChange={setBlameGutter} /></SetRow>
                <SetRow label="인라인 주석" hint="goal·task·PR에 연결된 주석 표시"><SetToggle on={ideAnnos} onChange={setIdeAnnos} /></SetRow>
                {ideAnnos && <SetRow label="주석 자동 링크" hint="새 주석을 활성 goal/task/PR에 자동 연결"><SetToggle on={annoAutoLink} onChange={setAnnoAutoLink} /></SetRow>}

                <div className="set-sub-h">실행 · 버전 관리</div>
                <SetRow label="임베디드 터미널" hint="IDE 안에서 셸 실행 — 샌드박스 정책 적용"><SetToggle on={embedTerminal} onChange={setEmbedTerminal} /></SetRow>
                <SetRow label="검색 색인" hint="심볼·전문 검색 인덱스 유지"><SetToggle on={searchIndex} onChange={setSearchIndex} /></SetRow>
                <SetRow label="연동 레포" hint="diff·PR·blame 소스 — 예: #7732"><div className="set-path"><input className="set-input mono" value={ideRepo} onChange={e => setIdeRepo(e.target.value)} /><VerifyBtn label="레포 확인" /></div></SetRow>
              </React.Fragment>
            )}

            {sec === 'gate' && (
              <React.Fragment>
                <div className="set-hint" style={{ marginBottom: 12 }}>외부 게이트 연결의 기본 설정. 개별 채널→keeper 바인딩은 <button className="set-link" onClick={() => onNav && onNav('connectors')}>커넥터 화면 →</button> 에서 관리합니다.</div>
                <SetRow label="게이트 base URL" hint="GET /api/v1/gate/connectors"><div className="set-path"><input className="set-input mono" value={gateBase} onChange={e => setGateBase(e.target.value)} /><VerifyBtn /></div></SetRow>
                {['Slack', 'Discord', 'Amplitude', 'GitHub'].map(g => (
                  <SetRow key={g} label={g} hint={gateOn[g] ? '연결됨' : '비활성'}><SetToggle on={gateOn[g]} onChange={(v) => setGateOn(p => ({ ...p, [g]: v }))} /></SetRow>
                ))}
                <button className="set-add">＋ 게이트 추가</button>
              </React.Fragment>
            )}

            {sec === 'paths' && (
              <React.Fragment>
                <div className="set-hint" style={{ marginBottom: 12 }}>서버·스토어의 base 경로(basepath)와 keeper 워크트리 루트. 각 항목은 연결 확인이 가능합니다.</div>
                <SetRow label="MCP 엔드포인트" hint="/mcp HTTP 진입점"><div className="set-path"><input className="set-input mono" value={mcpUrl} onChange={e => setMcpUrl(e.target.value)} /><VerifyBtn /></div></SetRow>
                <SetRow label="스토어 (DB)" hint="trace·감사 영속 저장소"><div className="set-path"><input className="set-input mono" value={storeUrl} onChange={e => setStoreUrl(e.target.value)} /><VerifyBtn /></div></SetRow>
                <SetRow label="기본 worktree basepath" hint="keeper worktree 루트 — 예: ~/wt/<keeper>"><div className="set-path"><input className="set-input mono" value={wtBase} onChange={e => setWtBase(e.target.value)} /><VerifyBtn label="경로 확인" /></div></SetRow>
              </React.Fragment>
            )}

            {sec === 'logs' && (
              <React.Fragment>
                <SetRow label="trace 보존 기간" hint="이후 자동 아카이브"><SetSeg value={traceKeep} options={['7일', '30일', '90일']} onChange={setTraceKeep} /></SetRow>
                <SetRow label="로그 레벨" hint="keeper 런타임 로그"><SetSeg value={logLevel} options={['error', 'warn', 'info', 'debug']} onChange={setLogLevel} /></SetRow>
                <SetRow label="telemetry 샘플링" hint="trace 수집 비율"><div className="set-slider"><input type="range" min="1" max="100" value={sampling} onChange={e => setSampling(+e.target.value)} /><span className="mono">{sampling}%</span></div></SetRow>
                <div className="set-sub-h">시스템 로그 (전체 keeper · 실시간)</div>
                <LogViewer />
              </React.Fragment>
            )}

            {sec === 'notify' && (
              <React.Fragment>
                <SetRow label="컨텍스트 임계치 알림" hint="이 % 초과 시 주의로 올림"><div className="set-slider"><input type="range" min="70" max="98" value={notifyCtx} onChange={e => setNotifyCtx(+e.target.value)} /><span className="mono">{notifyCtx}%</span></div></SetRow>
                <SetRow label="연속 실패 알림" hint="이 횟수 연속 실패 시 알림"><SetStepper v={notifyFails} set={setNotifyFails} min={1} max={10} /></SetRow>
                <SetRow label="알림 채널" hint="어디로 보낼지"><SetSeg value={notifyCh} options={['Slack', 'Discord', '없음']} onChange={setNotifyCh} /></SetRow>
                <div className="set-sub-h">알림 이벤트</div>
                {Object.keys(notifyOn).map(k => <SetRow key={k} label={k}><SetToggle on={notifyOn[k]} onChange={(v) => setNotifyOn(p => ({ ...p, [k]: v }))} /></SetRow>)}
              </React.Fragment>
            )}

            {sec === 'display' && (
              <React.Fragment>
                <SetRow label="밀도" hint="목록·카드 간격"><SetSeg value={density} options={['compact', 'regular']} onChange={setDensity} /></SetRow>
                <SetRow label="언어" hint="UI 표기"><SetSeg value={locale} options={['KO', 'EN']} onChange={setLocale} /></SetRow>
                <SetRow label="타임존" hint="타임스탬프 표시 기준"><SetSeg value={tz} options={['Asia/Seoul', 'Asia/Tokyo', 'UTC']} onChange={setTz} /></SetRow>
                <SetRow label="24시간제" hint="시각 표기"><SetToggle on={clock24} onChange={setClock24} /></SetRow>
              </React.Fragment>
            )}
          </div>
        </div>
      </div>
    </main>
  );
}

Object.assign(window, { SettingsSurface });
