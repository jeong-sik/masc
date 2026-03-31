import { html } from 'htm/preact'
import { MermaidGraph } from './common/mermaid-graph'
import { StatusChip } from './common/status-chip'
import { statusLabel } from '../lib/status-label'
import type {
  DashboardMissionOperationBadge,
  DashboardMissionSessionDetailResponse,
} from '../types'

type CodingStageKey = 'decompose' | 'inspect' | 'implement' | 'verify' | 'review'
type StageTone = 'pending' | 'active' | 'done' | 'blocked'

type StageSummary = {
  key: CodingStageKey
  label: string
  activeCount: number
  doneCount: number
  blockedCount: number
  totalCount: number
  latestUpdatedAt: number
}

const CODING_STAGES: { key: CodingStageKey; label: string }[] = [
  { key: 'decompose', label: '분해' },
  { key: 'inspect', label: '조사' },
  { key: 'implement', label: '구현' },
  { key: 'verify', label: '검증' },
  { key: 'review', label: '리뷰' },
]

const STAGE_ORDER = new Map<CodingStageKey, number>(
  CODING_STAGES.map((stage, index) => [stage.key, index]),
)

function normalizeStage(stage?: string | null): CodingStageKey | null {
  switch ((stage ?? '').trim().toLowerCase()) {
    case 'decompose':
    case 'inspect':
    case 'implement':
    case 'verify':
    case 'review':
      return stage!.trim().toLowerCase() as CodingStageKey
    default:
      return null
  }
}

function statusTone(status?: string | null): StageTone {
  switch ((status ?? '').trim().toLowerCase()) {
    case 'running':
    case 'active':
    case 'in_progress':
    case 'claimed':
      return 'active'
    case 'completed':
    case 'done':
    case 'ok':
    case 'healthy':
      return 'done'
    case 'blocked':
    case 'failed':
    case 'interrupted':
    case 'cancelled':
    case 'paused':
    case 'error':
      return 'blocked'
    default:
      return 'pending'
  }
}

function updatedAtMillis(value?: string | null): number {
  if (!value) return 0
  const millis = Date.parse(value)
  return Number.isFinite(millis) ? millis : 0
}

function summarizeStages(operations: DashboardMissionOperationBadge[]): StageSummary[] {
  const summaryByStage = new Map<CodingStageKey, StageSummary>(
    CODING_STAGES.map(stage => [
      stage.key,
      {
        key: stage.key,
        label: stage.label,
        activeCount: 0,
        doneCount: 0,
        blockedCount: 0,
        totalCount: 0,
        latestUpdatedAt: 0,
      },
    ]),
  )

  for (const operation of operations) {
    const stageKey = normalizeStage(operation.stage)
    if (!stageKey) continue
    const summary = summaryByStage.get(stageKey)
    if (!summary) continue
    const tone = statusTone(operation.status)
    summary.totalCount += 1
    if (tone === 'active') summary.activeCount += 1
    if (tone === 'done') summary.doneCount += 1
    if (tone === 'blocked') summary.blockedCount += 1
    summary.latestUpdatedAt = Math.max(summary.latestUpdatedAt, updatedAtMillis(operation.updated_at))
  }

  return CODING_STAGES.map(stage => summaryByStage.get(stage.key)!)
}

function stageTone(summary: StageSummary): StageTone {
  if (summary.blockedCount > 0) return 'blocked'
  if (summary.activeCount > 0) return 'active'
  if (summary.totalCount > 0 && summary.doneCount === summary.totalCount) return 'done'
  return 'pending'
}

function activeStageKey(summaries: StageSummary[], sessionStatus?: string | null): CodingStageKey | 'complete' | null {
  const activeStages = summaries.filter(summary => summary.activeCount > 0)
  if (activeStages.length > 0) {
    return [...activeStages].sort((left, right) => {
      if (right.latestUpdatedAt !== left.latestUpdatedAt) {
        return right.latestUpdatedAt - left.latestUpdatedAt
      }
      return (STAGE_ORDER.get(left.key) ?? 0) - (STAGE_ORDER.get(right.key) ?? 0)
    })[0]?.key ?? null
  }

  const completedStages = summaries.filter(summary => summary.totalCount > 0)
  if (completedStages.length > 0) {
    const furthest = [...completedStages].sort((left, right) =>
      (STAGE_ORDER.get(right.key) ?? 0) - (STAGE_ORDER.get(left.key) ?? 0),
    )[0]
    if ((sessionStatus ?? '').trim().toLowerCase() === 'completed' && furthest?.key === 'review') {
      return 'complete'
    }
    return furthest?.key ?? null
  }

  return null
}

function escapeMermaidLabel(value: string): string {
  return value
    .replace(/"/g, '\'')
    .replace(/[\[\]{}()|#;]/g, ' ')
    .replace(/\n+/g, ' ')
    .replace(/\s{2,}/g, ' ')
    .trim()
}

function stageSummaryText(summary: StageSummary): string {
  if (summary.totalCount === 0) return '작업 없음'
  const parts: string[] = []
  if (summary.activeCount > 0) parts.push(`active ${summary.activeCount}`)
  if (summary.doneCount > 0) parts.push(`done ${summary.doneCount}`)
  if (summary.blockedCount > 0) parts.push(`blocked ${summary.blockedCount}`)
  return parts.join(' · ')
}

function stageNodeLabel(summary: StageSummary): string {
  return escapeMermaidLabel(`${summary.label}<br/>${summary.key}<br/>${stageSummaryText(summary)}`)
}

function toneClass(tone: StageTone): string {
  switch (tone) {
    case 'active':
      return 'activeStage'
    case 'done':
      return 'doneStage'
    case 'blocked':
      return 'blockedStage'
    case 'pending':
    default:
      return 'pendingStage'
  }
}

function sessionNodeLabel(detail: DashboardMissionSessionDetailResponse): string {
  const session = detail.session
  if (!session) return '세션'
  return escapeMermaidLabel(
    `세션<br/>${session.goal}<br/>${statusLabel(session.status)} · ops ${detail.operations.length} · participants ${detail.participants.length}`,
  )
}

function blockerPreview(detail: DashboardMissionSessionDetailResponse): string | null {
  const blocker = detail.session?.blocker_summary?.trim()
  if (!blocker) return null
  return blocker.length > 120 ? `${blocker.slice(0, 117)}...` : blocker
}

export function buildSessionFlowMermaid(detail: DashboardMissionSessionDetailResponse): string | null {
  if (!detail.session || detail.operations.length === 0) return null
  const summaries = summarizeStages(detail.operations)
  const activeKey = activeStageKey(summaries, detail.session.status)
  const source: string[] = [
    'flowchart LR',
    '  classDef sessionHub fill:#111827,stroke:#38bdf8,color:#e0f2fe;',
    '  classDef activeStage fill:#082f1d,stroke:#4ade80,color:#dcfce7,stroke-width:3px;',
    '  classDef doneStage fill:#0f172a,stroke:#38bdf8,color:#bfdbfe;',
    '  classDef blockedStage fill:#3f0d12,stroke:#f87171,color:#fecaca;',
    '  classDef pendingStage fill:#111827,stroke:#475569,color:#94a3b8,stroke-dasharray: 3 4;',
    '  classDef terminalStage fill:#052e16,stroke:#22c55e,color:#dcfce7,stroke-width:3px;',
    `  session["${sessionNodeLabel(detail)}"]`,
  ]

  for (const summary of summaries) {
    source.push(`  ${summary.key}["${stageNodeLabel(summary)}"]`)
  }
  source.push('  complete["완료<br/>completed"]')
  source.push('  session --> decompose')
  for (let index = 0; index < CODING_STAGES.length - 1; index += 1) {
    source.push(`  ${CODING_STAGES[index]!.key} --> ${CODING_STAGES[index + 1]!.key}`)
  }
  source.push('  review --> complete')
  source.push('  class session sessionHub;')

  for (const summary of summaries) {
    source.push(`  class ${summary.key} ${toneClass(stageTone(summary))};`)
  }
  if (activeKey && activeKey !== 'complete') {
    source.push(`  class ${activeKey} activeStage;`)
  }
  if (activeKey === 'complete') {
    source.push('  class complete terminalStage;')
  } else {
    source.push('  class complete pendingStage;')
  }

  const blocker = blockerPreview(detail)
  if (blocker) {
    source.push(`  blocker["${escapeMermaidLabel(`막힘<br/>${blocker}`)}"]`)
    source.push('  session -.-> blocker')
    source.push('  class blocker blockedStage;')
  }

  if (detail.keepers.length > 0) {
    source.push(
      `  continuity["${escapeMermaidLabel(`연속성<br/>keepers ${detail.keepers.length}`)}"]`,
    )
    source.push('  implement -.-> continuity')
    source.push('  class continuity sessionHub;')
  }

  return source.join('\n')
}

export function sessionFlowFallback(detail: DashboardMissionSessionDetailResponse): string {
  const summaries = summarizeStages(detail.operations)
  const activeKey = activeStageKey(summaries, detail.session?.status)
  const activeSummary = activeKey && activeKey !== 'complete'
    ? summaries.find(summary => summary.key === activeKey)
    : null
  const stageText = activeKey === 'complete'
    ? '완료 단계'
    : activeSummary
      ? `${activeSummary.label}(${activeSummary.key})`
      : '활성 단계 없음'
  const blocker = blockerPreview(detail)
  return [
    `세션 ${statusLabel(detail.session?.status)} · 현재 ${stageText}`,
    `작전 ${detail.operations.length}개 · 참여자 ${detail.participants.length}명`,
    blocker ? `막힘: ${blocker}` : '막힘 없음',
  ].join(' | ')
}

export function SessionFlowCard({
  detail,
}: {
  detail: DashboardMissionSessionDetailResponse
}) {
  const source = buildSessionFlowMermaid(detail)
  if (!source) {
    return html`
      <div class="rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] p-4">
        <div class="flex items-center justify-between gap-3">
          <div>
            <div class="text-sm font-semibold text-[var(--text-strong)]">진행 순서도</div>
            <div class="mt-1 text-xs leading-[1.6] text-[var(--text-muted)]">
              연결된 작전이 없어 아직 흐름도를 만들 수 없습니다.
            </div>
          </div>
          <${StatusChip} label="작전 없음" />
        </div>
      </div>
    `
  }

  return html`
    <div class="rounded-xl border border-[var(--card-border)] bg-[var(--white-3)] p-4">
      <div class="flex flex-col gap-2 md:flex-row md:items-start md:justify-between">
        <div>
          <div class="text-sm font-semibold text-[var(--text-strong)]">진행 순서도</div>
          <div class="mt-1 text-xs leading-[1.6] text-[var(--text-muted)]">
            coding_task의 canonical stage를 기준으로 지금 어느 단계에 작업이 몰려 있는지 보여줍니다.
          </div>
        </div>
        <div class="flex flex-wrap gap-2 text-[11px] text-[var(--text-dim)]">
          <span class="rounded-full border border-[var(--white-8)] px-2 py-1">실선: canonical path</span>
          <span class="rounded-full border border-[var(--white-8)] px-2 py-1">점선: blocker / continuity</span>
        </div>
      </div>

      <div class="mt-3">
        <${MermaidGraph}
          source=${source}
          prefix="mission-session-flow"
          fallbackText=${sessionFlowFallback(detail)}
          minHeightClass="min-h-[240px]"
          diagramClass="border border-[var(--white-8)]"
        />
      </div>
    </div>
  `
}
