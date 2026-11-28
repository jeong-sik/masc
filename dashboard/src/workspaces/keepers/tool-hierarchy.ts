/**
 * Pure hierarchical grouping for Keeper tool calls & live open work:
 * - Concurrent parallel tool batches (`cohort.batch_index` or overlapping execution windows)
 *   with wall time vs summed duration, reach badges, and per-tool overlap bars.
 * - Async delegation lifecycles (`masc_keeper_delegate` + `masc_keeper_delegate_status*` +
 *   `masc_keeper_delegate_cancel` sharing `operation_id`) into a collapsible chain node
 *   with repetitive status polls collapsed by default.
 */

import { html } from 'htm/preact'
import type { KeeperToolCallEntry, TurnOpenActivity, TurnToolCohort, TurnToolReach } from './types'

export type ToolReachBadge = '샌드박스' | '외부 · 네트워크' | '모델' | '상태'

export type DelegateToolRole = 'launch' | 'status' | 'cancel'

export interface KeeperToolCallWithMeta extends KeeperToolCallEntry {
  readonly cohort?: TurnToolCohort | null
  readonly batch_index?: number | null
  readonly batch_size?: number | null
  readonly execution_mode?: string | null
  readonly reach?: TurnToolReach | null
}

export interface ParallelBatchMember {
  readonly entry: KeeperToolCallWithMeta
  readonly reach: ToolReachBadge
  readonly startMs: number
  readonly endMs: number
  readonly offsetMs: number
  readonly overlapStartPct: number
  readonly overlapWidthPct: number
}

export interface ParallelBatchGroupNode {
  readonly kind: 'parallel_batch'
  readonly id: string
  readonly batchIndex: number | null
  readonly batchSize: number
  readonly wallTimeMs: number
  readonly summedDurationMs: number
  readonly reaches: readonly ToolReachBadge[]
  readonly members: readonly ParallelBatchMember[]
}

export interface DelegateChainNode {
  readonly kind: 'delegate_chain'
  readonly id: string
  readonly operationId: string
  readonly launch: KeeperToolCallWithMeta | null
  readonly statusPolls: readonly KeeperToolCallWithMeta[]
  readonly cancel: KeeperToolCallWithMeta | null
  readonly totalCalls: number
  readonly wallTimeMs: number
  readonly summedDurationMs: number
  readonly terminalStatus: string
  readonly reach: ToolReachBadge
}

export interface SingleToolNode {
  readonly kind: 'single'
  readonly id: string
  readonly entry: KeeperToolCallWithMeta
  readonly reach: ToolReachBadge
}

export type ToolHierarchyNode = SingleToolNode | ParallelBatchGroupNode | DelegateChainNode

export type OpenToolActivity = Extract<TurnOpenActivity, { readonly kind: 'tool' }>

export interface OpenWorkParallelBatch {
  readonly kind: 'parallel_batch'
  readonly batchIndex: number
  readonly batchSize: number
  readonly members: readonly OpenToolActivity[]
  readonly reaches: readonly ToolReachBadge[]
}

export type OpenWorkHierarchyNode =
  | { readonly kind: 'single'; readonly activity: TurnOpenActivity; readonly reach: ToolReachBadge | null }
  | OpenWorkParallelBatch

export function reachBadgeForReach(reach: TurnToolReach | null | undefined): ToolReachBadge | null {
  switch (reach) {
    case 'sandbox':
      return '샌드박스'
    case 'network':
      return '외부 · 네트워크'
    case 'model_provider':
      return '모델'
    case 'masc_state':
      return '상태'
    default:
      return null
  }
}

export function inferReachFromToolName(toolName: string, explicitReach?: TurnToolReach | null): ToolReachBadge {
  const fromExplicit = reachBadgeForReach(explicitReach)
  if (fromExplicit) return fromExplicit

  const lower = toolName.trim().toLowerCase()
  if (
    lower.includes('webfetch')
    || lower.includes('websearch')
    || lower.includes('http')
    || lower.includes('fetch')
    || lower.includes('discord')
    || lower.includes('slack')
    || lower.includes('github')
    || lower.includes('browser')
    || lower.includes('network')
  ) {
    return '외부 · 네트워크'
  }
  if (
    lower === 'execute'
    || lower === 'bash'
    || lower === 'read'
    || lower === 'write'
    || lower === 'edit'
    || lower === 'grep'
    || lower === 'glob'
    || lower.startsWith('keeper_fs_')
    || lower.startsWith('keeper_shell')
    || lower.includes('sandbox')
  ) {
    return '샌드박스'
  }
  if (
    lower.includes('delegate')
    || lower.includes('fusion')
    || lower.includes('model')
    || lower.includes('llm')
    || lower.includes('keeper_ask')
  ) {
    return '모델'
  }
  return '상태'
}

export function delegateToolRole(toolName: string): DelegateToolRole | null {
  const trimmed = toolName.trim()
  if (trimmed === 'masc_keeper_delegate') return 'launch'
  if (trimmed.startsWith('masc_keeper_delegate_status')) return 'status'
  if (trimmed === 'masc_keeper_delegate_cancel') return 'cancel'
  return null
}

function readOpIdFromUnknown(val: unknown): string | null {
  if (val === null || val === undefined) return null
  if (typeof val === 'string') {
    const trimmed = val.trim()
    if (!trimmed.startsWith('{')) return null
    try {
      const parsed: unknown = JSON.parse(trimmed)
      return readOpIdFromUnknown(parsed)
    } catch {
      return null
    }
  }
  if (typeof val === 'object' && !Array.isArray(val)) {
    const rec = val as Record<string, unknown>
    for (const key of ['operation_id', 'operationId', 'op_id']) {
      const candidate = rec[key]
      if (typeof candidate === 'string' && candidate.trim().length > 0) {
        return candidate.trim()
      }
    }
    if (rec.result !== undefined) {
      const nested = readOpIdFromUnknown(rec.result)
      if (nested) return nested
    }
  }
  return null
}

export function extractOperationId(entry: Pick<KeeperToolCallEntry, 'input' | 'output'>): string | null {
  return readOpIdFromUnknown(entry.input) ?? readOpIdFromUnknown(entry.output)
}

function entryStartMs(entry: KeeperToolCallWithMeta): number {
  // Timestamps in MASC tool logs may be Unix seconds (~1e9) or milliseconds (~1e12).
  const ts = Number.isFinite(entry.ts) ? entry.ts : 0
  return ts > 1e11 ? ts : ts * 1000
}

function entryDurationMs(entry: KeeperToolCallWithMeta): number {
  return Number.isFinite(entry.duration_ms) && entry.duration_ms > 0 ? entry.duration_ms : 0
}

function explicitBatchKey(entry: KeeperToolCallWithMeta): { readonly key: string; readonly batchIndex: number; readonly batchSize: number } | null {
  if (entry.cohort && entry.cohort.concurrent && entry.cohort.batch_size > 1) {
    return {
      key: `${entry.turn ?? 'na'}:${entry.cohort.batch_index}`,
      batchIndex: entry.cohort.batch_index,
      batchSize: entry.cohort.batch_size,
    }
  }
  if (
    typeof entry.batch_index === 'number'
    && typeof entry.batch_size === 'number'
    && entry.batch_size > 1
    && entry.execution_mode === 'concurrent'
  ) {
    return {
      key: `${entry.turn ?? 'na'}:${entry.batch_index}`,
      batchIndex: entry.batch_index,
      batchSize: entry.batch_size,
    }
  }
  return null
}

function makeParallelBatchNode(
  entries: readonly KeeperToolCallWithMeta[],
  batchIndex: number | null,
  declaredBatchSize: number,
  indexSeed: number,
): ParallelBatchGroupNode {
  const intervals = entries.map((entry) => {
    const startMs = entryStartMs(entry)
    const dur = entryDurationMs(entry)
    return { entry, startMs, endMs: startMs + dur, dur }
  })
  const minStart = Math.min(...intervals.map((i) => i.startMs))
  const maxEnd = Math.max(...intervals.map((i) => i.endMs))
  const wallTimeMs = Math.max(0, Math.round(maxEnd - minStart))
  const summedDurationMs = Math.round(intervals.reduce((acc, i) => acc + i.dur, 0))
  const span = Math.max(1, maxEnd - minStart)

  const reachSet = new Set<ToolReachBadge>()
  const members: ParallelBatchMember[] = intervals.map((item) => {
    const reach = inferReachFromToolName(item.entry.tool, item.entry.reach)
    reachSet.add(reach)
    const offsetMs = Math.max(0, Math.round(item.startMs - minStart))
    const overlapStartPct = Math.max(0, Math.min(98, (offsetMs / span) * 100))
    const rawWidthPct = (item.dur / span) * 100
    const overlapWidthPct = Math.max(2, Math.min(100 - overlapStartPct, rawWidthPct))
    return {
      entry: item.entry,
      reach,
      startMs: item.startMs,
      endMs: item.endMs,
      offsetMs,
      overlapStartPct,
      overlapWidthPct,
    }
  })

  return {
    kind: 'parallel_batch',
    id: `batch:${batchIndex ?? indexSeed}:${entries[0]?.execution_id ?? entries[0]?.ts ?? indexSeed}`,
    batchIndex,
    batchSize: Math.max(declaredBatchSize, entries.length),
    wallTimeMs,
    summedDurationMs,
    reaches: [...reachSet],
    members,
  }
}

function buildDelegateChainNode(operationId: string, entries: readonly KeeperToolCallWithMeta[]): DelegateChainNode {
  let launch: KeeperToolCallWithMeta | null = null
  const statusPolls: KeeperToolCallWithMeta[] = []
  let cancel: KeeperToolCallWithMeta | null = null

  for (const entry of entries) {
    const role = delegateToolRole(entry.tool)
    if (role === 'launch' && !launch) {
      launch = entry
    } else if (role === 'cancel') {
      cancel = entry
    } else {
      statusPolls.push(entry)
    }
  }

  const starts = entries.map(entryStartMs)
  const ends = entries.map((e) => entryStartMs(e) + entryDurationMs(e))
  const wallTimeMs = entries.length > 0 ? Math.max(0, Math.round(Math.max(...ends) - Math.min(...starts))) : 0
  const summedDurationMs = Math.round(entries.reduce((acc, e) => acc + entryDurationMs(e), 0))
  const lastEntry = cancel ?? statusPolls[statusPolls.length - 1] ?? launch
  const terminalStatus = cancel
    ? 'cancelled'
    : lastEntry?.disposition ?? lastEntry?.wire_outcome ?? 'unknown'

  return {
    kind: 'delegate_chain',
    id: `delegate:${operationId}`,
    operationId,
    launch,
    statusPolls,
    cancel,
    totalCalls: entries.length,
    wallTimeMs,
    summedDurationMs,
    terminalStatus,
    reach: '모델',
  }
}

/**
 * Pure tree builder for recorded Keeper tool calls.
 * Preserves chronological encounter order while folding:
 * 1. Async delegation lifecycles (`masc_keeper_delegate` + `status*` + `cancel` sharing `operation_id`).
 * 2. Concurrent parallel batches (explicit `cohort.batch_index` / `batch_index` OR overlapping execution windows).
 */
export function buildToolCallHierarchy(
  entries: readonly KeeperToolCallWithMeta[],
): readonly ToolHierarchyNode[] {
  if (entries.length === 0) return []

  // Step 1: Identify delegation chains sharing operation_id
  const delegateByOp = new Map<string, KeeperToolCallWithMeta[]>()
  const entryDelegateOp = new Map<number, string>()

  for (let i = 0; i < entries.length; i += 1) {
    const entry = entries[i]!
    const role = delegateToolRole(entry.tool)
    if (!role) continue
    const opId = extractOperationId(entry)
    if (!opId) continue
    entryDelegateOp.set(i, opId)
    const list = delegateByOp.get(opId)
    if (list) list.push(entry)
    else delegateByOp.set(opId, [entry])
  }

  // Step 2: Identify explicit concurrent batches among non-delegation entries
  const explicitBatches = new Map<string, { batchIndex: number; batchSize: number; indices: number[] }>()
  const entryExplicitBatch = new Map<number, string>()

  for (let i = 0; i < entries.length; i += 1) {
    if (entryDelegateOp.has(i)) continue
    const entry = entries[i]!
    const b = explicitBatchKey(entry)
    if (!b) continue
    entryExplicitBatch.set(i, b.key)
    const cur = explicitBatches.get(b.key)
    if (cur) {
      cur.batchSize = Math.max(cur.batchSize, b.batchSize)
      cur.indices.push(i)
    } else {
      explicitBatches.set(b.key, { batchIndex: b.batchIndex, batchSize: b.batchSize, indices: [i] })
    }
  }

  // Step 3: Walk entries in order; emit delegate chains, explicit batches, or overlap-window batches
  const nodes: ToolHierarchyNode[] = []
  const emittedDelegates = new Set<string>()
  const emittedBatches = new Set<string>()
  const consumed = new Set<number>()

  for (let i = 0; i < entries.length; i += 1) {
    if (consumed.has(i)) continue

    const opId = entryDelegateOp.get(i)
    if (opId) {
      if (!emittedDelegates.has(opId)) {
        emittedDelegates.add(opId)
        const group = delegateByOp.get(opId)!
        nodes.push(buildDelegateChainNode(opId, group))
      }
      consumed.add(i)
      continue
    }

    const batchKey = entryExplicitBatch.get(i)
    if (batchKey) {
      if (!emittedBatches.has(batchKey)) {
        emittedBatches.add(batchKey)
        const batch = explicitBatches.get(batchKey)!
        for (const idx of batch.indices) consumed.add(idx)
        const members = batch.indices.map((idx) => entries[idx]!)
        nodes.push(makeParallelBatchNode(members, batch.batchIndex, batch.batchSize, i))
      }
      continue
    }

    // Check for overlapping execution windows with subsequent ungrouped entries
    const seed = entries[i]!
    const seedStart = entryStartMs(seed)
    const seedDur = entryDurationMs(seed)
    if (seedDur > 0) {
      let windowEnd = seedStart + seedDur
      const overlapIndices = [i]
      for (let j = i + 1; j < entries.length; j += 1) {
        if (consumed.has(j) || entryDelegateOp.has(j) || entryExplicitBatch.has(j)) continue
        const cand = entries[j]!
        if (seed.turn !== undefined && cand.turn !== undefined && seed.turn !== cand.turn) continue
        const candStart = entryStartMs(cand)
        const candEnd = candStart + entryDurationMs(cand)
        if (candStart >= seedStart && candStart < windowEnd && candEnd > seedStart) {
          overlapIndices.push(j)
          if (candEnd > windowEnd) windowEnd = candEnd
        }
      }
      if (overlapIndices.length > 1) {
        for (const idx of overlapIndices) consumed.add(idx)
        const members = overlapIndices.map((idx) => entries[idx]!)
        nodes.push(makeParallelBatchNode(members, null, members.length, i))
        continue
      }
    }

    consumed.add(i)
    nodes.push({
      kind: 'single',
      id: `single:${i}:${seed.execution_id ?? seed.ts}`,
      entry: seed,
      reach: inferReachFromToolName(seed.tool, seed.reach),
    })
  }

  return nodes
}

/**
 * Groups live `TurnOpenActivity[]` into hierarchical parallel batches with deduplicated reach badges.
 */
export function buildOpenWorkHierarchy(
  activities: readonly TurnOpenActivity[],
): readonly OpenWorkHierarchyNode[] {
  const result: OpenWorkHierarchyNode[] = []
  const batchAt = new Map<number, number>()

  for (const activity of activities) {
    if (
      activity.kind === 'tool'
      && activity.cohort !== null
      && activity.cohort.concurrent
      && activity.cohort.batch_size > 1
    ) {
      const idx = activity.cohort.batch_index
      const badge = inferReachFromToolName(activity.name, activity.reach)
      const existingPos = batchAt.get(idx)
      if (existingPos === undefined) {
        batchAt.set(idx, result.length)
        result.push({
          kind: 'parallel_batch',
          batchIndex: idx,
          batchSize: activity.cohort.batch_size,
          members: [activity],
          reaches: [badge],
        })
      } else {
        const cur = result[existingPos]
        if (cur?.kind === 'parallel_batch') {
          const nextReaches = cur.reaches.includes(badge) ? cur.reaches : [...cur.reaches, badge]
          result[existingPos] = {
            ...cur,
            batchSize: Math.max(cur.batchSize, activity.cohort.batch_size),
            members: [...cur.members, activity],
            reaches: nextReaches,
          }
        }
      }
      continue
    }

    result.push({
      kind: 'single',
      activity,
      reach: activity.kind === 'tool' ? inferReachFromToolName(activity.name, activity.reach) : null,
    })
  }

  return result
}

export interface ToolHierarchyViewProps {
  readonly nodes: readonly ToolHierarchyNode[]
  readonly activeExecutionId?: string
  readonly onSelectEntry?: (entry: KeeperToolCallEntry) => void
}

export function ToolHierarchyView({ nodes, activeExecutionId, onSelectEntry }: ToolHierarchyViewProps) {
  if (nodes.length === 0) return null

  return html`
    <div class="th-root" data-testid="tool-hierarchy-view">
      ${nodes.map((node) => {
        if (node.kind === 'parallel_batch') {
          return html`
            <details key=${node.id} class="th-group th-batch" open data-testid="tool-hierarchy-batch">
              <summary class="th-summary">
                <span class="th-title">
                  병렬 배치 (${node.members.length}/${node.batchSize})
                </span>
                <span class="th-metrics mono tnum">
                  벽시계 ${node.wallTimeMs}ms · 합산 ${node.summedDurationMs}ms
                </span>
                <span class="th-reaches">
                  ${node.reaches.map((r) => html`
                    <span key=${r} class="kp-pill" data-tone=${r === '외부 · 네트워크' ? 'warn' : 'info'}>${r}</span>
                  `)}
                </span>
              </summary>
              <div class="th-members">
                ${node.members.map((m, idx) => {
                  const isActive = activeExecutionId && m.entry.execution_id === activeExecutionId
                  return html`
                    <div
                      key=${`${node.id}:${idx}`}
                      class=${`th-member-row ${isActive ? 'is-active' : ''}`.trim()}
                      onClick=${onSelectEntry ? () => onSelectEntry(m.entry) : undefined}
                    >
                      <div class="th-member-head">
                        <span class="mono th-member-name" title=${m.entry.tool}>${m.entry.tool}</span>
                        <span class="kp-pill">${m.reach}</span>
                        <span class="mono tnum th-member-dur">${Math.round(m.entry.duration_ms)}ms</span>
                      </div>
                      <div class="th-overlap-track" aria-hidden="true">
                        <span
                          class="th-overlap-bar"
                          style=${{
                            left: `${m.overlapStartPct}%`,
                            width: `${m.overlapWidthPct}%`,
                          }}
                        />
                      </div>
                    </div>
                  `
                })}
              </div>
            </details>
          `
        }

        if (node.kind === 'delegate_chain') {
          return html`
            <details key=${node.id} class="th-group th-delegate" open data-testid="tool-hierarchy-delegate">
              <summary class="th-summary">
                <span class="th-title">
                  비동기 위임 체인 · <span class="mono">${node.operationId.slice(0, 12)}</span>
                </span>
                <span class="th-metrics mono tnum">
                  ${node.totalCalls}회 · ${node.wallTimeMs}ms · ${node.terminalStatus}
                </span>
                <span class="kp-pill" data-tone="info">${node.reach}</span>
              </summary>
              <div class="th-members">
                ${node.launch && html`
                  <div
                    class=${`th-member-row ${activeExecutionId && node.launch.execution_id === activeExecutionId ? 'is-active' : ''}`.trim()}
                    onClick=${onSelectEntry ? () => onSelectEntry(node.launch!) : undefined}
                  >
                    <div class="th-member-head">
                      <span class="mono th-member-name">시작 · ${node.launch.tool}</span>
                      <span class="mono tnum th-member-dur">${Math.round(node.launch.duration_ms)}ms</span>
                    </div>
                  </div>
                `}
                ${node.statusPolls.length > 0 && html`
                  <details class="th-polls" data-testid="tool-hierarchy-delegate-polls">
                    <summary class="th-polls-summary">
                      상태 폴링 ${node.statusPolls.length}회 (접힘)
                    </summary>
                    <div class="th-polls-list">
                      ${node.statusPolls.map((poll, idx) => html`
                        <div
                          key=${`${node.id}:poll:${idx}`}
                          class=${`th-member-row ${activeExecutionId && poll.execution_id === activeExecutionId ? 'is-active' : ''}`.trim()}
                          onClick=${onSelectEntry ? () => onSelectEntry(poll) : undefined}
                        >
                          <div class="th-member-head">
                            <span class="mono th-member-name">#${idx + 1} ${poll.tool}</span>
                            <span class="mono tnum th-member-dur">${Math.round(poll.duration_ms)}ms</span>
                          </div>
                        </div>
                      `)}
                    </div>
                  </details>
                `}
                ${node.cancel && html`
                  <div
                    class=${`th-member-row ${activeExecutionId && node.cancel.execution_id === activeExecutionId ? 'is-active' : ''}`.trim()}
                    onClick=${onSelectEntry ? () => onSelectEntry(node.cancel!) : undefined}
                  >
                    <div class="th-member-head">
                      <span class="mono th-member-name">취소 · ${node.cancel.tool}</span>
                      <span class="mono tnum th-member-dur">${Math.round(node.cancel.duration_ms)}ms</span>
                    </div>
                  </div>
                `}
              </div>
            </details>
          `
        }

        const isActive = activeExecutionId && node.entry.execution_id === activeExecutionId
        return html`
          <div
            key=${node.id}
            class=${`th-member-row th-single ${isActive ? 'is-active' : ''}`.trim()}
            data-testid="tool-hierarchy-single"
            onClick=${onSelectEntry ? () => onSelectEntry(node.entry) : undefined}
          >
            <div class="th-member-head">
              <span class="mono th-member-name">${node.entry.tool}</span>
              <span class="kp-pill">${node.reach}</span>
              <span class="mono tnum th-member-dur">${Math.round(node.entry.duration_ms)}ms</span>
            </div>
          </div>
        `
      })}
    </div>
  `
}
