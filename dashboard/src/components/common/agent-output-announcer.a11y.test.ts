// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { AgentOutputAnnouncer, announceAgentOutput } from './agent-output-announcer'

describe('AgentOutputAnnouncer a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    vi.useFakeTimers({ shouldAdvanceTime: true })
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
    vi.useRealTimers()
  })

  it('renders accessibly', async () => {
    render(
      html`<${AgentOutputAnnouncer}
          outputs=${[]}
        />
      `,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has aria-live region', () => {
    render(
      html`<${AgentOutputAnnouncer}
          outputs=${[]}
          priority=${'polite'}
        />
      `,
      container,
    )
    const region = container.querySelector('[aria-live="polite"]')
    expect(region).not.toBeNull()
    expect(region?.getAttribute('aria-atomic')).toBe('false')
    expect(region?.getAttribute('aria-label')).toBe('에이전트 출력 알림')
  })

  it('uses assertive when priority is assertive', () => {
    render(
      html`<${AgentOutputAnnouncer}
          outputs=${[]}
          priority=${'assertive'}
        />
      `,
      container,
    )
    const region = container.querySelector('[aria-live="assertive"]')
    expect(region).not.toBeNull()
    expect(region?.getAttribute('aria-atomic')).toBe('true')
  })

  it('announces text output', () => {
    const result = announceAgentOutput({
      id: '1',
      type: 'text',
      content: 'Hello world',
    })
    expect(result).toBe('텍스트 출력: Hello world')
  })

  it('summarizes long text output', () => {
    const long = 'a'.repeat(300)
    const result = announceAgentOutput({
      id: '2',
      type: 'text',
      content: long,
    })
    expect(result).toContain('텍스트 출력, 300자:')
    expect(result).toContain('...')
  })

  it('announces code output with metadata', () => {
    const result = announceAgentOutput({
      id: '3',
      type: 'code',
      content: 'const x = 1',
      metadata: { language: 'typescript', lineCount: 3 },
    })
    expect(result).toBe('코드 출력, typescript 언어, 3 줄')
  })

  it('announces code output with defaults', () => {
    const result = announceAgentOutput({
      id: '4',
      type: 'code',
      content: 'print(1)',
    })
    expect(result).toBe('코드 출력, 알 수 없는 언어, 여러 줄')
  })

  it('announces table output', () => {
    const result = announceAgentOutput({
      id: '5',
      type: 'table',
      content: 'a,b\n1,2\n3,4',
    })
    expect(result).toBe('테이블 데이터, 3 행')
  })

  it('announces error output', () => {
    const result = announceAgentOutput({
      id: '6',
      type: 'error',
      content: 'Connection refused',
    })
    expect(result).toBe('오류 발생: Connection refused')
  })

  it('truncates long error output', () => {
    const longError = 'e'.repeat(200)
    const result = announceAgentOutput({
      id: '7',
      type: 'error',
      content: longError,
    })
    expect(result).toBe(`오류 발생: ${longError.slice(0, 100)}`)
  })

  it('updates live region when new output arrives', async () => {
    const outputs = [{ id: '1', type: 'text' as const, content: 'First' }]
    const { rerender } = renderInAct(
      html`<${AgentOutputAnnouncer} outputs=${outputs} />`,
      container,
    )
    await act(async () => {
      await new Promise((r) => setTimeout(r, 0))
    })
    const region = container.querySelector('[aria-live]') as HTMLDivElement
    expect(region?.textContent).toBe('텍스트 출력: First')

    const next = [
      ...outputs,
      { id: '2', type: 'error' as const, content: 'Failed' },
    ]
    rerender(html`<${AgentOutputAnnouncer} outputs=${next} />`)
    await act(async () => {
      await new Promise((r) => setTimeout(r, 0))
    })
    expect(region?.textContent).toBe('오류 발생: Failed')
  })
})

function renderInAct(vnode: any, container: HTMLElement) {
  const rerender = (newVNode: any) => {
    act(() => render(newVNode, container))
  }
  act(() => render(vnode, container))
  return { rerender }
}
