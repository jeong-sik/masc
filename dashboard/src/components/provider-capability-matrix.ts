// ProviderCapabilityMatrix — Feature × Provider matrix, OAS wiring gaps,
// and anti-pattern registry. Static data from sec02/sec04/sec05 analysis
// with live provider overlay from /api/v1/providers.
//
// Sub-views (via FilterChips):
//   matrix      — 15 features × 13 providers
//   wiring      — 6 OAS wiring mismatches vs official API
//   anti-patterns — 32 anti-patterns (S/F/M/H categories) with risk ratings

import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { Card } from './common/card'
import { FilterChips } from './common/filter-chips'
import { StatusChip } from './common/status-chip'
import {
  fetchRuntimeProviders,
  type DashboardRuntimeProviderSnapshot,
} from '../api/dashboard'

// ── Sub-view types ────────────────────────────────────────────

type CapView = 'providers' | 'matrix' | 'wiring' | 'anti-patterns'

const CAP_VIEWS: Array<{ key: CapView; label: string }> = [
  { key: 'providers', label: 'OAS 프로바이더' },
  { key: 'matrix', label: '기능 매트릭스' },
  { key: 'wiring', label: 'OAS 배선 갭' },
  { key: 'anti-patterns', label: '안티패턴' },
]

// ── Static data: 15 features × 13 providers ───────────────────
// Source: sec04 Table 4.2.1 — External Feature Matrix
// Values: '●' native, '◐' partial, '○' none, '—' N/A

type FeatureSupport = '●' | '◐' | '○' | '—'

interface FeatureDef {
  id: string
  label: string
  providers: Record<string, FeatureSupport>
}

const FEATURES: FeatureDef[] = [
  {
    id: 'tool-calling',
    label: 'Native Tool Calling',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '●',
      qwen35: '●', mistral: '●', nemotron: '○', kimi: '●',
      ollama: '●', llamacpp: '○', glm: '●', gemini_cli: '○', codex_cli: '○',
    },
  },
  {
    id: 'parallel-tools',
    label: 'Parallel Tool Calls',
    providers: {
      openai: '●', claude: '●', gemini: '◐', deepseek: '●',
      qwen35: '●', mistral: '○', nemotron: '○', kimi: '◐',
      ollama: '○', llamacpp: '○', glm: '◐', gemini_cli: '○', codex_cli: '○',
    },
  },
  {
    id: 'tool-choice',
    label: 'tool_choice',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '●',
      qwen35: '●', mistral: '●', nemotron: '○', kimi: '●',
      ollama: '◐', llamacpp: '○', glm: '◐', gemini_cli: '○', codex_cli: '○',
    },
  },
  {
    id: 'structured-output',
    label: 'Structured Output',
    providers: {
      openai: '●', claude: '◐', gemini: '●', deepseek: '●',
      qwen35: '●', mistral: '●', nemotron: '○', kimi: '○',
      ollama: '◐', llamacpp: '○', glm: '◐', gemini_cli: '○', codex_cli: '○',
    },
  },
  {
    id: 'constrained-decoding',
    label: 'Constrained Decoding',
    providers: {
      openai: '○', claude: '○', gemini: '○', deepseek: '○',
      qwen35: '○', mistral: '○', nemotron: '○', kimi: '○',
      ollama: '●', llamacpp: '●', glm: '○', gemini_cli: '○', codex_cli: '○',
    },
  },
  {
    id: 'thinking',
    label: 'Thinking / Reasoning',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '●',
      qwen35: '●', mistral: '○', nemotron: '○', kimi: '●',
      ollama: '○', llamacpp: '○', glm: '●', gemini_cli: '●', codex_cli: '●',
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
      openai: '●', claude: '●', gemini: '●', deepseek: '◐',
      qwen35: '◐', mistral: '○', nemotron: '○', kimi: '◐',
      ollama: '○', llamacpp: '○', glm: '◐', gemini_cli: '○', codex_cli: '○',
    },
  },
  {
    id: 'prompt-caching',
    label: 'Prompt Caching',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '○',
      qwen35: '○', mistral: '●', nemotron: '○', kimi: '○',
      ollama: '○', llamacpp: '○', glm: '○', gemini_cli: '○', codex_cli: '○',
    },
  },
  {
    id: 'seed',
    label: 'seed (reproducible)',
    providers: {
      openai: '●', claude: '○', gemini: '●', deepseek: '○',
      qwen35: '○', mistral: '○', nemotron: '○', kimi: '○',
      ollama: '●', llamacpp: '●', glm: '○', gemini_cli: '○', codex_cli: '○',
    },
  },
  {
    id: 'multimodal',
    label: 'Multimodal',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '◐',
      qwen35: '●', mistral: '●', nemotron: '○', kimi: '●',
      ollama: '◐', llamacpp: '○', glm: '●', gemini_cli: '●', codex_cli: '○',
    },
  },
  {
    id: 'mcp',
    label: 'MCP Protocol',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '○',
      qwen35: '○', mistral: '○', nemotron: '○', kimi: '○',
      ollama: '○', llamacpp: '○', glm: '○', gemini_cli: '●', codex_cli: '●',
    },
  },
  {
    id: 'code-execution',
    label: 'Code Execution',
    providers: {
      openai: '●', claude: '○', gemini: '●', deepseek: '○',
      qwen35: '○', mistral: '○', nemotron: '○', kimi: '○',
      ollama: '○', llamacpp: '○', glm: '○', gemini_cli: '●', codex_cli: '●',
    },
  },
  {
    id: 'computer-use',
    label: 'Computer Use',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '○',
      qwen35: '○', mistral: '○', nemotron: '○', kimi: '○',
      ollama: '○', llamacpp: '○', glm: '○', gemini_cli: '○', codex_cli: '○',
    },
  },
  {
    id: 'max-context',
    label: 'Max Context ≥128K',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '●',
      qwen35: '●', mistral: '●', nemotron: '○', kimi: '●',
      ollama: '○', llamacpp: '○', glm: '●', gemini_cli: '●', codex_cli: '●',
    },
  },
]

const PROVIDER_IDS = [
  'openai', 'claude', 'gemini', 'deepseek',
  'qwen35', 'mistral', 'nemotron', 'kimi',
  'ollama', 'llamacpp', 'glm', 'gemini_cli', 'codex_cli',
] as const

const PROVIDER_LABELS: Record<string, string> = {
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

// ── Static data: OAS Provider Capabilities (sec02 Table 1) ──────
// Runtime provider kind definitions with capability flags and limits.
// 'usage' distinguishes Direct API (emit) from CLI wrappers (strip).

type UsageBehavior = 'emit' | 'strip'

interface OasProviderCap {
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

const OAS_PROVIDER_CAPS: OasProviderCap[] = [
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

const CAP_BOOLEAN_FIELDS: Array<{ key: keyof OasProviderCap; label: string }> = [
  { key: 'tools',     label: 'Tools' },
  { key: 'toolChoice', label: 'tool_choice' },
  { key: 'reasoning', label: 'Reasoning' },
  { key: 'vision',    label: 'Vision' },
  { key: 'topK',      label: 'top_k' },
]

// ── Static data: OAS Wiring Mismatches ────────────────────────
// Source: sec04 Table 4.2.3 — OAS Wiring vs Official API Support

interface WiringGap {
  id: string
  provider: string
  capability: string
  oasDeclares: string
  actualBehavior: string
  impact: 'high' | 'medium' | 'low'
}

const WIRING_GAPS: WiringGap[] = [
  {
    id: 'W01',
    provider: 'Gemini CLI',
    capability: 'tools',
    oasDeclares: 'tools=false',
    actualBehavior: 'MCP 지원하지만 OAS는 tool calling 비활성화로 라우팅',
    impact: 'high',
  },
  {
    id: 'W02',
    provider: 'Codex CLI',
    capability: 'tools vs MCP',
    oasDeclares: 'tools=false',
    actualBehavior: 'MCP 네이티브 지원, tool calling declaration 불일치',
    impact: 'high',
  },
  {
    id: 'W03',
    provider: 'GLM',
    capability: 'tool_choice',
    oasDeclares: 'none → auto 강제 변환',
    actualBehavior: 'auto만 지원, none/required 미지원. 강제 변환으로 의도 무시',
    impact: 'medium',
  },
  {
    id: 'W04',
    provider: 'GLM',
    capability: 'structured_output',
    oasDeclares: 'response_format 전송',
    actualBehavior: 'JSON mode만 지원, schema 강제 불가. 타입 안정성 낮음',
    impact: 'medium',
  },
  {
    id: 'W05',
    provider: 'Ollama',
    capability: 'tool_choice',
    oasDeclares: 'auto/none/required 전송',
    actualBehavior: '모델 의존적. 일부 모델은 tool_choice 무시',
    impact: 'low',
  },
  {
    id: 'W06',
    provider: 'Kimi CLI',
    capability: 'tool_choice',
    oasDeclares: 'Anthropic 호환 라우팅',
    actualBehavior: 'CLI 래퍼가 tool_choice를 처리하지 않고 무시',
    impact: 'medium',
  },
]

// ── Static data: Anti-patterns ────────────────────────────────
// Source: sec05 — 32 Anti-patterns with risk ratings

type AntiPatternCategory = 'silent-failure' | 'fake-fallback' | 'string-match' | 'hardcoding'
type RiskLevel = 'C' | 'H' | 'M' | 'L'

interface AntiPattern {
  id: string
  category: AntiPatternCategory
  description: string
  location: string
  risk: RiskLevel
}

const ANTI_PATTERNS: AntiPattern[] = [
  // S: Silent Failure (S01–S10)
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

  // F: Fake Fallback (F01–F04)
  { id: 'F01', category: 'fake-fallback', description: 'unknown provider → local 라우팅 — 의도치 않은 로컬 모델 사용', location: 'cascade_router.ml', risk: 'H' },
  { id: 'F02', category: 'fake-fallback', description: 'unknown model → $0 비용 — 비용 추적 우회', location: 'cost_estimator.ml', risk: 'M' },
  { id: 'F03', category: 'fake-fallback', description: 'missing limit → 무제한 — 예산 제어 무력화', location: 'budget_guard.ml', risk: 'H' },
  { id: 'F04', category: 'fake-fallback', description: 'parse 실패 → 빈 object — schema 검증 무시', location: 'response_parser.ml', risk: 'M' },

  // M: String Matching (M01–M06)
  { id: 'M01', category: 'string-match', description: 'prefix substring match로 provider 분류 — "deepseek-v4" → "deep" 매칭 위험', location: 'provider_classifier.ml', risk: 'H' },
  { id: 'M02', category: 'string-match', description: '"deepseek-v4" 문자열로 모델 패밀리 식별 — renaming 시 break', location: 'model_registry.ml', risk: 'H' },
  { id: 'M03', category: 'string-match', description: 'URL contains로 ollama 감지 — "ollama"가 path에 있으면 false positive', location: 'network_defaults.ml', risk: 'M' },
  { id: 'M04', category: 'string-match', description: '에러 메시지 문자열 파싱으로 rate-limit 감지 — provider 응답 변경 시 silent fail', location: 'error_classifier.ml', risk: 'H' },
  { id: 'M05', category: 'string-match', description: 'HTTP status code 대신 body 텍스트로 quota 판별', location: 'quota_detector.ml', risk: 'H' },
  { id: 'M06', category: 'string-match', description: '모델명에 "vision" 포함 여부로 multimodal 판별', location: 'capability_resolver.ml', risk: 'M' },

  // H: Hardcoding (H01–H12)
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

// ── Helper functions ──────────────────────────────────────────

function supportCellClass(v: FeatureSupport): string {
  switch (v) {
    case '●': return 'bg-[rgba(34,197,94,0.15)] text-[#22c55e]'
    case '◐': return 'bg-[rgba(234,179,8,0.15)] text-[#eab308]'
    case '○': return 'bg-[rgba(239,68,68,0.1)] text-[#ef4444]'
    case '—': return 'bg-[var(--white-4)] text-[var(--color-fg-muted)]'
  }
}

function riskTone(risk: RiskLevel): 'bad' | 'warn' | 'neutral' | 'info' {
  switch (risk) {
    case 'C': return 'bad'
    case 'H': return 'bad'
    case 'M': return 'warn'
    case 'L': return 'neutral'
  }
}

function riskLabel(risk: RiskLevel): string {
  switch (risk) {
    case 'C': return 'Critical'
    case 'H': return 'High'
    case 'M': return 'Medium'
    case 'L': return 'Low'
  }
}

function impactTone(impact: 'high' | 'medium' | 'low'): 'bad' | 'warn' | 'neutral' {
  switch (impact) {
    case 'high': return 'bad'
    case 'medium': return 'warn'
    case 'low': return 'neutral'
  }
}

function categoryLabel(cat: AntiPatternCategory): string {
  switch (cat) {
    case 'silent-failure': return 'Silent Failure'
    case 'fake-fallback': return 'Fake Fallback'
    case 'string-match': return 'String Match'
    case 'hardcoding': return 'Hardcoding'
  }
}

function categoryColor(cat: AntiPatternCategory): string {
  switch (cat) {
    case 'silent-failure': return 'bg-[rgba(239,68,68,0.12)] text-[#f87171] border-[rgba(239,68,68,0.25)]'
    case 'fake-fallback': return 'bg-[rgba(249,115,22,0.12)] text-[#fb923c] border-[rgba(249,115,22,0.25)]'
    case 'string-match': return 'bg-[rgba(234,179,8,0.12)] text-[#facc15] border-[rgba(234,179,8,0.25)]'
    case 'hardcoding': return 'bg-[rgba(99,102,241,0.12)] text-[#818cf8] border-[rgba(99,102,241,0.25)]'
  }
}

// Map runtime provider kind → matrix provider ID for overlay
function runtimeKindToMatrixId(kind: string | null | undefined): string | null {
  if (!kind) return null
  const lower = kind.toLowerCase()
  if (lower.includes('anthropic') || lower.includes('claude')) return 'claude'
  if (lower.includes('openai_compat') || lower.includes('openai')) return 'openai'
  if (lower.includes('gemini')) return 'gemini'
  if (lower.includes('glm')) return 'glm'
  if (lower.includes('ollama')) return 'ollama'
  if (lower.includes('kimi')) return 'kimi'
  if (lower.includes('dashscope') || lower.includes('qwen')) return 'qwen35'
  if (lower.includes('codex_cli')) return 'codex_cli'
  if (lower.includes('gemini_cli')) return 'gemini_cli'
  return null
}

// ── Live provider status overlay ──────────────────────────────

function liveStatusDot(
  providerId: string,
  liveProviders: DashboardRuntimeProviderSnapshot[],
): string | null {
  for (const p of liveProviders) {
    const matrixId = runtimeKindToMatrixId(p.kind)
    if (matrixId === providerId) {
      if (p.available) return 'available'
      if (p.status === 'error') return 'error'
      return 'unknown'
    }
  }
  return null
}

// ── Sub-components ────────────────────────────────────────────

function FeatureMatrix({ liveProviders }: { liveProviders: DashboardRuntimeProviderSnapshot[] }) {
  return html`
    <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
      <table class="w-full text-xs border-collapse">
        <thead>
          <tr class="bg-[var(--white-4)]">
            <th class="sticky left-0 z-10 bg-[var(--shell-rail-bg)] border-b border-r border-[var(--color-border-default)] px-2 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] min-w-[140px]">
              기능
            </th>
            ${PROVIDER_IDS.map(pid => {
              const dot = liveStatusDot(pid, liveProviders)
              const dotColor = dot === 'available'
                ? 'bg-[#22c55e]'
                : dot === 'error'
                  ? 'bg-[#ef4444]'
                  : dot ? 'bg-[var(--white-25)]' : ''
              return html`
                <th key=${pid} class="border-b border-[var(--color-border-default)] px-1.5 py-1.5 text-center font-medium text-[var(--color-fg-secondary)] min-w-[60px]">
                  <div class="flex flex-col items-center gap-0.5">
                    ${dotColor ? html`<span class="size-1.5 rounded-full ${dotColor}"></span>` : null}
                    <span>${PROVIDER_LABELS[pid] ?? pid}</span>
                  </div>
                </th>
              `
            })}
          </tr>
        </thead>
        <tbody>
          ${FEATURES.map((feat, i) => html`
            <tr key=${feat.id} class="${i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
              <td class="sticky left-0 z-10 ${i % 2 === 0 ? 'bg-[var(--shell-rail-bg)]' : 'bg-[var(--white-2)]'} border-r border-[var(--color-border-default)] px-2 py-1 font-medium text-[var(--color-fg-primary)]">
                ${feat.label}
              </td>
              ${PROVIDER_IDS.map(pid => {
                const v = feat.providers[pid] ?? '—'
                return html`
                  <td key=${pid} class="border-b border-[var(--color-border-default)] px-1 py-0.5 text-center">
                    <span class="inline-block w-full rounded px-1 py-0.5 text-[10px] font-mono font-bold ${supportCellClass(v)}">
                      ${v}
                    </span>
                  </td>
                `
              })}
            </tr>
          `)}
        </tbody>
      </table>
    </div>
  `
}

function WiringGaps() {
  return html`
    <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
      <table class="w-full text-xs border-collapse">
        <thead>
          <tr class="bg-[var(--white-4)]">
            <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">ID</th>
            <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">프로바이더</th>
            <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">기능</th>
            <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">OAS 선언</th>
            <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">실제 동작</th>
            <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">영향도</th>
          </tr>
        </thead>
        <tbody>
          ${WIRING_GAPS.map((gap, i) => html`
            <tr key=${gap.id} class="${i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
              <td class="border-b border-[var(--color-border-default)] px-3 py-2 font-mono text-[var(--color-fg-muted)]">${gap.id}</td>
              <td class="border-b border-[var(--color-border-default)] px-3 py-2 font-medium text-[var(--color-fg-primary)]">${gap.provider}</td>
              <td class="border-b border-[var(--color-border-default)] px-3 py-2 text-[var(--color-fg-secondary)]">${gap.capability}</td>
              <td class="border-b border-[var(--color-border-default)] px-3 py-2 font-mono text-[var(--color-fg-muted)]">${gap.oasDeclares}</td>
              <td class="border-b border-[var(--color-border-default)] px-3 py-2 text-[var(--color-fg-secondary)]">${gap.actualBehavior}</td>
              <td class="border-b border-[var(--color-border-default)] px-3 py-2">
                <${StatusChip} tone=${impactTone(gap.impact)}>${gap.impact.toUpperCase()}<//>
              </td>
            </tr>
          `)}
        </tbody>
      </table>
    </div>
  `
}

function AntiPatternList() {
  const categoryFilter = useSignal<AntiPatternCategory | 'all'>('all')

  const categories: AntiPatternCategory[] = ['silent-failure', 'fake-fallback', 'string-match', 'hardcoding']
  const filtered = categoryFilter.value === 'all'
    ? ANTI_PATTERNS
    : ANTI_PATTERNS.filter(ap => ap.category === categoryFilter.value)

  const riskCounts = { C: 0, H: 0, M: 0, L: 0 }
  for (const ap of ANTI_PATTERNS) riskCounts[ap.risk]++

  return html`
    <div class="flex flex-col gap-3">
      <div class="flex items-center gap-3 flex-wrap">
        <div class="flex gap-1">
          <button
            type="button"
            class="px-2 py-0.5 rounded text-[10px] font-mono border transition-colors ${
              categoryFilter.value === 'all'
                ? 'border-[var(--color-border-strong)] bg-[var(--white-8)] text-[var(--color-fg-primary)]'
                : 'border-[var(--color-border-default)] text-[var(--color-fg-muted)] hover:border-[var(--color-border-strong)]'
            }"
            onClick=${() => { categoryFilter.value = 'all' }}
          >전체 (${ANTI_PATTERNS.length})</button>
          ${categories.map(cat => html`
            <button
              key=${cat}
              type="button"
              class="px-2 py-0.5 rounded text-[10px] font-mono border transition-colors ${
                categoryFilter.value === cat
                  ? 'border-[var(--color-border-strong)] bg-[var(--white-8)] text-[var(--color-fg-primary)]'
                  : 'border-[var(--color-border-default)] text-[var(--color-fg-muted)] hover:border-[var(--color-border-strong)]'
              }"
              onClick=${() => { categoryFilter.value = cat }}
            >${categoryLabel(cat)} (${ANTI_PATTERNS.filter(ap => ap.category === cat).length})</button>
          `)}
        </div>
        <div class="flex gap-2 text-[10px] font-mono text-[var(--color-fg-muted)]">
          <span>C:<strong class="text-[#ef4444]">${riskCounts.C}</strong></span>
          <span>H:<strong class="text-[#ef4444]">${riskCounts.H}</strong></span>
          <span>M:<strong class="text-[#eab308]">${riskCounts.M}</strong></span>
          <span>L:<strong class="text-[var(--color-fg-muted)]">${riskCounts.L}</strong></span>
        </div>
      </div>

      <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
        <table class="w-full text-xs border-collapse">
          <thead>
            <tr class="bg-[var(--white-4)]">
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] w-[50px]">ID</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] w-[100px]">분류</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)]">설명</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] w-[160px]">위치</th>
              <th class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] w-[60px]">리스크</th>
            </tr>
          </thead>
          <tbody>
            ${filtered.map((ap, i) => html`
              <tr key=${ap.id} class="${i % 2 === 0 ? '' : 'bg-[var(--white-2)]'}">
                <td class="border-b border-[var(--color-border-default)] px-3 py-1.5 font-mono text-[var(--color-fg-muted)]">${ap.id}</td>
                <td class="border-b border-[var(--color-border-default)] px-3 py-1.5">
                  <span class="inline-block rounded border px-1.5 py-0.5 text-[10px] font-mono ${categoryColor(ap.category)}">
                    ${categoryLabel(ap.category)}
                  </span>
                </td>
                <td class="border-b border-[var(--color-border-default)] px-3 py-1.5 text-[var(--color-fg-secondary)]">${ap.description}</td>
                <td class="border-b border-[var(--color-border-default)] px-3 py-1.5 font-mono text-[10px] text-[var(--color-fg-muted)]">${ap.location}</td>
                <td class="border-b border-[var(--color-border-default)] px-3 py-1.5">
                  <${StatusChip} tone=${riskTone(ap.risk)}>${riskLabel(ap.risk)}<//>
                </td>
              </tr>
            `)}
          </tbody>
        </table>
      </div>
    </div>
  `
}

// ── OAS Provider Table (sec02 Table 1) ──────────────────────────

function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(n % 1_000_000 === 0 ? 0 : 2)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(n % 1_000 === 0 ? 0 : 1)}K`
  return String(n)
}

function OasProviderTable() {
  const isDirectApi = OAS_PROVIDER_CAPS.filter(p => p.usage === 'emit').length
  const isCliWrapper = OAS_PROVIDER_CAPS.filter(p => p.usage === 'strip').length

  return html`
    <div class="flex flex-col gap-3">
      <div class="flex items-center gap-3 text-[10px] font-mono text-[var(--color-fg-muted)]">
        <span class="flex items-center gap-1">
          <span class="inline-block size-2 rounded-full bg-[#22c55e]"></span>
          Direct API (${isDirectApi})
        </span>
        <span class="flex items-center gap-1">
          <span class="inline-block size-2 rounded-full bg-[#eab308]"></span>
          CLI Wrapper (${isCliWrapper})
        </span>
      </div>

      <div class="overflow-x-auto rounded border border-[var(--color-border-default)]">
        <table class="w-full text-xs border-collapse">
          <thead>
            <tr class="bg-[var(--white-4)]">
              <th class="border-b border-[var(--color-border-default)] px-2 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] sticky left-0 z-10 bg-[var(--white-4)] min-w-[100px]">Provider</th>
              <th class="border-b border-[var(--color-border-default)] px-2 py-1.5 text-left font-medium text-[var(--color-fg-secondary)] min-w-[90px]">Kind</th>
              <th class="border-b border-[var(--color-border-default)] px-2 py-1.5 text-right font-medium text-[var(--color-fg-secondary)] min-w-[70px]">Max Context</th>
              <th class="border-b border-[var(--color-border-default)] px-2 py-1.5 text-right font-medium text-[var(--color-fg-secondary)] min-w-[70px]">Max Output</th>
              ${CAP_BOOLEAN_FIELDS.map(f => html`
                <th key=${f.key} class="border-b border-[var(--color-border-default)] px-1.5 py-1.5 text-center font-medium text-[var(--color-fg-secondary)] min-w-[55px]">${f.label}</th>
              `)}
              <th class="border-b border-[var(--color-border-default)] px-2 py-1.5 text-center font-medium text-[var(--color-fg-secondary)] min-w-[50px]">Usage</th>
            </tr>
          </thead>
          <tbody>
            ${OAS_PROVIDER_CAPS.map((prov, i) => {
              const isCli = prov.usage === 'strip'
              const rowBg = isCli
                ? 'bg-[rgba(234,179,8,0.04)]'
                : i % 2 === 0 ? '' : 'bg-[var(--white-2)]'
              return html`
                <tr key=${prov.id} class="${rowBg}">
                  <td class="sticky left-0 z-10 ${rowBg || 'bg-[var(--shell-rail-bg)]'} border-r border-[var(--color-border-default)] px-2 py-1.5 font-medium text-[var(--color-fg-primary)]">
                    <div class="flex items-center gap-1.5">
                      <span class="size-1.5 rounded-full ${isCli ? 'bg-[#eab308]' : 'bg-[#22c55e]'}"></span>
                      ${prov.label}
                    </div>
                  </td>
                  <td class="border-r border-[var(--color-border-default)] px-2 py-1.5 font-mono text-[10px] text-[var(--color-fg-muted)]">${prov.kind}</td>
                  <td class="border-r border-[var(--color-border-default)] px-2 py-1.5 text-right font-mono text-[var(--color-fg-secondary)]">${formatTokens(prov.maxContext)}</td>
                  <td class="border-r border-[var(--color-border-default)] px-2 py-1.5 text-right font-mono text-[var(--color-fg-secondary)]">${formatTokens(prov.maxOutput)}</td>
                  ${CAP_BOOLEAN_FIELDS.map(f => {
                    const val = prov[f.key]
                    return html`
                      <td key=${String(f.key)} class="border-r border-[var(--color-border-default)] px-1 py-0.5 text-center">
                        <span class="inline-block w-full rounded px-1 py-0.5 text-[10px] font-mono font-bold ${
                          val
                            ? 'bg-[rgba(34,197,94,0.15)] text-[#22c55e]'
                            : 'bg-[rgba(239,68,68,0.1)] text-[#ef4444]'
                        }">
                          ${val ? 'O' : 'X'}
                        </span>
                      </td>
                    `
                  })}
                  <td class="px-2 py-0.5 text-center">
                    <span class="inline-block rounded px-1.5 py-0.5 text-[10px] font-mono ${
                      isCli
                        ? 'bg-[rgba(234,179,8,0.15)] text-[#eab308]'
                        : 'bg-[rgba(34,197,94,0.15)] text-[#22c55e]'
                    }">
                      ${prov.usage}
                    </span>
                  </td>
                </tr>
              `
            })}
          </tbody>
        </table>
      </div>
    </div>
  `
}

// ── Legend ─────────────────────────────────────────────────────

function MatrixLegend() {
  return html`
    <div class="flex items-center gap-4 text-[10px] font-mono text-[var(--color-fg-muted)] px-1">
      <span class="flex items-center gap-1"><span class="inline-block w-4 h-3 rounded bg-[rgba(34,197,94,0.15)] text-center text-[#22c55e]">●</span> 네이티브</span>
      <span class="flex items-center gap-1"><span class="inline-block w-4 h-3 rounded bg-[rgba(234,179,8,0.15)] text-center text-[#eab308]">◐</span> 부분 지원</span>
      <span class="flex items-center gap-1"><span class="inline-block w-4 h-3 rounded bg-[rgba(239,68,68,0.1)] text-center text-[#ef4444]">○</span> 미지원</span>
      <span class="flex items-center gap-1"><span class="inline-block size-1.5 rounded-full bg-[#22c55e]"></span> 런타임 활성</span>
      <span class="flex items-center gap-1"><span class="inline-block size-1.5 rounded-full bg-[#ef4444]"></span> 런타임 오류</span>
    </div>
  `
}

// ── Main component ─────────────────────────────────────────────

export function ProviderCapabilityMatrix() {
  const activeView = useSignal<CapView>('matrix')
  const liveProviders = useSignal<DashboardRuntimeProviderSnapshot[]>([])
  const updatedLabel = useSignal<string | null>(null)

  useEffect(() => {
    const ctrl = new AbortController()
    void fetchRuntimeProviders({ signal: ctrl.signal })
      .then(res => {
        liveProviders.value = res.providers
        updatedLabel.value = res.updated_at ?? null
      })
      .catch(err => {
        if (err instanceof DOMException && err.name === 'AbortError') return
        console.warn('[capability-matrix] provider fetch failed', err instanceof Error ? err.message : err)
      })
    return () => { ctrl.abort() }
  }, [])

  const updatedAt = updatedLabel.value

  return html`
    <div class="flex flex-col gap-4">
      <div class="flex items-center justify-between gap-3 flex-wrap">
        <${FilterChips}
          chips=${CAP_VIEWS}
          value=${activeView.value}
          onChange=${(v: CapView) => { activeView.value = v }}
        />
        ${updatedAt ? html`
          <span class="text-[10px] font-mono text-[var(--color-fg-muted)]">
            프로바이더 상태: ${updatedAt}
          </span>
        ` : null}
      </div>

      ${activeView.value === 'providers' ? html`
        <${Card}>
          <h3 class="text-sm font-semibold text-[var(--color-fg-primary)] mb-2">OAS Provider Capability 정의</h3>
          <p class="text-xs text-[var(--color-fg-muted)] mb-3">
            sec02 Table 1 — 12개 런타임 provider kind의 capability flag와 한계값.
            CLI wrapper 3종은 <code class="font-mono text-[10px] bg-[var(--white-4)] px-1 rounded">usage: strip</code>으로 토큰 카운트를 노출하지 않음.
          </p>
          <${OasProviderTable} />
        <//>
      ` : activeView.value === 'matrix' ? html`
        <div class="flex flex-col gap-2">
          <${MatrixLegend} />
          <${FeatureMatrix} liveProviders=${liveProviders.value} />
        </div>
      ` : activeView.value === 'wiring' ? html`
        <${Card}>
          <h3 class="text-sm font-semibold text-[var(--color-fg-primary)] mb-2">OAS 배선 vs 공식 API 지원</h3>
          <p class="text-xs text-[var(--color-fg-muted)] mb-3">
            OAS가 선언한 capability와 실제 프로바이더 API 동작 사이의 불일치.
            High 영향도 항목은 tool calling 비활성화로 이어져 OAS 라우팅 정확도에 직접 영향.
          </p>
          <${WiringGaps} />
        <//>
      ` : activeView.value === 'anti-patterns' ? html`
        <${Card}>
          <h3 class="text-sm font-semibold text-[var(--color-fg-primary)] mb-2">안티패턴 레지스트리</h3>
          <p class="text-xs text-[var(--color-fg-muted)] mb-3">
            sec05 분석에서 식별된 32개 안티패턴. Silent Failure가 운영 가시성에 가장 큰 위협.
          </p>
          <${AntiPatternList} />
        <//>
      ` : null}
    </div>
  `
}
