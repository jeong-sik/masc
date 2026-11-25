/**
 * Shared Paginated `/api/v1/keepers/:name/tool-result` State & Continuation Helper.
 *
 * Used identically by both `KeeperChatTab` inline tool cards and
 * `KeeperToolCallInspector` inside the shell `QuickPeekDrawer`.
 *
 * - Accumulates raw page chunks (`rawContent`) across continuation requests
 *   (`offset=<next_offset>&source_id=<source_id>`) and formats with
 *   `prettyFormatPayload` once `eof === true`, avoiding mangled JSON across
 *   16KB page boundaries.
 * - Bounds burst "끝까지 불러오기" loops (`TOOL_RESULT_MAX_PAGES_PER_BURST`)
 *   and aborts cleanly on unmount, keeper switch, or `sessionEpoch` changes.
 * - Detects `409 Conflict` / `source_id` drift without discarding already-loaded
 *   pages, offering a clean "처음부터 다시 불러오기" recovery path.
 */

import type { ApiError } from '../../core/transport'
import { prettyFormatPayload } from './chat-blocks'
import { fetchKeeperToolResultApi } from './keepers-api'
import type { KeeperToolResultResponse } from './types'

export const TOOL_RESULT_PAGE_BYTES = 16_384
export const TOOL_RESULT_MAX_PAGES_PER_BURST = 16
export const LONG_OUTPUT_CHAR_THRESHOLD = 600
export const LONG_OUTPUT_LINE_THRESHOLD = 14

export interface ToolResultState {
  readonly status: 'loading' | 'loaded' | 'pending' | 'unavailable' | 'error'
  readonly rawContent?: string
  readonly displayContent?: string
  readonly isError?: boolean
  readonly detail?: string
  readonly sourceChanged?: boolean
  readonly sourceId?: string
  readonly offset?: number
  readonly nextOffset?: number
  readonly recordedBytes?: number
  readonly totalBytes?: number
  readonly eof?: boolean
  readonly encoding?: string
  readonly isBinary?: boolean
  readonly pagesLoaded?: number
  readonly loadingMore?: boolean
  readonly loadMoreError?: string | null
  readonly loadMoreConflict?: boolean
}

export function formatByteSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return '0 B'
  if (bytes < 1024) return `${Math.round(bytes)} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`
}

export function formatToolResultProgress(state: ToolResultState | undefined): string | null {
  if (!state || state.status !== 'loaded') return null
  const total = state.totalBytes ?? state.recordedBytes
  if (total === undefined) return null
  if (state.eof === false) {
    const loaded = Math.min(total, Math.max(0, state.nextOffset ?? 0))
    return `${formatByteSize(loaded)} / ${formatByteSize(total)}`
  }
  return formatByteSize(total)
}

export function isLongToolOutput(text: string | undefined): boolean {
  if (!text) return false
  if (text.length >= LONG_OUTPUT_CHAR_THRESHOLD) return true
  let lines = 1
  for (let i = 0; i < text.length; i += 1) {
    if (text.charCodeAt(i) === 10) {
      lines += 1
      if (lines >= LONG_OUTPUT_LINE_THRESHOLD) return true
    }
  }
  return false
}

export function applyToolResultPage(
  prev: ToolResultState | undefined,
  response: KeeperToolResultResponse,
  opts?: { readonly append?: boolean },
): ToolResultState {
  const append = opts?.append === true

  if (response.state === 'pending') {
    if (append && prev?.status === 'loaded') {
      return {
        ...prev,
        loadingMore: false,
        loadMoreConflict: false,
        loadMoreError: '도구 실행 중 — 결과 준비 대기 중입니다.',
      }
    }
    return { status: 'pending' }
  }

  if (response.state === 'unavailable') {
    if (append && prev?.status === 'loaded') {
      return {
        ...prev,
        loadingMore: false,
        loadMoreConflict: false,
        loadMoreError: response.reason,
      }
    }
    return { status: 'unavailable', detail: response.reason }
  }

  const isBinary = response.encoding === 'base64'

  if (append && prev?.status === 'loaded' && !prev.isBinary) {
    if (prev.sourceId && response.sourceId && prev.sourceId !== response.sourceId) {
      return {
        ...prev,
        loadingMore: false,
        loadMoreConflict: true,
        loadMoreError: '원본 결과가 변경되었습니다. 처음부터 다시 불러오세요.',
      }
    }
    if (prev.nextOffset !== undefined && response.offset !== prev.nextOffset) {
      return {
        ...prev,
        loadingMore: false,
        loadMoreConflict: true,
        loadMoreError: '페이지 오프셋이 일치하지 않습니다. 처음부터 다시 불러오세요.',
      }
    }
    if (!response.eof && response.nextOffset <= response.offset) {
      return {
        ...prev,
        loadingMore: false,
        loadMoreConflict: false,
        loadMoreError: '추가 페이지 진행이 멈췄습니다.',
      }
    }
    if (isBinary) {
      const priorRaw = prev.rawContent ?? ''
      const priorDisplay = prev.displayContent ?? priorRaw
      const displayContent = priorDisplay
        ? `${priorDisplay}\n\n${response.content}`
        : response.content
      return {
        status: 'loaded',
        rawContent: priorRaw,
        displayContent,
        isError: response.isError,
        sourceId: response.sourceId ?? prev.sourceId,
        offset: response.offset,
        nextOffset: response.nextOffset,
        recordedBytes: response.recordedBytes,
        totalBytes: response.totalBytes,
        eof: response.eof,
        encoding: response.encoding,
        isBinary: true,
        pagesLoaded: (prev.pagesLoaded ?? 1) + 1,
        loadingMore: false,
        loadMoreError: null,
        loadMoreConflict: false,
      }
    }
    const rawContent = (prev.rawContent ?? '') + response.content
    const displayContent = response.eof
      ? prettyFormatPayload(rawContent)
      : rawContent
    return {
      status: 'loaded',
      rawContent,
      displayContent,
      isError: response.isError,
      sourceId: response.sourceId ?? prev.sourceId,
      offset: response.offset,
      nextOffset: response.nextOffset,
      recordedBytes: response.recordedBytes,
      totalBytes: response.totalBytes,
      eof: response.eof,
      encoding: response.encoding,
      isBinary: false,
      pagesLoaded: (prev.pagesLoaded ?? 1) + 1,
      loadingMore: false,
      loadMoreError: null,
      loadMoreConflict: false,
    }
  }

  const rawContent = response.content
  const displayContent = isBinary
    ? response.content
    : response.eof
      ? prettyFormatPayload(rawContent)
      : rawContent
  return {
    status: 'loaded',
    rawContent,
    displayContent,
    isError: response.isError,
    sourceId: response.sourceId,
    offset: response.offset,
    nextOffset: response.nextOffset,
    recordedBytes: response.recordedBytes,
    totalBytes: response.totalBytes,
    eof: response.eof,
    encoding: response.encoding,
    isBinary,
    pagesLoaded: 1,
    loadingMore: false,
    loadMoreError: null,
    loadMoreConflict: false,
  }
}

export function applyToolResultError(
  prev: ToolResultState | undefined,
  error: ApiError,
  opts?: { readonly append?: boolean },
): ToolResultState {
  const isConflict = error.status === 409 || error.kind === 'conflict_cas'
  if (opts?.append && prev?.status === 'loaded') {
    return {
      ...prev,
      loadingMore: false,
      loadMoreConflict: isConflict,
      loadMoreError: isConflict
        ? '원본 결과가 변경되었습니다. 처음부터 다시 불러오세요.'
        : error.message,
    }
  }
  return {
    status: 'error',
    detail: error.message,
    sourceChanged: isConflict,
  }
}

export async function copyTextToClipboard(text: string): Promise<boolean> {
  if (typeof navigator !== 'undefined' && navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
    try {
      await navigator.clipboard.writeText(text)
      return true
    } catch {
      // Fall through to execCommand fallback on permission/non-HTTPS failures.
    }
  }
  if (typeof document === 'undefined' || !document.body || typeof document.execCommand !== 'function') {
    return false
  }
  const ta = document.createElement('textarea')
  ta.value = text
  ta.setAttribute('readonly', '')
  ta.className = 'kp-sr-copy-buffer'
  document.body.appendChild(ta)
  try {
    ta.select()
    return document.execCommand('copy')
  } catch {
    return false
  } finally {
    ta.remove()
  }
}

export async function fetchToolResultContinuation(params: {
  readonly keeperName: string
  readonly executionId: string
  readonly initialState: ToolResultState
  readonly maxPages: number
  readonly signal: AbortSignal
  readonly isCurrent: () => boolean
  readonly onUpdate: (next: ToolResultState) => void
}): Promise<ToolResultState> {
  const { keeperName, executionId, maxPages, signal, isCurrent, onUpdate } = params
  let state: ToolResultState = params.initialState
  if (state.status !== 'loaded' || state.eof || state.isBinary) return state

  const cappedMaxPages = Math.max(1, Math.min(TOOL_RESULT_MAX_PAGES_PER_BURST, Math.trunc(maxPages)))

  if (!state.sourceId) {
    const conflictState: ToolResultState = {
      ...state,
      loadingMore: false,
      loadMoreConflict: true,
      loadMoreError: '원본 결과 식별자(source_id)가 없어 이어 읽을 수 없습니다. 처음부터 다시 불러오세요.',
    }
    onUpdate(conflictState)
    return conflictState
  }

  state = {
    ...state,
    loadingMore: true,
    loadMoreError: null,
    loadMoreConflict: false,
  }
  onUpdate(state)

  for (let pageIdx = 0; pageIdx < cappedMaxPages; pageIdx += 1) {
    if (signal.aborted || !isCurrent()) return state
    const nextOffset = state.nextOffset ?? 0
    const res = await fetchKeeperToolResultApi(
      keeperName,
      executionId,
      TOOL_RESULT_PAGE_BYTES,
      signal,
      { offset: nextOffset, sourceId: state.sourceId },
    )
    if (signal.aborted || !isCurrent()) return state
    if (!res.ok) {
      if (res.error.kind === 'aborted' || res.error.kind === 'epoch_stale') {
        return state
      }
      state = applyToolResultError(state, res.error, { append: true })
      onUpdate(state)
      return state
    }
    const merged = applyToolResultPage(state, res.value, { append: true })
    const hasMoreToFetch =
      pageIdx + 1 < cappedMaxPages
      && merged.status === 'loaded'
      && !merged.eof
      && !merged.isBinary
      && !merged.loadMoreError
      && !merged.loadMoreConflict
    state = hasMoreToFetch ? { ...merged, loadingMore: true } : merged
    onUpdate(state)
    if (!hasMoreToFetch) return state
  }

  if (state.loadingMore) {
    state = { ...state, loadingMore: false }
    onUpdate(state)
  }
  return state
}
