import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { formatTimeAgo } from '../../lib/format-time'
import { CountBadge } from '../common/badge'
import { ActionButton } from '../common/button'
import { JsonViewer } from '../common/json-viewer'

interface ToolResultProps {
  success: boolean
  text: string
  toolName: string
  timestamp: number
}

function tryParseJson(text: string): { isJson: boolean; parsed: unknown } {
  try {
    return { isJson: true, parsed: JSON.parse(text) }
  } catch {
    return { isJson: false, parsed: null }
  }
}

export function ToolResultDisplay({ success, text, toolName, timestamp }: ToolResultProps) {
  const expanded = useSignal(true)
  const { isJson, parsed } = tryParseJson(text)
  const timeStr = formatTimeAgo(timestamp)
  const lines = text.split('\n').length
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
          <div class="px-3 py-2 overflow-x-auto max-h-[400px] overflow-y-auto">
            ${isJson
              ? html`<${JsonViewer} data=${parsed} />`
              : html`<pre class="text-[12px] font-mono ${success ? 'text-[var(--text-body)]' : 'text-[var(--bad-light)]'}">${text}</pre>`
            }
          </div>
        ` : null}
      </div>
    </div>
  `
}
