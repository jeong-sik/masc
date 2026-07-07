// IDE annotation composer (#23471 FE-4). The write half of the annotation
// plane: the read half (line chips, popover, Context Lens) has been wired
// since Phase 1, but `createIdeAnnotation` had zero UI callers — a human
// could not leave a comment/decision from the IDE at all.
//
// Contract notes (server-enforced, mirrored here instead of re-invented):
// - Mutations require a repo scope; `keeper_lane` is read-only
//   (`keeper_lane_read_only`), so the composer submits with the explorer's
//   active repository and disables itself when none is selected.
// - Identity comes from the auth token; the composer never sends a
//   keeper_id.
// - After a successful create the workspace fetches re-run, so the new
//   record surfaces through the exact read path keeper annotations use.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type { VNode } from 'preact'
import { createIdeAnnotation } from '../../api/ide'
import type { AnnotationKind } from '../../api/schemas/ide-annotations'
import { showToast } from '../common/toast'
import { useSignalValue, useStoreSubscription } from './use-signal-value'
import { ideEditorSelection } from './ide-editor-selection'

const ANNOTATION_KINDS: readonly AnnotationKind[] = [
  'Comment',
  'Decision',
  'Question',
  'Bookmark',
]

interface ComposerDraft {
  readonly kind: AnnotationKind
  readonly lineStart: string
  readonly lineEnd: string
  readonly content: string
}

function draftFromSelection(filePath: string): ComposerDraft {
  const selection = ideEditorSelection.value
  const matches = selection !== null && selection.filePath === filePath
  const lineStart = matches ? selection.lineStart : 1
  const lineEnd = matches ? selection.lineEnd : lineStart
  return {
    kind: 'Comment',
    lineStart: String(lineStart),
    lineEnd: String(lineEnd),
    content: '',
  }
}

function parseLine(raw: string): number | null {
  const value = Number.parseInt(raw, 10)
  if (!Number.isInteger(value) || value < 1) return null
  return value
}

function draftProblem(draft: ComposerDraft): string | null {
  const lineStart = parseLine(draft.lineStart)
  const lineEnd = parseLine(draft.lineEnd)
  if (lineStart === null) return 'line_start는 1 이상의 정수여야 합니다'
  if (lineEnd === null) return 'line_end는 1 이상의 정수여야 합니다'
  if (lineEnd < lineStart) return 'line_end는 line_start 이상이어야 합니다'
  if (draft.content.trim() === '') return '내용을 입력하세요'
  return null
}

export function IdeAnnotationComposer({
  documentStore,
  activeRepositoryId,
  subscribeActiveRepositoryId,
  refresh,
}: {
  documentStore: {
    document: () => { readonly file_path: string | null }
    subscribe: (listener: () => void) => () => void
  }
  activeRepositoryId: () => string | null
  subscribeActiveRepositoryId: (listener: () => void) => () => void
  refresh: () => void
}): VNode | null {
  useStoreSubscription(documentStore.subscribe)
  useStoreSubscription(subscribeActiveRepositoryId)
  useSignalValue(ideEditorSelection)

  const [draft, setDraft] = useState<ComposerDraft | null>(null)
  const [submitting, setSubmitting] = useState(false)

  const filePath = documentStore.document().file_path
  if (filePath === null) return null
  const repoId = activeRepositoryId()

  if (draft === null) {
    return html`
      <div class="ide-annotation-composer" data-testid="ide-annotation-composer-closed">
        <button
          type="button"
          class="v2-ide-action"
          data-testid="ide-annotation-open"
          disabled=${repoId === null}
          title=${repoId === null
            ? '주석 생성에는 repo 선택이 필요합니다 (keeper_lane scope는 read-only)'
            : '현재 선택 라인에 주석을 남깁니다'}
          onClick=${() => setDraft(draftFromSelection(filePath))}
        >
          주석 추가
        </button>
      </div>
    `
  }

  const problem = draftProblem(draft)
  const update = (patch: Partial<ComposerDraft>) =>
    setDraft(current => (current === null ? current : { ...current, ...patch }))

  const submit = async () => {
    if (problem !== null || repoId === null || submitting) return
    const lineStart = parseLine(draft.lineStart)
    const lineEnd = parseLine(draft.lineEnd)
    if (lineStart === null || lineEnd === null) return
    setSubmitting(true)
    try {
      const created = await createIdeAnnotation(
        {
          file_path: filePath,
          line_start: lineStart,
          line_end: lineEnd,
          kind: draft.kind,
          content: draft.content.trim(),
        },
        { repoId },
      )
      if (created === null) {
        showToast('주석 응답 파싱 실패 — 서버 응답을 확인하세요', 'error')
      } else {
        showToast(`주석 저장됨: ${created.file_path}:${created.line_start}`, 'success')
        setDraft(null)
        refresh()
      }
    } catch (error) {
      showToast(`주석 저장 실패: ${error instanceof Error ? error.message : String(error)}`, 'error')
    } finally {
      setSubmitting(false)
    }
  }

  return html`
    <div class="ide-annotation-composer" data-testid="ide-annotation-composer-open">
      <div class="flex flex-wrap items-center gap-1.5 text-2xs">
        <span class="font-mono text-[var(--color-fg-muted)]" title=${filePath}>${filePath}</span>
        <select
          aria-label="주석 종류"
          data-testid="ide-annotation-kind"
          value=${draft.kind}
          onChange=${(event: Event) =>
            update({ kind: (event.currentTarget as HTMLSelectElement).value as AnnotationKind })}
        >
          ${ANNOTATION_KINDS.map(kind => html`<option key=${kind} value=${kind}>${kind}</option>`)}
        </select>
        <label class="flex items-center gap-1">
          L
          <input
            type="number"
            min="1"
            aria-label="시작 라인"
            data-testid="ide-annotation-line-start"
            style=${{ width: '5.5em' }}
            value=${draft.lineStart}
            onInput=${(event: Event) =>
              update({ lineStart: (event.currentTarget as HTMLInputElement).value })}
          />
        </label>
        <label class="flex items-center gap-1">
          –
          <input
            type="number"
            min="1"
            aria-label="끝 라인"
            data-testid="ide-annotation-line-end"
            style=${{ width: '5.5em' }}
            value=${draft.lineEnd}
            onInput=${(event: Event) =>
              update({ lineEnd: (event.currentTarget as HTMLInputElement).value })}
          />
        </label>
      </div>
      <textarea
        aria-label="주석 내용"
        data-testid="ide-annotation-content"
        rows="3"
        placeholder="코멘트 / 결정 / 질문 내용"
        value=${draft.content}
        onInput=${(event: Event) =>
          update({ content: (event.currentTarget as HTMLTextAreaElement).value })}
      ></textarea>
      <div class="flex items-center gap-1.5">
        <button
          type="button"
          class="v2-ide-action"
          data-testid="ide-annotation-submit"
          disabled=${problem !== null || submitting || repoId === null}
          title=${problem ?? ''}
          onClick=${() => void submit()}
        >
          ${submitting ? '저장 중…' : '저장'}
        </button>
        <button
          type="button"
          class="v2-ide-action"
          data-testid="ide-annotation-cancel"
          onClick=${() => setDraft(null)}
        >
          취소
        </button>
        ${problem !== null
          ? html`<span class="text-2xs text-[var(--color-status-warn)]">${problem}</span>`
          : null}
      </div>
    </div>
  `
}
