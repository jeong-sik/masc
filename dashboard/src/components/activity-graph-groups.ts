import type {
  ActivityCategory,
  ActivityGraphKindCounts,
  ActivityGraphTimelineEvent,
  ActionTimelineGroup,
} from '../types'

export type ActionTimelineFilter = 'all' | Exclude<ActivityCategory, 'lifecycle' | 'other'> | 'other'

const TASK_GAP_MS = 15 * 60 * 1000
const SESSION_GAP_MS = 5 * 60 * 1000
const MESSAGE_GAP_MS = 60 * 1000
const BOARD_GAP_MS = 120 * 1000
const GOVERNANCE_GAP_MS = 10 * 60 * 1000

type MutableGroup = {
  category: ActivityCategory
  rawEvents: ActivityGraphTimelineEvent[]
  latestTsMs: number
}

export function categoryForActivityKind(kind: string): ActivityCategory {
  if (kind.startsWith('task.')) return 'task'
  if (
    kind.startsWith('operation.')
    || kind.startsWith('team.turn')
    || kind.startsWith('keeper.autonomy_')
  ) return 'session'
  if (kind.startsWith('message.')) return 'message'
  if (kind.startsWith('board.')) return 'board'
  if (
    kind.startsWith('decision.')
    || kind.startsWith('policy.')
    || kind === 'keeper.contract_verdict'
    || kind === 'keeper.friction'
  ) return 'governance'
  if (
    kind === 'agent.joined'
    || kind === 'agent.left'
    || kind === 'agent.spawned'
    || kind === 'agent.retired'
    || kind === 'agent.compacted'
    || kind === 'agent.handoff'
    || kind === 'keeper.guardrail'
    || kind === 'keeper.compaction'
  ) return 'lifecycle'
  return 'other'
}

export function categoryLabel(category: ActivityCategory): string {
  switch (category) {
    case 'task': return '태스크'
    case 'session': return '세션'
    case 'message': return '메시지'
    case 'board': return '보드'
    case 'governance': return '거버넌스'
    case 'lifecycle': return '라이프사이클'
    default: return '기타'
  }
}

export function eventKindLabel(kind: string): string {
  switch (kind) {
    case 'agent.joined': return '입장'
    case 'agent.left': return '퇴장'
    case 'agent.spawned': return '스폰'
    case 'agent.retired': return '은퇴'
    case 'agent.compacted': return '컴팩트'
    case 'agent.handoff': return '핸드오프'
    case 'message.broadcast': return '브로드캐스트'
    case 'message.mentioned': return '멘션'
    case 'task.created': return '생성'
    case 'task.claimed': return '점유'
    case 'task.started': return '시작'
    case 'task.done': return '완료'
    case 'task.released': return '반환'
    case 'task.cancelled': return '취소'
    case 'task.submit_for_verification': return '검증 요청'
    case 'task.approved': return '검증 승인'
    case 'task.rejected': return '검증 반려'
    case 'board.posted': return '게시'
    case 'board.commented': return '댓글'
    case 'board.voted': return '투표'
    case 'operation.started': return '세션 시작'
    case 'operation.resumed': return '세션 재개'
    case 'operation.paused': return '세션 일시중지'
    case 'operation.stopped': return '세션 중단'
    case 'operation.finalized': return '세션 종료'
    case 'team.turn': return '팀 턴'
    case 'team.turn_failed': return '팀 턴 실패'
    case 'decision.opened': return '결정 시작'
    case 'decision.voted': return '결정 투표'
    case 'decision.resolved': return '결정 완료'
    case 'policy.approved': return '정책 승인'
    case 'policy.denied': return '정책 거절'
    case 'keeper.autonomy_started': return '자율 시작'
    case 'keeper.autonomy_completed': return '자율 완료'
    case 'keeper.contract_verdict': return '계약 판정'
    case 'keeper.friction': return '마찰 신호'
    case 'keeper.compaction': return '컴팩션'
    case 'keeper.guardrail': return '가드레일'
    case 'tool.called': return '툴 호출'
    default: return kind
  }
}

function eventActor(event: ActivityGraphTimelineEvent): string {
  const actor = event.actor as Record<string, unknown>
  if (typeof actor?.id === 'string' && actor.id.trim() !== '') return actor.id
  const payload = event.payload as Record<string, unknown>
  for (const key of ['agent', 'author', 'from', 'created_by', 'actor']) {
    const value = payload[key]
    if (typeof value === 'string' && value.trim() !== '') return value
  }
  return ''
}

function eventSubjectId(event: ActivityGraphTimelineEvent): string | null {
  if (event.subject?.id && typeof event.subject.id === 'string' && event.subject.id.trim() !== '') {
    return event.subject.id
  }
  const payload = event.payload as Record<string, unknown>
  for (const key of ['task_id', 'session_id', 'operation_id', 'post_id', 'target_id']) {
    const value = payload[key]
    if (typeof value === 'string' && value.trim() !== '') return value
  }
  return null
}

function eventTsMs(event: ActivityGraphTimelineEvent): number {
  const parsed = Date.parse(event.ts_iso)
  return Number.isNaN(parsed) ? event.ts : parsed
}

function payloadString(event: ActivityGraphTimelineEvent, keys: string[]): string {
  const payload = event.payload as Record<string, unknown>
  for (const key of keys) {
    const value = payload[key]
    if (typeof value === 'string' && value.trim() !== '') return value.trim()
  }
  return ''
}

export function eventDetail(event: ActivityGraphTimelineEvent, max = 120): string {
  const text = payloadString(event, [
    'message',
    'content',
    'task_title',
    'title',
    'reason',
    'notes',
    'cmd',
    'tool_args_preview',
    'tool_name',
    'verification_id',
    'contract_id',
    'run_id',
    'target_id',
  ])
  const base = text || eventSubjectId(event) || event.kind
  return base.length > max ? `${base.slice(0, max - 3)}...` : base
}

function eventPreview(event: ActivityGraphTimelineEvent, max = 72): string {
  return eventDetail(event, max)
}

function groupGapMs(category: ActivityCategory): number | null {
  switch (category) {
    case 'task': return TASK_GAP_MS
    case 'session': return SESSION_GAP_MS
    case 'message': return MESSAGE_GAP_MS
    case 'board': return BOARD_GAP_MS
    case 'governance': return GOVERNANCE_GAP_MS
    default: return null
  }
}

function canMergeGroup(group: MutableGroup, event: ActivityGraphTimelineEvent): boolean {
  const category = categoryForActivityKind(event.kind)
  if (group.category !== category) return false

  const gapMs = groupGapMs(category)
  if (gapMs == null) return false
  if (eventTsMs(event) - group.latestTsMs > gapMs) return false

  const first = group.rawEvents[0]
  if (!first) return false

  if (category === 'task' || category === 'session' || category === 'board') {
    return eventSubjectId(first) !== null && eventSubjectId(first) === eventSubjectId(event)
  }

  if (category === 'message') {
    return eventActor(first) !== '' && eventActor(first) === eventActor(event)
  }

  if (category === 'governance') {
    const firstSubject = eventSubjectId(first)
    const nextSubject = eventSubjectId(event)
    if (firstSubject && nextSubject) return firstSubject === nextSubject
    return eventActor(first) !== '' && eventActor(first) === eventActor(event)
  }

  return false
}

function sequenceSummary(events: ActivityGraphTimelineEvent[]): string {
  const labels: string[] = []
  for (const event of events) {
    const label = eventKindLabel(event.kind)
    if (labels[labels.length - 1] !== label) labels.push(label)
  }
  return labels.join(' -> ')
}

function groupActor(events: ActivityGraphTimelineEvent[]): string {
  const actors = [...new Set(events.map(eventActor).filter(Boolean))]
  if (actors.length === 0) return ''
  if (actors.length === 1) return actors[0]!
  return `${actors[0]} +${actors.length - 1}`
}

function groupSubjectId(events: ActivityGraphTimelineEvent[]): string | null {
  for (const event of events) {
    const subjectId = eventSubjectId(event)
    if (subjectId) return subjectId
  }
  return null
}

function groupTitle(category: ActivityCategory, events: ActivityGraphTimelineEvent[]): string {
  const subjectId = groupSubjectId(events)
  const actor = groupActor(events)
  const latest = events[events.length - 1]
  if (!latest) return 'Activity'

  switch (category) {
    case 'task':
      return payloadString(latest, ['task_title', 'title']) || subjectId || 'Task activity'
    case 'session':
      return subjectId || payloadString(latest, ['session_id', 'operation_id']) || 'Session activity'
    case 'message':
      return actor ? `${actor} message burst` : 'Message burst'
    case 'board':
      return payloadString(latest, ['title']) || subjectId || 'Board activity'
    case 'governance':
      return subjectId || 'Governance activity'
    case 'lifecycle':
      return actor || eventKindLabel(latest.kind)
    default:
      return subjectId || eventKindLabel(latest.kind)
  }
}

function groupSummary(category: ActivityCategory, events: ActivityGraphTimelineEvent[]): string {
  const latest = events[events.length - 1]
  if (!latest) return ''

  switch (category) {
    case 'message':
      return `${events.length} 메시지 이벤트 · ${eventPreview(latest)}`
    case 'board':
      return `${events.length} 보드 이벤트 · ${eventPreview(latest)}`
    case 'lifecycle':
      return eventDetail(latest)
    default: {
      const sequence = sequenceSummary(events)
      return events.length > 1 ? `${sequence} · ${events.length} 이벤트` : sequence
    }
  }
}

function groupId(category: ActivityCategory, events: ActivityGraphTimelineEvent[]): string {
  const first = events[0]
  const latest = events[events.length - 1]
  const subjectId = groupSubjectId(events) ?? 'none'
  const actor = groupActor(events) || 'system'
  const firstSeq = first?.seq ?? 0
  const latestSeq = latest?.seq ?? firstSeq
  return `${category}:${actor}:${subjectId}:${firstSeq}:${latestSeq}`
}

export function buildActionTimelineGroups(events: ActivityGraphTimelineEvent[]): ActionTimelineGroup[] {
  const sorted = [...events].sort((a, b) => {
    const delta = eventTsMs(a) - eventTsMs(b)
    return delta !== 0 ? delta : a.seq - b.seq
  })

  const groups: MutableGroup[] = []
  for (const event of sorted) {
    const category = categoryForActivityKind(event.kind)
    const current = groups[groups.length - 1]
    if (current && canMergeGroup(current, event)) {
      current.rawEvents.push(event)
      current.latestTsMs = eventTsMs(event)
      continue
    }
    groups.push({
      category,
      rawEvents: [event],
      latestTsMs: eventTsMs(event),
    })
  }

  return groups
    .map(group => {
      const latest = group.rawEvents[group.rawEvents.length - 1]!
      const uniqueKinds = [...new Set(group.rawEvents.map(event => event.kind))]
      return {
        id: groupId(group.category, group.rawEvents),
        category: group.category,
        actor: groupActor(group.rawEvents),
        subjectId: groupSubjectId(group.rawEvents),
        title: groupTitle(group.category, group.rawEvents),
        summary: groupSummary(group.category, group.rawEvents),
        latestTs: latest.ts_iso,
        latestTsMs: group.latestTsMs,
        rawCount: group.rawEvents.length,
        kinds: uniqueKinds,
        rawEvents: group.rawEvents,
      }
    })
    .sort((a, b) => b.latestTsMs - a.latestTsMs)
}

function emptyCategoryCounts(): Record<ActivityCategory, number> {
  return {
    task: 0,
    session: 0,
    message: 0,
    board: 0,
    governance: 0,
    lifecycle: 0,
    other: 0,
  }
}

export function buildCategoryCounts(groups: ActionTimelineGroup[]): Record<ActivityCategory, number> {
  const counts = emptyCategoryCounts()
  for (const group of groups) {
    counts[group.category] += 1
  }
  return counts
}

export function buildRawCategoryCounts(kindCounts: ActivityGraphKindCounts): Record<ActivityCategory, number> {
  const counts = emptyCategoryCounts()
  for (const [kind, value] of Object.entries(kindCounts)) {
    counts[categoryForActivityKind(kind)] += value
  }
  return counts
}
