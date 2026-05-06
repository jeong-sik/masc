// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, describe, expect, it } from 'vitest'
import type { Keeper } from '../types'
import { route } from '../router'
import { keepers } from '../store'
import {
  KeeperCognitionInspector,
  selectKeeperForInspector,
  toolAccessRowsForKeeper,
} from './keeper-cognition-inspector'

function keeper(overrides: Partial<Keeper>): Keeper {
  return {
    name: 'alpha',
    status: 'idle',
    ...overrides,
  } as Keeper
}

describe('KeeperCognitionInspector', () => {
  afterEach(() => {
    keepers.value = []
    route.value = { tab: 'overview', params: {}, postId: null }
  })

  it('selects a requested keeper by name, keeper id, or agent name', () => {
    const list = [
      keeper({ name: 'alpha', keeper_id: 'kid-alpha', agent_name: 'agent-alpha' }),
      keeper({ name: 'beta', keeper_id: 'kid-beta', agent_name: 'agent-beta' }),
    ]

    expect(selectKeeperForInspector(list, 'beta')?.name).toBe('beta')
    expect(selectKeeperForInspector(list, 'kid-beta')?.name).toBe('beta')
    expect(selectKeeperForInspector(list, 'agent-beta')?.name).toBe('beta')
  })

  it('falls back to a keeper with BDI data before a blank first row', () => {
    const list = [
      keeper({ name: 'alpha' }),
      keeper({ name: 'beta', will: 'ship the cockpit' }),
    ]

    expect(selectKeeperForInspector(list, null)?.name).toBe('beta')
  })

  it('formats live tool access rows from keeper runtime fields', () => {
    const rows = toolAccessRowsForKeeper(keeper({
      cascade_name: 'primary',
      sandbox_profile: 'docker',
      proactive_enabled: false,
      proactive_idle_sec: 120,
      mention_reactive_turn_count: 4,
      recent_tool_names: ['keeper_shell', 'web_search'],
      approval_policy_effective: { allow_rules: 3, deny_rules: 1, persisted_rules: 2 },
      configured_social_model: 'reactive',
    }))

    expect(rows.map(row => row.label)).toContain('cascade')
    expect(rows.find(row => row.label === 'cascade')?.value).toBe('primary')
    expect(rows.find(row => row.label === 'sandbox')?.value).toBe('docker')
    expect(rows.find(row => row.label === 'proactive idle')?.value).toContain('off')
    expect(rows.find(row => row.label === 'observed tools')?.value).toContain('keeper_shell')
    expect(rows.find(row => row.label === 'approval policy')?.value).toBe('3 allow · 1 deny · 2 persisted')
  })

  it('renders the tool access focus surface from the cognition keeper route', () => {
    const container = document.createElement('div')
    keepers.value = [
      keeper({
        name: 'beta',
        status: 'active',
        cascade_name: 'primary',
        latest_tool_names: ['keeper_task_done'],
      }),
    ]
    route.value = {
      tab: 'monitoring',
      params: { section: 'cognition', view: 'keeper', focus: 'tool-access' },
      postId: null,
    }

    render(html`<${KeeperCognitionInspector} />`, container)

    expect(container.querySelector('[data-testid="keeper-cognition-inspector"]')).not.toBeNull()
    expect(container.textContent).toContain('Tool Access Snapshot')
    expect(container.textContent).toContain('keeper_task_done')
    render(null, container)
  })
})
