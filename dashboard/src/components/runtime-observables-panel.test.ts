// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { cleanup, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import type { RuntimeObservablesSnapshot } from '../api/runtime-observables'

const mockFetch = vi.fn<() => Promise<RuntimeObservablesSnapshot>>()

vi.mock('../api/runtime-observables', async (importOriginal) => {
  const original = await importOriginal<typeof import('../api/runtime-observables')>()
  return {
    ...original,
    fetchRuntimeObservables: () => mockFetch(),
  }
})

import { decodeRuntimeObservables } from '../api/runtime-observables'
import { RuntimeObservablesPanel } from './runtime-observables-panel'

function makeSnapshot(
  overrides: Partial<RuntimeObservablesSnapshot> = {},
): RuntimeObservablesSnapshot {
  return {
    last_write_unixtime: 1_766_000_000,
    age_seconds: 12,
    console_sink: { queue_depth: 3, dropped_total: 0 },
    transition_audit: { queue_depth: 1 },
    fd: {
      open: 210,
      limit: 10_240,
      active_operations: [{ kind: 'jsonl_append', count: 2 }],
      resource_errors: [],
    },
    stores: [
      { store: 'logs', bytes: 2048, files: 4 },
      { store: 'tool_calls', bytes: 1_500_000, files: 12 },
    ],
    event_bus: [
      {
        bus: 'masc_domain',
        subscribers: 2,
        contracts: [
          {
            purpose: 'keeper_lifecycle',
            capacity: 1024,
            overflow: 'drop_oldest',
            depth: 0,
            dropped_total: 0,
            capacity_total: 1024,
          },
        ],
      },
    ],
    pool: {
      idle: 1,
      inflight: 0,
      reuse_total: 42,
      evict_total: 3,
      evict_failure_total: 0,
      create_total: 7,
    },
    ...overrides,
  }
}

describe('RuntimeObservablesPanel', () => {
  beforeEach(() => {
    mockFetch.mockReset()
  })

  afterEach(() => {
    cleanup()
  })

  it('renders the written cells as stats, stores, and bus contracts', async () => {
    mockFetch.mockResolvedValue(makeSnapshot())
    render(html`<${RuntimeObservablesPanel} />`)

    await waitFor(() => {
      expect(screen.getByText('프로세스 관측')).toBeTruthy()
    })
    expect(screen.getByText('12초 전 샘플')).toBeTruthy()
    expect(screen.getByText('콘솔 싱크 큐')).toBeTruthy()
    expect(screen.getByText('logs')).toBeTruthy()
    expect(screen.getByText('1.43 MB')).toBeTruthy()
    expect(screen.getByText('masc_domain')).toBeTruthy()
    expect(screen.getByText('keeper_lifecycle')).toBeTruthy()
  })

  it('renders absent cells as dashes, never as zero', async () => {
    mockFetch.mockResolvedValue(
      makeSnapshot({
        age_seconds: null,
        last_write_unixtime: null,
        console_sink: { queue_depth: null, dropped_total: null },
        pool: {
          idle: null,
          inflight: null,
          reuse_total: null,
          evict_total: null,
          evict_failure_total: null,
          create_total: null,
        },
      }),
    )
    render(html`<${RuntimeObservablesPanel} />`)

    await waitFor(() => {
      expect(screen.getByText('샘플 없음')).toBeTruthy()
    })
    const queueStat = document.querySelector('[data-observable-stat="콘솔 싱크 큐"]')
    expect(queueStat?.textContent).toContain('—')
    expect(queueStat?.textContent).not.toContain('0')
  })

  it('surfaces a fetch failure instead of an empty panel', async () => {
    mockFetch.mockRejectedValue(new Error('연결 실패'))
    render(html`<${RuntimeObservablesPanel} />`)

    await waitFor(() => {
      expect(
        document.querySelector('[data-observables-state="error"]')?.textContent,
      ).toContain('연결 실패')
    })
  })
})

describe('decodeRuntimeObservables', () => {
  it('round-trips a full server payload', () => {
    const snapshot = makeSnapshot()
    expect(decodeRuntimeObservables(JSON.parse(JSON.stringify(snapshot)))).toEqual(snapshot)
  })

  it('rejects structural drift instead of guessing', () => {
    const broken = JSON.parse(JSON.stringify(makeSnapshot())) as Record<string, unknown>
    delete broken.console_sink
    expect(decodeRuntimeObservables(broken)).toBeNull()
    expect(decodeRuntimeObservables({ stores: 'not-a-list' })).toBeNull()
  })
})
