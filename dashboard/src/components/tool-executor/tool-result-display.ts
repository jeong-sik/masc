import { html } from 'htm/preact'
import { useSignal } from '@preact/signals'
import { formatTimeAgo } from '../../lib/format-time'
import { CountBadge } from '../common/badge'
import { ActionButton } from '../common/button'
import { JsonViewer } from '../common/json-viewer'
import { parseToolBlobMarker, type ToolBlobMarker } from '../../lib/tool-blob-marker'
import { fetchToolBlob } from '../../api/tool-blob'

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

/**
 * Render a tool output that was externalized to the blob store.
 * Shows preview + metadata by default; on click fetches the full bytes
 * via `/api/v1/artifacts/<sha256>` and switches to the inline renderer.
 *
 * The marker carries enough metadata (sha + bytes + preview) for the
 * operator to decide whether the full payload is worth fetching, which
 * is the whole point of the externalization tradeoff.
 */
function StoredBlobView({
  marker, success, toolName, timestamp,
}: {
  marker: ToolBlobMarker
  success: boolean
  toolName: string
  timestamp: number
}) {
  const expanded = useSignal(false)
  const loading = useSignal(false)
  const error = useSignal<string | null>(null)
  const fullText = useSignal<string | null>(null)
  const timeStr = formatTimeAgo(timestamp)

  const onLoad = async () => {
    if (fullText.value !== null) {
      expanded.value = !expanded.value
      return
    }
    loading.value = true
    error.value = null
    try {
      const blob = await fetchToolBlob(marker.sha256)
      fullText.value = blob.content
      expanded.value = true
    } catch (e) {
      error.value = e instanceof Error ? e.message : String(e)
    } finally {
      loading.value = false
    }
  }

  // Once full bytes are fetched, delegate to the inline renderer so JSON
  // formatting and copy-button behavior stays consistent.
  if (fullText.value !== null && expanded.value) {
    return html`
      <div class="flex flex-col gap-2 mt-3">
        <div class="flex items-center gap-2">
          <${CountBadge} tone=${success ? 'ok' : 'bad'}>${success ? 'OK' : 'ERR'}<//>
          <span class="text-2xs text-[var(--color-fg-muted)]">${toolName}</span>
          <span class="text-3xs text-[var(--color-fg-muted)] ml-auto">${timeStr}</span>
        </div>
        <div class="rounded border border-[var(--color-border-default)] bg-[var(--bg-0)] overflow-hidden">
          <div class="flex items-center justify-between px-3 py-1.5 border-b border-[var(--color-border-default)]">
            <button type="button" class="text-3xs text-[var(--color-fg-muted)] cursor-pointer hover:text-[var(--color-fg-primary)]"
              onClick=${() => { expanded.value = false }}>
              접기 (${marker.bytes.toLocaleString()}B)
            </button>
            <${ActionButton} variant="subtle" size="sm"
              onClick=${() => void navigator.clipboard.writeText(fullText.value ?? '')}>복사<//>
          </div>
          <div class="px-3 py-2 overflow-x-auto max-h-100 overflow-y-auto">
            ${(() => {
              const { isJson, parsed } = tryParseJson(fullText.value ?? '')
              return isJson
                ? html`<${JsonViewer} data=${parsed} />`
                : html`<pre class="text-xs font-mono ${success ? 'text-[var(--color-fg-primary)]' : 'text-[var(--bad-light)]'}">${fullText.value}</pre>`
            })()}
          </div>
        </div>
      </div>
    `
  }

  // Default: show preview + metadata + Load button. Bytes only fetched on demand.
  return html`
    <div class="flex flex-col gap-2 mt-3" data-testid="tool-blob-marker">
      <div class="flex items-center gap-2">
        <${CountBadge} tone=${success ? 'ok' : 'bad'}>${success ? 'OK' : 'ERR'}<//>
        <span class="text-2xs text-[var(--color-fg-muted)]">${toolName}</span>
        <span class="text-3xs text-[var(--color-fg-muted)] ml-auto">${timeStr}</span>
      </div>
      <div class="rounded border border-[var(--color-border-default)] bg-[var(--bg-0)] overflow-hidden">
        <div class="flex items-center justify-between px-3 py-1.5 border-b border-[var(--color-border-default)]">
          <span class="text-3xs text-[var(--color-fg-muted)]">
            저장된 출력 · ${marker.bytes.toLocaleString()}B · sha ${marker.sha256.slice(0, 12)}\u2026
          </span>
          <${ActionButton}
            variant="subtle" size="sm"
            disabled=${loading.value}
            onClick=${() => void onLoad()}>
            ${loading.value ? '\uad6c\uac00\uc624\ub294 \uc911\u2026' : '\uc804\uccb4 \ucd9c\ub825 \uc5f4\uae30'}
          <//>
        </div>
        <div class="px-3 py-2 overflow-x-auto max-h-50 overflow-y-auto">
          <pre class="text-xs font-mono text-[var(--color-fg-muted)] whitespace-pre-wrap">${marker.preview}</pre>
        </div>
        ${error.value ? html`
          <div class="px-3 py-1.5 border-t border-[var(--color-border-default)] text-2xs text-[var(--bad-light)]">
            ${error.value}
          </div>
        ` : null}
      </div>
    </div>
  `
}

export function ToolResultDisplay({ success, text, toolName, timestamp }: ToolResultProps) {
  // First check whether the payload is a sentinel marker. If so, the
  // dashboard switches to lazy-fetch mode so the operator sees the
  // preview + metadata first.
  const marker = parseToolBlobMarker(text)
  if (marker !== null) {
    return html`<${StoredBlobView}
      marker=${marker}
      success=${success}
      toolName=${toolName}
      timestamp=${timestamp} />`
  }

  const expanded = useSignal(true)
  const { isJson, parsed } = tryParseJson(text)
  const timeStr = formatTimeAgo(timestamp)
  const lines = text.split('\n').length
  return html`
    <div class="flex flex-col gap-2 mt-3">
      <div class="flex items-center gap-2">
        <${CountBadge} tone=${success ? 'ok' : 'bad'}>${success ? 'OK' : 'ERR'}<//>
        <span class="text-2xs text-[var(--color-fg-muted)]">${toolName}</span>
        <span class="text-3xs text-[var(--color-fg-muted)] ml-auto">${timeStr}</span>
      </div>
      <div class="rounded border border-[var(--color-border-default)] bg-[var(--bg-0)] overflow-hidden">
        <div class="flex items-center justify-between px-3 py-1.5 border-b border-[var(--color-border-default)]">
          <button type="button" class="text-3xs text-[var(--color-fg-muted)] cursor-pointer hover:text-[var(--color-fg-primary)]"
            onClick=${() => { expanded.value = !expanded.value }}>
            ${expanded.value ? '접기' : '펼치기'} (${lines}줄)
          </button>
          <${ActionButton} variant="subtle" size="sm" onClick=${() => void navigator.clipboard.writeText(text)}>복사<//>
        </div>
        ${expanded.value ? html`
          <div class="px-3 py-2 overflow-x-auto max-h-100 overflow-y-auto">
            ${isJson
              ? html`<${JsonViewer} data=${parsed} />`
              : html`<pre class="text-xs font-mono ${success ? 'text-[var(--color-fg-primary)]' : 'text-[var(--bad-light)]'}">${text}</pre>`
            }
          </div>
        ` : null}
      </div>
    </div>
  `
}
