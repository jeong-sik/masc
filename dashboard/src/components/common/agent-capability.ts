// AgentCapability — AX molecule that renders an agent's tool set.
//
// Kimi design system sec05 reference: icon + tooltip badges for each tool
// an agent can use. The compact badge row lets operators quickly scan
// an agent's capability envelope without opening a detail panel.
//
// Icons are text/emoji placeholders (Kimi spec uses emoji). Production
// code should swap the icon field for an SVG icon map when an icon
// library is adopted.

import { html } from 'htm/preact'

interface ToolConfig {
  icon: string
  label: string
  description: string
}

const TOOL_CONFIG: Record<string, ToolConfig> = {
  file_read: { icon: '\u{1F4C4}', label: '파일 읽기', description: '로컬 파일 시스템 읽기' },
  file_write: { icon: '\u{270F}\u{FE0F}', label: '파일 쓰기', description: '로컬 파일 시스템 쓰기' },
  shell: { icon: '\u{1F4BB}', label: '터미널', description: '셸 명령 실행' },
  web_search: { icon: '\u{1F50D}', label: '웹 검색', description: '인터넷 검색' },
  db_query: { icon: '\u{1F5C3}\u{FE0F}', label: 'DB 쿼리', description: '데이터베이스 조회' },
  api_call: { icon: '\u{1F50C}', label: 'API 호출', description: '외부 API 호출' },
}

/** Pure: lookup a tool's display config. Falls back to a generic
    representation for unknown tools so the UI never renders blank. */
export function toolConfig(tool: string): ToolConfig {
  return (
    TOOL_CONFIG[tool] ?? {
      icon: '\u{2699}\u{FE0F}',
      label: tool,
      description: `${tool} 도구`,
    }
  )
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

interface AgentCapabilityProps {
  tools: Array<string | null | undefined> | null | undefined
  maxVisible?: number
  testId?: string
}

const BASE_BADGE =
  'inline-flex items-center rounded-[var(--r-0)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-3xs text-[var(--color-fg-primary)] transition-colors hover:bg-[var(--color-bg-elevated)]'

export function AgentCapability({
  tools,
  maxVisible = 4,
  testId,
}: AgentCapabilityProps) {
  const normalized = normalizeTools(tools)
  const visible = normalized.slice(0, maxVisible)
  const extra = Math.max(0, normalized.length - maxVisible)

  if (visible.length === 0 && extra === 0) {
    return html`
      <span
        class="inline-flex items-center rounded-[var(--r-0)] border border-dashed border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-3xs text-[var(--color-fg-muted)]"
        data-agent-capability
        data-testid=${testId}
      >
        도구 없음
      </span>
    `
  }

  return html`
    <div class="flex flex-wrap items-center gap-1.5" data-agent-capability data-testid=${testId}>
      ${visible.map(
        tool => {
          const cfg = toolConfig(tool)
          return html`
            <span
              class=${BASE_BADGE}
              title=${cfg.description}
              data-tool=${tool}
            >
              <span aria-hidden="true">${cfg.icon}</span>
              <span class="ml-1">${cfg.label}</span>
            </span>
          `
        },
      )}
      ${extra > 0
        ? html`
            <span
              class="inline-flex items-center rounded-[var(--r-0)] border border-dashed border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-2 py-0.5 text-3xs text-[var(--color-fg-muted)]"
              title="${normalized.slice(maxVisible).join(', ')}"
            >
              +${extra}
            </span>
          `
        : null}
    </div>
  `
}
