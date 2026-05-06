import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  AgentOutputAnnouncer,
  announceAgentOutput,
  resolveAgentOutputPriority,
  summarizeAgentOutput,
} from './agent-output-announcer'

describe('announceAgentOutput', () => {
  it('announces code output', () => {
    const out = { id: 'o1', type: 'code' as const, content: 'let x = 1', metadata: { language: 'ocaml', lineCount: 3 } }
    expect(announceAgentOutput(out)).toContain('코드 출력')
    expect(announceAgentOutput(out)).toContain('ocaml')
    expect(announceAgentOutput(out)).toContain('3')
  })

  it('announces code with unknown language', () => {
    const out = { id: 'o2', type: 'code' as const, content: 'x' }
    expect(announceAgentOutput(out)).toContain('알 수 없는')
  })

  it('announces table output', () => {
    const out = { id: 'o3', type: 'table' as const, content: 'a\nb\nc' }
    expect(announceAgentOutput(out)).toContain('테이블 데이터')
    expect(announceAgentOutput(out)).toContain('3')
  })

  it('announces error output', () => {
    const out = { id: 'o4', type: 'error' as const, content: 'something failed' }
    expect(announceAgentOutput(out)).toContain('오류 발생')
    expect(announceAgentOutput(out)).toContain('something failed')
  })

  it('truncates long error content', () => {
    const out = { id: 'o5', type: 'error' as const, content: 'x'.repeat(200) }
    expect(announceAgentOutput(out).length).toBeLessThan(150)
  })

  it('announces short text output', () => {
    const out = { id: 'o6', type: 'text' as const, content: 'hello' }
    expect(announceAgentOutput(out)).toContain('텍스트 출력')
    expect(announceAgentOutput(out)).toContain('hello')
  })

  it('announces long text output with length', () => {
    const out = { id: 'o7', type: 'text' as const, content: 'x'.repeat(300) }
    expect(announceAgentOutput(out)).toContain('텍스트 출력')
    expect(announceAgentOutput(out)).toContain('300')
  })

  it('summarizes output identity, type, priority, and content length', () => {
    const summary = summarizeAgentOutput(
      { id: 'o8', type: 'error', content: 'failed' },
      'auto',
    )
    expect(summary).toEqual({
      id: 'o8',
      type: 'error',
      message: '오류 발생: failed',
      priority: 'assertive',
      contentLength: 6,
    })
  })

  it('classifies auto live-region priority by output type', () => {
    expect(resolveAgentOutputPriority({ id: 't', type: 'text', content: 'ok' }, 'auto')).toBe('polite')
    expect(resolveAgentOutputPriority({ id: 'e', type: 'error', content: 'bad' }, 'auto')).toBe('assertive')
    expect(resolveAgentOutputPriority({ id: 'e', type: 'error', content: 'bad' }, 'polite')).toBe('polite')
  })
})

describe('AgentOutputAnnouncer', () => {
  it('renders live region', () => {
    const container = document.createElement('div')
    render(h(AgentOutputAnnouncer, { outputs: [] }), container)
    expect(container.querySelector('[role="log"]')).not.toBeNull()
  })

  it('renders polite by default', () => {
    const container = document.createElement('div')
    render(h(AgentOutputAnnouncer, { outputs: [] }), container)
    const el = container.querySelector('[role="log"]') as HTMLElement
    expect(el?.getAttribute('aria-live')).toBe('polite')
    expect(el?.getAttribute('aria-atomic')).toBe('false')
  })

  it('renders assertive when priority is assertive', () => {
    const container = document.createElement('div')
    render(h(AgentOutputAnnouncer, { outputs: [], priority: 'assertive' }), container)
    const el = container.querySelector('[role="log"]') as HTMLElement
    expect(el?.getAttribute('aria-live')).toBe('assertive')
    expect(el?.getAttribute('aria-atomic')).toBe('true')
  })

  it('auto priority renders errors as assertive after announcement', async () => {
    const container = document.createElement('div')
    render(h(AgentOutputAnnouncer, {
      outputs: [{ id: 'o-error', type: 'error', content: 'disk full' }],
      priority: 'auto',
    }), container)
    await new Promise((r) => setTimeout(r, 10))
    const el = container.querySelector('[role="log"]') as HTMLElement
    expect(el?.getAttribute('aria-live')).toBe('assertive')
    expect(el?.getAttribute('aria-atomic')).toBe('true')
    expect(el?.getAttribute('data-agent-output-announcer-priority')).toBe('assertive')
    expect(el?.getAttribute('data-agent-output-announcer-output-type')).toBe('error')
  })

  it('updates announcement priority when the policy changes for the same output', async () => {
    const container = document.createElement('div')
    const outputs = [{ id: 'o-error', type: 'error' as const, content: 'disk full' }]
    render(h(AgentOutputAnnouncer, { outputs, priority: 'polite' }), container)
    await new Promise((r) => setTimeout(r, 10))
    const el = container.querySelector('[role="log"]') as HTMLElement
    const textMutations: string[] = []
    const observer = new MutationObserver(() => {
      textMutations.push(el.textContent ?? '')
    })
    observer.observe(el, { childList: true, characterData: true, subtree: true })

    render(h(AgentOutputAnnouncer, { outputs, priority: 'auto' }), container)
    await new Promise((r) => setTimeout(r, 10))
    observer.disconnect()

    expect(el?.getAttribute('aria-live')).toBe('assertive')
    expect(el?.getAttribute('data-agent-output-announcer-priority')).toBe('assertive')
    expect(textMutations).toContain('')
    expect(textMutations.at(-1)).toBe('오류 발생: disk full')
  })

  it('renders aria-label', () => {
    const container = document.createElement('div')
    render(h(AgentOutputAnnouncer, { outputs: [] }), container)
    const el = container.querySelector('[role="log"]') as HTMLElement
    expect(el?.getAttribute('aria-label')).toBe('에이전트 출력 알림')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(AgentOutputAnnouncer, { outputs: [], testId: 'aoa-1' }), container)
    expect(container.querySelector('[data-testid="aoa-1"]')).not.toBeNull()
  })

  it('has data-agent-output-announcer', () => {
    const container = document.createElement('div')
    render(h(AgentOutputAnnouncer, { outputs: [] }), container)
    expect(container.querySelector('[data-agent-output-announcer]')).not.toBeNull()
  })

  it('announces new output after effect', async () => {
    const container = document.createElement('div')
    const outputs = [{ id: 'o1', type: 'text' as const, content: 'hello' }]
    render(h(AgentOutputAnnouncer, { outputs }), container)
    await new Promise((r) => setTimeout(r, 10))
    const el = container.querySelector('[role="log"]') as HTMLElement
    expect(el?.textContent).toContain('hello')
    expect(el?.getAttribute('data-agent-output-announcer-output-id')).toBe('o1')
    expect(el?.getAttribute('data-agent-output-announcer-content-length')).toBe('5')
  })

  it('announces a changed latest output id even when output count stays the same', async () => {
    const container = document.createElement('div')
    render(h(AgentOutputAnnouncer, {
      outputs: [{ id: 'o1', type: 'text', content: 'first' }],
    }), container)
    await new Promise((r) => setTimeout(r, 10))
    render(h(AgentOutputAnnouncer, {
      outputs: [{ id: 'o2', type: 'text', content: 'second' }],
    }), container)
    await new Promise((r) => setTimeout(r, 10))

    const el = container.querySelector('[role="log"]') as HTMLElement
    expect(el?.textContent).toContain('second')
    expect(el?.getAttribute('data-agent-output-announcer-output-id')).toBe('o2')
  })

  it('re-adds identical announcement text when only the output id changes', async () => {
    const container = document.createElement('div')
    render(h(AgentOutputAnnouncer, {
      outputs: [{ id: 'o1', type: 'text', content: 'same message' }],
    }), container)
    await new Promise((r) => setTimeout(r, 10))

    const el = container.querySelector('[role="log"]') as HTMLElement
    const textMutations: string[] = []
    const observer = new MutationObserver(() => {
      textMutations.push(el.textContent ?? '')
    })
    observer.observe(el, { childList: true, characterData: true, subtree: true })

    render(h(AgentOutputAnnouncer, {
      outputs: [{ id: 'o2', type: 'text', content: 'same message' }],
    }), container)
    await new Promise((r) => setTimeout(r, 10))
    observer.disconnect()

    expect(el?.textContent).toBe('텍스트 출력: same message')
    expect(el?.getAttribute('data-agent-output-announcer-output-id')).toBe('o2')
    expect(textMutations).toContain('')
    expect(textMutations.at(-1)).toBe('텍스트 출력: same message')
  })
})
