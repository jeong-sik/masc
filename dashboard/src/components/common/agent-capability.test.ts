import { describe, expect, it } from 'vitest'
import { h } from 'preact'
import { render } from 'preact'
import {
  AgentCapability,
  normalizeTools,
  summarizeAgentCapability,
  toolConfig,
} from './agent-capability'

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

describe('toolConfig', () => {
  it('returns mono glyph configs for known tools', () => {
    expect(toolConfig('shell')).toMatchObject({
      glyph: 'SH',
      label: '터미널',
    })
  })

  it('falls back to a generic mono glyph for unknown tools', () => {
    expect(toolConfig('custom_tool')).toEqual({
      glyph: 'TL',
      label: 'custom_tool',
      description: 'custom_tool 도구',
    })
  })

  it('treats prototype keys as unknown tools', () => {
    expect(toolConfig('__proto__')).toEqual({
      glyph: 'TL',
      label: '__proto__',
      description: '__proto__ 도구',
    })
    expect(toolConfig('constructor')).toEqual({
      glyph: 'TL',
      label: 'constructor',
      description: 'constructor 도구',
    })
  })
})

describe('summarizeAgentCapability', () => {
  it('summarizes visible and hidden tools', () => {
    const summary = summarizeAgentCapability(
      ['file_read', 'shell', 'unknown_tool', 'api_call'],
      2,
    )

    expect(summary).toMatchObject({
      tools: ['file_read', 'shell', 'unknown_tool', 'api_call'],
      count: 4,
      visibleCount: 2,
      extraCount: 2,
      empty: false,
      maxVisible: 2,
      hidden: ['unknown_tool', 'api_call'],
      hiddenLabel: 'unknown_tool, api_call',
    })
    expect(summary.visible).toEqual([
      expect.objectContaining({
        tool: 'file_read',
        glyph: 'RD',
        known: true,
        index: 0,
      }),
      expect.objectContaining({ tool: 'shell', glyph: 'SH', known: true, index: 1 }),
    ])
  })

  it('clamps negative maxVisible to zero', () => {
    const summary = summarizeAgentCapability(['shell'], -1)
    expect(summary.visible).toEqual([])
    expect(summary.hidden).toEqual(['shell'])
    expect(summary.extraCount).toBe(1)
    expect(summary.maxVisible).toBe(0)
  })

  it('does not mark inherited object keys as known', () => {
    const summary = summarizeAgentCapability(['__proto__', 'constructor'])
    expect(summary.visible).toEqual([
      expect.objectContaining({ tool: '__proto__', glyph: 'TL', known: false }),
      expect.objectContaining({ tool: 'constructor', glyph: 'TL', known: false }),
    ])
  })
})

describe('AgentCapability', () => {
  it('renders empty state', () => {
    const container = document.createElement('div')
    render(h(AgentCapability, { tools: [] }), container)
    expect(container.textContent).toContain('도구 없음')
    expect(
      container
        .querySelector('[data-agent-capability]')
        ?.getAttribute('data-capability-empty'),
    ).toBe('true')
    expect(
      container
        .querySelector('[data-agent-capability]')
        ?.getAttribute('data-capability-count'),
    ).toBe('0')
  })

  it('renders tool badges', () => {
    const container = document.createElement('div')
    render(h(AgentCapability, { tools: ['file_read', 'shell'] }), container)
    expect(container.textContent).toContain('파일 읽기')
    expect(container.textContent).toContain('터미널')
    expect(container.textContent).toContain('RD')
    expect(container.textContent).toContain('SH')
  })

  it('limits visible badges', () => {
    const container = document.createElement('div')
    render(
      h(AgentCapability, { tools: ['a', 'b', 'c', 'd', 'e'], maxVisible: 3 }),
      container,
    )
    expect(container.textContent).toContain('+2')
    const root = container.querySelector('[data-agent-capability]')
    expect(root?.getAttribute('data-capability-count')).toBe('5')
    expect(root?.getAttribute('data-capability-visible-count')).toBe('3')
    expect(root?.getAttribute('data-capability-extra-count')).toBe('2')
    expect(root?.getAttribute('data-capability-hidden-label')).toBe('d, e')
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

  it('publishes per-tool summary metadata', () => {
    const container = document.createElement('div')
    render(h(AgentCapability, { tools: ['shell', 'custom_tool'] }), container)
    const badges = container.querySelectorAll('[data-capability-tool]')

    expect(badges[0]?.getAttribute('data-capability-tool-known')).toBe('true')
    expect(badges[0]?.getAttribute('data-capability-tool-glyph')).toBe('SH')
    expect(badges[0]?.getAttribute('data-capability-tool-label')).toBe('터미널')
    expect(badges[1]?.getAttribute('data-capability-tool-known')).toBe('false')
    expect(badges[1]?.getAttribute('data-capability-tool-glyph')).toBe('TL')
    expect(badges[1]?.getAttribute('data-capability-tool-label')).toBe('custom_tool')
  })
})
