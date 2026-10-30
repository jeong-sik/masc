import type { IdeEditorView } from './ide-editor'

export function viewFromRoute(raw: string | null | undefined): IdeEditorView {
  const normalized = raw
    ?.trim()
    .toLowerCase()
    .replace(/[_\s]+/g, '-')
  if (normalized === 'split' || normalized === 'split-diff' || normalized === 'merge') return 'split-diff'
  if (normalized === 'unified') return 'unified'
  if (normalized === 'blame') return 'blame'
  return 'source'
}

export function isDiffEditorView(view: IdeEditorView): boolean {
  return view === 'split-diff' || view === 'unified'
}
