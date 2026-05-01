import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import { AgentCapability, normalizeTools, toolConfig } from './agent-capability'

describe('toolConfig', () => {
  it('returns config for known tools', () => {
    const cfg = toolConfig('file_read')
    expect(cfg.label).toBe('파일 읽기')
    expect(cfg.icon).toBeDefined()
  })

  it('returns generic fallback for unknown tools', () => {
    const cfg = toolConfig('unknown_tool')
    expect(cfg.label).toBe('unknown_tool')
    expect(cfg.description).toContain('unknown_tool')
  })
})

describe('normalizeTools', () => {
  it('returns empty array for null input', () => {
    expect(normalizeTools(null)).toEqual([])
  })

  it('filters null and undefined', () => {
    expect(normalizeTools(['a', null, undefined, 'b'])).toEqual(['a', 'b'])
  })

  it('deduplicates preserving order', () => {
    expect(normalizeTools(['a', 'b', 'a', 'c'])).toEqual(['a', 'b', 'c'])
  })

  it('trims whitespace', () => {
    expect(normalizeTools([' a ', 'b'])).toEqual(['a', 'b'])
  })
})

describe('AgentCapability', () => {
  it('renders empty state', () => {
    const container = document.createElement('div')
    render(h(AgentCapability, { tools: [] }), container)
    expect(container.textContent).toContain('도구 없음')
  })

  it('renders tool badges', () => {
    const container = document.createElement('div')
    render(h(AgentCapability, { tools: ['file_read', 'shell'] }), container)
    expect(container.textContent).toContain('파일 읽기')
    expect(container.textContent).toContain('터미널')
  })

  it('limits visible badges', () => {
    const container = document.createElement('div')
    render(h(AgentCapability, { tools: ['a', 'b', 'c', 'd', 'e'], maxVisible: 3 }), container)
    expect(container.textContent).toContain('+2')
  })

  it('applies testId', () => {
    const container = document.createElement('div')
    render(h(AgentCapability, { tools: [], testId: 'ac-1' }), container)
    expect(container.querySelector('[data-testid="ac-1"]')).not.toBeNull()
  })

  it('filters null tools', () => {
    const container = document.createElement('div')
    render(h(AgentCapability, { tools: ['file_read', null, 'shell'] }), container)
    const badges = container.querySelectorAll('[data-tool]')
    expect(badges.length).toBe(2)
  })
})
