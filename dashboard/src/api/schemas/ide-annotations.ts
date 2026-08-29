import { isRecord } from '../../components/common/normalize'

export type AnnotationKind = 'Comment' | 'Decision' | 'Question' | 'Bookmark'

export interface IdeAnnotationReference {
  readonly relation: string
  readonly reference: string
}

export interface IdeAnnotation {
  readonly id: string
  readonly file_path: string
  readonly line_start: number
  readonly line_end: number
  readonly keeper_id: string
  readonly kind: AnnotationKind
  readonly content: string
  readonly goal_id: string | null
  readonly task_id: string | null
  readonly references: ReadonlyArray<IdeAnnotationReference>
  readonly created_at_ms: number
  readonly updated_at_ms: number
}

const ANNOTATION_REFERENCE_FIELDS = new Set(['relation', 'reference'])
const ANNOTATION_FIELDS = new Set([
  'id',
  'file_path',
  'line_start',
  'line_end',
  'keeper_id',
  'kind',
  'content',
  'goal_id',
  'task_id',
  'references',
  'created_at_ms',
  'updated_at_ms',
])

function annotationKind(value: unknown): AnnotationKind | null {
  return value === 'Comment'
    || value === 'Decision'
    || value === 'Question'
    || value === 'Bookmark'
    ? value
    : null
}

function nullableString(value: unknown): string | null | undefined {
  return value === null || typeof value === 'string' ? value : undefined
}

function positiveSafeInteger(value: unknown): number | null {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0
    ? value
    : null
}

function finiteNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function parseIdeAnnotationReference(value: unknown): IdeAnnotationReference | null {
  if (!isRecord(value)) return null
  if (Object.keys(value).some(key => !ANNOTATION_REFERENCE_FIELDS.has(key))) return null
  if (typeof value.relation !== 'string' || value.relation.trim() === '') return null
  if (typeof value.reference !== 'string' || value.reference.trim() === '') return null
  return { relation: value.relation, reference: value.reference }
}

export function parseIdeAnnotationReferences(
  value: unknown,
): ReadonlyArray<IdeAnnotationReference> | null {
  if (!Array.isArray(value)) return null
  const references = value.map(parseIdeAnnotationReference)
  return references.some(reference => reference === null)
    ? null
    : references as ReadonlyArray<IdeAnnotationReference>
}

export function parseIdeAnnotation(value: unknown): IdeAnnotation | null {
  if (!isRecord(value)) return null
  if (Object.keys(value).some(key => !ANNOTATION_FIELDS.has(key))) return null
  const id = typeof value.id === 'string' && value.id.trim() !== '' ? value.id : null
  const filePath = typeof value.file_path === 'string' && value.file_path.trim() !== ''
    ? value.file_path
    : null
  const lineStart = positiveSafeInteger(value.line_start)
  const lineEnd = positiveSafeInteger(value.line_end)
  const keeperId = typeof value.keeper_id === 'string' && value.keeper_id.trim() !== ''
    ? value.keeper_id
    : null
  const kind = annotationKind(value.kind)
  const content = typeof value.content === 'string' ? value.content : null
  const goalId = nullableString(value.goal_id)
  const taskId = nullableString(value.task_id)
  const references = parseIdeAnnotationReferences(value.references)
  const createdAtMs = finiteNumber(value.created_at_ms)
  const updatedAtMs = finiteNumber(value.updated_at_ms)
  if (
    id === null
    || filePath === null
    || lineStart === null
    || lineEnd === null
    || lineEnd < lineStart
    || keeperId === null
    || kind === null
    || content === null
    || goalId === undefined
    || taskId === undefined
    || references === null
    || createdAtMs === null
    || updatedAtMs === null
  ) {
    return null
  }
  return {
    id,
    file_path: filePath,
    line_start: lineStart,
    line_end: lineEnd,
    keeper_id: keeperId,
    kind,
    content,
    goal_id: goalId,
    task_id: taskId,
    references,
    created_at_ms: createdAtMs,
    updated_at_ms: updatedAtMs,
  }
}

export function parseIdeAnnotations(value: unknown): ReadonlyArray<IdeAnnotation> | null {
  if (!Array.isArray(value)) return null
  const annotations = value.map(parseIdeAnnotation)
  return annotations.some(annotation => annotation === null)
    ? null
    : annotations as ReadonlyArray<IdeAnnotation>
}

