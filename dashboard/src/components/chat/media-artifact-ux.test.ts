// @vitest-environment jsdom
import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ChatBlock, KeeperConversationAttachment, KeeperConversationEntry } from '../../types'
import { ChatTranscript } from './primitives'

const flushUi = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 30))

function entry(
  overrides: Partial<KeeperConversationEntry> & Pick<KeeperConversationEntry, 'id' | 'text'>,
): KeeperConversationEntry {
  return {
    role: 'assistant',
    source: 'direct_assistant',
    label: 'sangsu',
    rawText: overrides.rawText ?? overrides.text,
    timestamp: '2026-03-24T00:00:00.000Z',
    delivery: 'history',
    streamState: null,
    details: null,
    error: null,
    ...overrides,
  }
}

function renderBlocks(blocks: ChatBlock[]) {
  const container = document.createElement('div')
  document.body.appendChild(container)
  render(
    html`<${ChatTranscript}
      entries=${[entry({ id: 'b1', text: '', blocks })]}
      emptyText="empty"
    />`,
    container,
  )
  return container
}

describe('media and artifact UX', () => {
  afterEach(() => {
    document.body.innerHTML = ''
  })

  it('opens an artifact preview modal and closes it', async () => {
    const container = renderBlocks([
      {
        t: 'artifact',
        kind: 'md',
        name: 'note.md',
        data: 'data:text/markdown;base64,SGVsbG8gV29ybGQ=',
        mimeType: 'text/markdown',
      },
    ])

    const artifact = container.querySelector('[data-chat-block="artifact"]')
    expect(artifact).not.toBeNull()

    const [openBtn, downloadBtn] = artifact!.querySelectorAll('button')
    expect(openBtn!.hasAttribute('disabled')).toBe(false)
    expect(downloadBtn!.hasAttribute('disabled')).toBe(false)

    ;(openBtn as HTMLElement).click()
    await flushUi()

    const modal = document.querySelector('[role="dialog"]')
    expect(modal).not.toBeNull()
    expect(modal!.textContent).toContain('note.md')

    const closeBtn = modal!.querySelector('button[aria-label="닫기"]')
    ;(closeBtn as HTMLElement).click()
    await flushUi()

    expect(document.querySelector('[role="dialog"]')).toBeNull()
  })

  it('disables open/download when artifact has no data', () => {
    const container = renderBlocks([{ t: 'artifact', kind: 'json', name: 'report.json' }])

    const artifact = container.querySelector('[data-chat-block="artifact"]')
    const [openBtn, downloadBtn] = artifact!.querySelectorAll('button')
    expect(openBtn!.hasAttribute('disabled')).toBe(true)
    expect(downloadBtn!.hasAttribute('disabled')).toBe(true)
  })

  it('downloads artifact data via a temporary anchor', async () => {
    const createEl = document.createElement
    const clickSpy = vi.fn()
    document.createElement = vi.fn((tag: string) => {
      const el = createEl.call(document, tag as keyof HTMLElementTagNameMap)
      if (tag === 'a') {
        ;(el as HTMLAnchorElement).click = clickSpy
      }
      return el
    }) as typeof document.createElement

    const container = renderBlocks([
      {
        t: 'artifact',
        kind: 'json',
        name: 'report.json',
        data: '{"ok":true}',
        mimeType: 'application/json',
      },
    ])

    const artifact = container.querySelector('[data-chat-block="artifact"]')
    const downloadBtn = artifact!.querySelector('button[aria-label="다운로드"]')
    ;(downloadBtn as HTMLElement).click()
    await flushUi()

    expect(clickSpy).toHaveBeenCalled()
    document.createElement = createEl
  })

  it('opens a lightbox when clicking an image block', async () => {
    const container = renderBlocks([{ t: 'image', src: '/img/screen.png', cap: '실행 화면' }])

    const frame = container.querySelector('[data-chat-block="image"] .chat-block-media-frame')
    ;(frame as HTMLElement).click()
    await flushUi()

    const modal = document.querySelector('[role="dialog"]')
    expect(modal).not.toBeNull()
    expect(modal!.querySelector('img')?.getAttribute('src')).toBe('/img/screen.png')

    ;(modal!.querySelector('button[aria-label="닫기"]') as HTMLElement).click()
    await flushUi()
    expect(document.querySelector('[role="dialog"]')).toBeNull()
  })

  it('opens a lightbox when clicking an svg block', async () => {
    const container = renderBlocks([
      { t: 'svg', svg: '<svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="5"/></svg>', cap: 'diagram' },
    ])

    ;(container.querySelector('[data-chat-block="svg"] .chat-block-media-frame') as HTMLElement).click()
    await flushUi()

    const modal = document.querySelector('[role="dialog"]')
    expect(modal).not.toBeNull()
    expect(modal!.querySelector('svg')).not.toBeNull()

    ;(modal!.querySelector('button[aria-label="닫기"]') as HTMLElement).click()
    await flushUi()
    expect(document.querySelector('[role="dialog"]')).toBeNull()
  })

  it('opens a lightbox when clicking an image attachment', async () => {
    const attachment: KeeperConversationAttachment = {
      id: 'att-1',
      type: 'image',
      name: 'screenshot.png',
      size: 1024,
      mimeType: 'image/png',
      data: 'data:image/png;base64,abc123',
    }
    const container = document.createElement('div')
    document.body.appendChild(container)
    render(
      html`<${ChatTranscript}
        entries=${[entry({ id: 'u1', text: '첨부 확인', attachments: [attachment] })]}
        emptyText="empty"
      />`,
      container,
    )

    const card = container.querySelector('[data-chat-attachment-card="att-1"]')
    ;(card!.querySelector('button') as HTMLElement).click()
    await flushUi()

    const modal = document.querySelector('[role="dialog"]')
    expect(modal).not.toBeNull()
    expect(modal!.textContent).toContain('screenshot.png')

    ;(modal!.querySelector('button[aria-label="닫기"]') as HTMLElement).click()
    await flushUi()
    expect(document.querySelector('[role="dialog"]')).toBeNull()
  })

  it('renders the audio player with desktop-style chrome and duration', () => {
    const container = document.createElement('div')
    document.body.appendChild(container)
    render(
      html`<${ChatTranscript}
        entries=${[
          entry({
            id: 'a1',
            text: 'hello',
            audio: {
              token: 'clip-1',
              audioUrl: '/api/v1/voice/audio/clip-1',
              mime: 'audio/mpeg',
              durationSec: 5,
              messageText: 'hello',
            },
          }),
        ]}
        emptyText="empty"
      />`,
      container,
    )

    const player = container.querySelector('[data-chat-audio-clip]')
    expect(player).not.toBeNull()
    expect(player!.classList.contains('chat-audio-clip')).toBe(true)
    expect(player!.querySelector('audio')).not.toBeNull()
    expect(player!.textContent).toContain('0:05')
  })
})
