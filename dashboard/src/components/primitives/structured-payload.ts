/**
 * Shared collapsible structured payload viewer for JSON and long text parameters/results.
 *
 * - Toggleable `Tree` (lazy expandable JSON tree with depth limit, array pagination,
 *   and 4KB head+tail string preview) vs `Raw` formatted view.
 * - `Wrap` toggle, `Copy` button, byte/line count badge.
 * - Default-collapsed when `defaultCollapsed` is true or payload exceeds thresholds
 *   (`> 8` lines or `> 600` chars), showing a compact 1-line preview.
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { copyTextToClipboard, formatByteSize } from '../../workspaces/keepers/tool-result-state'

export const DEFAULT_COLLAPSE_LINES = 8
export const DEFAULT_COLLAPSE_CHARS = 600
export const DEFAULT_MAX_DEPTH = 6
export const DEFAULT_ARRAY_PAGE_SIZE = 50
export const DEFAULT_STRING_PREVIEW_CHARS = 4096

export interface ParsedStructuredPayload {
  readonly isJson: boolean
  readonly parsed: unknown
  readonly formatted: string
  readonly bytes: number
  readonly lines: number
}

export interface StructuredPayloadViewProps {
  readonly value: unknown
  readonly label?: string
  readonly defaultCollapsed?: boolean
  readonly defaultMode?: 'tree' | 'raw'
  readonly collapseThresholdLines?: number
  readonly collapseThresholdChars?: number
  readonly maxDepth?: number
  readonly arrayPageSize?: number
  readonly maxStringPreviewChars?: number
  readonly testId?: string
  readonly bodyTestId?: string
  readonly className?: string
  readonly emptyText?: string
}

const UTF8_ENCODER = new TextEncoder()

export function parseStructuredPayload(value: unknown): ParsedStructuredPayload {
  if (value === undefined || value === null) {
    return { isJson: false, parsed: value, formatted: '', bytes: 0, lines: 0 }
  }
  if (typeof value === 'string') {
    const trimmed = value.trim()
    if (
      (trimmed.startsWith('{') && trimmed.endsWith('}'))
      || (trimmed.startsWith('[') && trimmed.endsWith(']'))
    ) {
      try {
        const parsed: unknown = JSON.parse(trimmed)
        const formatted = JSON.stringify(parsed, null, 2)
        return {
          isJson: true,
          parsed,
          formatted,
          bytes: UTF8_ENCODER.encode(formatted).length,
          lines: formatted === '' ? 0 : formatted.split('\n').length,
        }
      } catch {
        // Fall through to plain text formatting.
      }
    }
    return {
      isJson: false,
      parsed: value,
      formatted: value,
      bytes: UTF8_ENCODER.encode(value).length,
      lines: value === '' ? 0 : value.split('\n').length,
    }
  }
  try {
    const formatted = JSON.stringify(value, null, 2) ?? String(value)
    const isJson = typeof value === 'object'
    return {
      isJson,
      parsed: value,
      formatted,
      bytes: UTF8_ENCODER.encode(formatted).length,
      lines: formatted === '' ? 0 : formatted.split('\n').length,
    }
  } catch {
    const formatted = String(value)
    return {
      isJson: false,
      parsed: value,
      formatted,
      bytes: UTF8_ENCODER.encode(formatted).length,
      lines: formatted === '' ? 0 : formatted.split('\n').length,
    }
  }
}

export function shouldDefaultCollapse(
  formatted: string,
  maxLines = DEFAULT_COLLAPSE_LINES,
  maxChars = DEFAULT_COLLAPSE_CHARS,
): boolean {
  if (!formatted) return false
  if (formatted.length > maxChars) return true
  let lines = 1
  for (let i = 0; i < formatted.length; i += 1) {
    if (formatted.charCodeAt(i) === 10) {
      lines += 1
      if (lines > maxLines) return true
    }
  }
  return false
}

export function summarizePayload(parsed: unknown, formatted: string, maxChars = 120): string {
  if (Array.isArray(parsed)) {
    return `[${parsed.length} items]`
  }
  if (parsed !== null && typeof parsed === 'object') {
    const keys = Object.keys(parsed as Record<string, unknown>)
    if (keys.length === 0) return '{}'
    const shown = keys.slice(0, 5).join(', ')
    const more = keys.length > 5 ? `, +${keys.length - 5}` : ''
    const summary = `{ ${shown}${more} }`
    return summary.length > maxChars ? `${summary.slice(0, maxChars - 1)}…` : summary
  }
  const firstLine = formatted.split('\n').find((line) => line.trim().length > 0)?.trim() ?? formatted.trim()
  if (firstLine.length <= maxChars) return firstLine
  return `${firstLine.slice(0, maxChars - 1)}…`
}

export function splitHeadTailPreview(
  text: string,
  maxChars = DEFAULT_STRING_PREVIEW_CHARS,
): { readonly truncated: boolean; readonly head: string; readonly tail: string; readonly omittedChars: number } {
  if (text.length <= maxChars) {
    return { truncated: false, head: text, tail: '', omittedChars: 0 }
  }
  const half = Math.max(16, Math.floor(maxChars / 2))
  const head = text.slice(0, half)
  const tail = text.slice(text.length - half)
  return {
    truncated: true,
    head,
    tail,
    omittedChars: Math.max(0, text.length - head.length - tail.length),
  }
}

interface JsonTreeNodeProps {
  readonly name?: string
  readonly value: unknown
  readonly depth: number
  readonly maxDepth: number
  readonly arrayPageSize: number
  readonly maxStringPreviewChars: number
}

function JsonStringLeaf({
  text,
  maxStringPreviewChars,
}: {
  readonly text: string
  readonly maxStringPreviewChars: number
}) {
  const [expanded, setExpanded] = useState(false)
  const preview = useMemo(
    () => splitHeadTailPreview(text, maxStringPreviewChars),
    [text, maxStringPreviewChars],
  )
  if (!preview.truncated || expanded) {
    return html`
      <span class="spv-str">"${text}"</span>
      ${preview.truncated && html`
        <button
          type="button"
          class="btn-ghost btn-compact spv-inline-btn"
          onClick=${() => setExpanded(false)}
        >
          문자열 접기
        </button>
      `}
    `
  }
  return html`
    <span class="spv-str" data-testid="spv-truncated-string">
      "${preview.head}
      <span class="spv-omitted"> … [${preview.omittedChars.toLocaleString()}자 생략] … </span>
      ${preview.tail}"
    </span>
    <button
      type="button"
      class="btn-ghost btn-compact spv-inline-btn"
      data-testid="spv-expand-string"
      onClick=${() => setExpanded(true)}
    >
      전체 보기 (${text.length.toLocaleString()}자)
    </button>
  `
}

function JsonTreeNode({
  name,
  value,
  depth,
  maxDepth,
  arrayPageSize,
  maxStringPreviewChars,
}: JsonTreeNodeProps) {
  const isArray = Array.isArray(value)
  const isObject = value !== null && typeof value === 'object' && !isArray
  const [open, setOpen] = useState(depth < 2)
  const [visibleCount, setVisibleCount] = useState(arrayPageSize)

  const keyPrefix = name !== undefined
    ? html`<span class="spv-key">"${name}"</span><span class="spv-punct">: </span>`
    : null

  if (!isArray && !isObject) {
    if (typeof value === 'string') {
      return html`
        <div class="spv-leaf">
          ${keyPrefix}<${JsonStringLeaf} text=${value} maxStringPreviewChars=${maxStringPreviewChars} />
        </div>
      `
    }
    if (typeof value === 'number') {
      return html`<div class="spv-leaf">${keyPrefix}<span class="spv-num">${String(value)}</span></div>`
    }
    if (typeof value === 'boolean') {
      return html`<div class="spv-leaf">${keyPrefix}<span class="spv-bool">${String(value)}</span></div>`
    }
    return html`<div class="spv-leaf">${keyPrefix}<span class="spv-null">null</span></div>`
  }

  if (depth >= maxDepth) {
    const summary = isArray ? `[${value.length} items]` : `{${Object.keys(value as Record<string, unknown>).length} keys}`
    return html`
      <div class="spv-leaf" data-testid="spv-depth-limit">
        ${keyPrefix}<span class="spv-punct">${summary} (깊이 제한)</span>
      </div>
    `
  }

  if (isArray) {
    const len = value.length
    if (len === 0) {
      return html`<div class="spv-leaf">${keyPrefix}<span class="spv-punct">[]</span></div>`
    }
    const shown = open ? value.slice(0, visibleCount) : []
    const remaining = len - shown.length
    return html`
      <div class="spv-branch">
        <button
          type="button"
          class="spv-toggle"
          aria-expanded=${open ? 'true' : 'false'}
          onClick=${() => setOpen((v) => !v)}
        >
          <span class="spv-caret" aria-hidden="true">${open ? '▾' : '▸'}</span>
          ${keyPrefix}
          <span class="spv-punct">[${len} items]</span>
        </button>
        ${open && html`
          <div class="spv-children">
            ${shown.map((item, idx) => html`
              <${JsonTreeNode}
                key=${idx}
                name=${String(idx)}
                value=${item}
                depth=${depth + 1}
                maxDepth=${maxDepth}
                arrayPageSize=${arrayPageSize}
                maxStringPreviewChars=${maxStringPreviewChars}
              />
            `)}
            ${remaining > 0 && html`
              <button
                type="button"
                class="btn-ghost btn-compact spv-more-btn"
                data-testid="spv-array-more"
                onClick=${() => setVisibleCount((c) => c + arrayPageSize)}
              >
                더 보기 (+${Math.min(arrayPageSize, remaining)} / 남은 ${remaining}개)
              </button>
            `}
          </div>
        `}
      </div>
    `
  }

  const entries = Object.entries(value as Record<string, unknown>)
  if (entries.length === 0) {
    return html`<div class="spv-leaf">${keyPrefix}<span class="spv-punct">{}</span></div>`
  }

  return html`
    <div class="spv-branch">
      <button
        type="button"
        class="spv-toggle"
        aria-expanded=${open ? 'true' : 'false'}
        onClick=${() => setOpen((v) => !v)}
      >
        <span class="spv-caret" aria-hidden="true">${open ? '▾' : '▸'}</span>
        ${keyPrefix}
        <span class="spv-punct">{${entries.length} keys}</span>
      </button>
      ${open && html`
        <div class="spv-children">
          ${entries.map(([k, v]) => html`
            <${JsonTreeNode}
              key=${k}
              name=${k}
              value=${v}
              depth=${depth + 1}
              maxDepth=${maxDepth}
              arrayPageSize=${arrayPageSize}
              maxStringPreviewChars=${maxStringPreviewChars}
            />
          `)}
        </div>
      `}
    </div>
  `
}

export function StructuredPayloadView(props: StructuredPayloadViewProps) {
  const {
    value,
    label,
    defaultCollapsed,
    defaultMode,
    collapseThresholdLines = DEFAULT_COLLAPSE_LINES,
    collapseThresholdChars = DEFAULT_COLLAPSE_CHARS,
    maxDepth = DEFAULT_MAX_DEPTH,
    arrayPageSize = DEFAULT_ARRAY_PAGE_SIZE,
    maxStringPreviewChars = DEFAULT_STRING_PREVIEW_CHARS,
    testId,
    bodyTestId,
    className,
    emptyText = '데이터 없음',
  } = props

  const parsedPayload = useMemo(() => parseStructuredPayload(value), [value])
  const autoCollapse = useMemo(
    () => defaultCollapsed ?? shouldDefaultCollapse(parsedPayload.formatted, collapseThresholdLines, collapseThresholdChars),
    [defaultCollapsed, parsedPayload.formatted, collapseThresholdLines, collapseThresholdChars],
  )

  const [collapsed, setCollapsed] = useState(autoCollapse)
  const [mode, setMode] = useState<'tree' | 'raw'>(() =>
    defaultMode ?? (parsedPayload.isJson ? 'tree' : 'raw'),
  )
  const [wrap, setWrap] = useState(true)
  const [copied, setCopied] = useState(false)
  const copyTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const mountedRef = useRef(true)

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
      if (copyTimerRef.current) {
        clearTimeout(copyTimerRef.current)
        copyTimerRef.current = null
      }
    }
  }, [])

  useEffect(() => {
    setCollapsed(autoCollapse)
    setMode(defaultMode ?? (parsedPayload.isJson ? 'tree' : 'raw'))
    setCopied(false)
  }, [value, autoCollapse, defaultMode, parsedPayload.isJson])

  const handleCopy = useCallback(async () => {
    if (!parsedPayload.formatted) return
    const ok = await copyTextToClipboard(parsedPayload.formatted)
    if (!ok || !mountedRef.current) return
    setCopied(true)
    if (copyTimerRef.current) clearTimeout(copyTimerRef.current)
    copyTimerRef.current = setTimeout(() => {
      copyTimerRef.current = null
      if (mountedRef.current) setCopied(false)
    }, 1500)
  }, [parsedPayload.formatted])

  if (!parsedPayload.formatted) {
    return html`<div class="kp-block-status">${emptyText}</div>`
  }

  const effectiveMode = parsedPayload.isJson ? mode : 'raw'
  const summary = useMemo(
    () => summarizePayload(parsedPayload.parsed, parsedPayload.formatted),
    [parsedPayload.parsed, parsedPayload.formatted],
  )
  const badgeText = `${formatByteSize(parsedPayload.bytes)} · ${parsedPayload.lines}줄`

  return html`
    <div
      class=${`spv-root ${className ?? ''}`.trim()}
      data-testid=${testId ?? 'structured-payload'}
      data-collapsed=${collapsed ? 'true' : 'false'}
    >
      <div class="spv-bar">
        <div class="spv-bar-left">
          ${label && html`<span class="kp-block-sublabel">${label}</span>`}
          <span class="kp-pill mono tnum" data-testid="spv-meta-badge">${badgeText}</span>
        </div>
        <div class="spv-bar-actions">
          ${!collapsed && parsedPayload.isJson && html`
            <div class="ap-viewseg spv-mode-seg" role="group" aria-label="표시 형식">
              <button
                type="button"
                class=${`ap-viewbtn spv-seg-btn ${effectiveMode === 'tree' ? 'on' : ''}`}
                aria-pressed=${effectiveMode === 'tree' ? 'true' : 'false'}
                data-testid="spv-mode-tree"
                onClick=${() => setMode('tree')}
              >
                Tree
              </button>
              <button
                type="button"
                class=${`ap-viewbtn spv-seg-btn ${effectiveMode === 'raw' ? 'on' : ''}`}
                aria-pressed=${effectiveMode === 'raw' ? 'true' : 'false'}
                data-testid="spv-mode-raw"
                onClick=${() => setMode('raw')}
              >
                Raw
              </button>
            </div>
          `}
          ${!collapsed && effectiveMode === 'raw' && html`
            <button
              type="button"
              class="btn-ghost btn-compact"
              aria-pressed=${wrap ? 'true' : 'false'}
              data-testid="spv-wrap-toggle"
              onClick=${() => setWrap((w) => !w)}
            >
              줄바꿈
            </button>
          `}
          <button
            type="button"
            class="btn-ghost btn-compact"
            data-testid="spv-copy-btn"
            onClick=${() => void handleCopy()}
          >
            ${copied ? '복사됨' : '복사'}
          </button>
          <button
            type="button"
            class="btn-ghost btn-compact"
            aria-expanded=${!collapsed ? 'true' : 'false'}
            data-testid="spv-collapse-toggle"
            onClick=${() => setCollapsed((c) => !c)}
          >
            ${collapsed ? '펼치기' : '접기'}
          </button>
        </div>
      </div>

      ${collapsed
        ? html`
            <button
              type="button"
              class="spv-collapsed-preview mono"
              data-testid=${bodyTestId ? `${bodyTestId}-preview` : 'spv-collapsed-preview'}
              onClick=${() => setCollapsed(false)}
              title="클릭하여 전체 내용 펼치기"
            >
              <span class="spv-preview-text">${summary}</span>
              <span class="spv-preview-hint">펼치기 ▾</span>
            </button>
          `
        : effectiveMode === 'tree'
          ? html`
              <div
                class="spv-tree mono"
                data-testid=${bodyTestId ?? 'spv-tree'}
              >
                <${JsonTreeNode}
                  value=${parsedPayload.parsed}
                  depth=${0}
                  maxDepth=${maxDepth}
                  arrayPageSize=${arrayPageSize}
                  maxStringPreviewChars=${maxStringPreviewChars}
                />
              </div>
            `
          : html`
              <pre
                class=${`kp-block-pre spv-pre ${wrap ? 'spv-pre--wrap' : 'spv-pre--nowrap'}`}
                data-testid=${bodyTestId ?? 'spv-raw'}
              >${parsedPayload.formatted}</pre>
            `}
    </div>
  `
}
