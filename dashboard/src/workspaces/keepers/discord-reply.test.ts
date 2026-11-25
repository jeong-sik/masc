// @vitest-environment jsdom
import { webcrypto } from 'node:crypto'
import { currentSessionEpoch } from '../../core/auth'
import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { DiscordReplyPanel } from './discord-reply-panel'
import { decodeHistoryRow } from './keepers-api'
import type { DiscordReplyTarget } from './discord-reply'

const target: DiscordReplyTarget = {
  keeperName: 'keeper',
  chatId: 'local-chat-row-1',
  origin: { guildId: '100', channelId: '200', messageId: '300' },
}
const workspace = { base_path: '/workspace', masc_root: '/workspace/.masc' }

function json(value: unknown, status: number): Response {
  return new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json' } })
}

function receipt(operationId: string, data: Record<string, unknown>): Record<string, unknown> {
  return {
    operation_id: operationId,
    keeper_name: target.keeperName,
    chat_id: target.chatId,
    channel_id: target.origin.channelId,
    original_message_id: target.origin.messageId,
    ...data,
  }
}

let container: HTMLDivElement

function button(name: string): HTMLButtonElement {
  const found = Array.from(container.querySelectorAll('button')).find(el => el.textContent?.trim() === name)
  if (!found) throw new Error(`Missing action ${name}`)
  return found
}

async function mount() {
  await act(async () => {
    render(html`<${DiscordReplyPanel} target=${target} authority=${{ actor: "local-admin", epoch: currentSessionEpoch(), workspace }} onClose=${() => {}} />`, container)
  })
}

async function submitText(text: string, label = 'Discord로 보내기') {
  const input = container.querySelector('textarea')!
  await act(async () => {
    input.value = text
    input.dispatchEvent(new Event('input', { bubbles: true }))
  })
  await act(async () => { button(label).click() })
}

beforeEach(() => {
  vi.stubGlobal('crypto', webcrypto)
  container = document.createElement('div')
  document.body.append(container)
})

afterEach(() => {
  act(() => render(null, container))
  container.remove()
  sessionStorage.clear()
  vi.unstubAllGlobals()
})

describe('Dashboard Discord reply', () => {
  it('preserves the exact channel and external ID on a persisted inbound row', () => {
    const row = {
      id: target.chatId,
      role: 'user',
      speaker_authority: 'external',
      surface: {
        kind: 'discord', guild_id: '100', channel_id: '200', channel_name: 'support',
        parent_channel_id: '199', thread_id: '200',
      },
      external_message_id: '300',
    }
    expect(decodeHistoryRow(row)?.discordReplyOrigin).toEqual(target.origin)
    expect(decodeHistoryRow({ ...row, speaker_authority: 'owner' })?.discordReplyOrigin).toBeNull()
    expect(decodeHistoryRow({ ...row, surface: { ...row.surface, thread_id: '201' } })?.discordReplyOrigin).toBeNull()
  })

  it('sends only the stored chat row ID and restores the receipt across remount', async () => {
    const send = vi.fn(async (path: string, init: RequestInit) => {
      const body = JSON.parse(init.body as string)
      if (path.endsWith('/status')) {
        return json(receipt(body.operation_id, { state: 'delivered', message_id: '400' }), 200)
      }
      return json(receipt(body.operation_id, { state: 'sending' }), 202)
    })
    vi.stubGlobal('fetch', send)
    await mount()
    await submitText('  이어서 답합니다\n')
    await vi.waitFor(() => expect(send).toHaveBeenCalledTimes(1))
    const [path, init] = send.mock.calls[0]!
    expect(path).toBe('/api/v1/keepers/discord/reply')
    const body = JSON.parse(init.body as string)
    expect(body).toEqual({
      expected_workspace: workspace,
      operation_id: expect.any(String),
      keeper_name: target.keeperName,
      chat_id: target.chatId,
      content: '  이어서 답합니다\n',
    })
    expect(Object.values(sessionStorage).map(value => JSON.parse(value))).toEqual([
      { id: body.operation_id, fingerprint: expect.stringMatching(/^[0-9a-f]{64}$/) },
    ])

    act(() => render(null, container))
    await mount()
    await vi.waitFor(() => expect(send).toHaveBeenCalledTimes(2))
    await vi.waitFor(() => expect(container.querySelector('a[href$="/400"]')).not.toBeNull())
    const [statusPath, statusInit] = send.mock.calls[1]!
    expect(statusPath).toBe('/api/v1/keepers/discord/reply/status')
    expect(JSON.parse(statusInit.body as string)).toEqual({
      expected_workspace: workspace,
      operation_id: body.operation_id,
    })
  })

  it('reuses the operation and content after an uncertain submission', async () => {
    const send = vi.fn(async (_path: string, init: RequestInit) => {
      if (send.mock.calls.length === 1) throw new Error('connection lost')
      const { operation_id } = JSON.parse(init.body as string)
      return json(receipt(operation_id, { state: 'outcome_unknown' }), 200)
    })
    vi.stubGlobal('fetch', send)
    await mount()
    await submitText('확인해 주세요.')
    await vi.waitFor(() => expect(container.querySelector('[role="alert"]')?.textContent).toContain('connection lost'))
    expect(send).toHaveBeenCalledTimes(1)
    await act(async () => { button('같은 요청 다시 보내기').click() })
    await vi.waitFor(() => expect(container.textContent).toContain('Discord 전송 여부를 확인할 수 없습니다.'))
    expect(send).toHaveBeenCalledTimes(2)
    expect(send.mock.calls[1]?.[1].body).toEqual(send.mock.calls[0]?.[1].body)
  })

  it('re-enters exact text with the same ID after a reload and an unobserved admission', async () => {
    const send = vi.fn(async (path: string, init: RequestInit) => {
      if (send.mock.calls.length === 1) throw new Error('offline before admission')
      if (path.endsWith('/status')) return json({ error: 'receipt missing' }, 404)
      const { operation_id } = JSON.parse(init.body as string)
      return json(receipt(operation_id, { state: 'delivered', message_id: '401' }), 200)
    })
    vi.stubGlobal('fetch', send)
    await mount()
    await submitText('이 답장을 보냅니다.')
    await vi.waitFor(() => expect(container.textContent).toContain('offline before admission'))
    act(() => render(null, container))
    await mount()
    await vi.waitFor(() => expect(container.querySelector('textarea')).not.toBeNull())
    await submitText('다른 답장', '같은 작업으로 다시 보내기')
    await vi.waitFor(() => expect(container.textContent).toContain('처음 입력한 답장과 내용이 다릅니다.'))
    expect(send).toHaveBeenCalledTimes(2)

    await submitText('이 답장을 보냅니다.', '같은 작업으로 다시 보내기')
    await vi.waitFor(() => expect(container.querySelector('a[href$="/401"]')).not.toBeNull())
    expect(send).toHaveBeenCalledTimes(3)
    expect(send.mock.calls[2]?.[1].body).toEqual(send.mock.calls[0]?.[1].body)
  })
})
