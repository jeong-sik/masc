import { html } from 'htm/preact'
import { useCallback, useEffect, useRef, useState } from 'preact/hooks'
import { authSession, currentSessionEpoch, isEpochCurrent } from '../../core/auth'
import {
  WORKSPACE_MEDIA_ACCEPT,
  dataTransferHasFiles,
  deriveImageAltText,
  extractUploadFilesFromDataTransfer,
  formatUploadedImageMarkdown,
  insertTextAtSelection,
  isUploadBlockedBySession,
  uploadWorkspaceMedia,
  type MediaUploadError,
} from '../../lib/workspace-media-upload'
import { pushShellToast } from '../../shell/shell-state'
import { TextArea } from './input'
import { RichContent } from './rich-content'

type ComposerMode = 'write' | 'preview'

export function RichComposer({
  value,
  onValueChange,
  placeholder,
  rows = 6,
  disabled,
  helpText,
  previewLimit = 2,
  ariaLabel,
  enableMediaUpload = true,
  onUploadError,
}: {
  value: string
  onValueChange: (next: string) => void
  placeholder?: string
  rows?: number
  disabled?: boolean
  helpText?: string
  previewLimit?: number
  /** Accessible name for the underlying TextArea. Required for AT —
      without it the editor reads as an unlabeled form control. */
  ariaLabel?: string
  /** Enables clipboard paste, drag-and-drop, and toolbar file upload via POST /api/v1/media. */
  enableMediaUpload?: boolean
  onUploadError?: (error: MediaUploadError) => void
}) {
  const [mode, setMode] = useState<ComposerMode>('write')
  const [dragActive, setDragActive] = useState(false)
  const [uploadProgress, setUploadProgress] = useState<{ readonly current: number; readonly total: number } | null>(null)
  const [uploadError, setUploadError] = useState<string | null>(null)

  const textareaRef = useRef<HTMLTextAreaElement | null>(null)
  const fileInputRef = useRef<HTMLInputElement | null>(null)
  const uploadAbortRef = useRef<AbortController | null>(null)
  const mountedRef = useRef(true)
  const dragDepthRef = useRef(0)
  const selectionRef = useRef<{ start: number; end: number }>({ start: value.length, end: value.length })
  const pendingCursorRef = useRef<number | null>(null)
  const latestValueRef = useRef(value)
  latestValueRef.current = value
  const onValueChangeRef = useRef(onValueChange)
  onValueChangeRef.current = onValueChange
  const onUploadErrorRef = useRef(onUploadError)
  onUploadErrorRef.current = onUploadError

  const session = authSession.value
  const uploadBlocked = isUploadBlockedBySession(session)
  const canUpload = enableMediaUpload && !disabled && !uploadBlocked
  const uploading = uploadProgress !== null

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
      uploadAbortRef.current?.abort()
    }
  }, [])

  useEffect(() => {
    const pos = pendingCursorRef.current
    if (pos === null) return
    pendingCursorRef.current = null
    const target = textareaRef.current
    if (target && mountedRef.current) {
      target.focus()
      target.setSelectionRange(pos, pos)
    }
  }, [value])

  const syncSelection = useCallback(() => {
    const el = textareaRef.current
    if (!el) return
    selectionRef.current = {
      start: el.selectionStart ?? latestValueRef.current.length,
      end: el.selectionEnd ?? latestValueRef.current.length,
    }
  }, [])

  const handleUploadFiles = useCallback(async (files: readonly File[]) => {
    if (!enableMediaUpload || disabled || files.length === 0) return
    if (isUploadBlockedBySession(authSession.peek())) {
      const msg = '이미지 업로드 권한이 없습니다. 관리자 권한이 필요합니다.'
      setUploadError(msg)
      pushShellToast(msg, 'error')
      return
    }
    if (uploadAbortRef.current !== null) {
      pushShellToast('이미지 업로드가 진행 중입니다. 완료 후 다시 시도하세요.', 'info')
      return
    }

    const startEpoch = currentSessionEpoch()
    const ctrl = new AbortController()
    uploadAbortRef.current = ctrl
    setUploadError(null)
    let uploadedCount = 0

    try {
      for (let i = 0; i < files.length; i += 1) {
        const file = files[i]!
        if (!mountedRef.current || ctrl.signal.aborted || !isEpochCurrent(startEpoch)) break
        setUploadProgress({ current: i + 1, total: files.length })

        const res = await uploadWorkspaceMedia(file, { signal: ctrl.signal })
        if (!mountedRef.current || ctrl.signal.aborted || !isEpochCurrent(startEpoch)) break

        if (res.ok) {
          const el = textareaRef.current
          const currentText = latestValueRef.current
          const start = el && typeof document !== 'undefined' && document.activeElement === el
            ? (el.selectionStart ?? currentText.length)
            : Math.min(selectionRef.current.start, currentText.length)
          const end = el && typeof document !== 'undefined' && document.activeElement === el
            ? (el.selectionEnd ?? start)
            : Math.min(selectionRef.current.end, currentText.length)
          const prefix = uploadedCount > 0 ? '\n' : ''
          const snippet = `${prefix}${formatUploadedImageMarkdown(res.value, deriveImageAltText(file.name))}`
          const inserted = insertTextAtSelection(currentText, start, end, snippet)
          latestValueRef.current = inserted.value
          selectionRef.current = { start: inserted.cursor, end: inserted.cursor }
          pendingCursorRef.current = inserted.cursor
          onValueChangeRef.current(inserted.value)
          uploadedCount += 1
        } else {
          if (res.error.kind === 'aborted' || res.error.kind === 'epoch_stale') break
          setUploadError(res.error.message)
          pushShellToast(res.error.message, 'error')
          onUploadErrorRef.current?.(res.error)
        }
      }
    } finally {
      if (uploadAbortRef.current === ctrl) {
        uploadAbortRef.current = null
      }
      if (mountedRef.current) {
        setUploadProgress(null)
      }
      if (uploadedCount > 0 && mountedRef.current && !ctrl.signal.aborted && isEpochCurrent(startEpoch)) {
        pushShellToast(
          uploadedCount === 1
            ? '이미지를 업로드해 본문에 삽입했습니다.'
            : `이미지 ${uploadedCount}개를 업로드해 본문에 삽입했습니다.`,
          'success',
        )
      }
    }
  }, [disabled, enableMediaUpload])

  const onPaste = (event: ClipboardEvent) => {
    if (!enableMediaUpload || disabled) return
    const files = extractUploadFilesFromDataTransfer(event.clipboardData, { imagesOnly: true })
    if (files.length === 0) return
    event.preventDefault()
    void handleUploadFiles(files)
  }

  const onDragEnter = (event: DragEvent) => {
    if (!enableMediaUpload || disabled || !dataTransferHasFiles(event.dataTransfer)) return
    event.preventDefault()
    dragDepthRef.current += 1
    setDragActive(true)
  }

  const onDragOver = (event: DragEvent) => {
    if (!enableMediaUpload || disabled || !dataTransferHasFiles(event.dataTransfer)) return
    event.preventDefault()
    if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy'
    if (!dragActive) setDragActive(true)
  }

  const onDragLeave = () => {
    if (dragDepthRef.current > 0) {
      dragDepthRef.current -= 1
      if (dragDepthRef.current === 0) setDragActive(false)
    }
  }

  const onDrop = (event: DragEvent) => {
    dragDepthRef.current = 0
    setDragActive(false)
    if (!enableMediaUpload || disabled) return
    const files = extractUploadFilesFromDataTransfer(event.dataTransfer, { imagesOnly: false })
    if (files.length === 0) return
    event.preventDefault()
    void handleUploadFiles(files)
  }

  return html`
    <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
      <div class="flex flex-wrap items-center justify-between gap-2 border-b border-[var(--color-border-default)] px-3 py-2">
        <div class="flex items-center gap-1.5">
          ${(['write', 'preview'] as ComposerMode[]).map(tab => html`
            <button
              key=${tab}
              type="button"
              class=${`rich-composer-tab rounded-[var(--r-1)] border px-2.5 py-1 text-2xs font-medium transition-colors ${
                mode === tab
                  ? 'border-[var(--info-border)] bg-[var(--accent-12)] text-[var(--color-accent-fg)]'
                  : 'border-transparent bg-transparent text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)]'
              }`}
              onClick=${() => setMode(tab)}
              disabled=${disabled}
            >
              ${tab === 'write' ? 'Write' : 'Preview'}
            </button>
          `)}
        </div>
        <div class="flex items-center gap-2">
          ${enableMediaUpload && html`
            <input
              ref=${fileInputRef}
              type="file"
              accept=${WORKSPACE_MEDIA_ACCEPT}
              multiple
              class="hidden"
              tabIndex=${-1}
              aria-hidden="true"
              data-testid="rich-composer-file-input"
              onChange=${(event: Event) => {
                const input = event.target as HTMLInputElement
                const picked = input.files ? Array.from(input.files) : []
                input.value = ''
                if (picked.length > 0) void handleUploadFiles(picked)
              }}
            />
            <button
              type="button"
              class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-transparent px-2 py-1 text-2xs font-medium text-[var(--color-fg-secondary)] transition-colors hover:bg-[var(--color-bg-hover)] hover:text-[var(--color-fg-primary)] disabled:opacity-45"
              data-testid="rich-composer-upload-btn"
              disabled=${!canUpload || uploading}
              title=${uploadBlocked ? '관리자 권한이 필요합니다.' : '이미지 업로드 (PNG, JPEG, GIF, WebP)'}
              onClick=${() => fileInputRef.current?.click()}
            >
              ${uploading ? '업로드 중…' : '이미지 첨부'}
            </button>
          `}
          <div class="text-3xs text-[var(--color-fg-muted)]">
            ${enableMediaUpload ? 'Markdown · 이미지 붙여넣기/드롭 지원' : 'Markdown, code fence, URL, image link'}
          </div>
        </div>
      </div>

      <div class="p-3">
        ${uploadProgress && html`
          <div class="mb-2 flex items-center justify-between gap-2 rounded-[var(--r-1)] border border-[var(--info-border)] bg-[var(--info-soft)] px-2.5 py-1.5 text-2xs text-[var(--info-fg)]" role="status" aria-live="polite">
            <span>이미지 업로드 중… (${uploadProgress.current}/${uploadProgress.total})</span>
            <button
              type="button"
              class="rounded-[var(--r-1)] border border-transparent px-1.5 py-0.5 text-2xs font-medium underline"
              disabled=${disabled}
              onClick=${() => uploadAbortRef.current?.abort()}
            >
              업로드 취소
            </button>
          </div>
        `}
        ${uploadError && html`
          <div class="mb-2 rounded-[var(--r-1)] border border-[var(--err-border)] bg-[var(--err-soft)] px-2.5 py-1.5 text-2xs text-[var(--err-fg)]" role="alert">
            ${uploadError}
          </div>
        `}
        ${mode === 'write'
          ? html`
              <div
                class=${`relative rounded-[var(--r-1)] ${dragActive ? 'ring-2 ring-[var(--info-border)]' : ''}`}
                data-testid="rich-composer-dropzone"
                data-drag-active=${dragActive ? 'true' : 'false'}
                onpaste=${onPaste}
                ondragenter=${onDragEnter}
                ondragover=${onDragOver}
                ondragleave=${onDragLeave}
                ondrop=${onDrop}
                onKeyUp=${syncSelection}
                onClick=${syncSelection}
              >
                <${TextArea}
                  inputRef=${textareaRef}
                  value=${value}
                  placeholder=${placeholder}
                  rows=${rows}
                  disabled=${disabled}
                  ariaLabel=${ariaLabel}
                  class="min-h-35"
                  onInput=${(event: Event) => {
                    const target = event.target as HTMLTextAreaElement
                    selectionRef.current = {
                      start: target.selectionStart ?? target.value.length,
                      end: target.selectionEnd ?? target.value.length,
                    }
                    onValueChange(target.value)
                  }}
                />
                ${dragActive && html`
                  <div
                    class="pointer-events-none absolute inset-0 z-10 flex items-center justify-center rounded-[var(--r-1)] border-2 border-dashed border-[var(--info-border)] bg-[var(--color-bg-surface)]/90 px-4 text-center text-xs font-semibold text-[var(--color-accent-fg)]"
                    data-testid="rich-composer-drop-overlay"
                  >
                    이미지를 놓아 업로드 (PNG, JPEG, GIF, WebP)
                  </div>
                `}
              </div>
            `
          : value.trim()
            ? html`
                <div class="max-h-80 overflow-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-page)] p-3 custom-scrollbar">
                  <${RichContent} text=${value} previewLimit=${previewLimit} />
                </div>
              `
            : html`
                <div class="rounded-[var(--r-1)] border border-dashed border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-6 text-center text-xs text-[var(--color-fg-muted)]">
                  미리볼 내용이 아직 없습니다.
                </div>
              `}
        ${helpText
          ? html`<div class="mt-2 text-2xs leading-relaxed text-[var(--color-fg-muted)]">${helpText}</div>`
          : null}
      </div>
    </div>
  `
}
