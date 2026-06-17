// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { KeeperConversationEntry } from '../../types'
import { ChatArtifactPanel, extractArtifactGroups } from './artifact-panel'

function entry(
  overrides: Partial<KeeperConversationEntry> & Pick<KeeperConversationEntry, 'id' | 'text'>,
): KeeperConversationEntry {
  return {
    role: 'assistant',
    source: 'direct_assistant',
    label: 'sangsu',
    delivery: 'delivered',
    streamState: null,
    details: null,
    error: null,
    attachments: [],
    blocks: [],
    ...overrides,
    id: overrides.id,
    text: overrides.text,
  }
}

describe('extractArtifactGroups', () => {
  it('returns an empty array when there are no artifacts', () => {
    const groups = extractArtifactGroups([
      entry({ id: 'e1', text: 'hello', blocks: [], attachments: [] }),
    ])
    expect(groups).toHaveLength(0)
  })

  it('collects attachments, code, mermaid, images, svgs, artifacts, tool outputs, and links', () => {
    const groups = extractArtifactGroups([
      entry({
        id: 'e1',
        text: 'reply',
        role: 'assistant',
        label: 'sangsu',
        attachments: [
          { id: 'att-1', type: 'image', name: 'screen.png', size: 1024, mimeType: 'image/png', data: 'data:image/png;base64,abc' },
        ],
        blocks: [
          { t: 'code', cap: 'config.ml', html: 'let x = 1' },
          { t: 'mermaid', source: 'graph TD; A-->B', caption: 'flow' },
          { t: 'image', src: '/img/screen.png', cap: '실행 화면' },
          { t: 'svg', svg: '<svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="5"/></svg>', cap: 'diagram' },
          { t: 'artifact', kind: 'json', name: 'report.json', size: '12 KB', note: '3 items' },
          {
            t: 'trace',
            trace: [
              { kind: 'think', text: 'plan' },
              { kind: 'tool', name: 'keeper_context_status', status: 'ok', dur: '0.2s', args: { path: 'a' }, result: '{"ok":true}' },
            ],
          },
          { t: 'link', url: 'https://example.com', title: 'Example', meta: 'example.com' },
        ],
      }),
      entry({ id: 'e2', text: 'user msg', role: 'user', label: '사용자', blocks: [{ t: 'attach', name: 'shape.svg', svg: '<svg/>', size: '1 KB' }] }),
    ])

    expect(groups).toHaveLength(2)
    expect(groups[0]!.turnIndex).toBe(0)
    expect(groups[0]!.items).toHaveLength(8)
    expect(groups[1]!.turnIndex).toBe(1)
    expect(groups[1]!.items).toHaveLength(1)

    const kinds = groups[0]!.items.map((i) => i.kind)
    expect(kinds).toEqual(['attachment', 'code', 'mermaid', 'image', 'svg', 'artifact', 'tool', 'link'])
  })

  it('groups items by entry id', () => {
    const groups = extractArtifactGroups([
      entry({ id: 'e1', text: 'a', blocks: [{ t: 'code', html: 'a' }] }),
      entry({ id: 'e2', text: 'b', blocks: [{ t: 'code', html: 'b' }] }),
    ])
    expect(groups).toHaveLength(2)
    expect(groups[0]!.entryId).toBe('e1')
    expect(groups[1]!.entryId).toBe('e2')
  })
})

describe('ChatArtifactPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    vi.stubGlobal('open', vi.fn())
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.unstubAllGlobals()
  })

  it('renders the total artifact count', () => {
    render(
      html`<${ChatArtifactPanel}
        entries=${[
          entry({
            id: 'e1',
            text: 'reply',
            blocks: [
              { t: 'code', cap: 'a.ml', html: 'let x = 1' },
              { t: 'image', src: '/img/screen.png' },
            ],
          }),
        ]}
      />`,
      container,
    )

    expect(container.textContent).toContain('아티팩트')
    expect(container.querySelector('.chat-artifact-panel-count')?.textContent).toBe('2')
  })

  it('shows an empty message when there are no artifacts', () => {
    render(html`<${ChatArtifactPanel} entries=${[]} />`, container)
    expect(container.textContent).toContain('아티팩트가 없습니다')
  })

  it('groups artifacts under turn headers', () => {
    render(
      html`<${ChatArtifactPanel}
        entries=${[
          entry({ id: 'e1', text: 'a', role: 'assistant', label: 'sangsu', blocks: [{ t: 'code', html: 'a' }] }),
          entry({ id: 'e2', text: 'b', role: 'user', label: '사용자', blocks: [{ t: 'image', src: '/b.png' }] }),
        ]}
      />`,
      container,
    )

    expect(container.textContent).toContain('#1')
    expect(container.textContent).toContain('sangsu')
    expect(container.textContent).toContain('#2')
    expect(container.textContent).toContain('사용자')
  })

  it('renders compact cards with open and download buttons', () => {
    render(
      html`<${ChatArtifactPanel}
        entries=${[
          entry({
            id: 'e1',
            text: 'reply',
            blocks: [{ t: 'artifact', kind: 'json', name: 'report.json', size: '12 KB', note: '3 items' }],
          }),
        ]}
      />`,
      container,
    )

    const card = container.querySelector('[data-artifact-kind="artifact"]')
    expect(card).not.toBeNull()
    expect(card?.textContent).toContain('report.json')
    expect(card?.textContent).toContain('JSON')
    expect(card?.textContent).toContain('12 KB')
    const buttons = [...(card?.querySelectorAll('button') ?? [])].map((b) => b.textContent?.trim())
    expect(buttons).toContain('열기')
    expect(buttons).toContain('다운로드')
  })

  it('disables download for artifact blocks that carry no payload', () => {
    render(
      html`<${ChatArtifactPanel}
        entries=${[
          entry({
            id: 'e1',
            text: 'reply',
            blocks: [{ t: 'artifact', kind: 'json', name: 'report.json' }],
          }),
        ]}
      />`,
      container,
    )

    const card = container.querySelector('[data-artifact-kind="artifact"]')
    const downloadBtn = card?.querySelector('button[aria-label="다운로드"]') as HTMLButtonElement | null
    expect(downloadBtn?.disabled).toBe(true)
  })

  it('expands a code preview when open is clicked', async () => {
    render(
      html`<${ChatArtifactPanel}
        entries=${[
          entry({
            id: 'e1',
            text: 'reply',
            blocks: [{ t: 'code', cap: 'a.ml', html: 'let x = 1' }],
          }),
        ]}
      />`,
      container,
    )

    const card = container.querySelector('[data-artifact-kind="code"]')
    expect(card?.querySelector('[data-artifact-preview="code"]')).toBeNull()

    const openBtn = card?.querySelector('button[aria-label="미리보기"]') as HTMLButtonElement | null
    await act(async () => {
      openBtn?.click()
    })

    expect(card?.querySelector('[data-artifact-preview="code"]')).not.toBeNull()
    expect(card?.textContent).toContain('let x = 1')
  })

  it('opens a link in a new tab when open is clicked', async () => {
    render(
      html`<${ChatArtifactPanel}
        entries=${[
          entry({
            id: 'e1',
            text: 'reply',
            blocks: [{ t: 'link', url: 'https://example.com', title: 'Example' }],
          }),
        ]}
      />`,
      container,
    )

    const card = container.querySelector('[data-artifact-kind="link"]')
    const openBtn = card?.querySelector('button[aria-label="링크 열기"]') as HTMLButtonElement | null
    await act(async () => {
      openBtn?.click()
    })

    expect(window.open).toHaveBeenCalledWith('https://example.com', '_blank', 'noopener,noreferrer')
  })
})
