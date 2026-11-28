import { html } from 'htm/preact'
import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { authSession, resetAuthStateForTests } from '../../core/auth'
import {
  KeeperGroupBar,
  UNGROUPED_LABEL,
  buildKeeperGroupSummaries,
  collapsedGroupNames,
  groupBarCollapsed,
  normalizeKeeperGroup,
} from './keeper-group-bar'
import type { KeeperRosterItem } from './types'

function makeKeeper(overrides: Partial<KeeperRosterItem>): KeeperRosterItem {
  return {
    name: 'keeper-a',
    status: 'running',
    phase: 'idle',
    health: 'healthy',
    paused: false,
    keepalive_running: true,
    activation_mode: 'autonomous',
    runtime_id: 'claude-code',
    sandbox_profile: 'microvm',
    company: 'core',
    context_ratio: 0.2,
    context_tokens: 40_000,
    context_max: 200_000,
    context_unavailable_reason: null,
    runtime_blocker_summary: null,
    last_failure: null,
    directory_issue: null,
    turns_24h: 4,
    candle_balance_milli: '1000',
    portrait_equipment: null,
    chat_control_token: null,
    active_turn: null,
    ...overrides,
  }
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

describe('KeeperGroupBar', () => {
  beforeEach(() => {
    window.localStorage.clear()
    resetAuthStateForTests()
    groupBarCollapsed.value = false
    collapsedGroupNames.value = []
    authSession.value = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: { google: false, github: false, dev_token: false },
      workspaceId: 'default',
    }
  })

  afterEach(() => {
    cleanup()
    vi.restoreAllMocks()
    resetAuthStateForTests()
  })

  it('normalizes ungrouped sentinels to 미지정 and always sorts 미지정 last', () => {
    expect(normalizeKeeperGroup('ungrouped')).toBe(UNGROUPED_LABEL)
    expect(normalizeKeeperGroup('UNGROUPED')).toBe(UNGROUPED_LABEL)
    expect(normalizeKeeperGroup('General')).toBe(UNGROUPED_LABEL)
    expect(normalizeKeeperGroup('')).toBe(UNGROUPED_LABEL)
    expect(normalizeKeeperGroup('   ')).toBe(UNGROUPED_LABEL)
    expect(normalizeKeeperGroup(null)).toBe(UNGROUPED_LABEL)
    expect(normalizeKeeperGroup('research')).toBe('research')

    const keepers: KeeperRosterItem[] = [
      makeKeeper({ name: 'k-un', company: 'ungrouped', keepalive_running: false }),
      makeKeeper({ name: 'k-z', company: 'zebra', health: 'unhealthy' }),
      makeKeeper({ name: 'k-a', company: 'alpha', keepalive_running: true }),
      makeKeeper({ name: 'k-empty', company: '', last_failure: { cause: 'boom', at_unix: 1 } }),
    ]

    const summaries = buildKeeperGroupSummaries(keepers, [{ name: 'beta' }, { name: 'ungrouped' }])
    expect(summaries.map((s) => s.name)).toEqual(['alpha', 'beta', 'zebra', UNGROUPED_LABEL])
    expect(summaries[0]!.activeCount).toBe(1)
    expect(summaries[2]!.faultCount).toBe(1)
    const ungrouped = summaries[summaries.length - 1]!
    expect(ungrouped.isUngrouped).toBe(true)
    expect(ungrouped.memberCount).toBe(2)
    expect(ungrouped.faultCount).toBe(1)
  })

  it('filters by clicking group chips, persists collapse state, and updates keeper.group via CAS /api/v1/config/patch', async () => {
    const patchBodies: Record<string, unknown>[] = []
    vi.stubGlobal(
      'fetch',
      vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = String(input)
        if (url.includes('/api/v1/dashboard/shell')) {
          return jsonResponse({ groups: [{ name: 'ops' }, { name: 'ungrouped' }] })
        }
        if (url.includes('/api/v1/config/schema')) {
          return jsonResponse({
            data: {
              target: 'keeper:sangsu',
              file_exists: true,
              file_sha256: 'sha-abc-123',
              categories: [],
            },
          })
        }
        if (url.includes('/api/v1/config/patch') && init?.method === 'POST') {
          patchBodies.push(JSON.parse(String(init.body)))
          return jsonResponse({
            data: {
              applied: true,
              dry_run: false,
              target: 'keeper:sangsu',
              changed: true,
              before_sha256: 'sha-abc-123',
              new_sha256: 'sha-def-456',
              snapshot_id: 'snap-1',
              reload_scope: 'hot_reload',
              unified_diff: '',
              diff_hunks: [],
              validation_warnings: [],
            },
          })
        }
        return jsonResponse({})
      }),
    )

    const onSelectGroup = vi.fn()
    const onGroupAssigned = vi.fn()
    const keepers = [
      makeKeeper({ name: 'sangsu', company: 'ops' }),
      makeKeeper({ name: 'dreamer', company: 'ungrouped' }),
    ]

    const view = render(
      html`
        <${KeeperGroupBar}
          keepers=${keepers}
          selectedGroup=${null}
          onSelectGroup=${onSelectGroup}
          activeKeeper=${keepers[0]!}
          onGroupAssigned=${onGroupAssigned}
        />
      `,
    )

    // Click ops group chip -> filters roster
    const opsBtn = view.getByTestId('kgb-group-ops').querySelector('.kgb-chip-btn') as HTMLButtonElement
    fireEvent.click(opsBtn)
    expect(onSelectGroup).toHaveBeenCalledWith('ops')

    // Toggle collapse persists to localStorage
    fireEvent.click(view.getByTestId('kgb-toggle'))
    expect(window.localStorage.getItem('masc:keepers:group-bar-collapsed:v1')).toBe('true')
    fireEvent.click(view.getByTestId('kgb-toggle'))

    // Inline "그룹 지정" submits CAS POST /api/v1/config/patch
    fireEvent.click(view.getByTestId('kgb-assign-toggle'))
    const input = view.container.querySelector('#kgb-group-input') as HTMLInputElement
    fireEvent.input(input, { target: { value: 'research' } })
    fireEvent.click(view.getByTestId('kgb-assign-save'))

    await waitFor(() => {
      expect(patchBodies).toHaveLength(1)
    })
    expect(patchBodies[0]).toMatchObject({
      target: 'keeper:sangsu',
      expected_sha256: 'sha-abc-123',
      dry_run: false,
      changes: [
        {
          op: 'set',
          table: 'keeper',
          key: 'group',
          full_key: 'keeper.group',
          value: 'research',
        },
      ],
    })
    expect(patchBodies[0]).not.toHaveProperty('keeper_name')
    expect(onGroupAssigned).toHaveBeenCalledTimes(1)
  })

  it('aborts group assignment without sending patch when schema fetch fails and surfaces shell load errors', async () => {
    const patchCalls = vi.fn()
    vi.stubGlobal(
      'fetch',
      vi.fn(async (input: RequestInfo | URL) => {
        const url = String(input)
        if (url.includes('/api/v1/dashboard/shell')) {
          return jsonResponse({ error: 'shell unavailable' }, 503)
        }
        if (url.includes('/api/v1/config/schema')) {
          return jsonResponse({ error: 'schema unavailable' }, 500)
        }
        if (url.includes('/api/v1/config/patch')) {
          patchCalls()
          return jsonResponse({})
        }
        return jsonResponse({})
      }),
    )

    const keepers = [makeKeeper({ name: 'sangsu', company: 'General' })]
    const view = render(
      html`
        <${KeeperGroupBar}
          keepers=${keepers}
          selectedGroup=${null}
          onSelectGroup=${vi.fn()}
          activeKeeper=${keepers[0]!}
        />
      `,
    )

    await waitFor(() => {
      expect(view.getByTestId('kgb-shell-error')).toBeTruthy()
    })

    fireEvent.click(view.getByTestId('kgb-assign-toggle'))
    const input = view.container.querySelector('#kgb-group-input') as HTMLInputElement
    fireEvent.input(input, { target: { value: 'ops' } })
    fireEvent.click(view.getByTestId('kgb-assign-save'))

    await waitFor(() => {
      expect(view.getByTestId('kgb-assign-status').textContent).toContain('설정 스키마 조회 실패')
    })
    expect(patchCalls).not.toHaveBeenCalled()
  })
})
