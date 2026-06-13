// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  QuickBindForm,
  resetQuickBindState,
  channelIdPlaceholder,
} from './connector-quick-bind'
import type { GateKeeperInfo } from '../api/gate'

const mkKeeper = (name: string): GateKeeperInfo => ({ name } as GateKeeperInfo)

const flushUi = async () => {
  for (let i = 0; i < 4; i++) await Promise.resolve()
}

describe('QuickBindForm', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    resetQuickBindState()
  })
  afterEach(() => {
    document.body.removeChild(container)
    vi.restoreAllMocks()
  })

  it('renders nothing when there are no keepers', () => {
    render(html`<${QuickBindForm} connectorId="discord" keepers=${[]} />`, container)
    expect(container.querySelector('[data-quick-bind]')).toBeNull()
  })

  it('renders a channel input + keeper select + Bind button', () => {
    render(html`<${QuickBindForm} connectorId="discord" keepers=${[mkKeeper('kpr-a'), mkKeeper('kpr-b')]} />`, container)
    const form = container.querySelector('[data-quick-bind="discord"]')!
    expect(form.querySelector('input[placeholder*="1234567890"]')).toBeTruthy()
    const options = form.querySelectorAll('select option')
    expect(options.length).toBe(2)
    expect(options[0]!.textContent).toBe('kpr-a')
    expect(options[1]!.textContent).toBe('kpr-b')
    const submit = Array.from(form.querySelectorAll('button')).find(b => b.textContent?.includes('Bind'))
    expect(submit).toBeTruthy()
  })

  it('Bind button disabled while channel ID is empty', () => {
    render(html`<${QuickBindForm} connectorId="discord" keepers=${[mkKeeper('kpr-a')]} />`, container)
    const form = container.querySelector('[data-quick-bind="discord"]')!
    const submit = Array.from(form.querySelectorAll('button')).find(b => b.textContent?.includes('Bind')) as HTMLButtonElement
    expect(submit.disabled).toBe(true)
  })

  it('POSTs to /api/v1/gate/connector/bind when channel is filled', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ ok: true }), { status: 200 }),
    )
    render(html`<${QuickBindForm} connectorId="discord" keepers=${[mkKeeper('kpr-a')]} />`, container)
    const form = container.querySelector('[data-quick-bind="discord"]')!
    const input = form.querySelector('input') as HTMLInputElement
    input.value = '1234567890'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()

    const submit = Array.from(form.querySelectorAll('button')).find(b => b.textContent?.includes('Bind')) as HTMLButtonElement
    submit.click()
    await flushUi()

    const calls = fetchSpy.mock.calls
    const bindCall = calls.find(c => String(c[0]).includes('/api/v1/gate/connector/bind'))
    expect(bindCall).toBeTruthy()
    expect(String(bindCall?.[0])).toContain('name=discord')
    expect(bindCall?.[1]?.method?.toUpperCase()).toBe('POST')
    const body = bindCall?.[1]?.body as string
    expect(body).toContain('"channel_id":"1234567890"')
    expect(body).toContain('"keeper_name":"kpr-a"')
  })

  it('pressing Enter in the channel input submits the bind (no button click needed)', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ ok: true }), { status: 200 }),
    )
    render(html`<${QuickBindForm} connectorId="slack" keepers=${[mkKeeper('kpr-a')]} />`, container)
    const form = container.querySelector('[data-quick-bind="slack"]')!
    const input = form.querySelector('input') as HTMLInputElement
    input.value = 'C09TK9L4DV4'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()

    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    await flushUi()

    const bindCall = fetchSpy.mock.calls.find(c =>
      String(c[0]).includes('/api/v1/gate/connector/bind') && String(c[0]).includes('name=slack'),
    )
    expect(bindCall).toBeTruthy()
    const body = bindCall?.[1]?.body as string
    expect(body).toContain('"channel_id":"C09TK9L4DV4"')
  })

  it('bind FAILURE preserves the typed channel ID and re-enables the form (regression: draft wiped on failure)', async () => {
    // Local flag instead of fetchSpy.mock.calls: spyOn(globalThis, 'fetch')
    // accumulates call history across tests in this file, so only state
    // recorded by THIS implementation is trustworthy. Fresh Response per
    // call — the body is single-use.
    let bindRequested = false
    vi.spyOn(globalThis, 'fetch').mockImplementation((url) => {
      if (String(url).includes('/api/v1/gate/connector/bind')) bindRequested = true
      return Promise.resolve(new Response(JSON.stringify({ error: 'unknown keeper' }), { status: 404 }))
    })
    render(html`<${QuickBindForm} connectorId="discord" keepers=${[mkKeeper('kpr-a')]} />`, container)
    const form = container.querySelector('[data-quick-bind="discord"]')!
    const input = form.querySelector('input') as HTMLInputElement
    input.value = '1234567890123456789'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()

    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    await vi.waitFor(() => { expect(bindRequested).toBe(true) })
    // The failure path (error-body read -> toast -> setEntry) is
    // microtask-chained; two macrotask hops guarantee it has settled.
    await new Promise(resolve => setTimeout(resolve, 0))
    await new Promise(resolve => setTimeout(resolve, 0))
    await flushUi()

    const btn = Array.from(form.querySelectorAll('button')).find(b => b.textContent?.includes('Bind')) as HTMLButtonElement
    // 'Bind' (not '연결 중...') + enabled proves the submitting cycle
    // completed — guards against asserting the draft before the wipe
    // would have happened.
    expect(btn).toBeTruthy()
    expect(btn.disabled).toBe(false)
    expect(input.value).toBe('1234567890123456789')
  })

  it('bind SUCCESS clears the channel draft for the next bind', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ ok: true }), { status: 200 }),
    )
    render(html`<${QuickBindForm} connectorId="discord" keepers=${[mkKeeper('kpr-a')]} />`, container)
    const form = container.querySelector('[data-quick-bind="discord"]')!
    const input = form.querySelector('input') as HTMLInputElement
    input.value = '1234567890123456789'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()

    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    await vi.waitFor(() => { expect(input.value).toBe('') })
  })

  it('a second Enter while a bind is in flight does not fire a second POST (regression: Enter bypassed the submitting guard)', async () => {
    // Count via the implementation, not fetchSpy.mock.calls — spyOn call
    // history accumulates across tests in this file and would also count
    // earlier tests' bind POSTs.
    const deferred: Array<(r: Response) => void> = []
    let bindPosts = 0
    vi.spyOn(globalThis, 'fetch').mockImplementation((url) => {
      if (String(url).includes('/api/v1/gate/connector/bind')) bindPosts += 1
      return new Promise<Response>(resolve => { deferred.push(resolve) })
    })
    render(html`<${QuickBindForm} connectorId="discord" keepers=${[mkKeeper('kpr-a')]} />`, container)
    const form = container.querySelector('[data-quick-bind="discord"]')!
    const input = form.querySelector('input') as HTMLInputElement
    input.value = '1234567890123456789'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushUi()

    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    await flushUi()
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    await flushUi()

    expect(bindPosts).toBe(1)

    // Settle the in-flight bind so it cannot leak into the next test.
    deferred.forEach(resolve => { resolve(new Response(JSON.stringify({ ok: true }), { status: 200 })) })
    await flushUi()
  })

  it('renders the connector-specific placeholder (Slack shows C-prefix example, not Discord snowflake)', () => {
    render(html`<${QuickBindForm} connectorId="slack" keepers=${[mkKeeper('kpr-a')]} />`, container)
    const input = container.querySelector('[data-quick-bind="slack"] input') as HTMLInputElement
    const placeholder = input.getAttribute('placeholder') ?? ''
    expect(placeholder).toContain('C0123ABCD')
    expect(placeholder).not.toContain('18-19 digit')
  })
})

describe('channelIdPlaceholder', () => {
  it('discord placeholder is an 18-19 digit snowflake hint', () => {
    const p = channelIdPlaceholder('discord')
    expect(p).toMatch(/18-19 digit/)
    expect(p).toMatch(/\d{18,19}/)
  })

  it('slack placeholder includes C-prefix and #-name variants', () => {
    const p = channelIdPlaceholder('slack')
    expect(p).toContain('C0123ABCD')
    expect(p).toContain('#general')
  })

  it('telegram placeholder includes -100 format and @username variant', () => {
    const p = channelIdPlaceholder('telegram')
    expect(p).toContain('-100')
    expect(p).toContain('@channel_name')
  })

  it('imessage placeholder shows phone + group id examples', () => {
    const p = channelIdPlaceholder('imessage')
    expect(p).toContain('+1')
    expect(p).toContain('group id')
  })

  it('unknown connector falls through to a neutral example', () => {
    expect(channelIdPlaceholder('xyz-unknown')).toContain('1234567890')
  })
})
