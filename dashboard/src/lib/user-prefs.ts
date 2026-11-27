/**
 * Client-side User Preferences store (`masc:user-prefs:v1`).
 *
 * Covers Appearance (theme presets, accents, contrast, UI/chat/code scale,
 * density, chat layout/measure, reduce motion) and Audio & Notifications
 * (volume, mute, TTS, media device IDs, WebRTC processing, sound cues,
 * desktop notifications).
 *
 * Uses `persistentSignal` with strict schema validation and clamping so
 * corrupt or partial `localStorage` payloads can never crash the dashboard.
 */

import { effect } from '@preact/signals'
import { persistentSignal } from './persistent-signal'
import {
  applyContrast,
  applyTheme,
  onContrastApplied,
  onThemeApplied,
  persistContrast,
  persistTheme,
  resolveBaseThemeForPreset,
  type ConcreteThemePresetId,
  type ContrastId,
  type ThemeId,
  type ThemePresetId,
} from './theme'

export const USER_PREFS_STORAGE_KEY = 'masc:user-prefs:v1'

export type ThemePreset = ThemePresetId
export type ConcreteThemePreset = ConcreteThemePresetId
export type AccentId = 'brass' | 'steel' | 'jade' | 'rose' | 'iris'
export type ContrastPref = 'auto' | 'normal' | 'high'
export type DensityPref = 'compact' | 'normal' | 'comfortable'
export type ChatLayoutPref = 'cozy' | 'compact'
export type ChatMeasurePref = 'standard' | 'wide'
export type ReduceMotionPref = 'system' | 'on' | 'off'

export type SoundCueEvent =
  | 'approvalPending'
  | 'keeperAsk'
  | 'turnCompleted'
  | 'runFailed'
  | 'mention'

export type DesktopNotifyEvent =
  | 'approvalPending'
  | 'keeperAsk'
  | 'runFailed'

export interface SoundCuePrefs {
  readonly approvalPending: boolean
  readonly keeperAsk: boolean
  readonly turnCompleted: boolean
  readonly runFailed: boolean
  readonly mention: boolean
}

export interface DesktopNotifyPrefs {
  readonly approvalPending: boolean
  readonly keeperAsk: boolean
  readonly runFailed: boolean
}

export interface UserPrefs {
  // Appearance
  readonly theme: ThemePreset
  readonly accent: AccentId
  readonly contrast: ContrastPref
  readonly uiScale: number
  readonly chatFontSize: number
  readonly codeFontSize: number
  readonly density: DensityPref
  readonly chatLayout: ChatLayoutPref
  readonly chatMeasure: ChatMeasurePref
  readonly reduceMotion: ReduceMotionPref

  // Audio & Notifications
  readonly masterVolume: number
  readonly muted: boolean
  readonly muteWhenFocused: boolean
  readonly ttsAutoplay: boolean
  readonly ttsRate: number
  readonly inputDeviceId: string
  readonly outputDeviceId: string
  readonly noiseSuppression: boolean
  readonly echoCancellation: boolean
  readonly autoGainControl: boolean
  readonly soundCues: SoundCuePrefs
  readonly desktopNotify: DesktopNotifyPrefs
}

export const THEME_PRESETS: readonly ThemePreset[] = [
  'system',
  'dark',
  'midnight',
  'ash',
  'light',
  'paper-sepia',
] as const

export const ACCENT_IDS: readonly AccentId[] = [
  'brass',
  'steel',
  'jade',
  'rose',
  'iris',
] as const

export const CONTRAST_PREFS: readonly ContrastPref[] = ['auto', 'normal', 'high'] as const
export const DENSITY_PREFS: readonly DensityPref[] = ['compact', 'normal', 'comfortable'] as const
export const CHAT_LAYOUT_PREFS: readonly ChatLayoutPref[] = ['cozy', 'compact'] as const
export const CHAT_MEASURE_PREFS: readonly ChatMeasurePref[] = ['standard', 'wide'] as const
export const REDUCE_MOTION_PREFS: readonly ReduceMotionPref[] = ['system', 'on', 'off'] as const

export const SOUND_CUE_EVENTS: readonly SoundCueEvent[] = [
  'approvalPending',
  'keeperAsk',
  'turnCompleted',
  'runFailed',
  'mention',
] as const

export const DESKTOP_NOTIFY_EVENTS: readonly DesktopNotifyEvent[] = [
  'approvalPending',
  'keeperAsk',
  'runFailed',
] as const

export const DENSITY_SCALE_MAP: Readonly<Record<DensityPref, number>> = {
  compact: 0.82,
  normal: 1,
  comfortable: 1.18,
}

export const CHAT_MEASURE_MAP: Readonly<Record<ChatMeasurePref, string>> = {
  standard: '78ch',
  wide: '110ch',
}

export const USER_PREFS_LIMITS = {
  uiScale: { min: 0.85, max: 1.35, step: 0.05 },
  chatFontSize: { min: 12, max: 20, step: 1 },
  codeFontSize: { min: 10, max: 18, step: 1 },
  masterVolume: { min: 0, max: 1, step: 0.05 },
  ttsRate: { min: 0.75, max: 2.0, step: 0.05 },
} as const

export const DEFAULT_SOUND_CUE_PREFS: SoundCuePrefs = {
  approvalPending: true,
  keeperAsk: true,
  turnCompleted: false,
  runFailed: true,
  mention: true,
}

export const DEFAULT_DESKTOP_NOTIFY_PREFS: DesktopNotifyPrefs = {
  approvalPending: true,
  keeperAsk: true,
  runFailed: true,
}

export const DEFAULT_USER_PREFS: UserPrefs = {
  theme: 'dark',
  accent: 'brass',
  contrast: 'auto',
  uiScale: 1,
  chatFontSize: 14,
  codeFontSize: 12,
  density: 'normal',
  chatLayout: 'cozy',
  chatMeasure: 'standard',
  reduceMotion: 'system',

  masterVolume: 0.7,
  muted: false,
  muteWhenFocused: false,
  ttsAutoplay: false,
  ttsRate: 1,
  inputDeviceId: '',
  outputDeviceId: '',
  noiseSuppression: true,
  echoCancellation: true,
  autoGainControl: true,
  soundCues: DEFAULT_SOUND_CUE_PREFS,
  desktopNotify: DEFAULT_DESKTOP_NOTIFY_PREFS,
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function pickEnum<T extends string>(
  raw: unknown,
  allowed: readonly T[],
  fallback: T,
): T {
  return typeof raw === 'string' && (allowed as readonly string[]).includes(raw)
    ? (raw as T)
    : fallback
}

function clampNumber(
  raw: unknown,
  min: number,
  max: number,
  fallback: number,
  decimals: number,
): number {
  const num = typeof raw === 'number' ? raw : Number.NaN
  if (!Number.isFinite(num)) return fallback
  const clamped = Math.min(max, Math.max(min, num))
  const factor = 10 ** decimals
  return Math.round(clamped * factor) / factor
}

function pickBoolean(raw: unknown, fallback: boolean): boolean {
  return typeof raw === 'boolean' ? raw : fallback
}

function pickDeviceId(raw: unknown): string {
  return typeof raw === 'string' ? raw.slice(0, 256) : ''
}

export function sanitizeUserPrefs(raw: unknown): UserPrefs {
  if (!isRecord(raw)) return DEFAULT_USER_PREFS

  const rawCues = isRecord(raw.soundCues) ? raw.soundCues : {}
  const rawNotify = isRecord(raw.desktopNotify) ? raw.desktopNotify : {}

  return {
    theme: pickEnum(raw.theme, THEME_PRESETS, DEFAULT_USER_PREFS.theme),
    accent: pickEnum(raw.accent, ACCENT_IDS, DEFAULT_USER_PREFS.accent),
    contrast: pickEnum(raw.contrast, CONTRAST_PREFS, DEFAULT_USER_PREFS.contrast),
    uiScale: clampNumber(
      raw.uiScale,
      USER_PREFS_LIMITS.uiScale.min,
      USER_PREFS_LIMITS.uiScale.max,
      DEFAULT_USER_PREFS.uiScale,
      2,
    ),
    chatFontSize: clampNumber(
      raw.chatFontSize,
      USER_PREFS_LIMITS.chatFontSize.min,
      USER_PREFS_LIMITS.chatFontSize.max,
      DEFAULT_USER_PREFS.chatFontSize,
      0,
    ),
    codeFontSize: clampNumber(
      raw.codeFontSize,
      USER_PREFS_LIMITS.codeFontSize.min,
      USER_PREFS_LIMITS.codeFontSize.max,
      DEFAULT_USER_PREFS.codeFontSize,
      0,
    ),
    density: pickEnum(raw.density, DENSITY_PREFS, DEFAULT_USER_PREFS.density),
    chatLayout: pickEnum(raw.chatLayout, CHAT_LAYOUT_PREFS, DEFAULT_USER_PREFS.chatLayout),
    chatMeasure: pickEnum(raw.chatMeasure, CHAT_MEASURE_PREFS, DEFAULT_USER_PREFS.chatMeasure),
    reduceMotion: pickEnum(raw.reduceMotion, REDUCE_MOTION_PREFS, DEFAULT_USER_PREFS.reduceMotion),

    masterVolume: clampNumber(
      raw.masterVolume,
      USER_PREFS_LIMITS.masterVolume.min,
      USER_PREFS_LIMITS.masterVolume.max,
      DEFAULT_USER_PREFS.masterVolume,
      2,
    ),
    muted: pickBoolean(raw.muted, DEFAULT_USER_PREFS.muted),
    muteWhenFocused: pickBoolean(raw.muteWhenFocused, DEFAULT_USER_PREFS.muteWhenFocused),
    ttsAutoplay: pickBoolean(raw.ttsAutoplay, DEFAULT_USER_PREFS.ttsAutoplay),
    ttsRate: clampNumber(
      raw.ttsRate,
      USER_PREFS_LIMITS.ttsRate.min,
      USER_PREFS_LIMITS.ttsRate.max,
      DEFAULT_USER_PREFS.ttsRate,
      2,
    ),
    inputDeviceId: pickDeviceId(raw.inputDeviceId),
    outputDeviceId: pickDeviceId(raw.outputDeviceId),
    noiseSuppression: pickBoolean(raw.noiseSuppression, DEFAULT_USER_PREFS.noiseSuppression),
    echoCancellation: pickBoolean(raw.echoCancellation, DEFAULT_USER_PREFS.echoCancellation),
    autoGainControl: pickBoolean(raw.autoGainControl, DEFAULT_USER_PREFS.autoGainControl),
    soundCues: {
      approvalPending: pickBoolean(rawCues.approvalPending, DEFAULT_SOUND_CUE_PREFS.approvalPending),
      keeperAsk: pickBoolean(rawCues.keeperAsk, DEFAULT_SOUND_CUE_PREFS.keeperAsk),
      turnCompleted: pickBoolean(rawCues.turnCompleted, DEFAULT_SOUND_CUE_PREFS.turnCompleted),
      runFailed: pickBoolean(rawCues.runFailed, DEFAULT_SOUND_CUE_PREFS.runFailed),
      mention: pickBoolean(rawCues.mention, DEFAULT_SOUND_CUE_PREFS.mention),
    },
    desktopNotify: {
      approvalPending: pickBoolean(rawNotify.approvalPending, DEFAULT_DESKTOP_NOTIFY_PREFS.approvalPending),
      keeperAsk: pickBoolean(rawNotify.keeperAsk, DEFAULT_DESKTOP_NOTIFY_PREFS.keeperAsk),
      runFailed: pickBoolean(rawNotify.runFailed, DEFAULT_DESKTOP_NOTIFY_PREFS.runFailed),
    },
  }
}

export const userPrefs = persistentSignal<UserPrefs>({
  key: USER_PREFS_STORAGE_KEY,
  defaultValue: DEFAULT_USER_PREFS,
  deserialize: (raw: string) => sanitizeUserPrefs(JSON.parse(raw)),
})

export function isSystemLightPreferred(): boolean {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') {
    return false
  }
  try {
    return window.matchMedia('(prefers-color-scheme: light)').matches
  } catch {
    return false
  }
}

export function resolveConcreteTheme(preset: ThemePreset): ConcreteThemePreset {
  if (preset === 'system') {
    return isSystemLightPreferred() ? 'light' : 'dark'
  }
  return preset
}

export function resolveEffectiveBaseTheme(preset: ThemePreset): ThemeId {
  return resolveBaseThemeForPreset(resolveConcreteTheme(preset))
}

let applyingFromUserPrefs = false

export function applyUserPrefsToDocument(prefs: UserPrefs = userPrefs.peek()): void {
  if (typeof document === 'undefined') return
  const root = document.documentElement
  const concreteTheme = resolveConcreteTheme(prefs.theme)
  const baseTheme = resolveBaseThemeForPreset(concreteTheme)
  const contrastId: ContrastId | null = prefs.contrast === 'auto' ? null : prefs.contrast

  applyingFromUserPrefs = true
  try {
    applyTheme(baseTheme)
    persistTheme(baseTheme)
    applyContrast(contrastId)
    persistContrast(contrastId)

    root.dataset.themePreset = concreteTheme
    root.dataset.accent = prefs.accent
    root.dataset.density = prefs.density
    root.dataset.chatLayout = prefs.chatLayout
    root.dataset.chatMeasure = prefs.chatMeasure
    root.dataset.reduceMotion = prefs.reduceMotion

    root.style.setProperty('--ui-scale', String(prefs.uiScale))
    root.style.setProperty('--chat-font-size', `${prefs.chatFontSize}px`)
    root.style.setProperty('--code-font-size', `${prefs.codeFontSize}px`)
    root.style.setProperty('--density-scale', String(DENSITY_SCALE_MAP[prefs.density]))
    root.style.setProperty('--chat-measure', CHAT_MEASURE_MAP[prefs.chatMeasure])
  } finally {
    applyingFromUserPrefs = false
  }
}

export function updateUserPrefs(patch: Partial<UserPrefs>): UserPrefs {
  const current = userPrefs.peek()
  const next = sanitizeUserPrefs({
    ...current,
    ...patch,
    soundCues: patch.soundCues
      ? { ...current.soundCues, ...patch.soundCues }
      : current.soundCues,
    desktopNotify: patch.desktopNotify
      ? { ...current.desktopNotify, ...patch.desktopNotify }
      : current.desktopNotify,
  })
  userPrefs.value = next
  applyUserPrefsToDocument(next)
  return next
}

export function updateSoundCuePref(event: SoundCueEvent, enabled: boolean): UserPrefs {
  const current = userPrefs.peek()
  return updateUserPrefs({
    soundCues: {
      ...current.soundCues,
      [event]: enabled,
    },
  })
}

export function updateDesktopNotifyPref(event: DesktopNotifyEvent, enabled: boolean): UserPrefs {
  const current = userPrefs.peek()
  return updateUserPrefs({
    desktopNotify: {
      ...current.desktopNotify,
      [event]: enabled,
    },
  })
}

export function resetAppearancePrefs(): UserPrefs {
  return updateUserPrefs({
    theme: DEFAULT_USER_PREFS.theme,
    accent: DEFAULT_USER_PREFS.accent,
    contrast: DEFAULT_USER_PREFS.contrast,
    uiScale: DEFAULT_USER_PREFS.uiScale,
    chatFontSize: DEFAULT_USER_PREFS.chatFontSize,
    codeFontSize: DEFAULT_USER_PREFS.codeFontSize,
    density: DEFAULT_USER_PREFS.density,
    chatLayout: DEFAULT_USER_PREFS.chatLayout,
    chatMeasure: DEFAULT_USER_PREFS.chatMeasure,
    reduceMotion: DEFAULT_USER_PREFS.reduceMotion,
  })
}

export function resetAudioPrefs(): UserPrefs {
  return updateUserPrefs({
    masterVolume: DEFAULT_USER_PREFS.masterVolume,
    muted: DEFAULT_USER_PREFS.muted,
    muteWhenFocused: DEFAULT_USER_PREFS.muteWhenFocused,
    ttsAutoplay: DEFAULT_USER_PREFS.ttsAutoplay,
    ttsRate: DEFAULT_USER_PREFS.ttsRate,
    inputDeviceId: DEFAULT_USER_PREFS.inputDeviceId,
    outputDeviceId: DEFAULT_USER_PREFS.outputDeviceId,
    noiseSuppression: DEFAULT_USER_PREFS.noiseSuppression,
    echoCancellation: DEFAULT_USER_PREFS.echoCancellation,
    autoGainControl: DEFAULT_USER_PREFS.autoGainControl,
    soundCues: DEFAULT_SOUND_CUE_PREFS,
    desktopNotify: DEFAULT_DESKTOP_NOTIFY_PREFS,
  })
}

export function resetUserPrefs(): UserPrefs {
  userPrefs.value = DEFAULT_USER_PREFS
  applyUserPrefsToDocument(DEFAULT_USER_PREFS)
  return DEFAULT_USER_PREFS
}

export function cycleDensityPref(): DensityPref {
  const cur = userPrefs.peek().density
  const idx = DENSITY_PREFS.indexOf(cur)
  const next = DENSITY_PREFS[(idx + 1) % DENSITY_PREFS.length] ?? 'normal'
  updateUserPrefs({ density: next })
  return next
}

export function stepUiScale(delta: number): number {
  const cur = userPrefs.peek().uiScale
  const updated = updateUserPrefs({ uiScale: cur + delta })
  return updated.uiScale
}

export function initUserPrefs(): () => void {
  applyUserPrefsToDocument(userPrefs.peek())

  const disposeEffect = effect(() => {
    applyUserPrefsToDocument(userPrefs.value)
  })

  const disposeThemeSync = onThemeApplied((theme) => {
    if (applyingFromUserPrefs) return
    const cur = userPrefs.peek()
    const currentBase = resolveEffectiveBaseTheme(cur.theme)
    if (currentBase !== theme) {
      userPrefs.value = sanitizeUserPrefs({ ...cur, theme })
    }
  })

  const disposeContrastSync = onContrastApplied((contrast) => {
    if (applyingFromUserPrefs) return
    const cur = userPrefs.peek()
    const nextContrast: ContrastPref = contrast ?? 'auto'
    if (cur.contrast !== nextContrast) {
      userPrefs.value = sanitizeUserPrefs({ ...cur, contrast: nextContrast })
    }
  })

  let removeMediaListener: (() => void) | null = null
  if (typeof window !== 'undefined' && typeof window.matchMedia === 'function') {
    try {
      const mql = window.matchMedia('(prefers-color-scheme: light)')
      const onSchemeChange = () => {
        if (userPrefs.peek().theme === 'system') {
          applyUserPrefsToDocument(userPrefs.peek())
        }
      }
      if (typeof mql.addEventListener === 'function') {
        mql.addEventListener('change', onSchemeChange)
        removeMediaListener = () => mql.removeEventListener('change', onSchemeChange)
      } else if (typeof mql.addListener === 'function') {
        mql.addListener(onSchemeChange)
        removeMediaListener = () => mql.removeListener(onSchemeChange)
      }
    } catch {
      // matchMedia unavailable
    }
  }

  return () => {
    disposeEffect()
    disposeThemeSync()
    disposeContrastSync()
    removeMediaListener?.()
  }
}
