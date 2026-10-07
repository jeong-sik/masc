import { html } from 'htm/preact'
import { useState } from 'preact/hooks'

export function parseJsonLikeData(data: unknown): unknown {
  if (typeof data !== 'string') return data
  const trimmed = data.trim()
  if (!(trimmed.startsWith('{') || trimmed.startsWith('['))) return data
  try {
    return JSON.parse(trimmed)
  } catch {
    return data
  }
}

// A single long string rendered whole (the 160M-char curator raw_response
// incident) — or a container with tens of thousands of entries — floods the
// DOM and freezes the whole page. Both limits are render guards only: the
// data itself is passed through untouched.
const MAX_STRING_CHARS = 4_000
const STRING_PREVIEW_CHARS = 1_200
const MAX_RENDERED_ITEMS = 200

function LongStringLeaf({ data, label }: { data: string; label?: string }) {
  const [expanded, setExpanded] = useState(false)
  const labelNode = label
    ? html`<span class="text-[var(--color-fg-primary)] shrink-0 font-medium whitespace-nowrap">${label}:</span>`
    : null
  if (!expanded) {
    const head = data.slice(0, STRING_PREVIEW_CHARS)
    const tail = data.length > STRING_PREVIEW_CHARS + STRING_PREVIEW_CHARS
      ? ` … ${data.slice(-STRING_PREVIEW_CHARS)}`
      : data.slice(STRING_PREVIEW_CHARS)
    return html`
      <div class="font-mono text-sm leading-relaxed flex items-start gap-1.5 py-0.5 min-w-0 max-w-full">
        ${labelNode}
        <div class="min-w-0 break-words">
          <span class="text-[var(--color-status-ok)] whitespace-pre-wrap break-words">"${head}${tail}"</span>
          <button
            type="button"
            class="cursor-pointer hover:bg-[var(--color-bg-elevated)] rounded-[var(--r-1)] px-1 ml-2 select-none text-left bg-transparent border-0 text-[var(--color-accent)]"
            onClick=${() => setExpanded(true)}
            aria-label=${`Expand ${data.length.toLocaleString()}-character string`}
          >
            전체 ${data.length.toLocaleString()}자 보기
          </button>
        </div>
      </div>
    `
  }
  return html`
    <div class="font-mono text-sm leading-relaxed flex items-start gap-1.5 py-0.5 min-w-0 max-w-full">
      ${labelNode}
      <div class="min-w-0 break-words">
        <span class="text-[var(--color-status-ok)] whitespace-pre-wrap break-words">"${data}"</span>
        <button
          type="button"
          class="cursor-pointer hover:bg-[var(--color-bg-elevated)] rounded-[var(--r-1)] px-1 ml-2 select-none text-left bg-transparent border-0 text-[var(--color-accent)]"
          onClick=${() => setExpanded(false)}
          aria-label="Collapse string"
        >
          접기
        </button>
      </div>
    </div>
  `
}

export function JsonViewer({ data, label, initialCollapsed = false, collapseNested = true, level = 0, ancestors = [] }: { data: unknown; label?: string; initialCollapsed?: boolean; collapseNested?: boolean; level?: number; ancestors?: object[] }) {
  const [collapsed, setCollapsed] = useState(initialCollapsed)

  const isObject = data !== null && typeof data === 'object'
  const isArray = Array.isArray(data)

  if (isObject && ancestors.includes(data as object)) {
    return html`
      <div class="font-mono text-sm leading-relaxed flex items-start gap-1.5 py-0.5 min-w-0 max-w-full">
        ${label ? html`<span class="text-[var(--color-fg-primary)] shrink-0 font-medium whitespace-nowrap">${label}:</span>` : null}
        <span class="text-[var(--color-fg-muted)] italic">[Circular]</span>
      </div>
    `
  }

  if (!isObject) {
    let valueNode
    if (typeof data === 'string') {
      if ((data as string).length > MAX_STRING_CHARS) {
        return html`<${LongStringLeaf} data=${data as string} label=${label} />`
      }
      valueNode = html`<span class="text-[var(--color-status-ok)] whitespace-pre-wrap break-words">"${data}"</span>`
    } else if (typeof data === 'number') {
      valueNode = html`<span class="text-[var(--color-status-warn)]">${data}</span>`
    } else if (typeof data === 'boolean') {
      valueNode = html`<span class="text-[var(--rose-light)]">${data ? 'true' : 'false'}</span>`
    } else if (data === null) {
      valueNode = html`<span class="text-[var(--color-fg-muted)] italic">null</span>`
    } else {
      valueNode = html`<span class="text-[var(--color-fg-muted)]">${String(data)}</span>`
    }

    return html`
      <div class="font-mono text-sm leading-relaxed flex items-start gap-1.5 py-0.5 min-w-0 max-w-full">
        ${label ? html`<span class="text-[var(--color-fg-primary)] shrink-0 font-medium whitespace-nowrap">${label}:</span>` : null}
        <div class="min-w-0 break-words">${valueNode}</div>
      </div>
    `
  }

  const entries = isArray ? (data as unknown[]) : Object.entries(data as Record<string, unknown>)
  const isEmpty = isArray ? (data as unknown[]).length === 0 : entries.length === 0
  const nextAncestors = isObject ? [...ancestors, data as object] : ancestors
  const toggleLabel = label ?? (isArray ? 'JSON array' : 'JSON object')

  if (isEmpty) {
    return html`
      <div class="font-mono text-sm leading-relaxed flex items-start gap-1.5 py-0.5">
        ${label ? html`<span class="text-[var(--color-fg-primary)] shrink-0 font-medium whitespace-nowrap">${label}:</span>` : null}
        <span class="text-[var(--color-fg-muted)]">${isArray ? '[]' : '{}'}</span>
      </div>
    `
  }

  return html`
    <div class="font-mono text-sm leading-relaxed flex flex-col py-0.5 w-full min-w-0">
      <button
        type="button"
        class="flex items-center gap-1.5 cursor-pointer hover:bg-[var(--color-bg-elevated)] rounded-[var(--r-1)] px-1 -mx-1 select-none w-max max-w-full text-left bg-transparent border-0"
        onClick=${() => setCollapsed(!collapsed)}
        aria-expanded=${!collapsed}
        aria-label=${`${collapsed ? 'Expand' : 'Collapse'} ${toggleLabel}`}
      >
        <span aria-hidden="true" class="text-[var(--color-fg-muted)] shrink-0 w-4 inline-flex justify-center transition-transform duration-[var(--t-fast)] ${collapsed ? '-rotate-90' : ''}">▼</span>
        ${label ? html`<span class="text-[var(--color-fg-primary)] font-medium truncate">${label}</span>` : null}
        <span class="text-[var(--color-fg-muted)] text-2xs ml-1 shrink-0">
          ${isArray ? `[${(data as unknown[]).length}]` : `{${entries.length}}`}
        </span>
      </button>

      ${!collapsed && html`
        <div class="pl-4 ml-1.5 border-l border-[var(--color-border-divider)] mt-1 flex flex-col gap-0.5 w-full min-w-0">
          ${(isArray
            ? (data as unknown[]).slice(0, MAX_RENDERED_ITEMS)
            : (entries as [string, unknown][]).slice(0, MAX_RENDERED_ITEMS)
          ).map((entry, idx) => {
            const [key, val] = isArray ? [String(idx), entry] : (entry as [string, unknown])
            return html`<${JsonViewer} key=${key} data=${val} label=${key} level=${level + 1} initialCollapsed=${collapseNested && level >= 2} collapseNested=${collapseNested} ancestors=${nextAncestors} />`
          })}
          ${(isArray ? (data as unknown[]).length : entries.length) > MAX_RENDERED_ITEMS
            ? html`<div class="text-[var(--color-fg-muted)] text-2xs py-0.5">… 나머지 ${((isArray ? (data as unknown[]).length : entries.length) - MAX_RENDERED_ITEMS).toLocaleString()}개 항목 미표시 (렌더 방어)</div>`
            : null}
        </div>
      `}
    </div>
  `
}

export function JsonViewerCard({ data, title, expandAll = false }: { data: unknown; title?: string; expandAll?: boolean }) {
  return html`
    <div class="bg-[var(--color-bg-page)] border border-[var(--color-border-default)] rounded-[var(--r-1)] overflow-hidden flex flex-col max-h-100" data-testid="json-viewer-card" data-title=${title ?? ''}>
      ${title ? html`<div class="px-3 py-2 border-b border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-2xs uppercase tracking-wider font-semibold text-[var(--color-fg-muted)]">${title}</div>` : null}
      <div class="p-3 overflow-y-auto min-h-0 w-full">
        <${JsonViewer} data=${data} collapseNested=${!expandAll} />
      </div>
    </div>
  `
}
