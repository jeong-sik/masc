import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { TextInput, TextArea } from '../common/input'
import { Select } from '../common/select'
import { ActionButton } from '../common/button'
import { showTaskCreate, taskCreating, createTask } from './task-manage-state'

const title = signal('')
const description = signal('')
const priority = signal(2) // numeric priority: 1=low, 2=normal, 3=high, 4=critical
const PRIORITY_OPTIONS = [
  { value: '1', label: '낮음' },
  { value: '2', label: '보통' },
  { value: '3', label: '높음' },
  { value: '4', label: '긴급' }
]

function resetForm() { title.value = ''; description.value = ''; priority.value = 2 }

export function TaskCreateForm() {
  if (!showTaskCreate.value) {
    return html`<div class="mb-3">
      <${ActionButton} variant="primary" size="md" onClick=${() => { showTaskCreate.value = true }}>+ 태스크 추가<//>
    </div>`
  }
  return html`
    <div class="mb-4 rounded-xl border border-[var(--card-border)] bg-[var(--bg-1)] p-4">
      <h3 class="text-[13px] text-[var(--text-strong)] font-medium mb-3">새 태스크</h3>
      <div class="flex flex-col gap-3">
        <div class="flex flex-col gap-1">
          <label class="text-[11px] text-[var(--text-muted)] font-medium">제목<span class="text-[var(--bad)] ml-0.5">*</span></label>
          <${TextInput} value=${title.value} placeholder="태스크 제목"
            onInput=${(e: Event) => { title.value = (e.target as HTMLInputElement).value }} />
        </div>
        <div class="flex flex-col gap-1">
          <label class="text-[11px] text-[var(--text-muted)] font-medium">설명</label>
          <${TextArea} value=${description.value} placeholder="태스크 설명 (선택)" rows=${3}
            onInput=${(e: Event) => { description.value = (e.target as HTMLTextAreaElement).value }} />
        </div>
        <div class="flex flex-col gap-1 max-w-[200px]">
          <label class="text-[11px] text-[var(--text-muted)] font-medium">우선순위</label>
          <${Select} value=${String(priority.value)} options=${PRIORITY_OPTIONS} onInput=${(v: string) => { priority.value = Number(v) }} />
        </div>
        <div class="flex gap-2 mt-1">
          <${ActionButton} variant="primary" size="md" disabled=${taskCreating.value || !title.value.trim()}
            onClick=${() => { void createTask({ title: title.value, description: description.value, priority: priority.value }).then(ok => { if (ok) resetForm() }) }}>
            ${taskCreating.value ? '생성 중...' : '생성'}<//>
          <${ActionButton} variant="ghost" size="md" onClick=${() => { showTaskCreate.value = false; resetForm() }}>취소<//>
        </div>
      </div>
    </div>
  `
}
