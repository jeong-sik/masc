import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

void vi

const mocks = vi.hoisted(() => ({
  fetchKeeperConfig: vi.fn(async () => ({
    name: 'keeper-sangsu',
    prompt: {
      goal: 'Ship stable keeper ops',
      short_goal: 'Diagnose agent liveness',
      mid_goal: 'Reduce restart confusion',
      long_goal: 'Keep command plane stable',
      will: 'Stay on call',
      needs: 'Accurate runtime state',
      desires: 'Clear operator feedback',
      instructions: 'Prefer direct remediation',
      system_prompt_blocks: {
        constitution: { key: 'keeper.constitution', source: 'file', text: 'constitution text' },
        world: { key: 'keeper.world', source: 'override', text: 'world text' },
        capabilities: { key: 'keeper.capabilities', source: 'file', text: 'capabilities text' },
      },
      effective_system_prompt: 'full prompt',
    },
    execution: {
      models: ['llama:test-balanced'],
      active_model: 'llama:test-balanced',
      verify: true,
    },
    compaction: {
      profile: 'balanced',
      ratio_gate: 0.85,
      message_gate: 16,
      token_gate: 24000,
      cooldown_sec: 120,
    },
    proactive: {
      enabled: true,
      idle_sec: 900,
      cooldown_sec: 1800,
    },
    drift: {
      status: 'wired',
      enabled: true,
      min_turn_gap: 4,
      count_total: 2,
      last_reason: 'board quiet',
    },
    auto_team_session: {
      status: 'source_only',
      enabled: null,
    },
    handoff: {
      auto: true,
      threshold: 0.85,
      cooldown_sec: 300,
    },
    hooks: {
      slots: {},
      deny_list: [],
      deny_list_count: 0,
      destructive_check_tools: 'dynamic_boundary (Tool_dispatch.is_destructive)',
      cost_budget: {
        active: false,
      },
    },
    runtime: {
      paused: false,
      registered: true,
      keepalive_running: true,
      registry_state: 'running',
      fiber_health: 'healthy',
      presence_keepalive: true,
      presence_keepalive_sec: 30,
    },
    coordination: {
      room_scope: 'global',
      mention_targets: ['sangsu'],
      joined_room_ids: ['default'],
    },
    sources: {
      live_meta_path: '/tmp/.masc/keepers/keeper-sangsu/live.json',
      default_manifest_path: '/tmp/config/keepers/default.toml',
      default_source_kind: 'toml' as const,
      precedence: ['live_meta', 'toml', 'persona'],
      has_live_override: true,
      override_fields: ['goal', 'instructions'],
    },
    metrics: {
      generation: 3,
      total_turns: 12,
      total_input_tokens: 1200,
      total_output_tokens: 800,
      total_tokens: 2000,
      total_cost_usd: 0.12,
      last_model_used: 'llama:test-balanced',
      last_input_tokens: 120,
      last_output_tokens: 80,
      last_total_tokens: 200,
      last_latency_ms: 2400,
      last_total_tokens_per_sec: 22.4,
      last_output_tokens_per_sec: 11.2,
      compaction_count: 1,
    },
  })),
  patchKeeperConfig: vi.fn(),
}))

vi.mock('../api/dashboard', () => ({
  fetchKeeperConfig: mocks.fetchKeeperConfig,
  patchKeeperConfig: mocks.patchKeeperConfig,
}))

import { KeeperConfigPanel, loadKeeperConfig, resetKeeperConfig } from './keeper-config-panel'

async function flush() {
  await new Promise(resolve => setTimeout(resolve, 0))
}

describe('KeeperConfigPanel', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    resetKeeperConfig()
    mocks.fetchKeeperConfig.mockClear()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    resetKeeperConfig()
  })

  it('separates editable prompt controls from read-only runtime metadata', async () => {
    render(html`<${KeeperConfigPanel} keeperName="keeper-sangsu" />`, container)
    await flush()
    await flush()

    expect(mocks.fetchKeeperConfig).toHaveBeenCalledTimes(1)
    expect(container.textContent).toContain('편집 가능 범위')
    expect(container.textContent).toContain('resolved config root의 cascade.json')
    expect(container.textContent).toContain('런타임 설정')
    expect(container.textContent).toContain('/tmp/.masc/keepers/keeper-sangsu/live.json')
    expect(container.textContent).toContain('활성 모델')
    expect(container.textContent).toContain('레지스트리 상태')
    expect(container.textContent).toContain('running')
    expect(container.textContent).toContain('dynamic_boundary (Tool_dispatch.is_destructive)')

    const editButton = Array.from(container.querySelectorAll('button')).find(button =>
      button.textContent?.includes('편집'),
    )
    editButton?.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flush()

    const textareas = Array.from(container.querySelectorAll('textarea'))
    expect(textareas.length).toBeGreaterThan(0)
    expect(textareas[0]?.value).toContain('Ship stable keeper ops')
  })

  it('supports forced config refresh for already-loaded keepers', async () => {
    await loadKeeperConfig('keeper-sangsu')
    await loadKeeperConfig('keeper-sangsu')
    await loadKeeperConfig('keeper-sangsu', { force: true })

    expect(mocks.fetchKeeperConfig).toHaveBeenCalledTimes(2)
  })
})
