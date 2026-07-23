import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type { EditorView } from '@codemirror/view'
import type { IdeAnnotationDeleteOutcome } from '../../api/ide'
import type { SelectedAnnotation } from './ide-lsp-client'
import {
  openIdeContextRouteLink,
  routeLinksForContext,
  type IdeContextRouteLink,
} from './ide-context-lens'

const KIND_LABEL: Record<string, string> = {
  Comment: 'comment',
  Decision: 'decision',
  Question: 'question',
  Bookmark: 'bookmark',
}

const KIND_COLOR: Record<string, string> = {
  Comment: 'var(--color-accent-fg)',
  Decision: 'var(--color-success-fg)',
  Question: 'var(--color-fg-warning)',
  Bookmark: 'var(--color-fg-muted)',
}

export function EditorContextRouteLink(link: IdeContextRouteLink) {
  return html`
    <button
      key=${link.id}
      type="button"
      class="ide-editor-context-route-link v2-ide-action"
      title=${link.evidence}
      aria-label=${`Open ${link.evidence}`}
      onClick=${() => openIdeContextRouteLink(link)}
    >
      ${link.label}
    </button>
  `
}

export function EditorContextRouteCount({
  count,
  label,
}: {
  readonly count: number
  readonly label: string
}) {
  return html`
    <span
      class="ide-editor-context-route-count"
      title=${`${count} linked ${label} routes`}
      aria-label=${`${count} linked ${label} routes`}
    >
      CTX ${count}
    </span>
  `
}

// Two-click destructive control: the first click arms, the second runs.
// Deletability is not knowable up front — the dashboard has no whoami and
// the DELETE route decides ownership from the token identity — so the
// button is always offered and a 'forbidden' outcome (another identity's
// annotation, or a scope the token may not mutate) simply disarms; the
// delete handler owns the explanatory toast.
export function AnnotationDeleteControl({
  annotation,
  onDelete,
  onDeleted,
}: {
  readonly annotation: SelectedAnnotation
  readonly onDelete: (annotation: SelectedAnnotation) => Promise<IdeAnnotationDeleteOutcome>
  readonly onDeleted: () => void
}) {
  // Armed/pending state is keyed to the annotation id: switching the
  // popover to a different annotation reuses this component instance
  // (same vDOM slot), and a plain boolean would carry the armed click
  // over to the new target — one click would then delete an annotation
  // the user never armed.
  const [armedFor, setArmedFor] = useState<string | null>(null)
  const [pendingFor, setPendingFor] = useState<string | null>(null)
  const latestIdRef = useRef(annotation.id)
  latestIdRef.current = annotation.id

  // Disarm on target switch, not just mask: without this, arming ann-1,
  // browsing to ann-2 and coming back would leave ann-1 pre-armed.
  useEffect(() => {
    setArmedFor(current =>
      current !== null && current !== annotation.id ? null : current)
  }, [annotation.id])

  const armed = armedFor === annotation.id
  const pending = pendingFor === annotation.id

  const run = async () => {
    if (pendingFor !== null) return
    if (!armed) {
      setArmedFor(annotation.id)
      return
    }
    const target = annotation
    setPendingFor(target.id)
    let outcome: IdeAnnotationDeleteOutcome
    try {
      outcome = await onDelete(target)
    } catch {
      outcome = 'error'
    }
    if (outcome === 'deleted' && latestIdRef.current === target.id) {
      // The popover unmounts with the deleted annotation — skip state
      // updates that would land on an unmounted component.
      onDeleted()
      return
    }
    // Non-deleted outcome, or the popover moved to a different annotation
    // while the delete was in flight — closing now would dismiss a target
    // the user is looking at, so just settle the control.
    setPendingFor(null)
    setArmedFor(null)
  }

  return html`
    <button
      type="button"
      class="v2-ide-action"
      data-testid="ide-annotation-delete"
      disabled=${pendingFor !== null}
      title=${armed
        ? '한 번 더 누르면 삭제됩니다'
        : '주석 삭제 (본인이 작성한 주석만 서버가 허용)'}
      style=${{ color: armed ? 'var(--color-fg-warning)' : undefined, marginLeft: 'auto' }}
      onClick=${() => void run()}
    >
      ${pending ? '삭제 중…' : armed ? '삭제 확인' : '삭제'}
    </button>
  `
}

export function AnnotationPopover({
  annotation,
  view,
  onClose,
  onDelete,
}: {
  readonly annotation: SelectedAnnotation
  readonly view: EditorView
  readonly onClose: () => void
  readonly onDelete?: (annotation: SelectedAnnotation) => Promise<IdeAnnotationDeleteOutcome>
}) {
  const line = annotation.line_start
  const lineInfo = line >= 1 && line <= view.state.doc.lines
    ? view.state.doc.line(line)
    : null
  const coords = lineInfo
    ? view.coordsAtPos(lineInfo.from)
    : null

  if (!coords) return null

  const shellRect = view.dom.closest('.ide-codemirror-shell')?.getBoundingClientRect()
  if (!shellRect) return null

  const top = coords.bottom - shellRect.top + 4
  const left = Math.max(8, coords.left - shellRect.left)
  const routeLinks = annotationRouteLinks(annotation)

  return html`
    <div
      class="ide-annotation-popover v2-ide-panel"
      role="dialog"
      aria-label="Annotation detail"
      style=${{
        position: 'absolute',
        top: top + 'px',
        left: left + 'px',
        zIndex: 40,
        minWidth: '240px',
        maxWidth: '380px',
        background: 'var(--color-bg-elevated)',
        border: '1px solid var(--color-border-default)',
        borderRadius: 'var(--r-2)',
        boxShadow: 'var(--shadow-panel)',
        padding: 'var(--sp-3)',
        fontFamily: 'var(--font-sans)',
        fontSize: '13px',
        lineHeight: 1.5,
      }}
    >
      <div style=${{ display: 'flex', alignItems: 'center', gap: 'var(--sp-2)', marginBottom: 'var(--sp-2)' }}>
        <span style=${{
          padding: '1px 6px',
          borderRadius: 'var(--r-1)',
          fontSize: '11px',
          fontWeight: 600,
          textTransform: 'uppercase',
          color: KIND_COLOR[annotation.kind] ?? 'var(--color-fg-muted)',
          background: 'var(--color-bg-muted)',
        }}>${KIND_LABEL[annotation.kind] ?? annotation.kind}</span>
        <span style=${{ color: 'var(--color-fg-muted)', fontSize: '11px', flex: 1 }}>
          L${annotation.line_start}${annotation.line_start !== annotation.line_end ? `-${annotation.line_end}` : ''}
        </span>
        <button
          type="button"
          class="v2-ide-action"
          aria-label="Close annotation"
          onClick=${onClose}
          style=${{
            background: 'none',
            border: 'none',
            color: 'var(--color-fg-muted)',
            cursor: 'pointer',
            fontSize: '14px',
            lineHeight: 1,
            padding: '2px 4px',
          }}
        >&times;</button>
      </div>
      <div style=${{ color: 'var(--color-fg-primary)', whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>
        ${annotation.content}
      </div>
      <div
        class="ide-editor-annotation-references"
        aria-label="Annotation references"
        style=${{ marginTop: 'var(--sp-2)', display: 'flex', gap: 'var(--sp-1)', flexWrap: 'wrap' }}
      >
        ${annotation.references.map((reference, index) => html`
          <span
            key=${`${reference.relation}:${reference.reference}:${index}`}
            class="ide-editor-annotation-reference"
          >${reference.relation}: ${reference.reference}</span>
        `)}
      </div>
      ${routeLinks.length > 0 ? html`
        <div
          class="ide-editor-context-route-links"
          aria-label="Annotation operational links"
          style=${{ marginTop: 'var(--sp-2)' }}
        >
          <${EditorContextRouteCount} count=${routeLinks.length} label="annotation context" />
          ${routeLinks.map(link => EditorContextRouteLink(link))}
        </div>
      ` : null}
      <div style=${{ display: 'flex', gap: 'var(--sp-2)', marginTop: 'var(--sp-2)', flexWrap: 'wrap' }}>
        ${annotation.keeper_id ? html`
          <span style=${{ color: 'var(--color-fg-muted)', fontSize: '11px' }}>
            keeper: <strong>${annotation.keeper_id}</strong>
          </span>
        ` : null}
        ${annotation.goal_id ? html`
          <span style=${{ color: 'var(--color-fg-muted)', fontSize: '11px' }}>
            goal: ${annotation.goal_id}
          </span>
        ` : null}
        ${annotation.task_id ? html`
          <span style=${{ color: 'var(--color-fg-muted)', fontSize: '11px' }}>
            task: ${annotation.task_id}
          </span>
        ` : null}
        ${onDelete ? html`
          <${AnnotationDeleteControl}
            annotation=${annotation}
            onDelete=${onDelete}
            onDeleted=${onClose}
          />
        ` : null}
      </div>
    </div>
  `
}

export function annotationRouteLinks(annotation: SelectedAnnotation): ReadonlyArray<IdeContextRouteLink> {
  return routeLinksForContext({
    filePath: annotation.file_path,
    line: annotation.line_start,
    surface: annotation.kind,
    label: annotation.content,
    sourceId: `annotation-${annotation.id}`,
    goalId: annotation.goal_id ?? undefined,
    taskId: annotation.task_id ?? undefined,
    keeperId: annotation.keeper_id,
  })
}
