import { h } from 'preact'
import { cleanup, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

import type { KeeperSandboxStatusResponse } from '../api/schemas/keeper-sandbox-status'
import { KeeperSandboxPanel } from './keeper-sandbox-panel'

function response(
  overrides: Partial<KeeperSandboxStatusResponse['sandbox']> = {},
): KeeperSandboxStatusResponse {
  return {
    keeper: 'sangsu',
    sandbox: {
      keeper: 'sangsu',
      sandbox_profile: 'docker',
      configured_network_mode: 'none',
      effective_mode: 'docker_idle',
      security_boundary: {
        execution_boundary: 'docker_container',
        filesystem_boundary: 'explicit_container_mounts',
        network_boundary: 'isolated_network_namespace',
        credential_boundary: 'ephemeral_container_projection',
        rootfs_read_only: true,
        cap_drop_all: true,
        no_new_privileges: true,
      },
      container_count: 0,
      containers: [],
      preflight: null,
      container_error: null,
      why_no_container: 'docker_idle',
      recommendation: 'No lifecycle action is required.',
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
      ...overrides,
    },
  }
}

afterEach(() => {
  cleanup()
  vi.restoreAllMocks()
})

describe('KeeperSandboxPanel', () => {
  it('explains that docker idle is healthy on-demand state without managed/prewarm controls', async () => {
    const fetchStatus = vi.fn(async () => response())
    render(h(KeeperSandboxPanel, { keeperName: 'sangsu', fetchStatus }))

    await waitFor(() => expect(screen.getByText('docker idle')).toBeInTheDocument())
    expect(screen.getByText(/Healthy on-demand mode/)).toBeInTheDocument()
    expect(screen.queryByText(/managed|prewarm/i)).toBeNull()
  })

  it('renders exact active container kind and host-network truth', async () => {
    const fetchStatus = vi.fn(async () => response({
      configured_network_mode: 'host',
      effective_mode: 'docker_active',
      security_boundary: {
        execution_boundary: 'docker_container',
        filesystem_boundary: 'explicit_container_mounts',
        network_boundary: 'host_network_namespace',
        credential_boundary: 'ephemeral_container_projection',
        rootfs_read_only: true,
        cap_drop_all: true,
        no_new_privileges: true,
      },
      container_count: 1,
      containers: [{
        id: 'container-id',
        name: 'masc-turn-sangsu',
        image: 'masc-keeper-sandbox:local',
        status: 'Up 3 seconds',
        running: true,
        created_at: '2026-07-11T00:00:00Z',
        keeper_name: 'sangsu',
        container_kind: 'turn',
        network_label: 'host',
        owner_pid: 1234,
        started_at: 1_752_192_000,
        ttl_sec: 900,
      }],
    }))
    render(h(KeeperSandboxPanel, { keeperName: 'sangsu', fetchStatus }))

    await waitFor(() => expect(screen.getByText('docker active')).toBeInTheDocument())
    expect(screen.getByText('turn')).toBeInTheDocument()
    expect(screen.getByText('host · Docker --network host')).toBeInTheDocument()
    expect(screen.getByText('masc-turn-sangsu')).toBeInTheDocument()
  })

  it('shows the managed local credential boundary without claiming namespace isolation', async () => {
    const fetchStatus = vi.fn(async () => response({
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
    }))
    render(h(KeeperSandboxPanel, { keeperName: 'sangsu', fetchStatus }))

    await waitFor(() => expect(screen.getByText('local host')).toBeInTheDocument())
    expect(screen.getByText(/BasePath-owned HOME\/XDG/)).toBeInTheDocument()
    expect(screen.getByText(/no namespace isolation/)).toBeInTheDocument()
  })

  it('renders repository observation and fail-closed policy evidence', async () => {
    const fetchStatus = vi.fn(async () => response({
      playground_repos: [{
        name: 'masc',
        source: 'git',
        path: 'repos/masc',
        policy_status: 'unregistered_repository',
        policy_allowed: false,
        policy_source: 'repositories.toml',
        policy_reason: 'repository is not registered',
        error: null,
        branch: 'main',
        latest_commit: 'abc123 root fix',
        shallow: false,
        observed_at: '2026-07-11T00:00:00Z',
        observed_at_unix: 1_752_192_000,
      }],
    }))
    render(h(KeeperSandboxPanel, { keeperName: 'sangsu', fetchStatus }))

    await waitFor(() => expect(screen.getByText('unregistered_repository')).toBeInTheDocument())
    expect(screen.getByText('repos/masc')).toBeInTheDocument()
    expect(screen.getByText('repositories.toml')).toBeInTheDocument()
    expect(screen.getByText('repository is not registered')).toBeInTheDocument()
  })

  it('surfaces repository observation failure instead of presenting an empty repository set', async () => {
    const fetchStatus = vi.fn(async () => response({
      playground_repos_error: 'playground repository cache JSON is invalid',
    }))
    render(h(KeeperSandboxPanel, { keeperName: 'sangsu', fetchStatus }))

    await waitFor(() => {
      expect(screen.getByText('playground repository cache JSON is invalid')).toBeInTheDocument()
    })
    expect(screen.queryByText('관측된 repository가 없습니다.')).toBeNull()
  })

  it('surfaces fetch failure without substituting an idle status', async () => {
    const fetchStatus = vi.fn(async () => {
      throw new Error('docker daemon unavailable')
    })
    render(h(KeeperSandboxPanel, { keeperName: 'sangsu', fetchStatus }))

    await waitFor(() => expect(screen.getByTestId('keeper-sandbox-error')).toBeInTheDocument())
    expect(screen.getByText('docker daemon unavailable')).toBeInTheDocument()
    expect(screen.queryByText('docker idle')).toBeNull()
  })
})
