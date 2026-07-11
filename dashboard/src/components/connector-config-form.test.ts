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

// Mock api/core — the component uses get/post instead of raw fetch,
// so we intercept at the module boundary for reliable test control.
vi.mock('../api/core', () => ({
  get: vi.fn(),
  post: vi.fn(),
}))

import { get, post } from '../api/core'

const mockedGet = vi.mocked(get)
const mockedPost = vi.mocked(post)

const flushUi = async () => {
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
    mockedGet.mockReset()
    mockedPost.mockReset()
  })

  it('renders ⚙ Config button with aria-expanded=false initially', () => {
    render(html`<${ConnectorConfigToggle} connectorId="discord" />`, container)
    const btn = container.querySelector('button')
    expect(btn).toBeTruthy()
    expect(btn?.getAttribute('aria-expanded')).toBe('false')
    expect(btn?.textContent).toContain('Config')
  })

  it('flips aria-expanded to true when clicked', async () => {
    // Uses telegram (a sidecar connector) — slack is now in-process (no schema fetch).
    mockedGet.mockResolvedValue({ ok: true, id: 'telegram', schema: { properties: {}, required: [] } })
    render(html`<${ConnectorConfigToggle} connectorId="telegram" />`, container)
    const btn = container.querySelector('button')!
    btn.click()
    await flushUi()
    expect(btn.getAttribute('aria-expanded')).toBe('true')
    expect(mockedGet).toHaveBeenCalledWith(
      expect.stringContaining('/api/v1/sidecar/schema?name=telegram'),
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
    mockedGet.mockReset()
    mockedPost.mockReset()
  })

  it('renders nothing while closed', () => {
    render(html`<${ConnectorConfigForm} connectorId="discord" />`, container)
    expect(container.textContent?.trim()).toBe('')
  })

  it('renders in-process Discord config guidance without sidecar API calls', async () => {
    render(html`
      <div>
        <${ConnectorConfigToggle} connectorId="discord" />
        <${ConnectorConfigForm} connectorId="discord" />
      </div>
    `, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()

    expect(mockedGet).not.toHaveBeenCalled()
    expect(mockedPost).not.toHaveBeenCalled()
    const panel = container.querySelector('[data-in-process-config-panel]')
    expect(panel).toBeTruthy()
    expect(container.querySelector('.v2-connector-config-form')).not.toBeNull()
    expect(panel?.textContent).toContain('server in-process')
    expect(panel?.textContent).toContain('DISCORD_BOT_TOKEN')
    expect(panel?.querySelector('a')?.classList.contains('v2-mobile-operator-target')).toBe(true)
    expect(panel?.textContent).not.toContain('Save')
    expect(panel?.textContent).not.toContain('자동 재시작')
  })

  it('Save button stays disabled while a required field is empty', async () => {
    // telegram (sidecar) stands in for a schema-driven connector; slack is in-process.
    mockedGet.mockResolvedValue({
      ok: true,
      id: 'telegram',
      schema: {
        properties: {
          TELEGRAM_BOT_TOKEN: { type: 'string' },
        },
        required: ['TELEGRAM_BOT_TOKEN'],
      },
    })
    render(html`
      <div>
        <${ConnectorConfigToggle} connectorId="telegram" />
        <${ConnectorConfigForm} connectorId="telegram" />
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
    expect(container.textContent).toContain('TELEGRAM_BOT_TOKEN')
    expect(container.querySelector('[data-field-hint="TELEGRAM_BOT_TOKEN"] a')?.classList.contains('v2-mobile-operator-target')).toBe(true)
  })

  it('Save button POSTs to /api/v1/sidecar/config when required field is filled', async () => {
    mockedGet
      // 1) schema GET
      .mockResolvedValueOnce({
        ok: true,
        id: 'telegram',
        schema: {
          properties: {
            GATE_BASE_URL: { type: 'string', default: 'http://localhost:8935' },
          },
          required: [],
        },
      })
      // 2) current-values GET (no file yet)
      .mockResolvedValueOnce({ ok: true, exists: false, values: {} })
    // 3) save POST
    mockedPost.mockResolvedValueOnce({ ok: true, id: 'telegram', written_fields: 1 })

    render(html`
      <div>
        <${ConnectorConfigToggle} connectorId="telegram" />
        <${ConnectorConfigForm} connectorId="telegram" />
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

    expect(mockedGet).toHaveBeenCalledTimes(2)
    expect(mockedPost).toHaveBeenCalledTimes(1)
    const saveCall = mockedPost.mock.calls[0]
    expect(saveCall?.[0]).toContain('/api/v1/sidecar/config?name=telegram')
    expect(JSON.stringify(saveCall?.[1])).toContain('GATE_BASE_URL')
  })

  it('after Save success, restart button POSTs stop then start in order', async () => {
    mockedGet
      // 1) schema GET
      .mockResolvedValueOnce({
        ok: true,
        id: 'telegram',
        schema: {
          properties: { GATE_BASE_URL: { type: 'string', default: 'http://localhost:8935' } },
          required: [],
        },
      })
      // 2) current-values GET
      .mockResolvedValueOnce({ ok: true, exists: false, values: {} })
    mockedPost
      // 3) save POST
      .mockResolvedValueOnce({ ok: true })
      // 4) stop POST
      .mockResolvedValueOnce({ ok: true, signaled: true })
      // 5) start POST
      .mockResolvedValueOnce({ ok: true })

    render(html`
      <div>
        <${ConnectorConfigToggle} connectorId="telegram" />
        <${ConnectorConfigForm} connectorId="telegram" />
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

    expect(mockedGet).toHaveBeenCalledTimes(2)
    expect(mockedPost).toHaveBeenCalledTimes(3)
    expect(mockedPost.mock.calls[1]?.[0]).toContain('/api/v1/sidecar/stop?name=telegram')
    expect(mockedPost.mock.calls[2]?.[0]).toContain('/api/v1/sidecar/start?name=telegram')
  })

  it('renders in-process Slack config guidance (both tokens) without sidecar API calls', async () => {
    // Slack is an in-process connector (RFC-0317): the config panel shows the
    // Socket Mode app token + outbound bot token and calls no sidecar API.
    render(html`
      <div>
        <${ConnectorConfigToggle} connectorId="slack" />
        <${ConnectorConfigForm} connectorId="slack" />
      </div>
    `, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()

    expect(mockedGet).not.toHaveBeenCalled()
    expect(mockedPost).not.toHaveBeenCalled()
    const panel = container.querySelector('[data-in-process-config-panel]')
    expect(panel).toBeTruthy()
    expect(panel?.textContent).toContain('server in-process')
    expect(panel?.textContent).toContain('SLACK_APP_TOKEN')
    expect(panel?.textContent).toContain('SLACK_BOT_TOKEN')
    expect(panel?.textContent).not.toContain('Save')
    // Both credentials get a where-to-find hint card; unknown fields stay clean.
    const appHint = container.querySelector('[data-field-hint="SLACK_APP_TOKEN"]')
    expect(appHint).toBeTruthy()
    expect(appHint?.textContent).toContain('Slack App')
    expect(container.querySelector('[data-field-hint="SLACK_BOT_TOKEN"]')).toBeTruthy()
    expect(container.querySelector('[data-field-hint="GATE_BASE_URL"]')).toBeNull()
  })


  it('auto-restart OFF by default; Save button label stays "Save"; single POST on click', async () => {
    mockedGet
      .mockResolvedValueOnce({
        ok: true,
        id: 'telegram',
        schema: { properties: { GATE_BASE_URL: { type: 'string', default: 'http://x' } }, required: [] },
      })
      .mockResolvedValueOnce({ ok: true, exists: false, values: {} })
    mockedPost.mockResolvedValueOnce({ ok: true })

    render(html`
      <div>
        <${ConnectorConfigToggle} connectorId="telegram" />
        <${ConnectorConfigForm} connectorId="telegram" />
      </div>
    `, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    await flushUi()

    const toggle = container.querySelector('[data-testid="auto-restart-toggle"]') as HTMLInputElement
    expect(toggle).toBeTruthy()
    expect(toggle.checked).toBe(false)

    const saveBtn = Array.from(container.querySelectorAll('button'))
      .find(b => b.textContent?.trim() === 'Save') as HTMLButtonElement
    expect(saveBtn).toBeTruthy()
    saveBtn.click()
    await flushUi()
    await flushUi()
    // schema + values GET + config POST, no stop/start
    expect(mockedGet).toHaveBeenCalledTimes(2)
    expect(mockedPost).toHaveBeenCalledTimes(1)
  })

  it('auto-restart ON: Save button becomes "Save & Apply" and chains config→stop→start', async () => {
    mockedGet
      .mockResolvedValueOnce({
        ok: true,
        id: 'telegram',
        schema: { properties: { GATE_BASE_URL: { type: 'string', default: 'http://x' } }, required: [] },
      })
      .mockResolvedValueOnce({ ok: true, exists: false, values: {} })
    mockedPost
      .mockResolvedValueOnce({ ok: true })
      .mockResolvedValueOnce({ ok: true, signaled: true })
      .mockResolvedValueOnce({ ok: true })

    render(html`
      <div>
        <${ConnectorConfigToggle} connectorId="telegram" />
        <${ConnectorConfigForm} connectorId="telegram" />
      </div>
    `, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    await flushUi()

    const toggle = container.querySelector('[data-testid="auto-restart-toggle"]') as HTMLInputElement
    toggle.click()
    await flushUi()

    const btn = Array.from(container.querySelectorAll('button'))
      .find(b => b.textContent?.trim() === 'Save & Apply') as HTMLButtonElement
    expect(btn).toBeTruthy()
    btn.click()
    await new Promise(r => setTimeout(r, 1000))
    await flushUi()

    expect(mockedGet).toHaveBeenCalledTimes(2)
    expect(mockedPost).toHaveBeenCalledTimes(3)
    expect(mockedPost.mock.calls[0]?.[0]).toContain('/api/v1/sidecar/config?name=telegram')
    expect(mockedPost.mock.calls[1]?.[0]).toContain('/api/v1/sidecar/stop?name=telegram')
    expect(mockedPost.mock.calls[2]?.[0]).toContain('/api/v1/sidecar/start?name=telegram')
  })

  it('auto-restart soft-stop: if stop rejects, start still fires', async () => {
    mockedGet
      .mockResolvedValueOnce({
        ok: true,
        id: 'telegram',
        schema: { properties: { GATE_BASE_URL: { type: 'string', default: 'http://x' } }, required: [] },
      })
      .mockResolvedValueOnce({ ok: true, exists: false, values: {} })
    mockedPost
      .mockResolvedValueOnce({ ok: true })
      .mockRejectedValueOnce(new Error('stop refused'))
      .mockResolvedValueOnce({ ok: true })

    render(html`
      <div>
        <${ConnectorConfigToggle} connectorId="telegram" />
        <${ConnectorConfigForm} connectorId="telegram" />
      </div>
    `, container)
    ;(container.querySelector('button[aria-expanded]') as HTMLButtonElement).click()
    await flushUi()
    await flushUi()

    ;(container.querySelector('[data-testid="auto-restart-toggle"]') as HTMLInputElement).click()
    await flushUi()
    const btn = Array.from(container.querySelectorAll('button'))
      .find(b => b.textContent?.trim() === 'Save & Apply') as HTMLButtonElement
    btn.click()
    await new Promise(r => setTimeout(r, 1000))
    await flushUi()

    expect(mockedGet).toHaveBeenCalledTimes(2)
    expect(mockedPost).toHaveBeenCalledTimes(3)
    expect(mockedPost.mock.calls[1]?.[0]).toContain('/sidecar/stop')
    expect(mockedPost.mock.calls[2]?.[0]).toContain('/sidecar/start')
  })

  it('after toggle + fetch, renders required field marker and password input for token', async () => {
    mockedGet.mockResolvedValue({
      ok: true,
      id: 'telegram',
      schema: {
        properties: {
          TELEGRAM_BOT_TOKEN: { type: 'string', title: 'Telegram Bot Token' },
          GATE_BASE_URL: { type: 'string', default: 'http://localhost:8935' },
        },
        required: ['TELEGRAM_BOT_TOKEN'],
      },
    })

    render(html`
      <div>
        <${ConnectorConfigToggle} connectorId="telegram" />
        <${ConnectorConfigForm} connectorId="telegram" />
      </div>
    `, container)
    const toggle = container.querySelector('button[aria-expanded]') as HTMLButtonElement
    toggle.click()
    await flushUi()
    await flushUi()

    expect(container.textContent).toContain('TELEGRAM_BOT_TOKEN')
    expect(container.textContent).toContain('GATE_BASE_URL')
    expect(container.textContent).toContain('1 required')
    const tokenInput = container.querySelector('input[type="password"]')
    expect(tokenInput).toBeTruthy()
  })
})
