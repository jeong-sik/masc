// Static data for Provider Capability Matrix.
// Sources: sec02 Table 1, sec04 Tables 4.2.1–4.2.3, sec05 anti-pattern analysis.

// ── Feature Matrix ──────────────────────────────────────────────
// 15 features × 13 providers. Source: sec04 Table 4.2.1.

export type FeatureSupport = '●' | '◐' | '○' | '—'

export type CategoryLevel = 'high' | 'mid' | 'low'

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
      openai: '●', claude: '●', gemini: '●', deepseek: '●',
      qwen36: '●', mistral: '●', nemotron: '◐', kimi: '●',
      ollama: '◐', llamacpp: '●', glm: '●', gemini_cli: '●', codex_cli: '◐',
    },
  },
  {
    id: 'parallel-tools',
    label: 'Parallel Tool Calls',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '●',
      qwen36: '●', mistral: '●', nemotron: '●', kimi: '●',
      ollama: '●', llamacpp: '●', glm: '●', gemini_cli: '●', codex_cli: '○',
    },
  },
  {
    id: 'tool-choice',
    label: 'tool_choice',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '◐',
      qwen36: '●', mistral: '●', nemotron: '◐', kimi: '●',
      ollama: '◐', llamacpp: '●', glm: '◐', gemini_cli: '◐', codex_cli: '○',
    },
  },
  {
    id: 'structured-output',
    label: 'Structured Output',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '◐',
      qwen36: '●', mistral: '●', nemotron: '●', kimi: '●',
      ollama: '◐', llamacpp: '◐', glm: '◐', gemini_cli: '◐', codex_cli: '◐',
    },
  },
  {
    id: 'constrained-decoding',
    label: 'Constrained Decoding',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '◐',
      qwen36: '○', mistral: '○', nemotron: '○', kimi: '○',
      ollama: '○', llamacpp: '○', glm: '○', gemini_cli: '○', codex_cli: '◐',
    },
  },
  {
    id: 'thinking',
    label: 'Thinking / Reasoning',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '●',
      qwen36: '●', mistral: '◐', nemotron: '◐', kimi: '◐',
      ollama: '◐', llamacpp: '◐', glm: '●', gemini_cli: '○', codex_cli: '●',
    },
  },
  {
    id: 'interleaved-thinking',
    label: 'Interleaved Thinking',
    providers: {
      openai: '○', claude: '●', gemini: '○', deepseek: '○',
      qwen36: '○', mistral: '○', nemotron: '○', kimi: '○',
      ollama: '○', llamacpp: '○', glm: '○', gemini_cli: '○', codex_cli: '○',
    },
  },
  {
    id: 'streaming-tools',
    label: 'Streaming Tool Calls',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '●',
      qwen36: '●', mistral: '●', nemotron: '●', kimi: '●',
      ollama: '●', llamacpp: '●', glm: '●', gemini_cli: '●', codex_cli: '●',
    },
  },
  {
    id: 'prompt-caching',
    label: 'Prompt Caching',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '○',
      qwen36: '○', mistral: '○', nemotron: '○', kimi: '●',
      ollama: '◐', llamacpp: '●', glm: '○', gemini_cli: '○', codex_cli: '●',
    },
  },
  {
    id: 'seed',
    label: 'seed (reproducible)',
    providers: {
      openai: '●', claude: '○', gemini: '●', deepseek: '○',
      qwen36: '○', mistral: '●', nemotron: '○', kimi: '○',
      ollama: '●', llamacpp: '●', glm: '○', gemini_cli: '○', codex_cli: '○',
    },
  },
  {
    id: 'multimodal',
    label: 'Multimodal',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '○',
      qwen36: '●', mistral: '●', nemotron: '●', kimi: '●',
      ollama: '◐', llamacpp: '◐', glm: '●', gemini_cli: '◐', codex_cli: '◐',
    },
  },
  {
    id: 'mcp',
    label: 'MCP Protocol',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '○',
      qwen36: '○', mistral: '○', nemotron: '○', kimi: '●',
      ollama: '○', llamacpp: '○', glm: '○', gemini_cli: '●', codex_cli: '●',
    },
  },
  {
    id: 'code-execution',
    label: 'Code Execution',
    providers: {
      openai: '○', claude: '●', gemini: '○', deepseek: '○',
      qwen36: '○', mistral: '○', nemotron: '●', kimi: '●',
      ollama: '○', llamacpp: '○', glm: '○', gemini_cli: '○', codex_cli: '●',
    },
  },
  {
    id: 'computer-use',
    label: 'Computer Use',
    providers: {
      openai: '○', claude: '●', gemini: '○', deepseek: '○',
      qwen36: '○', mistral: '○', nemotron: '○', kimi: '○',
      ollama: '○', llamacpp: '○', glm: '○', gemini_cli: '○', codex_cli: '○',
    },
  },
  {
    id: 'max-context',
    label: 'Max Context ≥128K',
    providers: {
      openai: '●', claude: '●', gemini: '●', deepseek: '●',
      qwen36: '●', mistral: '●', nemotron: '●', kimi: '●',
      ollama: '◐', llamacpp: '◐', glm: '●', gemini_cli: '●', codex_cli: '●',
    },
  },
]

export const PROVIDER_IDS = [
  'openai', 'claude', 'gemini', 'deepseek',
  'qwen36', 'mistral', 'nemotron', 'kimi',
  'ollama', 'llamacpp', 'glm', 'gemini_cli', 'codex_cli',
] as const

export const PROVIDER_LABELS: Record<string, string> = {
  openai: 'OpenAI',
  claude: 'Claude',
  gemini: 'Gemini',
  deepseek: 'DeepSeek',
  qwen36: 'Qwen 3.6',
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
  qwen36: 'direct', mistral: 'direct', nemotron: 'direct', kimi: 'direct',
  ollama: 'direct', llamacpp: 'direct', glm: 'direct',
  gemini_cli: 'cli', codex_cli: 'cli',
}

// Provider category (Cloud API / CLI / Local). Source: sec01 §1.2.
export type ProviderCategory = 'cloud' | 'cli' | 'local'

export const PROVIDER_CATEGORY: Record<string, ProviderCategory> = {
  openai: 'cloud', claude: 'cloud', gemini: 'cloud', deepseek: 'cloud',
  qwen36: 'cloud', mistral: 'cloud', nemotron: 'cloud', kimi: 'cloud',
  ollama: 'local', llamacpp: 'local', glm: 'cloud',
  gemini_cli: 'cli', codex_cli: 'cli',
}

// Feature grouping by functional category. Source: sec01 §1.3 Table.
export const FEATURE_CATEGORIES: Array<{ id: string; label: string; featureIds: string[] }> = [
  { id: 'tool-use', label: 'Tool Use / Function Calling', featureIds: ['tool-calling', 'parallel-tools', 'tool-choice', 'streaming-tools'] },
  { id: 'thinking', label: 'Thinking / Reasoning', featureIds: ['thinking', 'interleaved-thinking'] },
  { id: 'structured-output', label: 'Structured Output', featureIds: ['structured-output', 'constrained-decoding'] },
  { id: 'sampling', label: 'Sampling & Reproducibility', featureIds: ['seed'] },
  { id: 'context', label: 'Context & Caching', featureIds: ['prompt-caching', 'max-context'] },
  { id: 'extended', label: 'Multimodal / Extended', featureIds: ['multimodal', 'mcp', 'code-execution', 'computer-use'] },
]

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

export interface CategoryCoverage {
  id: string
  label: string
  native: number
  total: number
  pct: number
}

export function computeCategoryCoverage(): CategoryCoverage[] {
  const featById = new Map(FEATURES.map(f => [f.id, f]))
  return FEATURE_CATEGORIES.map(cat => {
    let native = 0, total = 0
    for (const fid of cat.featureIds) {
      const feat = featById.get(fid)
      if (!feat) continue
      for (const pid of PROVIDER_IDS) {
        if (feat.providers[pid] === '●') native++
        total++
      }
    }
    return { id: cat.id, label: cat.label, native, total, pct: total > 0 ? Math.round((native / total) * 100) : 0 }
  })
}

// ── BFCL Benchmarks ─────────────────────────────────────────────
// Source: BFCL V4 Leaderboard, gorilla.cs.berkeley.edu (Last Updated: 2026-04-12)
// 109 models evaluated. Selection: top-performing + MASC-relevant providers.

export interface BfclEntry {
  rank: number
  model: string
  bfclV3: string
  bfclV4: string
  feature: string
  license: string
}

export const BFCL_RANKINGS: BfclEntry[] = [
  { rank: 1,  model: 'Claude Opus 4.5 (FC)',      bfclV3: '—', bfclV4: '77.47%', feature: 'V4 1위, Interleaved Thinking',           license: '상업적' },
  { rank: 2,  model: 'Claude Sonnet 4.5 (FC)',     bfclV3: '—', bfclV4: '73.24%', feature: '성능/비용 최적 균형',                     license: '상업적' },
  { rank: 3,  model: 'Gemini 3 Pro Preview (Prompt)', bfclV3: '—', bfclV4: '72.51%', feature: 'Google 차세대, Prompt mode',             license: '상업적' },
  { rank: 4,  model: 'GLM-4.6 (FC thinking)',      bfclV3: '—', bfclV4: '72.38%', feature: 'Zhipu AI, FC+thinking 혼합',             license: 'MIT' },
  { rank: 6,  model: 'Claude Haiku 4.5 (FC)',      bfclV3: '—', bfclV4: '68.70%', feature: '소형 모델 중 최고 수준',                  license: '상업적' },
  { rank: 11, model: 'Kimi K2 Instruct (FC)',       bfclV3: '—', bfclV4: '59.06%', feature: 'MoonshotAI, MoE 오픈웨이트',             license: 'Modified MIT' },
  { rank: 14, model: 'DeepSeek V3.2 Exp (Prompt)',  bfclV3: '—', bfclV4: '56.73%', feature: 'Prompt+Thinking 모드',                   license: 'MIT' },
  { rank: 15, model: 'Gemini 2.5 Flash (FC)',       bfclV3: '—', bfclV4: '56.24%', feature: 'Google 경량, FC mode',                    license: '상업적' },
  { rank: 16, model: 'GPT-5.2 (FC)',                bfclV3: '—', bfclV4: '55.87%', feature: 'OpenAI 최신, MCPMark와 차이 유의',       license: '상업적' },
  { rank: 20, model: 'GPT-4.1 (FC)',                bfclV3: '—', bfclV4: '53.96%', feature: 'OpenAI 4.1, 비용 효율',                  license: '상업적' },
  { rank: 23, model: 'Qwen3-235B-A22B (Prompt)',    bfclV3: '—', bfclV4: '52.15%', feature: 'Alibaba MoE 오픈웨이트',                 license: 'Apache 2.0' },
  { rank: 46, model: 'Mistral Large 2411 (FC)',     bfclV3: '—', bfclV4: '38.37%', feature: 'Mistral AI 최상위, FC mode',             license: '상업적' },
]

// ── BFCL V4 Category Breakdown ──────────────────────────────────

export interface BfclV4Category {
  id: string
  label: string
  description: string
  weight: string
}

export const BFCL_V4_CATEGORIES: BfclV4Category[] = [
  { id: 'agentic',       label: 'Agentic (Holistic)',         description: 'Web Search + Memory 전체 에이전트 평가',  weight: '3개 서브카테고리' },
  { id: 'multi-turn',    label: 'Multi-turn Interactions',    description: 'Multi turn + Non-live (AST) + Live (AST)', weight: '3개 서브카테고리' },
  { id: 'single-turn',   label: 'Single Turn',                description: 'Simple + Multiple + Parallel + Multi-Parallel', weight: '4개 서브카테고리' },
  { id: 'hallucination', label: 'Hallucination Measurement',  description: '오류 탐지: Miss Func / Miss Param / Long Context', weight: '6개 서브카테고리' },
  { id: 'format',        label: 'Format Sensitivity',         description: 'FC vs Prompt 모드 간 격차 측정 (Prompt 전용)', weight: 'Prompt 전용' },
]

export interface BfclModelCategoryBreakdown {
  model: string
  overall: string
  singleTurn: string
  multiTurn: string
  agentic: string
  hallucination: string
  format: string
}

// Per-category scores from BFCL V4 leaderboard (gorilla.cs.berkeley.edu, 2026-04-12).
// Overall = unweighted average of all sub-categories.
export const BFCL_MODEL_BREAKDOWN: BfclModelCategoryBreakdown[] = [
  { model: 'Claude Opus 4.5',   overall: '77.47%', singleTurn: '88.58', multiTurn: '73.76', agentic: '84.50', hallucination: '68.38', format: '79.79' },
  { model: 'Claude Sonnet 4.5', overall: '73.24%', singleTurn: '88.65', multiTurn: '64.95', agentic: '81.00', hallucination: '61.37', format: '81.13' },
  { model: 'GLM-4.6',           overall: '72.38%', singleTurn: '87.56', multiTurn: '55.70', agentic: '77.50', hallucination: '68.00', format: '80.90' },
  { model: 'Claude Haiku 4.5',  overall: '68.70%', singleTurn: '86.50', multiTurn: '54.41', agentic: '83.50', hallucination: '53.62', format: '78.68' },
  { model: 'Kimi K2',           overall: '59.06%', singleTurn: '77.89', multiTurn: '42.27', agentic: '66.50', hallucination: '53.68', format: '67.78' },
  { model: 'DeepSeek V3.2',     overall: '56.73%', singleTurn: '73.56', multiTurn: '38.33', agentic: '66.50', hallucination: '45.57', format: '64.36' },
  { model: 'Gemini 2.5 Flash',  overall: '56.24%', singleTurn: '76.16', multiTurn: '42.11', agentic: '58.00', hallucination: '42.12', format: '70.69' },
  { model: 'GPT-5.2',           overall: '55.87%', singleTurn: '70.26', multiTurn: '42.19', agentic: '69.00', hallucination: '38.51', format: '71.63' },
  { model: 'GPT-4.1',           overall: '53.96%', singleTurn: '70.72', multiTurn: '37.81', agentic: '60.50', hallucination: '42.26', format: '70.66' },
  { model: 'Qwen3-235B',        overall: '52.15%', singleTurn: '69.81', multiTurn: '35.67', agentic: '55.00', hallucination: '44.12', format: '68.48' },
  { model: 'Mistral Large',     overall: '38.37%', singleTurn: '84.65', multiTurn: '24.95', agentic: '28.00', hallucination: '14.12', format: '81.87' },
]

export function categoryLevelClass(level: CategoryLevel): string {
  switch (level) {
    case 'high': return 'bg-[var(--ok-10)] text-[var(--color-status-ok)]'
    case 'mid':  return 'bg-[var(--warn-10)] text-[var(--color-status-warn)]'
    case 'low':  return 'bg-[var(--bad-10)] text-[var(--bad-light)]'
  }
}

export function categoryLevelLabel(level: CategoryLevel): string {
  switch (level) {
    case 'high': return '높음'
    case 'mid':  return '중간'
    case 'low':  return '낮음'
  }
}

export function scoreColor(score: string): string {
  const v = parseFloat(score)
  if (v >= 75) return 'text-[var(--color-status-ok)]'
  if (v >= 50) return 'text-[var(--color-status-warn)]'
  return 'text-[var(--bad-light)]'
}

export function scoreBucket(score: string): string {
  const v = parseFloat(score)
  if (v >= 75) return 'z4'
  if (v >= 60) return 'z3'
  if (v >= 55) return 'z2'
  if (v >= 40) return 'z1'
  return 'z0'
}


// ── Function Calling Harness Case Study ──────────────────────────

export interface HarnessModel {
  id: string
  params: string
  compileRate: string
}

export const HARNESS_MODELS: HarnessModel[] = [
  { id: 'qwen3.6-plus',      params: 'Hosted, 1M ctx', compileRate: '100%' },
  { id: 'qwen3.6-35b-a3b',   params: '3B/35B MoE',     compileRate: '100%' },
  { id: 'qwen3.6-27b',       params: '27B Dense',      compileRate: '100%' },
  { id: 'qwen3-coder-next',  params: '3B/80B Coding',  compileRate: '100%' },
]

// ── MCPMark: MCP Agent Workflow Benchmark ──────────────────────
// Source: external_research.md §1.2.3, verified 2026-04-30.
// MCPMark measures pass@1 on MCP-based agent workflows (not schema compliance).
// BFCL 1위(Claude Opus 4.5) ≠ MCPMark 1위(GPT-5) — benchmark dependency warning.

export interface McpMarkEntry {
  model: string
  passAt1: string
  avgAgentTime: string
  costPerRun: string
  note: string
}

export const MCPMARK_ENTRIES: McpMarkEntry[] = [
  { model: 'GPT-5',          passAt1: '52.6%', avgAgentTime: '478.21s', costPerRun: '$127.46', note: 'BFCL 7위이나 MCPMark 1위. 에이전트 워크플로우 강점' },
  { model: 'Claude Opus 4.1', passAt1: '29.9%', avgAgentTime: '361.81s', costPerRun: '고가',     note: 'BFCL 2위. pass@1은 GPT-5에 0.57×' },
  { model: 'Claude Sonnet 4', passAt1: '28.1%', avgAgentTime: '218.27s', costPerRun: '$252.41',  note: '가장 빠른 에이전트 완주, 비용은 GPT-5의 2×' },
  { model: 'Qwen 3-Coder',   passAt1: '24.8%', avgAgentTime: '274.29s', costPerRun: '$36.46',   note: '최저 비용 ($36/런). BFCL 미참여' },
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
  { id: 'W02', provider: 'Codex CLI', capability: 'tools vs MCP', oasDeclares: 'supports_tools=false', actualBehavior: 'inline tool calling은 없으나 runtime_mcp_tools=true로 MCP 네이티브 지원', impact: 'medium' },
  { id: 'W03', provider: 'GLM', capability: 'tool_choice', oasDeclares: 'supports_tool_choice=false', actualBehavior: 'auto만 지원. Any/Tool/None은 Auto로 coerce → 사용자 의도 무시 (Fake Fallback)', impact: 'medium' },
  { id: 'W04', provider: 'GLM', capability: 'structured_output', oasDeclares: 'supports_structured_output=false', actualBehavior: 'JSON Schema 지정 가능하나 JSON Mode에 가까움, Constrained Decoding 불가', impact: 'low' },
  { id: 'W05', provider: 'Ollama', capability: 'tool_choice', oasDeclares: 'supports_tool_choice=false', actualBehavior: '모델 의존적. Qwen3.6+Jinja에서는 tool_choice 정상 작동, 일반 모델은 Auto만', impact: 'medium' },
  { id: 'W06', provider: 'Kimi CLI', capability: 'tool_choice', oasDeclares: 'supports_tool_choice=false', actualBehavior: 'Kimi API는 auto/forced/none 모두 지원. CLI --print 모드에서 req.tools 무시', impact: 'medium' },
  { id: 'W07', provider: 'Kimi CLI', capability: 'usage tokens', oasDeclares: 'emits_usage_tokens=false (strip)', actualBehavior: 'CLI subprocess에서 usage 정보 미포함, 정확한 선언', impact: 'correct' },
  { id: 'W08', provider: 'Gemini CLI', capability: 'usage tokens', oasDeclares: 'emits_usage_tokens=false (strip)', actualBehavior: 'CLI subprocess 특성상 usage 불안정, 정확한 선언', impact: 'correct' },
  { id: 'W09', provider: 'Codex CLI', capability: 'usage tokens', oasDeclares: 'emits_usage_tokens=false (strip)', actualBehavior: 'JSONL envelope에서 usage 미제공, 정확한 선언', impact: 'correct' },
  { id: 'W10', provider: 'Anthropic Claude', capability: 'tools', oasDeclares: 'supports_tools=true', actualBehavior: 'tool_use/tool_result 블록 구조, 공식 문서와 일치', impact: 'correct' },
  { id: 'W11', provider: 'Anthropic Claude', capability: 'extended thinking', oasDeclares: 'supports_extended_thinking=true', actualBehavior: 'budget_tokens + Interleaved Thinking (Claude 4+), 정확한 선언', impact: 'correct' },
  { id: 'W12', provider: 'Ollama', capability: 'is_ollama flag', oasDeclares: 'is_ollama=true', actualBehavior: 'tool_calls를 raw JSON 객체로 직렬화, 정확한 선언', impact: 'correct' },
  { id: 'W13', provider: 'Gemini CLI', capability: 'infinite thinking', oasDeclares: '—', actualBehavior: 'Gemini 2.5 Flash에서 thinking loop 무한 루프 발생 (GitHub #2025), 복잡 프롬프트 시 hang', impact: 'high' },
  { id: 'W14', provider: 'DeepSeek', capability: 'V3.2 FC', oasDeclares: '—', actualBehavior: 'V3.1 Strict FC (Beta) 지원, R1은 vLLM 경로만 tool calling, V3.2 Speciale은 FC 미지원', impact: 'medium' },
  { id: 'W15', provider: 'Qwen', capability: 'tool format', oasDeclares: '—', actualBehavior: 'Hermes-style tool format 사용, 1M context (3.6 Plus), Hybrid Thinking Mode', impact: 'low' },
  { id: 'W16', provider: 'Nemotron', capability: 'thinking vs FC', oasDeclares: '—', actualBehavior: 'thinking ON 시 tool calling 미지원, thinking OFF 필요 시에만 FC 활성화 (§2.5)', impact: 'medium' },
  { id: 'W17', provider: 'Kimi', capability: 'JSON Schema validation', oasDeclares: '—', actualBehavior: 'minimum, maximum, minLength, maxLength 검증 키워드 일부 거부 → tool 호출 실패 사례 보고 (§4.1.6)', impact: 'medium' },
  { id: 'W18', provider: 'Ollama', capability: 'streaming tool calls', oasDeclares: '—', actualBehavior: 'OpenAI compat 엔드포인트(/v1/chat/completions)에서 streaming 시 tool calls 누락 버그, native /api/chat 권장 (§4.1.7)', impact: 'high' },
  { id: 'W19', provider: 'Ollama', capability: 'num_ctx default', oasDeclares: '—', actualBehavior: 'num_ctx 기본값 4096으로 대형 시스템 프롬프트+다수 툴 정의가 무시 트렁케이션 (§4.1.7)', impact: 'high' },
  { id: 'W20', provider: 'Codex CLI', capability: 'sandbox bypass CVE', oasDeclares: '—', actualBehavior: 'CVE-2025-59532 샌드박스 우회 취약점, 0.39.0에서 패치. 컨테이너 격리 한계 (§4.1.10)', impact: 'medium' },
]

// ── Anti-patterns ───────────────────────────────────────────────
// Source: sec05 — 32 Anti-patterns with risk ratings

export type AntiPatternCategory = 'silent-failure' | 'fake-fallback' | 'string-match' | 'hardcoding'
export type RiskLevel = 'C' | 'H' | 'M' | 'L'
export type AntiPatternSource = 'masc-mcp' | 'oas' | 'unverified'

export interface AntiPattern {
  id: string
  category: AntiPatternCategory
  description: string
  location: string
  risk: RiskLevel
  source: AntiPatternSource
  improvement: string
  /** What breaks when this anti-pattern fires — from sec05 risk matrix */
  impact?: string
  /** When this anti-pattern is triggered — from sec05 risk matrix */
  likelihood?: string
}

export const ANTI_PATTERNS: AntiPattern[] = [
  // Silent Failure (S01-S10)
  { id: 'S01', category: 'silent-failure', description: '`top_k` capability drop 시 one-shot WARN, 상위 포착 불가', location: 'backend_openai.ml:207-208', risk: 'M', source: 'oas', improvement: 'WARN를 structured logging으로 전환', impact: '단일 요청 파라미터 누락', likelihood: 'capability 불일치 모든 요청' },
  { id: 'S02', category: 'silent-failure', description: '`min_p` capability drop 시 동일 패턴', location: 'backend_openai.ml:214-215', risk: 'M', source: 'oas', improvement: 'WARN를 structured logging으로 전환', impact: '단일 요청 파라미터 누락', likelihood: 'capability 불일치 모든 요청' },
  { id: 'S03', category: 'silent-failure', description: 'non-DeepSeek 모델의 `chat_template_kwargs` 무시', location: 'backend_openai.ml:234', risk: 'H', source: 'oas', improvement: '`thinking_control_format` capability 필드 추가', impact: 'Thinking 기능 비활성화', likelihood: 'non-DeepSeek reasoning 모델' },
  { id: 'S04', category: 'silent-failure', description: 'ToolResult name lookup 실패 시 `tool_use_id`를 name으로 사용', location: 'backend_gemini.ml:62-64', risk: 'M', source: 'oas', improvement: 'fallback 시 debug 로그 기록', impact: '잘못된 툴 호출 기록', likelihood: '툴 체인 복잡한 대화' },
  { id: 'S05', category: 'silent-failure', description: 'CLI wrapper usage stripping — usage 누락', location: 'capabilities.ml:273,286,300', risk: 'L', source: 'oas', improvement: 'usage 누락의 구조적 특성 문서화', impact: 'Usage 데이터 누락', likelihood: '모든 CLI Provider 호출' },
  { id: 'S06', category: 'silent-failure', description: '`supports_min_p=false`와 주석 "both true" 불일치', location: 'capabilities.ml:179-185', risk: 'M', source: 'oas', improvement: '주석-코드 동기화', impact: 'min_p 의도치 않은 drop', likelihood: '모든 Ollama 호출' },
  { id: 'S07', category: 'silent-failure', description: 'unknown model의 tool_choice를 `true`로 가정', location: 'backend_openai.ml:252-258', risk: 'M', source: 'oas', improvement: 'capability override 설정 노출', impact: '400 오류 또는 잘못된 가정', likelihood: '알 수 없는 모델 사용 시' },
  { id: 'S08', category: 'silent-failure', description: '`max_tokens` 4096 fallback — 알 수 없는 모델 출력 제한', location: 'backend_openai.ml:173', risk: 'H', source: 'oas', improvement: '모델 discovery 동적 연동', impact: '출력 길이 제한', likelihood: '알 수 없는 모델 + max_tokens 미설정' },
  { id: 'S09', category: 'silent-failure', description: '`thinkingBudget` 기본값 10000 하드코딩', location: 'backend_gemini.ml:189', risk: 'L', source: 'oas', improvement: '모델별 동적 기본값', impact: 'Thinking depth 제한', likelihood: 'thinking 미설정 모든 요청' },
  { id: 'S10', category: 'silent-failure', description: 'GLM `Required`/`None_`를 `Auto`로 coerce', location: 'backend_openai.ml:60-66', risk: 'M', source: 'oas', improvement: 'contract relaxation 명시화', impact: '강제 툴 호출 의도 무시', likelihood: 'GLM + Required/None_ 요청' },
  // Fake Fallback (F01-F04)
  { id: 'F01', category: 'fake-fallback', description: 'GLM tool_choice auto만 지원, 사용자 의도 무시', location: 'backend_glm.ml', risk: 'M', source: 'oas', improvement: 'pipeline-level contract 검증 강화', impact: '계약 위반 미검출', likelihood: 'GLM + specific tool 요청' },
  { id: 'F02', category: 'fake-fallback', description: 'Codex unsupported config 필드 WARN 후 무시', location: 'transport_codex_cli.ml:628-639', risk: 'M', source: 'oas', improvement: '`Provider_config.validate`에서 사전 에러', impact: '설정 의도 미반영', likelihood: 'Codex + unsupported config' },
  { id: 'F03', category: 'fake-fallback', description: 'Gemini CLI `supports_tools=false`', location: 'capabilities.ml:265-275', risk: 'L', source: 'oas', improvement: 'CLI Provider 실제 능력 탐지 개선', impact: 'Tool 경로 우회', likelihood: 'Gemini CLI 사용 시' },
  { id: 'F04', category: 'fake-fallback', description: 'Ollama `supports_tool_choice=false`', location: 'capabilities.ml:179-185', risk: 'M', source: 'oas', improvement: 'per-model override 허용', impact: 'Tool choice 제한', likelihood: 'Ollama + tool_choice 필요 시' },
  // String Matching (M01-M06)
  { id: 'M01', category: 'string-match', description: '`for_model_id` prefix substring match, 순서 의존', location: 'capabilities.ml:308-586', risk: 'H', source: 'oas', improvement: 'prefix 길이 기반 자동 정렬 테스트', impact: '잘못된 capability 매칭', likelihood: '모델 추가/네이밍 변경 시' },
  { id: 'M02', category: 'string-match', description: '`deepseek-v4` 문자열 매칭으로 thinking control 분기', location: 'backend_openai.ml:221', risk: 'H', source: 'oas', improvement: 'capability 필드 기반 결정론적 분기', impact: 'Thinking 처리 불일치', likelihood: '새로운 reasoning 모델 추가 시' },
  { id: 'M03', category: 'string-match', description: 'Ollama 모델 capability 문자열 기반 추정 불가', location: 'capabilities.ml:308-586', risk: 'M', source: 'oas', improvement: 'Ollama `/api/show` 연동(가용 시)', impact: '과소/과대 capability 선언', likelihood: 'Ollama 모델 변경 시' },
  { id: 'M04', category: 'string-match', description: '`contains_ci` Ollama 에러 메시지 문자열 파싱', location: 'oas_compat.ml', risk: 'H', source: 'oas', improvement: '구조화된 에러 코드 사용', impact: '잘못된 에러 분류', likelihood: 'Provider 메시지 변경 시' },
  { id: 'M05', category: 'string-match', description: '`accept_rejected_cascadable_markers` 패턴 매칭', location: 'oas_compat.ml', risk: 'H', source: 'oas', improvement: 'retryable 에러 코드 체계 도입', impact: '잘못된 에러 분류', likelihood: 'Provider 메시지 변경 시' },
  { id: 'M06', category: 'string-match', description: 'Provider label case-insensitive match', location: 'capabilities.ml:594-608', risk: 'L', source: 'oas', improvement: 'alias 충돌 테스트 자동화', impact: '잘못된 capability 반환', likelihood: '새 provider 추가 시' },
  // Hardcoding (H01-H12)
  { id: 'H01', category: 'hardcoding', description: '`max_tokens` fallback 4096', location: 'backend_openai.ml:173', risk: 'M', source: 'oas', improvement: '모델 메타데이터 동적 조회', impact: '설정 유연성 저하', likelihood: '관련 기능 사용 시' },
  { id: 'H02', category: 'hardcoding', description: '`thinkingBudget` 기본값 10000', location: 'backend_gemini.ml:189', risk: 'M', source: 'oas', improvement: '모델별 설정 외부화', impact: '설정 유연성 저하', likelihood: '관련 기능 사용 시' },
  { id: 'H03', category: 'hardcoding', description: '`reasoning_effort` "medium" 기본값', location: 'Provider_config.ml', risk: 'M', source: 'oas', improvement: 'effort-budget 매핑 테이블화', impact: '설정 유연성 저하', likelihood: '관련 기능 사용 시' },
  { id: 'H04', category: 'hardcoding', description: 'cache_control watermark 0.9', location: 'pipeline.ml:858', risk: 'M', source: 'oas', improvement: '설정 가능한 파라미터로 전환', impact: '부정확한 게이트', likelihood: 'cache 관련 요청 시' },
  { id: 'H05', category: 'hardcoding', description: 'prompt cache min chars 4096', location: 'Constants.Anthropic', risk: 'M', source: 'oas', improvement: '토큰 기반 게이트로 개선', impact: '부정확한 게이트', likelihood: 'cache 관련 요청 시' },
  { id: 'H06', category: 'hardcoding', description: '`keep_alive` 기본값 "-1"', location: 'backend_ollama.ml:81', risk: 'L', source: 'oas', improvement: '환경 변수 문서화 및 검증', impact: '의도와 다른 동작', likelihood: 'Ollama 기본 설정 사용 시' },
  { id: 'H07', category: 'hardcoding', description: '`think` 기본값 `false`', location: 'backend_ollama.ml:39-40', risk: 'L', source: 'oas', improvement: '모델별 기본값 설정', impact: '의도와 다른 동작', likelihood: 'Ollama 기본 설정 사용 시' },
  { id: 'H08', category: 'hardcoding', description: 'prompt_argv_threshold 512KB', location: 'transport_codex_cli.ml:252', risk: 'M', source: 'oas', improvement: '플랫폼별 설정 외부화', impact: '플랫폼 호환성 이슈', likelihood: 'CLI 사용 + 큰 프롬프트 시' },
  { id: 'H09', category: 'hardcoding', description: 'prompt_argv_threshold 32KB', location: 'transport_kimi_cli.ml:41', risk: 'M', source: 'oas', improvement: '플랫폼별 설정 외부화', impact: '플랫폼 호환성 이슈', likelihood: 'CLI 사용 + 큰 프롬프트 시' },
  { id: 'H10', category: 'hardcoding', description: 'chars per token ≈ 4 추정', location: 'backend_openai_parse.ml:187', risk: 'L', source: 'oas', improvement: '토크나이저 연동(가용 시)', impact: '부정확한 telemetry', likelihood: 'reasoning_tokens fallback 시' },
  { id: 'H11', category: 'hardcoding', description: 'Anthropic/OpenAI model pricing', location: 'provider.ml:512-516', risk: 'M', source: 'oas', improvement: 'pricing API 동적 연동', impact: '유지보수 부담', likelihood: '모델 업데이트/신규 출시 시' },
  { id: 'H12', category: 'hardcoding', description: 'Static benchmark 기반 capability 테이블', location: 'capabilities.ml:308-586', risk: 'M', source: 'oas', improvement: '동적 capability discovery 연구', impact: '유지보수 부담', likelihood: '모델 업데이트/신규 출시 시' },
]

// ── Provider Model Catalog ──────────────────────────────────────
// Per-provider model listings with context/pricing. Source: supplement research + official docs.

export interface ProviderModel {
  id: string
  context: string
  tier: 'flagship' | 'standard' | 'fast' | 'coding' | 'legacy'
  inputPrice?: string
  outputPrice?: string
  notes?: string
}

export interface ProviderModelGroup {
  providerId: string
  models: ProviderModel[]
}

export const PROVIDER_MODELS: ProviderModelGroup[] = [
  {
    providerId: 'openai',
    models: [
      { id: 'gpt-4.1', context: '1M', tier: 'flagship', inputPrice: '$2.00', outputPrice: '$8.00', notes: 'Multimodal' },
      { id: 'gpt-4.1-mini', context: '1M', tier: 'standard', inputPrice: '$0.40', outputPrice: '$1.60' },
      { id: 'gpt-4.1-nano', context: '1M', tier: 'fast', inputPrice: '$0.10', outputPrice: '$0.40' },
      { id: 'o4-mini', context: '200K', tier: 'standard', inputPrice: '$1.10', outputPrice: '$4.40', notes: 'Reasoning' },
    ],
  },
  {
    providerId: 'claude',
    models: [
      { id: 'claude-opus-4-5-20251101', context: '200K', tier: 'flagship', inputPrice: '$15.00', outputPrice: '$75.00', notes: 'BFCL V4 #1, Extended+Interleaved Thinking' },
      { id: 'claude-sonnet-4-5-20250929', context: '200K', tier: 'standard', inputPrice: '$3.00', outputPrice: '$15.00', notes: 'BFCL V4 #2, Adaptive Thinking' },
      { id: 'claude-haiku-4-5-20251001', context: '200K', tier: 'fast', inputPrice: '$0.80', outputPrice: '$4.00', notes: 'BFCL V4 #6' },
      { id: 'claude-sonnet-4-6', context: '200K', tier: 'standard', inputPrice: '$3.00', outputPrice: '$15.00', notes: 'Adaptive Thinking' },
    ],
  },
  {
    providerId: 'gemini',
    models: [
      { id: 'gemini-2.5-pro', context: '1M', tier: 'flagship', inputPrice: '$1.25', outputPrice: '$10.00', notes: 'Thinking' },
      { id: 'gemini-2.5-flash', context: '1M', tier: 'standard', inputPrice: '$0.15', outputPrice: '$0.60', notes: 'Thinking' },
      { id: 'gemini-2.0-flash', context: '1M', tier: 'fast', inputPrice: '$0.10', outputPrice: '$0.40' },
    ],
  },
  {
    providerId: 'deepseek',
    models: [
      { id: 'deepseek-r1', context: '128K', tier: 'flagship', inputPrice: '$0.55', outputPrice: '$2.19', notes: 'Reasoning, vLLM 경로만 tool calling 지원' },
      { id: 'deepseek-v3.1', context: '128K', tier: 'standard', inputPrice: '$0.27', outputPrice: '$1.10', notes: 'Strict FC (Beta), tool_choice=required/none 가능' },
      { id: 'deepseek-v3.2-exp', context: '128K', tier: 'standard', inputPrice: '$0.27', outputPrice: '$1.10', notes: 'BFCL V4 #14, Prompt+Thinking, V3.2 Speciale은 FC 미지원' },
      { id: 'deepseek-chat', context: '128K', tier: 'fast', inputPrice: '$0.14', outputPrice: '$0.28', notes: 'V3.1 hybrid: Non-Think+Think 통합 모드' },
    ],
  },
  {
    providerId: 'qwen36',
    models: [
      { id: 'qwen3.6-plus', context: '1M', tier: 'flagship', inputPrice: '$0.50', outputPrice: '$3.00', notes: '1M ctx, Hybrid Thinking Mode, Hermes tool format, GPQA 90.4' },
      { id: 'qwen3.6-max-preview', context: '1M', tier: 'standard', inputPrice: '—', outputPrice: '—', notes: '1M ctx, Most capable, Hybrid Thinking' },
      { id: 'qwen3-235b-a22b', context: '131K', tier: 'standard', inputPrice: '—', outputPrice: '—', notes: 'MoE 오픈웨이트, BFCL V4 #23, Hermes tool format' },
      { id: 'qwen3.6-27b', context: '131K', tier: 'standard', inputPrice: '$0.161', outputPrice: '$0.965', notes: 'Open weight, GPQA Diamond 87.8' },
      { id: 'qwen3.6-35b-a3b', context: '262K', tier: 'fast', inputPrice: '$0.06', outputPrice: '$0.36', notes: '3B/35B MoE, open weight, Hybrid Thinking' },
    ],
  },
  {
    providerId: 'mistral',
    models: [
      { id: 'mistral-large-2411', context: '128K', tier: 'flagship', inputPrice: '$2.00', outputPrice: '$6.00' },
      { id: 'mistral-medium-2505', context: '128K', tier: 'standard', inputPrice: '$0.40', outputPrice: '$2.00' },
      { id: 'codestral-latest', context: '256K', tier: 'coding', inputPrice: '$0.30', outputPrice: '$0.90', notes: 'Code' },
    ],
  },
  {
    providerId: 'glm',
    models: [
      { id: 'glm-4.6', context: '128K', tier: 'flagship', inputPrice: '$1.00', outputPrice: '$0.20', notes: 'BFCL V4 #4, FC+thinking' },
      { id: 'glm-4.6v', context: '128K', tier: 'standard', inputPrice: '—', outputPrice: '—', notes: '최초 VLM 네이티브 FC, 106B+9B Flash, MIT' },
      { id: 'glm-5-code', context: '128K', tier: 'coding', inputPrice: '$1.20', outputPrice: '$0.30', notes: 'Coding Plan 전용' },
      { id: 'glm-4.5-air', context: '128K', tier: 'fast', inputPrice: '—', outputPrice: '—', notes: 'Coding Plan 경량' },
    ],
  },
  {
    providerId: 'nemotron',
    models: [
      { id: 'nemotron-4-340b', context: '4K', tier: 'flagship', inputPrice: '—', outputPrice: '—', notes: 'NVIDIA NIM, thinking OFF 필요 시 tool calling' },
    ],
  },
  {
    providerId: 'kimi',
    models: [
      { id: 'kimi-k2.6', context: '256K', tier: 'flagship', inputPrice: '—', outputPrice: '—', notes: 'MoE 1T/32B, SWE-Bench Pro 58.6% > GPT-5.4(57.7%), Context Caching' },
      { id: 'kimi-k2-instruct', context: '256K', tier: 'standard', inputPrice: '—', outputPrice: '—', notes: 'BFCL V4 #11, MoE 오픈웨이트, OpenAI 완전 호환' },
      { id: 'kimi-k2-thinking', context: '256K', tier: 'standard', inputPrice: '—', outputPrice: '—', notes: '장기 사고' },
      { id: 'kimi-k2-turbo-preview', context: '256K', tier: 'fast', inputPrice: '—', outputPrice: '—', notes: '60-100 tok/s' },
      { id: 'moonshot-v1-128k', context: '128K', tier: 'legacy', inputPrice: '—', outputPrice: '—' },
    ],
  },
  {
    providerId: 'ollama',
    models: [
      { id: 'llama3.3:70b', context: '128K', tier: 'flagship', notes: 'Tool calling 지원' },
      { id: 'qwen3:32b', context: '128K', tier: 'standard', notes: 'Tool + thinking 지원' },
      { id: 'gemma3:27b', context: '128K', tier: 'standard', notes: 'Tool 지원' },
      { id: 'gemma4:27b', context: '128K', tier: 'standard', notes: 'Apache 2.0, 멀티모달(T/I/A), BFCL v3 76.9%' },
      { id: 'mistral-nemo:12b', context: '128K', tier: 'fast', notes: 'Tool calling 지원' },
      { id: 'functionary:v3.2', context: '128K', tier: 'coding', notes: 'FC 특화, Hermes 포맷' },
      { id: 'hermes3:8b', context: '128K', tier: 'fast', notes: 'Tool calling 지원' },
      { id: 'deepseek-r1:70b', context: '128K', tier: 'standard', notes: 'Tool 실험적 지원' },
    ],
  },
  {
    providerId: 'llamacpp',
    models: [
      { id: '(local GGUF)', context: 'varies', tier: 'standard', notes: 'Native + Generic tool format, --chat-template-file 오버라이드' },
    ],
  },
]

export function modelTierStyle(tier: ProviderModel['tier']): string {
  switch (tier) {
    case 'flagship': return 'bg-[var(--ok-10)] text-[var(--color-status-ok)]'
    case 'standard': return 'bg-[var(--white-4)] text-[var(--color-fg-secondary)]'
    case 'fast':     return 'bg-[var(--warn-10)] text-[var(--color-status-warn)]'
    case 'coding':   return 'bg-[var(--bad-10)] text-[var(--bad-light)]'
    case 'legacy':   return 'bg-[var(--white-4)] text-[var(--color-fg-muted)]'
  }
}

// ── CLI Transport Comparison ──────────────────────────────────
// CLI transport implementation details. Source: cli_noninteractive_deep_dive.md.

export interface CliTransportInfo {
  providerId: string
  binary: string
  contextWindow: string
  promptMode: string
  streamFormat: string
  argvThreshold: string
  notes: string
}

export const CLI_TRANSPORTS: CliTransportInfo[] = [
  { providerId: 'claude', binary: 'claude', contextWindow: '200K', promptMode: '-p', streamFormat: 'stream-json', argvThreshold: '512KB', notes: 'thinking+tool_use 보존 위해 내부 stream 사용' },
  { providerId: 'gemini_cli', binary: 'gemini', contextWindow: '1M', promptMode: '--prompt', streamFormat: 'JSON chunks', argvThreshold: '—', notes: 'SSE-style chunked 응답. Gemini 2.5 Flash infinite thinking bug (#2025)' },
  { providerId: 'codex_cli', binary: 'codex', contextWindow: '1M', promptMode: 'stdin', streamFormat: 'NDJSON', argvThreshold: '—', notes: 'GPT-5.2-Codex 기본, 내부 5-model rotation, Agents SDK 오케스트레이션' },
  { providerId: 'kimi', binary: 'kimi-for-coding', contextWindow: '262K', promptMode: '-p', streamFormat: 'NDJSON', argvThreshold: '—', notes: 'Anthropic API 호환 포맷' },
]

// ── GLM Model Mapping ─────────────────────────────────────────
// OAS GLM provider model list. Source: sec01 provider table.
// GLM-5-Code and GLM-4.5-Air are NOT confirmed in reference docs — marked as unverified.

export const GLM_CODING_PLAN_MAP: Array<{ envVar: string; glmModel: string; note: string }> = [
  { envVar: 'ANTHROPIC_DEFAULT_OPUS_MODEL', glmModel: 'glm-4.7', note: 'BFCL V4 강자 (200K)' },
  { envVar: 'ANTHROPIC_DEFAULT_SONNET_MODEL', glmModel: 'glm-5-turbo', note: '표준 코딩 (200K)' },
  { envVar: 'ANTHROPIC_DEFAULT_HAIKU_MODEL', glmModel: 'glm-5.1', note: '빠른 응답 (200K)' },
]

export const GLM_WIRING_GAPS: Array<{ area: string; oasCurrent: string; official: string; gap: string }> = [
  { area: 'Tool Choice', oasCurrent: 'supports_tool_choice=false', official: 'auto만 지원 (none/any/강제 불가)', gap: 'Coerce-to-auto fake fallback' },
  { area: 'Structured Output', oasCurrent: 'supports_structured_output=false', official: 'JSON Schema 지정 가능 (JSON Mode)', gap: 'JSON Mode ≠ Constrained Decoding' },
  { area: 'Context', oasCurrent: '200K (sec01 기준)', official: '200K (sec01 기준)', gap: '검증된 gap 없음' },
]

// ── Claude Code Architecture ────────────────────────────────────
// Source: external_research.md §1.3.3, §2.3.2 (verified 2026-04-30)

export interface ExtensionMechanism {
  name: string
  since: string
  cost: string
  description: string
}

export const CLAUDE_CODE_EXTENSIONS: ExtensionMechanism[] = [
  { name: 'MCP Servers', since: '2024.11', cost: 'high', description: '외부 서버 연동, 도구/리소스/프롬프트 제공' },
  { name: 'Subagents', since: '2025.07', cost: 'medium', description: '독립 에이전트 스폰, 병렬 작업' },
  { name: 'Hooks', since: '2025.09', cost: 'zero', description: 'PreToolUse/PostToolUse/Stop/Notification 이벤트' },
  { name: 'Plugins/Skills', since: '2025.10', cost: 'low', description: 'SKILL.md + YAML frontmatter, 슬래시 명령' },
  { name: 'Agent Teams', since: '2026.02', cost: 'medium', description: '멀티 에이전트 협업, TaskList 공유' },
]

export const CLAUDE_CODE_STATS = {
  tools: 54,
  unconditionalTools: 19,
  conditionalTools: 35,
  approvalRate: '93%',
  compactionThreshold: '~75%',
  contextWindow: '200K',
  structuredOutput: 'Constrained Decoding (2025.11)',
  thinkingModes: ['Extended (budget_tokens)', 'Interleaved (Claude 4+)', 'Adaptive (Sonnet 4.6/Opus 4.6)'],
}

// ── Cascade Traces ────────────────────────────────────────────
// OAS cascade routing trace scenarios. Source: sec03 cascade flow analysis.

export type CascadeStepStatus = 'hit' | 'miss' | 'skipped'

export interface CascadeStep {
  provider: string
  status: CascadeStepStatus
  ms: number
  reason: string
}

export interface CascadeTraceScenario {
  id: string
  label: string
  tier: 'typical' | 'ideal' | 'worst' | 'cooldown'
  steps: CascadeStep[]
}

export const CASCADE_TRACES: CascadeTraceScenario[] = [
  {
    id: 'ct-rate-limit',
    label: 'Rate-limit → Fallback',
    tier: 'typical',
    steps: [
      { provider: 'Anthropic', status: 'miss', ms: 820, reason: 'rate-limit.soft' },
      { provider: 'OpenAI',    status: 'miss', ms: 540, reason: 'timeout' },
      { provider: 'Moonshot',  status: 'hit',  ms: 420, reason: 'ok' },
    ],
  },
  {
    id: 'ct-first-hit',
    label: 'Primary Hit',
    tier: 'ideal',
    steps: [
      { provider: 'Anthropic', status: 'hit',     ms: 380, reason: 'ok' },
      { provider: 'OpenAI',    status: 'skipped',  ms: 0,   reason: 'skipped' },
      { provider: 'Moonshot',  status: 'skipped',  ms: 0,   reason: 'skipped' },
    ],
  },
  {
    id: 'ct-exhaustion',
    label: '전체 Exhaustion',
    tier: 'worst',
    steps: [
      { provider: 'Anthropic', status: 'miss', ms: 1240, reason: 'rate-limit.hard' },
      { provider: 'OpenAI',    status: 'miss', ms: 980,  reason: 'server_error' },
      { provider: 'Moonshot',  status: 'miss', ms: 650,  reason: 'auth_failure' },
      { provider: 'Ollama',    status: 'miss', ms: 320,  reason: 'model_unloaded' },
    ],
  },
  {
    id: 'ct-cooldown',
    label: 'Cooldown Bypass',
    tier: 'cooldown',
    steps: [
      { provider: 'Anthropic', status: 'miss', ms: 100, reason: 'cooldown (30s remaining)' },
      { provider: 'OpenAI',    status: 'hit',  ms: 460, reason: 'ok' },
      { provider: 'Moonshot',  status: 'skipped', ms: 0, reason: 'skipped' },
    ],
  },
]

export function cascadeStepColor(status: CascadeStepStatus): string {
  switch (status) {
    case 'hit':     return 'bg-[var(--ok-10)] text-[var(--color-status-ok)] border-[var(--ok-20)]'
    case 'miss':    return 'bg-[var(--bad-10)] text-[var(--bad-light)] border-[var(--bad-20)]'
    case 'skipped': return 'bg-[var(--white-4)] text-[var(--color-fg-muted)] border-[var(--color-border-default)]'
  }
}

export function cascadeTierLabel(tier: CascadeTraceScenario['tier']): string {
  switch (tier) {
    case 'typical':  return '일반'
    case 'ideal':    return '이상'
    case 'worst':    return '최악'
    case 'cooldown': return 'Cooldown'
  }
}

export function cascadeTierStyle(tier: CascadeTraceScenario['tier']): string {
  switch (tier) {
    case 'typical':  return 'bg-[var(--white-4)] text-[var(--color-fg-secondary)]'
    case 'ideal':    return 'bg-[var(--ok-10)] text-[var(--color-status-ok)]'
    case 'worst':    return 'bg-[var(--bad-10)] text-[var(--bad-light)]'
    case 'cooldown': return 'bg-[var(--warn-10)] text-[var(--color-status-warn)]'
  }
}

// ── P0–P7 Improvement Roadmap ────────────────────────────────────
// Source: sec06 Table 6-1

export type RoadmapPhase = 'P0' | 'P1' | 'P2' | 'P3' | 'P4' | 'P5' | 'P6' | 'P7'

export interface RoadmapItem {
  id: RoadmapPhase
  area: string
  goal: string
  targetAntiPatterns: string[]
  reference: string
  effect: string
  timeline: string
  deps: RoadmapPhase[]
}

export const ROADMAP_ITEMS: RoadmapItem[] = [
  {
    id: 'P0', area: 'Verification Loop',
    goal: '모든 tool calling 결과를 JSON Schema로 검증, 실패 시 self-healing 루프',
    targetAntiPatterns: ['S01-S10', 'F01-F04'],
    reference: 'Sam Chon Harness, Typia',
    effect: '복잡한 스키마 tool call 성공률 6.75%→100%',
    timeline: '1-4주', deps: [],
  },
  {
    id: 'P1', area: 'Context Compaction',
    goal: 'KV Cache 압축, capability 기반 context ceiling, cache_control 자동화',
    targetAntiPatterns: ['H04-H05', 'S08'],
    reference: 'Claude Code compaction',
    effect: '장기 세션 60-70% 컨텍스트 해제',
    timeline: '2-6주', deps: ['P0'],
  },
  {
    id: 'P2', area: 'MCP Integration',
    goal: 'CLI Provider MCP 활성화, runtime tool discovery, ToolResult 타입 검증',
    targetAntiPatterns: ['F02-F03', 'M04-M05'],
    reference: 'MCPMark, Claude Code MCP',
    effect: 'CLI Provider tool 사용률 0→100%',
    timeline: '3-8주', deps: ['P0'],
  },
  {
    id: 'P3', area: 'Thinking Unification',
    goal: 'thinking_control_format capability 필드, provider별 직렬화 표준화',
    targetAntiPatterns: ['M01-M03', 'S03'],
    reference: 'BFCL, Gemini thinking config',
    effect: 'thinking 처리 결정론적 분기 보장',
    timeline: '2-6주', deps: ['P0'],
  },
  {
    id: 'P4', area: 'Deterministic Output',
    goal: 'seed 파라미터 지원, temperature=0 한계 문서화, 이미지 입력 처리',
    targetAntiPatterns: ['H10', 'S05'],
    reference: 'OpenAI seed docs, PyTorch determinism',
    effect: '텍스트 전용 프롬프트 재생 가능한 출력',
    timeline: '4-10주', deps: ['P0', 'P3'],
  },
  {
    id: 'P5', area: 'Anti-pattern Removal',
    goal: 'Silent Failure→Explicit Error, Fake Fallback→Capability Honesty, String→Metadata, Hardcode→Config',
    targetAntiPatterns: ['S01-S10', 'F01-F04', 'M01-M06', 'H01-H12'],
    reference: 'Ch5 분석 결과',
    effect: '32개 안티패턴 중 28개 제거 (87.5%)',
    timeline: '2-16주', deps: ['P0', 'P2', 'P4'],
  },
  {
    id: 'P6', area: 'New Provider Support',
    goal: 'Nemotron API, Gemma 4, Ollama Cloud 지원 추가',
    targetAntiPatterns: ['H11-H12'],
    reference: 'NVIDIA NIM docs, Gemma 4 docs',
    effect: '3개 신규 제공자 지원',
    timeline: '4-12주', deps: [],
  },
  {
    id: 'P7', area: 'Monitoring & Observability',
    goal: 'usage tokens 복원, capability drift 감지, per-provider metrics',
    targetAntiPatterns: ['S05', 'H10-H12'],
    reference: 'Claude Code metrics',
    effect: 'provider API 변경 시 24시간 이내 감지',
    timeline: '4-16주', deps: [],
  },
]

export type Applicability = 'full' | 'partial' | 'none' | 'na'

export const APPLICABILITY_MATRIX: Record<RoadmapPhase, Record<string, Applicability>> = {
  P0: { openai:'full',claude:'full',gemini:'full',deepseek:'full',qwen36:'full',mistral:'full',ollama:'full',llamacpp:'full',glm:'full',nemotron:'full',kimi:'full',gemini_cli:'partial',codex_cli:'partial' },
  P1: { openai:'full',claude:'full',gemini:'full',deepseek:'full',qwen36:'full',mistral:'full',ollama:'full',llamacpp:'full',glm:'full',nemotron:'full',kimi:'full',gemini_cli:'full',codex_cli:'full' },
  P2: { openai:'na',claude:'na',gemini:'na',deepseek:'na',qwen36:'na',mistral:'na',ollama:'full',llamacpp:'na',glm:'na',nemotron:'na',kimi:'na',gemini_cli:'full',codex_cli:'full' },
  P3: { openai:'full',claude:'full',gemini:'full',deepseek:'full',qwen36:'full',mistral:'partial',ollama:'full',llamacpp:'full',glm:'partial',nemotron:'full',kimi:'partial',gemini_cli:'na',codex_cli:'na' },
  P4: { openai:'full',claude:'none',gemini:'full',deepseek:'partial',qwen36:'partial',mistral:'full',ollama:'full',llamacpp:'full',glm:'partial',nemotron:'partial',kimi:'partial',gemini_cli:'none',codex_cli:'none' },
  P5: { openai:'full',claude:'full',gemini:'full',deepseek:'full',qwen36:'full',mistral:'full',ollama:'full',llamacpp:'full',glm:'full',nemotron:'full',kimi:'full',gemini_cli:'full',codex_cli:'full' },
  P6: { openai:'na',claude:'na',gemini:'na',deepseek:'na',qwen36:'na',mistral:'na',ollama:'na',llamacpp:'na',glm:'na',nemotron:'full',kimi:'na',gemini_cli:'na',codex_cli:'na' },
  P7: { openai:'full',claude:'full',gemini:'full',deepseek:'full',qwen36:'full',mistral:'full',ollama:'full',llamacpp:'full',glm:'full',nemotron:'full',kimi:'full',gemini_cli:'full',codex_cli:'full' },
}

export function applicabilitySymbol(a: Applicability): string {
  switch (a) {
    case 'full': return '✅'
    case 'partial': return '⚠️'
    case 'none': return '❌'
    case 'na': return '—'
  }
}

export function applicabilityCellClass(a: Applicability): string {
  switch (a) {
    case 'full': return 'z4'
    case 'partial': return 'z2'
    case 'none': return 'z0'
    case 'na': return 'z0'
  }
}

export function phaseColor(id: RoadmapPhase): string {
  const idx = ROADMAP_ITEMS.findIndex(r => r.id === id)
  if (idx <= 1) return 'bg-[var(--ok-10)] text-[var(--color-status-ok)] border-[var(--ok-20)]'
  if (idx <= 4) return 'bg-[var(--warn-10)] text-[var(--color-status-warn)] border-[var(--warn-20)]'
  return 'bg-[var(--white-4)] text-[var(--color-fg-secondary)] border-[var(--color-border-default)]'
}

// ── Phase Timeline (sec07 Table 7-1) ──────────────────────────

export interface PhaseMilestone {
  week: string
  phase: string
  work: string
  deliverable: string
  deps: string
}

export const PHASE_TIMELINE: PhaseMilestone[] = [
  { week: '0–1', phase: 'Phase 1', work: 'P0-1: Function Calling Harness 핵심 루프', deliverable: 'ToolValidationLoop 모듈, 최대 3회 retry', deps: '—' },
  { week: '1–2', phase: 'Phase 1', work: 'P0-2: PPX 기반 컴파일 시점 타입-스키마 검증', deliverable: 'SchemaViolationError 타입', deps: 'P0-1' },
  { week: '2–3', phase: 'Phase 1', work: 'P0-3: Per-provider 통합 테스트 스위트 (13 provider × 5 scenario)', deliverable: 'Integration test suite', deps: 'P0-1' },
  { week: '3–4', phase: 'Phase 1', work: 'P5-1: S01–S05, F01–F02 안티패턴 제거', deliverable: 'CapabilityDrop, FallbackTriggered 이벤트', deps: 'P0-1' },
  { week: '4–5', phase: 'Phase 2', work: 'P1-1: cache_control 자동화', deliverable: 'system/tool cache 삽입 최적화', deps: 'Phase 1' },
  { week: '5–6', phase: 'Phase 2', work: 'P1-2: Context Reducer ceiling (target = max_tokens × 0.5)', deliverable: '동적 compaction budget, 최근 4turn 보존', deps: 'P1-1' },
  { week: '6–7', phase: 'Phase 2', work: 'P3-1: thinking_control_format 4-variant capability', deliverable: '25필드 capability 레코드, 문자열 매칭 제거', deps: 'Phase 1' },
  { week: '7–8', phase: 'Phase 2', work: 'P3-2: Provider별 thinking 직렬화 표준화', deliverable: 'thinking_config 공통 타입, wire format 매핑', deps: 'P3-1' },
  { week: '8–9', phase: 'Phase 3', work: 'P2-1: CLI Provider MCP 활성화', deliverable: 'validate strict mode, cross-tool context', deps: 'Phase 1' },
  { week: '9–10', phase: 'Phase 3', work: 'P2-2: Ollama runtime tool discovery (/api/show)', deliverable: '동적 ollama_capabilities 오버라이드', deps: 'P2-1' },
  { week: '10–11', phase: 'Phase 3', work: 'P6-1: Nemotron API, Gemma 4 추가', deliverable: '2개 신규 capability 집합', deps: 'Phase 1' },
  { week: '11–12', phase: 'Phase 3', work: 'P6-2: Ollama Cloud + ToolResult schema validation', deliverable: 'Ollama Cloud 지원, ToolResultValidationError', deps: 'P6-1, P2-2' },
  { week: '12–13', phase: 'Phase 4', work: 'P4-1: supports_seed, supports_seed_with_images', deliverable: '27필드 capability 레코드', deps: 'Phase 1–2' },
  { week: '13–14', phase: 'Phase 4', work: 'P4-2: temperature=0 한계 문서화, 이미지 seed 무효화', deliverable: '결정론 제한 경고 (warn_once)', deps: 'P4-1' },
  { week: '14–15', phase: 'Phase 4', work: 'P7-1: Usage tokens 복원 + Capability drift 감지', deliverable: 'Usage 추출, CapabilityDriftAlert', deps: 'Phase 1–3' },
  { week: '15–16', phase: 'Phase 4', work: 'P7-3: Per-provider metrics, Grafana 대시보드', deliverable: '5개 메트릭 OTLP, 대시보드', deps: 'P7-2' },
]

export const PHASE_COLORS: Record<string, string> = {
  'Phase 1': 'bg-[var(--ok-10)] text-[var(--color-status-ok)]',
  'Phase 2': 'bg-[var(--warn-10)] text-[var(--color-status-warn)]',
  'Phase 3': 'bg-[var(--info-soft)] text-[var(--color-status-info)]',
  'Phase 4': 'bg-[var(--white-4)] text-[var(--color-fg-secondary)]',
}

export const RESOURCE_ALLOCATION = [
  { track: 'OAS 코어 수정', scope: 'Backend 직렬화/파싱, Capabilities, Config', headcount: 2, pct: ['100%', '80%', '50%', '30%'] },
  { track: 'MASC 확장', scope: 'Provider_tool_support, Cascade, Metrics', headcount: 1, pct: ['50%', '80%', '100%', '80%'] },
  { track: '인프라', scope: 'Integration test, CI/CD, Grafana, Prometheus', headcount: 1, pct: ['80%', '100%', '100%', '100%'] },
]

// ── Success Metrics (sec07 §7.3) ──────────────────────────────
// Three cross-cutting success indicators for the 16-week roadmap.

export interface SuccessMetric {
  id: string
  title: string
  target: string
  description: string
  phases: Record<string, string>
}

export const SUCCESS_METRICS: SuccessMetric[] = [
  {
    id: 'bfcl-accuracy',
    title: 'BFCL 90%+ Tool Use Accuracy',
    target: '90%',
    description: '주요 6개 제공자(OpenAI, Claude, Gemini, DeepSeek, Qwen, Mistral)의 OAS 파이프라인 정확도. 모델 자체 성능이 아닌 직렬화→전송→파싱→검증 파이프라인의 정확도를 측정.',
    phases: {
      'Phase 1': '13 providers × 5 scenario = 65 test cases 100% pass',
      'Phase 2': 'thinking 복합 스키마 검증 성공률 95%+',
      'Phase 3': 'CLI Provider MCP E2E 성공률 100%, 신규 3 provider 통합 테스트 100%',
      'Phase 4': 'BFCL V4 Simple/Parallel/Relevance 6 provider 전체 90%+',
    },
  },
  {
    id: 'zero-silent-failure',
    title: 'Zero Silent Failure',
    target: '0건',
    description: '모든 비정상 동작이 WARN+ 로그 레벨로 기록, Prometheus 메트릭이나 structured event로 포착. masc_capability_drop_total, masc_fallback_triggered_total counter 기준.',
    phases: {
      'Phase 1': 'S01–S05 (5건) Silent Failure 완전 제거 → counter 증가 0',
      'Phase 2': 'S06–S08 제거, F01–F04 Fake Fallback 제거',
      'Phase 3': 'S09–S10 제거, M01–M06 String Match 중 3건 제거',
      'Phase 4': '잔여 안티패턴 제거 완료 (28/32 = 87.5%), Grafana "Zero Silent Failure" panel OK',
    },
  },
  {
    id: 'capability-accuracy',
    title: 'Capability Accuracy 100%',
    target: '100%',
    description: 'Llm_provider.Capabilities 레코드 각 필드가 실제 API 동작과 일치. capability_mismatch rejection 비율 < 1%.',
    phases: {
      'Phase 1': 'supports_tools, supports_tool_choice 통합 테스트 100% pass',
      'Phase 2': 'thinking_control_format 4-variant 정합성 검증',
      'Phase 3': 'supports_seed, supports_seed_with_images 선언 정합성',
      'Phase 4': 'emits_usage_tokens 정합성 + drift 감지 24h 이내',
    },
  },
]

// ── Shared helpers ──────────────────────────────────────────────

export function supportHeatBucket(v: FeatureSupport): string {
  switch (v) {
    case '●': return 'z4'
    case '◐': return 'z2'
    case '○': return 'z1'
    case '—': return 'z0'
  }
}

export function riskBucket(risk: RiskLevel): string {
  switch (risk) {
    case 'C': return 'z4'
    case 'H': return 'z3'
    case 'M': return 'z2'
    case 'L': return 'z1'
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

export type WiringImpact = 'high' | 'medium' | 'low' | 'correct'

export function impactBucket(impact: WiringImpact): string {
  switch (impact) {
    case 'high': return 'z4'
    case 'medium': return 'z2'
    case 'low': return 'z1'
    case 'correct': return 'z0'
  }
}

export function impactTone(impact: WiringImpact): 'bad' | 'warn' | 'neutral' | 'info' {
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

export const SOURCE_LABEL: Record<AntiPatternSource, string> = {
  'masc-mcp': 'MASC',
  oas: 'OAS',
  unverified: '미검증',
}

export function sourceColor(src: AntiPatternSource): string {
  switch (src) {
    case 'masc-mcp': return 'bg-[var(--info-soft)] text-[var(--color-status-info)] border-[var(--info-border)]'
    case 'oas': return 'bg-[var(--ok-10)] text-[var(--color-status-ok)] border-[var(--ok-20)]'
    case 'unverified': return 'bg-[var(--warn-10)] text-[var(--color-status-warn)] border-[var(--warn-20)]'
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
  dashscope: 'qwen36',
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
  qwen: 'qwen36',
  qwen35: 'qwen36',
  qwen36: 'qwen36',
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
  if (key.includes('dashscope') || key.includes('qwen')) return 'qwen36'
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
