/**
 * What the operator typed and sent in Runtime → Prompts, per prompt.
 *
 * - Kept outside the tab. Picking another prompt unmounts the detail, and
 *   leaving Prompts for another Runtime tab unmounts the whole tab; an answer
 *   that arrives then still lands here. Coming back shows the draft, the
 *   request still in flight, or what the server answered.
 * - One request per prompt is in flight at a time, whichever button sent it.
 * - Scoped to one session epoch, like the preset write state. A new session
 *   starts empty. A request still in flight then has no answer anyone reads,
 *   so the operator is told that, without naming the prompt.
 * - A page reload drops it all.
 */

import { signal, type ReadonlySignal } from '@preact/signals'
import { sessionEpoch } from '../../core'
import { pushShellToast } from '../../shell/shell-state'
import type { PromptOverrideRequest } from './prompts-wire'

/** A request for one prompt: in flight, refused with the server's reason, or sent with no answer to read. */
export type PromptWrite =
  | { readonly kind: 'sending' }
  | { readonly kind: 'refused'; readonly action: PromptOverrideRequest['action']; readonly why: string }
  | { readonly kind: 'unknown'; readonly why: string }

export type PromptWriteEnd = Exclude<PromptWrite, { readonly kind: 'sending' }>

/** What the operator reads about a request that ended without being applied. */
export function writeEndText(end: PromptWriteEnd): string {
  switch (end.kind) {
    case 'refused':
      return `${end.action === 'set' ? '저장하지' : 'override 를 지우지'} 못했어요: ${end.why}`
    case 'unknown':
      return `결과를 알 수 없어요 (${end.why}). 목록을 다시 읽었어요.`
  }
}

export interface PromptEdits {
  readonly epoch: number
  readonly drafts: ReadonlyMap<string, string>
  readonly writes: ReadonlyMap<string, PromptWrite>
}

const emptyEdits = (epoch: number): PromptEdits => ({ epoch, drafts: new Map(), writes: new Map() })

const edits = signal<PromptEdits>(emptyEdits(sessionEpoch.peek()))
sessionEpoch.subscribe(epoch => {
  const before = edits.peek()
  if (before.epoch === epoch) return
  if ([...before.writes.values()].some(w => w.kind === 'sending')) {
    pushShellToast('세션이 바뀌어서 보내던 프롬프트 요청의 결과를 확인하지 못했어요. 목록을 다시 확인해 주세요.', 'warning')
  }
  edits.value = emptyEdits(epoch)
})

export const promptEdits: ReadonlySignal<PromptEdits> = edits

/** The edits of `epoch`, or none when the session moved on. */
export function promptEditsFor(epoch: number): PromptEdits {
  const current = edits.value
  return current.epoch === epoch ? current : emptyEdits(epoch)
}

function withEntry<V>(map: ReadonlyMap<string, V>, key: string, value: V | undefined): ReadonlyMap<string, V> {
  const next = new Map(map)
  if (value === undefined) next.delete(key)
  else next.set(key, value)
  return next
}

export function setPromptDraft(epoch: number, key: string, text: string | undefined): void {
  const current = edits.peek()
  if (current.epoch !== epoch) return
  edits.value = { ...current, drafts: withEntry(current.drafts, key, text) }
}

/** Marks a request for `key` in flight; false when one already is, or the session moved on. */
export function beginPromptWrite(epoch: number, key: string): boolean {
  const current = edits.peek()
  if (current.epoch !== epoch || current.writes.get(key)?.kind === 'sending') return false
  edits.value = { ...current, writes: withEntry(current.writes, key, { kind: 'sending' }) }
  return true
}

/** Ends the request for `key` with what the server answered (`undefined`: applied), dropping the draft if asked. */
export function finishPromptWrite(epoch: number, key: string, end: PromptWriteEnd | undefined, dropDraft: boolean): void {
  const current = edits.peek()
  if (current.epoch !== epoch) return
  edits.value = {
    ...current,
    writes: withEntry(current.writes, key, end),
    drafts: dropDraft ? withEntry(current.drafts, key, undefined) : current.drafts,
  }
}

// The prompt whose detail is on screen. It is not part of the edits: an
// answer reads it once, to decide whether the operator would see the outcome.
let shown: string | null = null

/** Called by the mounted tab; `null` when no prompt detail is on screen. */
export function markShownPrompt(key: string | null): void {
  shown = key
}

export function isPromptShown(key: string): boolean {
  return shown === key
}
