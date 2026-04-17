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
} from './connector-config-form'

const flushUi = async () => {
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

    expect(fetchSpy).toHaveBeenCalledTimes(2)
    const lastCall = fetchSpy.mock.calls[1]
    expect(lastCall?.[0]).toContain('/api/v1/sidecar/config?name=discord')
    expect(lastCall?.[1]?.method).toBe('POST')
    expect(lastCall?.[1]?.body).toContain('GATE_BASE_URL')
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
