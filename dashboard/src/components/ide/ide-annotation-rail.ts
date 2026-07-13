import { html } from 'htm/preact'
import type { IdeAnnotation } from '../../api/schemas/ide-annotations'
import { KeeperBadge } from '../keeper-badge'
import { focusIdeContextAnchor } from './ide-state'
import { routeLinksForContext } from './ide-context-lens'

const EMPTY_ANNOTATIONS: ReadonlyArray<IdeAnnotation> = []

const KIND_LABEL: Readonly<Record<IdeAnnotation['kind'], string>> = {
  Comment: 'comment',
  Decision: 'decision',
  Question: 'question',
  Bookmark: 'bookmark',
}

/**
 * Compact, file-addressable annotation view for the IDE rail.  The reference
 * IDE uses a dedicated annotation tab; keeping it separate from the broader
 * keeper-work dashboard makes the editor's operational context scannable.
 */
export function IdeAnnotationRail({
  annotations = EMPTY_ANNOTATIONS,
}: {
  readonly annotations?: ReadonlyArray<IdeAnnotation>
}) {
  return html`
    <section
      class="ide-annotation-rail"
      data-testid="ide-annotation-rail"
      aria-label="IDE annotations"
    >
      ${annotations.length === 0
        ? html`<div class="ide-rail-empty">no annotations for this file</div>`
        : html`
          <ol class="ide-annotation-rail-list">
            ${annotations.map(annotation => html`<${AnnotationRailCard} annotation=${annotation} />`)}
          </ol>
        `}
    </section>
  `
}

function AnnotationRailCard({ annotation }: { readonly annotation: IdeAnnotation }) {
  const lineLabel = annotation.line_start === annotation.line_end
    ? `L${annotation.line_start}`
    : `L${annotation.line_start}-${annotation.line_end}`
  const routeLinks = routeLinksForContext({
    filePath: annotation.file_path,
    line: annotation.line_start,
    surface: annotation.kind,
    label: annotation.content,
    sourceId: `annotation:${annotation.id}`,
    goalId: annotation.goal_id ?? undefined,
    taskId: annotation.task_id ?? undefined,
    keeperId: annotation.keeper_id,
  })
  const focus = (): void => {
    focusIdeContextAnchor({
      file_path: annotation.file_path,
      line: annotation.line_start,
      surface: annotation.kind,
      label: annotation.content,
      source_id: `annotation:${annotation.id}`,
      keeper_id: annotation.keeper_id,
      route_links: routeLinks,
    }, 'operator')
  }

  return html`
    <li class="ide-annotation-rail-card">
      <button
        type="button"
        class="ide-annotation-rail-card-main"
        aria-label=${`Focus ${annotation.kind} annotation at ${annotation.file_path}:${annotation.line_start}`}
        title=${`${annotation.file_path}:${lineLabel}`}
        onClick=${focus}
      >
        <span class=${`ide-annotation-rail-kind is-${annotation.kind.toLowerCase()}`}>
          ${KIND_LABEL[annotation.kind]}
        </span>
        <span class="ide-annotation-rail-line">${lineLabel}</span>
        <span class="ide-annotation-rail-content">${annotation.content}</span>
      </button>
      <div class="ide-annotation-rail-meta">
        <${KeeperBadge} id=${annotation.keeper_id} variant="sigil" size="sm" />
        <span>${annotation.keeper_id}</span>
        <span class="ide-annotation-rail-path">${annotation.file_path}</span>
        ${annotation.references.map((reference, index) => html`
          <span
            key=${`${reference.relation}:${reference.reference}:${index}`}
            class="ide-annotation-rail-reference"
            data-testid="ide-annotation-reference"
          >${reference.relation}: ${reference.reference}</span>
        `)}
        ${routeLinks.length > 0 ? html`<span class="ide-annotation-rail-context">CTX ${routeLinks.length}</span>` : null}
      </div>
    </li>
  `
}
