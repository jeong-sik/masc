import { html } from 'htm/preact'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import '@testing-library/jest-dom'

const apiRefs = vi.hoisted(() => ({
  fetchKeeperGithubIdentity: vi.fn(),
  streamKeeperGithubLogin: vi.fn(),
}))

vi.mock('../api/dashboard-keeper-github', () => ({
  fetchKeeperGithubIdentity: apiRefs.fetchKeeperGithubIdentity,
  streamKeeperGithubLogin: apiRefs.streamKeeperGithubLogin,
}))

import type {
  KeeperGithubIdentityObservation,
  KeeperGithubLoginEvent,
} from '../api/dashboard-keeper-github'
import { KeeperGithubIdentityPanel } from './keeper-github-identity-panel'

function makeObservation(
  overrides: Partial<KeeperGithubIdentityObservation> = {},
): KeeperGithubIdentityObservation {
  return {
    ok: true,
    keeper: 'sangsu',
    hostname: 'github.com',
    config_dir: '/tmp/base/.masc/keepers/sangsu/github-cli',
    projected_token_env_names: [],
    stored: { authenticated: true, login: 'masc-sangsu-bot', error: null },
    effective: { authenticated: false, login: null, error: null },
    effective_probe_scope: 'host_process_credential_only',
    checked_at_unix: 1786000000,
    ...overrides,
  }
}

beforeEach(() => {
  apiRefs.fetchKeeperGithubIdentity.mockReset()
  apiRefs.streamKeeperGithubLogin.mockReset()
  apiRefs.fetchKeeperGithubIdentity.mockResolvedValue(makeObservation())
  apiRefs.streamKeeperGithubLogin.mockResolvedValue(undefined)
})

afterEach(() => {
  cleanup()
})

describe('KeeperGithubIdentityPanel', () => {
  it('shows the stored account and the unauthenticated effective probe', async () => {
    apiRefs.fetchKeeperGithubIdentity.mockResolvedValue(
      makeObservation({
        projected_token_env_names: ['GH_TOKEN'],
        effective: { authenticated: false, login: null, error: 'HTTP 401' },
      }),
    )
    render(html`<${KeeperGithubIdentityPanel} keeperName="sangsu" />`)

    await waitFor(() => {
      expect(screen.getByText('@masc-sangsu-bot')).toBeInTheDocument()
    })
    expect(apiRefs.fetchKeeperGithubIdentity).toHaveBeenCalledWith(
      'sangsu',
      'github.com',
      expect.any(AbortSignal),
    )
    expect(screen.getByText('연결 안 됨')).toBeInTheDocument()
    expect(screen.getByText(/확인 실패: HTTP 401/)).toBeInTheDocument()
    expect(screen.getByText(/투영된 토큰 변수: GH_TOKEN/)).toBeInTheDocument()
  })

  it('surfaces a failed observation fetch as a load error', async () => {
    apiRefs.fetchKeeperGithubIdentity.mockRejectedValue(
      new Error('keeper is not registered'),
    )
    render(html`<${KeeperGithubIdentityPanel} keeperName="ghost" />`)

    await waitFor(() => {
      expect(screen.getByText('keeper is not registered')).toBeInTheDocument()
    })
  })

  it('re-probes the identity when 새로고침 is pressed', async () => {
    render(html`<${KeeperGithubIdentityPanel} keeperName="sangsu" />`)
    await waitFor(() => {
      expect(screen.getByText('@masc-sangsu-bot')).toBeInTheDocument()
    })

    fireEvent.click(screen.getByText('새로고침'))

    await waitFor(() => {
      expect(apiRefs.fetchKeeperGithubIdentity).toHaveBeenCalledTimes(2)
    })
  })

  it('streams login output into the modal and closes by aborting the request', async () => {
    const captured: {
      onEvent: ((event: KeeperGithubLoginEvent) => void) | null
      signal: AbortSignal | null
    } = { onEvent: null, signal: null }
    apiRefs.streamKeeperGithubLogin.mockImplementation(
      (
        _keeper: string,
        _hostname: string,
        onEvent: (event: KeeperGithubLoginEvent) => void,
        signal: AbortSignal,
      ) => {
        captured.onEvent = onEvent
        captured.signal = signal
        // The stream stays open until the operator finishes or cancels.
        return new Promise<void>(() => {})
      },
    )

    render(html`<${KeeperGithubIdentityPanel} keeperName="sangsu" />`)
    await waitFor(() => {
      expect(screen.getByText('@masc-sangsu-bot')).toBeInTheDocument()
    })

    fireEvent.click(screen.getByText('GitHub 로그인'))
    await waitFor(() => {
      expect(screen.getByRole('dialog')).toBeInTheDocument()
    })
    expect(apiRefs.streamKeeperGithubLogin).toHaveBeenCalledTimes(1)

    await act(async () => {
      captured.onEvent?.({
        event: 'output',
        stream: 'stdout',
        text: 'one-time code: ABCD-1234 open https://github.com/login/device',
      })
    })
    expect(screen.getByText(/ABCD-1234/)).toBeInTheDocument()
    const deviceLink = screen.getByText('GitHub 페이지 열기')
    expect(deviceLink).toHaveAttribute('href', 'https://github.com/login/device')

    await act(async () => {
      captured.onEvent?.({
        event: 'complete',
        observation: makeObservation({
          effective: { authenticated: true, login: 'masc-sangsu-bot', error: null },
        }),
      })
    })
    expect(screen.getAllByText('@masc-sangsu-bot')).toHaveLength(2)

    fireEvent.click(screen.getByText('취소'))
    await waitFor(() => {
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    })
    expect(captured.signal?.aborted).toBe(true)
  })
})
