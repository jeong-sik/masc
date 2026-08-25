// fleet-aside-extras — keeper-v2 Fleet aside 잔여 섹션 (fl-q-* / fl-rot-* /
// fl-as-mini) 의 라이브 소스 연결을 검증한다. 핵심 규칙은 mark don't fake:
// 관측되지 않는 값(큐 회계, failover 이벤트, tps)은 렌더하지 않는다.

import { html } from 'htm/preact'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  FleetAsideActions,
  FleetQueueSection,
  FleetRotationSection,
  fleetActivityMinis,
} from './fleet-aside-extras'
import type { Keeper } from '../types'
import type { RuntimeResolvedResponse } from '../api'
import { loaded, idle } from '../lib/async-state'

vi.mock('../keeper-waiting-inventory-store', async importOriginal => {
  const original = await importOriginal<typeof import('../keeper-waiting-inventory-store')>()
  return {
    ...original,
    subscribeKeeperWaitingInventory: vi.fn(() => vi.fn()),
  }
})

vi.mock('../lib/runtime-resolved-resource', async importOriginal => {
  const original = await importOriginal<typeof import('../lib/runtime-resolved-resource')>()
  return {
    ...original,
    loadRuntimeResolved: vi.fn(() => Promise.resolve()),
  }
})

import { keeperWaitingInventoryStates } from '../keeper-waiting-inventory-store'
import { runtimeResolvedState } from '../lib/runtime-resolved-resource'

function makeKeeper(overrides: Partial<Keeper> = {}): Keeper {
  return {
    name: 'sangsu',
    agent_name: 'keeper-sangsu-agent',
    status: 'active',
    phase: 'Running',
    registered: true,
    keepalive_running: true,
    ...overrides,
  } as Keeper
}

async function flushUi(): Promise<void> {
  await act(async () => {
    await Promise.resolve()
  })
}

describe('fleetActivityMinis', () => {
  it('returns nothing for a missing keeper', () => {
    expect(fleetActivityMinis(null)).toEqual([])
    expect(fleetActivityMinis(undefined)).toEqual([])
  })

  it('renders only counters the keeper actually reported', () => {
    const minis = fleetActivityMinis(makeKeeper({ drift_count_total: 2 }))
    expect(minis).toEqual([{ k: '드리프트', v: '2' }])
  })

  it('never fabricates the design tps/traces slots', () => {
    const minis = fleetActivityMinis(makeKeeper({}))
    expect(minis.map(m => m.k)).not.toContain('초당 토큰')
    expect(minis.map(m => m.k)).not.toContain('트레이스')
  })
})

describe('FleetQueueSection (fl-q-*)', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    keeperWaitingInventoryStates.value = {}
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    keeperWaitingInventoryStates.value = {}
  })

  function seedInventory(waitingOn: unknown[]): void {
    keeperWaitingInventoryStates.value = {
      sangsu: {
        inventory: {
          keeper_count: 1,
          waiting_keeper_count: 1,
          row_count: waitingOn.length,
          keepers: [
            {
              keeper_name: 'sangsu',
              state: 'waiting',
              waiting_on: waitingOn,
              waiting_count: waitingOn.length,
            },
          ],
        },
        ready: true,
        loading: false,
        error: null,
      } as never,
    }
  }

  it('renders nothing when neither queue rows nor heartbeat signal exist', async () => {
    await act(async () => {
      render(html`<${FleetQueueSection} keeper=${makeKeeper({ keepalive_running: undefined, keeper_keepalive_interval_s: undefined })} />`, container)
    })
    await flushUi()
    expect(container.querySelector('.fl-q')).toBeNull()
  })

  it('renders waiting rows from the live keeper waiting inventory', async () => {
    seedInventory([
      {
        source: 'hitl_pending',
        waiting_on: 'HITL H-038 결재 대기',
        what: '승인 대기 중',
        wake_producer: 'hitl',
        since_iso: '2026-08-23T04:00:00Z',
        next_action: '승인 처리',
      },
      {
        source: 'event_queue_pending',
        waiting_on: 'keeper_event_queue pending',
        what: '자율 이벤트 대기',
        wake_producer: null,
        since_iso: null,
        next_action: '드레인 대기',
      },
    ])

    await act(async () => {
      render(html`<${FleetQueueSection} keeper=${makeKeeper()} />`, container)
    })
    await flushUi()

    const items = container.querySelectorAll('.fl-q-item')
    expect(items).toHaveLength(2)
    expect(items[0]?.querySelector('.fl-q-kind')?.textContent).toBe('승인 대기')
    expect(items[0]?.querySelector('.fl-q-gl')?.textContent).toBe('⚿')
    expect(items[0]?.querySelector('.fl-q-from')?.textContent).toBe('hitl')
    // 두 번째 행은 since 가 없다 — 디자인의 시각 미기록 arm.
    expect(items[1]?.querySelector('.fl-q-at')?.textContent).toBe('시각 미기록')
    expect(container.querySelector('[data-testid="fleet-queue-section"] h4')?.textContent)
      .toBe('들어온 이벤트')
    // 회계(admitted/deferred/dropped)는 라이브 소스가 없어 렌더하지 않는다.
    expect(container.querySelector('.fl-q-acct')).toBeNull()
  })

  it('marks rows as draining when the keeper is in Draining phase', async () => {
    seedInventory([
      {
        source: 'schedule_waiting',
        waiting_on: 'schedule_runner',
        what: '예약 실행 대기',
        since_iso: '2026-08-23T04:00:00Z',
        next_action: '드레인',
      },
    ])

    await act(async () => {
      render(html`<${FleetQueueSection} keeper=${makeKeeper({ phase: 'Draining' })} />`, container)
    })
    await flushUi()

    expect(container.querySelector('.fl-q-item.drain')).not.toBeNull()
    expect(container.querySelector('[data-testid="fleet-queue-section"] h4')?.textContent)
      .toBe('드레인 대기')
  })

  it('renders the live keepalive cadence and last heartbeat', async () => {
    await act(async () => {
      render(html`<${FleetQueueSection} keeper=${makeKeeper({
        keeper_keepalive_interval_s: 15,
        last_heartbeat: '2026-08-23T05:00:00Z',
      })} />`, container)
    })
    await flushUi()

    const hb = container.querySelector('.fl-q-hb')
    expect(hb?.textContent).toContain('15초마다 깨어남')
    expect(hb?.textContent).toContain('마지막')
    expect(hb?.querySelector('.fl-q-hb-dot')).not.toBeNull()
  })

  it('renders the off arm only when keepalive is explicitly reported stopped', async () => {
    await act(async () => {
      render(html`<${FleetQueueSection} keeper=${makeKeeper({
        keepalive_running: false,
        phase: 'Paused',
      })} />`, container)
    })
    await flushUi()

    const hb = container.querySelector('.fl-q-hb.off')
    expect(hb?.textContent).toContain('깨어나지 않음')
  })

  it('surfaces a heartbeat ledger read error instead of a stale timestamp', async () => {
    await act(async () => {
      render(html`<${FleetQueueSection} keeper=${makeKeeper({
        heartbeat_observation_error: 'ledger read failed',
      })} />`, container)
    })
    await flushUi()

    expect(container.querySelector('.fl-q-hb.off')?.textContent)
      .toContain('하트비트 기록 읽기 실패 · ledger read failed')
  })
})

describe('FleetRotationSection (fl-rot-*)', () => {
  let container: HTMLDivElement

  const RESOLVED: RuntimeResolvedResponse = {
    config_path: '/tmp/runtime.toml',
    default_runtime: null,
    runtimes: [],
    lanes: [
      {
        id: 'lane-main',
        runtime_ids: ['claude/main', 'codex/main', 'local/gguf'],
        preferred_candidate: 'codex/main',
        preferred_at_ts: 1_700_000_000,
      },
    ],
    assignments: [
      { keeper: 'sangsu', assignment_source: 'explicit', resolved: { kind: 'lane', id: 'lane-main' } },
      { keeper: 'solo', assignment_source: 'explicit', resolved: { kind: 'single_runtime', id: 'claude/main' } },
    ],
  }

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    runtimeResolvedState.value = idle
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    runtimeResolvedState.value = idle
  })

  it('renders nothing until runtime/resolved has loaded', async () => {
    await act(async () => {
      render(html`<${FleetRotationSection} keeper=${makeKeeper()} />`, container)
    })
    await flushUi()
    expect(container.querySelector('[data-testid="fleet-rotation-section"]')).toBeNull()
  })

  it('renders the lane candidate chain with head + current markers', async () => {
    runtimeResolvedState.value = loaded(RESOLVED)

    await act(async () => {
      render(html`<${FleetRotationSection} keeper=${makeKeeper({ runtime_canonical: 'codex/main' })} />`, container)
    })
    await flushUi()

    const cands = container.querySelectorAll('.fl-rot-cand')
    expect(cands).toHaveLength(3)
    expect(cands[0]?.classList.contains('head')).toBe(true)
    expect(cands[1]?.classList.contains('cur')).toBe(true)
    expect(container.querySelectorAll('.fl-rot-arr')).toHaveLength(2)
    expect(container.querySelector('.fl-rot-note')?.textContent)
      .toContain('codex/main')
    expect(container.querySelector('.fl-as-tag')?.textContent).toBe('후보 3')
  })

  it('renders the na arm for a single-runtime assignment', async () => {
    runtimeResolvedState.value = loaded(RESOLVED)

    await act(async () => {
      render(html`<${FleetRotationSection} keeper=${makeKeeper({ name: 'solo' })} />`, container)
    })
    await flushUi()

    expect(container.querySelector('.fl-rot-na')?.textContent)
      .toBe('단일 런타임에 고정 — 후보 체인 없음')
    expect(container.querySelector('.fl-rot-chain')).toBeNull()
  })

  it('renders the na arm when the assignment is absent', async () => {
    runtimeResolvedState.value = loaded(RESOLVED)

    await act(async () => {
      render(html`<${FleetRotationSection} keeper=${makeKeeper({ name: 'ghost' })} />`, container)
    })
    await flushUi()

    expect(container.querySelector('.fl-rot-na')?.textContent)
      .toContain('할당이 없습니다')
  })

  it('does not invent failover events (fl-rot-ev has no live source)', async () => {
    runtimeResolvedState.value = loaded(RESOLVED)

    await act(async () => {
      render(html`<${FleetRotationSection} keeper=${makeKeeper()} />`, container)
    })
    await flushUi()

    expect(container.querySelector('.fl-rot-ev')).toBeNull()
  })
})

describe('FleetAsideActions (fl-actbar / fl-btn / fl-noact)', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })

  afterEach(() => {
    render(null, container)
    container.remove()
  })

  it('renders only the actions keeperActionVisibility opens for a running keeper', async () => {
    await act(async () => {
      render(html`<${FleetAsideActions} keeper=${makeKeeper()} />`, container)
    })
    await flushUi()

    const keys = Array.from(
      container.querySelectorAll('[data-testid="fleet-aside-actions"] .fl-btn'),
    ).map(el => (el as HTMLElement).dataset.action)
    expect(keys).toEqual(['pause', 'wakeup', 'shutdown'])
    // 종료는 danger arm — 디자인의 a.danger 와 같은 자리.
    const shutdown = container.querySelector('.fl-btn[data-action="shutdown"]')
    expect(shutdown?.classList.contains('danger')).toBe(true)
    expect(shutdown?.querySelector('.g')).not.toBeNull()
    expect(container.querySelector('.fl-noact')).toBeNull()
  })

  it('offers boot + purge (not pause) for an offline keeper', async () => {
    await act(async () => {
      render(html`<${FleetAsideActions} keeper=${makeKeeper({ phase: 'Stopped', status: 'offline' })} />`, container)
    })
    await flushUi()

    const keys = Array.from(
      container.querySelectorAll('[data-testid="fleet-aside-actions"] .fl-btn'),
    ).map(el => (el as HTMLElement).dataset.action)
    expect(keys).toEqual(['boot', 'purge'])
  })
})
