import { isDismissEscape } from '../../lib/keyboard'
// Goal creation form — right-hand side panel in the Work surface.
// Design reference: prototype NewGoalComposer (work.jsx ~line 437).
// A new Goal declares its measured quantity and target alongside its title.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import type { RenderableProps } from 'preact'
import { useEffect, useRef } from 'preact/hooks'
import { TextInput } from '../common/input'
import { ActionButton } from '../common/button'
import { goalStoreUnavailable } from '../../goal-tree-state'
import { goalStoreUnavailableSummary } from '../../lib/goal-store-unavailable-labels'
import type { ArtifactWorkspace } from '../../api/published-artifacts'
import { storedTokenRevision } from '../../api/token-revision'
import { dashboardActorRevision } from '../../lib/dashboard-session-actor'
import { executionWorkspaceAuthority } from '../../store'
import type { GoalStoreUnavailable } from '../../types/goal-store-unavailable'
import {
  showGoalCreate,
  goalCreating,
  goalCreateError,
  goalCreateOutcomes,
  goalCreateOutcomeIsCurrent,
  goalCreateDraftHasOutcome,
  dismissGoalCreateOutcome,
  createGoal,
  currentGoalCreateDraft,
  resetGoalCreateForm,
  goalCreateErrorMessage,
  GOAL_PRIORITY_MIN,
  GOAL_PRIORITY_MAX,
  GOAL_PRIORITY_DEFAULT,
} from './goal-create-state'

// ── Local form state signals ─────────────────────────────────────────────────

const titleSignal = signal('')
const metricSignal = signal('')
const targetSignal = signal('')
const prioritySignal = signal(GOAL_PRIORITY_DEFAULT)

export function resetGoalCreateFormLocal(): void {
  titleSignal.value = ''
  metricSignal.value = ''
  targetSignal.value = ''
  prioritySignal.value = GOAL_PRIORITY_DEFAULT
  resetGoalCreateForm()
}

// ── Component ────────────────────────────────────────────────────────────────

export type GoalCreateSource =
  | { kind: 'ready' }
  | { kind: 'unconfirmed' }
  | { kind: 'unavailable'; unavailable: GoalStoreUnavailable }

export function GoalCreateForm({ source, isStoreUnavailableNow, currentWorkspace, isWorkspaceCurrent }: RenderableProps<{
  source?: GoalCreateSource
  isStoreUnavailableNow?: () => boolean
  currentWorkspace?: ArtifactWorkspace | null
  isWorkspaceCurrent?: () => boolean
}> = {}) {
  const workspaceView = useRef({ currentWorkspace, isWorkspaceCurrent })
  workspaceView.current = { currentWorkspace, isWorkspaceCurrent }
  // Escape key dismisses
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (isDismissEscape(e) && showGoalCreate.value) {
        e.stopPropagation()
        showGoalCreate.value = false
        resetGoalCreateFormLocal()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => { window.removeEventListener('keydown', onKey) }
  }, [])

  if (!showGoalCreate.value) return null

  const handleSubmit = () => {
    // Recheck at the event boundary in case an owned failure arrived after
    // the last render. The server still makes the final write decision.
    const unavailableNow = () => isStoreUnavailableNow ? isStoreUnavailableNow()
      : source === undefined ? goalStoreUnavailable.peek() !== null : source.kind === 'unavailable'
    if (unavailableNow()) return
    const owner = currentGoalCreateDraft()
    void createGoal({
      title: titleSignal.value,
      metric: metricSignal.value,
      targetValue: targetSignal.value,
      priority: prioritySignal.value,
    }, unavailableNow, workspace => {
      const view = workspaceView.current
      if (!view.isWorkspaceCurrent?.() || !view.currentWorkspace) return 'unconfirmed'
      return view.currentWorkspace.basePath === workspace.basePath && view.currentWorkspace.mascRoot === workspace.mascRoot
        ? 'current' : 'different'
    }).then(ok => {
      if (ok && owner === currentGoalCreateDraft()) resetGoalCreateFormLocal()
    })
  }

  const handleClose = () => {
    showGoalCreate.value = false
    resetGoalCreateFormLocal()
  }

  const isTitleEmpty = !titleSignal.value.trim()
  const isMetricEmpty = !metricSignal.value.trim()
  const isTargetEmpty = !targetSignal.value.trim()
  // RFC-0444 §2.2: every Goal write is refused while the store cannot be read,
  // so the form does not offer a submit that the server would reject.
  // Only the standalone form falls back to the shared observation. A Work
  // source explicitly says whether its own bound observation is unavailable.
  const sourceUnavailable = source === undefined ? goalStoreUnavailable.value
    : source.kind === 'unavailable' ? source.unavailable : null
  // The actor revision triggers a render even when no other signal changes.
  void dashboardActorRevision.value
  void executionWorkspaceAuthority.value
  void storedTokenRevision.value
  const visibleOutcomes = goalCreateOutcomes.value.filter(goalCreateOutcomeIsCurrent)
  const isSubmitDisabled = goalCreating.value || isTitleEmpty || isMetricEmpty || isTargetEmpty
    || sourceUnavailable !== null || goalCreateDraftHasOutcome(visibleOutcomes)
  const error = goalCreateError.value
  const visibleError = error?.kind === 'uncertain'
    && !visibleOutcomes.some(outcome => outcome.ticket === error.ticket) ? null : error

  return html`
    <aside
      class="wk-goal-create-panel"
      role="form"
      aria-labelledby="goal-create-title"
      data-testid="goal-create-panel"
    >
      <div class="wk-goal-create-hd">
        <div>
          <div class="wk-goal-create-eyebrow">성공 기준이 있는 목표</div>
          <h3 id="goal-create-title">새 목표</h3>
        </div>
        <button
          type="button"
          class="wk-goal-create-close"
          data-testid="goal-create-close"
          onClick=${handleClose}
          aria-label="닫기 (Esc)"
        >✕</button>
      </div>

      <div class="wk-goal-create-body">
        <div class="wk-goal-create-sec">
          <label
            for="goal-create-title-input"
            class="wk-goal-create-label"
          >
            제목<span class="wk-goal-create-req">*</span>
          </label>
          <${TextInput}
            id="goal-create-title-input"
            testId="goal-create-title-input"
            value=${titleSignal.value}
            placeholder="예) scheduler p99 SLO 400ms 회복"
            autoFocus=${true}
            required=${true}
            disabled=${goalCreating.value}
            onInput=${(e: Event) => { titleSignal.value = (e.target as HTMLInputElement).value }}
          />
          ${isTitleEmpty && goalCreateError.value?.kind === 'title_empty' ? html`
            <p class="wk-goal-create-err" role="alert" data-testid="goal-create-title-error">
              ${goalCreateErrorMessage(goalCreateError.value)}
            </p>
          ` : null}
        </div>

        <div class="wk-goal-create-sec">
          <label for="goal-create-metric" class="wk-goal-create-label">
            측정 지표<span class="wk-goal-create-req">*</span>
          </label>
          <${TextInput}
            id="goal-create-metric"
            testId="goal-create-metric"
            required=${true}
            disabled=${goalCreating.value}
            value=${metricSignal.value}
            placeholder="예) 24시간 운전 중 scheduler 지연 p99"
            onInput=${(e: Event) => { metricSignal.value = (e.target as HTMLInputElement).value }}
          />
          ${goalCreateError.value?.kind === 'metric_empty' ? html`
            <p class="wk-goal-create-err" role="alert">${goalCreateErrorMessage(goalCreateError.value)}</p>
          ` : null}
        </div>

        <div class="wk-goal-create-sec">
          <label for="goal-create-target" class="wk-goal-create-label">
            목표 값<span class="wk-goal-create-req">*</span>
          </label>
          <${TextInput}
            id="goal-create-target"
            testId="goal-create-target"
            required=${true}
            disabled=${goalCreating.value}
            value=${targetSignal.value}
            placeholder="예) 400ms 이하"
            onInput=${(e: Event) => { targetSignal.value = (e.target as HTMLInputElement).value }}
          />
          ${goalCreateError.value?.kind === 'target_empty' ? html`
            <p class="wk-goal-create-err" role="alert">${goalCreateErrorMessage(goalCreateError.value)}</p>
          ` : null}
        </div>

        <div class="wk-goal-create-sec">
          <label
            for="goal-create-priority"
            class="wk-goal-create-label"
          >
            우선순위 · <span class="mono">P${prioritySignal.value}</span>
          </label>
          <input
            id="goal-create-priority"
            type="range"
            disabled=${goalCreating.value}
            class="wk-goal-create-range"
            data-testid="goal-create-priority"
            min=${GOAL_PRIORITY_MIN}
            max=${GOAL_PRIORITY_MAX}
            value=${prioritySignal.value}
            onInput=${(e: Event) => { prioritySignal.value = Number((e.target as HTMLInputElement).value) }}
          />
        </div>

        ${sourceUnavailable ? html`
          <div class="wk-goal-create-sec">
            <p class="wk-goal-create-err" role="alert" data-testid="goal-create-source-unavailable">
              ${goalStoreUnavailableSummary(sourceUnavailable)}
            </p>
          </div>
        ` : null}

        ${source?.kind === 'unconfirmed' ? html`
          <div class="wk-goal-create-sec">
            <p role="status" data-testid="goal-create-source-unconfirmed">
              현재 Goal 저장소 상태를 확인하지 못했습니다. 생성 요청의 결과를 확인해 주세요.
            </p>
          </div>
        ` : null}

        ${visibleError?.kind === 'submit' || visibleError?.kind === 'uncertain' ? html`
          <div class="wk-goal-create-sec">
            <p class="wk-goal-create-err" role="alert" data-testid="goal-create-error">
              ${goalCreateErrorMessage(visibleError)}
            </p>
          </div>
        ` : null}

        ${visibleOutcomes.map(outcome => html`
          <div key=${outcome.ticket} class="wk-goal-create-sec" role="status" data-testid="goal-create-outcome">
            <p>${outcome.state === 'pending' ? '목표 생성 요청을 처리 중입니다.'
              : outcome.state === 'created' ? '서버가 목표 생성 요청에 응답했습니다.'
                : '생성 결과가 불확실합니다. 다시 요청하기 전에 원래 작업 공간을 확인해 주세요.'}</p>
            ${currentWorkspace && isWorkspaceCurrent?.()
              && currentWorkspace.basePath === outcome.workspace.basePath && currentWorkspace.mascRoot === outcome.workspace.mascRoot
              ? html`<p>요청한 Goal ID: ${outcome.goalId}</p>`
              : html`<p>원래 작업 공간을 확인하면 요청한 Goal ID를 볼 수 있습니다.</p>`}
            ${outcome.state === 'pending' ? null : html`
              <${ActionButton} variant="ghost" size="sm" onClick=${() => dismissGoalCreateOutcome(outcome.ticket)}>
                안내 닫기
              <//>`}
          </div>
        `)}

        <div class="wk-goal-create-actions">
          <${ActionButton}
            variant="primary"
            size="md"
            testId="goal-create-submit"
            disabled=${isSubmitDisabled}
            ariaBusy=${goalCreating.value}
            onClick=${handleSubmit}
          >
            ${goalCreating.value ? '생성 중...' : '＋ 목표 생성'}
          <//>
          <${ActionButton}
            variant="ghost"
            size="md"
            testId="goal-create-cancel"
            onClick=${handleClose}
          >취소<//>
        </div>
      </div>
    </aside>
  `
}
