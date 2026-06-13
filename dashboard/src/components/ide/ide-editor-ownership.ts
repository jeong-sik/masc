import { GutterMarker, gutter, type ViewUpdate } from '@codemirror/view'
import { StateField, StateEffect, Extension } from '@codemirror/state'
import type { LineOwnership } from './keeper-line-ownership-store'
import { kSigil } from '../keeper-badge'

interface BlameMarkerValue {
  readonly keeperId: string
  readonly hueIndex: number
  readonly editKind: string
}

class BlameMarker extends GutterMarker {
  constructor(private readonly info: BlameMarkerValue | null) {
    super()
  }

  toDOM(): HTMLElement {
    const el = document.createElement('span')
    if (!this.info) {
      el.textContent = '—'
      el.style.color = 'var(--color-fg-disabled)'
      el.style.fontSize = 'var(--fs-11)'
      return el
    }
    const slot = Math.min(12, Math.max(1, this.info.hueIndex || 1))
    const color = `var(--color-keeper-${slot}, var(--k-${slot}))`
    el.className = 'cm-blame-marker'
    el.style.setProperty('--cm-blame-color', color)
    el.title = `${this.info.keeperId} · ${this.info.editKind}`
    const sigil = document.createElement('span')
    sigil.className = 'cm-blame-sigil'
    sigil.textContent = kSigil(this.info.keeperId)
    sigil.setAttribute('aria-hidden', 'true')
    const name = document.createElement('span')
    name.className = 'cm-blame-name'
    name.textContent = this.info.keeperId
    el.append(sigil, name)
    return el
  }

  eq(other: BlameMarker): boolean {
    if (!this.info && !other.info) return true
    if (!this.info || !other.info) return false
    return this.info.keeperId === other.info.keeperId && this.info.editKind === other.info.editKind
  }
}

const BLAME_EMPTY = new BlameMarker(null)

export const setOwnership = StateEffect.define<ReadonlyMap<number, LineOwnership>>()

const blameMarkerField = StateField.define<BlameMarker[]>({
  create() {
    return []
  },
  update(markers, tr) {
    for (const effect of tr.effects) {
      if (effect.is(setOwnership)) {
        const ownership = effect.value
        const newMarkers: BlameMarker[] = []
        const doc = tr.state.doc
        for (let i = 1; i <= doc.lines; i++) {
          const owner = ownership.get(i)
          if (owner) {
            newMarkers.push(new BlameMarker({
              keeperId: owner.keeper_id,
              hueIndex: owner.hue_index,
              editKind: owner.last_edit_kind,
            }))
          } else {
            newMarkers.push(BLAME_EMPTY)
          }
        }
        return newMarkers
      }
    }
    return markers
  },
})

function blameGutterExt(): Extension {
  return [
    blameMarkerField,
    gutter({
      class: 'cm-blame-gutter',
      lineMarkerChange(update: ViewUpdate) {
        return update.startState.field(blameMarkerField, false) !== update.state.field(blameMarkerField, false)
      },
      lineMarker(view, block) {
        const line = view.state.doc.lineAt(block.from)
        const field = view.state.field(blameMarkerField, false)
        return field?.[line.number - 1] ?? BLAME_EMPTY
      },
      initialSpacer: () => BLAME_EMPTY,
    }),
  ]
}

export function pushOwnership(view: import('@codemirror/view').EditorView, ownership: ReadonlyMap<number, LineOwnership>): void {
  view.dispatch({ effects: [setOwnership.of(ownership)] })
}

export function blameExtensions(): Extension[] {
  return [blameGutterExt()]
}
