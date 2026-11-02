// @vitest-environment happy-dom
import { afterEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { render } from 'preact'

vi.mock('../store', () => ({
  shellAuthSummary: { value: null },
  refreshShell: vi.fn().mockResolvedValue(undefined),
}))
vi.mock('../api/mcp', () => ({ resetMcpClientState: vi.fn() }))
vi.mock('../api/dev-token', () => ({
  devTokenBootstrapStatus: { value: 'idle' },
  ensureDevToken: vi.fn().mockResolvedValue(undefined),
}))
vi.mock('./common/toast', () => ({ showToast: vi.fn() }))

import { captureDashboardCredentialOwner, currentDashboardActor, dashboardCredentialOwnerIsCurrent } from '../api/core'
import { DASHBOARD_AGENT_NAME_KEY } from '../lib/dashboard-actor'
import { resetDashboardSessionActorForTests } from '../lib/dashboard-session-actor'
import { AuthStatus, __resetForTests } from './auth-status'

describe('AuthStatus actor selection ownership', () => {
  let container: HTMLElement | null = null

  afterEach(() => {
    if (container) render(null, container)
    container = null
    document.body.innerHTML = ''
    __resetForTests()
    resetDashboardSessionActorForTests()
    sessionStorage.clear()
    localStorage.removeItem(DASHBOARD_AGENT_NAME_KEY)
    window.history.replaceState({}, '', '/')
  })

  it.each(['/', '/?agent=alice'])(
    'retires an earlier uncredentialed owner when the UI selects alice → bob → alice at %s',
    async url => {
      window.history.replaceState({}, '', url)
      localStorage.setItem(DASHBOARD_AGENT_NAME_KEY, 'alice')
      const owner = captureDashboardCredentialOwner()
      expect(currentDashboardActor()).toBe('alice')
      container = document.createElement('div')
      document.body.appendChild(container)
      render(html`<${AuthStatus} />`, container)
      fireEvent.click(container.querySelector('button[aria-haspopup]')!)
      await waitFor(() => expect(container?.querySelector('input[aria-label="Dashboard actor"]')).not.toBeNull())

      for (const actor of ['bob', 'alice']) {
        const input = container.querySelector('input[aria-label="Dashboard actor"]') as HTMLInputElement
        fireEvent.input(input, { target: { value: actor } })
        fireEvent.keyDown(input, { key: 'Enter' })
        await waitFor(() => expect(currentDashboardActor()).toBe(actor))
        expect(dashboardCredentialOwnerIsCurrent(owner)).toBe(false)
      }
    },
  )
})
