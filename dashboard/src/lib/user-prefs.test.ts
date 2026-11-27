// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { applyContrast, applyTheme } from './theme'
import {
  DEFAULT_USER_PREFS,
  USER_PREFS_STORAGE_KEY,
  applyUserPrefsToDocument,
  cycleDensityPref,
  initUserPrefs,
  resetAppearancePrefs,
  resetAudioPrefs,
  resetUserPrefs,
  sanitizeUserPrefs,
  stepUiScale,
  updateDesktopNotifyPref,
  updateSoundCuePref,
  updateUserPrefs,
  userPrefs,
} from './user-prefs'
import {
  enumerateMediaDevices,
  getDesktopNotificationPermission,
  playSoundCue,
  shouldPlaySoundCue,
  startMicLevelProbe,
} from './sound-cues'

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
      masterVolume: -5,
      muted: 'yes',
      ttsRate: Number.NaN,
      inputDeviceId: 12345,
      soundCues: { approvalPending: false, runFailed: 'bad' },
      desktopNotify: { keeperAsk: false },
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
    expect(sanitized.masterVolume).toBe(0)
    expect(sanitized.muted).toBe(false)
    expect(sanitized.ttsRate).toBe(1)
    expect(sanitized.inputDeviceId).toBe('')
    expect(sanitized.soundCues.approvalPending).toBe(false)
    expect(sanitized.soundCues.runFailed).toBe(true)
    expect(sanitized.desktopNotify.keeperAsk).toBe(false)
    expect(sanitized.desktopNotify.approvalPending).toBe(true)
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

  it('cycles density, steps UI scale within limits, and resets appearance/audio independently', () => {
    expect(cycleDensityPref()).toBe('comfortable')
    expect(cycleDensityPref()).toBe('compact')
    expect(cycleDensityPref()).toBe('normal')

    expect(stepUiScale(0.5)).toBe(1.35)
    expect(stepUiScale(-1.0)).toBe(0.85)

    updateSoundCuePref('mention', false)
    updateDesktopNotifyPref('runFailed', false)
    updateUserPrefs({ masterVolume: 0.35, accent: 'iris' })

    resetAppearancePrefs()
    expect(userPrefs.value.accent).toBe('brass')
    expect(userPrefs.value.uiScale).toBe(1)
    expect(userPrefs.value.masterVolume).toBe(0.35)
    expect(userPrefs.value.soundCues.mention).toBe(false)

    resetAudioPrefs()
    expect(userPrefs.value.masterVolume).toBe(0.7)
    expect(userPrefs.value.soundCues.mention).toBe(true)
    expect(userPrefs.value.desktopNotify.runFailed).toBe(true)
    expect(localStorage.getItem(USER_PREFS_STORAGE_KEY)).not.toBeNull()
    applyUserPrefsToDocument()
  })
})

describe('sound-cues synthesizer, mic probe cleanup & notifications', () => {
  beforeEach(() => {
    resetUserPrefs()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('honors muted, masterVolume, muteWhenFocused, and per-event toggles', () => {
    const base = { ...DEFAULT_USER_PREFS, masterVolume: 0.7, muted: false, muteWhenFocused: false }
    expect(shouldPlaySoundCue('approvalPending', base, true)).toBe(true)
    expect(shouldPlaySoundCue('turnCompleted', base, false)).toBe(false)
    expect(shouldPlaySoundCue('approvalPending', { ...base, muted: true }, false)).toBe(false)
    expect(shouldPlaySoundCue('approvalPending', { ...base, masterVolume: 0 }, false)).toBe(false)
    expect(shouldPlaySoundCue('approvalPending', { ...base, muteWhenFocused: true }, true)).toBe(false)
    expect(shouldPlaySoundCue('approvalPending', { ...base, muteWhenFocused: true }, false)).toBe(true)

    // Safe no-op in happy-dom when AudioContext is absent
    expect(playSoundCue('approvalPending', { force: true })).toBe(false)
  })

  it('gracefully handles missing mediaDevices & Notification APIs and stops mic tracks on cleanup', async () => {
    const emptyDevices = await enumerateMediaDevices()
    expect(emptyDevices.inputs).toEqual([])
    expect(emptyDevices.outputs).toEqual([])

    expect(['default', 'granted', 'denied', 'unsupported']).toContain(
      getDesktopNotificationPermission(),
    )

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
        ]),
        getUserMedia: mockGetUserMedia,
      },
    })

    const listed = await enumerateMediaDevices()
    expect(listed.supported).toBe(true)
    expect(listed.inputs).toHaveLength(1)
    expect(listed.inputs[0]?.label).toBe('Studio Mic')
    expect(listed.outputs).toHaveLength(1)

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

    const levels: number[] = []
    const handle = await startMicLevelProbe({
      deviceId: 'mic-1',
      onLevel: (v) => levels.push(v),
    })
    expect(handle).not.toBeNull()
    expect(levels.length).toBeGreaterThan(0)

    handle?.stop()
    expect(stopTrack).toHaveBeenCalledTimes(1)
    expect(disconnect).toHaveBeenCalledTimes(1)
    expect(closeCtx).toHaveBeenCalledTimes(1)
    expect(levels[levels.length - 1]).toBe(0)
  })
})
