// Human selection state of the read-only CM6 editor (#23471 FE-4).
// The editor's existing updateListener publishes the current main
// selection as 1-based line numbers; the annotation composer reads it to
// default the line range of a new annotation. Kept in its own module so
// the composer does not import the (heavy) editor module.

import { signal } from '@preact/signals'

export interface IdeEditorSelection {
  readonly filePath: string
  readonly lineStart: number
  readonly lineEnd: number
}

export const ideEditorSelection = signal<IdeEditorSelection | null>(null)
