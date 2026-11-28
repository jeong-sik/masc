// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h, render } from 'preact'
import { act, fireEvent } from '@testing-library/preact'
import { activeContrast, activeTheme, resetShellStateForTests } from '../../shell/shell-state'
import { resetUserPrefs, userPrefs } from '../../lib/user-prefs'
import { AppearancePanel } from './appearance-panel'
import { AudioPrefsPanel } from './audio-prefs-panel'
import { ProfileSessionsTab } from '../account/profile-tab'

describe('AppearancePanel, AudioPrefsPanel & Account Profile embedding', () => {
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

  it('controls master volume, mute, TTS speed, sound cue toggles, and resets in AudioPrefsPanel', async () => {
    await act(async () => {
      render(h(AudioPrefsPanel, {}), container)
    })

    const volSlider = container.querySelector('input[aria-label="마스터 볼륨"]') as HTMLInputElement
    await act(async () => {
      fireEvent.input(volSlider, { target: { value: '0.45' } })
    })
    expect(userPrefs.value.masterVolume).toBe(0.45)
    expect(container.querySelector('[data-testid="master-volume-value"]')?.textContent).toBe('45%')

    const muteCheckbox = container.querySelector('input[aria-label="전체 음소거"]') as HTMLInputElement
    await act(async () => {
      fireEvent.change(muteCheckbox, { target: { checked: true } })
    })
    expect(userPrefs.value.muted).toBe(true)

    const ttsSlider = container.querySelector('input[aria-label="TTS 재생 속도"]') as HTMLInputElement
    await act(async () => {
      fireEvent.input(ttsSlider, { target: { value: '1.5' } })
    })
    expect(userPrefs.value.ttsRate).toBe(1.5)
    expect(container.querySelector('[data-testid="tts-rate-value"]')?.textContent).toBe('1.50x')

    // Clicking [테스트] sound cue button does not throw even without AudioContext
    const testCueBtn = container.querySelector('[data-test-cue="approvalPending"]') as HTMLButtonElement
    await act(async () => {
      fireEvent.click(testCueBtn)
    })

    // Reset restores audio defaults
    await act(async () => {
      fireEvent.click(container.querySelector('[data-testid="audio-reset-btn"]')!)
    })
    expect(userPrefs.value.masterVolume).toBe(0.7)
    expect(userPrefs.value.muted).toBe(false)
    expect(userPrefs.value.ttsRate).toBe(1)
  })

  it('exposes both AppearancePanel and AudioPrefsPanel to non-Admin Workers in ProfileSessionsTab', async () => {
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

    // Switch to Audio & Notifications tab
    await act(async () => {
      fireEvent.click(container.querySelector('[data-testid="prefs-tab-audio"]')!)
    })
    expect(container.querySelector('[data-testid="settings-audio-prefs-panel"]')).not.toBeNull()
  })
})
