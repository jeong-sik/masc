import { beforeEach, describe, expect, it, vi } from 'vitest'

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
import { refreshServerConfig } from './server-config'

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

  it('keeps runtime/config truth visible when env config fetch fails', async () => {
    mocks.fetchDashboardConfig.mockRejectedValue(new Error('config fetch failed'))
    mocks.fetchDashboardTools.mockResolvedValue({
      generated_at: '2026-04-10T00:00:00Z',
      config_resolution: {
        status: 'ready',
        warnings: [],
        config_root: { path: '/tmp/root/.masc/config', exists: true, source: 'local_masc' },
        cascade: { path: '/tmp/root/.masc/config/cascade.json', exists: true, source: 'local_masc' },
        prompts: { path: '/tmp/root/.masc/config/prompts', exists: true, source: 'local_masc' },
        keepers: { path: '/tmp/root/.masc/config/keepers', exists: true, source: 'local_masc' },
        personas: { path: '/tmp/root/.masc/config/personas', exists: true, source: 'local_masc' },
      },
      runtime_resolution: {
        status: 'ready',
        warnings: [],
        base_path: { path: '/tmp/root', exists: true, source: 'input' },
        workspace_path: { path: '/tmp/root', exists: true, source: 'workspace' },
        resolved_base_path: { path: '/tmp/root', exists: true, source: 'resolved_base' },
        data_root: { path: '/tmp/root/.masc', exists: true, source: 'runtime_data' },
        prompt_markdown_dir: { path: '/tmp/root/.masc/config/prompts', exists: true, source: 'prompt_registry' },
        workspace_git_commit: 'abc1234',
        resolved_base_git_commit: 'abc1234',
        source_mismatch: false,
        diagnostics: [],
        build: {
          release_version: 'dev',
          commit: 'abc1234',
          started_at: '2026-04-10T00:00:00Z',
          uptime_seconds: 12,
        },
      },
      tool_inventory: { tools: [] },
      tool_usage: {
        total_calls: 0,
        distinct_tools_called: 0,
        top_20: [],
        never_called_count: 0,
        dispatch_v2_enabled: false,
        registered_count: 0,
      },
    })

    await refreshServerConfig()
    render(html`<${ServerConfig} />`, container)
    await flush()

    expect(container.textContent).toContain('config fetch failed')
    expect(container.textContent).toContain('ConfigResolutionPanel')
    expect(container.textContent).not.toContain('MASC_HTTP_PORT')
  })
})
