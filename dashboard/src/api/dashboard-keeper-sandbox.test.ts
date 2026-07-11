import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  callMcpTool: vi.fn(),
}))

vi.mock('./mcp', () => ({
  callMcpTool: mocks.callMcpTool,
}))

import {
  fetchKeeperSandboxStatus,
  KeeperSandboxResponseDecodeError,
} from './dashboard-keeper-sandbox'

function responseText(): string {
  return JSON.stringify({
    keeper: 'sangsu',
    sandbox: {
      keeper: 'sangsu',
      sandbox_profile: 'local',
      configured_network_mode: 'host',
      effective_mode: 'local',
      security_boundary: {
        execution_boundary: 'host_process',
        filesystem_boundary: 'host_filesystem_tool_policy',
        network_boundary: 'host_network_namespace',
        credential_boundary: 'managed_home_projection',
        rootfs_read_only: null,
        cap_drop_all: null,
        no_new_privileges: null,
      },
      container_count: 0,
      containers: [],
      preflight: null,
      container_error: null,
      why_no_container: 'sandbox_profile=local',
      recommendation: 'No Docker container is expected.',
      playground_repos: [],
      playground_repos_source: 'live',
      playground_repos_error: null,
      identity: {
        agent_name: 'keeper-sangsu',
        expected_agent_name: 'keeper-sangsu',
        agent_name_matches: true,
        trace_id: 'trace-sangsu',
        warnings: [],
      },
    },
  })
}

describe('fetchKeeperSandboxStatus', () => {
  beforeEach(() => {
    mocks.callMcpTool.mockReset()
  })

  it('requests verbose preflight truth from the canonical sandbox tool', async () => {
    mocks.callMcpTool.mockResolvedValue(responseText())

    const result = await fetchKeeperSandboxStatus('  sangsu  ')

    expect(mocks.callMcpTool).toHaveBeenCalledWith('masc_keeper_sandbox_status', {
      name: 'sangsu',
      include_preflight: true,
      verbose: true,
    })
    expect(result.sandbox.effective_mode).toBe('local')
  })

  it('surfaces invalid JSON explicitly', async () => {
    mocks.callMcpTool.mockResolvedValue('{broken')
    await expect(fetchKeeperSandboxStatus('sangsu')).rejects.toThrow(
      KeeperSandboxResponseDecodeError,
    )
  })
})
