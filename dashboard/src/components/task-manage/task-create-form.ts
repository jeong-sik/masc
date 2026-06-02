import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { TextInput } from '../common/input'
import { Select } from '../common/select'
import { ActionButton } from '../common/button'
import { RichComposer } from '../common/rich-composer'
import { showTaskCreate, taskCreating, createTask } from './task-manage-state'
import { Tk } from '../tk'

export const title = signal('')
export const description = signal('')
export const priority = signal(3) // MASC priority: 1=P1 highest, 4=P4 lowest
const PRIORITY_OPTIONS = [
  { value: '1', label: 'P1 · 긴급' },
  { value: '2', label: 'P2 · 높음' },
  { value: '3', label: 'P3 · 보통' },
  { value: '4', label: 'P4 · 낮음' },
]

export function resetForm() { title.value = ''; description.value = ''; priority.value = 3 }

export function TaskCreateForm(props: { goalId?: string | null; goalTitle?: string | null } = {}) {
  const linkedGoalId = props.goalId?.trim() || null
  const linkedGoalTitle = props.goalTitle?.trim() || null
  if (!showTaskCreate.value) {
    return html`
      <div class="flex flex-col gap-3">
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
          onClick=${() => { showTaskCreate.value = true }}
        >태스크 추가<//>
      </div>
    `
  }

  return html`
    <div class="rounded-[var(--r-1)] border border-card-border/70 bg-[var(--color-bg-surface)] p-4">
      <div class="mb-3 flex items-start justify-between gap-3">
        <div>
          <h3 class="text-base font-semibold text-text-strong">새 태스크</h3>
          <p class="mt-1 text-xs leading-relaxed text-text-muted">
            ${linkedGoalId
              ? 'goal_id가 함께 저장됩니다. 제목에 [goal:<id>] 태그를 붙이지 않아도 Goal Manager에 연결됩니다.'
              : '간단한 제목만 있어도 backlog에 등록됩니다. 설명은 나중에 보강해도 됩니다.'}
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
            onInput=${(e: Event) => { title.value = (e.target as HTMLInputElement).value }}
          />
        </div>

        <div class="grid gap-3 md:grid-cols-[minmax(0,1fr)_180px]">
          <div class="flex flex-col gap-1.5">
            <label class="text-2xs font-medium text-text-muted">설명</label>
            <${RichComposer}
              value=${description.value}
              placeholder="배경, 재현 조건, 원하는 결과를 적으면 backlog 카드와 Task 상세에서 그대로 렌더링됩니다."
              rows=${4}
              onValueChange=${(next: string) => { description.value = next }}
              helpText="Markdown, fenced code block, URL 링크 카드, 단독 이미지 URL을 지원합니다."
              previewLimit=${2}
            />
          </div>

          <div class="flex flex-col gap-1.5">
            <label class="text-2xs font-medium text-text-muted">우선순위</label>
            <${Select}
              value=${String(priority.value)}
              options=${PRIORITY_OPTIONS}
              onInput=${(v: string) => { priority.value = Number(v) }}
            />
            <div class="rounded-[var(--r-1)] border border-card-border/60 bg-[var(--color-bg-surface)] px-3 py-2 text-2xs leading-relaxed text-text-muted">
              backlog 카드와 동일하게 <strong class="text-text-strong">P1 → P4</strong> 순으로 표시됩니다.
            </div>
          </div>
        </div>

        <div class="mt-1 flex flex-wrap gap-2">
          <${ActionButton}
            variant="primary"
            size="md"
            disabled=${taskCreating.value || !title.value.trim()}
            onClick=${() => {
              void createTask({
                title: title.value,
                description: description.value,
                priority: priority.value,
                goal_id: linkedGoalId,
              })
                .then(ok => { if (ok) resetForm() })
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
