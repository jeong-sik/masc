import { isPositiveSafeInteger } from '../common/normalize'
import type { RunActivityEvent } from './run-activity-store'

export interface IdeContextTextRouteRefs {
  readonly line?: number
  readonly goalId?: string
  readonly taskId?: string
  readonly boardPostId?: string
  readonly commentId?: string
  readonly prId?: string
  readonly gitRef?: string
  readonly logId?: string
  readonly sessionId?: string
  readonly operationId?: string
  readonly workerRunId?: string
}

const REF_VALUE_PATTERN = '([A-Za-z0-9][A-Za-z0-9._/@:-]*)'
const EVENT_REF_PATTERNS = {
  goalId: new RegExp(`\\bgoal[:#/]+${REF_VALUE_PATTERN}`, 'i'),
  taskId: new RegExp(`\\btask[:#/]+${REF_VALUE_PATTERN}`, 'i'),
  boardPostId: new RegExp(`\\b(?:board|post)[:#/]+${REF_VALUE_PATTERN}`, 'i'),
  commentId: new RegExp(`\\bcomment[:#/]+${REF_VALUE_PATTERN}`, 'i'),
  prId: /\b(?:pr|pull[_\s-]?request)\s*[:#/]?\s*#?(\d{1,10})\b/i,
  gitRef: new RegExp(`\\b(?:git|commit|branch|ref)[:#/]+${REF_VALUE_PATTERN}`, 'i'),
  logId: new RegExp(`\\b(?:log|turn)[:#/]+${REF_VALUE_PATTERN}`, 'i'),
  sessionId: new RegExp(`\\bsession[:#/]+${REF_VALUE_PATTERN}`, 'i'),
  operationId: new RegExp(`\\b(?:operation|op)[:#/]+${REF_VALUE_PATTERN}`, 'i'),
  workerRunId: new RegExp(`\\b(?:worker_run|worker|wr)[:#/]+${REF_VALUE_PATTERN}`, 'i'),
} as const

export function routeRefsFromText(text: string): IdeContextTextRouteRefs {
  return {
    line: eventLineRef(text),
    goalId: firstEventRef(text, EVENT_REF_PATTERNS.goalId),
    taskId: firstEventRef(text, EVENT_REF_PATTERNS.taskId),
    boardPostId: firstEventRef(text, EVENT_REF_PATTERNS.boardPostId),
    commentId: firstEventRef(text, EVENT_REF_PATTERNS.commentId),
    prId: firstEventRef(text, EVENT_REF_PATTERNS.prId),
    gitRef: firstEventRef(text, EVENT_REF_PATTERNS.gitRef),
    logId: firstEventRef(text, EVENT_REF_PATTERNS.logId),
    sessionId: firstEventRef(text, EVENT_REF_PATTERNS.sessionId),
    operationId: firstEventRef(text, EVENT_REF_PATTERNS.operationId),
    workerRunId: firstEventRef(text, EVENT_REF_PATTERNS.workerRunId),
  }
}

export function eventRouteRefs(event: RunActivityEvent): IdeContextTextRouteRefs {
  return routeRefsFromText(eventRawText(event))
}

function eventRawText(event: RunActivityEvent): string {
  return [
    event.kind,
    event.verb,
    event.target,
    event.detail,
    ...(event.tags ?? []),
  ]
    .filter((part): part is string => typeof part === 'string' && part.trim() !== '')
    .join(' ')
}

function firstEventRef(text: string, pattern: RegExp): string | undefined {
  return cleanParsedRef(pattern.exec(text)?.[1])
}

function cleanParsedRef(value: string | undefined): string | undefined {
  const cleaned = value?.trim().replace(/[),.;\]}]+$/u, '')
  return cleaned ? cleaned : undefined
}

function eventLineRef(text: string): number | undefined {
  const explicit = /\b(?:line|l)[:#]+(\d{1,7})\b/i.exec(text)?.[1]
  const compact = explicit ?? /\bL(\d{1,7})\b/.exec(text)?.[1]
  return compact ? positiveLine(Number(compact)) : undefined
}

export function positiveLine(value: number | null | undefined): number | undefined {
  return isPositiveSafeInteger(value) ? value : undefined
}
