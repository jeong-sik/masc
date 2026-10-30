// What a Keeper is waiting on a human for, as it arrives on the wire.
//
// GET /api/v1/keepers/asks lists the questions. Answers travel as choice ids,
// never labels: rewording a choice cannot orphan an answer already recorded.
// A row whose mode or free-text shape is unknown fails the parse rather than
// defaulting, because a surface that guessed would offer the operator a
// control the server will refuse.

import { isRecord } from './type-guards'

export type AskChoice = {
  readonly choiceId: string
  readonly label: string
  readonly description: string | null
}

export type AskMode = 'single' | 'multi'

export type AskFreeText =
  | { readonly allowed: false }
  | { readonly allowed: true; readonly hint: string | null }

export type AskQuestion = {
  readonly questionId: string
  readonly header: string
  readonly prompt: string
  readonly mode: AskMode
  readonly freeText: AskFreeText
  readonly choices: readonly AskChoice[]
}

export type AskResolution =
  | { readonly state: 'open' }
  | {
      readonly state: 'answered'
      readonly answeredAt: number
      readonly answeredQuestionIds: readonly string[]
    }
  | { readonly state: 'withdrawn'; readonly reason: string; readonly withdrawnAt: number }

export type AskRow = {
  readonly keeper: string
  readonly askId: string
  readonly askedAt: number
  /** Why the Keeper is asking, in its own words. A row that hides this reads
      as a decision with no stakes. */
  readonly context: string | null
  readonly questions: readonly AskQuestion[]
  readonly resolution: AskResolution
}

export type AsksSnapshot = {
  readonly scope: 'keeper' | 'fleet'
  readonly keeper: string | null
  /** The server's count, not `rows.length`: a filtered list still says how
      many are waiting. */
  readonly openCount: number
  readonly rows: readonly AskRow[]
}

export type ParseResult<T> =
  | { readonly ok: true; readonly value: T }
  | { readonly ok: false; readonly error: string }

function fail<T>(error: string): ParseResult<T> {
  return { ok: false, error }
}

function requireString(raw: Record<string, unknown>, key: string): ParseResult<string> {
  const value = raw[key]
  if (typeof value !== 'string') return fail(`${key} must be a string`)
  return { ok: true, value }
}

function optionalString(raw: Record<string, unknown>, key: string): ParseResult<string | null> {
  const value = raw[key]
  if (value === null || value === undefined) return { ok: true, value: null }
  if (typeof value !== 'string') return fail(`${key} must be a string or null`)
  return { ok: true, value }
}

function requireNumber(raw: Record<string, unknown>, key: string): ParseResult<number> {
  const value = raw[key]
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return fail(`${key} must be a finite number`)
  }
  return { ok: true, value }
}

function parseChoice(raw: unknown): ParseResult<AskChoice> {
  if (!isRecord(raw)) return fail('each choice must be an object')
  const choiceId = requireString(raw, 'choice_id')
  if (!choiceId.ok) return choiceId
  const label = requireString(raw, 'label')
  if (!label.ok) return label
  const description = optionalString(raw, 'description')
  if (!description.ok) return description
  return {
    ok: true,
    value: { choiceId: choiceId.value, label: label.value, description: description.value },
  }
}

function parseMode(raw: unknown): ParseResult<AskMode> {
  if (raw === 'single' || raw === 'multi') return { ok: true, value: raw }
  // A mode this surface does not know would put a control on screen that the
  // server refuses, so the row fails to parse rather than guessing single.
  return fail(`unknown question mode ${JSON.stringify(raw)}`)
}

function parseFreeText(raw: unknown): ParseResult<AskFreeText> {
  if (!isRecord(raw)) return fail('free_text must be an object')
  const allowed = raw['allowed']
  if (allowed === false) return { ok: true, value: { allowed: false } }
  if (allowed !== true) return fail('free_text.allowed must be a boolean')
  const hint = optionalString(raw, 'hint')
  if (!hint.ok) return hint
  return { ok: true, value: { allowed: true, hint: hint.value } }
}

function parseQuestion(raw: unknown): ParseResult<AskQuestion> {
  if (!isRecord(raw)) return fail('each question must be an object')
  const questionId = requireString(raw, 'question_id')
  if (!questionId.ok) return questionId
  const header = requireString(raw, 'header')
  if (!header.ok) return header
  const prompt = requireString(raw, 'prompt')
  if (!prompt.ok) return prompt
  const mode = parseMode(raw['mode'])
  if (!mode.ok) return mode
  const freeText = parseFreeText(raw['free_text'])
  if (!freeText.ok) return freeText
  const rawChoices = raw['choices']
  if (!Array.isArray(rawChoices)) return fail('choices must be an array')
  const choices: AskChoice[] = []
  for (const item of rawChoices) {
    const choice = parseChoice(item)
    if (!choice.ok) return choice
    choices.push(choice.value)
  }
  if (choices.length === 0 && !freeText.value.allowed) {
    return fail(`question ${questionId.value} offers no way to answer`)
  }
  return {
    ok: true,
    value: {
      questionId: questionId.value,
      header: header.value,
      prompt: prompt.value,
      mode: mode.value,
      freeText: freeText.value,
      choices,
    },
  }
}

function parseResolution(raw: unknown): ParseResult<AskResolution> {
  if (!isRecord(raw)) return fail('resolution must be an object')
  const state = raw['state']
  if (state === 'open') return { ok: true, value: { state: 'open' } }
  if (state === 'answered') {
    const answeredAt = requireNumber(raw, 'answered_at')
    if (!answeredAt.ok) return answeredAt
    const rawIds = raw['answered_question_ids']
    if (!Array.isArray(rawIds)) return fail('answered_question_ids must be an array')
    const ids: string[] = []
    for (const item of rawIds) {
      if (typeof item !== 'string') return fail('answered_question_ids must contain strings')
      ids.push(item)
    }
    return { ok: true, value: { state: 'answered', answeredAt: answeredAt.value, answeredQuestionIds: ids } }
  }
  if (state === 'withdrawn') {
    const reason = requireString(raw, 'reason')
    if (!reason.ok) return reason
    const withdrawnAt = requireNumber(raw, 'withdrawn_at')
    if (!withdrawnAt.ok) return withdrawnAt
    return { ok: true, value: { state: 'withdrawn', reason: reason.value, withdrawnAt: withdrawnAt.value } }
  }
  return fail(`unknown resolution state ${JSON.stringify(state)}`)
}

function parseRow(raw: unknown): ParseResult<AskRow> {
  if (!isRecord(raw)) return fail('each ask must be an object')
  const keeper = requireString(raw, 'keeper')
  if (!keeper.ok) return keeper
  const askId = requireString(raw, 'ask_id')
  if (!askId.ok) return askId
  const askedAt = requireNumber(raw, 'asked_at')
  if (!askedAt.ok) return askedAt
  const context = optionalString(raw, 'context')
  if (!context.ok) return context
  const rawQuestions = raw['questions']
  if (!Array.isArray(rawQuestions)) return fail('questions must be an array')
  if (rawQuestions.length === 0) return fail(`ask ${askId.value} has no questions`)
  const questions: AskQuestion[] = []
  for (const item of rawQuestions) {
    const question = parseQuestion(item)
    if (!question.ok) return question
    questions.push(question.value)
  }
  const resolution = parseResolution(raw['resolution'])
  if (!resolution.ok) return resolution
  return {
    ok: true,
    value: {
      keeper: keeper.value,
      askId: askId.value,
      askedAt: askedAt.value,
      context: context.value,
      questions,
      resolution: resolution.value,
    },
  }
}

export function parseAsksSnapshot(raw: unknown): ParseResult<AsksSnapshot> {
  if (!isRecord(raw)) return fail('response must be an object')
  const scope = raw['scope']
  if (scope !== 'keeper' && scope !== 'fleet') {
    return fail(`unknown scope ${JSON.stringify(scope)}`)
  }
  const keeper = optionalString(raw, 'keeper')
  if (!keeper.ok) return keeper
  const openCount = requireNumber(raw, 'open_count')
  if (!openCount.ok) return openCount
  const rawRows = raw['asks']
  if (!Array.isArray(rawRows)) return fail('asks must be an array')
  const rows: AskRow[] = []
  for (const item of rawRows) {
    const row = parseRow(item)
    if (!row.ok) return row
    rows.push(row.value)
  }
  return { ok: true, value: { scope, keeper: keeper.value, openCount: openCount.value, rows } }
}
