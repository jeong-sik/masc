import { html } from 'htm/preact'
import { Markdown } from "../common/markdown"
import { useSignal } from '@preact/signals'
import { CountBadge } from '../common/badge'
import { ActionButton } from '../common/button'

interface ToolResultProps {
  success: boolean
  text: string
  toolName: string
  timestamp: number
}

function tryFormatJson(text: string): { isJson: boolean; formatted: string } {
  try { const parsed = JSON.parse(text); return { isJson: true, formatted: JSON.stringify(parsed, null, 2) } }
  catch { return { isJson: false, formatted: text } }
}

export function ToolResultDisplay({ success, text, toolName, timestamp }: ToolResultProps) {
  const expanded = useSignal(true)
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
          <div class="max-h-[400px] overflow-auto bg-[var(--bg-0)]">
            <${Markdown} text=${'```json\n' + formatted + '\n```'} />
          </div>
        ` : null}
      </div>
    </div>
  `
}
