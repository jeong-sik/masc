import { isDismissEscape } from '../../lib/keyboard'
// Goal creation form — right-hand side panel in the Work surface.
// A new Goal declares its measure (a count, a quantity against a limit, or a
// condition) and how it is read, alongside its title.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import type { RenderableProps } from 'preact'
import { useEffect, useRef } from 'preact/hooks'
import { TextArea, TextInput } from '../common/input'
import { Select } from '../common/select'
import type { GoalMeasureDirection } from '../../api/goal-measure'
import { ActionButton } from '../common/button'
import { goalStoreUnavailable } from '../../goal-tree-state'
import { goalStoreUnavailableSummary } from '../../lib/goal-store-unavailable-labels'
import type { ArtifactWorkspace } from '../../api/published-artifacts'
import { storedTokenRevision } from '../../api/token-revision'
import { dashboardActorRevision, managedDashboardActorRevision, managedDashboardAuthRevision,
  managedDashboardRefusal, managedDashboardUnverified } from '../../lib/dashboard-session-actor'
import { getStoredToken, getStoredTokenMeta } from '../../api/core'
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
  parseGoalMeasureDraft,
  malformedMeasureNumber,
  type GoalMeasureDraft,
  GOAL_PRIORITY_MIN,
  GOAL_PRIORITY_MAX,
  GOAL_PRIORITY_DEFAULT,
} from './goal-create-state'

// ── Local form state signals ─────────────────────────────────────────────────

type MeasureKind = GoalMeasureDraft['kind']

const MEASURE_KIND_OPTIONS: Array<{ value: MeasureKind; label: string }> = [
  { value: 'count', label: '개수 — 전체 중 몇 개를 끝냈나' },
  { value: 'quantity', label: '수치 — 목표 수치 이상·이하' },
  { value: 'done_when', label: '조건 — 참이 되면 끝' },
]
const DIRECTION_OPTIONS: Array<{ value: GoalMeasureDirection; label: string }> = [
  { value: 'at_most', label: '이하 (≤)' },
  { value: 'at_least', label: '이상 (≥)' },
]

function measureKindOf(value: string): MeasureKind | null {
  return MEASURE_KIND_OPTIONS.find(option => option.value === value)?.value ?? null
}
function directionOf(value: string): GoalMeasureDirection | null {
  return DIRECTION_OPTIONS.find(option => option.value === value)?.value ?? null
}

const titleSignal = signal('')
const kindSignal = signal<MeasureKind>('count')
const nounSignal = signal('')
const totalSignal = signal('')
const directionSignal = signal<GoalMeasureDirection>('at_most')
const targetSignal = signal('')
const unitSignal = signal('')
const conditionSignal = signal('')
const procedureSignal = signal('')
const prioritySignal = signal(GOAL_PRIORITY_DEFAULT)

export function resetGoalCreateFormLocal(): void {
  titleSignal.value = ''
  kindSignal.value = 'count'
  nounSignal.value = ''
  totalSignal.value = ''
  directionSignal.value = 'at_most'
  targetSignal.value = ''
  unitSignal.value = ''
  conditionSignal.value = ''
  procedureSignal.value = ''
  prioritySignal.value = GOAL_PRIORITY_DEFAULT
  resetGoalCreateForm()
}

function measureDraft(): GoalMeasureDraft {
  switch (kindSignal.value) {
    case 'count': return { kind: 'count', noun: nounSignal.value, total: totalSignal.value }
    case 'quantity': return { kind: 'quantity', unit: unitSignal.value, direction: directionSignal.value, target: targetSignal.value }
    case 'done_when': return { kind: 'done_when', condition: conditionSignal.value }
  }
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
      measure: measureDraft(),
      procedure: procedureSignal.value,
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
  const draft = measureDraft()
  const parsedMeasure = parseGoalMeasureDraft(draft)
  const isProcedureEmpty = !procedureSignal.value.trim()
  const submitted = goalCreateError.value
  // A number that does not read says why, since the disabled button alone
  // would not; a blank field says nothing.
  const measureError = malformedMeasureNumber(draft)
    ?? (submitted?.kind === 'measure_label' || submitted?.kind === 'measure_total' || submitted?.kind === 'measure_target'
      ? submitted : null)
  const measureMessage = goalCreateErrorMessage(measureError)
  // Every Goal write is refused while the store cannot be read,
  // so the form does not offer a submit that the server would reject.
  // Only the standalone form falls back to the shared observation. A Work
  // source explicitly says whether its own bound observation is unavailable.
  const sourceUnavailable = source === undefined ? goalStoreUnavailable.value
    : source.kind === 'unavailable' ? source.unavailable : null
  // The actor revision triggers a render even when no other signal changes.
  void dashboardActorRevision.value
  void managedDashboardActorRevision.value
  void managedDashboardAuthRevision.value
  void executionWorkspaceAuthority.value
  void storedTokenRevision.value
  const outcomes = goalCreateOutcomes.value
  const visibleOutcomes = outcomes.filter(goalCreateOutcomeIsCurrent)
  const earlierDraftOutcomes = outcomes.filter(outcome => outcome.draft === currentGoalCreateDraft()
    && !goalCreateOutcomeIsCurrent(outcome))
  const managedRefused = getStoredToken() !== null && getStoredTokenMeta()?.source === 'dev'
    && (managedDashboardRefusal.value === storedTokenRevision.value || managedDashboardUnverified.value === storedTokenRevision.value)
  const isSubmitDisabled = goalCreating.value || isTitleEmpty || !parsedMeasure.ok || isProcedureEmpty
    || sourceUnavailable !== null || goalCreateDraftHasOutcome(outcomes) || managedRefused
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
          <label for="goal-create-measure-kind" class="wk-goal-create-label">
            성공 조건<span class="wk-goal-create-req">*</span>
          </label>
          <${Select}
            id="goal-create-measure-kind"
            testId="goal-create-measure-kind"
            value=${kindSignal.value}
            options=${MEASURE_KIND_OPTIONS}
            disabled=${goalCreating.value}
            onInput=${(value: string) => { const kind = measureKindOf(value); if (kind) kindSignal.value = kind }}
          />
        </div>

        ${kindSignal.value === 'count' ? html`
          <div class="wk-goal-create-sec">
            <label for="goal-create-total" class="wk-goal-create-label">
              개수<span class="wk-goal-create-req">*</span>
            </label>
            <${TextInput}
              id="goal-create-total"
              testId="goal-create-total"
              required=${true}
              disabled=${goalCreating.value}
              value=${totalSignal.value}
              placeholder="예) 14"
              onInput=${(e: Event) => { totalSignal.value = (e.target as HTMLInputElement).value }}
            />
            <label for="goal-create-noun" class="wk-goal-create-label">
              세는 대상<span class="wk-goal-create-req">*</span>
            </label>
            <${TextInput}
              id="goal-create-noun"
              testId="goal-create-noun"
              required=${true}
              disabled=${goalCreating.value}
              value=${nounSignal.value}
              placeholder="예) 병합된 PR"
              onInput=${(e: Event) => { nounSignal.value = (e.target as HTMLInputElement).value }}
            />
          </div>
        ` : null}

        ${kindSignal.value === 'quantity' ? html`
          <div class="wk-goal-create-sec">
            <label for="goal-create-direction" class="wk-goal-create-label">방향</label>
            <${Select}
              id="goal-create-direction"
              testId="goal-create-direction"
              value=${directionSignal.value}
              options=${DIRECTION_OPTIONS}
              disabled=${goalCreating.value}
              onInput=${(value: string) => { const direction = directionOf(value); if (direction) directionSignal.value = direction }}
            />
            <label for="goal-create-target" class="wk-goal-create-label">
              목표 수치<span class="wk-goal-create-req">*</span>
            </label>
            <${TextInput}
              id="goal-create-target"
              testId="goal-create-target"
              required=${true}
              disabled=${goalCreating.value}
              value=${targetSignal.value}
              placeholder="예) 400"
              onInput=${(e: Event) => { targetSignal.value = (e.target as HTMLInputElement).value }}
            />
            <label for="goal-create-unit" class="wk-goal-create-label">
              단위<span class="wk-goal-create-req">*</span>
            </label>
            <${TextInput}
              id="goal-create-unit"
              testId="goal-create-unit"
              required=${true}
              disabled=${goalCreating.value}
              value=${unitSignal.value}
              placeholder="예) ms"
              onInput=${(e: Event) => { unitSignal.value = (e.target as HTMLInputElement).value }}
            />
          </div>
        ` : null}

        ${kindSignal.value === 'done_when' ? html`
          <div class="wk-goal-create-sec">
            <label for="goal-create-condition" class="wk-goal-create-label">
              완료 조건<span class="wk-goal-create-req">*</span>
            </label>
            <${TextInput}
              id="goal-create-condition"
              testId="goal-create-condition"
              required=${true}
              disabled=${goalCreating.value}
              value=${conditionSignal.value}
              placeholder="예) TUI 가 첫 실행에서 키퍼 목록을 그린다"
              onInput=${(e: Event) => { conditionSignal.value = (e.target as HTMLInputElement).value }}
            />
          </div>
        ` : null}

        ${measureMessage ? html`
          <p class="wk-goal-create-err" role="alert" data-testid="goal-create-measure-error">${measureMessage}</p>
        ` : null}

        <div class="wk-goal-create-sec">
          <label for="goal-create-procedure" class="wk-goal-create-label">
            측정 방법<span class="wk-goal-create-req">*</span>
          </label>
          <${TextArea}
            id="goal-create-procedure"
            rows=${3}
            required=${true}
            disabled=${goalCreating.value}
            value=${procedureSignal.value}
            placeholder="예) 이슈 본문의 1단계 줄이 [x] 이고 줄마다 병합된 PR 이 있는지 센다"
            onInput=${(e: Event) => { procedureSignal.value = (e.target as HTMLTextAreaElement).value }}
          />
          ${goalCreateError.value?.kind === 'procedure_empty' ? html`
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

        ${managedRefused ? html`<p role="alert">인증이 거부되었습니다. 인증을 확인한 뒤 다시 시도해 주세요.</p>` : null}
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

        ${earlierDraftOutcomes.map(outcome => html`
          <div key=${outcome.ticket} class="wk-goal-create-sec" role="status" data-testid="goal-create-earlier-outcome">
            <p>${outcome.state === 'pending'
              ? '이 초안의 이전 생성 요청이 진행 중입니다. 결과를 기다려 주세요.'
              : '이 초안으로 보낸 이전 생성 요청이 있습니다. 다시 요청하기 전에 원래 작업 공간에서 결과를 확인해 주세요.'}</p>
            ${outcome.state === 'pending' ? null : html`
              <${ActionButton} variant="ghost" size="sm" onClick=${() => dismissGoalCreateOutcome(outcome.ticket)}>
                이전 요청 확인 후 안내 닫기
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
