import { html } from 'htm/preact'
import { useEffect, useState, useCallback } from 'preact/hooks'

interface MemoryEntry {
  readonly id: string
  readonly kind: string
  readonly content: string
  readonly file_path: string
  readonly line_start: number
  readonly line_end: number
  readonly keeper_id: string
  readonly created_at_ms: number
  readonly goal_id: string | null
  readonly task_id: string | null
}

interface MemoryResponse {
  readonly entries: ReadonlyArray<MemoryEntry>
  readonly total: number
  readonly limit: number
}

interface IdeMemoryPanelProps {
  readonly keeperName?: string | null
}

const KIND_COLORS: Record<string, string> = {
  Comment: 'var(--tone-info, #6b7280)',
  Decision: 'var(--tone-ok, #10b981)',
  Question: 'var(--tone-warn, #f59e0b)',
  Bookmark: 'var(--tone-brass, #d97706)',
}

function formatTimestamp(ms: number): string {
  const date = new Date(ms)
  const now = new Date()
  const diffMs = now.getTime() - date.getTime()
  const diffMin = Math.floor(diffMs / 60_000)
  if (diffMin < 1) return 'just now'
  if (diffMin < 60) return `${diffMin}m ago`
  const diffHr = Math.floor(diffMin / 60)
  if (diffHr < 24) return `${diffHr}h ago`
  return date.toLocaleDateString()
}

export function IdeMemoryPanel({ keeperName }: IdeMemoryPanelProps) {
  const [entries, setEntries] = useState<ReadonlyArray<MemoryEntry>>([])
  const [total, setTotal] = useState(0)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const fetchMemory = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const params = new URLSearchParams()
      if (keeperName) params.set('keeper_id', keeperName)
      params.set('limit', '50')
      const res = await fetch(`/api/v1/ide/memory?${params}`)
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const data: MemoryResponse = await res.json()
      setEntries(data.entries)
      setTotal(data.total)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load')
    } finally {
      setLoading(false)
    }
  }, [keeperName])

  useEffect(() => {
    fetchMemory()
  }, [fetchMemory])

  return html`
    <div class="ide-memory-panel v2-ide-panel" data-testid="ide-memory-panel">
      <div class="ide-memory-panel__header">
        <span class="ide-memory-panel__title">Memory</span>
        <span>
          <button
            class="ide-memory-panel__refresh v2-ide-action"
            onClick=${fetchMemory}
            disabled=${loading}
            title="Refresh memory entries"
          >↻</button>
          <span class="ide-memory-panel__count">${total}</span>
        </span>
      </div>
      ${loading
        ? html`<div class="ide-memory-panel__loading">Loading...</div>`
        : error
          ? html`<div class="ide-memory-panel__error">${error}</div>`
          : entries.length === 0
            ? html`<div class="ide-memory-panel__empty">No memory entries</div>`
            : html`
              <div class="ide-memory-panel__list">
                ${entries.map(
                  (entry) => html`
                    <div
                      class="ide-memory-panel__entry v2-ide-row"
                      key=${entry.id}
                      data-kind=${entry.kind}
                    >
                      <div class="ide-memory-panel__entry-header">
                        <span
                          class="ide-memory-panel__kind"
                          style=${{ color: KIND_COLORS[entry.kind] ?? 'inherit' }}
                        >${entry.kind}</span>
                        <span class="ide-memory-panel__time">
                          ${formatTimestamp(entry.created_at_ms)}
                        </span>
                      </div>
                      <div class="ide-memory-panel__content">
                        ${entry.content.length > 120
                          ? entry.content.slice(0, 120) + '...'
                          : entry.content}
                      </div>
                      <div class="ide-memory-panel__meta">
                        <span class="ide-memory-panel__file">
                          ${entry.file_path}:${entry.line_start}
                        </span>
                        ${entry.goal_id
                          ? html`<span class="ide-memory-panel__tag">goal:${entry.goal_id}</span>`
                          : null}
                        ${entry.task_id
                          ? html`<span class="ide-memory-panel__tag">task:${entry.task_id}</span>`
                          : null}
                      </div>
                    </div>
                  `,
                )}
              </div>
            `}
    </div>
  `
}
