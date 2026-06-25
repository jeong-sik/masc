// Goal creation form — right-hand side panel in the Work surface.
// Design reference: prototype NewGoalComposer (work.jsx ~line 437).
// RFC-0294: no horizon; no lead keeper (live Goal type has no owner field).
// Fields: title (required), priority (1-5), require_completion_approval (checkbox).

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { TextInput } from '../common/input'
import { ActionButton } from '../common/button'
import { KeeperBadge } from '../keeper-badge'
import { keepers } from '../../store'
import {
  showGoalCreate,
  goalCreating,
  goalCreateError,
  createGoal,
  resetGoalCreateForm,
  GOAL_PRIORITY_MIN,
  GOAL_PRIORITY_MAX,
  GOAL_PRIORITY_DEFAULT,
  GOAL_HORIZONS,
  GOAL_HORIZON_LABELS,
} from './goal-create-state'
import type { GoalHorizon } from './goal-create-state'

// ── Local form state signals ─────────────────────────────────────────────────

const titleSignal = signal('')
const prioritySignal = signal(GOAL_PRIORITY_DEFAULT)
const approvalSignal = signal(false)
const horizonSignal = signal<GoalHorizon>('long')
const leadKeeperSignal = signal<string | null>(null)

export function resetGoalCreateFormLocal(): void {
  titleSignal.value = ''
  prioritySignal.value = GOAL_PRIORITY_DEFAULT
  approvalSignal.value = false
  horizonSignal.value = 'long'
  leadKeeperSignal.value = null
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
      require_completion_approval: approvalSignal.value,
      horizon: horizonSignal.value,
      lead_keeper: leadKeeperSignal.value,
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
          ${isTitleEmpty && goalCreateError.value === '제목을 입력하세요' ? html`
            <p class="wk-goal-create-err" role="alert" data-testid="goal-create-title-error">
              ${goalCreateError.value}
            </p>
          ` : null}
        </div>

        <div class="wk-goal-create-sec">
          <label class="wk-goal-create-label">호라이즌 · 계획 주기</label>
          <div class="wk-goal-create-chips" role="radiogroup" aria-label="호라이즌">
            ${GOAL_HORIZONS.map(h => html`
              <button
                type="button"
                key=${h}
                class=${`wk-chip ${horizonSignal.value === h ? 'on' : ''}`}
                role="radio"
                aria-checked=${horizonSignal.value === h}
                onClick=${() => { horizonSignal.value = h }}
              >${GOAL_HORIZON_LABELS[h]}</button>
            `)}
          </div>
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

        <div class="wk-goal-create-sec">
          <label class="wk-goal-create-label">예상 위험도 horizon + priority</label>
          <div class="wk-goal-create-risk">
            <span class="wk-goal-create-risk-level">Safe</span>
            <span class="wk-goal-create-risk-desc">가드 통과 · 자율 실행</span>
          </div>
        </div>

        <div class="wk-goal-create-sec">
          <label class="wk-goal-create-label">리드 KEEPER</label>
          <div class="wk-goal-create-keepers">
            <button
              type="button"
              class=${`wk-keeper-chip ${leadKeeperSignal.value === null ? 'on' : ''}`}
              onClick=${() => { leadKeeperSignal.value = null }}
              title="미지정"
              aria-label="미지정"
            >
              <span class="wk-keeper-avatar-none" aria-hidden="true">?</span>
              <span>미지정</span>
            </button>
            ${keepers.value.map(k => html`
              <button
                type="button"
                key=${k.name}
                class=${`wk-keeper-chip ${leadKeeperSignal.value === k.name ? 'on' : ''}`}
                onClick=${() => { leadKeeperSignal.value = k.name }}
                title=${k.name}
                aria-label=${k.name}
              >
                <${KeeperBadge} id=${k.name} size="sm" variant="sigil" />
                <span>${k.name}</span>
              </button>
            `)}
          </div>
        </div>

        <div class="wk-goal-create-sec">
          <label class="wk-goal-create-check">
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
          <div class="wk-goal-create-sec">
            <p class="wk-goal-create-err" role="alert" data-testid="goal-create-error">
              ${goalCreateError.value}
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
