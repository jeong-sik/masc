// Unified status display utilities.
// Consolidates statusLabel, displayStatus, prettyJson from
// mission-utils, agents, agent-roster, status-badge, helpers, ops/helpers.
//
// SSOT principle: one English-key → one Korean label. Sister keys that share
// a meaning (e.g. `done`/`completed`/`ended`) collapse to the same label.
// Distinct meanings get distinct labels — collisions across unrelated keys
// (the prior `중단됨` = interrupted + stopped, `대기` = listening + idle + todo,
// `오류` vs `문제` for error/failed) are an operator-confusion source.
//
// RFC-0135 §3 / PR-7 — `actionLabel(verb)` lives alongside `statusLabel`
// for the noun/verb separation. State labels are nouns ("일시정지"),
// action labels are verbs ("일시정지하기"). The visual distinction is
// what prevents the §1.5.2 collision matrix (operator looks at one
// row and can't tell whether "일시정지" is a state badge or the button
// they're about to press).

/** Comprehensive status label — maps normalized status strings to Korean labels. */
export function statusLabel(value?: string | null): string {
  const normalized = (value ?? '').trim().toLowerCase()
  switch (normalized) {
    case 'ok':
    case 'healthy':
    case 'green':
      return '안정'
    case 'active':
    case 'running':
    case 'in_progress':
      return '진행 중'
    case 'working':
    case 'busy':
      return '작업 중'
    case 'watching':
      return '관찰 중'
    case 'listening':
      return '수신 대기'
    case 'pending':
      return '대기 중'
    case 'todo':
      return '예정'
    case 'idle':
      return '대기'
    case 'paused':
      return '일시정지'
    case 'blocked':
      return '차단됨'
    case 'interrupted':
      return '인터럽트됨'
    case 'stopped':
      return '중단됨'
    case 'warn':
    case 'watch':
    case 'warning':
    case 'degraded':
      return '주의'
    case 'bad':
    case 'critical':
    case 'risk':
      return '위험'
    case 'offline':
    case 'inactive':
      return '오프라인'
    case 'unbooted':
      return '미기동'
    case 'quiet':
      return '조용함'
    case 'loading':
      return '불러오는 중'
    case 'error':
    case 'failed':
      return '오류'
    case 'unavailable':
      return '사용 불가'
    case 'stale':
      return '오래됨'
    case 'refreshing':
      return '갱신 중'
    case 'cached':
      return '캐시됨'
    case 'connected':
      return '연결됨'
    case 'disconnected':
      return '끊김'
    case 'ready':
      return '준비됨'
    case 'done':
    case 'completed':
    case 'ended':
      return '완료'
    case 'cancelled':
      return '취소됨'
    case 'retired':
      return '은퇴'
    case 'spawned':
      return '생성됨'
    case 'compacting':
      return '컴팩팅'
    case 'handoff':
      return '핸드오프'
    case 'claimed':
      return '점유됨'
    case 'awaiting_verification':
      return '검증 대기'
    case 'preview':
      return '미리보기'
    case 'captured':
      return '기록됨'
    case 'unknown':
    case '':
      return '확인 필요'
    default:
      return value?.trim() || '확인 필요'
  }
}

/**
 * Short display status — thin alias for {@link statusLabel} kept for
 * backwards-compat with existing call sites. Previously this duplicated the
 * dispatch table with `error → '문제'` while statusLabel returned `'오류'`,
 * a silent divergence operators could only spot by reading both code paths.
 * Delegating removes that divergence: same key, same label, everywhere.
 */
export function displayStatus(status?: string | null): string {
  return statusLabel(status)
}

/**
 * The five keeper lifecycle action verbs. Exhaustive — adding a new
 * verb requires extending {@link KeeperActionVerb}, the
 * {@link ACTION_LABELS} map, and any consumer that switches on the
 * verb. TS catches the missing arms.
 */
export type KeeperActionVerb =
  | 'pause'
  | 'resume'
  | 'wakeup'
  | 'boot'
  | 'shutdown'

/**
 * Verb metadata for keeper action buttons.
 *
 * `text` is the Korean button label with the `하기` suffix that
 * visually separates the verb form from the matching state noun
 * (state '일시정지' vs verb '일시정지하기'). The `wakeup` verb keeps
 * its concise form ('깨우기') because it has no state-noun twin
 * (there is no Wakeup phase, only the Stuck phase that the action
 * resolves).
 *
 * `pastTense` is the toast-feedback noun ("일시정지됨") — past
 * participle form, used after the backend confirms the action.
 *
 * `icon` is a single-character glyph for `title` tooltips and any
 * icon-only variant; intentionally not Lucide since the action panel
 * already carries the button color/tone visually.
 *
 * `precondition` / `effect` are Korean tooltips that render via the
 * `title` attribute on the action button. RFC-0135 §3.3 requires
 * every action verb to declare both — operators should never have to
 * read code to learn what a button does.
 */
interface ActionLabelEntry {
  text: string
  pastTense: string
  icon: string
  precondition: string
  effect: string
}

const ACTION_LABELS: Record<KeeperActionVerb, ActionLabelEntry> = {
  pause: {
    text: '일시정지하기',
    pastTense: '일시정지됨',
    icon: '⏸',
    precondition: '실행 중인 키퍼만',
    effect: '현재 turn 완료 후 정지, 재개 시 동일 generation 유지',
  },
  resume: {
    text: '재개하기',
    pastTense: '재개됨',
    icon: '▶',
    precondition: '일시정지된 키퍼만',
    effect: '다음 turn부터 정상 실행 재개',
  },
  wakeup: {
    text: '깨우기',
    pastTense: '깨워짐',
    icon: '⚡',
    precondition: '실행 중이거나 차단된 키퍼',
    effect: '즉시 다음 turn 시도, sleep/cooldown 우회',
  },
  boot: {
    text: '기동하기',
    pastTense: '기동됨',
    icon: '🚀',
    precondition: '오프라인 키퍼만',
    effect: '새 fiber 시작, 첫 turn 진입',
  },
  shutdown: {
    text: '종료하기',
    pastTense: '종료됨',
    icon: '⏏',
    precondition: '실행 중이거나 일시정지된 키퍼',
    effect: '현재 turn 중단, fiber 종료. 재시작은 기동 필요',
  },
}

/**
 * Lookup verb metadata for a keeper action button. Returns the full
 * {@link ActionLabelEntry}; consumers pick the fields they need
 * (`text` for the button label, `precondition + effect` for the
 * tooltip, `pastTense` for toast feedback).
 */
export function actionLabel(verb: KeeperActionVerb): ActionLabelEntry {
  return ACTION_LABELS[verb]
}

/**
 * Build the standard tooltip text for an action button. Combines the
 * verb label with its precondition + effect so operators see the
 * contract before clicking.
 */
export function actionTooltip(verb: KeeperActionVerb): string {
  const entry = ACTION_LABELS[verb]
  return `${entry.text}\n사전조건: ${entry.precondition}\n효과: ${entry.effect}`
}

/** Format unknown values as pretty JSON or pass-through strings. */
export function prettyJson(value: unknown): string {
  if (value === null || value === undefined) return ''
  if (typeof value === 'string') return value
  try {
    return JSON.stringify(value, null, 2)
  } catch {
    return String(value)
  }
}
