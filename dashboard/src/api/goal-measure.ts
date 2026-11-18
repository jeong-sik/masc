// What a Goal measures, read exactly as the server writes it
// (Goal_measure.to_yojson, lib/goal_measure/goal_measure.ml). Three shapes:
// a count out of a total, a quantity against a limit, or a condition that
// holds or does not. The reader refuses an unknown kind, a missing field or
// an extra field and fills nothing in, as Goal_measure.of_yojson does.

import { isRecord } from '../components/common/normalize'

export type GoalMeasureDirection = 'at_least' | 'at_most'

export type GoalMeasure =
  | { readonly kind: 'count'; readonly noun: string; readonly total: number }
  | { readonly kind: 'quantity'; readonly unit: string; readonly direction: GoalMeasureDirection; readonly target: number }
  | { readonly kind: 'done_when'; readonly condition: string }

// OCaml String.trim removes these five; the server calls a label blank when
// nothing else is left (Goal_measure.make_label).
const OCAML_TRIM_BLANK = /^[ \t\n\r\f]*$/

/** Blank as the server reads it: nothing left after OCaml String.trim. A
 *  no-break or ideographic space is text to the server, unlike JS trim. */
export function isServerBlank(text: string): boolean {
  return OCAML_TRIM_BLANK.test(text)
}

/** The text when it is a label the server accepts: not blank and on one line. */
export function goalMeasureLabel(text: string): string | null {
  if (isServerBlank(text)) return null
  if (text.includes('\n') || text.includes('\r')) return null
  return text
}

function exactKeys(raw: Record<string, unknown>, keys: readonly string[]): boolean {
  const present = Object.keys(raw)
  return present.length === keys.length && keys.every(key => Object.hasOwn(raw, key))
}

function label(value: unknown): string | null {
  return typeof value === 'string' ? goalMeasureLabel(value) : null
}

export function decodeGoalMeasure(raw: unknown): GoalMeasure | null {
  if (!isRecord(raw)) return null
  switch (raw.kind) {
    case 'count': {
      if (!exactKeys(raw, ['kind', 'noun', 'total'])) return null
      const noun = label(raw.noun)
      const total = raw.total
      if (noun === null || typeof total !== 'number' || !Number.isSafeInteger(total) || total < 1) return null
      return { kind: 'count', noun, total }
    }
    case 'quantity': {
      if (!exactKeys(raw, ['kind', 'unit', 'direction', 'target'])) return null
      const unit = label(raw.unit)
      const direction = raw.direction
      const target = raw.target
      if (unit === null || (direction !== 'at_least' && direction !== 'at_most')
        || typeof target !== 'number' || !Number.isFinite(target)) return null
      return { kind: 'quantity', unit, direction, target }
    }
    case 'done_when': {
      if (!exactKeys(raw, ['kind', 'condition'])) return null
      const condition = label(raw.condition)
      return condition === null ? null : { kind: 'done_when', condition }
    }
    default:
      return null
  }
}

export function goalMeasureEqual(left: GoalMeasure, right: GoalMeasure): boolean {
  switch (left.kind) {
    case 'count':
      return right.kind === 'count' && left.noun === right.noun && left.total === right.total
    case 'quantity':
      return right.kind === 'quantity' && left.unit === right.unit
        && left.direction === right.direction && left.target === right.target
    case 'done_when':
      return right.kind === 'done_when' && left.condition === right.condition
  }
}

/** What a screen shows where a row's measure did not read. The server always
 *  writes one, so this is a decoding failure made visible, not an empty Goal. */
export const MEASURE_UNREADABLE = '측정 조건을 읽을 수 없음'

/** One line for a screen: `14 층`, `≤ 100 ms`, or the condition itself.
 *  String(number) is the shortest text that reads back as the same number,
 *  so a target such as 1048576 is shown whole. */
export function goalMeasureText(measure: GoalMeasure): string {
  switch (measure.kind) {
    case 'count':
      return `${measure.total} ${measure.noun}`
    case 'quantity':
      return `${measure.direction === 'at_least' ? '≥' : '≤'} ${String(measure.target)} ${measure.unit}`
    case 'done_when':
      return measure.condition
  }
}
