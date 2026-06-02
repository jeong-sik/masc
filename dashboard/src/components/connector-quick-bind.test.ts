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

    const bindCall = fetchSpy.mock.calls.find(c => String(c[0]).includes('/api/v1/gate/connector/bind'))
    expect(bindCall).toBeTruthy()
    const body = bindCall?.[1]?.body as string
    expect(body).toContain('"channel_id":"C09TK9L4DV4"')
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
