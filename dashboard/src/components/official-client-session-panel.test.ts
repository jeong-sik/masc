// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { fireEvent, render, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { keepers } from '../store'
import { OfficialClientSessionPanel } from './official-client-session-panel'

const apiMocks = vi.hoisted(() => ({
  fetchOfficialClientSession: vi.fn(),
  resolveOfficialClientSession: vi.fn(),
}))

vi.mock('../api/dashboard', () => apiMocks)

const recoveryResponse = {
  schema: 'masc.dashboard.official-client-session.v1' as const,
  ok: true as const,
  keeper_name: 'sangsu',
  session: {
    client_kind: 'codex' as const,
    runtime_id: 'codex.codex',
    phase: {
      kind: 'recovery_required' as const,
      recovery_id: '018f3a4a-27f4-7c9a-8fd8-330c2a3845aa',
      failure: 'protocol_failed' as const,
      detail: 'malformed app-server event',
      required_at: 1_786_230_000,
      owner_epoch: '018f3a4a-27f4-7c9a-8fd8-330c2a3845ab',
      observed_session_id: 'thread-observed',
      observed_turn_id: null,
      previous_settlement: null,
    },
    turn_count: 1,
    tool_surface_sha256: 'a'.repeat(64),
    last_recovery_resolution: null,
    last_transient_release: null,
    updated_at: 1_786_230_000,
  },
}

const resolvedResponse = {
  ...recoveryResponse,
  resolution_application: 'applied' as const,
  audit: { recorded: true as const },
  session: {
    ...recoveryResponse.session,
    phase: {
      kind: 'ready' as const,
    },
    last_recovery_resolution: {
      recovery_id: recoveryResponse.session.phase.recovery_id,
      failure: 'protocol_failed' as const,
      resolution: { kind: 'restart_fresh' as const },
      resolved_by: 'dashboard',
      resolved_at: 1_786_230_010,
    },
  },
}

describe('OfficialClientSessionPanel', () => {
  beforeEach(() => {
    keepers.value = [{ name: 'sangsu', status: 'idle', runtime_id: 'codex.codex' }]
    apiMocks.fetchOfficialClientSession.mockReset().mockResolvedValue(recoveryResponse)
    apiMocks.resolveOfficialClientSession.mockReset().mockResolvedValue(resolvedResponse)
  })

  afterEach(() => {
    keepers.value = []
  })

  it('shows measured recovery evidence and resolves the exact recovery fence', async () => {
    const view = render(html`<${OfficialClientSessionPanel} />`)

    await waitFor(() => {
      expect(view.getByTestId('official-client-session-phase').textContent).toContain('recovery_required')
    })
    expect(view.getByTestId('official-client-session-evidence').textContent).toContain('codex.codex')
    expect(view.getByTestId('official-client-session-recovery-required').textContent).toContain('protocol_failed')
    expect(view.getByTestId('official-client-session-recovery-required').textContent).toContain('thread-observed')

    fireEvent.click(view.getByTestId('official-client-session-restart-fresh'))

    await waitFor(() => {
      expect(apiMocks.resolveOfficialClientSession).toHaveBeenCalledWith(
        'sangsu',
        recoveryResponse.session.phase.recovery_id,
        { resolution: 'restart_fresh' },
      )
    })
  })

  it('offers retry without accepting caller-supplied settlement identities', async () => {
    const view = render(html`<${OfficialClientSessionPanel} />`)

    await waitFor(() => {
      expect(view.getByTestId('official-client-session-retry-previous')).toBeTruthy()
    })
    fireEvent.click(view.getByTestId('official-client-session-retry-previous'))

    await waitFor(() => {
      expect(apiMocks.resolveOfficialClientSession).toHaveBeenCalledWith(
        'sangsu',
        recoveryResponse.session.phase.recovery_id,
        { resolution: 'retry_previous' },
      )
      expect(view.getByTestId('official-client-session-last-resolution').textContent).toContain('dashboard')
    })
  })

})
