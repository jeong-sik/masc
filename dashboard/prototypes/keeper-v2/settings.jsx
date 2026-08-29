/* MASC v2 — Settings surface: sectioned operator console.
   Grounded in real MASC concepts (README): /mcp endpoint, operator role, masc_* tools,
   /api/v1/gate, 12-state FSM, namespace. Controls hold local state — persistence is mock. */
const { useState: useSet } = React;

function SetToggle({ on, onChange }) {
  return <button className={`set-toggle ${on ? 'on' : ''}`} onClick={() => onChange(!on)} role="switch" aria-checked={on}><span className="knob"></span></button>;
}
function SetSeg({ value, options, onChange }) {
  return <div className="set-seg">{options.map(o => <button key={o} className={`set-seg-b ${value === o ? 'on' : ''}`} aria-pressed={value === o} onClick={() => onChange(o)}>{o}</button>)}</div>;
}
function SetRow({ label, hint, children }) {
  return (
    <div className="set-row">
      <div className="set-row-l"><div className="set-label">{label}</div>{hint && <div className="set-hint">{hint}</div>}</div>
      <div className="set-row-c">{children}</div>
    </div>
  );
}
function SetStepper({ v, set, min, max, label }) {
  return (
    <div className="set-stepper" role="group" aria-label={label}>
      <button aria-label={`${label || ''} 1 줄이기`.trim()} disabled={v <= min} onClick={() => set(Math.max(min, v - 1))}>−</button>
      <span className="mono" aria-live="polite">{v}</span>
      <button aria-label={`${label || ''} 1 늘리기`.trim()} disabled={v >= max} onClick={() => set(Math.min(max, v + 1))}>+</button>
    </div>
  );
}
function VerifyBtn({ label }) {
  const [st, setSt] = useSet('idle');
  return <button className={`set-verify ${st}`} onClick={(e) => { e.stopPropagation(); setSt('checking'); setTimeout(() => setSt('ok'), 700); }}>{st === 'idle' ? (label || '확인') : st === 'checking' ? '확인 중…' : '✓ 정상'}</button>;
}

// Settings 섹션 = 소스 SETTINGS_ROUTE_SECTION_IDS (2026-07 · 12개):
// account · runtime · routing · runtimes · paths · mcp · repositories · notify · prompts · fusion · logs · display.
// 소스에서 제거됨: policy(tool_policy 미사용) · lifecycle · sandbox(→ keeper별 설정/레지스트리) · gate(→ Gate 상위 surface) · ide.
const SET_SECTIONS = [
  ['account', 'Account', '계정'],
  ['runtime', 'Runtime', '런타임 기본값'],
  ['runtimes', 'Runtimes', '런타임 관리'],
  ['routing', 'Routing', '모델 라우팅'],
  ['mcp', 'MCP', 'MCP 서버'],
  ['prompts', 'Prompts', '기본 프롬프트'],
  ['fusion', 'Fusion', '패널·심판 심의'],
  ['repositories', 'Repositories', '저장소'],
  ['paths', 'Paths', '경로 · Basepath'],
  ['logs', 'Logs', '관측 · 시스템 로그'],
  ['notify', 'Notify', '알림'],
  ['display', 'Display', '표시'],
];

const SET_GROUPS = [
  ['계정', ['account']],
  ['Keeper 운영', ['runtime', 'routing', 'prompts', 'fusion']],
  ['인프라 · 실행', ['runtimes', 'paths']],
  ['연결 · 통합', ['mcp', 'repositories']],
  ['관측 · 알림', ['logs', 'notify', 'display']],
];

// Real masc_* tools, grouped by tool_policy.toml [masc.*] groups (essential /
// workspace / goal) + masc_fusion ([fusion]). The fabricated masc_start /
// masc_handoff / masc_compact / masc_amplitude_query / masc_trace_window /
// masc_board_metrics / masc_git_blame names did NOT exist in the registry.
const MCP_TOOL_GROUPS = [
  ['essential', 'essential — 모든 keeper (오리엔테이션 + 웹)', ['masc_status', 'masc_web_search', 'masc_web_fetch']],
  ['workspace', 'workspace — 태스크·에이전트 조정', ['masc_tasks', 'masc_claim_next', 'masc_transition', 'masc_add_task', 'masc_agents', 'masc_broadcast', 'masc_messages', 'masc_heartbeat']],
  ['goal', 'goal — 목표 Store + FSM 증명', ['masc_goal_list', 'masc_goal_upsert', 'masc_goal_transition', 'masc_goal_verify']],
  ['fusion', 'fusion — 패널·심판 심의 (RFC-0252)', ['masc_fusion']],
];
const MCP_TOOLS = MCP_TOOL_GROUPS.flatMap(g => g[2]);

// [fusion] — RFC-0252 panel+judge deliberation (config/runtime.toml [fusion]).
const FUSION = {
  enabled: true,
  default_preset: 'trio',
  max_concurrent_panels: 2,
  per_hour_budget: 20,
  presets: {
    trio: {
      panel: ['ollama_cloud.deepseek-v4-flash', 'glm-coding.glm-5-turbo', 'ollama_cloud.minimax-m3'],
      judge: 'deepseek.deepseek-v4-pro',
      panel_timeout_s: 300, judge_timeout_s: 300,
      web_tools: false, max_tool_calls_per_panel: 0,
    },
  },
};

// tool_policy.toml — named groups referenced by keeper tool_access lists.
// kind: 'local' = [groups.*] (keeper-local tools) · 'masc' = [masc.*] (server tools).
const TOOL_GROUPS = [
  { id: 'base', kind: 'local', tools: ['keeper_time_now', 'keeper_context_status', 'keeper_memory_search', 'keeper_memory_write', 'keeper_tool_search', 'keeper_tools_list'] },
  { id: 'board_core', kind: 'local', tools: ['keeper_board_get', 'keeper_board_post', 'keeper_board_comment', 'keeper_board_vote', 'keeper_board_list', 'keeper_board_curation_read', 'keeper_board_curation_submit'] },
  { id: 'workspace_core', kind: 'local', tools: ['keeper_tasks_list', 'keeper_task_claim', 'keeper_task_create', 'keeper_task_done', 'keeper_broadcast'] },
  { id: 'filesystem', kind: 'local', tools: ['tool_read_file'] },
  { id: 'workspace_write', kind: 'local', tools: ['tool_edit_file', 'tool_write_file'] },
  { id: 'execute', kind: 'local', guard: true, tools: ['tool_execute'] },
  { id: 'library', kind: 'local', tools: ['keeper_library_search', 'keeper_library_read'] },
  { id: 'voice', kind: 'local', optin: true, tools: ['keeper_voice_speak', 'keeper_voice_listen', 'keeper_voice_agent', 'keeper_voice_sessions'] },
  { id: 'masc.essential', kind: 'masc', tools: ['masc_status', 'masc_web_search', 'masc_web_fetch'] },
  { id: 'masc.workspace', kind: 'masc', tools: ['masc_tasks', 'masc_claim_next', 'masc_transition', 'masc_add_task', 'masc_agents', 'masc_broadcast', 'masc_messages', 'masc_heartbeat'] },
  { id: 'masc.goal', kind: 'masc', tools: ['masc_goal_list', 'masc_goal_upsert', 'masc_goal_transition', 'masc_goal_verify'] },
];
// [groups.last_turn_safe] — on a keeper's final turn, allowed tools are intersected with this set.
const LAST_TURN_SAFE = ['keeper_board_post', 'keeper_board_comment', 'keeper_board_curation_submit', 'keeper_context_status', 'extend_turns', 'keeper_time_now', 'keeper_tool_search', 'keeper_broadcast', 'keeper_tasks_list', 'keeper_task_done', 'masc_tasks', 'masc_transition', 'tool_read_file', 'tool_search_files', 'tool_execute', 'masc_web_search', 'masc_web_fetch'];
// tool_execute 3-layer deterministic guard (tool_policy.toml [groups.execute]).
const EXEC_GUARD = ['validate_command', 'destructive_guard', 'write_gate'];
// [discord].trigger_policy (config/runtime.toml) — env MASC_DISCORD_TRIGGER_POLICY overrides.
const DISCORD_TRIGGER = [
  ['mention_or_thread', '스레드 자동 응답, 일반 채널은 멘션 필요 (기본)'],
  ['mention_only', '@멘션된 메시지만 응답'],
  ['all', '모든 메시지에 응답'],
  ['user_only', '특정 사용자(snowflake)만'],
];
const RUNTIMES = [
  { name: 'ollama_cloud.deepseek-v4-flash', endpoint: 'agent-core://seoul-1.masc.run', region: 'ap-northeast-2', kind: 'AGENT_CORE', keepers: 3 },
  { name: 'deepseek.deepseek-v4-pro', endpoint: 'agent-core://tokyo-2.masc.run', region: 'ap-northeast-1', kind: 'AGENT_CORE', keepers: 2 },
  { name: 'ollama.gemma4-26b-a4b-qat', endpoint: 'unix:///var/run/masc.sock', region: 'local', kind: 'Docker', keepers: 1 },
];
const APPROVAL_ACTIONS = [
  ['git push / merge', 'always', '원격 브랜치에 쓰기'],
  ['배포 (infra/deploy)', 'always', 'deploy 트리거'],
  ['외부 호출 (Slack·Discord 발신)', 'risky', '외부로 메시지 전송'],
  ['파일 쓰기 (worktree)', 'auto', 'keeper 워크트리 내 편집'],
  ['읽기 전용 도구', 'auto', 'query·trace·blame 등'],
];
const SYS_LOG = [
  ['16:24:51', 'info', 'masc-improver', 'masc_web_search 완료', 'ok'],
  ['16:24:48', 'info', 'masc-improver', 'masc_web_search 호출', 'run'],
  ['16:23:10', 'warn', 'nick0cave', 'Compaction_started — provider overflow 복구', 'warn'],
  ['16:22:55', 'info', 'sangsu', 'keeper_memory_search 완료', 'ok'],
  ['16:21:02', 'error', 'drifter', 'masc_fusion 실패 — context overflow', 'fail'],
  ['16:20:40', 'info', 'qa-king', 'masc_transition HandingOff → sangsu 인계 시작', 'run'],
  ['16:19:33', 'info', 'nick0cave', 'masc_transition Compacting 완료 (−64%)', 'ok'],
  ['16:18:12', 'error', 'drifter', 'masc_transition Restarting 실패 (3/3)', 'fail'],
  ['16:17:50', 'info', 'scholar', 'masc_goal_verify 완료', 'ok'],
  ['16:16:04', 'warn', 'analyst', 'keeper_memory_write 색인 실패 1건', 'warn'],
];

function LogViewer() {
  const [f, setF] = useSet('전체');
  const rows = SYS_LOG.filter(r => f === '전체' || (f === '도구' && /(masc|keeper)_/.test(r[3])) || (f === '성공' && r[4] === 'ok') || (f === '실패' && r[4] === 'fail'));
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
  const [defRuntime, setDefRuntime] = useSet('ollama_cloud.deepseek-v4-flash');
  const [defModel, setDefModel] = useSet('deepseek-v4-flash');
  const [maxPar, setMaxPar] = useSet(6);
  const [compactAt, setCompactAt] = useSet(85);
  const [autoCompact, setAutoCompact] = useSet(true);
  const [rtEditorOpen, setRtEditorOpen] = useSet(false);
  // routing — real [runtime] lanes from runtime-data.jsx (default/librarian/cross_verifier)
  const [routing, setRouting] = useSet(() => ({ ...(window.RT_ROUTING || { default: 'ollama_cloud.deepseek-v4-flash', librarian: 'ollama_cloud.minimax-m3', cross_verifier: 'deepseek.deepseek-v4-pro' }) }));
  const [approve, setApprove] = useSet(Object.fromEntries(APPROVAL_ACTIONS.map(a => [a[0], a[1]])));
  // tool policy (grant named groups at namespace level) + fusion
  const [grant, setGrant] = useSet(() => Object.fromEntries(TOOL_GROUPS.map(g => [g.id, !g.optin])));
  const [fusionOn, setFusionOn] = useSet(FUSION.enabled);
  const [fusionPreset, setFusionPreset] = useSet(FUSION.default_preset);
  const [fusionPanels, setFusionPanels] = useSet(FUSION.max_concurrent_panels);
  const [fusionBudget, setFusionBudget] = useSet(FUSION.per_hour_budget);
  const [fusionWeb, setFusionWeb] = useSet(FUSION.presets.trio.web_tools);
  const [discordTrigger, setDiscordTrigger] = useSet('mention_or_thread');
  // lifecycle
  const [idleDrain, setIdleDrain] = useSet(30);
  const [autoRestart, setAutoRestart] = useSet(true);
  const [restartMax, setRestartMax] = useSet(3);
  const [onOverflow, setOnOverflow] = useSet('자동 compact');
  // gate / paths
  const [gateBase, setGateBase] = useSet('https://gate.masc.local');
  const [gateOn, setGateOn] = useSet({ Discord: true, Slack: true, iMessage: false, Webhook: true });
  const [wtBase, setWtBase] = useSet('~/wt');
  const [storeUrl, setStoreUrl] = useSet('postgres://masc.local:5432/masc');
  // sandbox — real MASC keys only (keepers/<name>.toml [access])
  const [sbProfile, setSbProfile] = useSet('local');
  const [netMode, setNetMode] = useSet('inherit');
  // repositories — POST /api/v1/repositories (add-repo-dialog.ts fields)
  const [repos, setRepos] = useSet([
    { id: 'masc', name: 'masc', url: 'https://github.com/jeong-sik/masc.git', branch: 'main', autoSync: true, interval: 300, path: '.masc/repos/masc' },
    { id: 'kidsnote', name: 'kidsnote-web', url: 'https://github.com/kidsnote/web.git', branch: 'develop', autoSync: false, interval: 300, path: '.masc/repos/kidsnote-web' },
  ]);
  const [repoAdding, setRepoAdding] = useSet(false);
  const [fleetMax, setFleetMax] = useSet(10);
  const [repoForm, setRepoForm] = useSet({ name: '', url: '', branch: 'main', autoSync: true, interval: 300, path: '' });
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
  const _nf = (typeof window !== 'undefined' && window.MASC_NOTIFY) || {};
  const [notifyCtx, setNotifyCtx] = useSet(_nf.ctx ?? 85);
  const [notifyFails, setNotifyFails] = useSet(_nf.fails ?? 3);
  const [notifyCh, setNotifyCh] = useSet(_nf.channel ?? 'Slack');
  const [notifyOn, setNotifyOn] = useSet(_nf.on ?? { '컨텍스트 오버플로우 · 압축': true, '연속 실패': true, 'keeper crash/dead': true, '핸드오프 완료': false, '승인 요청': true });
  // push every Notify edit into the live alarm engine (window.MASC_NOTIFY)
  const _pushNotify = (patch) => { if (window.setNotify) window.setNotify(patch); };
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
                <SetRow label="MCP 엔드포인트" hint="GET/POST /mcp"><div className="set-path"><input className="set-input mono" value={mcpUrl} onChange={e => setMcpUrl(e.target.value)} /><VerifyBtn /></div></SetRow>
                <SetRow label="전송 방식" hint="transport"><SetSeg value={transport} options={['http', 'stdio', 'sse']} onChange={setTransport} /></SetRow>
                <div className="set-mcp-detail mono">
                  {transport === 'http' && <span>POST {mcpUrl}  ·  Content-Type: application/json  ·  Authorization: Bearer ••••</span>}
                  {transport === 'stdio' && <span>spawn: masc-mcp serve --stdio  ·  framing: ndjson  ·  pid 8421</span>}
                  {transport === 'sse' && <span>GET {mcpUrl}/sse  ·  keep-alive 15s  ·  event: message</span>}
                </div>
                <div className="set-sub-h">노출 도구 ({Object.values(tools).filter(Boolean).length}/{MCP_TOOLS.length})</div>
                {MCP_TOOL_GROUPS.map(([gid, glabel, gtools]) => (
                  <React.Fragment key={gid}>
                    <div className="set-mcp-detail mono" style={{ margin: '10px 0 2px' }}>{glabel}</div>
                    {gtools.map(t => (
                      <SetRow key={t} label={<span className="mono" style={{ fontSize: 12.5 }}>{t}</span>}><SetToggle on={tools[t]} onChange={(v) => setTools(p => ({ ...p, [t]: v }))} /></SetRow>
                    ))}
                  </React.Fragment>
                ))}
              </React.Fragment>
            )}

            {sec === 'runtime' && (
              <React.Fragment>
                <SetRow label="기본 런타임" hint="[runtime].default · 새 keeper 가 시작될 런타임 id (provider.model)">
                  <select className="set-input mono" style={{ minWidth: 260 }} value={defRuntime} onChange={e => setDefRuntime(e.target.value)}>
                    {(window.rtRuntimeIds ? window.rtRuntimeIds() : [defRuntime]).map(id => <option key={id} value={id}>{id}</option>)}
                  </select>
                </SetRow>
                <SetRow label="autoboot_max" hint="부팅 시 자동 기동할 keeper 수"><SetStepper v={maxPar} set={setMaxPar} min={1} max={12} label="autoboot_max" /></SetRow>
                <SetRow label="플릿 메시지 상한" hint="다른 keeper 발화를 몇 건까지 볼지 · 0 = 끔"><SetStepper v={fleetMax} set={setFleetMax} min={0} max={50} label="플릿 메시지 상한" /></SetRow>
                <SetRow label="스트림 idle timeout" hint="응답이 멈춘 채 이 시간을 넘기면 중단"><span className="set-ro mono">600s · floor (부팅 로그가 유효값과 출처를 명시)</span></SetRow>
                <SetRow label="모델 카탈로그" hint="사용 가능한 모델 목록"><span className="set-ro mono">agent-core-models-overlay.toml · override = MASC_MODEL_CATALOG</span></SetRow>
                <div className="set-dead">☠ 읽히지 않는 키 — 있으면 제거: <span className="mono">[autonomous] concurrency</span> · <span className="mono">[bootstrap] max_active_keepers</span> · <span className="mono">memory_os_consolidation</span>(이 키가 남아있으면 파서가 unknown 으로 거부). 자동 컴팩션 임계치 설정은 소스에서 삭제되어 이 자리에 더 이상 없습니다.</div>
              </React.Fragment>
            )}

            {sec === 'runtimes' && (
              <div className="set-rt-launch">
                <h3>런타임 편집기</h3>
                <p>provider × model × binding 구조의 실제 <span className="mono">config/runtime.toml</span>을 편집 — 라우팅 레인, 프로바이더, 모델 능력, 바인딩(런타임 id), keeper 배정.</p>
                <div className="set-rt-launch-stats">
                  <div className="set-rt-launch-stat"><span className="v mono">{window.rtRuntimeIds ? window.rtRuntimeIds().length : 0}</span><span className="k">런타임 id</span></div>
                  <div className="set-rt-launch-stat"><span className="v mono">{(window.RT_PROVIDERS || []).length}</span><span className="k">프로바이더</span></div>
                  <div className="set-rt-launch-stat"><span className="v mono">{(window.RT_MODELS || []).length}</span><span className="k">모델</span></div>
                </div>
                <div className="set-mcp-detail mono" style={{ marginBottom: 14 }}>default = {window.RT_ROUTING ? window.RT_ROUTING.default : '—'}</div>
                <button className="set-rt-open" onClick={() => setRtEditorOpen(true)}>런타임 편집기 열기 →</button>
              </div>
            )}

            {sec === 'routing' && (
              <React.Fragment>
                <div className="set-hint" style={{ marginBottom: 12 }}><span className="mono">[runtime]</span> 라우팅 레인. keeper 채팅은 <b>default</b> 를 쓰고, 특정 작업만 전용 런타임으로 분기됩니다. <span className="mono">librarian·cross_verifier</span> 는 JSON 모드가 필요해 JSON 비지원 런타임은 선택지에서 제외됩니다.</div>
                {[['default', '기본 — keeper 채팅', '미할당 keeper 가 상속', false], ['librarian', 'Librarian — memory-os', '턴 후 에피소드 추출 · JSON 모드 필요', true], ['cross_verifier', 'Cross-verifier', '반-합리화 평가자 · JSON 모드 필요', true]].map(([lane, lbl, hint, needJson]) => {
                  const ids = (window.rtRuntimeIds ? window.rtRuntimeIds() : [routing[lane]]).filter(id => !needJson || !window.rtIsJsonCapable || window.rtIsJsonCapable(id));
                  return (
                    <SetRow key={lane} label={lbl} hint={hint}>
                      <select className="set-input mono" style={{ minWidth: 240 }} value={routing[lane]} onChange={e => setRouting(p => ({ ...p, [lane]: e.target.value }))}>
                        {ids.map(id => <option key={id} value={id}>{id}</option>)}
                      </select>
                    </SetRow>
                  );
                })}
                <div className="set-mcp-detail mono" style={{ marginTop: 12 }}>media_failover = [] · 키퍼별 override 는 런타임 편집기 · [runtime.assignments] 에서</div>
              </React.Fragment>
            )}

            {sec === 'prompts' && (
              <div className="set-promptbook-host">
                {window.PromptBook ? <window.PromptBook /> : <div className="set-hint">주입서 로딩…</div>}
              </div>
            )}

            {sec === 'fusion' && (
              <React.Fragment>
                <div className="set-hint" style={{ marginBottom: 12 }}><span className="mono">masc_fusion</span> 의 out-of-band 심의 루프 (RFC-0252). 서로 다른 모델 패밀리로 패널을 구성해 관점 다양성을 확보하고, 심판이 종합합니다. 귫fusion이 발화 가치 있는지는 keeper가 판단하고 게이트는 남용만 막습니다.</div>
                <SetRow label="Fusion 심의" hint="끄면 masc_fusion 호출이 게이트에서 Deny 반환">
                  <SetToggle on={fusionOn} onChange={setFusionOn} />
                </SetRow>
                {fusionOn && (
                  <React.Fragment>
                    <SetRow label="기본 프리셋" hint="default_preset"><SetSeg value={fusionPreset} options={['trio']} onChange={setFusionPreset} /></SetRow>
                    <SetRow label="동시 패널 수" hint="max_concurrent_panels · Async_agent.all 상한"><SetStepper v={fusionPanels} set={setFusionPanels} min={1} max={8} label="동시 패널 수" /></SetRow>
                    <SetRow label="시간당 발화 budget" hint="[fusion.gate].per_hour_budget · UTC hour bucket"><SetStepper v={fusionBudget} set={setFusionBudget} min={1} max={100} label="시간당 발화 budget" /></SetRow>
                    <SetRow label="패널·심판 웹 도구" hint="web_search / web_fetch 주입 여부"><SetToggle on={fusionWeb} onChange={setFusionWeb} /></SetRow>

                    <div className="set-sub-h">trio 프리셋</div>
                    <div className="set-fus-preset">
                      <div className="set-fus-lane">
                        <div className="set-fus-lane-h">panel · {FUSION.presets.trio.panel.length}</div>
                        {FUSION.presets.trio.panel.map(id => <div key={id} className="set-fus-model mono">{id}</div>)}
                      </div>
                      <div className="set-fus-lane">
                        <div className="set-fus-lane-h">judge</div>
                        <div className="set-fus-model judge mono">{FUSION.presets.trio.judge}</div>
                      </div>
                    </div>
                    <div className="set-mcp-detail mono" style={{ marginTop: 10 }}>panel_timeout {FUSION.presets.trio.panel_timeout_s}s · judge_timeout {FUSION.presets.trio.judge_timeout_s}s · max_tool_calls_per_panel {FUSION.presets.trio.max_tool_calls_per_panel} (0 = 무제한)</div>
                  </React.Fragment>
                )}
              </React.Fragment>
            )}

            {sec === 'policy' && (
              <React.Fragment>
                <div className="set-hint" style={{ marginBottom: 10 }}>도구 접근은 런타임에 <span className="mono">registry/descriptor</span> 로 결정됩니다. 여기서 namespace 기본 부여 그룹과 안전장치를 관리합니다.</div>
                <div className="set-legacy-note">
                  <span className="set-legacy-tag">legacy</span>
                  <span><span className="mono">tool_policy.toml</span> 은 config-root 마커일 뿐 — 내용은 런타임에서 읽지 않습니다. 아래 그룹 정의는 registry/descriptor 를 반영한 표시용입니다.</span>
                </div>
                <div className="set-sub-h">도구 그룹 부여</div>
                {TOOL_GROUPS.map(g => (
                  <div key={g.id} className="set-tg-row">
                    <div className="set-tg-l">
                      <div className="set-tg-head">
                        <span className="set-tg-id mono">{g.id}</span>
                        <span className={`set-tg-kind ${g.kind}`}>{g.kind}</span>
                        {g.guard && <span className="set-tg-kind guard">3-layer guard</span>}
                        {g.optin && <span className="set-tg-kind optin">opt-in</span>}
                      </div>
                      <div className="set-tg-tools">{g.tools.map(t => <span key={t} className="set-tg-chip mono">{t}</span>)}</div>
                    </div>
                    <SetToggle on={grant[g.id]} onChange={(v) => setGrant(p => ({ ...p, [g.id]: v }))} />
                  </div>
                ))}

                <div className="set-sub-h">tool_execute 가드 — 3계층 결정적</div>
                <div className="set-hint" style={{ marginBottom: 8 }}>셀 타입된 argv 명령은 세 계층을 순차 통과해야 실행됩니다. redirection/tee 또는 직접 file write 우회는 여기서 막힙니다.</div>
                <div className="set-guard">
                  {EXEC_GUARD.map((s, i) => (
                    <React.Fragment key={s}>
                      {i > 0 && <span className="set-guard-arrow">→</span>}
                      <span className="set-guard-step mono">{s}</span>
                    </React.Fragment>
                  ))}
                </div>

                <div className="set-sub-h">마지막 턴 안전 도구 — last_turn_safe</div>
                <div className="set-hint" style={{ marginBottom: 8 }}>keeper 의 마지막 턴에서는 허용 도구가 이 집합과 교집합됩니다 ({LAST_TURN_SAFE.length}개).</div>
                <div className="set-tg-tools">{LAST_TURN_SAFE.map(t => <span key={t} className="set-tg-chip mono safe">{t}</span>)}</div>
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
                <div className="set-hint" style={{ marginBottom: 12 }}>keeper 실행 격리의 <b>namespace 기본값</b>. keeper별 override 는 각 keeper 설정에서. 실제 키는 <span className="mono">sandbox_profile</span> · <span className="mono">network_mode</span> 입니다.</div>
                <div className="set-callout warn" style={{ marginBottom: 14 }}>
                  <b>보안 경계 아님.</b> <span className="mono">container</span> 는 <span className="mono">docker run</span> 을 호출하지만 Docker 미가용 시 <b>local 실행으로 폴백</b>합니다. 신뢰 경계가 아니라 편의적 격리로 취급하세요.
                </div>
                <SetRow label="sandbox_profile" hint="실행 격리 방식 · keeper 기본값"><SetSeg value={sbProfile} options={['local', 'container', 'none']} onChange={setSbProfile} /></SetRow>
                <SetRow label="network_mode" hint="inherit=호스트 상속 · off=차단 · allow=허용"><SetSeg value={netMode} options={['inherit', 'off', 'allow']} onChange={setNetMode} /></SetRow>
              </React.Fragment>
            )}

            {sec === 'ide' && (
              <React.Fragment>

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
                <div className="set-hint" style={{ marginBottom: 12 }}>외부 게이트 채널의 기본 설정. 실제 지원 채널은 <span className="mono">discord · slack · imessage · webhook</span> 이며, 개별 채널→keeper 바인딩은 <button className="set-link" onClick={() => onNav && onNav('connectors')}>커넥터 화면 →</button> 에서 관리합니다.</div>
                <SetRow label="게이트 base URL" hint="GET /api/v1/gate/connectors"><div className="set-path"><input className="set-input mono" value={gateBase} onChange={e => setGateBase(e.target.value)} /><VerifyBtn /></div></SetRow>
                {[['Discord', 'live'], ['Slack', 'sidecar'], ['iMessage', 'sidecar'], ['Webhook', 'live']].map(([g, tier]) => (
                  <SetRow key={g} label={g} hint={tier === 'sidecar' ? 'sidecar 필요 · 미가동 시 비활성' : gateOn[g] ? '연결됨' : '비활성'}><SetToggle on={gateOn[g]} onChange={(v) => setGateOn(p => ({ ...p, [g]: v }))} /></SetRow>
                ))}
                {gateOn.Discord && (
                  <React.Fragment>
                    <div className="set-sub-h">Discord 트리거 정책</div>
                    <div className="set-hint" style={{ marginBottom: 8 }}>어떤 인바운드 이벤트에 봇이 응답할지 — <span className="mono">[discord].trigger_policy</span> · env <span className="mono">MASC_DISCORD_TRIGGER_POLICY</span> 우선.</div>
                    {DISCORD_TRIGGER.map(([val, hint]) => (
                      <button key={val} className={`set-trigger ${discordTrigger === val ? 'on' : ''}`} onClick={() => setDiscordTrigger(val)}>
                        <span className="set-trigger-radio"></span>
                        <span className="set-trigger-l"><span className="mono">{val}</span><span className="set-trigger-hint">{hint}</span></span>
                      </button>
                    ))}
                  </React.Fragment>
                )}
              </React.Fragment>
            )}

            {sec === 'repositories' && (
              <React.Fragment>
                <div className="set-hint" style={{ marginBottom: 12 }}>keeper 가 작업하는 git 저장소. 등록하면 <span className="mono">POST /api/v1/repositories</span> 로 클론되고, keeper 별 매핑은 워크스페이스 › Repositories 에서. 워크트리는 <span className="mono">.masc/repos/&lt;id&gt;</span> 아래.</div>
                <div className="set-repo-list">
                  {repos.map(r => (
                    <div key={r.id} className="set-repo">
                      <div className="set-repo-main">
                        <div className="set-repo-name mono">{r.name}<span className="set-repo-branch">{r.branch}</span></div>
                        <div className="set-repo-url mono">{r.url}</div>
                      </div>
                      <div className="set-repo-meta">
                        <span className={'set-repo-sync' + (r.autoSync ? ' on' : '')}>{r.autoSync ? `자동 · ${r.interval}s` : '수동'}</span>
                        <button className="set-repo-del" title="저장소 제거" onClick={() => setRepos(repos.filter(x => x.id !== r.id))}>✕</button>
                      </div>
                    </div>
                  ))}
                  {repos.length === 0 && <div className="dashed-notice">등록된 저장소 없음</div>}
                </div>

                {!repoAdding ? (
                  <button className="set-add" onClick={() => { setRepoForm({ name: '', url: '', branch: 'main', autoSync: true, interval: 300, path: '' }); setRepoAdding(true); }}>＋ 저장소 추가</button>
                ) : (
                  <div className="set-repo-form">
                    <div className="set-sub-h">저장소 추가</div>
                    <SetRow label="이름" hint="필수"><input className="set-input mono" style={{ width: 220 }} placeholder="my-project" value={repoForm.name} onChange={e => setRepoForm({ ...repoForm, name: e.target.value })} /></SetRow>
                    <SetRow label="URL" hint="필수 · git remote"><input className="set-input mono" style={{ width: 300 }} placeholder="https://github.com/owner/repo.git" value={repoForm.url} onChange={e => setRepoForm({ ...repoForm, url: e.target.value })} /></SetRow>
                    <SetRow label="기본 브랜치" hint="default_branch"><input className="set-input mono" style={{ width: 160 }} placeholder="main" value={repoForm.branch} onChange={e => setRepoForm({ ...repoForm, branch: e.target.value })} /></SetRow>
                    <SetRow label="로컬 경로" hint="비우면 .masc/repos/<id>"><input className="set-input mono" style={{ width: 260 }} placeholder=".masc/repos/<id>" value={repoForm.path} onChange={e => setRepoForm({ ...repoForm, path: e.target.value })} /></SetRow>
                    <SetRow label="자동 동기화" hint="auto_sync"><SetToggle on={repoForm.autoSync} onChange={v => setRepoForm({ ...repoForm, autoSync: v })} /></SetRow>
                    {repoForm.autoSync && <SetRow label="동기화 간격" hint="초 · 최소 60"><SetStepper v={repoForm.interval} set={val => { const n = typeof val === 'function' ? val(repoForm.interval) : val; setRepoForm({ ...repoForm, interval: Math.max(60, n) }); }} min={60} max={3600} step={60} /></SetRow>}
                    <div className="set-repo-form-act">
                      <button className="set-btn-ghost" onClick={() => setRepoAdding(false)}>취소</button>
                      <button className="set-btn-primary" disabled={!repoForm.name.trim() || !repoForm.url.trim()} onClick={() => {
                        const id = repoForm.name.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-');
                        setRepos([...repos, { id, name: repoForm.name.trim(), url: repoForm.url.trim(), branch: repoForm.branch.trim() || 'main', autoSync: repoForm.autoSync, interval: repoForm.interval, path: repoForm.path.trim() || `.masc/repos/${id}` }]);
                        setRepoAdding(false);
                        if (window.pushToast) window.pushToast({ tone: 'ok', msg: '저장소 등록 완료', sub: repoForm.name.trim() });
                      }}>저장소 등록</button>
                    </div>
                  </div>
                )}
              </React.Fragment>
            )}

            {sec === 'paths' && (
              <React.Fragment>
                <SetRow label="MCP 엔드포인트" hint="HTTP 진입점"><div className="set-path"><input className="set-input mono" value={mcpUrl} onChange={e => setMcpUrl(e.target.value)} /><VerifyBtn /></div></SetRow>
                <SetRow label="스토어 (DB)" hint="trace · 감사 저장소"><div className="set-path"><input className="set-input mono" value={storeUrl} onChange={e => setStoreUrl(e.target.value)} /><VerifyBtn /></div></SetRow>
                <SetRow label="기본 worktree basepath" hint="keeper worktree 루트 — 예: ~/wt/<keeper>"><div className="set-path"><input className="set-input mono" value={wtBase} onChange={e => setWtBase(e.target.value)} /><VerifyBtn label="경로 확인" /></div></SetRow>
                <div className="set-sub-h">상태 스토어 레이아웃 (읽기 전용 · --base-path 기준)</div>
                <div className="set-storemap">
                  {[
                    ['.masc/root-state.json', 'workspace 루트 마커 — 구 .masc/state.json fallback 제거됨'],
                    ['.masc/costs/YYYY-MM/DD.jsonl', '비용 원장 — 날짜 분할 · (trace_id, keeper_turn_id, oas_turn_ordinal) 정확 일치로만 병합'],
                    ['.masc/telemetry/YYYY-MM/DD.jsonl', '텔레메트리 — 단일 .masc/telemetry.jsonl 리더 제거됨'],
                    ['.masc/gate/', 'Gate 상태 · Always Allowed 규칙 저장소 · Auto Judge 판단'],
                    ['.masc/keepers/*.json + *.jsonl', 'keeper 런타임 상태·메모리 (서버가 생성 — 수정 금지)'],
                    ['.masc/audit-approvals/', 'HITL 승인 이력'],
                  ].map(([p, d]) => (
                    <div key={p} className="set-storerow"><span className="mono">{p}</span><span className="d">{d}</span></div>
                  ))}
                </div>
                <div className="set-dead">호스트 FD 압박 오버라이드는 <span className="mono">MASC_HOST_FD_PRESSURE_STATE_FILE</span> 하나 (+ <span className="mono">--base-path</span> / <span className="mono">MASC_BASE_PATH</span>). repo·cwd fallback 과 <span className="mono">MASC_SYSMON_PRESSURE_STATE</span> 는 거부됩니다.</div>
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
                <SetRow label="오버플로우 · 압축 알림" hint="Compaction_started 관측 시 알림 (임계치 설정 없음)"><span className="set-ro mono">이벤트 기반 · 항상 관측</span></SetRow>
                <SetRow label="연속 실패 알림" hint="이 횟수 연속 실패 시 알림"><SetStepper v={notifyFails} set={(v) => { const n = typeof v === 'function' ? v(notifyFails) : v; setNotifyFails(n); _pushNotify({ fails: n }); }} min={1} max={10} /></SetRow>
                <SetRow label="알림 채널" hint="어디로 보낼지 · '없음'이면 알림 끔"><SetSeg value={notifyCh} options={['Slack', 'Discord', '없음']} onChange={(v) => { setNotifyCh(v); _pushNotify({ channel: v }); }} /></SetRow>
                <div className="set-sub-h">알림 이벤트</div>
                {Object.keys(notifyOn).map(k => <SetRow key={k} label={k}><SetToggle on={notifyOn[k]} onChange={(v) => { setNotifyOn(p => { const n = { ...p, [k]: v }; _pushNotify({ on: n }); return n; }); }} /></SetRow>)}
                <div className="set-row">
                  <div className="set-row-l"><div className="set-label">테스트 알림</div><div className="set-hint">현재 채널·토글로 실제 토스트를 한 번 발화</div></div>
                  <div className="set-row-c"><button className="set-verify" onClick={(e) => { e.stopPropagation(); if (window.fireAlarm) window.fireAlarm('승인 요청', { force: true, tone: 'info', msg: '테스트 알림', sub: notifyCh === '없음' ? '채널 없음 — 발화만 표시' : '설정 동작 확인' }); }}>보내기</button></div>
                </div>
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
      {rtEditorOpen && window.RuntimeEditor && <window.RuntimeEditor onClose={() => setRtEditorOpen(false)} />}
    </main>
  );
}

Object.assign(window, { SettingsSurface });
