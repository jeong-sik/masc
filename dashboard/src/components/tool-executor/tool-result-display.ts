import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { CountBadge } from '../common/badge'
import { ActionButton } from '../common/button'

interface ToolResultProps {
  success: boolean
  text: string
  toolName: string
  timestamp: number
}

const expanded = signal(true)

function tryFormatJson(text: string): { isJson: boolean; formatted: string } {
  try { const parsed = JSON.parse(text); return { isJson: true, formatted: JSON.stringify(parsed, null, 2) } }
  catch { return { isJson: false, formatted: text } }
}

export function ToolResultDisplay({ success, text, toolName, timestamp }: ToolResultProps) {
  const { formatted } = tryFormatJson(text)
  const timeStr = new Date(timestamp).toLocaleTimeString('ko-KR')
  const lines = formatted.split('\n').length
  return html`
    <div class="flex flex-col gap-2 mt-3">
      <div class="flex items-center gap-2">
        <${CountBadge} tone=${success ? 'ok' : 'bad'}>${success ? 'OK' : 'ERR'}<//>
        <span class="text-[11px] text-[var(--text-muted)]">${toolName}</span>
        <span class="text-[10px] text-[var(--text-muted)] ml-auto">${timeStr}</span>
      </div>
      <div class="rounded-lg border border-[var(--card-border)] bg-[var(--bg-0)] overflow-hidden">
        <div class="flex items-center justify-between px-3 py-1.5 border-b border-[var(--card-border)]">
          <button type="button" class="text-[10px] text-[var(--text-muted)] cursor-pointer hover:text-[var(--text-body)]"
            onClick=${() => { expanded.value = !expanded.value }}>
            ${expanded.value ? '접기' : '펼치기'} (${lines}줄)
          </button>
          <${ActionButton} variant="subtle" size="sm" onClick=${() => void navigator.clipboard.writeText(text)}>복사<//>
        </div>
        ${expanded.value ? html`
          <pre class="px-3 py-2 text-[12px] font-mono overflow-x-auto max-h-[400px] overflow-y-auto
            ${success ? 'text-[var(--text-body)]' : 'text-[#fda4af]'}">${formatted}</pre>
        ` : null}
      </div>
    </div>
  `
}
