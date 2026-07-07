import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { IdeAnnotationComposer } from './ide-annotation-composer'
import { ideEditorSelection } from './ide-editor-selection'

vi.mock('../../api/ide', async importOriginal => {
  const original = await importOriginal<typeof import('../../api/ide')>()
  return {
    ...original,
    createIdeAnnotation: vi.fn(),
  }
})

vi.mock('../common/toast', async importOriginal => {
  const original = await importOriginal<typeof import('../common/toast')>()
  return {
    ...original,
    showToast: vi.fn(),
  }
})

import { createIdeAnnotation } from '../../api/ide'

const createIdeAnnotationMock = vi.mocked(createIdeAnnotation)

function documentStoreFixture(filePath: string | null) {
  return {
    document: () => ({ file_path: filePath }),
    subscribe: () => () => {},
  }
}

function composer({
  filePath = 'lib/foo.ml',
  repoId = 'masc',
  refresh = () => {},
}: {
  filePath?: string | null
  repoId?: string | null
  refresh?: () => void
} = {}) {
  return html`
    <${IdeAnnotationComposer}
      documentStore=${documentStoreFixture(filePath)}
      activeRepositoryId=${() => repoId}
      subscribeActiveRepositoryId=${() => () => {}}
      refresh=${refresh}
    />
  `
}

describe('IdeAnnotationComposer', () => {
  let host: HTMLDivElement | null = null

  beforeEach(() => {
    createIdeAnnotationMock.mockReset()
    ideEditorSelection.value = null
  })

  afterEach(() => {
    if (host) {
      render(null, host)
      host.remove()
      host = null
    }
  })

  function mount(node: ReturnType<typeof html>): HTMLDivElement {
    host = document.createElement('div')
    document.body.appendChild(host)
    render(node, host)
    return host
  }

  function tick(): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, 0))
  }

  async function open(el: HTMLElement): Promise<void> {
    const button = el.querySelector<HTMLButtonElement>('[data-testid="ide-annotation-open"]')
    expect(button).not.toBeNull()
    button?.click()
    await tick()
  }

  it('renders nothing without an active file', () => {
    const el = mount(composer({ filePath: null }))
    expect(el.querySelector('[data-testid="ide-annotation-composer-closed"]')).toBeNull()
    expect(el.querySelector('[data-testid="ide-annotation-composer-open"]')).toBeNull()
  })

  it('disables the entry button without a repo scope (keeper_lane is read-only)', () => {
    const el = mount(composer({ repoId: null }))
    const button = el.querySelector<HTMLButtonElement>('[data-testid="ide-annotation-open"]')
    expect(button?.disabled).toBe(true)
    expect(button?.title ?? '').toContain('repo 선택')
  })

  it('opens the form with the editor selection as the default line range', async () => {
    ideEditorSelection.value = { filePath: 'lib/foo.ml', lineStart: 12, lineEnd: 34 }
    const el = mount(composer())
    await open(el)
    const start = el.querySelector<HTMLInputElement>('[data-testid="ide-annotation-line-start"]')
    const end = el.querySelector<HTMLInputElement>('[data-testid="ide-annotation-line-end"]')
    expect(start?.value).toBe('12')
    expect(end?.value).toBe('34')
  })

  it('ignores a selection recorded for a different file', async () => {
    ideEditorSelection.value = { filePath: 'lib/other.ml', lineStart: 12, lineEnd: 34 }
    const el = mount(composer())
    await open(el)
    const start = el.querySelector<HTMLInputElement>('[data-testid="ide-annotation-line-start"]')
    expect(start?.value).toBe('1')
  })

  it('keeps submit disabled while the draft is invalid', async () => {
    const el = mount(composer())
    await open(el)
    const submit = el.querySelector<HTMLButtonElement>('[data-testid="ide-annotation-submit"]')
    expect(submit?.disabled).toBe(true)
    expect(el.textContent ?? '').toContain('내용을 입력하세요')
  })

  it.each(['1.9', '1e3', '12abc', '-3', ''])(
    'rejects non-integer line input %j instead of silently truncating it',
    async raw => {
      const el = mount(composer())
      await open(el)

      const content = el.querySelector<HTMLTextAreaElement>('[data-testid="ide-annotation-content"]')
      if (content) {
        content.value = '유효한 내용'
        content.dispatchEvent(new Event('input', { bubbles: true }))
      }
      const start = el.querySelector<HTMLInputElement>('[data-testid="ide-annotation-line-start"]')
      expect(start).not.toBeNull()
      if (start) {
        start.value = raw
        start.dispatchEvent(new Event('input', { bubbles: true }))
      }
      await tick()

      const submit = el.querySelector<HTMLButtonElement>('[data-testid="ide-annotation-submit"]')
      expect(submit?.disabled).toBe(true)
      expect(el.textContent ?? '').toContain('line_start는 1 이상의 정수')
    },
  )

  it('submits the draft with the repo scope and refreshes on success', async () => {
    createIdeAnnotationMock.mockResolvedValue({
      id: 'a-1',
      file_path: 'lib/foo.ml',
      line_start: 12,
      line_end: 34,
    } as Awaited<ReturnType<typeof createIdeAnnotation>>)
    const refresh = vi.fn()
    ideEditorSelection.value = { filePath: 'lib/foo.ml', lineStart: 12, lineEnd: 34 }
    const el = mount(composer({ refresh }))
    await open(el)

    const content = el.querySelector<HTMLTextAreaElement>('[data-testid="ide-annotation-content"]')
    expect(content).not.toBeNull()
    if (content) {
      content.value = '경계 조건 확인 필요'
      content.dispatchEvent(new Event('input', { bubbles: true }))
    }
    await tick()

    const submit = el.querySelector<HTMLButtonElement>('[data-testid="ide-annotation-submit"]')
    expect(submit?.disabled).toBe(false)
    submit?.click()
    await tick()
    await tick()

    expect(createIdeAnnotationMock).toHaveBeenCalledTimes(1)
    expect(createIdeAnnotationMock).toHaveBeenCalledWith(
      {
        file_path: 'lib/foo.ml',
        line_start: 12,
        line_end: 34,
        kind: 'Comment',
        content: '경계 조건 확인 필요',
      },
      { repoId: 'masc' },
    )
    expect(refresh).toHaveBeenCalledTimes(1)
    expect(el.querySelector('[data-testid="ide-annotation-composer-open"]')).toBeNull()
  })
})
