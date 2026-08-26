import { describe, expect, it } from 'vitest'
import type { AskChoice, AskQuestion, AskRow } from './keeper-ask-wire'
import {
  answerRequestBody,
  clearQuestion,
  draftFor,
  emptyDraft,
  freeTextSlot,
  readiness,
  responseFor,
  setText,
  skipQuestion,
  toggleChoice,
} from './keeper-ask-draft'

// Every case here is one an operator reaches with two clicks, so a regression
// shows up as a wrong click rather than a wrong type.

const yes: AskChoice = { choiceId: 'yes', label: 'Yes', description: null }
const no: AskChoice = { choiceId: 'no', label: 'No', description: null }

function question(overrides: Partial<AskQuestion> = {}): AskQuestion {
  return {
    questionId: 'q1',
    header: 'Header',
    prompt: 'Prompt',
    mode: 'single',
    freeText: { allowed: false },
    choices: [yes, no],
    ...overrides,
  }
}

function row(overrides: Partial<AskRow> = {}): AskRow {
  return {
    keeper: 'asker',
    askId: 'a1',
    askedAt: 1,
    context: null,
    questions: [question()],
    resolution: { state: 'open' },
    ...overrides,
  }
}

const single = question()
const multi = question({ mode: 'multi' })
const textOnly = question({ freeText: { allowed: true, hint: null }, choices: [] })

function slotOf(q: AskQuestion) {
  const slot = freeTextSlot(q)
  if (slot === null) throw new Error('expected a slot')
  return slot
}

describe('draft ownership', () => {
  it('keeps a draft that belongs to the row', () => {
    const drafted = toggleChoice(emptyDraft('a1'), single, yes)
    expect(draftFor(drafted, row())).toBe(drafted)
  })

  it('starts clean when the selection moves to another ask', () => {
    const drafted = toggleChoice(emptyDraft('a1'), single, yes)
    const fresh = draftFor(drafted, row({ askId: 'a2' }))
    expect(fresh.askId).toBe('a2')
    expect(responseFor(fresh, single)).toBeNull()
  })
})

describe('choices', () => {
  it('replaces the selection on a single-answer question', () => {
    let draft = toggleChoice(emptyDraft('a1'), single, yes)
    draft = toggleChoice(draft, single, no)
    expect(responseFor(draft, single)).toEqual({ kind: 'chose', choiceIds: ['no'] })
  })

  it('clears when the chosen one is picked again', () => {
    let draft = toggleChoice(emptyDraft('a1'), single, yes)
    draft = toggleChoice(draft, single, yes)
    expect(responseFor(draft, single)).toBeNull()
  })

  it('keeps the order the operator picked', () => {
    let draft = toggleChoice(emptyDraft('a1'), multi, no)
    draft = toggleChoice(draft, multi, yes)
    expect(responseFor(draft, multi)).toEqual({ kind: 'chose', choiceIds: ['no', 'yes'] })
  })

  it('removes one without disturbing the rest', () => {
    let draft = toggleChoice(emptyDraft('a1'), multi, no)
    draft = toggleChoice(draft, multi, yes)
    draft = toggleChoice(draft, multi, no)
    expect(responseFor(draft, multi)).toEqual({ kind: 'chose', choiceIds: ['yes'] })
  })

  it('treats an emptied selection as unanswered', () => {
    let draft = toggleChoice(emptyDraft('a1'), multi, yes)
    draft = toggleChoice(draft, multi, yes)
    expect(responseFor(draft, multi)).toBeNull()
  })

  it('leaves the previous draft untouched', () => {
    const before = toggleChoice(emptyDraft('a1'), multi, yes)
    toggleChoice(before, multi, no)
    expect(responseFor(before, multi)).toEqual({ kind: 'chose', choiceIds: ['yes'] })
  })
})

describe('free text', () => {
  it('offers no slot on a choices-only question', () => {
    expect(freeTextSlot(single)).toBeNull()
  })

  it('carries the hint to the editor', () => {
    const slot = slotOf(question({ freeText: { allowed: true, hint: 'one line' } }))
    expect(slot.hint).toBe('one line')
  })

  it('records what was written', () => {
    const draft = setText(emptyDraft('a1'), slotOf(textOnly), 'ship it')
    expect(responseFor(draft, textOnly)).toEqual({ kind: 'wrote', text: 'ship it' })
  })

  it('treats an emptied editor as unanswered', () => {
    const slot = slotOf(textOnly)
    let draft = setText(emptyDraft('a1'), slot, 'draft')
    draft = setText(draft, slot, '   ')
    expect(responseFor(draft, textOnly)).toBeNull()
  })
})

describe('skip and clear', () => {
  it('counts a skip as an answer', () => {
    const draft = skipQuestion(emptyDraft('a1'), single)
    expect(responseFor(draft, single)).toEqual({ kind: 'skipped' })
  })

  it('clears back to unanswered', () => {
    const draft = clearQuestion(toggleChoice(emptyDraft('a1'), single, yes), single)
    expect(responseFor(draft, single)).toBeNull()
  })
})

const q1 = question({ questionId: 'q1' })
const q2 = question({ questionId: 'q2' })
const twoQuestions = row({ questions: [q1, q2] })

describe('readiness', () => {
  it('names every gap at once', () => {
    const result = readiness(emptyDraft('a1'), twoQuestions)
    expect(result.state).toBe('missing')
    if (result.state !== 'missing') return
    expect(result.questions.map((q) => q.questionId)).toEqual(['q1', 'q2'])
  })

  it('shrinks as questions are answered', () => {
    const result = readiness(skipQuestion(emptyDraft('a1'), q1), twoQuestions)
    expect(result.state).toBe('missing')
    if (result.state !== 'missing') return
    expect(result.questions.map((q) => q.questionId)).toEqual(['q2'])
  })

  it('sends answers in the ask order, not the click order', () => {
    let draft = skipQuestion(emptyDraft('a1'), q2)
    draft = toggleChoice(draft, q1, yes)
    const result = readiness(draft, twoQuestions)
    expect(result.state).toBe('ready')
    if (result.state !== 'ready') return
    expect(result.answers.map((a) => a.question_id)).toEqual(['q1', 'q2'])
  })

  it('encodes each response shape the endpoint decodes', () => {
    const q3 = question({ questionId: 'q3', freeText: { allowed: true, hint: null }, choices: [] })
    const three = row({ questions: [q1, q2, q3] })
    let draft = toggleChoice(emptyDraft('a1'), q1, yes)
    draft = skipQuestion(draft, q2)
    draft = setText(draft, slotOf(q3), 'because')
    const result = readiness(draft, three)
    expect(result.state).toBe('ready')
    if (result.state !== 'ready') return
    expect(result.answers).toEqual([
      { question_id: 'q1', response: { kind: 'chose', choice_ids: ['yes'] } },
      { question_id: 'q2', response: { kind: 'skipped' } },
      { question_id: 'q3', response: { kind: 'wrote', text: 'because' } },
    ])
  })

  it('offers nothing on an answered ask', () => {
    const answered = row({
      resolution: { state: 'answered', answeredAt: 2, answeredQuestionIds: ['q1'] },
    })
    expect(readiness(emptyDraft('a1'), answered).state).toBe('not-open')
  })

  it('offers nothing on a withdrawn ask', () => {
    const withdrawn = row({ resolution: { state: 'withdrawn', reason: 'moot', withdrawnAt: 2 } })
    expect(readiness(emptyDraft('a1'), withdrawn).state).toBe('not-open')
  })

  it('ignores a draft that belongs to another ask', () => {
    const foreign = skipQuestion(emptyDraft('OTHER'), q1)
    const result = readiness(foreign, twoQuestions)
    expect(result.state).toBe('missing')
    if (result.state !== 'missing') return
    expect(result.questions.map((q) => q.questionId)).toEqual(['q1', 'q2'])
  })
})

describe('answerRequestBody', () => {
  it('names the keeper and the ask the way the endpoint reads them', () => {
    const body = answerRequestBody(row(), [
      { question_id: 'q1', response: { kind: 'skipped' } },
    ])
    expect(JSON.parse(JSON.stringify(body))).toEqual({
      name: 'asker',
      ask_id: 'a1',
      answers: [{ question_id: 'q1', response: { kind: 'skipped' } }],
    })
  })

  it('leaves out a blank identity instead of sending an empty string', () => {
    const body = answerRequestBody(row(), [], { actorId: '   ', sessionId: null })
    expect('actor_id' in body).toBe(false)
    expect('session_id' in body).toBe(false)
  })

  it('carries the identity when there is one', () => {
    const body = answerRequestBody(row(), [], { actorId: 'vincent', sessionId: 's1' })
    expect(body.actor_id).toBe('vincent')
    expect(body.session_id).toBe('s1')
  })
})
