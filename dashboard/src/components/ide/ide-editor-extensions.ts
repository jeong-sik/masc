import { EditorView, GutterMarker, gutter } from '@codemirror/view'
import { Annotation, EditorState, Extension, StateField, StateEffect } from '@codemirror/state'
import type { LineOwnership } from './keeper-line-ownership-store'

// ── Read-only lock ────────────────────────────────────────────────
// Prevents all user input. CM6 6.x uses EditorState.changeFilter.

export const internalDocumentSync = Annotation.define<boolean>()

export function readOnlyExt(): Extension {
  return EditorState.changeFilter.of(transaction =>
    transaction.annotation(internalDocumentSync) === true,
  )
}

// ── Theme from design-system CSS variables ────────────────────────
// Maps semantic tokens to CM6 theme facets so the editor matches the
// dashboard light/dark theme without a hardcoded theme object.

export function themeExt(): Extension {
  return EditorView.theme({
    '&': {
      background: 'var(--color-bg-page)',
      color: 'var(--color-fg-secondary)',
      fontFamily: 'var(--font-mono)',
      fontSize: 'var(--fs-13)',
      lineHeight: '1.6',
    },
    '.cm-content': {
      caretColor: 'transparent',
      padding: 'var(--sp-2) 0',
    },
    '.cm-line': {
      padding: '0 var(--sp-3)',
    },
    '.cm-gutters': {
      background: 'var(--color-bg-page)',
      color: 'var(--color-fg-disabled)',
      border: 'none',
      fontSize: 'var(--fs-11)',
      minWidth: '40px',
    },
    '.cm-gutterElement': {
      textAlign: 'right',
      paddingRight: 'var(--sp-2)',
    },
    '&.cm-focused': {
      outline: 'none',
    },
    '.cm-cursor': {
      display: 'none',
    },
    '.cm-selectionBackground': {
      background: 'transparent !important',
    },
  })
}

// ── Blame gutter ──────────────────────────────────────────────────
// Left gutter showing keeper ownership per line. Uses a StateEffect
// to push ownership updates into the gutter marker.

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
    const color = `var(--color-keeper-${this.info.hueIndex}-glow, var(--k-${this.info.hueIndex}))`
    el.textContent = this.info.keeperId
    el.title = `${this.info.keeperId} · ${this.info.editKind}`
    el.style.color = color
    el.style.fontSize = 'var(--fs-11)'
    el.style.maxWidth = '80px'
    el.style.overflow = 'hidden'
    el.style.textOverflow = 'ellipsis'
    el.style.whiteSpace = 'nowrap'
    return el
  }

  eq(other: BlameMarker): boolean {
    if (!this.info && !other.info) return true
    if (!this.info || !other.info) return false
    return this.info.keeperId === other.info.keeperId && this.info.editKind === other.info.editKind
  }
}

const BLAME_EMPTY = new BlameMarker(null)

const setOwnership = StateEffect.define<ReadonlyMap<number, LineOwnership>>()

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
      lineMarker(view, block) {
        const line = view.state.doc.lineAt(block.from)
        const field = view.state.field(blameMarkerField, false)
        return field?.[line.number - 1] ?? BLAME_EMPTY
      },
      initialSpacer: () => BLAME_EMPTY,
    }),
  ]
}

export function pushOwnership(view: EditorView, ownership: ReadonlyMap<number, LineOwnership>): void {
  view.dispatch({ effects: [setOwnership.of(ownership)] })
}

export function keeperLineSelectExt(
  getOwnership: () => ReadonlyMap<number, LineOwnership>,
  onKeeperLineSelect: (keeperId: string, line: number) => void,
): Extension {
  return EditorView.domEventHandlers({
    click(event, view) {
      if (!(event instanceof MouseEvent) || event.button !== 0) return false
      const pos = view.posAtCoords({ x: event.clientX, y: event.clientY })
      if (pos === null) return false
      const line = view.state.doc.lineAt(pos)
      const owner = getOwnership().get(line.number)
      if (!owner) return false
      onKeeperLineSelect(owner.keeper_id, line.number)
      return false
    },
  })
}

// ── Language support (dynamic import) ─────────────────────────────

type LanguageModule = () => Promise<{ extension: Extension }>

const LANGUAGE_MAP: Readonly<Record<string, LanguageModule>> = {
  '.ts': () => import('@codemirror/lang-javascript').then(m => m.javascript({ typescript: true })),
  '.tsx': () => import('@codemirror/lang-javascript').then(m => m.javascript({ typescript: true, jsx: true })),
  '.js': () => import('@codemirror/lang-javascript').then(m => m.javascript()),
  '.jsx': () => import('@codemirror/lang-javascript').then(m => m.javascript({ jsx: true })),
  '.py': () => import('@codemirror/lang-python').then(m => m.python()),
  '.html': () => import('@codemirror/lang-html').then(m => m.html()),
  '.css': () => import('@codemirror/lang-css').then(m => m.css()),
  '.json': () => import('@codemirror/lang-json').then(m => m.json()),
  '.md': () => import('@codemirror/lang-markdown').then(m => m.markdown()),
  '.ocaml': () => import('@codemirror/lang-javascript').then(m => m.javascript()),
  '.ml': () => import('@codemirror/lang-javascript').then(m => m.javascript()),
  '.mli': () => import('@codemirror/lang-javascript').then(m => m.javascript()),
  '.toml': () => import('@codemirror/lang-json').then(m => m.json()),
  '.yaml': () => import('@codemirror/lang-json').then(m => m.json()),
  '.yml': () => import('@codemirror/lang-json').then(m => m.json()),
}

export async function languageExt(filePath: string): Promise<Extension> {
  const ext = filePath.slice(filePath.lastIndexOf('.'))
  const loader = LANGUAGE_MAP[ext]
  if (!loader) return []
  try {
    return await loader()
  } catch {
    return []
  }
}

// ── Line number gutter ────────────────────────────────────────────

export function lineNumberExt(): Extension {
  return []
}

// ── Blame mode extensions bundle ──────────────────────────────────

export function blameExtensions(): Extension[] {
  return [blameGutterExt()]
}

export { setOwnership }
