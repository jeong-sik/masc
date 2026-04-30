// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { axe } from 'jest-axe'
import { AgentMemory } from './agent-memory'

describe('AgentMemory a11y', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => {
    render(null, container)
    document.body.removeChild(container)
  })

  const makeEntries = (): import('./agent-memory').MemoryEntry[] => [
    {
      id: 's1',
      content: '파일 읽기 요청',
      type: 'short_term',
      timestamp: Date.now() - 60000,
    },
    {
      id: 's2',
      content: 'API 호출 결과',
      type: 'short_term',
      timestamp: Date.now() - 120000,
    },
    {
      id: 'l1',
      content: '사용자 선호 설정 A',
      type: 'long_term',
      timestamp: Date.now() - 86400000,
      similarity: 0.92,
      cluster: 'preferences',
    },
    {
      id: 'l2',
      content: '데이터베이스 스키마 v3',
      type: 'long_term',
      timestamp: Date.now() - 172800000,
      similarity: 0.78,
      cluster: 'schema',
    },
  ]

  it('renders accessibly with mixed entries', async () => {
    render(html`<${AgentMemory} entries=${makeEntries()} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with empty entries', async () => {
    render(html`<${AgentMemory} entries=${[]} />`, container)
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with only short_term', async () => {
    render(
      html`<${AgentMemory}
        entries=${[
          { id: 's1', content: 'test', type: 'short_term', timestamp: Date.now() },
        ]}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('renders accessibly with only long_term', async () => {
    render(
      html`<${AgentMemory}
        entries=${[
          {
            id: 'l1',
            content: 'test',
            type: 'long_term',
            timestamp: Date.now(),
            cluster: 'c1',
          },
        ]}
      />`,
      container,
    )
    expect(await axe(container)).toHaveNoViolations()
  })

  it('has list roles for memory sections', () => {
    render(html`<${AgentMemory} entries=${makeEntries()} />`, container)
    const lists = container.querySelectorAll('[role="list"]')
    expect(lists.length).toBe(2)
  })

  it('renders short-term content in recency order', () => {
    render(html`<${AgentMemory} entries=${makeEntries()} />`, container)
    expect(container.textContent).toContain('파일 읽기 요청')
    expect(container.textContent).toContain('API 호출 결과')
  })

  it('renders cluster labels', () => {
    render(html`<${AgentMemory} entries=${makeEntries()} />`, container)
    expect(container.textContent).toContain('preferences')
    expect(container.textContent).toContain('schema')
  })
})
