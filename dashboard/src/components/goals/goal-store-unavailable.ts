// RFC-0444 §2.3 row 4: the Goal tree's alert block for a Goal store this
// build cannot read. Draws the file, the reason (with the refused field), the
// .last-good mirror status and the reset step in plain words.

import { html } from 'htm/preact'
import {
  GOAL_STORE_UNAVAILABLE_TITLE,
  goalStoreMirrorLabel,
  goalStoreReasonLabel,
  goalStoreResetStepLabel,
} from '../../lib/goal-store-unavailable-labels'
import type { GoalStoreUnavailable } from '../../types'

export function GoalStoreUnavailableAlert({ unavailable }: { unavailable: GoalStoreUnavailable }) {
  return html`
    <div
      class="flex flex-col gap-1 rounded-[var(--r-0)] border border-[var(--bad-30)] bg-[var(--bad-12)] px-4 py-3 text-sm text-[var(--bad-light)]"
      role="alert"
      data-testid="goal-store-unavailable"
      data-reason=${unavailable.reason}
      data-reset-step=${unavailable.resetStep}
    >
      <div class="font-semibold">${GOAL_STORE_UNAVAILABLE_TITLE}</div>
      <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 text-xs">
        <dt>파일</dt>
        <dd class="font-mono break-all" data-testid="goal-store-unavailable-file">${unavailable.file}</dd>
        <dt>원인</dt>
        <dd data-testid="goal-store-unavailable-reason">${goalStoreReasonLabel(unavailable.reason, unavailable.field)}</dd>
        <dt>미러</dt>
        <dd data-testid="goal-store-unavailable-mirror">${goalStoreMirrorLabel(unavailable.mirror)}</dd>
        <dt>다음 단계</dt>
        <dd data-testid="goal-store-unavailable-reset-step">${goalStoreResetStepLabel(unavailable.resetStep, unavailable.field)}</dd>
      </dl>
    </div>
  `
}
