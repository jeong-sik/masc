// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent, waitFor } from '@testing-library/preact'

vi.mock('../router', async (importOriginal) => ({
  ...(await importOriginal<typeof import('../router')>()),
  navigate: vi.fn(),
}))
import { navigate } from '../router'

import { missionSnapshot } from '../mission-signals'
import {
  AttentionIndicator,
  attentionItemBucket,
  summarizeAttention,
  BUCKET_META,
} from './attention-indicator'
import type {
  DashboardMissionAttentionQueueItem,
  DashboardMissionResponse,
} from '../types/dashboard-mission'

function item(
  partial: Partial<DashboardMissionAttentionQueueItem>,
): DashboardMissionAttentionQueueItem {
  return {
    id: 'i',
    kind: 'unknown_kind',
    severity: 'warn',
    summary: '',
    target_type: 'workspace',
    related_session_ids: [],
    related_agent_names: [],
    evidence_preview: [],
    ...partial,
  }
}

function setQueue(items: DashboardMissionAttentionQueueItem[]): void {
  missionSnapshot.value = { attention_queue: items } as unknown as DashboardMissionResponse
}

describe('attentionItemBucket', () => {
  it('routes the approval kind to approvals (by kind)', () => {
    expect(attentionItemBucket({ kind: 'pending_confirm_waiting', target_type: 'workspace' })).toBe('approvals')
  })
  it('routes a keeper target_type to keepers', () => {
    expect(attentionItemBucket({ kind: 'keeper_stalled', target_type: 'keeper' })).toBe('keepers')
  })
  it('routes everything else to an explicit other bucket', () => {
    expect(attentionItemBucket({ kind: 'tool_host_failure', target_type: 'workspace' })).toBe('other')
  })
  it('prefers the approval kind even on a keeper target', () => {
    expect(attentionItemBucket({ kind: 'pending_confirm_waiting', target_type: 'keeper' })).toBe('approvals')
  })
})

describe('summarizeAttention', () => {
  it('returns an empty summary for no items', () => {
    expect(summarizeAttention([])).toEqual({ total: 0, tone: 'warn', buckets: [] })
  })

  it('counts items into buckets and keeps total === queue length (no silent drop)', () => {
    const s = summarizeAttention([
      item({ kind: 'pending_confirm_waiting' }),
      item({ kind: 'pending_confirm_waiting' }),
      item({ target_type: 'keeper', kind: 'keeper_x' }),
      item({ kind: 'tool_host_failure' }),
    ])
    expect(s.total).toBe(4)
    const counts = Object.fromEntries(s.buckets.map((b) => [b.key, b.count]))
    expect(counts).toEqual({ approvals: 2, keepers: 1, other: 1 })
    // the bucket counts cover every queued item
    expect(s.buckets.reduce((n, b) => n + b.count, 0)).toBe(s.total)
  })

  it('omits empty buckets and keeps a fixed approvals→keepers→other order', () => {
    const s = summarizeAttention([
      item({ kind: 'tool_host_failure' }), // other
      item({ kind: 'pending_confirm_waiting' }), // approvals
    ])
    expect(s.buckets.map((b) => b.key)).toEqual(['approvals', 'other'])
  })

  it('marks a bucket and the chip bad when any item is critical or bad', () => {
    const s = summarizeAttention([
      item({ target_type: 'keeper', kind: 'keeper_a', severity: 'warn' }),
      item({ target_type: 'keeper', kind: 'keeper_b', severity: 'critical' }),
    ])
    expect(s.buckets.find((b) => b.key === 'keepers')?.tone).toBe('bad')
    expect(s.tone).toBe('bad')
  })

  it('keeps tone warn when every item is warn', () => {
    expect(summarizeAttention([item({ severity: 'warn' })]).tone).toBe('warn')
  })
})

describe('BUCKET_META nav targets', () => {
  it('maps each bucket to a real surface tab', () => {
    expect(BUCKET_META.approvals.tab).toBe('approvals')
    expect(BUCKET_META.keepers.tab).toBe('keepers')
    expect(BUCKET_META.other.tab).toBe('overview')
  })
})

describe('AttentionIndicator component', () => {
  let container: HTMLDivElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    vi.mocked(navigate).mockClear()
  })
  afterEach(() => {
    render(null, container)
    container.remove()
    missionSnapshot.value = null
  })

  it('renders the ✓ 정상 zero-state when the queue is empty', () => {
    setQueue([])
    render(html`<${AttentionIndicator} />`, container)
    const el = container.querySelector('[data-attention-indicator]')
    expect(el?.getAttribute('data-attention-total')).toBe('0')
    expect(el?.textContent).toContain('정상')
  })

  it('renders the 주의 chip with the total and a bad tone', () => {
    setQueue([
      item({ kind: 'pending_confirm_waiting', severity: 'bad' }),
      item({ target_type: 'keeper', kind: 'keeper_x', severity: 'warn' }),
    ])
    render(html`<${AttentionIndicator} />`, container)
    const wrap = container.querySelector('[data-attention-indicator]')
    expect(wrap?.getAttribute('data-attention-total')).toBe('2')
    const chip = container.querySelector('button.v2-statchip.attn')
    expect(chip?.className).toContain('bad')
    expect(chip?.textContent).toContain('주의')
    expect(chip?.textContent).toContain('2')
  })

  it('opens the categorized dropdown on chip click and navigates on row click', async () => {
    setQueue([
      item({ kind: 'pending_confirm_waiting', severity: 'bad' }),
      item({ target_type: 'keeper', kind: 'keeper_x', severity: 'warn' }),
    ])
    render(html`<${AttentionIndicator} />`, container)
    const chip = container.querySelector('button.v2-statchip.attn') as HTMLButtonElement
    fireEvent.click(chip)
    await waitFor(() => {
      expect(container.querySelector('[role="menu"]')).not.toBeNull()
    })
    expect(container.querySelectorAll('[data-attention-bucket]').length).toBe(2)
    const approvalsRow = container.querySelector('[data-attention-bucket="approvals"]') as HTMLButtonElement
    fireEvent.click(approvalsRow)
    await waitFor(() => {
      expect(vi.mocked(navigate)).toHaveBeenCalledWith('approvals')
    })
  })

  it('closes the dropdown on outside click and Escape', async () => {
    setQueue([
      item({ kind: 'pending_confirm_waiting', severity: 'bad' }),
      item({ target_type: 'keeper', kind: 'keeper_x', severity: 'warn' }),
    ])
    render(html`<${AttentionIndicator} />`, container)
    const chip = container.querySelector('button.v2-statchip.attn') as HTMLButtonElement

    fireEvent.click(chip)
    await waitFor(() => {
      expect(container.querySelector('[role="menu"]')).not.toBeNull()
    })
    fireEvent.click(document)
    await waitFor(() => {
      expect(container.querySelector('[role="menu"]')).toBeNull()
    })

    fireEvent.click(chip)
    await waitFor(() => {
      expect(container.querySelector('[role="menu"]')).not.toBeNull()
    })
    fireEvent.keyDown(document, { key: 'Escape' })
    await waitFor(() => {
      expect(container.querySelector('[role="menu"]')).toBeNull()
    })
  })
})
