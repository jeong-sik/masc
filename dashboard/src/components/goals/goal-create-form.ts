// Goal creation form — right-hand side panel in the Work surface.
// Design reference: prototype NewGoalComposer (work.jsx ~line 437).
// RFC-0294: no horizon; no lead keeper (live Goal type has no owner field).
// Fields: title (required), priority (1-5).

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
  resetGoalCreateForm,
  goalCreateErrorMessage,
  GOAL_PRIORITY_MIN,
  GOAL_PRIORITY_MAX,
  GOAL_PRIORITY_DEFAULT,
} from './goal-create-state'

// ── Local form state signals ─────────────────────────────────────────────────

const titleSignal = signal('')
const prioritySignal = signal(GOAL_PRIORITY_DEFAULT)

export function resetGoalCreateFormLocal(): void {
  titleSignal.value = ''
  prioritySignal.value = GOAL_PRIORITY_DEFAULT
  resetGoalCreateForm()
}

function resetLocalForm(): void {
  resetGoalCreateFormLocal()
}

// ── Component ────────────────────────────────────────────────────────────────

export function GoalCreateForm() {
  if (!showGoalCreate.value) return null

  // Escape key dismisses
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation()
        showGoalCreate.value = false
        resetLocalForm()
      }
    }
    window.addEventListener('keydown', onKey)
    return () => { window.removeEventListener('keydown', onKey) }
  }, [])

  const handleSubmit = () => {
    void createGoal({
      title: titleSignal.value,
      priority: prioritySignal.value,
    }).then(ok => {
      if (ok) resetLocalForm()
    })
  }

  const handleClose = () => {
    showGoalCreate.value = false
    resetLocalForm()
  }

  const isTitleEmpty = !titleSignal.value.trim()
  const isSubmitDisabled = goalCreating.value || isTitleEmpty

  return html`
    <aside
      class="wk-goal-create-panel"
      role="form"
      aria-labelledby="goal-create-title"
      data-testid="goal-create-panel"
    >
      <div class="wk-goal-create-hd">
        <div>
          <div class="wk-goal-create-eyebrow">goal store · create</div>
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
            onInput=${(e: Event) => { titleSignal.value = (e.target as HTMLInputElement).value }}
          />
          ${isTitleEmpty && goalCreateError.value?.kind === 'title_empty' ? html`
            <p class="wk-goal-create-err" role="alert" data-testid="goal-create-title-error">
              ${goalCreateErrorMessage(goalCreateError.value)}
            </p>
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
