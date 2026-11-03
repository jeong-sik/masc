import { html } from 'htm/preact'
import { batch, signal } from '@preact/signals'
import { useLayoutEffect, useRef } from 'preact/hooks'
import { TextInput } from '../common/input'
import { Select } from '../common/select'
import { ActionButton } from '../common/button'
import { RichComposer } from '../common/rich-composer'
import { beginSeparateTaskDraft, chooseTaskCreateMemoryOnly, retryTaskCreateStorage, showTaskCreate, taskCreating,
  taskCreateStorageNotice, taskCreateUsingMemoryOnly, taskDraftHasUnconfirmedRequest,
  createTask, type GoalTaskDispatch } from './task-manage-state'
import { isCanonicalGoalId } from '../../lib/goal-identity'
import { Tk } from '../tk'

export const title = signal('')
export const description = signal('')
export const priority = signal(3) // MASC priority: 1=P1 highest, 4=P4 lowest
let draftRevision = 0
const PRIORITY_OPTIONS = [
  { value: '1', label: 'P1 · 긴급' },
  { value: '2', label: 'P2 · 높음' },
  { value: '3', label: 'P3 · 보통' },
  { value: '4', label: 'P4 · 낮음' },
]

export function resetForm() { draftRevision++; title.value = ''; description.value = ''; priority.value = 3 }

export function TaskCreateForm(props: { goalId?: string | null; goalTitle?: string | null; goalDispatch?: GoalTaskDispatch } = {}) {
  const mounted = useRef(true)
  useLayoutEffect(() => {
    mounted.current = true
    return () => { mounted.current = false }
  }, [])
  const linkedGoalId = props.goalId ?? null
  const linkedGoalTitle = props.goalTitle?.trim() || null
  const goalUnavailable = linkedGoalId !== null
    && (!isCanonicalGoalId(linkedGoalId) || !props.goalDispatch || !props.goalDispatch.isCurrent())
  if (!showTaskCreate.value) {
    return html`
      <div class="v2-workspace-surface flex flex-col gap-3">
        <div class="text-xs leading-relaxed text-text-muted">
          ${linkedGoalId
            ? html`
              <span class="inline-flex items-center gap-1 rounded-[var(--r-1)] border border-[var(--accent-30)] bg-[var(--accent-10)] px-1.5 py-0.5 text-2xs text-accent-fg">
                goal ${linkedGoalTitle ?? linkedGoalId}
              </span>
              에 직접 연결된 backlog 태스크를 생성합니다.
            `
            : html`
              이 프로젝트의 백로그에 바로 추가됩니다. 우선순위는 <${Tk}>P1<//>이 가장 높습니다.
            `}
        </div>
        <${ActionButton}
          variant="primary"
          size="md"
          block=${true}
          onClick=${() => { beginSeparateTaskDraft(); draftRevision++; showTaskCreate.value = true }}
        >태스크 추가<//>
      </div>
    `
  }

  return html`
    <div class="v2-workspace-surface rounded-[var(--r-1)] border border-card-border/70 bg-[var(--color-bg-surface)] p-4">
      <div class="mb-3 flex items-start justify-between gap-3">
        <div>
          <h3 class="text-base font-semibold text-text-strong">새 태스크</h3>
          <p class="mt-1 text-xs leading-relaxed text-text-muted">
            ${linkedGoalId
              ? 'goal_id 자동 연결'
              : '제목만으로 등록 가능'}
          </p>
        </div>
      </div>

      <div class="flex flex-col gap-3">
        ${linkedGoalId ? html`
          <div class="rounded-[var(--r-1)] border border-[var(--accent-25)] bg-[var(--accent-10)] px-3 py-2 text-2xs leading-relaxed text-accent-fg">
            연결 목표:
            <strong class="ml-1 text-text-strong">${linkedGoalTitle ?? linkedGoalId}</strong>
            <span class="ml-1 text-text-muted">(${linkedGoalId})</span>
          </div>
        ` : null}

        <div class="flex flex-col gap-1.5">
          <label class="text-2xs font-medium text-text-muted">
            제목<span class="ml-0.5 text-[var(--color-status-err)]">*</span>
          </label>
          <${TextInput}
            value=${title.value}
            placeholder="예: runtime config introspection 정리"
            onInput=${(e: Event) => { draftRevision++; title.value = (e.target as HTMLInputElement).value }}
          />
        </div>

        <div class="grid gap-3 md:grid-cols-[minmax(0,1fr)_180px]">
          <div class="flex flex-col gap-1.5">
            <label class="text-2xs font-medium text-text-muted">설명</label>
            <${RichComposer}
              value=${description.value}
              placeholder="배경, 재현 조건, 원하는 결과를 적으면 backlog 카드와 Task 상세에서 그대로 렌더링됩니다."
              rows=${4}
              onValueChange=${(next: string) => { draftRevision++; description.value = next }}
              helpText="Markdown, fenced code block, URL 링크 카드, 단독 이미지 URL을 지원합니다."
              previewLimit=${2}
            />
          </div>

          <div class="flex flex-col gap-1.5">
            <label class="text-2xs font-medium text-text-muted">우선순위</label>
            <${Select}
              value=${String(priority.value)}
              options=${PRIORITY_OPTIONS}
              onInput=${(v: string) => { draftRevision++; priority.value = Number(v) }}
            />
            <div class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-surface)] px-3 py-2 text-2xs leading-relaxed text-text-muted">
              backlog 카드와 동일하게 <strong class="text-text-strong">P1 → P4</strong> 순으로 표시됩니다.
            </div>
          </div>
        </div>

        <div class="mt-1 flex flex-wrap gap-2">
          ${taskDraftHasUnconfirmedRequest.value ? html`
            <div role="status" class="w-full text-xs text-text-muted">
              이 초안으로 이미 생성 요청을 보냈습니다. 이전 요청을 확인하거나 별도 새 태스크를 작성해 주세요.
              <${ActionButton} variant="ghost" size="sm" onClick=${() => { beginSeparateTaskDraft(); resetForm() }}>
                별도 새 태스크 작성
              <//>
            </div>` : null}
          ${taskCreateStorageNotice.value ? html`
            <div role="alert" class="w-full text-xs text-text-muted">
              요청 기록을 저장할 수 없습니다. 메모리에만 보관하면 새로고침 뒤 결과를 확인할 식별자가 사라집니다.
              <${ActionButton} variant="ghost" size="sm" onClick=${retryTaskCreateStorage}>저장 다시 확인<//>
              <${ActionButton} variant="ghost" size="sm" onClick=${chooseTaskCreateMemoryOnly}>이번 초안은 메모리에만 보관<//>
            </div>` : null}
          ${taskCreateUsingMemoryOnly.value ? html`<p role="status" class="w-full text-xs text-text-muted">
            이번 요청은 이 탭의 메모리에만 보관됩니다. 새로고침 전에 결과를 확인해 주세요.
          </p>` : null}
          <${ActionButton}
            variant="primary"
            size="md"
            disabled=${taskCreating.value || taskDraftHasUnconfirmedRequest.value || !title.value.trim() || goalUnavailable}
            onClick=${() => {
              if (linkedGoalId !== null && (!props.goalDispatch || !props.goalDispatch.isCurrent())) return
              const submittedDraft = draftRevision
              const isDraftCurrent = () => mounted.current && draftRevision === submittedDraft && showTaskCreate.peek()
              void createTask({
                title: title.value,
                description: description.value,
                priority: priority.value,
                goal_id: linkedGoalId,
              }, props.goalDispatch, {
                isCurrent: isDraftCurrent,
                finish: () => {
                  if (!isDraftCurrent()
                    || (linkedGoalId !== null && !props.goalDispatch?.isCurrent())) return false
                  batch(() => { showTaskCreate.value = false; resetForm() })
                  return true
                },
              })
            }}
          >
            ${taskCreating.value ? '추가 중...' : 'backlog에 추가'}
          <//>
          <${ActionButton}
            variant="ghost"
            size="md"
            onClick=${() => { showTaskCreate.value = false; resetForm() }}
          >취소<//>
        </div>
      </div>
    </div>`
  }
