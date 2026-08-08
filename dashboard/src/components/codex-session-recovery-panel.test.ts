// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { fireEvent, render, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { keepers } from '../store'
import { CodexSessionRecoveryPanel } from './codex-session-recovery-panel'

const apiMocks = vi.hoisted(() => ({
  fetchCodexSession: vi.fn(),
  resolveCodexSession: vi.fn(),
}))

vi.mock('../api/dashboard', () => apiMocks)

const recoveryResponse = {
  schema: 'masc.dashboard.codex-session.v1' as const,
  ok: true as const,
  keeper_name: 'sangsu',
  session: {
    runtime_id: 'codex.codex',
    phase: {
      kind: 'recovery_required' as const,
      recovery_id: '018f3a4a-27f4-7c9a-8fd8-330c2a3845aa',
      failure: 'protocol_failed' as const,
      detail: 'malformed app-server event',
      required_at: 1_786_230_000,
      observed_thread_id: 'thread-observed',
      observed_turn_id: null,
      previous_settlement: null,
    },
    turn_count: 1,
    tool_surface_sha256: 'a'.repeat(64),
    last_recovery_resolution: null,
    updated_at: 1_786_230_000,
  },
}

const settledResponse = {
  ...recoveryResponse,
  session: {
    ...recoveryResponse.session,
    phase: {
      kind: 'settled' as const,
      thread_id: 'thread-verified',
      turn_id: 'turn-verified',
    },
    last_recovery_resolution: {
      recovery_id: recoveryResponse.session.phase.recovery_id,
      failure: 'protocol_failed' as const,
      resolution: { kind: 'adopt_verified' as const, settlement: { thread_id: 'thread-verified', turn_id: 'turn-verified' } },
      resolved_by: 'dashboard',
      resolved_at: 1_786_230_010,
    },
  },
}

describe('CodexSessionRecoveryPanel', () => {
  beforeEach(() => {
    keepers.value = [{ name: 'sangsu', status: 'idle', runtime_id: 'codex.codex' }]
    apiMocks.fetchCodexSession.mockReset().mockResolvedValue(recoveryResponse)
    apiMocks.resolveCodexSession.mockReset().mockResolvedValue(settledResponse)
  })

  afterEach(() => {
    keepers.value = []
  })

  it('shows measured recovery evidence and resolves the exact recovery fence', async () => {
    const view = render(html`<${CodexSessionRecoveryPanel} />`)

    await waitFor(() => {
      expect(view.getByTestId('codex-session-phase').textContent).toContain('recovery_required')
    })
    expect(view.getByTestId('codex-session-evidence').textContent).toContain('codex.codex')
    expect(view.getByTestId('codex-session-recovery-required').textContent).toContain('protocol_failed')
    expect(view.getByTestId('codex-session-recovery-required').textContent).toContain('thread-observed')

    fireEvent.click(view.getByTestId('codex-session-restart-fresh'))

    await waitFor(() => {
      expect(apiMocks.resolveCodexSession).toHaveBeenCalledWith(
        'sangsu',
        recoveryResponse.session.phase.recovery_id,
        { resolution: 'restart_fresh' },
      )
    })
  })

  it('requires both verified identities before adoption and shows the durable actor', async () => {
    const view = render(html`<${CodexSessionRecoveryPanel} />`)

    await waitFor(() => {
      expect(view.getByTestId('codex-session-adopt-verified')).toBeTruthy()
    })
    const adoptButton = view.getByTestId('codex-session-adopt-verified') as HTMLButtonElement
    expect(adoptButton.disabled).toBe(true)

    fireEvent.input(view.getByTestId('codex-session-adopt-thread'), {
      target: { value: 'thread-verified' },
    })
    fireEvent.input(view.getByTestId('codex-session-adopt-turn'), {
      target: { value: 'turn-verified' },
    })
    expect(adoptButton.disabled).toBe(false)
    fireEvent.click(adoptButton)

    await waitFor(() => {
      expect(apiMocks.resolveCodexSession).toHaveBeenCalledWith(
        'sangsu',
        recoveryResponse.session.phase.recovery_id,
        {
          resolution: 'adopt_verified',
          thread_id: 'thread-verified',
          turn_id: 'turn-verified',
        },
      )
      expect(view.getByTestId('codex-session-last-resolution').textContent).toContain('dashboard')
    })
  })
})
