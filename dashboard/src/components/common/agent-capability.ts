// AgentCapability — AX molecule that renders an agent's tool set.
//
// Kimi design system sec05 reference: icon + tooltip badges for each tool
// an agent can use. The compact badge row lets operators quickly scan
// an agent's capability envelope without opening a detail panel.
//
// Cockpit treatment uses compact mono glyphs instead of emoji/icon-library
// placeholders so capability affordances stay dense and operator-readable.

import { html } from 'htm/preact'

export type CapabilityGlyph = 'RD' | 'WR' | 'SH' | 'SR' | 'DB' | 'API' | 'TL'

export interface ToolConfig {
  glyph: CapabilityGlyph
  label: string
  description: string
}

const TOOL_CONFIG = Object.freeze({
  file_read: { glyph: 'RD', label: '파일 읽기', description: '로컬 파일 시스템 읽기' },
  file_write: { glyph: 'WR', label: '파일 쓰기', description: '로컬 파일 시스템 쓰기' },
  shell: { glyph: 'SH', label: '터미널', description: '셸 명령 실행' },
  web_search: { glyph: 'SR', label: '웹 검색', description: '인터넷 검색' },
  db_query: { glyph: 'DB', label: 'DB 쿼리', description: '데이터베이스 조회' },
  api_call: { glyph: 'API', label: 'API 호출', description: '외부 API 호출' },
} satisfies Record<string, ToolConfig>)

function hasToolConfig(tool: string): tool is keyof typeof TOOL_CONFIG {
  return Object.prototype.hasOwnProperty.call(TOOL_CONFIG, tool)
}

/** Pure: lookup a tool's display config. Falls back to a generic
    representation for unknown tools so the UI never renders blank. */
export function toolConfig(tool: string): ToolConfig {
  if (hasToolConfig(tool)) return TOOL_CONFIG[tool]
  return {
    glyph: 'TL',
    label: tool,
    description: `${tool} 도구`,
  }
}

/** Pure: filter + deduplicate tool names, preserving order. */
export function normalizeTools(
  tools: Array<string | null | undefined> | null | undefined,
): string[] {
  if (!tools) return []
  const seen = new Set<string>()
  const out: string[] = []
  for (const t of tools) {
    const name = t?.trim()
    if (!name || seen.has(name)) continue
    seen.add(name)
    out.push(name)
  }
  return out
}

export interface CapabilityItemSummary {
  tool: string
  glyph: CapabilityGlyph
  label: string
  description: string
  known: boolean
  index: number
}

export interface AgentCapabilitySummary {
  tools: string[]
  visible: CapabilityItemSummary[]
  hidden: string[]
  count: number
  visibleCount: number
  extraCount: number
  empty: boolean
  maxVisible: number
  hiddenLabel: string
}

export function summarizeAgentCapability(
  tools: Array<string | null | undefined> | null | undefined,
  maxVisible = 4,
): AgentCapabilitySummary {
  const normalized = normalizeTools(tools)
  const limit = Math.max(0, Math.floor(maxVisible))
  const visibleTools = normalized.slice(0, limit)
  const hidden = normalized.slice(limit)
  const visible = visibleTools.map((tool, index) => {
    const cfg = toolConfig(tool)
    return {
      tool,
      glyph: cfg.glyph,
      label: cfg.label,
      description: cfg.description,
      known: hasToolConfig(tool),
      index,
    }
  })

  return {
    tools: normalized,
    visible,
    hidden,
    count: normalized.length,
    visibleCount: visible.length,
    extraCount: hidden.length,
    empty: normalized.length === 0,
    maxVisible: limit,
    hiddenLabel: hidden.join(', '),
  }
}

interface AgentCapabilityProps {
  tools: Array<string | null | undefined> | null | undefined
  maxVisible?: number
  testId?: string
}

const BASE_BADGE =
  'inline-flex min-w-0 max-w-full items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-3xs text-[var(--color-fg-primary)] transition-colors hover:bg-[var(--color-bg-elevated)]'

const GLYPH_BADGE =
  'mr-1 inline-flex h-4 min-w-4 shrink-0 items-center justify-center rounded-[var(--r-0)] border border-[var(--color-border-subtle)] bg-[var(--color-bg-elevated)] px-1 font-mono text-[9px] font-semibold leading-none text-[var(--color-accent-fg)]'

export function AgentCapability({
  tools,
  maxVisible = 4,
  testId,
}: AgentCapabilityProps) {
  const summary = summarizeAgentCapability(tools, maxVisible)

  if (summary.empty) {
    return html`
      <span
        class="inline-flex min-w-0 max-w-full items-center rounded-[var(--r-0)] border border-dashed border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-3xs text-[var(--color-fg-muted)]"
        data-agent-capability
        data-capability-count=${summary.count}
        data-capability-visible-count=${summary.visibleCount}
        data-capability-extra-count=${summary.extraCount}
        data-capability-max-visible=${summary.maxVisible}
        data-capability-empty=${summary.empty}
        data-capability-hidden-label=${summary.hiddenLabel}
        data-testid=${testId}
      >
        <span class=${GLYPH_BADGE} aria-hidden="true">TL</span>
        <span class="min-w-0 truncate">도구 없음</span>
      </span>
    `
  }

  return html`
    <div
      class="flex min-w-0 max-w-full flex-wrap items-center gap-1.5"
      data-agent-capability
      data-capability-count=${summary.count}
      data-capability-visible-count=${summary.visibleCount}
      data-capability-extra-count=${summary.extraCount}
      data-capability-max-visible=${summary.maxVisible}
      data-capability-empty=${summary.empty}
      data-capability-hidden-label=${summary.hiddenLabel}
      data-testid=${testId}
    >
      ${summary.visible.map(
        item => html`
          <span
            class=${BASE_BADGE}
            title=${item.description}
            data-tool=${item.tool}
            data-capability-tool=${item.tool}
            data-capability-tool-index=${item.index}
            data-capability-tool-known=${item.known}
            data-capability-tool-label=${item.label}
            data-capability-tool-glyph=${item.glyph}
          >
            <span class=${GLYPH_BADGE} aria-hidden="true">${item.glyph}</span>
            <span class="min-w-0 truncate">${item.label}</span>
          </span>
        `,
      )}
      ${summary.extraCount > 0
        ? html`
            <span
              class="inline-flex min-w-0 max-w-full items-center rounded-[var(--r-0)] border border-dashed border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 font-mono text-3xs text-[var(--color-fg-muted)]"
              title=${summary.hiddenLabel}
              data-capability-extra
              data-capability-extra-count=${summary.extraCount}
            >
              +${summary.extraCount}
            </span>
          `
        : null}
    </div>
  `
}
