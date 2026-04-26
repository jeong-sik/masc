import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { Card } from './common/card'
import { LoadingState } from './common/feedback-state'
import { fetchExcusePatterns, updateExcusePatterns } from '../api/dashboard'
import type { ExcusePattern } from '../api/dashboard'
import { createAsyncResource } from '../lib/async-state'

const patternsResource = createAsyncResource<ExcusePattern[]>()
const saving = signal(false)
const saveMessage = signal('')

function refreshExcusePatterns(): Promise<void> {
  patternsResource.reset()
  return patternsResource.load(fetchExcusePatterns)
}

function handleSave(event: Event) {
  event.preventDefault()
  const formData = new FormData(event.target as HTMLFormElement)
  const jsonStr = formData.get('patterns') as string
  try {
    const parsed = JSON.parse(jsonStr) as ExcusePattern[]
    if (!Array.isArray(parsed)) throw new Error('Root must be an array')
    for (const item of parsed) {
      if (!Array.isArray(item) || item.length !== 2 || typeof item[0] !== 'string' || typeof item[1] !== 'string') {
        throw new Error('Items must be an array of exactly two strings: [pattern, reason]')
      }
    }
    saving.value = true
    saveMessage.value = ''
    updateExcusePatterns(parsed).then(() => {
      saveMessage.value = 'Saved successfully.'
      refreshExcusePatterns()
    }).catch(err => {
      saveMessage.value = `Failed to save: ${err.message}`
    }).finally(() => {
      saving.value = false
    })
  } catch (err: any) {
    saveMessage.value = `Invalid format: ${err.message}`
  }
}

export function ExcusePatterns() {
  const s = patternsResource.state.value

  if (s.status === 'idle') {
    void refreshExcusePatterns()
  }

  if (s.status === 'loading') {
    return html`
      <${Card} title="반합리화 패턴">
        <${LoadingState}>핑계 패턴 불러오는 중...<//>
      </Card>
    `
  }

  if (s.status === 'error') {
    return html`
      <${Card} title="반합리화 패턴">
        <div class="p-4 text-[var(--bad-light)]" role="alert">패턴 로드 실패: ${s.message}</div>
      </Card>
    `
  }

  const data = s.status === 'loaded' ? s.data : undefined
  const jsonStr = data ? JSON.stringify(data, null, 2) : '[]'

  return html`
    <${Card} title="반합리화 패턴">
      <div class="p-4">
        <p class="text-sm text-[var(--text-muted)] mb-4">
          에이전트 완료 노트와 매칭되는 패턴입니다. 매칭 시 태스크가 거부됩니다.
          변경 사항은 <code>config/excuse_patterns.json</code>에 저장되며, 재시작 없이 즉시 적용됩니다.
          형식은 문자열 두 개를 포함하는 배열의 배열이어야 합니다: <code>["패턴", "사유"]</code>.
        </p>

        <form aria-label="핑계 패턴 편집" onSubmit=${handleSave}>
          <textarea autoComplete="off"
            name="patterns"
            class="w-full h-96 p-3 bg-[var(--bg-card)] border border-[var(--border-subtle)] rounded font-mono text-sm mb-4 text-[var(--text-primary)]"
            spellcheck="false"
            aria-label="핑계 패턴 JSON"
          >${jsonStr}</textarea>
          
          <div class="flex items-center gap-3">
            <button type="submit"
              class="px-4 py-2 bg-[var(--accent-primary)] text-white rounded hover:opacity-90 disabled:opacity-50 text-sm font-medium"
              disabled=${saving.value}
            >
              ${saving.value ? 'Saving...' : 'Save Patterns'}
            </button>
            ${saveMessage.value ? html`
              <span class="text-sm ${saveMessage.value.startsWith('Failed') || saveMessage.value.startsWith('Invalid') ? 'text-[var(--bad-light)]' : 'text-[var(--ok)]'}" role="status">
                ${saveMessage.value}
              </span>
            ` : null}
          </div>
        </form>
      </div>
    </Card>
  `
}
