// Human selection state of the read-only CM6 editor. The editor's
// updateListener publishes the current main selection as 1-based line
// numbers; the interject surface reads it to say which lines the operator
// is talking about. Kept in its own module so readers do not import the
// (heavy) editor module.

import { signal } from '@preact/signals'

export interface IdeEditorSelection {
  readonly filePath: string
  readonly lineStart: number
  readonly lineEnd: number
}

export const ideEditorSelection = signal<IdeEditorSelection | null>(null)
