// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { applyContrast, applyTheme, CONTRAST_STORAGE_KEY } from './theme'
import { activeContrast, activeTheme, toggleThemeMode } from '../shell/shell-state'
import {
  DEFAULT_USER_PREFS,
  USER_PREFS_STORAGE_KEY,
  applyUserPrefsToDocument,
  cycleDensityPref,
  initUserPrefs,
  resetAppearancePrefs,
  resetMicrophonePrefs,
  resetUserPrefs,
  sanitizeUserPrefs,
  stepUiScale,
  updateUserPrefs,
  userPrefs,
} from './user-prefs'
import {
  enumerateMicrophones,
  startMicLevelProbe,
} from './microphone'

describe('user-prefs store, schema clamping & DOM sync', () => {
  beforeEach(() => {
    localStorage.clear()
    document.documentElement.removeAttribute('data-theme')
    document.documentElement.removeAttribute('data-theme-preset')
    document.documentElement.removeAttribute('data-accent')
    document.documentElement.removeAttribute('data-contrast')
    document.documentElement.removeAttribute('data-density')
    document.documentElement.removeAttribute('data-chat-layout')
    document.documentElement.removeAttribute('data-chat-measure')
    document.documentElement.removeAttribute('data-reduce-motion')
    resetUserPrefs()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('clamps numeric bounds and falls back cleanly on corrupt payloads', () => {
    expect(sanitizeUserPrefs(null)).toEqual(DEFAULT_USER_PREFS)
    expect(sanitizeUserPrefs('not-an-object')).toEqual(DEFAULT_USER_PREFS)
    expect(sanitizeUserPrefs([1, 2, 3])).toEqual(DEFAULT_USER_PREFS)

    const sanitized = sanitizeUserPrefs({
      theme: 'invalid-theme',
      accent: 'neon-pink',
      contrast: 'extreme',
      uiScale: 9.9,
      chatFontSize: 2,
      codeFontSize: 99,
      density: 'ultra',
      chatLayout: 'wide',
      chatMeasure: 'narrow',
      reduceMotion: 'maybe',
      inputDeviceId: 12345,
      echoCancellation: false,
      noiseSuppression: 'yes',
    })

    expect(sanitized.theme).toBe('dark')
    expect(sanitized.accent).toBe('brass')
    expect(sanitized.contrast).toBe('auto')
    expect(sanitized.uiScale).toBe(1.35)
    expect(sanitized.chatFontSize).toBe(12)
    expect(sanitized.codeFontSize).toBe(18)
    expect(sanitized.density).toBe('normal')
    expect(sanitized.chatLayout).toBe('cozy')
    expect(sanitized.chatMeasure).toBe('standard')
    expect(sanitized.reduceMotion).toBe('system')
    expect(sanitized.inputDeviceId).toBe('')
    expect(sanitized.echoCancellation).toBe(false)
    expect(sanitized.noiseSuppression).toBe(true)
  })

  it('applies dataset attributes and CSS variables onto documentElement', () => {
    updateUserPrefs({
      theme: 'paper-sepia',
      accent: 'jade',
      contrast: 'high',
      uiScale: 1.15,
      chatFontSize: 16,
      codeFontSize: 14,
      density: 'compact',
      chatLayout: 'compact',
      chatMeasure: 'wide',
      reduceMotion: 'on',
    })

    const root = document.documentElement
    expect(root.dataset.theme).toBe('light')
    expect(root.dataset.themePreset).toBe('paper-sepia')
    expect(root.dataset.accent).toBe('jade')
    expect(root.dataset.contrast).toBe('high')
    expect(root.dataset.density).toBe('compact')
    expect(root.dataset.chatLayout).toBe('compact')
    expect(root.dataset.chatMeasure).toBe('wide')
    expect(root.dataset.reduceMotion).toBe('on')

    expect(root.style.getPropertyValue('--ui-scale')).toBe('1.15')
    expect(root.style.getPropertyValue('--chat-font-size')).toBe('16px')
    expect(root.style.getPropertyValue('--code-font-size')).toBe('14px')
    expect(root.style.getPropertyValue('--density-scale')).toBe('0.82')
    expect(root.style.getPropertyValue('--chat-measure')).toBe('110ch')
  })

  it('reacts to OS prefers-color-scheme changes when theme is system and syncs theme.ts', () => {
    let matches = false
    const listeners: Array<(ev: MediaQueryListEvent) => void> = []
    const mockMql = {
      get matches() { return matches },
      media: '(prefers-color-scheme: light)',
      addEventListener: (_type: string, cb: (ev: MediaQueryListEvent) => void) => {
        listeners.push(cb)
      },
      removeEventListener: vi.fn(),
    }
    vi.spyOn(window, 'matchMedia').mockReturnValue(mockMql as unknown as MediaQueryList)

    const dispose = initUserPrefs()
    try {
      updateUserPrefs({ theme: 'system' })
      expect(document.documentElement.dataset.theme).toBeUndefined()
      expect(document.documentElement.dataset.themePreset).toBe('dark')

      matches = true
      for (const listener of listeners) {
        listener({ matches: true } as MediaQueryListEvent)
      }
      expect(document.documentElement.dataset.theme).toBe('light')
      expect(document.documentElement.dataset.themePreset).toBe('light')

      // External theme.ts calls stay synchronized
      applyTheme('dark')
      expect(userPrefs.value.theme).toBe('dark')
      applyContrast('high')
      expect(userPrefs.value.contrast).toBe('high')
    } finally {
      dispose()
    }
  })

  it('cycles density, steps UI scale within limits, and resets appearance and microphone settings independently', () => {
    expect(cycleDensityPref()).toBe('comfortable')
    expect(cycleDensityPref()).toBe('compact')
    expect(cycleDensityPref()).toBe('normal')

    expect(stepUiScale(0.5)).toBe(1.35)
    expect(stepUiScale(-1.0)).toBe(0.85)

    updateUserPrefs({ inputDeviceId: 'mic-1', noiseSuppression: false, accent: 'iris' })

    resetAppearancePrefs()
    expect(userPrefs.value.accent).toBe('brass')
    expect(userPrefs.value.uiScale).toBe(1)
    expect(userPrefs.value.inputDeviceId).toBe('mic-1')
    expect(userPrefs.value.noiseSuppression).toBe(false)

    resetMicrophonePrefs()
    expect(userPrefs.value.inputDeviceId).toBe('')
    expect(userPrefs.value.noiseSuppression).toBe(true)
    expect(localStorage.getItem(USER_PREFS_STORAGE_KEY)).not.toBeNull()
    applyUserPrefsToDocument()
  })

  it('preserves legacy theme and high-contrast storage on first load without masc:user-prefs:v1 and syncs shell-state', () => {
    localStorage.clear()
    localStorage.setItem('masc-theme', 'light')
    localStorage.setItem(CONTRAST_STORAGE_KEY, 'high')
    document.documentElement.removeAttribute('data-theme')
    document.documentElement.removeAttribute('data-contrast')
    activeTheme.value = 'dark'
    activeContrast.value = null

    const dispose = initUserPrefs()
    try {
      expect(document.documentElement.dataset.theme).toBe('light')
      expect(document.documentElement.dataset.contrast).toBe('high')
      expect(localStorage.getItem('masc-theme')).toBe('light')
      expect(localStorage.getItem(CONTRAST_STORAGE_KEY)).toBe('high')
      expect(userPrefs.value.theme).toBe('light')
      expect(userPrefs.value.contrast).toBe('high')
      expect(activeTheme.value).toBe('light')
      expect(activeContrast.value).toBe('high')

      // First toggle click flips immediately without a no-op turn
      expect(toggleThemeMode()).toBe('dark')
      expect(document.documentElement.dataset.theme).toBeUndefined()
      expect(activeTheme.value).toBe('dark')
    } finally {
      dispose()
    }
  })

  it('honors ?theme=light and ?contrast=high URL parameters over stored defaults and syncs activeTheme', () => {
    localStorage.setItem(
      USER_PREFS_STORAGE_KEY,
      JSON.stringify({ ...DEFAULT_USER_PREFS, theme: 'dark', contrast: 'normal' }),
    )
    const prevUrl = window.location.href
    window.history.replaceState(null, '', '/?theme=light&contrast=high')
    const dispose = initUserPrefs()
    try {
      expect(document.documentElement.dataset.theme).toBe('light')
      expect(document.documentElement.dataset.themePreset).toBe('light')
      expect(document.documentElement.dataset.contrast).toBe('high')
      expect(activeTheme.value).toBe('light')
      expect(activeContrast.value).toBe('high')
    } finally {
      dispose()
      window.history.replaceState(null, '', prevUrl)
    }
  })
})

describe('microphone enumeration and level probe', () => {
  beforeEach(() => {
    resetUserPrefs()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('enumerates usable microphones and applies saved constraints to the level probe', async () => {
    expect(await enumerateMicrophones()).toEqual([])

    const stopTrack = vi.fn()
    const closeCtx = vi.fn(async () => {})
    const disconnect = vi.fn()

    const mockStream = { getTracks: () => [{ stop: stopTrack }] }
    const mockGetUserMedia = vi.fn(async () => mockStream)
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: {
        enumerateDevices: vi.fn(async () => [
          { deviceId: 'mic-1', label: 'Studio Mic', kind: 'audioinput' },
          { deviceId: 'spk-1', label: 'Monitor Out', kind: 'audiooutput' },
          { deviceId: '', label: '', kind: 'audioinput' },
        ]),
        getUserMedia: mockGetUserMedia,
      },
    })

    const listed = await enumerateMicrophones()
    expect(listed.map((device) => device.label)).toEqual(['Studio Mic'])

    class FakeAudioContext {
      state = 'running'
      createMediaStreamSource() {
        return { connect: vi.fn(), disconnect }
      }
      createAnalyser() {
        return {
          fftSize: 256,
          getByteTimeDomainData: (arr: Uint8Array) => {
            arr.fill(140)
          },
        }
      }
      close = closeCtx
    }
    vi.stubGlobal('AudioContext', FakeAudioContext)

    updateUserPrefs({ inputDeviceId: 'mic-1', echoCancellation: false })
    const levels: number[] = []
    const handle = await startMicLevelProbe({
      onLevel: (v) => levels.push(v),
    })
    expect(handle).not.toBeNull()
    expect(mockGetUserMedia).toHaveBeenCalledWith({
      audio: {
        deviceId: { ideal: 'mic-1' },
        echoCancellation: false,
        noiseSuppression: true,
        autoGainControl: true,
      },
    })
    expect(levels.length).toBeGreaterThan(0)

    handle?.stop()
    expect(stopTrack).toHaveBeenCalledTimes(1)
    expect(disconnect).toHaveBeenCalledTimes(1)
    expect(closeCtx).toHaveBeenCalledTimes(1)
    expect(levels[levels.length - 1]).toBe(0)
  })
})
