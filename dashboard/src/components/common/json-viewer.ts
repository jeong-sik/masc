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

export function JsonViewer({ data, label, initialCollapsed = false, level = 0, ancestors = [] }: { data: unknown; label?: string; initialCollapsed?: boolean; level?: number; ancestors?: object[] }) {
  const [collapsed, setCollapsed] = useState(initialCollapsed)

  const isObject = data !== null && typeof data === 'object'
  const isArray = Array.isArray(data)

  if (isObject && ancestors.includes(data as object)) {
    return html`
      <div class="font-mono text-sm leading-relaxed flex items-start gap-1.5 py-0.5 min-w-0 max-w-full">
        ${label ? html`<span class="text-[var(--text-body)] shrink-0 font-medium whitespace-nowrap">${label}:</span>` : null}
        <span class="text-[var(--text-muted)] italic">[Circular]</span>
      </div>
    `
  }

  if (!isObject) {
    let valueNode
    if (typeof data === 'string') {
      valueNode = html`<span class="text-[var(--ok)] whitespace-pre-wrap break-words">"${data}"</span>`
    } else if (typeof data === 'number') {
      valueNode = html`<span class="text-[var(--warn)]">${data}</span>`
    } else if (typeof data === 'boolean') {
      valueNode = html`<span class="text-[#e27e8d]">${data ? 'true' : 'false'}</span>`
    } else if (data === null) {
      valueNode = html`<span class="text-[var(--text-muted)] italic">null</span>`
    } else {
      valueNode = html`<span class="text-[var(--text-muted)]">${String(data)}</span>`
    }

    return html`
      <div class="font-mono text-sm leading-relaxed flex items-start gap-1.5 py-0.5 min-w-0 max-w-full">
        ${label ? html`<span class="text-[var(--text-body)] shrink-0 font-medium whitespace-nowrap">${label}:</span>` : null}
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
        ${label ? html`<span class="text-[var(--text-body)] shrink-0 font-medium whitespace-nowrap">${label}:</span>` : null}
        <span class="text-[var(--text-muted)]">${isArray ? '[]' : '{}'}</span>
      </div>
    `
  }

  return html`
    <div class="font-mono text-sm leading-relaxed flex flex-col py-0.5 w-full min-w-0">
      <button type="button"
        class="flex items-center gap-1.5 cursor-pointer hover:bg-[var(--white-4)] rounded px-1 -mx-1 select-none w-max max-w-full text-left bg-transparent border-0"
        onClick=${() => setCollapsed(!collapsed)}
        aria-expanded=${!collapsed}
        aria-label=${`${collapsed ? '펼치기' : '접기'} ${toggleLabel}`}
      >
        <span aria-hidden="true" class="text-[var(--text-muted)] shrink-0 w-4 inline-flex justify-center transition-transform duration-150 ${collapsed ? '-rotate-90' : ''}">▼</span>
        ${label ? html`<span class="text-[var(--text-body)] font-medium truncate" title=${label}>${label}</span>` : null}
        <span class="text-[var(--text-muted)] text-2xs ml-1 shrink-0">
          ${isArray ? `[${(data as unknown[]).length}]` : `{${entries.length}}`}
        </span>
      </button>

      ${!collapsed && html`
        <div class="pl-4 ml-1.5 border-l border-[var(--white-4)] mt-1 flex flex-col gap-0.5 w-full min-w-0">
          ${isArray
            ? (data as unknown[]).map((val, idx) => html`<${JsonViewer} key=${idx} data=${val} label=${String(idx)} level=${level + 1} initialCollapsed=${level >= 2} ancestors=${nextAncestors} />`)
            : (entries as [string, unknown][]).map(([k, v]) => html`<${JsonViewer} key=${k} data=${v} label=${k} level=${level + 1} initialCollapsed=${level >= 2} ancestors=${nextAncestors} />`)
          }
        </div>
      `}
    </div>
  `
}

export function JsonViewerCard({ data, title }: { data: unknown; title?: string }) {
  return html`
    <div class="bg-[var(--bg-0)] border border-[var(--card-border)] rounded overflow-hidden flex flex-col max-h-100" role="region" aria-label=${title ?? 'JSON 뷰어'} data-testid="json-viewer-card" data-title=${title ?? ''}>
      ${title ? html`<div class="px-3 py-2 border-b border-[var(--card-border)] bg-[var(--white-3)] text-2xs uppercase tracking-wider font-semibold text-[var(--text-muted)]">${title}</div>` : null}
      <div class="p-3 overflow-y-auto custom-scrollbar min-h-0 w-full">
        <${JsonViewer} data=${data} />
      </div>
    </div>
  `
}
