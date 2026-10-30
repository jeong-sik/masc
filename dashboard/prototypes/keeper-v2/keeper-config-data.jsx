/* MASC v2 — Keeper 상세 설정: 데이터 레이어.
   - KC_GOALS : 배정 가능한 goal 카탈로그 (실제 시스템 goal id/제목 기반, horizon 태그).
   - KC_HOOKS : keeper lifecycle 훅 14 슬롯 (slot · source · gate).
   - keeperConfig(k) : keeper 한 명의 구조화된 설정 기본값.
   필드는 실제 keeper 상세 화면(runtime.toml · live override · keeper 프롬프트)을
   카테고리로 재정리한 것. 일부 미구현 필드는 surface 쪽에서 '기획'으로 표기한다. */

// 배정 가능한 goal — 실제 goal store의 제목/horizon을 반영(검색·필터 데모용 충분량).
const KC_GOALS = [
  ['goal-automated-pipeline', 'Automated task/goal generation pipeline — prevents backlog stagnation', 'short'],
  ['goal-pm-flow', 'PM Flow: backlog clearance and capacity_backpressure fix', 'short'],
  ['goal-lifecycle-worker-proof-2', 'PR Lifecycle Proof Attempt 2', 'short'],
  ['goal-1779422574029-023a', 'Fix fleet-level infrastructure blockers (capacity_backpressure, verification queue)', 'short'],
  ['goal-system-recovery', 'System recovery from cascade exhaustion and provider pool depletion', 'short'],
  ['goal-backlog-triage', 'Backlog Triage: re-scope and route stalled tasks', 'short'],
  ['goal-keeper-tool-selection-surface-contract-20260612', 'Stabilize Keeper tool selection for Discord/channel surface queries', 'short'],
  ['goal-1781294776367-2046', 'MASC/AGENT_CORE turn lifecycle audit: eliminate waste, SSOT drift, silent failures', 'short'],
  ['goal-merge-audit-20260613', '2026-06-13 머지 감사 결함 해소 (P1 3건 + P2 핵심)', 'short'],
  ['goal-utilization-recovery-20260612', 'Keeper Utilization Recovery — activate idle fleet', 'short'],
  ['goal-failed-task-resolution-20260612', 'Failed Task Resolution — surface & fix internal failures', 'short'],
  ['goal-orphan-prevention-20260612', 'Orphan Task Prevention — auto-detect & release stuck assignments', 'short'],
  ['goal-cascade-reliability', 'Cascade Reliability Improvements', 'short'],
  ['masc-transport-gc-storm', 'MASC Transport GC Storm 근본 해결', 'short'],
  ['goal-transport-gc-storm-fix', 'MASC Transport GC Storm 수정 — 점진적 지연 해소', 'short'],
  ['goal-1781235828597-bc8b', 'MASC/AGENT_CORE 병렬 처리 경계 취약점 식별 및 완화', 'short'],
  ['goal-keeper-sandbox-cwd-boundary-20260604', 'Keeper sandbox/CWD boundary decoupling', 'short'],
  ['goal-masc-improver', 'masc-improver keeper: voice, fleet, and infrastructure reliability', 'short'],
  ['goal-1779367005935-d99a', 'Baseline keeper liveness and runtime recovery', 'short'],
  ['cascade-bounded-wait-c1', 'Cascade Tier Bounded-Wait Admission (RFC-0153 Phase C.1)', 'short'],
  ['goal-telemetry-logging-keeper-team-20260517', 'Telemetry & Logging: Downstream retro-trace for operator clarity', 'short'],
  ['goal-stale-fact-lifecycle-001', 'Document stale-fact lifecycle architecture', 'short'],
  ['goal-sangsu-cascade-fsm', 'cascade_fsm.accept_on_exhaustion 및 관련 테스트 구현', 'short'],
  ['goal-003', 'Eliminate stale task-cache emissions across all write_backlog sites', 'short'],
  ['goal-agent-core-reasoning-control-library-20260614', 'AGENT_CORE Reasoning Control Library and MASC safe continuation integration', 'mid'],
  ['goal-agent-core-reasoning-dialect-registry-20260614', 'AGENT_CORE provider reasoning dialect registry', 'mid'],
  ['goal-agent-core-continuation-boundary-20260614', 'AGENT_CORE continuation boundary and pending input primitive', 'mid'],
  ['goal-masc-safe-continuation-20260614', 'MASC safe continuation integration for keeper/dashboard/Discord', 'mid'],
  ['goal-reasoning-control-verification-20260614', 'Reasoning control verification harness and rollout', 'mid'],
  ['goal-exec-policy-surface-unification-20260522', 'Unify execution policy surfaces under Exec_policy', 'mid'],
  ['memory-os-judgment-wiring', 'memory-os LLM judgment 배선 + 선행 4가드 (PR #21319 후속)', 'mid'],
  ['goal-1781689009140-f183', 'Shell IR approval gate: autonomous sandbox-conditional policy (RFC-0254)', 'mid'],
  ['goal-cascade-keeper-team-20260517', 'Cascade Keeper Team Operations', 'mid'],
  ['keeper-fleet-cascade-stabilization', 'Keeper Fleet Cascade Stabilization', 'mid'],
  ['sandbox-redesign', 'Sandbox Subsystem Redesign — 설정 SSOT + Backend Interface', 'mid'],
  ['goal-keeper-harness-evolution-20260530', 'Keeper self-improving harness evolution (6-axis)', 'long'],
  ['goal-1779367006576-dec8', '코드와 시스템의 빈틈을 찾아낸다. 테스트가 증명하지 않은 것은 동작하지 않는 것이다.', 'long'],
  ['goal-1781660490733-5c49', 'Memory OS: record well, not value — no score/decay/edges rebuilds (RFC-0251)', 'long'],
];
const KC_HORIZON = { short: '단기', mid: '중기', long: '장기' };

// 바인딩 가능한 런타임 카탈로그 — runtime.toml [runtime.assignments] 가 고를 수 있는 전체 목록.
// provider.model 형식. where: cloud|local · ctx: 최대 컴텍스트 · badges: 성격 태그.
const KC_RUNTIMES = [
  { id: 'ollama_cloud.deepseek-v4-flash', model: 'deepseek-v4-flash', where: 'cloud', ctx: '196k', badges: ['flash', 'multimodal'] },
  { id: 'ollama_cloud.deepseek-v4-pro', model: 'deepseek-v4-pro', where: 'cloud', ctx: '128k', badges: ['pro', 'reasoning'] },
  { id: 'deepseek.deepseek-v4-pro', model: 'deepseek-v4-pro', where: 'cloud', ctx: '128k', badges: ['pro', 'reasoning'] },
  { id: 'deepseek.deepseek-v4-flash', model: 'deepseek-v4-flash', where: 'cloud', ctx: '196k', badges: ['flash'] },
  { id: 'zhipu.glm-5-turbo', model: 'glm-5-turbo', where: 'cloud', ctx: '128k', badges: ['turbo', 'reasoning'] },
  { id: 'openrouter.claude-opus-4', model: 'claude-opus-4', where: 'cloud', ctx: '200k', badges: ['frontier', 'reasoning'] },
  { id: 'openrouter.gpt-5-mini', model: 'gpt-5-mini', where: 'cloud', ctx: '128k', badges: ['mini', 'fast'] },
  { id: 'ollama.gemma4-26b-a4b-qat', model: 'gemma4-26b-a4b-qat', where: 'local', ctx: '64k', badges: ['local', 'qat'] },
  { id: 'ollama.gemma4-9b', model: 'gemma4-9b', where: 'local', ctx: '32k', badges: ['local', 'fast'] },
  { id: 'ollama.qwen3-32b', model: 'qwen3-32b', where: 'local', ctx: '64k', badges: ['local'] },
  { id: 'lmstudio.mistral-large-3', model: 'mistral-large-3', where: 'local', ctx: '96k', badges: ['local'] },
];

// keeper lifecycle 훅 — 14 슬롯. registered=등록됨 · gate=게이트 필터.
const KC_HOOKS = [
  ['before_turn', 'keeper_hooks_oas', null, true],
  ['before_turn_params', 'keeper_run_tools', null, true],
  ['after_turn', 'keeper_hooks_oas', null, true],
  ['pre_tool_use', 'keeper_guards', 'timing · streak_gate · destructive_pattern · governance_approval', true],
  ['post_tool_use', 'keeper_hooks_oas', null, true],
  ['post_tool_use_failure', 'keeper_hooks_oas', null, true],
  ['on_stop', 'keeper_hooks_oas', null, true],
  ['on_idle', 'keeper_hooks_oas', null, true],
  ['on_idle_escalated', 'keeper_hooks_oas', null, true],
  ['on_error', 'keeper_hooks_oas', null, true],
  ['on_tool_error', 'keeper_hooks_oas', null, true],
  ['pre_compact', 'not_registered', null, false],
  ['post_compact', 'not_registered', null, false],
  ['on_context_compacted', 'not_registered', null, false],
];

// pre_tool_use 가드 — 이 keeper의 도구 호출이 통과하는 필터. 외부 효과(external effect)
// 호출은 Gate 로 라우팅된다 (Always Allow / LLM Auto Judge / HITL — data.jsx APPROVALS 와 연결).
// 명령·도구명 기반 authorization heuristic 은 소스에서 제거됨 — 실행 경계에는 객관적
// typed input · path jail · sandbox 불변식만 남는다.
const KC_GUARDS = [
  { id: 'timing', lbl: '타이밍', desc: '도구 호출 간 최소 간격 — 폭주 차단 (keeper-local pacing)' },
  { id: 'streak_gate', lbl: '스트릭 게이트', desc: '연속 실패·동일 호출 반복 차단' },
  { id: 'destructive_pattern', lbl: '경로·샌드박스 불변식', desc: '실행 경계의 typed input · path jail · sandbox 검증 (객관 불변식)' },
  { id: 'governance_approval', lbl: 'Gate 라우팅', desc: '외부 효과 요청을 Gate(HITL) 큐로 라우팅' },
];

// 이 keeper 가드가 최근 발동한 이력 — 승인 큐(APPROVALS)·감사 로그(APPROVAL_HISTORY)에서 파생.
//   action: escalated(승인 큐로 올림) · blocked(차단) · passed(통과) · warned(경고)
function kcfInterventions(k) {
  const kindGuard = { 'destructive-fs': 'destructive_pattern', 'tool-grant': 'governance_approval', 'spend': 'governance_approval', 'handoff': 'governance_approval', 'model-switch': 'governance_approval', 'restart': 'governance_approval' };
  const out = [];
  (window.APPROVALS || []).filter(a => a.keeper === k.id).forEach(a => {
    out.push({ at: `${Math.round(a.opened / 60)}분 전`, guard: kindGuard[a.kind] || 'governance_approval', action: 'escalated', note: a.title, ref: a.id });
  });
  (window.APPROVAL_HISTORY || []).filter(a => a.keeper === k.id).slice(0, 3).forEach(a => {
    out.push({ at: a.at, guard: kindGuard[a.kind] || 'governance_approval', action: a.decision === 'denied' ? 'blocked' : 'passed', note: a.reason, ref: a.id });
  });
  return out;
}

// keeper 한 명의 설정 기본값 — 기존 roster/grants/personas 에서 합성.
function keeperConfig(k) {
  const base = (window.PERSONAS && window.PERSONAS[k.id]) || (window.DEFAULT_PERSONA || { persona: '', instructions: '', traits: [] });
  const grant = (window.KEEPER_GRANTS && window.KEEPER_GRANTS[k.id]) || (window.DEFAULT_GRANT || { fs: 'worktree', git: false, net: false, tools: [] });
  const liveRt = k.runtime && k.runtime !== '—' ? k.runtime : 'ollama_cloud.deepseek-v4-flash';
  const slug = k.id;
  return {
    identity: {
      // ── editable avatar identity (slot color + sigil monogram + optional portrait) ──
      slot: k.slot, sigil: k.sigil,
      name: k.kr || k.id,
      avatarMode: k.portrait ? 'portrait' : 'sigil',
      portrait: k.portrait || null, customPortrait: null,
      cwd: k.cwd, sandbox: k.sandbox, repo: `masc-mcp · keeper/${slug}`, created: '4일 전', role: k.role || 'keeper',
      runtimeProfile: liveRt, registry: k.status === 'off' ? 'stopped' : 'registered',
      fiber: k.status === 'run' ? 'running' : k.status === 'pause' ? 'parked' : 'unknown',
      liveMetaPath: `~/.masc/keepers/${slug}.json`,
      manifestPath: `~/.masc/config/keepers/${slug}.toml`,
    },
    prompt: {
      objective: '매 사이클 시스템 상태를 읽고 개선점을 우선순위가 명확한 task/goal 큐로 발행한다. MASC 생태계가 끊임없이 자기 비판하고 진화하는 시스템이 되게 한다.',
      instructions: base.instructions || '',
      persona: base.persona || '',
      traits: base.traits || [],
      override: 'prompt.instructions',
      priority: 'live_meta',
    },
    runtime: {
      profile: liveRt, runtimeId: liveRt.replace('·', '_'),
      liveOverride: true, priority: 'live_meta',
      timeout: 90, turnBudget: 8, fallback: ['ollama_cloud.deepseek-v4-flash', 'deepseek.deepseek-v4-pro', 'ollama.gemma4-26b-a4b-qat'],
      activeRuntime: k.status === 'run' ? liveRt : '—',
    },
    policy: {
      verify: k.id === 'qa-king', candidate: 'none', profile: 'custom',
      // 제거됨(2026-08 소스): ratio/msg/token 게이트 · compaction 정책 오써링 · auto handoff 임계치.
      mentionTargets: '—',
      proactive: k.status === 'run', idleTrigger: 120, proCooldown: 300,
      paused: k.status === 'pause', autoBoot: false, keepAlive: false,
    },
    access: {
      fs: grant.fs, git: !!grant.git, net: !!grant.net, tools: [...grant.tools],
      sandbox: 'local', network: 'inherit',
      effectivePath: `.masc/playground/${slug}/`,
      denyCount: 0, destructiveTool: 'dynamic_guard',
    },
    goals: {
      // 처음 몇 개를 배정된 것으로 시드
      assigned: KC_GOALS.slice(0, k.tasks ? Math.min(3 + k.tasks, 7) : 2).map(g => g[0]),
      namespaces: 'none',
    },
    health: {
      verifyPass: k.status !== 'off', lastAttempt: 'completed · 1회 시도',
      lastVerifyEvent: 'Terminal Reason · 17시간 전', lastSignal: `최근 활동 ${k.last}`,
      runningFibers: 3, idleSec: 71311,
      scopeMsg: 'dashboard: 알아서',
    },
  };
}

Object.assign(window, { KC_GOALS, KC_HORIZON, KC_RUNTIMES, KC_HOOKS, KC_GUARDS, kcfInterventions, keeperConfig });
