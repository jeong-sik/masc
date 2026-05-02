// Static data for Provider Capability Matrix.
// Sources: sec02 Table 1, sec04 Tables 4.2.1–4.2.3, sec05 anti-pattern analysis.

// ── Feature Matrix ──────────────────────────────────────────────
// 15 features × 13 providers. Source: sec04 Table 4.2.1.

export type FeatureSupport = '●' | '◐' | '○' | '—'

export interface FeatureDef {
  id: string
  label: string
  providers: Record<string, FeatureSupport>
}

// ● = native support, ◐ = partial/conditional, ○ = not supported, — = N/A

export const FEATURES: FeatureDef[] = [
  {
    id: 'tool-calling',
    label: 'Native Tool Calling',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '◐',
      qwen35: '●', mistral: '●', nemotron: '◐', kimi: '●',
      ollama: '◐', llamacpp: '●', glm: '●', gemini_cli: '◐', codex_cli: '◐',
    },
  },
  {
    id: 'parallel-tools',
    label: 'Parallel Tool Calls',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '●',
      qwen35: '●', mistral: '●', nemotron: '●', kimi: '●',
      ollama: '●', llamacpp: '●', glm: '●', gemini_cli: '●', codex_cli: '○',
    },
  },
  {
    id: 'tool-choice',
    label: 'tool_choice',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '◐',
      qwen35: '●', mistral: '●', nemotron: '◐', kimi: '●',
      ollama: '◐', llamacpp: '●', glm: '◐', gemini_cli: '◐', codex_cli: '○',
    },
  },
  {
    id: 'structured-output',
    label: 'Structured Output',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '◐',
      qwen35: '●', mistral: '●', nemotron: '●', kimi: '●',
      ollama: '◐', llamacpp: '◐', glm: '◐', gemini_cli: '◐', codex_cli: '◐',
    },
  },
  {
    id: 'constrained-decoding',
    label: 'Constrained Decoding',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '◐',
      qwen35: '○', mistral: '○', nemotron: '○', kimi: '○',
      ollama: '○', llamacpp: '○', glm: '○', gemini_cli: '○', codex_cli: '◐',
    },
  },
  {
    id: 'thinking',
    label: 'Thinking / Reasoning',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '●',
      qwen35: '●', mistral: '◐', nemotron: '◐', kimi: '◐',
      ollama: '◐', llamacpp: '◐', glm: '●', gemini_cli: '○', codex_cli: '●',
    },
  },
  {
    id: 'interleaved-thinking',
    label: 'Interleaved Thinking',
    providers: {
      openai: '○', claude: '●', gemini: '○', deepseek: '○',
      qwen35: '○', mistral: '○', nemotron: '○', kimi: '○',
      ollama: '○', llamacpp: '○', glm: '○', gemini_cli: '○', codex_cli: '○',
    },
  },
  {
    id: 'streaming-tools',
    label: 'Streaming Tool Calls',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '●',
      qwen35: '●', mistral: '●', nemotron: '●', kimi: '●',
      ollama: '●', llamacpp: '●', glm: '●', gemini_cli: '●', codex_cli: '●',
    },
  },
  {
    id: 'prompt-caching',
    label: 'Prompt Caching',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '○',
      qwen35: '○', mistral: '○', nemotron: '○', kimi: '●',
      ollama: '◐', llamacpp: '●', glm: '○', gemini_cli: '○', codex_cli: '●',
    },
  },
  {
    id: 'seed',
    label: 'seed (reproducible)',
    providers: {
      openai: '●', claude: '○', gemini: '●', deepseek: '○',
      qwen35: '○', mistral: '●', nemotron: '○', kimi: '○',
      ollama: '●', llamacpp: '●', glm: '○', gemini_cli: '○', codex_cli: '○',
    },
  },
  {
    id: 'multimodal',
    label: 'Multimodal',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '◐',
      qwen35: '●', mistral: '●', nemotron: '●', kimi: '●',
      ollama: '◐', llamacpp: '◐', glm: '●', gemini_cli: '◐', codex_cli: '◐',
    },
  },
  {
    id: 'mcp',
    label: 'MCP Protocol',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '○',
      qwen35: '○', mistral: '○', nemotron: '○', kimi: '●',
      ollama: '○', llamacpp: '○', glm: '○', gemini_cli: '●', codex_cli: '●',
    },
  },
  {
    id: 'code-execution',
    label: 'Code Execution',
    providers: {
      openai: '○', claude: '●', gemini: '○', deepseek: '○',
      qwen35: '○', mistral: '○', nemotron: '●', kimi: '●',
      ollama: '○', llamacpp: '○', glm: '○', gemini_cli: '○', codex_cli: '●',
    },
  },
  {
    id: 'computer-use',
    label: 'Computer Use',
    providers: {
      openai: '○', claude: '●', gemini: '○', deepseek: '○',
      qwen35: '○', mistral: '○', nemotron: '○', kimi: '○',
      ollama: '○', llamacpp: '○', glm: '○', gemini_cli: '○', codex_cli: '○',
    },
  },
  {
    id: 'max-context',
    label: 'Max Context ≥128K',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '●',
      qwen35: '●', mistral: '●', nemotron: '●', kimi: '●',
      ollama: '◐', llamacpp: '◐', glm: '●', gemini_cli: '●', codex_cli: '●',
    },
  },
]

export const PROVIDER_IDS = [
  'openai', 'claude', 'gemini', 'deepseek',
  'qwen35', 'mistral', 'nemotron', 'kimi',
  'ollama', 'llamacpp', 'glm', 'gemini_cli', 'codex_cli',
] as const

export const PROVIDER_LABELS: Record<string, string> = {
  openai: 'OpenAI',
  claude: 'Claude',
  gemini: 'Gemini',
  deepseek: 'DeepSeek',
  qwen35: 'Qwen 3.5',
  mistral: 'Mistral',
  nemotron: 'Nemotron',
  kimi: 'Kimi',
  ollama: 'Ollama',
  llamacpp: 'llama.cpp',
  glm: 'GLM',
  gemini_cli: 'Gemini CLI',
  codex_cli: 'Codex CLI',
}

// Cascade tier in default OAS routing order (1 = primary).
export const PROVIDER_CASCADE_TIER: Record<string, number> = {
  anthropic: 1, openai: 2, moonshot: 3, google: 4,
  deepseek: 5, xai: 6, ollama: 7,
}

export const PROVIDER_KIND: Record<string, 'direct' | 'cli'> = {
  openai: 'direct', claude: 'direct', gemini: 'direct', deepseek: 'direct',
  qwen35: 'direct', mistral: 'direct', nemotron: 'direct', kimi: 'direct',
  ollama: 'direct', llamacpp: 'direct', glm: 'direct',
  gemini_cli: 'cli', codex_cli: 'cli',
}

export function computeMatrixSummary() {
  let native = 0, partial = 0, unsupported = 0, total = 0
  for (const feat of FEATURES) {
    for (const pid of PROVIDER_IDS) {
      const v = feat.providers[pid]
      if (v === '●') native++
      else if (v === '◐') partial++
      else if (v === '○') unsupported++
      total++
    }
  }
  return { native, partial, unsupported, total }
}

// ── BFCL Benchmarks ─────────────────────────────────────────────
// Source: sec04 Table 4.2.2

export interface BfclEntry {
  rank: number
  model: string
  bfclV3: string
  bfclV4: string
  feature: string
  license: string
}

export const BFCL_RANKINGS: BfclEntry[] = [
  { rank: 1,  model: 'GLM-4.5 (FC)',           bfclV3: '70.85%', bfclV4: '—',       feature: '복잡한 스키마 강점, Zhipu AI',           license: '상업적' },
  { rank: 2,  model: 'Claude Opus 4.1',         bfclV3: '70.36%', bfclV4: '—',       feature: 'Anthropic 최상위, Interleaved Thinking', license: '상업적' },
  { rank: 3,  model: 'Claude Sonnet 4',         bfclV3: '70.29%', bfclV4: '—',       feature: '성능/비용 효율 균형',                    license: '상업적' },
  { rank: 4,  model: 'Qwen3.5-397B-A17B',       bfclV3: '—',      bfclV4: '72.9%',   feature: 'BFCL V4 1위, 397B MoE 오픈웨이트',      license: '오픈웨이트' },
  { rank: 5,  model: 'GPT-5',                   bfclV3: '59.22%', bfclV4: '—',       feature: 'MCPMark 52.6% 선두 (BFCL≠MCPMark)',      license: '상업적' },
  { rank: 6,  model: 'Claude Haiku 4.5',        bfclV3: '80.6%',  bfclV4: '—',       feature: '소형 모델 최고 효율 (Inspect 벤치마크)', license: '상업적' },
  { rank: 7,  model: 'Qwen 3-Coder',            bfclV3: '경쟁력', bfclV4: '—',       feature: 'MCPMark $36.46/런 최저비용',             license: '오픈웨이트' },
  { rank: 8,  model: 'DeepSeek V3.1',           bfclV3: '개선됨', bfclV4: '—',       feature: 'Strict Function Calling (Beta)',         license: '오픈웨이트' },
  { rank: 9,  model: 'Gemma 4 27B/31B',         bfclV3: '76.9%',  bfclV4: '—',       feature: 'Apache 2.0 멀티모달 오픈웨이트',         license: 'Apache 2.0' },
  { rank: 10, model: 'Kimi K2.6',               bfclV3: '—',      bfclV4: '경쟁력',  feature: 'SWE-Bench Pro 58.6%, 256K 컨텍스트',    license: 'Modified MIT' },
]

// ── OAS Provider Capabilities (sec02 Table 1) ──────────────────

export type UsageBehavior = 'emit' | 'strip'

export interface OasProviderCap {
  id: string
  label: string
  kind: string
  maxContext: number
  maxOutput: number
  tools: boolean
  toolChoice: boolean
  reasoning: boolean
  vision: boolean
  topK: boolean
  usage: UsageBehavior
}

export const OAS_PROVIDER_CAPS: OasProviderCap[] = [
  { id: 'anthropic',      label: 'Anthropic',      kind: 'Anthropic',      maxContext: 200_000,  maxOutput: 8_192,  tools: true,  toolChoice: true,  reasoning: true,  vision: true,  topK: true,  usage: 'emit' },
  { id: 'kimi',           label: 'Kimi',           kind: 'Kimi',           maxContext: 262_144,  maxOutput: 32_768, tools: true,  toolChoice: true,  reasoning: true,  vision: false, topK: false, usage: 'emit' },
  { id: 'openai-chat',    label: 'OpenAI Chat',    kind: 'OpenAI_compat',  maxContext: 128_000,  maxOutput: 16_384, tools: true,  toolChoice: true,  reasoning: false, vision: true,  topK: false, usage: 'emit' },
  { id: 'openai-ext',     label: 'OpenAI Ext',     kind: 'OpenAI_compat',  maxContext: 128_000,  maxOutput: 16_384, tools: true,  toolChoice: true,  reasoning: true,  vision: true,  topK: true,  usage: 'emit' },
  { id: 'ollama',         label: 'Ollama',         kind: 'Ollama',         maxContext: 128_000,  maxOutput: 16_384, tools: true,  toolChoice: false, reasoning: true,  vision: true,  topK: true,  usage: 'emit' },
  { id: 'dashscope',      label: 'DashScope',      kind: 'DashScope',      maxContext: 128_000,  maxOutput: 16_384, tools: true,  toolChoice: true,  reasoning: true,  vision: true,  topK: true,  usage: 'emit' },
  { id: 'glm',            label: 'GLM',            kind: 'GLM',            maxContext: 200_000,  maxOutput: 40_960, tools: true,  toolChoice: false, reasoning: true,  vision: false, topK: false, usage: 'emit' },
  { id: 'gemini',         label: 'Gemini',         kind: 'Gemini',         maxContext: 1_000_000, maxOutput: 65_000, tools: true,  toolChoice: true,  reasoning: true,  vision: true,  topK: true,  usage: 'emit' },
  { id: 'claude-code',    label: 'Claude Code',    kind: 'Claude_code',    maxContext: 1_000_000, maxOutput: 64_000, tools: true,  toolChoice: true,  reasoning: true,  vision: true,  topK: true,  usage: 'emit' },
  { id: 'gemini-cli',     label: 'Gemini CLI',     kind: 'Gemini_cli',     maxContext: 1_000_000, maxOutput: 65_000, tools: false, toolChoice: false, reasoning: false, vision: false, topK: false, usage: 'strip' },
  { id: 'kimi-cli',       label: 'Kimi CLI',       kind: 'Kimi_cli',       maxContext: 262_144,  maxOutput: 32_768, tools: true,  toolChoice: false, reasoning: true,  vision: false, topK: false, usage: 'strip' },
  { id: 'codex-cli',      label: 'Codex CLI',      kind: 'Codex_cli',      maxContext: 1_050_000, maxOutput: 32_000, tools: false, toolChoice: false, reasoning: false, vision: false, topK: false, usage: 'strip' },
]

export const CAP_BOOLEAN_FIELDS: Array<{ key: keyof OasProviderCap; label: string }> = [
  { key: 'tools',     label: 'Tools' },
  { key: 'toolChoice', label: 'tool_choice' },
  { key: 'reasoning', label: 'Reasoning' },
  { key: 'vision',    label: 'Vision' },
  { key: 'topK',      label: 'top_k' },
]

// ── Wiring Gaps ─────────────────────────────────────────────────
// Source: sec04 Table 4.2.3

export interface WiringGap {
  id: string
  provider: string
  capability: string
  oasDeclares: string
  actualBehavior: string
  impact: 'high' | 'medium' | 'low' | 'correct'
}

export const WIRING_GAPS: WiringGap[] = [
  { id: 'W01', provider: 'Gemini CLI', capability: 'tools', oasDeclares: 'supports_tools=false', actualBehavior: '빌트인 도구 + MCP + cross-tool context 지원, OAS가 원천 차단', impact: 'high' },
  { id: 'W02', provider: 'Codex CLI', capability: 'tools vs MCP', oasDeclares: 'supports_tools=false', actualBehavior: 'inline tool calling은 없으나 runtime_mcp_tools=true로 MCP 네이티브 지원', impact: 'high' },
  { id: 'W03', provider: 'GLM', capability: 'tool_choice', oasDeclares: 'supports_tool_choice=false', actualBehavior: 'auto만 지원. Any/Tool/None은 Auto로 coerce → 사용자 의도 무시 (Fake Fallback)', impact: 'medium' },
  { id: 'W04', provider: 'GLM', capability: 'structured_output', oasDeclares: 'supports_structured_output=false', actualBehavior: 'JSON Schema 지정 가능하나 JSON Mode에 가까움, Constrained Decoding 불가', impact: 'low' },
  { id: 'W05', provider: 'Ollama', capability: 'tool_choice', oasDeclares: 'supports_tool_choice=false', actualBehavior: '모델 의존적. Qwen3.5+Jinja에서는 tool_choice 정상 작동, 일반 모델은 Auto만', impact: 'medium' },
  { id: 'W06', provider: 'Kimi CLI', capability: 'tool_choice', oasDeclares: 'supports_tool_choice=false', actualBehavior: 'Kimi API는 auto/forced/none 모두 지원. CLI --print 모드에서 req.tools 무시', impact: 'medium' },
  { id: 'W07', provider: 'Kimi CLI', capability: 'usage tokens', oasDeclares: 'emits_usage_tokens=false (strip)', actualBehavior: 'CLI subprocess에서 usage 정보 미포함, 정확한 선언', impact: 'correct' },
  { id: 'W08', provider: 'Gemini CLI', capability: 'usage tokens', oasDeclares: 'emits_usage_tokens=false (strip)', actualBehavior: 'CLI subprocess 특성상 usage 불안정, 정확한 선언', impact: 'correct' },
  { id: 'W09', provider: 'Codex CLI', capability: 'usage tokens', oasDeclares: 'emits_usage_tokens=false (strip)', actualBehavior: 'JSONL envelope에서 usage 미제공, 정확한 선언', impact: 'correct' },
  { id: 'W10', provider: 'Anthropic Claude', capability: 'tools', oasDeclares: 'supports_tools=true', actualBehavior: 'tool_use/tool_result 블록 구조, 공식 문서와 일치', impact: 'correct' },
  { id: 'W11', provider: 'Anthropic Claude', capability: 'extended thinking', oasDeclares: 'supports_extended_thinking=true', actualBehavior: 'budget_tokens + Interleaved Thinking (Claude 4+), 정확한 선언', impact: 'correct' },
  { id: 'W12', provider: 'Ollama', capability: 'is_ollama flag', oasDeclares: 'is_ollama=true', actualBehavior: 'tool_calls를 raw JSON 객체로 직렬화, 정확한 선언', impact: 'correct' },
]

// ── Anti-patterns ───────────────────────────────────────────────
// Source: sec05 — 32 Anti-patterns with risk ratings

export type AntiPatternCategory = 'silent-failure' | 'fake-fallback' | 'string-match' | 'hardcoding'
export type RiskLevel = 'C' | 'H' | 'M' | 'L'

export interface AntiPattern {
  id: string
  category: AntiPatternCategory
  description: string
  location: string
  risk: RiskLevel
}

export const ANTI_PATTERNS: AntiPattern[] = [
  { id: 'S01', category: 'silent-failure', description: 'Error _ → None이 모든 예외를 삼킴', location: 'cascade_ollama_probe.ml', risk: 'M' },
  { id: 'S02', category: 'silent-failure', description: 'Yojson parse exception → None', location: 'cascade_ollama_probe.ml', risk: 'M' },
  { id: 'S03', category: 'silent-failure', description: 'chat_template_kwargs 무시 — Ollama 커스텀 설정 미전달', location: 'capabilities.ml', risk: 'H' },
  { id: 'S04', category: 'silent-failure', description: '401/403 응답 body 미검사 — auth 만료를 network error로 오분류', location: 'provider_http.ml', risk: 'M' },
  { id: 'S05', category: 'silent-failure', description: 'empty response → 빈 list 반환, caller가 실패로 감지 못함', location: 'turn_executor.ml', risk: 'M' },
  { id: 'S06', category: 'silent-failure', description: 'timeout 시 부분 결과 폐기 후 None', location: 'cascade_runner.ml', risk: 'M' },
  { id: 'S07', category: 'silent-failure', description: 'tool_result 없는 tool_use → 다음 turn에서 LLM이 hallucination', location: 'content_block.ml', risk: 'H' },
  { id: 'S08', category: 'silent-failure', description: 'max_tokens 미지정 시 4096 fallback — 긴 응답 잘림', location: 'backend_*.ml', risk: 'H' },
  { id: 'S09', category: 'silent-failure', description: 'usage 필드 누락 시 토큰 계산 스킵 — 비용 추적 불가', location: 'usage_tracker.ml', risk: 'M' },
  { id: 'S10', category: 'silent-failure', description: 'streaming mid-turn disconnect → 부분 상태로 재시도', location: 'stream_adapter.ml', risk: 'M' },
  { id: 'F01', category: 'fake-fallback', description: 'unknown provider → local 라우팅 — 의도치 않은 로컬 모델 사용', location: 'cascade_router.ml', risk: 'H' },
  { id: 'F02', category: 'fake-fallback', description: 'unknown model → $0 비용 — 비용 추적 우회', location: 'cost_estimator.ml', risk: 'M' },
  { id: 'F03', category: 'fake-fallback', description: 'missing limit → 무제한 — 예산 제어 무력화', location: 'budget_guard.ml', risk: 'H' },
  { id: 'F04', category: 'fake-fallback', description: 'parse 실패 → 빈 object — schema 검증 무시', location: 'response_parser.ml', risk: 'M' },
  { id: 'M01', category: 'string-match', description: 'prefix substring match로 provider 분류 — "deepseek-v4" → "deep" 매칭 위험', location: 'provider_classifier.ml', risk: 'H' },
  { id: 'M02', category: 'string-match', description: '"deepseek-v4" 문자열로 모델 패밀리 식별 — renaming 시 break', location: 'model_registry.ml', risk: 'H' },
  { id: 'M03', category: 'string-match', description: 'URL contains로 ollama 감지 — "ollama"가 path에 있으면 false positive', location: 'network_defaults.ml', risk: 'M' },
  { id: 'M04', category: 'string-match', description: '에러 메시지 문자열 파싱으로 rate-limit 감지 — provider 응답 변경 시 silent fail', location: 'error_classifier.ml', risk: 'H' },
  { id: 'M05', category: 'string-match', description: 'HTTP status code 대신 body 텍스트로 quota 판별', location: 'quota_detector.ml', risk: 'H' },
  { id: 'M06', category: 'string-match', description: '모델명에 "vision" 포함 여부로 multimodal 판별', location: 'capability_resolver.ml', risk: 'M' },
  { id: 'H01', category: 'hardcoding', description: '기본 포트 11434가 6파일에 하드코딩', location: 'config/*.ml', risk: 'M' },
  { id: 'H02', category: 'hardcoding', description: 'timeout 30s가 4파일에 리터럴 — 설정 불가', location: 'cascade/*.ml', risk: 'M' },
  { id: 'H03', category: 'hardcoding', description: 'max_tokens 4096 기본값이 3백엔드에 산재', location: 'backend_*.ml', risk: 'M' },
  { id: 'H04', category: 'hardcoding', description: 'API base URL이 테스트에 하드코딩 — 환경 변수 무시', location: 'test/*.ml', risk: 'L' },
  { id: 'H05', category: 'hardcoding', description: 'keeper heartbeat 간격 5s가 상수 아닌 리터럴', location: 'keeper_loop.ml', risk: 'L' },
  { id: 'H06', category: 'hardcoding', description: 'retry 횟수 3이 call site마다 하드코딩', location: 'retry_*.ml', risk: 'M' },
  { id: 'H07', category: 'hardcoding', description: 'model ID 문자열이 match arm에 직접 기입', location: 'routing/*.ml', risk: 'M' },
  { id: 'H08', category: 'hardcoding', description: '에러 메시지 template이 코드 내에 인라인', location: 'error_*.ml', risk: 'L' },
  { id: 'H09', category: 'hardcoding', description: 'SSE 재연결 간격 1s 리터럴', location: 'sse_client.ml', risk: 'L' },
  { id: 'H10', category: 'hardcoding', description: 'Ollama keepalive 5m이 2파일에 중복 정의', location: 'ollama_*.ml', risk: 'M' },
  { id: 'H11', category: 'hardcoding', description: 'context window size가 모델별로 하드코딩 — 신규 모델 추가 시 수동 갱신', location: 'model_caps.ml', risk: 'H' },
  { id: 'H12', category: 'hardcoding', description: 'BFCL score threshold가 상수 아닌 리터럴', location: 'model_selector.ml', risk: 'L' },
]

// ── Shared helpers ──────────────────────────────────────────────

export function supportCellClass(v: FeatureSupport): string {
  switch (v) {
    case '●': return 'bg-[var(--ok-10)] text-[var(--color-status-ok)]'
    case '◐': return 'bg-[var(--warn-10)] text-[var(--color-status-warn)]'
    case '○': return 'bg-[var(--bad-10)] text-[var(--bad-light)]'
    case '—': return 'bg-[var(--white-4)] text-[var(--color-fg-muted)]'
  }
}

export function riskTone(risk: RiskLevel): 'bad' | 'warn' | 'neutral' | 'info' {
  switch (risk) {
    case 'C': return 'bad'
    case 'H': return 'bad'
    case 'M': return 'warn'
    case 'L': return 'neutral'
  }
}

export function riskLabel(risk: RiskLevel): string {
  switch (risk) {
    case 'C': return 'Critical'
    case 'H': return 'High'
    case 'M': return 'Medium'
    case 'L': return 'Low'
  }
}

export function impactTone(impact: 'high' | 'medium' | 'low' | 'correct'): 'bad' | 'warn' | 'neutral' | 'info' {
  switch (impact) {
    case 'high': return 'bad'
    case 'medium': return 'warn'
    case 'low': return 'neutral'
    case 'correct': return 'info'
  }
}

export function categoryLabel(cat: AntiPatternCategory): string {
  switch (cat) {
    case 'silent-failure': return 'Silent Failure'
    case 'fake-fallback': return 'Fake Fallback'
    case 'string-match': return 'String Match'
    case 'hardcoding': return 'Hardcoding'
  }
}

export function categoryColor(cat: AntiPatternCategory): string {
  switch (cat) {
    case 'silent-failure': return 'bg-[var(--bad-10)] text-[var(--bad-light)] border-[var(--bad-20)]'
    case 'fake-fallback': return 'bg-[var(--warn-10)] text-[var(--warn-bright)] border-[var(--warn-20)]'
    case 'string-match': return 'bg-[var(--warn-10)] text-[var(--color-status-warn)] border-[var(--warn-20)]'
    case 'hardcoding': return 'bg-[var(--white-4)] text-[var(--color-status-info)] border-[var(--color-border-default)]'
  }
}

function normalizeRuntimeKey(value: string | null | undefined): string | null {
  const normalized = value?.trim().toLowerCase().replace(/[\s-]+/g, '_')
  return normalized === '' ? null : normalized ?? null
}

const PROVIDER_TO_MATRIX_ID: Record<string, string> = {
  anthropic: 'claude',
  claude: 'claude',
  claude_code: 'claude',
  codex: 'codex_cli',
  codex_api: 'openai',
  codex_cli: 'codex_cli',
  dashscope: 'qwen35',
  gemini: 'gemini_cli',
  gemini_api: 'gemini',
  gemini_cli: 'gemini_cli',
  glm: 'glm',
  glm_api: 'glm',
  kimi: 'kimi',
  kimi_api: 'kimi',
  kimi_cli: 'kimi',
  llama: 'llamacpp',
  llama_cpp: 'llamacpp',
  llamacpp: 'llamacpp',
  ollama: 'ollama',
  openai: 'openai',
  openai_chat: 'openai',
  openai_compat: 'openai',
  openai_ext: 'openai',
  qwen: 'qwen35',
  qwen35: 'qwen35',
  zai: 'glm',
  zhipu: 'glm',
}

const RUNTIME_KIND_TO_MATRIX_ID: Record<string, string> = {
  ...PROVIDER_TO_MATRIX_ID,
  gemini: 'gemini',
}

function inferMatrixId(key: string): string | null {
  if (key.includes('codex_api')) return 'openai'
  if (key.includes('codex_cli') || key.includes('codex')) return 'codex_cli'
  if (key.includes('gemini_api')) return 'gemini'
  if (key.includes('gemini_cli')) return 'gemini_cli'
  if (key.includes('gemini')) return 'gemini'
  if (key.includes('anthropic') || key.includes('claude')) return 'claude'
  if (key.includes('openai_compat') || key.includes('openai')) return 'openai'
  if (key.includes('glm') || key.includes('zai') || key.includes('zhipu')) return 'glm'
  if (key.includes('ollama')) return 'ollama'
  if (key.includes('kimi')) return 'kimi'
  if (key.includes('llama_cpp') || key.includes('llamacpp') || key === 'llama') return 'llamacpp'
  if (key.includes('dashscope') || key.includes('qwen')) return 'qwen35'
  return null
}

export function runtimeProviderToMatrixId(
  provider: string | null | undefined,
  runtimeKind?: string | null,
): string | null {
  const providerKey = normalizeRuntimeKey(provider)
  if (providerKey !== null) {
    const exact = PROVIDER_TO_MATRIX_ID[providerKey]
    if (exact !== undefined) return exact
    const inferred = inferMatrixId(providerKey)
    if (inferred !== null) return inferred
  }

  const kindKey = normalizeRuntimeKey(runtimeKind)
  if (kindKey !== null) {
    const exact = RUNTIME_KIND_TO_MATRIX_ID[kindKey]
    if (exact !== undefined) return exact
    return inferMatrixId(kindKey)
  }

  return null
}

export function runtimeKindToMatrixId(kind: string | null | undefined): string | null {
  return runtimeProviderToMatrixId(null, kind)
}
