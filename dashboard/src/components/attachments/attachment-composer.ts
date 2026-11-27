/**
 * Shared Upload-First `<AttachmentComposer>` used by both Keeper Chat and Board.
 *
 * - File picker (`accept="image/*,application/pdf,audio/*"`), clipboard paste (`onPaste`),
 *   and drag-and-drop (`onDrop` with visual drag-over highlight).
 * - Immediate upload to `POST /api/v1/attachments` with upload progress, retry on error,
 *   and thumbnail preview chip tray (`<img>` + dimensions + filename + size + remove `×`).
 */

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'
import { useCallback, useEffect, useRef, useState } from 'preact/hooks'
import {
  uploadAttachment,
  type AttachmentKind,
  type AttachmentRef,
} from '../../api/attachments'
import { randomUuid } from '../../lib/uuid'
import {
  ATTACHMENT_INPUT_ACCEPT,
  DEFAULT_MAX_ATTACHMENT_BYTES,
  MAX_COMPOSER_ATTACHMENTS,
  classifyAttachmentKind,
  createLocalPreviewUrl,
  extractTransferFiles,
  formatAttachmentBytes,
  readImageDimensions,
  resolveAttachmentMimeType,
  revokeLocalPreviewUrl,
  validateAttachmentFile,
} from './validation'

export interface ComposerAttachmentItem {
  readonly localId: string
  readonly file: File
  readonly filename: string
  readonly mimeType: string
  readonly kind: AttachmentKind
  readonly bytes: number
  readonly width: number | null
  readonly height: number | null
  readonly previewUrl: string | null
  readonly status: 'uploading' | 'ready' | 'error'
  readonly progress: number
  readonly error: string | null
  readonly ref: AttachmentRef | null
}

export function readyAttachmentsOf(items: readonly ComposerAttachmentItem[]): readonly AttachmentRef[] {
  const out: AttachmentRef[] = []
  for (const item of items) {
    if (item.status === 'ready' && item.ref) out.push(item.ref)
  }
  return out
}

export function hasUploadingAttachments(items: readonly ComposerAttachmentItem[]): boolean {
  return items.some((item) => item.status === 'uploading')
}

export function hasFailedAttachments(items: readonly ComposerAttachmentItem[]): boolean {
  return items.some((item) => item.status === 'error')
}

export function revokeComposerPreviews(items: readonly ComposerAttachmentItem[]): void {
  for (const item of items) {
    revokeLocalPreviewUrl(item.previewUrl)
  }
}

export interface AttachmentComposerProps {
  readonly items: readonly ComposerAttachmentItem[]
  readonly onChange: (updater: (prev: readonly ComposerAttachmentItem[]) => readonly ComposerAttachmentItem[]) => void
  readonly disabled?: boolean
  readonly maxItems?: number
  readonly maxBytes?: number
  readonly accept?: string
  readonly showTrigger?: boolean
  readonly triggerLabel?: string
  readonly pickerRef?: { current: (() => void) | null }
  readonly className?: string
  readonly onError?: (message: string) => void
  readonly uploadImpl?: typeof uploadAttachment
  readonly children?: ComponentChildren
}

export function AttachmentComposer({
  items,
  onChange,
  disabled = false,
  maxItems = MAX_COMPOSER_ATTACHMENTS,
  maxBytes = DEFAULT_MAX_ATTACHMENT_BYTES,
  accept = ATTACHMENT_INPUT_ACCEPT,
  showTrigger = true,
  triggerLabel = '첨부',
  pickerRef,
  className,
  onError,
  uploadImpl = uploadAttachment,
  children,
}: AttachmentComposerProps) {
  const fileInputRef = useRef<HTMLInputElement>(null)
  const dragDepthRef = useRef(0)
  const [dragOver, setDragOver] = useState(false)
  const mountedRef = useRef(true)
  const itemsRef = useRef(items)
  itemsRef.current = items
  const onChangeRef = useRef(onChange)
  onChangeRef.current = onChange
  const controllersRef = useRef<Map<string, AbortController>>(new Map())

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
      const abortedIds = new Set(controllersRef.current.keys())
      for (const ctrl of controllersRef.current.values()) {
        ctrl.abort('unmounted')
      }
      controllersRef.current.clear()
      if (abortedIds.size > 0) {
        onChangeRef.current((prev) =>
          prev.map((cur) =>
            abortedIds.has(cur.localId) && cur.status === 'uploading'
              ? { ...cur, status: 'error', progress: 0, error: '업로드가 중단되었습니다. 다시 시도하거나 제거하세요.' }
              : cur,
          ),
        )
      }
    }
  }, [])

  const openPicker = useCallback(() => {
    if (disabled) return
    fileInputRef.current?.click()
  }, [disabled])

  useEffect(() => {
    if (!pickerRef) return
    pickerRef.current = openPicker
    return () => {
      if (pickerRef.current === openPicker) pickerRef.current = null
    }
  }, [pickerRef, openPicker])

  const startUpload = useCallback((item: ComposerAttachmentItem) => {
    controllersRef.current.get(item.localId)?.abort('retry')
    const ctrl = new AbortController()
    controllersRef.current.set(item.localId, ctrl)

    void uploadImpl(item.file, {
      filename: item.filename,
      mimeType: item.mimeType,
      signal: ctrl.signal,
      onProgress: (pct) => {
        if (!mountedRef.current || ctrl.signal.aborted) return
        onChange((prev) =>
          prev.map((cur) => (cur.localId === item.localId ? { ...cur, progress: pct } : cur)),
        )
      },
    }).then((res) => {
      if (controllersRef.current.get(item.localId) === ctrl) {
        controllersRef.current.delete(item.localId)
      }
      if (!mountedRef.current || ctrl.signal.aborted) return
      if (!res.ok) {
        onChange((prev) =>
          prev.map((cur) =>
            cur.localId === item.localId
              ? { ...cur, status: 'error', progress: 0, error: res.error.message, ref: null }
              : cur,
          ),
        )
        onError?.(`${item.filename} 업로드 실패: ${res.error.message}`)
        return
      }
      const ref = res.value
      onChange((prev) =>
        prev.map((cur) =>
          cur.localId === item.localId
            ? {
                ...cur,
                status: 'ready',
                progress: 100,
                error: null,
                ref,
                width: ref.width ?? cur.width,
                height: ref.height ?? cur.height,
                bytes: ref.bytes > 0 ? ref.bytes : cur.bytes,
              }
            : cur,
        ),
      )
    })
  }, [onChange, onError, uploadImpl])

  const enqueueFiles = useCallback((rawFiles: readonly File[]) => {
    if (disabled || rawFiles.length === 0) return
    const remaining = Math.max(0, maxItems - itemsRef.current.length)
    if (remaining === 0) {
      onError?.(`첨부 파일은 최대 ${maxItems}개까지 추가할 수 있습니다.`)
      return
    }
    const accepted: ComposerAttachmentItem[] = []
    const errors: string[] = []
    const slice = rawFiles.slice(0, remaining)
    if (rawFiles.length > remaining) {
      errors.push(`최대 ${maxItems}개까지만 첨부할 수 있어 일부 파일이 제외되었습니다.`)
    }
    for (const file of slice) {
      const validationError = validateAttachmentFile(file, maxBytes)
      if (validationError) {
        errors.push(validationError)
        continue
      }
      const mimeType = resolveAttachmentMimeType(file)
      const kind = classifyAttachmentKind(mimeType)
      const localId = `draft-${randomUuid()}`
      const filename = file.name || `clipboard-${localId.slice(-6)}.${mimeType.split('/')[1] ?? 'bin'}`
      const previewUrl = createLocalPreviewUrl(file, mimeType)
      const draft: ComposerAttachmentItem = {
        localId,
        file,
        filename,
        mimeType,
        kind,
        bytes: file.size,
        width: null,
        height: null,
        previewUrl,
        status: 'uploading',
        progress: 5,
        error: null,
        ref: null,
      }
      accepted.push(draft)
    }

    if (errors.length > 0) {
      onError?.(errors.join(' · '))
    }
    if (accepted.length === 0) return

    onChange((prev) => [...prev, ...accepted])

    for (const item of accepted) {
      if (item.kind === 'image') {
        void readImageDimensions(item.file).then((dims) => {
          if (!mountedRef.current || !dims) return
          onChange((prev) =>
            prev.map((cur) =>
              cur.localId === item.localId
                ? { ...cur, width: cur.width ?? dims.width, height: cur.height ?? dims.height }
                : cur,
            ),
          )
        })
      }
      startUpload(item)
    }
  }, [disabled, maxBytes, maxItems, onChange, onError, startUpload])

  const handleRemove = useCallback((localId: string) => {
    controllersRef.current.get(localId)?.abort('removed')
    controllersRef.current.delete(localId)
    onChange((prev) => {
      const target = prev.find((x) => x.localId === localId)
      if (target) revokeLocalPreviewUrl(target.previewUrl)
      return prev.filter((x) => x.localId !== localId)
    })
  }, [onChange])

  const handleRetry = useCallback((item: ComposerAttachmentItem) => {
    if (disabled) return
    onChange((prev) =>
      prev.map((cur) =>
        cur.localId === item.localId
          ? { ...cur, status: 'uploading', progress: 5, error: null }
          : cur,
      ),
    )
    startUpload(item)
  }, [disabled, onChange, startUpload])

  const handleFileInputChange = (e: Event) => {
    const input = e.currentTarget as HTMLInputElement
    const files = input.files ? Array.from(input.files) : []
    input.value = ''
    enqueueFiles(files)
  }

  const handlePaste = (e: ClipboardEvent) => {
    if (disabled) return
    const files = extractTransferFiles(e.clipboardData)
    if (files.length === 0) return
    // Only prevent default when clipboard carries files/images (preserve text paste).
    e.preventDefault()
    enqueueFiles(files)
  }

  const handleDragEnter = (e: DragEvent) => {
    if (disabled) return
    const types = Array.from(e.dataTransfer?.types ?? [])
    if (types.length > 0 && !types.includes('Files')) return
    e.preventDefault()
    dragDepthRef.current += 1
    setDragOver(true)
  }

  const handleDragOver = (e: DragEvent) => {
    if (disabled) return
    e.preventDefault()
    if (e.dataTransfer) e.dataTransfer.dropEffect = 'copy'
    if (!dragOver) setDragOver(true)
  }

  const handleDragLeave = (e: DragEvent) => {
    e.preventDefault()
    dragDepthRef.current = Math.max(0, dragDepthRef.current - 1)
    if (dragDepthRef.current === 0) setDragOver(false)
  }

  const handleDrop = (e: DragEvent) => {
    e.preventDefault()
    dragDepthRef.current = 0
    setDragOver(false)
    if (disabled) return
    const files = extractTransferFiles(e.dataTransfer)
    enqueueFiles(files)
  }

  const wrapperClass = ['att-composer-zone', className].filter(Boolean).join(' ')

  return html`
    <div
      class=${wrapperClass}
      data-testid="attachment-composer"
      data-drag-over=${dragOver ? 'true' : 'false'}
      onPaste=${handlePaste}
      onDragEnter=${handleDragEnter}
      onDragOver=${handleDragOver}
      onDragLeave=${handleDragLeave}
      onDrop=${handleDrop}
    >
      ${dragOver && html`
        <div class="att-drop-overlay" role="status" data-testid="attachment-drop-overlay">
          여기에 이미지 · PDF · 오디오 파일을 놓아 첨부하세요
        </div>
      `}

      ${items.length > 0 && html`
        <div class="att-chip-tray" role="list" aria-label="첨부 파일 목록" data-testid="attachment-chip-tray">
          ${items.map((item) => {
            const dims = item.width && item.height ? `${item.width}×${item.height}` : null
            const size = formatAttachmentBytes(item.bytes)
            const metaLine = [dims, size].filter(Boolean).join(' · ')
            return html`
              <div
                key=${item.localId}
                role="listitem"
                class="att-chip"
                data-status=${item.status}
                data-kind=${item.kind}
                data-testid="attachment-chip"
              >
                ${item.kind === 'image' && item.previewUrl
                  ? html`<img class="att-chip-thumb" src=${item.previewUrl} alt=${item.filename} />`
                  : html`<span class="att-chip-icon mono" aria-hidden="true">${item.kind === 'audio' ? 'AUDIO' : item.mimeType === 'application/pdf' ? 'PDF' : 'FILE'}</span>`}
                <div class="att-chip-body">
                  <div class="att-chip-name" title=${item.filename}>${item.filename}</div>
                  <div class="att-chip-meta mono">
                    ${item.status === 'uploading'
                      ? `업로드 중… ${item.progress}%`
                      : item.status === 'error'
                        ? (item.error ?? '업로드 실패')
                        : metaLine || item.mimeType}
                  </div>
                </div>
                ${item.status === 'error' && html`
                  <button
                    type="button"
                    class="btn-ghost btn-compact"
                    aria-label=${`${item.filename} 재시도`}
                    onClick=${() => handleRetry(item)}
                  >
                    재시도
                  </button>
                `}
                <button
                  type="button"
                  class="att-chip-remove"
                  aria-label=${`${item.filename} 첨부 제거`}
                  onClick=${() => handleRemove(item.localId)}
                >
                  ×
                </button>
              </div>
            `
          })}
        </div>
      `}

      ${hasFailedAttachments(items) && html`
        <div class="ap-error" role="alert" data-testid="attachment-error-blocker">
          업로드에 실패한 첨부 파일을 재시도하거나 제거한 뒤 전송하세요.
        </div>
      `}

      ${children}

      <input
        ref=${fileInputRef}
        type="file"
        multiple
        accept=${accept}
        class="kp-hidden-input"
        aria-label="첨부 파일 선택"
        data-testid="attachment-file-input"
        disabled=${disabled}
        onChange=${handleFileInputChange}
      />

      ${showTrigger && html`
        <div class="att-composer-bar">
          <button
            type="button"
            class="btn-ghost btn-compact"
            disabled=${disabled || items.length >= maxItems}
            onClick=${openPicker}
          >
            📎 ${triggerLabel}
          </button>
          <span class="att-composer-hint">이미지 붙여넣기(⌘V) · 드래그 앤 드롭 지원</span>
        </div>
      `}
    </div>
  `
}
