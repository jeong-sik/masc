// @vitest-environment happy-dom
import { cleanup, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'
import { html } from 'htm/preact'
import {
  fetchKeeperSandboxLiveStatus,
  parseKeeperSandboxLiveStatus,
  type KeeperSandboxLiveStatus,
} from '../api/keeper'

vi.mock('../api/keeper', async () => {
  const actual = await vi.importActual<typeof import('../api/keeper')>('../api/keeper')
  return { ...actual, fetchKeeperSandboxLiveStatus: vi.fn() }
})

vi.mock('../lib/auto-refresh', () => ({
  DEFAULT_PANEL_REFRESH_MS: 30_000,
  setupVisibleAutoRefresh: vi.fn(() => () => undefined),
}))

import { KeeperSandboxLivePanel } from './keeper-sandbox-live'

const fetchSandboxStatus = vi.mocked(fetchKeeperSandboxLiveStatus)

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

function status(overrides: Partial<KeeperSandboxLiveStatus> = {}): KeeperSandboxLiveStatus {
  return {
    sandbox_profile: 'microvm',
    configured_network_mode: 'inherit',
    effective_mode: 'persistent_vm',
    managed_container_kind: 'keeper-vm',
    containers: [{
      id: 'masc-keeper-vm-lane-smith-faea17a4',
      name: 'masc-keeper-vm-lane-smith-faea17a4',
      image: 'docker.io/library/masc-keeper-sandbox:local',
      status: 'running',
      running: true,
      container_kind: 'keeper-vm',
      network_label: 'inherit',
      owner_pid: 42,
    }],
    container_error: null,
    why_no_container: null,
    keeper_last_error: null,
    ...overrides,
  }
}

describe('parseKeeperSandboxLiveStatus', () => {
  it('rejects a missing live observation instead of presenting a default', () => {
    expect(() => parseKeeperSandboxLiveStatus({ name: 'lane-smith' }))
      .toThrow('keeper status has no sandbox_live observation')
  })
})

describe('KeeperSandboxLivePanel', () => {
  it('shows the active Apple Container VM and its log command', async () => {
    fetchSandboxStatus.mockResolvedValue(status())

    render(html`<${KeeperSandboxLivePanel} keeperName="lane-smith" />`)

    await waitFor(() => expect(fetchSandboxStatus).toHaveBeenCalledWith('lane-smith', expect.any(Object)))
    expect(await screen.findByText('masc-keeper-vm-lane-smith-faea17a4')).toBeInTheDocument()
    expect(screen.getByText('microvm')).toBeInTheDocument()
    expect(screen.getByLabelText('container log command')).toHaveTextContent(
      'container logs -f masc-keeper-vm-lane-smith-faea17a4',
    )
  })

  it('names docker as the CLI for a docker keeper', async () => {
    fetchSandboxStatus.mockResolvedValue(status({ sandbox_profile: 'docker' }))

    render(html`<${KeeperSandboxLivePanel} keeperName="sangsu" />`)

    expect(await screen.findByLabelText('container log command')).toHaveTextContent(
      'docker logs -f masc-keeper-vm-lane-smith-faea17a4',
    )
  })

  // The old two-way test answered 'docker' for anything that was not microvm,
  // so a profile with no docker containers still got a `docker logs -f` line
  // to copy. No CLI means no command row.
  it('offers no log command for a profile that runs no containers', async () => {
    fetchSandboxStatus.mockResolvedValue(status({ sandbox_profile: 'remote_ssh' }))

    render(html`<${KeeperSandboxLivePanel} keeperName="remote-one" />`)

    expect(await screen.findByText('masc-keeper-vm-lane-smith-faea17a4')).toBeInTheDocument()
    expect(screen.queryByLabelText('container log command')).toBeNull()
  })

  it('offers no log command for a profile this bundle cannot name', async () => {
    fetchSandboxStatus.mockResolvedValue(status({ sandbox_profile: 'some_future_profile' }))

    render(html`<${KeeperSandboxLivePanel} keeperName="future-one" />`)

    expect(await screen.findByText('masc-keeper-vm-lane-smith-faea17a4')).toBeInTheDocument()
    expect(screen.queryByLabelText('container log command')).toBeNull()
  })

  it('explains an observed absence without pretending the keeper ran locally', async () => {
    fetchSandboxStatus.mockResolvedValue(status({
      containers: [],
      why_no_container: 'The VM is created on the first tool execution.',
    }))

    render(html`<${KeeperSandboxLivePanel} keeperName="edgar.a.poe" />`)

    expect(await screen.findByText('실행 중인 관리 컨테이너가 없습니다.')).toBeInTheDocument()
    expect(screen.getByText('The VM is created on the first tool execution.')).toBeInTheDocument()
  })
})
