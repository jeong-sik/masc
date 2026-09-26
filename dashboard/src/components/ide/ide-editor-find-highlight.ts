import { StateEffect, StateField, type Extension } from '@codemirror/state'
import { Decoration, EditorView, type DecorationSet } from '@codemirror/view'

/**
 * The current find match, drawn as a mark. The IDE theme hides the native
 * selection background (the editor is read-only and shows no cursor), so a
 * match that was only selected was invisible.
 */
export const setFindMatch = StateEffect.define<{ readonly from: number; readonly to: number } | null>()

const findMatchMark = Decoration.mark({ class: 'cm-masc-find-match' })

const findMatchField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(marks, transaction) {
    let next = marks.map(transaction.changes)
    for (const effect of transaction.effects) {
      if (!effect.is(setFindMatch)) continue
      next = effect.value === null || effect.value.from === effect.value.to
        ? Decoration.none
        : Decoration.set([findMatchMark.range(effect.value.from, effect.value.to)])
    }
    return next
  },
  provide: field => EditorView.decorations.from(field),
})

const findMatchTheme = EditorView.theme({
  '.cm-masc-find-match': {
    background: 'color-mix(in srgb, var(--color-accent-fg) 35%, transparent)',
    outline: '1px solid var(--color-accent-fg)',
    borderRadius: '2px',
  },
})

export function findMatchExt(): Extension {
  return [findMatchField, findMatchTheme]
}
