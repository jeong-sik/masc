import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { AnnotationDeleteControl } from './ide-editor-annotation-ui'
import type { SelectedAnnotation } from './ide-lsp-client'
import type { IdeAnnotationDeleteOutcome } from '../../api/ide'

const annotation: SelectedAnnotation = {
  id: 'ann-1',
  keeper_id: 'sangsu',
  kind: 'Comment',
  content: '경계 조건 확인 필요',
  goal_id: null,
  task_id: null,
  file_path: 'lib/foo.ml',
  line_start: 12,
  line_end: 34,
}

describe('AnnotationDeleteControl', () => {
  let host: HTMLDivElement | null = null
  const onDelete = vi.fn<(a: SelectedAnnotation) => Promise<IdeAnnotationDeleteOutcome>>()
  const onDeleted = vi.fn()

  beforeEach(() => {
    onDelete.mockReset()
    onDeleted.mockReset()
  })

  afterEach(() => {
    if (host) {
      render(null, host)
      host.remove()
      host = null
    }
  })

  function mount(target: SelectedAnnotation = annotation): HTMLDivElement {
    host = host ?? (() => {
      const created = document.createElement('div')
      document.body.appendChild(created)
      return created
    })()
    render(
      html`
        <${AnnotationDeleteControl}
          annotation=${target}
          onDelete=${onDelete}
          onDeleted=${onDeleted}
        />
      `,
      host,
    )
    return host
  }

  function tick(): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, 0))
  }

  function button(el: HTMLElement): HTMLButtonElement {
    const found = el.querySelector<HTMLButtonElement>('[data-testid="ide-annotation-delete"]')
    expect(found).not.toBeNull()
    return found!
  }

  it('arms on the first click without calling onDelete', async () => {
    const el = mount()
    expect(button(el).textContent?.trim()).toBe('삭제')

    button(el).click()
    await tick()

    expect(onDelete).not.toHaveBeenCalled()
    expect(button(el).textContent?.trim()).toBe('삭제 확인')
  })

  it('runs the delete on the second click and shows a pending state', async () => {
    let resolveDelete: (outcome: IdeAnnotationDeleteOutcome) => void = () => {}
    onDelete.mockReturnValue(new Promise(resolve => { resolveDelete = resolve }))
    const el = mount()

    button(el).click()
    await tick()
    button(el).click()
    await tick()

    expect(onDelete).toHaveBeenCalledTimes(1)
    expect(onDelete).toHaveBeenCalledWith(annotation)
    expect(button(el).textContent?.trim()).toBe('삭제 중…')
    expect(button(el).disabled).toBe(true)

    resolveDelete('deleted')
    await tick()
  })

  it('notifies onDeleted when the outcome is deleted', async () => {
    onDelete.mockResolvedValue('deleted')
    const el = mount()

    button(el).click()
    await tick()
    button(el).click()
    await tick()

    expect(onDeleted).toHaveBeenCalledTimes(1)
  })

  it('disarms without closing when the server rejects the deletion', async () => {
    onDelete.mockResolvedValue('forbidden')
    const el = mount()

    button(el).click()
    await tick()
    button(el).click()
    await tick()

    expect(onDeleted).not.toHaveBeenCalled()
    expect(button(el).textContent?.trim()).toBe('삭제')
    expect(button(el).disabled).toBe(false)
  })

  it('disarms when the popover switches to a different annotation', async () => {
    const el = mount()
    button(el).click()
    await tick()
    expect(button(el).textContent?.trim()).toBe('삭제 확인')

    mount({ ...annotation, id: 'ann-2' })
    await tick()

    expect(button(el).textContent?.trim()).toBe('삭제')
    button(el).click()
    await tick()
    expect(onDelete).not.toHaveBeenCalled()
  })

  it('treats a rejected onDelete as an error and stays usable', async () => {
    onDelete.mockRejectedValue(new Error('boom'))
    const el = mount()

    button(el).click()
    await tick()
    button(el).click()
    await tick()

    expect(onDeleted).not.toHaveBeenCalled()
    expect(button(el).textContent?.trim()).toBe('삭제')
    expect(button(el).disabled).toBe(false)
  })
})
