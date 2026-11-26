/**
 * Read-Only Tool Call Inspector rendered inside the shell `QuickPeekDrawer`.
 *
 * Wired from both `Work & Sandbox` (`KeeperWorkSandboxTab`) and `Debug Companion`
 * (`KeeperDebugCompanion`) tool-call rows. Shares the exact same multi-page
 * `/api/v1/keepers/:name/tool-result` accumulator as `KeeperChatTab`.
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { MarkdownContent } from '../../components/common/markdown-renderer'
import { currentSessionEpoch, isEpochCurrent, sessionEpoch } from '../../core/auth'
import { prettyFormatPayload, toolResultMarkdownPreview } from './chat-blocks'
import { fetchKeeperToolResultApi } from './keepers-api'
import {
  TOOL_RESULT_MAX_PAGES_PER_BURST,
  TOOL_RESULT_PAGE_BYTES,
  applyToolResultError,
  applyToolResultPage,
  copyTextToClipboard,
  fetchToolResultContinuation,
  formatByteSize,
  formatToolResultProgress,
  isLongToolOutput,
  type ToolResultState,
} from './tool-result-state'
import type { KeeperToolCallEntry } from './types'

export interface KeeperToolCallInspectorProps {
  readonly keeperName: string
  readonly entry: KeeperToolCallEntry
}

function formatEntryPayload(value: unknown): string {
  if (value === undefined || value === null) return ''
  return prettyFormatPayload(value)
}

const UTF8_ENCODER = new TextEncoder()

function isPreviewTruncated(entry: KeeperToolCallEntry): boolean {
  if (entry.truncated_to !== undefined) return true
  if (entry.result_bytes === undefined) return false
  if (typeof entry.output === 'string') {
    return entry.result_bytes > UTF8_ENCODER.encode(entry.output).length
  }
  return false
}

export function KeeperToolCallInspector(props: KeeperToolCallInspectorProps) {
  const { keeperName, entry } = props
  const executionId = entry.execution_id?.trim() || ''

  const [resultState, setResultState] = useState<ToolResultState | null>(() =>
    executionId ? { status: 'loading' } : null,
  )
  const [inputExpanded, setInputExpanded] = useState(false)
  const [outputExpanded, setOutputExpanded] = useState(false)
  const [showRawJson, setShowRawJson] = useState(false)
  const [copiedTarget, setCopiedTarget] = useState<'input' | 'output' | 'raw' | null>(null)

  const mountedRef = useRef(true)
  const activeControllerRef = useRef<AbortController | null>(null)
  const resultStateRef = useRef<ToolResultState | null>(resultState)
  resultStateRef.current = resultState
  const targetRef = useRef({ keeperName, executionId })
  targetRef.current = { keeperName, executionId }
  const copyTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  const abortActive = useCallback(() => {
    activeControllerRef.current?.abort()
    activeControllerRef.current = null
  }, [])

  const triggerCopy = useCallback(async (target: 'input' | 'output' | 'raw', text: string) => {
    const ok = await copyTextToClipboard(text)
    if (!ok || !mountedRef.current) return
    setCopiedTarget(target)
    if (copyTimerRef.current) clearTimeout(copyTimerRef.current)
    copyTimerRef.current = setTimeout(() => {
      copyTimerRef.current = null
      if (mountedRef.current) setCopiedTarget(null)
    }, 1500)
  }, [])

  const loadInitialPage = useCallback(async (force = false) => {
    if (!executionId) {
      setResultState(null)
      return
    }
    if (activeControllerRef.current && !force) return
    abortActive()
    const ctrl = new AbortController()
    activeControllerRef.current = ctrl
    const startEpoch = currentSessionEpoch()
    const targetKeeper = keeperName
    const targetExec = executionId
    setResultState({ status: 'loading' })
    try {
      const res = await fetchKeeperToolResultApi(
        targetKeeper,
        targetExec,
        TOOL_RESULT_PAGE_BYTES,
        ctrl.signal,
      )
      if (
        !mountedRef.current
        || !isEpochCurrent(startEpoch)
        || activeControllerRef.current !== ctrl
        || ctrl.signal.aborted
        || targetRef.current.keeperName !== targetKeeper
        || targetRef.current.executionId !== targetExec
      ) {
        return
      }
      if (!res.ok) {
        if (res.error.kind === 'aborted' || res.error.kind === 'epoch_stale') return
        setResultState(applyToolResultError(undefined, res.error))
        return
      }
      setResultState(applyToolResultPage(undefined, res.value))
    } finally {
      if (activeControllerRef.current === ctrl) {
        activeControllerRef.current = null
      }
    }
  }, [abortActive, executionId, keeperName])

  const loadMorePages = useCallback(async (maxPages: number) => {
    const cur = resultStateRef.current
    if (!executionId || !cur || cur.status !== 'loaded' || cur.eof || cur.isBinary) return
    if (activeControllerRef.current) return
    const ctrl = new AbortController()
    activeControllerRef.current = ctrl
    const startEpoch = currentSessionEpoch()
    const targetKeeper = keeperName
    const targetExec = executionId
    const isCurrent = () =>
      mountedRef.current
      && isEpochCurrent(startEpoch)
      && activeControllerRef.current === ctrl
      && !ctrl.signal.aborted
      && targetRef.current.keeperName === targetKeeper
      && targetRef.current.executionId === targetExec
    try {
      await fetchToolResultContinuation({
        keeperName: targetKeeper,
        executionId: targetExec,
        initialState: cur,
        maxPages,
        signal: ctrl.signal,
        isCurrent,
        onUpdate: (next) => {
          if (isCurrent()) setResultState(next)
        },
      })
    } finally {
      if (activeControllerRef.current === ctrl) {
        activeControllerRef.current = null
      }
    }
  }, [executionId, keeperName])

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
      abortActive()
      if (copyTimerRef.current) {
        clearTimeout(copyTimerRef.current)
        copyTimerRef.current = null
      }
    }
  }, [abortActive])

  useEffect(() => {
    let lastEpoch = currentSessionEpoch()
    return sessionEpoch.subscribe((ep) => {
      if (ep !== lastEpoch) {
        lastEpoch = ep
        abortActive()
        if (mountedRef.current) {
          void loadInitialPage()
        }
      }
    })
  }, [abortActive, loadInitialPage])

  useEffect(() => {
    setInputExpanded(false)
    setOutputExpanded(false)
    setShowRawJson(false)
    setCopiedTarget(null)
    if (executionId) {
      void loadInitialPage(true)
    } else {
      abortActive()
      setResultState(null)
    }
  }, [keeperName, executionId, entry.ts, entry.tool, loadInitialPage, abortActive])

  const formattedInput = useMemo(() => formatEntryPayload(entry.input), [entry.input])
  const previewOutput = useMemo(() => formatEntryPayload(entry.output), [entry.output])
  const rawEntryJson = useMemo(() => JSON.stringify(entry, null, 2), [entry])

  const hydratedLoaded = resultState?.status === 'loaded'
  const effectiveOutput = hydratedLoaded
    ? (resultState.displayContent ?? '')
    : previewOutput
  const outcomeTone =
    entry.disposition === 'failed' || (hydratedLoaded && resultState.isError)
      ? 'bad'
      : entry.disposition === 'deferred'
        ? 'warn'
        : 'ok'
  const progressText = formatToolResultProgress(resultState ?? undefined)
  const previewTruncated = isPreviewTruncated(entry)
  const completeOutput = hydratedLoaded ? resultState.eof && !resultState.isBinary : !previewTruncated
  const markdown = completeOutput ? toolResultMarkdownPreview(effectiveOutput) : null
  const rawOutput = html`
    <pre
      class=${outputExpanded ? 'kp-block-pre kp-block-pre--expanded' : 'kp-block-pre'}
      data-testid="tool-call-inspector-output"
    >${effectiveOutput}</pre>
  `
  const canLoadMore = Boolean(
    executionId
    && hydratedLoaded
    && !resultState.eof
    && !resultState.isBinary,
  )

  const secondaryMetaSummary: string[] = []
  if (entry.turn !== undefined) secondaryMetaSummary.push(`Turn #${entry.turn}`)
  if (entry.record_kind !== 'tool_call') secondaryMetaSummary.push(entry.record_kind)
  if (entry.model) secondaryMetaSummary.push(entry.model)
  if (executionId) secondaryMetaSummary.push(`exec: ${executionId.slice(0, 12)}${executionId.length > 12 ? '…' : ''}`)
  const hasSecondaryMeta = secondaryMetaSummary.length > 0

  return html`
    <div class="kp-inspector" data-testid="tool-call-inspector">
      <div class="kp-pill-row" data-testid="tool-call-inspector-meta">
        <span class="kp-pill" data-tone="info">${entry.tool}</span>
        <span class="kp-pill" data-tone=${outcomeTone}>
          ${entry.disposition ?? entry.wire_outcome}
        </span>
        <span class="kp-pill">${Math.round(entry.duration_ms)}ms</span>
        ${entry.failure_class && html`
          <span class="kp-pill" data-tone="bad">${entry.failure_class}</span>
        `}
        ${hydratedLoaded && progressText
          ? html`
              <span class="kp-pill" data-tone=${resultState.eof === false ? 'warn' : 'ok'}>
                ${progressText}${resultState.isBinary ? ' · 바이너리' : ''}${resultState.eof === false ? ' · 일부 표시' : ' · 전체'}
              </span>
            `
          : entry.result_bytes !== undefined && html`
              <span class="kp-pill" data-tone=${previewTruncated ? 'warn' : 'default'}>
                ${formatByteSize(entry.result_bytes)}${previewTruncated ? ' · 잘림' : ''}
              </span>
            `}
      </div>

      ${hasSecondaryMeta && html`
        <details class="ap-disclosure" data-testid="tool-call-inspector-secondary-meta">
          <summary class="ap-disclosure-trigger">
            <span>실행 메타데이터 (${secondaryMetaSummary.join(' · ')})</span>
            <span aria-hidden="true">▸</span>
          </summary>
          <div class="ap-disclosure-body">
            <div class="kp-pill-row">
              ${entry.turn !== undefined && html`
                <span class="kp-pill">Turn #${entry.turn}</span>
              `}
              ${entry.record_kind !== 'tool_call' && html`
                <span class="kp-pill">${entry.record_kind}</span>
              `}
              ${entry.model && html`
                <span class="kp-pill">${entry.model}</span>
              `}
              ${executionId && html`
                <span class="kp-pill">exec: ${executionId}</span>
              `}
            </div>
          </div>
        </details>
      `}

      <!-- Input (Args) -->
      <section class="kp-inspector-section" aria-label="입력 (Args)">
        <div class="kp-block-subbar">
          <span class="kp-block-sublabel">Input (Args)</span>
          <div class="kp-block-subactions">
            ${formattedInput && html`
              <button
                type="button"
                class="btn-ghost kp-toggle-btn"
                onClick=${() => void triggerCopy('input', formattedInput)}
              >
                ${copiedTarget === 'input' ? '복사됨' : '복사'}
              </button>
            `}
            ${isLongToolOutput(formattedInput) && html`
              <button
                type="button"
                class="btn-ghost kp-toggle-btn"
                onClick=${() => setInputExpanded((v) => !v)}
              >
                ${inputExpanded ? '축소' : '전체 높이'}
              </button>
            `}
          </div>
        </div>
        ${formattedInput
          ? html`
              <pre
                class=${inputExpanded ? 'kp-block-pre kp-block-pre--expanded' : 'kp-block-pre'}
                data-testid="tool-call-inspector-input"
              >${formattedInput}</pre>
            `
          : html`<div class="kp-block-status">입력 인자 없음</div>`}
      </section>

      <!-- Output (Result) -->
      <section class="kp-inspector-section" aria-label="출력 (Result)">
        <div class="kp-block-subbar">
          <div class="kp-pill-row">
            <span class="kp-block-sublabel">Output (Result)</span>
            ${hydratedLoaded
              ? html`<span class="kp-pill" data-tone="ok">원본 결과</span>`
              : executionId
                ? html`<span class="kp-pill" data-tone="info">미리보기</span>`
                : null}
            ${progressText && html`<span class="kp-pill">${progressText}</span>`}
          </div>
          <div class="kp-block-subactions">
            ${effectiveOutput && html`
              <button
                type="button"
                class="btn-ghost kp-toggle-btn"
                onClick=${() => void triggerCopy('output', effectiveOutput)}
              >
                ${copiedTarget === 'output' ? '복사됨' : '복사'}
              </button>
            `}
            ${isLongToolOutput(effectiveOutput) && html`
              <button
                type="button"
                class="btn-ghost kp-toggle-btn"
                onClick=${() => setOutputExpanded((v) => !v)}
              >
                ${outputExpanded ? '축소' : '전체 높이'}
              </button>
            `}
          </div>
        </div>

        ${resultState?.status === 'loading' && html`
          <div class="kp-block-status" data-testid="tool-call-inspector-loading">
            원본 전체 결과 불러오는 중…
          </div>
        `}

        ${resultState?.status === 'pending' && html`
          <div class="kp-block-status">
            도구 실행 중 — 결과 준비 대기 중…
            ${' '}
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              onClick=${() => void loadInitialPage(true)}
            >
              다시 확인
            </button>
          </div>
        `}

        ${resultState?.status === 'unavailable' && html`
          <div class="kp-block-status">
            저장된 원본 결과 없음 (${resultState.detail ?? 'unavailable'}) — 로그 미리보기 표시
          </div>
        `}

        ${resultState?.status === 'error' && html`
          <div class="kp-tool-result-error" role="status">
            <span>원본 결과 조회 실패 (${resultState.detail ?? 'error'})</span>
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              onClick=${() => void loadInitialPage(true)}
            >
              ${resultState.sourceChanged ? '처음부터 다시 불러오기' : '다시 시도'}
            </button>
          </div>
        `}

        ${effectiveOutput
          ? markdown === null ? rawOutput : html`
              <${MarkdownContent} text=${markdown} />
              <details open=${outputExpanded || undefined}>
                <summary>저장 참조</summary>
                ${rawOutput}
              </details>
            `
          : hydratedLoaded
            ? html`<div class="kp-block-status">(빈 출력 · 0 B)</div>`
            : html`<div class="kp-block-status">출력 결과 없음</div>`}

        ${canLoadMore && html`
          <div class="kp-tool-result-pager" data-testid="tool-call-inspector-pager">
            <span class="kp-pill" data-tone="warn">
              ${resultState?.loadingMore
                ? `불러오는 중… (${progressText ?? ''})`
                : `표시 중 ${progressText ?? ''}`}
            </span>
            <div class="kp-block-subactions">
              <button
                type="button"
                class="btn-ghost kp-toggle-btn"
                disabled=${resultState?.loadingMore === true}
                onClick=${() => void loadMorePages(1)}
              >
                더 불러오기 (+16KB)
              </button>
              <button
                type="button"
                class="btn-ghost kp-toggle-btn"
                disabled=${resultState?.loadingMore === true}
                onClick=${() => void loadMorePages(TOOL_RESULT_MAX_PAGES_PER_BURST)}
              >
                끝까지 불러오기
              </button>
            </div>
          </div>
        `}

        ${hydratedLoaded && resultState.loadMoreError && html`
          <div class="kp-tool-result-error" role="status" data-testid="tool-call-inspector-load-more-error">
            <span>${resultState.loadMoreError}</span>
            <div class="kp-block-subactions">
              ${resultState.loadMoreConflict
                ? html`
                    <button
                      type="button"
                      class="btn-ghost kp-toggle-btn"
                      onClick=${() => void loadInitialPage(true)}
                    >
                      처음부터 다시 불러오기
                    </button>
                  `
                : html`
                    <button
                      type="button"
                      class="btn-ghost kp-toggle-btn"
                      onClick=${() => void loadMorePages(1)}
                    >
                      다시 시도
                    </button>
                    <button
                      type="button"
                      class="btn-ghost kp-toggle-btn"
                      onClick=${() => void loadInitialPage(true)}
                    >
                      처음부터 다시 불러오기
                    </button>
                  `}
            </div>
          </div>
        `}
      </section>

      <!-- Raw JSON Toggle -->
      <div class="kp-inspector-section">
        <div class="kp-block-subbar">
          <button
            type="button"
            class="btn-ghost kp-toggle-btn"
            data-testid="tool-call-raw-toggle"
            aria-pressed=${showRawJson ? 'true' : 'false'}
            onClick=${() => setShowRawJson((v) => !v)}
          >
            ${showRawJson ? '원본 JSON 숨기기' : '원본 JSON 보기'}
          </button>
          ${showRawJson && html`
            <button
              type="button"
              class="btn-ghost kp-toggle-btn"
              onClick=${() => void triggerCopy('raw', rawEntryJson)}
            >
              ${copiedTarget === 'raw' ? '복사됨' : 'JSON 복사'}
            </button>
          `}
        </div>
        ${showRawJson && html`
          <pre class="kp-block-pre" data-testid="tool-call-inspector-raw">${rawEntryJson}</pre>
        `}
      </div>
    </div>
  `
}
