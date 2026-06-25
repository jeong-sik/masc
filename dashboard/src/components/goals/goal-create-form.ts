// Goal creation form — modal overlay pattern.
// Design reference: prototype NewGoalComposer (work.jsx ~line 437).
// RFC-0294: no horizon; no lead keeper (live Goal type has no owner field).
// Fields: title (required), priority (1-5), require_completion_approval (checkbox).

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { TextInput } from '../common/input'
import { Select } from '../common/select'
import { ActionButton } from '../common/button'
import {
  showGoalCreate,
  goalCreating,
  goalCreateError,
  createGoal,
  resetGoalCreateForm,
  GOAL_PRIORITY_MIN,
  GOAL_PRIORITY_MAX,
  GOAL_PRIORITY_DEFAULT,
} from './goal-create-state'

// ── Local form state signals ─────────────────────────────────────────────────

const titleSignal = signal('')
const prioritySignal = signal(GOAL_PRIORITY_DEFAULT)
const approvalSignal = signal(false)

export function resetGoalCreateFormLocal(): void {
  titleSignal.value = ''
  prioritySignal.value = GOAL_PRIORITY_DEFAULT
  approvalSignal.value = false
  resetGoalCreateForm()
}

function resetLocalForm(): void {
  resetGoalCreateFormLocal()
}

// ── Priority options ─────────────────────────────────────────────────────────

const PRIORITY_OPTIONS = Array.from(
  { length: GOAL_PRIORITY_MAX - GOAL_PRIORITY_MIN + 1 },
  (_, i) => {
    const v = GOAL_PRIORITY_MIN + i
    const label = v === 1 ? `P${v} · 최고` : v === GOAL_PRIORITY_MAX ? `P${v} · 낮음` : `P${v}`
    return { value: String(v), label }
  },
)

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
      require_completion_approval: approvalSignal.value,
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
    <div
      class="turn-overlay"
      role="dialog"
      aria-modal="true"
      aria-labelledby="goal-create-title"
      data-testid="goal-create-overlay"
      onClick=${handleClose}
    >
      <div
        class="turn-drawer ngc-drawer"
        data-testid="goal-create-form"
        onClick=${(e: MouseEvent) => { e.stopPropagation() }}
      >
        <div class="turn-hd">
          <h3 id="goal-create-title">새 목표</h3>
          <span class="tid mono">masc_goal_upsert</span>
          <span style=${{ marginLeft: 'auto' }}></span>
          <button
            type="button"
            class="turn-close"
            data-testid="goal-create-close"
            onClick=${handleClose}
            aria-label="닫기 (Esc)"
          >✕</button>
        </div>

        <div class="turn-body">
          <div class="turn-sec">
            <label
              for="goal-create-title-input"
              class="text-2xs font-medium text-text-muted"
            >
              제목<span class="ml-0.5 text-[var(--color-status-err)]">*</span>
            </label>
            <${TextInput}
              id="goal-create-title-input"
              testId="goal-create-title-input"
              value=${titleSignal.value}
              placeholder="예) scheduler p99 SLO 400ms 회복"
              autoFocus=${true}
              onInput=${(e: Event) => { titleSignal.value = (e.target as HTMLInputElement).value }}
            />
            ${isTitleEmpty && goalCreateError.value === '제목을 입력하세요' ? html`
              <p class="mt-1 text-2xs text-[var(--color-status-err)]" role="alert" data-testid="goal-create-title-error">
                ${goalCreateError.value}
              </p>
            ` : null}
          </div>

          <div class="turn-sec">
            <label
              for="goal-create-priority"
              class="text-2xs font-medium text-text-muted"
            >
              우선순위 · <span class="mono">P${prioritySignal.value}</span>
            </label>
            <${Select}
              id="goal-create-priority"
              testId="goal-create-priority"
              value=${String(prioritySignal.value)}
              options=${PRIORITY_OPTIONS}
              ariaLabel="우선순위"
              onInput=${(v: string) => { prioritySignal.value = Number(v) }}
            />
            <p class="mt-1 text-2xs text-text-muted">P1이 가장 높습니다.</p>
          </div>

          <div class="turn-sec">
            <label class="ngc-check flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                data-testid="goal-create-approval-checkbox"
                checked=${approvalSignal.value}
                onChange=${(e: Event) => { approvalSignal.value = (e.target as HTMLInputElement).checked }}
              />
              <span>완료 승인 필요 <b>operator 검증 게이트</b></span>
            </label>
          </div>

          ${goalCreateError.value && goalCreateError.value !== '제목을 입력하세요' ? html`
            <div class="turn-sec">
              <p class="text-2xs text-[var(--color-status-err)]" role="alert" data-testid="goal-create-error">
                ${goalCreateError.value}
              </p>
            </div>
          ` : null}

          <div class="turn-sec bcc-actions flex flex-wrap gap-2">
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
      </div>
    </div>
  `
}
