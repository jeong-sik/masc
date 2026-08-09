// @vitest-environment happy-dom
import { html } from 'htm/preact'
import { fireEvent, render, waitFor } from '@testing-library/preact'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { OfficialClientLoginProbe } from './official-client-login-probe'

const apiMocks = vi.hoisted(() => ({
  probeOfficialClientLogin: vi.fn(),
}))

vi.mock('../api/dashboard', () => apiMocks)

const readyResponse = {
  schema: 'masc.dashboard.official-client-probe.v1' as const,
  ok: true as const,
  runtime_id: 'codex.codex',
  client_kind: 'codex' as const,
  configured_model: 'gpt-5.3-codex-spark',
  measured_at: 1_786_230_100,
  login: {
    status: 'ready' as const,
    authenticated: true,
    evidence_source: 'configured_executable_self_report' as const,
    identity_verified: false as const,
    auth_method: 'chatgpt',
    subscription_type: 'pro',
    api_provider: null,
    detail: null,
  },
  client: { user_agent: 'codex_cli_rs/0.147.0' },
  execution: {
    status: 'not_measured' as const,
    reason: 'login_probe_does_not_submit_model_turn' as const,
  },
}

describe('OfficialClientLoginProbe', () => {
  beforeEach(() => {
    apiMocks.probeOfficialClientLogin.mockReset().mockResolvedValue(readyResponse)
  })

  it('does not probe automatically and keeps execution visibly unmeasured', async () => {
    const view = render(html`<${OfficialClientLoginProbe}
      runtimeId="codex.codex"
      configuredModel="gpt-5.3-codex-spark"
    />`)

    expect(apiMocks.probeOfficialClientLogin).not.toHaveBeenCalled()
    expect(view.getByTestId('official-client-probe-login').textContent).toContain('not_measured')
    expect(view.getByTestId('official-client-probe-execution').textContent).toContain('not_measured')

    fireEvent.click(view.getByTestId('official-client-login-probe-run-codex.codex'))

    await waitFor(() => {
      expect(apiMocks.probeOfficialClientLogin).toHaveBeenCalledWith('codex.codex')
      expect(view.getByTestId('official-client-probe-login').textContent).toContain('self_reported')
    })
    expect(view.getByTestId('official-client-probe-details').textContent).toContain('pro')
    expect(view.getByTestId('official-client-probe-details').textContent).toContain('unverified')
    expect(view.getByTestId('official-client-probe-execution').textContent).toContain('not_measured')
  })

  it('renders a measured login failure without claiming an execution failure', async () => {
    apiMocks.probeOfficialClientLogin.mockResolvedValueOnce({
      ...readyResponse,
      login: {
        status: 'login_required' as const,
        authenticated: false,
        evidence_source: 'configured_executable_self_report' as const,
        identity_verified: false as const,
        auth_method: null,
        subscription_type: null,
        api_provider: null,
        detail: 'official CLI has no active subscription account',
      },
    })
    const view = render(html`<${OfficialClientLoginProbe} runtimeId="codex.codex" />`)

    fireEvent.click(view.getByTestId('official-client-login-probe-run-codex.codex'))

    await waitFor(() => {
      expect(view.getByTestId('official-client-probe-login').textContent).toContain('login_required')
    })
    expect(view.getByTestId('official-client-probe-detail').textContent).toContain('no active subscription')
    expect(view.getByTestId('official-client-probe-execution').textContent).toContain('not_measured')
  })
})
