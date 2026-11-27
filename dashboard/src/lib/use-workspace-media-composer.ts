/**
 * Shared Preact hook for authenticated workspace media upload authoring across
 * live Dashboard Markdown composers (`WikiTab`, `BoardTab`, `TasksTab`).
 *
 * Owns clipboard image paste, drag-and-drop, file picker upload, cursor-aware
 * Markdown insertion, and draft-identity (`draftKey`) abort fencing so switching
 * targets or submitting a draft never inserts a late upload into a new draft.
 */

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks'
import type { RefObject } from 'preact'
import { currentSessionEpoch, isEpochCurrent } from '../core/auth'
import { pushShellToast } from '../shell/shell-state'
import {
  dataTransferHasFiles,
  deriveImageAltText,
  extractUploadFilesFromDataTransfer,
  formatUploadedImageMarkdown,
  insertTextAtSelection,
  uploadWorkspaceMedia,
} from './workspace-media-upload'

export interface WorkspaceMediaUploadProgress {
  readonly current: number
  readonly total: number
}

export interface UseWorkspaceMediaComposerOptions {
  readonly value: string
  readonly onChange: (nextValue: string) => void
  readonly draftKey: string
  readonly disabled?: boolean
  readonly textareaRef?: RefObject<HTMLTextAreaElement>
}

export interface WorkspaceMediaComposerController {
  readonly textareaRef: RefObject<HTMLTextAreaElement>
  readonly fileInputRef: RefObject<HTMLInputElement>
  readonly dragActive: boolean
  readonly uploadProgress: WorkspaceMediaUploadProgress | null
  readonly uploading: boolean
  readonly uploadError: string | null
  readonly syncSelection: () => void
  readonly insertSnippet: (snippet: string) => void
  readonly handleUploadFiles: (files: readonly File[]) => Promise<void>
  readonly handlePaste: (event: ClipboardEvent) => void
  readonly handleDragEnter: (event: DragEvent) => void
  readonly handleDragOver: (event: DragEvent) => void
  readonly handleDragLeave: () => void
  readonly handleDrop: (event: DragEvent) => void
  readonly handleFileInputChange: (event: Event) => void
  readonly openFilePicker: () => void
  readonly cancelUpload: () => void
  readonly reset: () => void
}

export function useWorkspaceMediaComposer({
  value,
  onChange,
  draftKey,
  disabled = false,
  textareaRef: externalTextareaRef,
}: UseWorkspaceMediaComposerOptions): WorkspaceMediaComposerController {
  const internalTextareaRef = useRef<HTMLTextAreaElement>(null)
  const textareaRef = externalTextareaRef ?? internalTextareaRef
  const fileInputRef = useRef<HTMLInputElement>(null)

  const [dragActive, setDragActive] = useState(false)
  const [uploadProgress, setUploadProgress] = useState<WorkspaceMediaUploadProgress | null>(null)
  const [uploadError, setUploadError] = useState<string | null>(null)

  const mountedRef = useRef(true)
  const uploadAbortRef = useRef<AbortController | null>(null)
  const uploadingRef = useRef(false)
  const dragDepthRef = useRef(0)
  const selectionRef = useRef<{ start: number; end: number }>({
    start: value.length,
    end: value.length,
  })
  const pendingCursorRef = useRef<number | null>(null)

  const valueRef = useRef(value)
  valueRef.current = value
  const onChangeRef = useRef(onChange)
  onChangeRef.current = onChange
  const disabledRef = useRef(disabled)
  disabledRef.current = disabled
  const draftKeyRef = useRef(draftKey)
  draftKeyRef.current = draftKey
  const prevDraftKeyRef = useRef(draftKey)

  const reset = useCallback(() => {
    uploadAbortRef.current?.abort()
    uploadAbortRef.current = null
    uploadingRef.current = false
    dragDepthRef.current = 0
    pendingCursorRef.current = null
    if (mountedRef.current) {
      setDragActive(false)
      setUploadProgress(null)
      setUploadError(null)
    }
  }, [])

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
      uploadAbortRef.current?.abort()
      uploadAbortRef.current = null
      uploadingRef.current = false
    }
  }, [])

  // Abort and clear upload state synchronously on DOM commit whenever the edited draft target changes.
  useLayoutEffect(() => {
    if (prevDraftKeyRef.current === draftKey) return
    prevDraftKeyRef.current = draftKey
    reset()
    selectionRef.current = { start: valueRef.current.length, end: valueRef.current.length }
  }, [draftKey, reset])

  // Abort in-flight uploads synchronously if editing permissions become disabled.
  useLayoutEffect(() => {
    if (disabled && uploadingRef.current) {
      reset()
    }
  }, [disabled, reset])

  useLayoutEffect(() => {
    const pos = pendingCursorRef.current
    if (pos === null) return
    pendingCursorRef.current = null
    const target = textareaRef.current
    if (target && mountedRef.current) {
      target.focus()
      target.setSelectionRange(pos, pos)
      selectionRef.current = { start: pos, end: pos }
    }
  }, [value, textareaRef])

  const syncSelection = useCallback(() => {
    const el = textareaRef.current
    if (!el) return
    selectionRef.current = {
      start: el.selectionStart ?? el.value.length,
      end: el.selectionEnd ?? el.value.length,
    }
  }, [textareaRef])

  const insertSnippet = useCallback((snippet: string) => {
    const el = textareaRef.current
    const currentText = valueRef.current
    const start = el && typeof document !== 'undefined' && document.activeElement === el
      ? (el.selectionStart ?? currentText.length)
      : Math.min(selectionRef.current.start, currentText.length)
    const end = el && typeof document !== 'undefined' && document.activeElement === el
      ? (el.selectionEnd ?? currentText.length)
      : Math.min(selectionRef.current.end, currentText.length)
    const { value: nextText, cursor: nextCursor } = insertTextAtSelection(currentText, start, end, snippet)
    valueRef.current = nextText
    selectionRef.current = { start: nextCursor, end: nextCursor }
    pendingCursorRef.current = nextCursor
    onChangeRef.current(nextText)
  }, [textareaRef])

  const handleUploadFiles = useCallback(async (files: readonly File[]) => {
    if (disabledRef.current || files.length === 0) return
    if (uploadingRef.current) {
      pushShellToast('이미지 업로드가 진행 중입니다. 완료 후 다시 시도하세요.', 'info')
      return
    }
    const startEpoch = currentSessionEpoch()
    const startDraftKey = draftKeyRef.current
    const ctrl = new AbortController()
    uploadAbortRef.current = ctrl
    uploadingRef.current = true
    setUploadError(null)

    let uploadedCount = 0
    try {
      for (let i = 0; i < files.length; i += 1) {
        if (
          ctrl.signal.aborted
          || !mountedRef.current
          || !isEpochCurrent(startEpoch)
          || draftKeyRef.current !== startDraftKey
        ) {
          break
        }
        setUploadProgress({ current: i + 1, total: files.length })
        const file = files[i]!
        const res = await uploadWorkspaceMedia(file, { signal: ctrl.signal })
        if (
          ctrl.signal.aborted
          || !mountedRef.current
          || !isEpochCurrent(startEpoch)
          || draftKeyRef.current !== startDraftKey
        ) {
          break
        }
        if (res.ok) {
          const prefix = uploadedCount > 0 ? '\n' : ''
          const markdown = `${prefix}${formatUploadedImageMarkdown(res.value, deriveImageAltText(file.name))}`
          insertSnippet(markdown)
          uploadedCount += 1
        } else {
          if (res.error.kind === 'aborted' || res.error.kind === 'epoch_stale') break
          setUploadError(res.error.message)
          pushShellToast(res.error.message, 'error')
        }
      }
    } finally {
      if (uploadAbortRef.current === ctrl) {
        uploadAbortRef.current = null
        uploadingRef.current = false
        if (mountedRef.current) {
          setUploadProgress(null)
        }
      }
      if (
        uploadedCount > 0
        && mountedRef.current
        && !ctrl.signal.aborted
        && isEpochCurrent(startEpoch)
        && draftKeyRef.current === startDraftKey
      ) {
        pushShellToast(
          uploadedCount === 1
            ? '이미지를 업로드해 본문에 삽입했습니다.'
            : `이미지 ${uploadedCount}개를 업로드해 본문에 삽입했습니다.`,
          'success',
        )
      }
    }
  }, [insertSnippet])

  const handlePaste = useCallback((event: ClipboardEvent) => {
    if (disabledRef.current) return
    const files = extractUploadFilesFromDataTransfer(event.clipboardData, { imagesOnly: true })
    if (files.length === 0) return
    event.preventDefault()
    void handleUploadFiles(files)
  }, [handleUploadFiles])

  const handleDragEnter = useCallback((event: DragEvent) => {
    if (disabledRef.current || !dataTransferHasFiles(event.dataTransfer)) return
    event.preventDefault()
    dragDepthRef.current += 1
    setDragActive(true)
  }, [])

  const handleDragOver = useCallback((event: DragEvent) => {
    if (disabledRef.current || !dataTransferHasFiles(event.dataTransfer)) return
    event.preventDefault()
    if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy'
    setDragActive(true)
  }, [])

  const handleDragLeave = useCallback(() => {
    if (dragDepthRef.current > 0) {
      dragDepthRef.current -= 1
      if (dragDepthRef.current === 0) setDragActive(false)
    }
  }, [])

  const handleDrop = useCallback((event: DragEvent) => {
    dragDepthRef.current = 0
    setDragActive(false)
    if (disabledRef.current) return
    const files = extractUploadFilesFromDataTransfer(event.dataTransfer, { imagesOnly: false })
    if (files.length === 0) return
    event.preventDefault()
    void handleUploadFiles(files)
  }, [handleUploadFiles])

  const handleFileInputChange = useCallback((event: Event) => {
    const input = event.target as HTMLInputElement
    const picked = input.files ? Array.from(input.files) : []
    input.value = ''
    if (picked.length > 0) void handleUploadFiles(picked)
  }, [handleUploadFiles])

  const openFilePicker = useCallback(() => {
    if (disabledRef.current || uploadingRef.current) return
    fileInputRef.current?.click()
  }, [])

  const cancelUpload = useCallback(() => {
    uploadAbortRef.current?.abort()
  }, [])

  return {
    textareaRef,
    fileInputRef,
    dragActive,
    uploadProgress,
    uploading: uploadProgress !== null,
    uploadError,
    syncSelection,
    insertSnippet,
    handleUploadFiles,
    handlePaste,
    handleDragEnter,
    handleDragOver,
    handleDragLeave,
    handleDrop,
    handleFileInputChange,
    openFilePicker,
    cancelUpload,
    reset,
  }
}
