import { html } from 'htm/preact'
import { cleanup, render, screen, waitFor, within } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

const fetchProofMock = vi.hoisted(() => vi.fn())
const unregisterMock = vi.hoisted(() => vi.fn())

vi.mock('../api/dashboard', () => ({
  fetchKeeperPersistenceProof: fetchProofMock,
}))

vi.mock('../sse-store', () => ({
  registerInternalAgentRefresh: vi.fn(() => unregisterMock),
}))

import { KeeperPersistenceProofPanel, keeperProofTone } from './keeper-persistence-proof-panel'

const response = {
  generatedAt: '2026-08-14T12:00:00Z',
  status: 'warn' as const,
  summary: '1/2 keepers have durable turn spans >= 24h',
  tiers: [
    {
      id: '1h' as const,
      requiredSpanHours: 1,
      status: 'pass' as const,
      evidenceKind: 'durable_turn_span' as const,
      keeperCount: 2,
      observedCount: 2,
      missingCount: 0,
      undeterminedCount: 0,
      observedKeepers: ['keeper-a', 'keeper-b'],
      missingKeepers: [],
      undeterminedKeepers: [],
    },
    {
      id: '2h' as const,
      requiredSpanHours: 2,
      status: 'pass' as const,
      evidenceKind: 'durable_turn_span' as const,
      keeperCount: 2,
      observedCount: 2,
      missingCount: 0,
      undeterminedCount: 0,
      observedKeepers: ['keeper-a', 'keeper-b'],
      missingKeepers: [],
      undeterminedKeepers: [],
    },
    {
      id: '4h' as const,
      requiredSpanHours: 4,
      status: 'warn' as const,
      evidenceKind: 'durable_turn_span' as const,
      keeperCount: 2,
      observedCount: 1,
      missingCount: 1,
      undeterminedCount: 0,
      observedKeepers: ['keeper-a'],
      missingKeepers: ['keeper-b'],
      undeterminedKeepers: [],
    },
    {
      id: '24h' as const,
      requiredSpanHours: 24,
      status: 'warn' as const,
      evidenceKind: 'durable_turn_span' as const,
      keeperCount: 2,
      observedCount: 1,
      missingCount: 1,
      undeterminedCount: 0,
      observedKeepers: ['keeper-a'],
      missingKeepers: ['keeper-b'],
      undeterminedKeepers: [],
    },
  ],
}

describe('KeeperPersistenceProofPanel', () => {
  beforeEach(() => {
    fetchProofMock.mockReset()
    fetchProofMock.mockResolvedValue(response)
    unregisterMock.mockClear()
  })

  afterEach(() => cleanup())

  it('maps the closed proof status vocabulary to semantic tones', () => {
    expect(keeperProofTone('pass')).toBe('ok')
    expect(keeperProofTone('warn')).toBe('warn')
    expect(keeperProofTone('fail')).toBe('bad')
  })

  it('renders all durable tiers and exposes missing Keeper evidence', async () => {
    render(html`<${KeeperPersistenceProofPanel} />`)

    const panel = await screen.findByTestId('keeper-persistence-proof-panel')
    await waitFor(() => expect(fetchProofMock).toHaveBeenCalledTimes(1))
    await screen.findByTestId('keeper-persistence-tier-24h')
    expect(within(panel).getByText(/무중단 uptime 증거가 아닙니다/)).toBeTruthy()
    expect(panel.getAttribute('data-proof-generated-at')).toBe(response.generatedAt)
    for (const id of ['1h', '2h', '4h', '24h']) {
      expect(within(panel).getByTestId(`keeper-persistence-tier-${id}`)).toBeTruthy()
    }
    const tier24h = within(panel).getByTestId('keeper-persistence-tier-24h')
    expect(tier24h).toHaveAttribute('data-proof-status', 'warn')
    expect(tier24h).toHaveAttribute('data-evidence-kind', 'durable_turn_span')
    expect(within(tier24h).getByText('keeper-b')).toBeTruthy()
  })

  it('shows a Keeper whose history was never read apart from a failing one', async () => {
    const tiers = response.tiers.map(tier => ({
      ...tier,
      status: 'warn' as const,
      keeperCount: 3,
      observedCount: 1,
      missingCount: 1,
      undeterminedCount: 1,
      observedKeepers: ['keeper-a'],
      missingKeepers: ['keeper-b'],
      undeterminedKeepers: ['keeper-c'],
    }))
    fetchProofMock.mockResolvedValue({ ...response, tiers })

    render(html`<${KeeperPersistenceProofPanel} />`)
    const panel = await screen.findByTestId('keeper-persistence-proof-panel')
    const tier24h = await within(panel).findByTestId('keeper-persistence-tier-24h')

    expect(tier24h).toHaveAttribute('data-undetermined-count', '1')
    const missing = within(tier24h).getByTestId('keeper-persistence-missing-24h')
    const undetermined = within(tier24h).getByTestId('keeper-persistence-undetermined-24h')
    expect(missing.textContent).toContain('keeper-b')
    expect(missing.textContent).not.toContain('keeper-c')
    expect(undetermined.textContent).toContain('keeper-c')
    expect(undetermined.textContent).not.toContain('keeper-b')
  })
})
