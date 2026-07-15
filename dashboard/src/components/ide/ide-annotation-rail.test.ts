import { afterEach, describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { IdeAnnotationRail } from './ide-annotation-rail'
import { ideContextFocus } from './ide-state'

afterEach(() => {
  ideContextFocus.value = null
})

describe('IdeAnnotationRail', () => {
  it('renders an empty state when the current file has no annotations', () => {
    const container = document.createElement('div')
    render(h(IdeAnnotationRail, { annotations: [] }), container)

    expect(container.querySelector('[data-testid="ide-annotation-rail"]')?.textContent)
      .toContain('no annotations for this file')
  })

  it('opens a file-addressable annotation context from its card', () => {
    const container = document.createElement('div')
    render(h(IdeAnnotationRail, {
      annotations: [{
        id: 'ann-1',
        file_path: 'lib/scheduler/round.ml',
        line_start: 94,
        line_end: 94,
        keeper_id: 'sangsu',
        kind: 'Decision',
        content: 'Move compact outside the round lock.',

        task_id: 'task-1',
        references: [
          { relation: 'evidence', reference: 'urn:review:7741' },
          { relation: 'source', reference: 'opaque-main' },
        ],
        created_at_ms: 1,
        updated_at_ms: 2,
      }],
    }), container)

    expect(container.textContent).toContain('Move compact outside the round lock.')
    expect(container.textContent).toContain('evidence: urn:review:7741')
    expect(container.textContent).toContain('source: opaque-main')
    expect(container.textContent).toContain('CTX 4')
    expect(container.querySelectorAll('[data-testid="ide-annotation-reference"]')).toHaveLength(2)

    fireEvent.click(container.querySelector<HTMLButtonElement>('.ide-annotation-rail-card-main')!)
    expect(ideContextFocus.value).toMatchObject({
      file_path: 'lib/scheduler/round.ml',
      line: 94,
      surface: 'Decision',
      keeper_id: 'sangsu',
    })
  })
})
