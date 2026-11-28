import { html } from 'htm/preact'
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { authSession, resetAuthStateForTests } from '../../core/auth'
import { currentRoute, resetRouterForTests } from '../../routes/router'
import {
  diskPressureSummary,
  installHostDiskObservation,
  resetShellStateForTests,
  updateHostDiskObservation,
} from '../../shell/shell-state'
import { TopBar } from '../../shell/top-bar'
import { HostStorageCard } from './host-storage-card'

const GIB = 1024 * 1024 * 1024

function makeObservablesPayload(storeCount: number) {
  const stores = Array.from({ length: storeCount }, (_, i) => ({
    store: `store-${i + 1}`,
    bytes: (i + 1) * 10 * 1024 * 1024,
    files: (i + 1) * 3,
  }))
  return {
    last_write_unixtime: 1_700_000_000,
    age_seconds: 5,
    console_sink: { queue_depth: 0, dropped_total: 0 },
    transition_audit: { queue_depth: 0 },
    fd: { open: 10, limit: 1024, active_operations: [], resource_errors: [] },
    stores,
    event_bus: [],
    pool: { idle: 0, inflight: 0, reuse_total: 0, evict_total: 0, evict_failure_total: 0, create_total: 0 },
  }
}

describe('HostStorageCard & TopBar disk pressure telemetry', () => {
  beforeEach(() => {
    resetAuthStateForTests()
    resetShellStateForTests()
    resetRouterForTests()
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    resetAuthStateForTests()
    resetShellStateForTests()
    resetRouterForTests()
  })

  it('renders threshold-colored capacity bar, mount metadata, and sorted .masc stores', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => Response.json(makeObservablesPayload(3))))

    const view = render(html`
      <${HostStorageCard}
        hostStorage=${{
          masc_root: '/srv/.masc',
          mode: 'observation_only',
          storage_space_exhaustion_observations_total: 0,
          last_storage_space_exhaustion_ts: null,
          filesystem: {
            path: '/srv/.masc',
            filesystem: '/dev/disk3s5',
            mounted_on: '/System/Volumes/Data',
            total_bytes: 500 * GIB,
            used_bytes: 420 * GIB,
            available_bytes: 80 * GIB,
            capacity_percent: 84.0,
            available_percent: 16.0,
          },
        }}
      />
    `)

    expect(view.getByTestId('host-storage-status-badge').getAttribute('data-tone')).toBe('warn')
    expect(view.getByTestId('host-storage-capacity').textContent).toContain('80.0 GiB 사용 가능 / 500.0 GiB 전체')
    expect(view.getByTestId('host-storage-capacity').textContent).toContain('84.0%')
    expect(view.getByTestId('host-storage-capacity').textContent).toContain('/System/Volumes/Data')
    expect(view.getByTestId('host-storage-capacity').textContent).toContain('/dev/disk3s5')
    expect(view.queryByTestId('host-storage-enospc-alert')).toBeNull()

    await waitFor(() => {
      expect(view.getByTestId('host-storage-stores-body').textContent).toContain('store-3')
    })
    // Sorted descending by bytes: store-3 (30 MiB) appears before store-1 (10 MiB)
    const rows = Array.from(view.container.querySelectorAll('.hst-store-table tbody tr'))
    expect(rows).toHaveLength(3)
    expect(rows[0]!.textContent).toContain('store-3')
    expect(rows[2]!.textContent).toContain('store-1')
  })

  it('renders ENOSPC alert banner when exhaustion observation is recent and collapses >5 store rows by default', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => Response.json(makeObservablesPayload(7))))
    const recentTs = Math.floor(Date.now() / 1000) - 60

    const view = render(html`
      <${HostStorageCard}
        hostStorage=${{
          status: 'degraded',
          status_reasons: ['enospc observed'],
          storage_space_exhaustion_observations_total: 2,
          last_storage_space_exhaustion_ts: recentTs,
          filesystem: {
            path: '/srv/.masc',
            filesystem: '/dev/nvme0n1',
            mounted_on: '/',
            total_bytes: 100 * GIB,
            used_bytes: 95 * GIB,
            available_bytes: 5 * GIB,
            capacity_percent: 95.0,
            available_percent: 5.0,
          },
        }}
      />
    `)

    expect(view.getByTestId('host-storage-status-badge').getAttribute('data-tone')).toBe('bad')
    expect(view.getByTestId('host-storage-enospc-alert').textContent).toContain('ENOSPC')
    expect(view.getByTestId('host-storage-enospc-alert').textContent).toContain('2')

    await waitFor(() => {
      expect(view.getByTestId('host-storage-stores-toggle').textContent).toContain('7개 스토어')
    })
    expect(view.getByTestId('host-storage-stores-toggle').getAttribute('aria-expanded')).toBe('false')
    expect(view.queryByTestId('host-storage-stores-body')).toBeNull()

    fireEvent.click(view.getByTestId('host-storage-stores-toggle'))
    expect(view.getByTestId('host-storage-stores-body').querySelectorAll('tbody tr')).toHaveLength(7)
  })

  it('downgrades stale ENOSPC cumulative observations to non-alert history when filesystem is healthy', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => Response.json(makeObservablesPayload(2))))
    const staleTs = Math.floor(Date.now() / 1000) - 7200
    const recoveredPayload = {
      status: 'ok',
      storage_space_exhaustion_observations_total: 3,
      last_storage_space_exhaustion_ts: staleTs,
      filesystem: {
        path: '/srv/.masc',
        filesystem: '/dev/nvme0n1',
        mounted_on: '/',
        total_bytes: 100 * GIB,
        used_bytes: 42 * GIB,
        available_bytes: 58 * GIB,
        capacity_percent: 42.0,
        available_percent: 58.0,
      },
    }

    updateHostDiskObservation(recoveredPayload)
    expect(diskPressureSummary.value.level).toBe('ok')

    const topBarView = render(html`<${TopBar} />`)
    expect(topBarView.queryByTestId('topbar-disk-pressure-pill')).toBeNull()
    topBarView.unmount()

    const cardView = render(html`<${HostStorageCard} hostStorage=${recoveredPayload} />`)
    expect(cardView.getByTestId('host-storage-status-badge').getAttribute('data-tone')).toBe('ok')
    expect(cardView.queryByTestId('host-storage-enospc-alert')).toBeNull()
    expect(cardView.getByTestId('host-storage-enospc-history').textContent).toContain('3')
  })


  it('uses server critical status below 80% and refreshes recovery without mounting Pulse', async () => {
    resetRouterForTests('/infra/sandboxes')
    vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible')
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      role: 'admin',
      tokenPresent: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
    const critical = {
      status: 'critical',
      filesystem: { total_bytes: 8 * GIB, available_bytes: 1.8 * GIB, capacity_percent: 77.5 },
    }
    const shell = (disk_observation: object) => ({ runtime_resolution: { disk_observation } })
    const fetchImpl = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(Response.json(shell(critical)))
      .mockImplementationOnce(async () => Response.json(shell({
        status: 'ok', filesystem: { capacity_percent: 40 },
      })))

    const stop = installHostDiskObservation(fetchImpl)
    try {
      const view = render(html`<${TopBar} />`)
      const pill = await view.findByTestId('topbar-disk-pressure-pill')
      expect(pill.getAttribute('data-disk-level')).toBe('critical')
      expect(fetchImpl.mock.calls[0]?.[0]).toBe('/api/v1/dashboard/shell?light=true')

      document.dispatchEvent(new Event('visibilitychange'))
      await waitFor(() => expect(view.queryByTestId('topbar-disk-pressure-pill')).toBeNull())
      expect(fetchImpl).toHaveBeenCalledTimes(2)
    } finally {
      stop()
    }
  })

  it('keeps TopBar completely silent when healthy and shows clickable warning pill when pressured', async () => {
    updateHostDiskObservation({
      storage_space_exhaustion_observations_total: 0,
      filesystem: { capacity_percent: 45.0, available_bytes: 55 * GIB, total_bytes: 100 * GIB },
    })
    expect(diskPressureSummary.value.level).toBe('ok')

    const view = render(html`<${TopBar} />`)
    expect(view.queryByTestId('topbar-disk-pressure-pill')).toBeNull()

    updateHostDiskObservation({
      storage_space_exhaustion_observations_total: 0,
      filesystem: { capacity_percent: 86.0, available_bytes: 14 * GIB, total_bytes: 100 * GIB },
    })
    expect(diskPressureSummary.value.level).toBe('warning')

    const pill = await view.findByTestId('topbar-disk-pressure-pill')
    expect(pill.getAttribute('data-disk-level')).toBe('warning')
    expect(pill.textContent).toContain('86%')

    fireEvent.click(pill)
    expect(currentRoute.value.workspace).toBe('infra')
    expect(currentRoute.value.subroute).toBe('sandboxes')
  })
})
