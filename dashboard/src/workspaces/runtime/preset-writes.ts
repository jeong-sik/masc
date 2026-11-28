/**
 * The preset write in flight and what the last one left, kept outside the
 * Presets view.
 *
 * - One write may be in flight even when its form or the whole tab is gone,
 *   so the outcome lives in a module signal and `PresetFeedback` shows it
 *   in either view of Runtime → Prompts.
 * - A new write replaces what the last one left: its refusal, its taken
 *   name, and its restore report. An old report next to a new failure would
 *   read as the new result.
 * - Scoped to one session epoch. A new session starts empty. A write still
 *   in flight then has no answer anyone reads, so the operator is told that,
 *   without naming the preset.
 */

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { sessionEpoch } from '../../core'
import { pushShellToast } from '../../shell/shell-state'
import { RestoreReportView } from './preset-restore-report'
import type { RestoreReport } from './presets-wire'

export type PresetWrite = { readonly target: string; readonly action: '저장' | '복원' | '삭제' }

/** A save the server refused because the name exists: what to send if the operator replaces it. */
export type TakenName = { readonly name: string; readonly description: string }

type WriteFeedback = {
  readonly epoch: number
  readonly active: PresetWrite | null
  readonly refusal: string | null
  readonly taken: TakenName | null
  readonly report: RestoreReport | null
}

const idleFeedback = (epoch: number): WriteFeedback => ({ epoch, active: null, refusal: null, taken: null, report: null })

const writeFeedback = signal<WriteFeedback>(idleFeedback(sessionEpoch.peek()))
sessionEpoch.subscribe(epoch => {
  const before = writeFeedback.peek()
  if (before.epoch === epoch) return
  if (before.active !== null) {
    pushShellToast('세션이 바뀌어서 보내던 프리셋 요청의 결과를 확인하지 못했어요. 프리셋 목록을 다시 확인해 주세요.', 'warning')
  }
  writeFeedback.value = idleFeedback(epoch)
})

/** What the Presets view reads: whether a write is out, and a taken name waiting for the operator. */
export function presetWriteState(epoch: number): { readonly busy: boolean; readonly taken: TakenName | null } {
  const state = writeFeedback.value
  return state.epoch === epoch ? { busy: state.active !== null, taken: state.taken } : { busy: false, taken: null }
}

export function beginWrite(epoch: number, active: PresetWrite): boolean {
  const before = writeFeedback.peek()
  if (epoch !== sessionEpoch.peek() || (before.epoch === epoch && before.active !== null)) return false
  writeFeedback.value = { ...idleFeedback(epoch), active }
  return true
}

export function finishWrite(epoch: number, result: Partial<Pick<WriteFeedback, 'refusal' | 'taken' | 'report'>> = {}): void {
  if (epoch !== sessionEpoch.peek()) return
  writeFeedback.value = { ...writeFeedback.peek(), ...result, active: null }
}

function dismiss(field: 'refusal' | 'taken' | 'report', epoch: number): void {
  const current = writeFeedback.peek()
  if (current.epoch === epoch && current[field] !== null) writeFeedback.value = { ...current, [field]: null }
}

export function dismissTaken(epoch: number): void {
  dismiss('taken', epoch)
}

export function PresetFeedback() {
  const state = writeFeedback.value
  const epoch = sessionEpoch.value
  if (state.epoch !== epoch) return null
  return html`
    ${state.active !== null && html`
      <div class="wka-card" role="status" data-testid="preset-write-pending">
        ${state.active.target} 프리셋 ${state.active.action} 중…
      </div>
    `}
    ${state.refusal !== null && html`
      <div role="alert" class="ap-error" data-testid="preset-refusal" style=${{ display: 'flex', gap: 'var(--sp-2)', alignItems: 'center' }}>
        <span style=${{ flex: '1 1 auto', minWidth: 0, overflowWrap: 'anywhere' }}>${state.refusal}</span>
        <button type="button" class="btn-ghost btn-compact" data-testid="preset-refusal-dismiss" onClick=${() => dismiss('refusal', epoch)}>닫기</button>
      </div>
    `}
    ${state.report !== null && html`
      <${RestoreReportView} report=${state.report} onDismiss=${() => dismiss('report', epoch)} />
    `}
  `
}

// The preset whose detail is on screen. An answer reads it once, to read
// that detail again; it is `null` while the Presets view is not mounted.
let shown: string | null = null

/** Called by the mounted Presets view. */
export function markShownPreset(name: string | null): void {
  shown = name
}

export function shownPreset(): string | null {
  return shown
}
