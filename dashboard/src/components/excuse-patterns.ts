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
    if (!Array.isArray(parsed)) throw new Error('루트는 배열이어야 합니다')
    for (const item of parsed) {
      if (!Array.isArray(item) || item.length !== 2 || typeof item[0] !== 'string' || typeof item[1] !== 'string') {
        throw new Error('각 항목은 정확히 두 문자열의 배열이어야 합니다: [pattern, reason]')
      }
    }
    saving.value = true
    saveMessage.value = ''
    updateExcusePatterns(parsed).then(() => {
      saveMessage.value = '저장 완료.'
      refreshExcusePatterns()
    }).catch(err => {
      saveMessage.value = `저장 실패: ${err.message}`
    }).finally(() => {
      saving.value = false
    })
  } catch (err: any) {
    saveMessage.value = `잘못된 형식: ${err.message}`
  }
}

export function ExcusePatterns() {
  const s = patternsResource.state.value

  if (s.status === 'idle') {
    void refreshExcusePatterns()
  }

  if (s.status === 'loading') {
    return html`
      <${Card} title="Anti-Rationalization 핑계 패턴">
        <${LoadingState}>핑계 패턴 불러오는 중...<//>
      </Card>
    `
  }

  if (s.status === 'error') {
    return html`
      <${Card} title="Anti-Rationalization 핑계 패턴">
        <div class="p-4 text-[var(--color-status-err)]" role="alert">패턴 로드 실패: ${s.message}</div>
      </Card>
    `
  }

  const data = s.status === 'loaded' ? s.data : undefined
  const jsonStr = data ? JSON.stringify(data, null, 2) : '[]'

  return html`
    <${Card} title="Anti-Rationalization 핑계 패턴">
      <div class="p-4">
        <p class="text-sm text-[var(--color-fg-muted)] mb-4">
          이 패턴들은 에이전트 completion note 와 매칭됩니다. 매칭되면 해당 task 는 거부됩니다.
          변경 사항은 <code>config/excuse_patterns.json</code> 에 저장되며 재시작 없이 즉시 적용됩니다.
          형식은 두 개의 문자열을 담은 배열들의 JSON 배열이어야 합니다: <code>["pattern", "reason"]</code>.
        </p>

        <form onSubmit=${handleSave}>
          <textarea
            name="patterns"
            class="w-full h-96 p-3 bg-[var(--color-bg-elevated)] border border-[var(--color-border-divider)] rounded-[var(--r-1)] font-mono text-sm mb-4 text-[var(--color-fg-primary)]"
            spellcheck="false"
          >${jsonStr}</textarea>
          
          <div class="flex items-center gap-3">
            <button
              type="submit"
              class="px-4 py-2 bg-[var(--color-accent-fg)] text-white rounded-[var(--r-1)] hover:opacity-90 disabled:opacity-50 text-sm font-medium"
              disabled=${saving.value}
            >
              ${saving.value ? '저장 중...' : '패턴 저장'}
            </button>
            ${saveMessage.value ? html`
              <span class="text-sm ${saveMessage.value.startsWith('Failed') || saveMessage.value.startsWith('Invalid') ? 'text-[var(--color-status-err)]' : 'text-[var(--color-status-ok)]'}">
                ${saveMessage.value}
              </span>
            ` : null}
          </div>
        </form>
      </div>
    </Card>
  `
}
