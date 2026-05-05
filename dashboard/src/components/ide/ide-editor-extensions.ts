import { EditorView, GutterMarker, gutter, lineNumbers, type ViewUpdate } from '@codemirror/view'
import { Annotation, EditorState, Extension, StateField, StateEffect } from '@codemirror/state'
import { defaultHighlightStyle, syntaxHighlighting } from '@codemirror/language'
import type { LineOwnership } from './keeper-line-ownership-store'
import { kSigil } from '../keeper-badge'

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
      height: '100%',
    },
    '.cm-scroller': {
      overflow: 'auto',
      minHeight: '0',
    },
    '.cm-content': {
      caretColor: 'transparent',
      padding: 'var(--sp-2) 0',
      minHeight: '100%',
    },
    '.cm-line': {
      padding: '0 var(--sp-3)',
    },
    '.cm-gutters': {
      background: 'var(--color-bg-page)',
      color: 'var(--color-fg-disabled)',
      border: 'none',
      fontSize: 'var(--fs-11)',
      minWidth: '44px',
      position: 'sticky',
      left: '0',
      zIndex: '2',
    },
    '.cm-gutterElement': {
      textAlign: 'right',
      paddingRight: 'var(--sp-2)',
    },
    '.cm-lineNumbers': {
      borderRight: '1px solid var(--color-border-default)',
    },
    '.cm-blame-gutter': {
      minWidth: '78px',
      borderRight: '1px solid var(--color-border-default)',
      background: 'var(--color-bg-surface)',
    },
    '.cm-blame-gutter .cm-gutterElement': {
      padding: '0 var(--sp-2)',
      textAlign: 'left',
    },
    '.cm-blame-marker': {
      display: 'inline-grid',
      gridTemplateColumns: '18px minmax(0, 1fr)',
      alignItems: 'center',
      gap: 'var(--sp-1)',
      width: '68px',
      minWidth: '0',
      color: 'var(--cm-blame-color)',
      fontSize: 'var(--fs-10)',
      lineHeight: '1.4',
    },
    '.cm-blame-sigil': {
      display: 'inline-flex',
      alignItems: 'center',
      justifyContent: 'center',
      width: '16px',
      height: '14px',
      borderRadius: 'var(--r-0)',
      color: 'var(--color-bg-page)',
      background: 'var(--cm-blame-color)',
      fontSize: 'var(--fs-9)',
      fontWeight: '700',
      letterSpacing: '0',
    },
    '.cm-blame-name': {
      overflow: 'hidden',
      textOverflow: 'ellipsis',
      whiteSpace: 'nowrap',
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

export function syntaxHighlightExt(): Extension {
  return syntaxHighlighting(defaultHighlightStyle, { fallback: true })
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
  return lineNumbers()
}

// ── Blame mode extensions bundle ──────────────────────────────────

export function blameExtensions(): Extension[] {
  return [blameGutterExt()]
}

export { setOwnership }
