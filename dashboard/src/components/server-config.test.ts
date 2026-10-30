// @vitest-environment happy-dom
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { Effect } from 'effect'

vi.mock('../api/dashboard-config', () => ({
  fetchDashboardConfig: vi.fn(),
}))

vi.mock('../store', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../store')>()
  return {
    ...actual,
    refreshShell: vi.fn(),
    shellConfigResolution: { value: null },
    shellRuntimeResolution: { value: null },
  }
})

import { fetchDashboardConfig } from '../api/dashboard-config'
import { refreshShell } from '../store'
import { refreshServerConfig, ServerConfig } from './server-config'

const dashboardConfigFixture = {
  server: {
    version: '1.0.0',
    uptimeSeconds: 0,
    ocamlVersion: '5.2.0',
    pid: 1,
  },
  categories: {},
}

describe('refreshServerConfig', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(fetchDashboardConfig).mockReturnValue(
      Effect.succeed(dashboardConfigFixture),
    )
  })

  it('refreshes shell truth before loading config data', async () => {
    await refreshServerConfig()

    expect(refreshShell).toHaveBeenCalledTimes(1)
    expect(refreshShell).toHaveBeenCalledWith({ force: true })
    expect(fetchDashboardConfig).toHaveBeenCalledTimes(1)
  })
})

describe('ServerConfig rendering', () => {
  let container: HTMLElement

  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(fetchDashboardConfig).mockReturnValue(
      Effect.succeed(dashboardConfigFixture),
    )
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    document.body.removeChild(container)
  })

  it('renders the connector surface marker', async () => {
    await refreshServerConfig()
    render(html`<${ServerConfig} />`, container)

    expect(container.querySelector('.v2-connector-surface')).not.toBeNull()
  })
})
