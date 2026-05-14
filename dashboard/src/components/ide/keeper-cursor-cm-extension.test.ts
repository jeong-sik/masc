// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { EditorState, type Extension } from '@codemirror/state'
import { EditorView } from '@codemirror/view'
import { cursorOverlaySignal } from './keeper-cursor-overlay'
import { keeperCursorExtension } from './keeper-cursor-cm-extension'

function createTestView(extensions: Extension[], doc = 'one\ntwo\n') {
  const container = document.createElement('div')
  document.body.appendChild(container)
  const state = EditorState.create({ doc, extensions })
  const view = new EditorView({ state, parent: container })
  return { view, container }
}

describe('keeperCursorExtension', () => {
  beforeEach(() => {
    cursorOverlaySignal.value = {
      active_file: 'runtime.ts',
      cursors: new Map(),
      heatmap: new Map(),
      collisions: [],
    }
  })

  afterEach(() => {
    cursorOverlaySignal.value = {
      active_file: null,
      cursors: new Map(),
      heatmap: new Map(),
      collisions: [],
    }
    document.body.replaceChildren()
  })

  it('renders cursor labels with design-system keeper tokens', () => {
    cursorOverlaySignal.value = {
      active_file: 'runtime.ts',
      cursors: new Map([[
        'alpha',
        {
          keeper_id: 'alpha',
          file_path: 'runtime.ts',
          line: 1,
          column: 1,
          focus_mode: 'editing',
          last_update: Date.now(),
        },
      ]]),
      heatmap: new Map(),
      collisions: [],
    }

    const { view, container } = createTestView([keeperCursorExtension()])
    view.dispatch({ selection: { anchor: 1 } })

    const label = container.querySelector<HTMLElement>('.cm-keeper-cursor-label')
    expect(label?.getAttribute('style')).toContain('var(--color-keeper-')
    expect(label?.getAttribute('style')).toContain('var(--color-bg-page)')
    expect(label?.getAttribute('style')).not.toMatch(/#[0-9a-fA-F]{3,8}|rgba\(/)

    view.destroy()
    container.remove()
  })
})
