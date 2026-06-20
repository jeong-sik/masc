import type { TraceSummary, UnifiedTraceEvent } from './session-trace-state'

export type ProcessCriticSeverity = 'action' | 'warning' | 'notice'

export interface ProcessCriticFinding {
  id: string
  severity: ProcessCriticSeverity
  title: string
  detail: string
  action: string
  evidence: string[]
}

export interface ProcessCriticInput {
  events: readonly UnifiedTraceEvent[]
  summary: TraceSummary
  nowMs?: number
}

interface ToolRunCluster {
  name: string
  count: number
  shortCount: number
  samples: string[]
}

const MAX_FINDINGS = 3
const RECENT_EVENT_LIMIT = 16
const RECENT_TOOL_LIMIT = 12
const REPEATED_TOOL_THRESHOLD = 3
const TOOL_CHURN_THRESHOLD = 8
const STALE_TRACE_MS = 5 * 60 * 1000
const SHORT_TOOL_MIN_MS = 350
const SHORT_TOOL_MAX_MS = 800

export function evaluateProcessTrace({
  events,
  summary,
  nowMs = Date.now(),
}: ProcessCriticInput): ProcessCriticFinding[] {
  if (events.length === 0) return []

  const findings: ProcessCriticFinding[] = []
  const recent = events.slice(0, RECENT_EVENT_LIMIT)
  const failures = recent.filter(isFailureEvent)

  if (failures.length > 0 || summary.oas_error_count > 0) {
    findings.push({
      id: 'recent-failure-boundary',
      severity: 'action',
      title: 'Failure boundary first',
      detail: 'Recent trace evidence contains a failure, so the next process move should pin the failing boundary before broad exploration continues.',
      action: 'Inspect latest error',
      evidence: compactEvidence(failures, summary.oas_error_count > 0 ? [`OAS errors ${summary.oas_error_count}`] : []),
    })
  }

  const repeatedTool = findRepeatedToolCluster(recent)
  if (repeatedTool) {
    const shortSuffix = repeatedTool.shortCount >= REPEATED_TOOL_THRESHOLD
      ? `; ${repeatedTool.shortCount} were ${SHORT_TOOL_MIN_MS}-${SHORT_TOOL_MAX_MS}ms short runs`
      : ''
    findings.push({
      id: 'repeated-tool-loop',
      severity: repeatedTool.shortCount >= REPEATED_TOOL_THRESHOLD ? 'action' : 'warning',
      title: 'Tool loop detected',
      detail: `The recent window repeats ${repeatedTool.name} ${repeatedTool.count} times${shortSuffix}. Narrow the target before another similar call.`,
      action: 'Narrow query or line range',
      evidence: repeatedTool.samples,
    })
  }

  if (summary.oas_context_count > 0 || summary.oas_tokens_saved > 0) {
    findings.push({
      id: 'context-pressure',
      severity: 'warning',
      title: 'Context pressure is active',
      detail: 'The trace includes context compaction, so the safer process move is to preserve the current decision boundary before opening a wider search.',
      action: 'Checkpoint or split scope',
      evidence: [
        `context compactions ${summary.oas_context_count}`,
        summary.oas_tokens_saved > 0 ? `tokens saved ${summary.oas_tokens_saved}` : '',
      ].filter(Boolean),
    })
  }

  const totalTools = summary.tool_call_count + summary.oas_tool_count
  if (totalTools >= TOOL_CHURN_THRESHOLD && summary.task_completed_count === 0) {
    findings.push({
      id: 'tool-churn-no-completion',
      severity: 'notice',
      title: 'High tool churn',
      detail: 'Many tool calls have accumulated without a completion marker; a short checkpoint can prevent more low-signal exploration.',
      action: 'State next checkpoint',
      evidence: [`tools ${totalTools}`, `completed ${summary.task_completed_count}`],
    })
  }

  const latest = events[0]
  if (latest && nowMs - latest.ts >= STALE_TRACE_MS && summary.task_completed_count === 0) {
    findings.push({
      id: 'stale-trace-evidence',
      severity: 'notice',
      title: 'Trace evidence is stale',
      detail: 'The latest visible trace row is old; refresh or confirm liveness before trusting the current working hypothesis.',
      action: 'Refresh trace',
      evidence: [`last event ${formatAge(nowMs - latest.ts)} ago`, latest.summary],
    })
  }

  return dedupeFindings(findings).slice(0, MAX_FINDINGS)
}

function isFailureEvent(event: UnifiedTraceEvent): boolean {
  if (event.error) return true
  if (event.gate?.status === 'reject') return true
  return event.detail.durable_kind === 'error_occurred'
}

function eventToolName(event: UnifiedTraceEvent): string | null {
  if (event.kind !== 'tool_call' && event.kind !== 'oas_tool') return null
  const fromField = typeof event.toolName === 'string' ? event.toolName.trim() : ''
  if (fromField) return fromField
  const fromDetail = typeof event.detail.tool_name === 'string' ? event.detail.tool_name.trim() : ''
  if (fromDetail) return fromDetail
  const fromSummary = event.summary.trim()
  return fromSummary || null
}

function findRepeatedToolCluster(events: readonly UnifiedTraceEvent[]): ToolRunCluster | null {
  const clusters = new Map<string, ToolRunCluster>()
  let consideredTools = 0

  for (const event of events) {
    const name = eventToolName(event)
    if (!name) continue
    consideredTools += 1
    if (consideredTools > RECENT_TOOL_LIMIT) break
    const key = name.toLowerCase()
    const duration = event.duration_ms
    const isShort = duration != null && duration >= SHORT_TOOL_MIN_MS && duration <= SHORT_TOOL_MAX_MS
    const cluster = clusters.get(key) ?? { name, count: 0, shortCount: 0, samples: [] }
    cluster.count += 1
    if (isShort) cluster.shortCount += 1
    if (cluster.samples.length < 4) {
      cluster.samples.push(duration != null ? `${name} ${formatDuration(duration)}` : name)
    }
    clusters.set(key, cluster)
  }

  let best: ToolRunCluster | null = null
  for (const cluster of clusters.values()) {
    if (cluster.count < REPEATED_TOOL_THRESHOLD) continue
    if (!best || cluster.count > best.count || cluster.shortCount > best.shortCount) {
      best = cluster
    }
  }
  return best
}

function compactEvidence(events: readonly UnifiedTraceEvent[], fallback: string[] = []): string[] {
  const evidence = events.slice(0, 4).map(event => {
    const reason = event.error ?? (event.gate?.reason ? `gate ${event.gate.reason}` : null)
    return reason ? `${event.summary}: ${reason}` : event.summary
  })
  return evidence.length > 0 ? evidence : fallback
}

function dedupeFindings(findings: ProcessCriticFinding[]): ProcessCriticFinding[] {
  const seen = new Set<string>()
  const deduped: ProcessCriticFinding[] = []
  for (const finding of findings) {
    if (seen.has(finding.id)) continue
    seen.add(finding.id)
    deduped.push(finding)
  }
  return deduped
}

function formatDuration(ms: number): string {
  if (ms >= 1000) return `${(ms / 1000).toFixed(1)}s`
  return `${Math.round(ms)}ms`
}

function formatAge(ms: number): string {
  const minutes = Math.floor(ms / 60_000)
  if (minutes < 60) return `${minutes}m`
  const hours = Math.floor(minutes / 60)
  return `${hours}h`
}
