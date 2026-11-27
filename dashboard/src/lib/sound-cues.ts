/**
 * Zero-dependency WebAudio chime synthesizer, media device enumerator,
 * live microphone VU meter probe, and safe Browser Notification helper.
 *
 * Gracefully no-ops in SSR / jsdom / happy-dom environments where WebAudio,
 * MediaDevices, or Notification APIs are absent.
 */

import {
  userPrefs,
  type DesktopNotifyEvent,
  type SoundCueEvent,
  type UserPrefs,
} from './user-prefs'

interface ToneStep {
  readonly freq: number
  readonly offsetSec: number
  readonly durationSec: number
  readonly type: OscillatorType
  readonly gainRatio: number
}

const CUE_RECIPES: Readonly<Record<SoundCueEvent, readonly ToneStep[]>> = {
  approvalPending: [
    { freq: 523.25, offsetSec: 0, durationSec: 0.14, type: 'sine', gainRatio: 0.85 },
    { freq: 659.25, offsetSec: 0.11, durationSec: 0.22, type: 'sine', gainRatio: 0.9 },
  ],
  keeperAsk: [
    { freq: 440, offsetSec: 0, durationSec: 0.12, type: 'triangle', gainRatio: 0.75 },
    { freq: 659.25, offsetSec: 0.1, durationSec: 0.2, type: 'sine', gainRatio: 0.8 },
  ],
  turnCompleted: [
    { freq: 587.33, offsetSec: 0, durationSec: 0.1, type: 'sine', gainRatio: 0.7 },
    { freq: 880, offsetSec: 0.08, durationSec: 0.18, type: 'sine', gainRatio: 0.75 },
  ],
  runFailed: [
    { freq: 311.13, offsetSec: 0, durationSec: 0.16, type: 'triangle', gainRatio: 0.85 },
    { freq: 233.08, offsetSec: 0.15, durationSec: 0.24, type: 'triangle', gainRatio: 0.8 },
  ],
  mention: [
    { freq: 783.99, offsetSec: 0, durationSec: 0.09, type: 'sine', gainRatio: 0.75 },
    { freq: 1046.5, offsetSec: 0.08, durationSec: 0.16, type: 'sine', gainRatio: 0.8 },
  ],
}

type AudioContextCtor = typeof AudioContext

function getAudioContextCtor(): AudioContextCtor | null {
  if (typeof window === 'undefined') return null
  const win = window as unknown as {
    AudioContext?: AudioContextCtor
    webkitAudioContext?: AudioContextCtor
  }
  return win.AudioContext ?? win.webkitAudioContext ?? null
}

let sharedAudioCtx: AudioContext | null = null

function getOrCreateAudioContext(): AudioContext | null {
  const Ctor = getAudioContextCtor()
  if (!Ctor) return null
  try {
    if (!sharedAudioCtx || sharedAudioCtx.state === 'closed') {
      sharedAudioCtx = new Ctor()
    }
    if (sharedAudioCtx.state === 'suspended' && typeof sharedAudioCtx.resume === 'function') {
      void sharedAudioCtx.resume().catch(() => {})
    }
    return sharedAudioCtx
  } catch {
    return null
  }
}

export function shouldPlaySoundCue(
  event: SoundCueEvent,
  prefs: UserPrefs = userPrefs.peek(),
  focused: boolean = typeof document !== 'undefined' && typeof document.hasFocus === 'function'
    ? document.hasFocus()
    : false,
): boolean {
  if (prefs.muted) return false
  if (prefs.masterVolume <= 0) return false
  if (prefs.muteWhenFocused && focused) return false
  return prefs.soundCues[event] === true
}

export function playSoundCue(
  event: SoundCueEvent,
  options?: { readonly force?: boolean; readonly prefs?: UserPrefs },
): boolean {
  const prefs = options?.prefs ?? userPrefs.peek()
  const force = options?.force === true
  if (!force && !shouldPlaySoundCue(event, prefs)) {
    return false
  }

  const ctx = getOrCreateAudioContext()
  if (!ctx) return false

  const volume = force
    ? Math.max(0.25, Math.min(1, prefs.masterVolume || 0.5))
    : Math.max(0, Math.min(1, prefs.masterVolume))
  if (volume <= 0) return false

  const recipe = CUE_RECIPES[event]
  const now = ctx.currentTime

  try {
    for (const step of recipe) {
      const osc = ctx.createOscillator()
      const gain = ctx.createGain()
      osc.type = step.type
      osc.frequency.setValueAtTime(step.freq, now + step.offsetSec)

      const peak = Math.max(0.001, volume * 0.22 * step.gainRatio)
      const startAt = now + step.offsetSec
      const endAt = startAt + step.durationSec

      gain.gain.setValueAtTime(0.0001, startAt)
      gain.gain.exponentialRampToValueAtTime(peak, startAt + 0.015)
      gain.gain.exponentialRampToValueAtTime(0.0001, endAt)

      osc.connect(gain)
      gain.connect(ctx.destination)
      osc.start(startAt)
      osc.stop(endAt + 0.01)
    }
    return true
  } catch {
    return false
  }
}

// ── Media Device Enumeration ──────────────────────────────────────────

export interface MediaDeviceOption {
  readonly deviceId: string
  readonly label: string
  readonly kind: 'audioinput' | 'audiooutput'
}

export interface EnumeratedAudioDevices {
  readonly inputs: readonly MediaDeviceOption[]
  readonly outputs: readonly MediaDeviceOption[]
  readonly supported: boolean
  readonly error?: string
}

export async function enumerateMediaDevices(): Promise<EnumeratedAudioDevices> {
  if (
    typeof navigator === 'undefined'
    || !navigator.mediaDevices
    || typeof navigator.mediaDevices.enumerateDevices !== 'function'
  ) {
    return { inputs: [], outputs: [], supported: false }
  }

  try {
    const devices = await navigator.mediaDevices.enumerateDevices()
    const inputs: MediaDeviceOption[] = []
    const outputs: MediaDeviceOption[] = []
    let inIdx = 1
    let outIdx = 1

    for (const dev of devices) {
      if (dev.kind === 'audioinput') {
        inputs.push({
          deviceId: dev.deviceId,
          label: dev.label.trim() || `Microphone ${inIdx++}`,
          kind: 'audioinput',
        })
      } else if (dev.kind === 'audiooutput') {
        outputs.push({
          deviceId: dev.deviceId,
          label: dev.label.trim() || `Speaker ${outIdx++}`,
          kind: 'audiooutput',
        })
      }
    }

    return { inputs, outputs, supported: true }
  } catch (err) {
    return {
      inputs: [],
      outputs: [],
      supported: true,
      error: err instanceof Error ? err.message : String(err),
    }
  }
}

// ── Live Mic Input VU Meter Probe ─────────────────────────────────────

export interface MicLevelProbeOptions {
  readonly deviceId?: string
  readonly noiseSuppression?: boolean
  readonly echoCancellation?: boolean
  readonly autoGainControl?: boolean
  readonly onLevel: (rms: number) => void
  readonly onError?: (message: string) => void
}

export interface MicLevelProbeHandle {
  readonly stop: () => void
}

export async function startMicLevelProbe(
  options: MicLevelProbeOptions,
): Promise<MicLevelProbeHandle | null> {
  if (
    typeof navigator === 'undefined'
    || !navigator.mediaDevices
    || typeof navigator.mediaDevices.getUserMedia !== 'function'
  ) {
    options.onError?.('이 브라우저는 마이크 입력 테스트를 지원하지 않습니다.')
    return null
  }

  const Ctor = getAudioContextCtor()
  if (!Ctor) {
    options.onError?.('WebAudio AudioContext를 사용할 수 없습니다.')
    return null
  }

  let stream: MediaStream | null = null
  let ctx: AudioContext | null = null
  let source: MediaStreamAudioSourceNode | null = null
  let rafId: number | null = null
  let stopped = false

  const stop = () => {
    if (stopped) return
    stopped = true
    if (rafId !== null && typeof cancelAnimationFrame === 'function') {
      cancelAnimationFrame(rafId)
      rafId = null
    }
    try {
      source?.disconnect()
    } catch { /* ignore */ }
    if (stream) {
      for (const track of stream.getTracks()) {
        try {
          track.stop()
        } catch { /* ignore */ }
      }
      stream = null
    }
    if (ctx && ctx.state !== 'closed') {
      void ctx.close().catch(() => {})
      ctx = null
    }
    options.onLevel(0)
  }

  try {
    const audioConstraints: MediaTrackConstraints = {
      noiseSuppression: options.noiseSuppression ?? true,
      echoCancellation: options.echoCancellation ?? true,
      autoGainControl: options.autoGainControl ?? true,
      ...(options.deviceId ? { deviceId: { ideal: options.deviceId } } : {}),
    }

    stream = await navigator.mediaDevices.getUserMedia({ audio: audioConstraints, video: false })
    if (stopped) {
      stop()
      return null
    }

    ctx = new Ctor()
    source = ctx.createMediaStreamSource(stream)
    const analyser = ctx.createAnalyser()
    analyser.fftSize = 256
    source.connect(analyser)

    const samples = new Uint8Array(analyser.fftSize)
    const tick = () => {
      if (stopped) return
      analyser.getByteTimeDomainData(samples)
      let sumSq = 0
      for (let i = 0; i < samples.length; i += 1) {
        const centered = ((samples[i] ?? 128) - 128) / 128
        sumSq += centered * centered
      }
      const rms = Math.min(1, Math.sqrt(sumSq / samples.length) * 2.4)
      options.onLevel(rms)
      if (typeof requestAnimationFrame === 'function') {
        rafId = requestAnimationFrame(tick)
      }
    }

    tick()
    return { stop }
  } catch (err) {
    stop()
    options.onError?.(err instanceof Error ? err.message : String(err))
    return null
  }
}

// ── Browser Desktop Notifications ─────────────────────────────────────

export type DesktopNotificationPermission = 'default' | 'granted' | 'denied' | 'unsupported'

export function getDesktopNotificationPermission(): DesktopNotificationPermission {
  if (typeof window === 'undefined' || typeof Notification === 'undefined') {
    return 'unsupported'
  }
  const perm = Notification.permission
  if (perm === 'granted' || perm === 'denied' || perm === 'default') {
    return perm
  }
  return 'unsupported'
}

export async function requestDesktopNotificationPermission(): Promise<DesktopNotificationPermission> {
  if (typeof window === 'undefined' || typeof Notification === 'undefined') {
    return 'unsupported'
  }
  if (typeof Notification.requestPermission !== 'function') {
    return getDesktopNotificationPermission()
  }
  try {
    const result = await Notification.requestPermission()
    if (result === 'granted' || result === 'denied' || result === 'default') {
      return result
    }
    return 'denied'
  } catch {
    return getDesktopNotificationPermission()
  }
}

export function sendDesktopNotification(
  event: DesktopNotifyEvent,
  title: string,
  body?: string,
  prefs: UserPrefs = userPrefs.peek(),
): boolean {
  if (!prefs.desktopNotify[event]) return false
  if (getDesktopNotificationPermission() !== 'granted') return false
  try {
    new Notification(title, body ? { body } : undefined)
    return true
  } catch {
    return false
  }
}
