// MASC Dashboard — the questions Keepers are waiting on, and the answer going
// back.
//
// One draft at a time. The draft carries the ask it belongs to, so selecting
// another question cannot post an answer under the wrong one; `draftFor` is
// what enforces that rather than a reset the caller has to remember.

import { signal } from '@preact/signals'
import { createManagedAsyncResource } from '../lib/async-state'
import { AskAnswerConflict, answerKeeperAsk, fetchKeeperAsks } from '../api/keeper-asks'
import type { AskRow, AsksSnapshot } from '../lib/keeper-ask-wire'
import {
  answerRequestBody,
  draftFor,
  emptyDraft,
  readiness,
  type AskDraft,
} from '../lib/keeper-ask-draft'

export const asksResource = createManagedAsyncResource<AsksSnapshot>()

/** Which ask the operator is answering. Null means they are only reading. */
export const openAskId = signal<string | null>(null)
export const askDraft = signal<AskDraft | null>(null)
export const askSubmitting = signal(false)
export const askError = signal<string | null>(null)
/** Set when someone else answered first; cleared on the next selection. */
export const askConflict = signal<string | null>(null)

export function refreshKeeperAsks(): Promise<AsksSnapshot | undefined> {
  return asksResource.load(async () => fetchKeeperAsks())
}

export function selectAsk(row: AskRow): void {
  openAskId.value = row.askId
  askDraft.value = draftFor(askDraft.value, row)
  askError.value = null
  askConflict.value = null
}

export function closeAsk(): void {
  openAskId.value = null
  askDraft.value = null
  askError.value = null
}

export function updateDraft(next: AskDraft): void {
  askDraft.value = next
  // Editing after a failed submit clears the complaint: the operator is
  // already acting on it, and a stale error beside a changed draft reads as a
  // second problem.
  askError.value = null
}

export function draftForRow(row: AskRow): AskDraft {
  return draftFor(askDraft.value, row) ?? emptyDraft(row.askId)
}

export async function submitAnswer(row: AskRow, actorId: string | null): Promise<boolean> {
  const draft = draftFor(askDraft.value, row)
  const state = readiness(draft, row)
  if (state.state === 'not-open') {
    askError.value = '이미 답이 달린 질문입니다'
    return false
  }
  if (state.state === 'missing') {
    // Every gap at once, the way the domain reports them: fixing one and then
    // learning about the next is a round trip per mistake.
    askError.value = `아직 답하지 않은 질문: ${state.questions.map((q) => q.header).join(', ')}`
    return false
  }
  askSubmitting.value = true
  askError.value = null
  askConflict.value = null
  try {
    await answerKeeperAsk(answerRequestBody(row, state.answers, { actorId }))
    closeAsk()
    await refreshKeeperAsks()
    return true
  } catch (error) {
    if (error instanceof AskAnswerConflict) {
      askConflict.value = '다른 사람이 먼저 답했습니다. 새로 읽은 내용을 확인해 주세요.'
      closeAsk()
      await refreshKeeperAsks()
      return false
    }
    askError.value = error instanceof Error ? error.message : String(error)
    return false
  } finally {
    askSubmitting.value = false
  }
}
