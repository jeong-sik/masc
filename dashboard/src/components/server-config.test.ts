// @vitest-environment happy-dom
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'

vi.mock('../api/dashboard', () => ({
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

import { fetchDashboardConfig } from '../api/dashboard'
import { refreshShell } from '../store'
import { refreshServerConfig, ServerConfig } from './server-config'

const dashboardConfigFixture = {
  generated_at: '2026-04-10T00:00:00Z',
  server: {
    version: '1.0.0',
    git_commit: null,
    uptime_seconds: 0,
    ocaml_version: '5.2.0',
    pid: 1,
  },
  categories: {},
}

describe('refreshServerConfig', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(fetchDashboardConfig).mockResolvedValue(dashboardConfigFixture)
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
    vi.mocked(fetchDashboardConfig).mockResolvedValue(dashboardConfigFixture)
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
