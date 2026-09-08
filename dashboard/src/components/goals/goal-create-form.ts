// Goal creation form — right-hand side panel in the Work surface.
// Design reference: prototype NewGoalComposer (work.jsx ~line 437).
// A new Goal declares its measured quantity and target alongside its title.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { TextInput } from '../common/input'
import { ActionButton } from '../common/button'
import {
  showGoalCreate,
  goalCreating,
  goalCreateError,
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

export function GoalCreateForm() {
  // Escape key dismisses
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && showGoalCreate.value) {
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
    const owner = currentGoalCreateDraft()
    void createGoal({
      title: titleSignal.value,
      metric: metricSignal.value,
      targetValue: targetSignal.value,
      priority: prioritySignal.value,
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
  const isSubmitDisabled = goalCreating.value || isTitleEmpty || isMetricEmpty || isTargetEmpty

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

        ${goalCreateError.value?.kind === 'submit' ? html`
          <div class="wk-goal-create-sec">
            <p class="wk-goal-create-err" role="alert" data-testid="goal-create-error">
              ${goalCreateErrorMessage(goalCreateError.value)}
            </p>
          </div>
        ` : null}

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
