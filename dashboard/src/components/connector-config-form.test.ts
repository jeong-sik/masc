// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  ConnectorConfigToggle,
  ConnectorConfigForm,
  resetConnectorConfigState,
  _testParseSchema,
  _testBuildEnvBlock,
  _testIsSensitive,
  _testGetFieldHint,
} from './connector-config-form'

const flushUi = async () => {
  // Three Promise.resolve cycles cover: schema fetch → JSON parse →
  // current-values fetch → JSON parse → setEntry → render.
  await Promise.resolve()
  await Promise.resolve()
  await Promise.resolve()
  await Promise.resolve()
}

describe('connector-config-form pure helpers', () => {
  it('parseSchema sorts required fields first then alpha', () => {
    const fields = _testParseSchema({
      ok: true,
      id: 'discord',
      schema: {
        properties: {
          GATE_BASE_URL: { type: 'string', default: 'http://localhost:8935' },
          DISCORD_BOT_TOKEN: { type: 'string', title: 'Discord Bot Token' },
          GATE_TIMEOUT_SEC: { type: 'integer', default: 120 },
        },
        required: ['DISCORD_BOT_TOKEN'],
      },
    })

    expect(fields[0]?.name).toBe('DISCORD_BOT_TOKEN')
    expect(fields[0]?.required).toBe(true)
    expect(fields.slice(1).map(f => f.name)).toEqual(['GATE_BASE_URL', 'GATE_TIMEOUT_SEC'])
  })

  it('buildEnvBlock skips empty optional fields but keeps required ones', () => {
    const fields = _testParseSchema({
      ok: true,
      id: 'discord',
      schema: {
        properties: {
          DISCORD_BOT_TOKEN: { type: 'string' },
          GATE_TIMEOUT_SEC: { type: 'integer', default: 120 },
        },
        required: ['DISCORD_BOT_TOKEN'],
      },
    })
    const block = _testBuildEnvBlock(fields, {
      DISCORD_BOT_TOKEN: '',
      GATE_TIMEOUT_SEC: '',
    })

    expect(block).toContain('DISCORD_BOT_TOKEN=')
    expect(block).not.toContain('GATE_TIMEOUT_SEC')
  })

  it('getFieldHint returns where-to-find guidance for known credentials, null otherwise', () => {
    const discord = _testGetFieldHint('DISCORD_BOT_TOKEN')
    expect(discord?.where).toContain('Discord Developer Portal')
    expect(discord?.url).toBe('https://discord.com/developers/applications')

    const slack = _testGetFieldHint('SLACK_BOT_TOKEN')
    expect(slack?.where).toContain('xoxb')

    const telegram = _testGetFieldHint('TELEGRAM_BOT_TOKEN')
    expect(telegram?.url).toBe('https://t.me/BotFather')

    // Unknown fields must not fabricate hints.
    expect(_testGetFieldHint('GATE_BASE_URL')).toBeNull()
    expect(_testGetFieldHint('STATUS_HEARTBEAT_SEC')).toBeNull()
  })

  it('isSensitive flags token/secret/password/api_key variants', () => {
    expect(_testIsSensitive('DISCORD_BOT_TOKEN')).toBe(true)
    expect(_testIsSensitive('CLIENT_SECRET')).toBe(true)
    expect(_testIsSensitive('PASSWORD')).toBe(true)
    expect(_testIsSensitive('API_KEY')).toBe(true)
    expect(_testIsSensitive('api-key')).toBe(true)
    expect(_testIsSensitive('GATE_BASE_URL')).toBe(false)
    expect(_testIsSensitive('STATUS_HEARTBEAT_SEC')).toBe(false)
  })
})

describe('ConnectorConfigToggle', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    resetConnectorConfigState()
  })
  afterEach(() => {
    document.body.removeChild(container)
    vi.restoreAllMocks()
  })

  it('renders ⚙ Config button with aria-expanded=false initially', () => {
    render(html`<${ConnectorConfigToggle} connectorId="discord" />`, container)
    const btn = container.querySelector('button')
    expect(btn).toBeTruthy()
    expect(btn?.getAttribute('aria-expanded')).toBe('false')
    expect(btn?.textContent).toContain('Config')
  })

  it('flips aria-expanded to true when clicked', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ ok: true, id: 'discord', schema: { properties: {}, required: [] } }), {
        status: 200,
      }),
    )
    render(html`<${ConnectorConfigToggle} connectorId="discord" />`, container)
    const btn = container.querySelector('button')!
    btn.click()
    await flushUi()
    expect(btn.getAttribute('aria-expanded')).toBe('true')
    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/sidecar/schema?name=discord'),
      expect.any(Object),
    )
  })
})

describe('ConnectorConfigForm', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    resetConnectorConfigState()
  })
  afterEach(() => {
    document.body.removeChild(container)
    vi.restoreAllMocks()
  })

  it('renders nothing while closed', () => {
    render(html`<${ConnectorConfigForm} connectorId="discord" />`, container)
    expect(container.textContent?.trim()).toBe('')
  })

  it('Save button stays disabled while a required field is empty', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          id: 'discord',
          schema: {
            properties: {
              DISCORD_BOT_TOKEN: { type: 'string' },
            },
            required: ['DISCORD_BOT_TOKEN'],
          },
        }),
        { status: 200 },
      ),
    )
    render(html`
      <div>
        <${ConnectorConfigToggle} connectorId="discord" />
        <${ConnectorConfigForm} connectorId="discord" />
      </div>
    `, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    await flushUi()

    const buttons = Array.from(container.querySelectorAll('button'))
    const saveBtn = buttons.find(b => b.textContent?.trim() === 'Save') as HTMLButtonElement | undefined
    expect(saveBtn).toBeTruthy()
    expect(saveBtn?.disabled).toBe(true)
    // Required field surfaces in the form (label) so operator can see what's missing.
    expect(container.textContent).toContain('DISCORD_BOT_TOKEN')
  })

  it('Save button POSTs to /api/v1/sidecar/config when required field is filled', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
      // 1) schema GET
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            id: 'discord',
            schema: {
              properties: {
                GATE_BASE_URL: { type: 'string', default: 'http://localhost:8935' },
              },
              required: [],
            },
          }),
          { status: 200 },
        ),
      )
      // 2) current-values GET (no file yet)
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ ok: true, exists: false, values: {} }), { status: 200 }),
      )
      // 3) save POST
      .mockResolvedValueOnce(
        new Response(JSON.stringify({ ok: true, id: 'discord', written_fields: 1 }), { status: 200 }),
      )

    render(html`
      <div>
        <${ConnectorConfigToggle} connectorId="discord" />
        <${ConnectorConfigForm} connectorId="discord" />
      </div>
    `, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    await flushUi()

    const saveBtn = Array.from(container.querySelectorAll('button'))
      .find(b => b.textContent?.trim() === 'Save') as HTMLButtonElement
    expect(saveBtn.disabled).toBe(false)
    saveBtn.click()
    await flushUi()
    await flushUi()

    expect(fetchSpy).toHaveBeenCalledTimes(3)
    const saveCall = fetchSpy.mock.calls[2]
    expect(saveCall?.[0]).toContain('/api/v1/sidecar/config?name=discord')
    expect(saveCall?.[1]?.method).toBe('POST')
    expect(saveCall?.[1]?.body).toContain('GATE_BASE_URL')
  })

  it('after Save success, restart button POSTs stop then start in order', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
      // 1) schema GET
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            id: 'discord',
            schema: {
              properties: { GATE_BASE_URL: { type: 'string', default: 'http://localhost:8935' } },
              required: [],
            },
          }),
          { status: 200 },
        ),
      )
      // 2) current-values GET
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true, exists: false, values: {} }), { status: 200 }))
      // 3) save POST
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true }), { status: 200 }))
      // 4) stop POST
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true, signaled: true }), { status: 200 }))
      // 5) start POST
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true }), { status: 202 }))

    render(html`
      <div>
        <${ConnectorConfigToggle} connectorId="discord" />
        <${ConnectorConfigForm} connectorId="discord" />
      </div>
    `, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    await flushUi()

    const saveBtn = Array.from(container.querySelectorAll('button'))
      .find(b => b.textContent?.trim() === 'Save') as HTMLButtonElement
    saveBtn.click()
    await flushUi()
    await flushUi()

    const restartBtn = Array.from(container.querySelectorAll('button'))
      .find(b => b.textContent?.includes('재시작')) as HTMLButtonElement | undefined
    expect(restartBtn).toBeTruthy()
    restartBtn!.click()
    // stop completes immediately, then 800ms delay, then start. Wait past it.
    await new Promise(r => setTimeout(r, 1000))
    await flushUi()

    expect(fetchSpy).toHaveBeenCalledTimes(5)
    expect(fetchSpy.mock.calls[3]?.[0]).toContain('/api/v1/sidecar/stop?name=discord')
    expect(fetchSpy.mock.calls[4]?.[0]).toContain('/api/v1/sidecar/start?name=discord')
  })

  it('renders where-to-find hint block for DISCORD_BOT_TOKEN when schema contains it', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          id: 'discord',
          schema: {
            properties: {
              DISCORD_BOT_TOKEN: { type: 'string' },
              GATE_BASE_URL: { type: 'string', default: 'http://localhost:8935' },
            },
            required: ['DISCORD_BOT_TOKEN'],
          },
        }),
        { status: 200 },
      ),
    )
    render(html`
      <div>
        <${ConnectorConfigToggle} connectorId="discord" />
        <${ConnectorConfigForm} connectorId="discord" />
      </div>
    `, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    await flushUi()

    const hint = container.querySelector('[data-field-hint="DISCORD_BOT_TOKEN"]')
    expect(hint).toBeTruthy()
    expect(hint?.textContent).toContain('Discord Developer Portal')
    // Unknown fields stay clean — hint must not leak to GATE_BASE_URL.
    expect(container.querySelector('[data-field-hint="GATE_BASE_URL"]')).toBeNull()
  })


  it('auto-restart OFF by default; Save button label stays "Save"; single POST on click', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            id: 'discord',
            schema: { properties: { GATE_BASE_URL: { type: 'string', default: 'http://x' } }, required: [] },
          }),
          { status: 200 },
        ),
      )
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true, exists: false, values: {} }), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true }), { status: 200 })) // config POST

    render(html`
      <div>
        <${ConnectorConfigToggle} connectorId="discord" />
        <${ConnectorConfigForm} connectorId="discord" />
      </div>
    `, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    await flushUi()

    const toggle = container.querySelector('[data-auto-restart-toggle]') as HTMLInputElement
    expect(toggle).toBeTruthy()
    expect(toggle.checked).toBe(false)

    const saveBtn = Array.from(container.querySelectorAll('button'))
      .find(b => b.textContent?.trim() === 'Save') as HTMLButtonElement
    expect(saveBtn).toBeTruthy()
    saveBtn.click()
    await flushUi()
    await flushUi()
    // schema + values + config POST, no stop/start
    expect(fetchSpy).toHaveBeenCalledTimes(3)
  })

  it('auto-restart ON: Save button becomes "Save & Apply" and chains config→stop→start', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            id: 'discord',
            schema: { properties: { GATE_BASE_URL: { type: 'string', default: 'http://x' } }, required: [] },
          }),
          { status: 200 },
        ),
      )
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true, exists: false, values: {} }), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true }), { status: 200 })) // config
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true, signaled: true }), { status: 200 })) // stop
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true }), { status: 202 })) // start

    render(html`
      <div>
        <${ConnectorConfigToggle} connectorId="discord" />
        <${ConnectorConfigForm} connectorId="discord" />
      </div>
    `, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    await flushUi()

    const toggle = container.querySelector('[data-auto-restart-toggle]') as HTMLInputElement
    toggle.click()
    await flushUi()

    const btn = Array.from(container.querySelectorAll('button'))
      .find(b => b.textContent?.trim() === 'Save & Apply') as HTMLButtonElement
    expect(btn).toBeTruthy()
    btn.click()
    await new Promise(r => setTimeout(r, 1000))
    await flushUi()

    expect(fetchSpy).toHaveBeenCalledTimes(5)
    const urls = fetchSpy.mock.calls.slice(2).map(c => String(c[0]))
    expect(urls[0]).toContain('/api/v1/sidecar/config?name=discord')
    expect(urls[1]).toContain('/api/v1/sidecar/stop?name=discord')
    expect(urls[2]).toContain('/api/v1/sidecar/start?name=discord')
  })

  it('auto-restart soft-stop: if stop rejects, start still fires', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            ok: true,
            id: 'discord',
            schema: { properties: { GATE_BASE_URL: { type: 'string', default: 'http://x' } }, required: [] },
          }),
          { status: 200 },
        ),
      )
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true, exists: false, values: {} }), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true }), { status: 200 })) // config
      .mockRejectedValueOnce(new Error('stop refused')) // stop rejects
      .mockResolvedValueOnce(new Response(JSON.stringify({ ok: true }), { status: 202 })) // start still fires

    render(html`
      <div>
        <${ConnectorConfigToggle} connectorId="discord" />
        <${ConnectorConfigForm} connectorId="discord" />
      </div>
    `, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    await flushUi()

    ;(container.querySelector('[data-auto-restart-toggle]') as HTMLInputElement).click()
    await flushUi()
    const btn = Array.from(container.querySelectorAll('button'))
      .find(b => b.textContent?.trim() === 'Save & Apply') as HTMLButtonElement
    btn.click()
    await new Promise(r => setTimeout(r, 1000))
    await flushUi()

    expect(fetchSpy).toHaveBeenCalledTimes(5)
    const last = fetchSpy.mock.calls.slice(-2).map(c => String(c[0]))
    expect(last[0]).toContain('/sidecar/stop')
    expect(last[1]).toContain('/sidecar/start')
  })

  it('after toggle + fetch, renders required field marker and password input for token', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify({
          ok: true,
          id: 'discord',
          schema: {
            properties: {
              DISCORD_BOT_TOKEN: { type: 'string', title: 'Discord Bot Token' },
              GATE_BASE_URL: { type: 'string', default: 'http://localhost:8935' },
            },
            required: ['DISCORD_BOT_TOKEN'],
          },
        }),
        { status: 200 },
      ),
    )

    render(html`
      <div>
        <${ConnectorConfigToggle} connectorId="discord" />
        <${ConnectorConfigForm} connectorId="discord" />
      </div>
    `, container)
    const toggle = container.querySelector('button[aria-expanded]') as HTMLButtonElement
    toggle.click()
    await flushUi()
    await flushUi()

    expect(container.textContent).toContain('DISCORD_BOT_TOKEN')
    expect(container.textContent).toContain('GATE_BASE_URL')
    expect(container.textContent).toContain('1 required')
    const tokenInput = container.querySelector('input[type="password"]')
    expect(tokenInput).toBeTruthy()
  })
})
