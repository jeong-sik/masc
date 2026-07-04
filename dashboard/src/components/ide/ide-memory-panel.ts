import { html } from 'htm/preact'
import { useEffect, useState, useCallback } from 'preact/hooks'
import { MemoryLens } from '../memory/memory-lens'
import type { MemoryLensProps } from '../memory/memory-lens'

interface MemoryEntry {
  readonly id: string
  readonly kind: string
  readonly content: string
  readonly file_path: string
  readonly line_start: number
  readonly line_end: number
  readonly keeper_id: string
  readonly created_at_ms: number
  readonly source_kind?: string
  readonly retrieval_status?: string
  readonly goal_id: string | null
  readonly task_id: string | null
}

interface MemoryContract {
  readonly source_kind?: string
  readonly retrieval_status?: string
  readonly semantic_memory_status?: string
  readonly episodic_memory_status?: string
}

interface MemoryResponse {
  readonly entries: ReadonlyArray<MemoryEntry>
  readonly total: number
  readonly limit: number
  readonly contract?: MemoryContract
}

interface IdeMemoryPanelProps {
  readonly keeperName?: string | null
  readonly repoId?: string | null
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

function memorySourceLabel(sourceKind?: string): string {
  switch (sourceKind) {
    case 'ide_annotation':
      return 'annotation'
    case 'semantic_memory':
      return 'semantic'
    case 'episodic_memory':
      return 'episode'
    case undefined:
    case '':
      return 'unknown'
    default:
      return sourceKind
  }
}

function memoryStatusLabel(status?: string): string {
  switch (status) {
    case 'annotation_index_only':
      return 'annotation index'
    case 'not_configured':
      return 'not configured'
    case undefined:
    case '':
      return 'unknown'
    default:
      return status
  }
}

const LENS_NODE_TYPES: MemoryLensProps['nodeTypes'] = {
  memory: { kr: '기억', g: '◆', c: 'var(--volt)' },
  goal: { kr: '골', g: '◎', c: 'var(--accent-ice)' },
  task: { kr: '태스크', g: '▣', c: 'var(--status-ok)' },
  board: { kr: '보드', g: '◈', c: '#8a6cf0' },
}

function buildLensGraph(entries: ReadonlyArray<MemoryEntry>): {
  nodes: MemoryLensProps['nodes']
  edges: MemoryLensProps['edges']
  start: string
} {
  const nodes: Record<string, MemoryLensProps['nodes'][string]> = {}
  const edges: Array<{ source: string; target: string; rel: string }> = []

  for (const entry of entries) {
    nodes[entry.id] = {
      type: 'memory',
      title: entry.content.length > 80 ? `${entry.content.slice(0, 80)}...` : entry.content,
      kp: entry.keeper_id || 'unknown',
      meta: entry.kind,
      ns: `${entry.file_path}:${entry.line_start}`,
    }

    if (entry.goal_id) {
      if (!nodes[entry.goal_id]) {
        nodes[entry.goal_id] = {
          type: 'goal',
          title: `Goal ${entry.goal_id}`,
          kp: entry.keeper_id || 'unknown',
          meta: 'linked',
          ns: 'goal',
        }
      }
      edges.push({ source: entry.id, target: entry.goal_id, rel: 'goal' })
    }

    if (entry.task_id) {
      if (!nodes[entry.task_id]) {
        nodes[entry.task_id] = {
          type: 'task',
          title: `Task ${entry.task_id}`,
          kp: entry.keeper_id || 'unknown',
          meta: 'linked',
          ns: 'task',
        }
      }
      edges.push({ source: entry.id, target: entry.task_id, rel: 'task' })
    }
  }

  return { nodes, edges, start: entries[0]!.id }
}

export function IdeMemoryPanel({ keeperName, repoId }: IdeMemoryPanelProps) {
  const [entries, setEntries] = useState<ReadonlyArray<MemoryEntry>>([])
  const [total, setTotal] = useState(0)
  const [contract, setContract] = useState<MemoryContract | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const fetchMemory = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const params = new URLSearchParams()
      if (keeperName) params.set('keeper_id', keeperName)
      if (repoId) params.set('repo_id', repoId)
      params.set('limit', '50')
      const res = await fetch(`/api/v1/ide/memory?${params}`)
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const data: MemoryResponse = await res.json()
      setEntries(data.entries)
      setTotal(data.total)
      setContract(data.contract ?? null)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Failed to load')
    } finally {
      setLoading(false)
    }
  }, [keeperName, repoId])

  useEffect(() => {
    fetchMemory()
  }, [fetchMemory])

  const sourceKind = contract?.source_kind ?? entries[0]?.source_kind
  const retrievalStatus = contract?.retrieval_status ?? entries[0]?.retrieval_status
  const semanticStatus = contract?.semantic_memory_status

  return html`
    <div class="ide-memory-panel v2-ide-panel" data-testid="ide-memory-panel">
      <div class="ide-memory-panel__header">
        <span class="ide-memory-panel__title">Memory</span>
        <span>
          <span class="ide-memory-panel__source" title="Memory source">
            source:${memorySourceLabel(sourceKind)}
          </span>
          <span class="ide-memory-panel__source" title="Semantic memory status">
            semantic:${memoryStatusLabel(semanticStatus)}
          </span>
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
                        <span class="ide-memory-panel__source">
                          ${memorySourceLabel(entry.source_kind ?? sourceKind)}
                        </span>
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
                        <span class="ide-memory-panel__tag">
                          retrieval:${memoryStatusLabel(entry.retrieval_status ?? retrievalStatus)}
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

              ${(() => {
                const { nodes, edges, start } = buildLensGraph(entries)
                return html`
                  <div class="ide-memory-panel__lens v2-ide-section" data-testid="ide-memory-lens">
                    <${MemoryLens}
                      nodes=${nodes}
                      edges=${edges}
                      nodeTypes=${LENS_NODE_TYPES}
                      start=${start}
                      W=${520}
                      H=${360}
                      ariaLabel="IDE 메모리 연결 렌즈"
                    />
                  </div>
                `
              })()}
            `}
    </div>
  `
}
