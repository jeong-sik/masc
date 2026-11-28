// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h, render } from 'preact'
import { act, fireEvent } from '@testing-library/preact'
import { activeContrast, activeTheme, resetShellStateForTests } from '../../shell/shell-state'
import { resetUserPrefs, userPrefs } from '../../lib/user-prefs'
import { AppearancePanel } from './appearance-panel'
import { MicrophonePrefsPanel } from './microphone-prefs-panel'
import { ProfileSessionsTab } from '../account/profile-tab'

describe('AppearancePanel, MicrophonePrefsPanel & Account Profile embedding', () => {
  let container: HTMLDivElement

  beforeEach(() => {
    localStorage.clear()
    container = document.createElement('div')
    document.body.appendChild(container)
    resetShellStateForTests()
    resetUserPrefs()
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    vi.restoreAllMocks()
  })

  it('updates theme presets, accents, sliders, density, live preview, and resets cleanly', async () => {
    await act(async () => {
      render(h(AppearancePanel, {}), container)
    })

    expect(container.querySelector('[data-testid="appearance-live-preview"]')).not.toBeNull()

    // Select Midnight OLED preset
    const midnightBtn = container.querySelector('[data-theme-option="midnight"]') as HTMLButtonElement
    await act(async () => {
      fireEvent.click(midnightBtn)
    })
    expect(userPrefs.value.theme).toBe('midnight')
    expect(document.documentElement.dataset.themePreset).toBe('midnight')
    expect(activeTheme.value).toBe('dark')

    // Select Light · Warm Paper preset (syncs shell-state activeTheme)
    const lightBtn = container.querySelector('[data-theme-option="light"]') as HTMLButtonElement
    await act(async () => {
      fireEvent.click(lightBtn)
    })
    expect(userPrefs.value.theme).toBe('light')
    expect(document.documentElement.dataset.theme).toBe('light')
    expect(activeTheme.value).toBe('light')

    // Select Jade accent
    const jadeBtn = container.querySelector('[data-accent-option="jade"]') as HTMLButtonElement
    await act(async () => {
      fireEvent.click(jadeBtn)
    })
    expect(userPrefs.value.accent).toBe('jade')
    expect(document.documentElement.dataset.accent).toBe('jade')

    // Adjust UI scale & chat font sliders
    const scaleSlider = container.querySelector('input[aria-label="전체 UI 배율"]') as HTMLInputElement
    const chatSlider = container.querySelector('input[aria-label="채팅 본문 글꼴 크기"]') as HTMLInputElement
    await act(async () => {
      fireEvent.input(scaleSlider, { target: { value: '1.2' } })
      fireEvent.input(chatSlider, { target: { value: '18' } })
    })
    expect(container.querySelector('[data-testid="ui-scale-value"]')?.textContent).toBe('120%')
    expect(container.querySelector('[data-testid="chat-font-value"]')?.textContent).toBe('18px')
    expect(document.documentElement.style.getPropertyValue('--chat-font-size')).toBe('18px')

    // Density & Reduce Motion & High Contrast
    await act(async () => {
      fireEvent.click(container.querySelector('[data-density-option="compact"]')!)
      fireEvent.click(container.querySelector('[data-reduce-motion-option="on"]')!)
    })
    const hcBtn = Array.from(container.querySelectorAll('button')).find(
      (b) => b.textContent?.trim() === 'High Contrast',
    ) as HTMLButtonElement
    await act(async () => {
      fireEvent.click(hcBtn)
    })
    expect(document.documentElement.dataset.density).toBe('compact')
    expect(document.documentElement.dataset.reduceMotion).toBe('on')
    expect(activeContrast.value).toBe('high')

    // Reset button restores defaults
    await act(async () => {
      fireEvent.click(container.querySelector('[data-testid="appearance-reset-btn"]')!)
    })
    expect(userPrefs.value.theme).toBe('dark')
    expect(userPrefs.value.accent).toBe('brass')
    expect(userPrefs.value.uiScale).toBe(1)
    expect(userPrefs.value.density).toBe('normal')
  })

  it('updates and resets microphone processing settings', async () => {
    await act(async () => {
      render(h(MicrophonePrefsPanel, {}), container)
    })

    const noiseSuppression = container.querySelector<HTMLInputElement>('input[aria-label="소음 억제"]')!
    expect(noiseSuppression.checked).toBe(true)
    await act(async () => {
      fireEvent.change(noiseSuppression, { target: { checked: false } })
    })
    expect(userPrefs.value.noiseSuppression).toBe(false)

    await act(async () => {
      fireEvent.click(container.querySelector('[data-testid="mic-reset-btn"]')!)
    })
    expect(userPrefs.value.noiseSuppression).toBe(true)
    expect(noiseSuppression.checked).toBe(true)
  })

  it('exposes both AppearancePanel and MicrophonePrefsPanel to non-Admin Workers in ProfileSessionsTab', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ id: 'u-worker', role: 'worker' }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      }),
    )

    await act(async () => {
      render(
        h(ProfileSessionsTab, {
          session: {
            kind: 'multi_account_signed_in',
            mode: 'multi_account',
            accountId: 'u-worker',
            email: 'worker@example.com',
            displayName: 'Worker User',
            role: 'worker',
            csrfToken: 'csrf-token',
            authMethods: { google: true, github: false, dev_token: false },
            workspaceId: 'default',
          },
        }),
        container,
      )
    })

    expect(container.querySelector('[data-testid="account-user-prefs"]')).not.toBeNull()
    expect(container.querySelector('[data-testid="settings-appearance-panel"]')).not.toBeNull()

    // Switch to the microphone tab
    await act(async () => {
      fireEvent.click(container.querySelector('[data-testid="prefs-tab-microphone"]')!)
    })
    expect(container.querySelector('[data-testid="settings-microphone-prefs-panel"]')).not.toBeNull()
  })
})
