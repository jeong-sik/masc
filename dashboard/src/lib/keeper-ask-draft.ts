// The answer on its way back to a Keeper.
//
// The domain requires a response for every question of an ask and reports
// every violation together, so a surface that posts a question at a time makes
// the human pay a round trip per mistake. This module holds the whole answer
// as a draft and names what is still missing before the request rather than
// after it.

import type { AskChoice, AskQuestion, AskRow } from './keeper-ask-wire'

export type DraftResponse =
  | { readonly kind: 'chose'; readonly choiceIds: readonly string[] }
  | { readonly kind: 'wrote'; readonly text: string }
  | { readonly kind: 'skipped' }

export type AskDraft = {
  readonly askId: string
  readonly responses: ReadonlyMap<string, DraftResponse>
}

export function emptyDraft(askId: string): AskDraft {
  return { askId, responses: new Map() }
}

/** The draft when it belongs to `row`, a fresh one otherwise. Moving the
    selection to another ask therefore starts clean without the caller having
    to remember to reset. */
export function draftFor(existing: AskDraft | null, row: AskRow): AskDraft {
  if (existing !== null && existing.askId === row.askId) return existing
  return emptyDraft(row.askId)
}

export function responseFor(draft: AskDraft, question: AskQuestion): DraftResponse | null {
  return draft.responses.get(question.questionId) ?? null
}

function withResponse(draft: AskDraft, questionId: string, response: DraftResponse): AskDraft {
  const responses = new Map(draft.responses)
  responses.set(questionId, response)
  return { askId: draft.askId, responses }
}

function withoutResponse(draft: AskDraft, questionId: string): AskDraft {
  if (!draft.responses.has(questionId)) return draft
  const responses = new Map(draft.responses)
  responses.delete(questionId)
  return { askId: draft.askId, responses }
}

function chosenIds(draft: AskDraft, questionId: string): readonly string[] {
  const current = draft.responses.get(questionId)
  return current !== undefined && current.kind === 'chose' ? current.choiceIds : []
}

/** `single` replaces the selection, and re-picking the chosen id clears it, so
    a mis-click needs no separate control. `multi` adds or removes; removing the
    last one clears the response, because an empty selection is not an answer.
    Taking the choice rather than an id means an id this ask never offered
    cannot be drafted. */
export function toggleChoice(draft: AskDraft, question: AskQuestion, choice: AskChoice): AskDraft {
  const chosen = chosenIds(draft, question.questionId)
  const already = chosen.includes(choice.choiceId)
  const next =
    question.mode === 'single'
      ? already
        ? []
        : [choice.choiceId]
      : already
        ? chosen.filter((id) => id !== choice.choiceId)
        : [...chosen, choice.choiceId]
  if (next.length === 0) return withoutResponse(draft, question.questionId)
  return withResponse(draft, question.questionId, { kind: 'chose', choiceIds: next })
}

declare const freeTextSlotBrand: unique symbol

export type FreeTextSlot = {
  readonly questionId: string
  readonly hint: string | null
  readonly [freeTextSlotBrand]: true
}

/** `null` when the question offers choices only. A slot is the only way to
    reach `setText`, so an editor cannot open on a question whose answer the
    server would refuse. */
export function freeTextSlot(question: AskQuestion): FreeTextSlot | null {
  if (!question.freeText.allowed) return null
  return {
    questionId: question.questionId,
    hint: question.freeText.hint,
  } as FreeTextSlot
}

/** Blank text clears the response instead of recording it: the domain rejects
    a blank write, and an editor emptied by backspaces means unanswered. */
export function setText(draft: AskDraft, slot: FreeTextSlot, text: string): AskDraft {
  if (text.trim() === '') return withoutResponse(draft, slot.questionId)
  return withResponse(draft, slot.questionId, { kind: 'wrote', text })
}

export function skipQuestion(draft: AskDraft, question: AskQuestion): AskDraft {
  return withResponse(draft, question.questionId, { kind: 'skipped' })
}

export function clearQuestion(draft: AskDraft, question: AskQuestion): AskDraft {
  return withoutResponse(draft, question.questionId)
}

export type AnswerWire = {
  readonly question_id: string
  readonly response:
    | { readonly kind: 'chose'; readonly choice_ids: readonly string[] }
    | { readonly kind: 'wrote'; readonly text: string }
    | { readonly kind: 'skipped' }
}

export type Readiness =
  | { readonly state: 'ready'; readonly answers: readonly AnswerWire[] }
  | { readonly state: 'missing'; readonly questions: readonly AskQuestion[] }
  /** Already answered or withdrawn. Offering submit here would promise
      something the store settles by first write. */
  | { readonly state: 'not-open' }

function answerWire(question: AskQuestion, response: DraftResponse): AnswerWire {
  if (response.kind === 'chose') {
    return { question_id: question.questionId, response: { kind: 'chose', choice_ids: response.choiceIds } }
  }
  if (response.kind === 'wrote') {
    return { question_id: question.questionId, response: { kind: 'wrote', text: response.text } }
  }
  return { question_id: question.questionId, response: { kind: 'skipped' } }
}

/** A draft belonging to another ask contributes nothing, so the answer is
    every question missing -- which is true, not a guess. */
export function readiness(draft: AskDraft, row: AskRow): Readiness {
  if (row.resolution.state !== 'open') return { state: 'not-open' }
  const belongs = draft.askId === row.askId
  const missing: AskQuestion[] = []
  const answers: AnswerWire[] = []
  for (const question of row.questions) {
    const response = belongs ? draft.responses.get(question.questionId) : undefined
    if (response === undefined) missing.push(question)
    else answers.push(answerWire(question, response))
  }
  if (missing.length > 0) return { state: 'missing', questions: missing }
  return { state: 'ready', answers }
}

export type AnswerRequestBody = {
  readonly name: string
  readonly ask_id: string
  readonly answers: readonly AnswerWire[]
  readonly actor_id?: string
  readonly session_id?: string
}

export function answerRequestBody(
  row: AskRow,
  answers: readonly AnswerWire[],
  identity: { readonly actorId?: string | null; readonly sessionId?: string | null } = {},
): AnswerRequestBody {
  const actorId = identity.actorId?.trim()
  const sessionId = identity.sessionId?.trim()
  return {
    name: row.keeper,
    ask_id: row.askId,
    answers,
    ...(actorId !== undefined && actorId !== '' ? { actor_id: actorId } : {}),
    ...(sessionId !== undefined && sessionId !== '' ? { session_id: sessionId } : {}),
  }
}
