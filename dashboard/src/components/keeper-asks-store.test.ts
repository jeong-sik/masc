import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AskRow } from '../lib/keeper-ask-wire'
import { skipQuestion, toggleChoice } from '../lib/keeper-ask-draft'

// The transport is stubbed so these cover what the store decides, not what the
// network does. What the store decides is: which draft belongs to which ask,
// what happens when the answer is incomplete, and what happens when somebody
// answered first.
const answerKeeperAsk = vi.fn()
const fetchKeeperAsks = vi.fn()

vi.mock('../api/keeper-asks', async () => {
  const actual = await vi.importActual<typeof import('../api/keeper-asks')>('../api/keeper-asks')
  return {
    ...actual,
    answerKeeperAsk: (...args: unknown[]) => answerKeeperAsk(...args),
    fetchKeeperAsks: (...args: unknown[]) => fetchKeeperAsks(...args),
  }
})

const store = await import('./keeper-asks-store')
const { AskAnswerConflict } = await import('../api/keeper-asks')

function row(overrides: Partial<AskRow> = {}): AskRow {
  return {
    keeper: 'orrery',
    askId: 'a1',
    askedAt: 1,
    context: null,
    questions: [
      {
        questionId: 'q1',
        header: '이관 방식',
        prompt: '어느 쪽으로 갈까요?',
        mode: 'single',
        freeText: { allowed: false },
        choices: [
          { choiceId: 'now', label: '지금', description: null },
          { choiceId: 'wait', label: '나중', description: null },
        ],
      },
      {
        questionId: 'q2',
        header: '시간대',
        prompt: '언제요?',
        mode: 'multi',
        freeText: { allowed: false },
        choices: [{ choiceId: 'night', label: '밤', description: null }],
      },
    ],
    resolution: { state: 'open' },
    ...overrides,
  }
}

beforeEach(() => {
  answerKeeperAsk.mockReset()
  fetchKeeperAsks.mockReset()
  fetchKeeperAsks.mockResolvedValue({ scope: 'fleet', keeper: null, openCount: 0, rows: [] })
  store.closeAsk()
  store.askConflict.value = null
})

afterEach(() => {
  store.closeAsk()
})

describe('draft ownership', () => {
  it('starts a clean draft when another ask is selected', () => {
    const first = row()
    store.selectAsk(first)
    store.updateDraft(toggleChoice(store.draftForRow(first), first.questions[0]!, first.questions[0]!.choices[0]!))
    const second = row({ askId: 'a2' })
    store.selectAsk(second)
    expect(store.draftForRow(second).askId).toBe('a2')
    expect(store.draftForRow(second).responses.size).toBe(0)
  })
})

describe('submitAnswer', () => {
  it('names every unanswered question instead of sending a partial answer', async () => {
    const r = row()
    store.selectAsk(r)
    const sent = await store.submitAnswer(r, null)
    expect(sent).toBe(false)
    expect(answerKeeperAsk).not.toHaveBeenCalled()
    expect(store.askError.value).toContain('이관 방식')
    expect(store.askError.value).toContain('시간대')
  })

  it('sends once every question has an answer', async () => {
    const r = row()
    store.selectAsk(r)
    let draft = toggleChoice(store.draftForRow(r), r.questions[0]!, r.questions[0]!.choices[0]!)
    draft = skipQuestion(draft, r.questions[1]!)
    store.updateDraft(draft)
    answerKeeperAsk.mockResolvedValue({ askId: 'a1', answerCount: 2, openRemaining: 0 })
    const sent = await store.submitAnswer(r, 'vincent')
    expect(sent).toBe(true)
    expect(answerKeeperAsk).toHaveBeenCalledTimes(1)
    const body = answerKeeperAsk.mock.calls[0]![0] as Record<string, unknown>
    expect(body['name']).toBe('orrery')
    expect(body['ask_id']).toBe('a1')
    expect(body['actor_id']).toBe('vincent')
    expect(fetchKeeperAsks).toHaveBeenCalled()
  })

  it('refuses an ask that already has an answer', async () => {
    const answered = row({
      resolution: { state: 'answered', answeredAt: 2, answeredQuestionIds: ['q1'] },
    })
    store.selectAsk(answered)
    expect(await store.submitAnswer(answered, null)).toBe(false)
    expect(answerKeeperAsk).not.toHaveBeenCalled()
    expect(store.askError.value).toContain('이미 답이 달린')
  })

  it('tells the operator when someone answered first, and rereads', async () => {
    const r = row()
    store.selectAsk(r)
    let draft = skipQuestion(store.draftForRow(r), r.questions[0]!)
    draft = skipQuestion(draft, r.questions[1]!)
    store.updateDraft(draft)
    answerKeeperAsk.mockRejectedValue(new AskAnswerConflict('a1', 'already answered at 2'))
    const sent = await store.submitAnswer(r, null)
    expect(sent).toBe(false)
    expect(store.askConflict.value).toContain('먼저 답했습니다')
    expect(fetchKeeperAsks).toHaveBeenCalled()
    expect(store.openAskId.value).toBeNull()
  })

  it('keeps the draft open when the request itself failed', async () => {
    const r = row()
    store.selectAsk(r)
    let draft = skipQuestion(store.draftForRow(r), r.questions[0]!)
    draft = skipQuestion(draft, r.questions[1]!)
    store.updateDraft(draft)
    answerKeeperAsk.mockRejectedValue(new Error('network is down'))
    expect(await store.submitAnswer(r, null)).toBe(false)
    // The draft is still the operator's work; closing it would throw it away
    // over something that may succeed on the next press.
    expect(store.openAskId.value).toBe('a1')
    expect(store.askError.value).toContain('network is down')
  })
})
