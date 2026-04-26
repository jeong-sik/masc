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
      <${Card} title="Anti-Rationalization Excuse Patterns">
        <${LoadingState}>핑계 패턴 불러오는 중...<//>
      </Card>
    `
  }

  if (s.status === 'error') {
    return html`
      <${Card} title="Anti-Rationalization Excuse Patterns">
        <div class="p-4 text-[var(--bad-light)]">Failed to load patterns: ${s.message}</div>
      </Card>
    `
  }

  const data = s.status === 'loaded' ? s.data : undefined
  const jsonStr = data ? JSON.stringify(data, null, 2) : '[]'

  return html`
    <${Card} title="Anti-Rationalization Excuse Patterns">
      <div class="p-4">
        <p class="text-sm text-[var(--color-fg-muted)] mb-4">
          These patterns are matched against agent completion notes. If matched, the task is rejected.
          Changes here are saved to <code>config/excuse_patterns.json</code> and applied immediately without restarting.
          The format must be a JSON array of arrays, each containing two strings: <code>["pattern", "reason"]</code>.
        </p>

        <form onSubmit=${handleSave}>
          <textarea
            name="patterns"
            class="w-full h-96 p-3 bg-[var(--bg-card)] border border-[var(--color-border-divider)] rounded font-mono text-sm mb-4 text-[var(--text-primary)]"
            spellcheck="false"
          >${jsonStr}</textarea>
          
          <div class="flex items-center gap-3">
            <button
              type="submit"
              class="px-4 py-2 bg-[var(--accent-primary)] text-white rounded hover:opacity-90 disabled:opacity-50 text-sm font-medium"
              disabled=${saving.value}
            >
              ${saving.value ? 'Saving...' : 'Save Patterns'}
            </button>
            ${saveMessage.value ? html`
              <span class="text-sm ${saveMessage.value.startsWith('Failed') || saveMessage.value.startsWith('Invalid') ? 'text-[var(--bad-light)]' : 'text-[var(--color-status-ok)]'}">
                ${saveMessage.value}
              </span>
            ` : null}
          </div>
        </form>
      </div>
    </Card>
  `
}
