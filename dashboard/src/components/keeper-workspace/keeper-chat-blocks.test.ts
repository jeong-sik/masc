// @vitest-environment jsdom

import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, describe, expect, it } from 'vitest'
import type { ChatBlock, KeeperConversationEntry } from '../../types'
import { ChatTranscript } from '../chat/primitives'

function entry(
  overrides: Partial<KeeperConversationEntry> & Pick<KeeperConversationEntry, 'id' | 'text'>,
): KeeperConversationEntry {
  return {
    role: 'assistant',
    source: 'direct_assistant',
    label: 'masc-improver',
    rawText: overrides.rawText ?? overrides.text,
    timestamp: '2026-06-22T01:00:00.000Z',
    delivery: 'delivered',
    streamState: null,
    details: null,
    error: null,
    ...overrides,
  }
}

function renderBlocks(blocks: ChatBlock[]): HTMLDivElement {
  const container = document.createElement('div')
  document.body.appendChild(container)
  render(
    html`<${ChatTranscript}
      entries=${[entry({ id: 'kb-1', text: '', blocks })]}
      emptyText="empty"
    />`,
    container,
  )
  return container
}

describe('Keeper chat rich blocks', () => {
  afterEach(() => {
    document.body.innerHTML = ''
  })

  it('renders a chart block with title, svg and legend', () => {
    const container = renderBlocks([
      {
        t: 'chart',
        title: 'open_fds — drain 횟수에 따른 추이',
        series: [
          { label: '패치 전 (누수)', values: [42, 58, 72, 87] },
          { label: '패치 후 (안정)', values: [41, 42, 41, 41] },
        ],
        labels: ['1', '2', '3', '4'],
        xLabel: 'drain 횟수',
      },
    ])

    const chart = container.querySelector('[data-chat-block="chart"]')
    expect(chart).not.toBeNull()
    expect(chart?.textContent).toContain('open_fds — drain 횟수에 따른 추이')
    expect(chart?.querySelector('svg')).not.toBeNull()
    expect(chart?.textContent).toContain('패치 전 (누수)')
    expect(chart?.textContent).toContain('패치 후 (안정)')
  })

  it('renders suggestion buttons with expected text and icons', () => {
    const container = renderBlocks([
      {
        t: 'suggestions',
        items: [
          { icon: '▸', label: 'PR #7763 열기', action: 'open-pr' },
          { icon: '✦', label: 'open_fds 패널 추가', action: 'add-panel' },
          { icon: '▸', label: 'compact 라이터에도 적용', action: 'apply-compact' },
        ],
      },
    ])

    const suggestions = container.querySelector('[data-chat-block="suggestions"]')
    expect(suggestions).not.toBeNull()
    // Mirrors prototype messages.jsx:139 — "추천 후속 질문" label precedes the chip row.
    expect(suggestions?.querySelector('.chat-block-suggestions-label')?.textContent).toBe('추천 후속 질문')
    const row = suggestions?.querySelector('.chat-block-suggestions-row')
    expect(row).not.toBeNull()
    const buttons = [...(row?.querySelectorAll('button') ?? [])]
    expect(buttons).toHaveLength(3)
    expect(buttons.map((b) => b.textContent?.trim())).toEqual([
      '▸PR #7763 열기',
      '✦open_fds 패널 추가',
      '▸compact 라이터에도 적용',
    ])
  })

  it('renders an artifact card with name and view/download buttons', () => {
    const container = renderBlocks([
      {
        t: 'artifact',
        kind: 'md',
        name: 'fd-leak-fix.md',
        size: '1.2 KB',
        note: 'PATCH',
        data: 'data:text/markdown;base64,IyBmaXg=',
        mimeType: 'text/markdown',
      },
    ])

    const artifact = container.querySelector('[data-chat-block="artifact"]')
    expect(artifact).not.toBeNull()
    expect(artifact?.textContent).toContain('fd-leak-fix.md')
    expect(artifact?.textContent).toContain('MD')
    expect(artifact?.textContent).toContain('1.2 KB')
    const buttons = [...(artifact?.querySelectorAll('button') ?? [])].map((b) => b.textContent?.trim())
    expect(buttons).toContain('열기')
    expect(buttons).toContain('다운로드')
  })

  it('renders an issue card with repo, number, title and status', () => {
    const container = renderBlocks([
      {
        t: 'issue',
        repo: 'ocaml-multicore/eio',
        number: 388,
        title: 'Resource leak when forking into a parent Switch',
        status: 'open',
        url: 'https://github.com/ocaml-multicore/eio/issues/388',
        meta: 'github.com · Issue #388',
      },
    ])

    const issue = container.querySelector('[data-chat-block="issue"]')
    expect(issue).not.toBeNull()
    expect(issue?.textContent).toContain('ocaml-multicore/eio')
    expect(issue?.textContent).toContain('#388')
    expect(issue?.textContent).toContain('Resource leak when forking into a parent Switch')
    expect(issue?.textContent).toContain('OPEN')
    expect(issue?.getAttribute('href')).toBe('https://github.com/ocaml-multicore/eio/issues/388')
  })
})
