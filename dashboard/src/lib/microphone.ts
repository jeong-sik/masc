import { userPrefs } from './user-prefs'

type AudioContextCtor = typeof AudioContext

function getAudioContextCtor(): AudioContextCtor | null {
  if (typeof window === 'undefined') return null
  const win = window as unknown as {
    AudioContext?: AudioContextCtor
    webkitAudioContext?: AudioContextCtor
  }
  return win.AudioContext ?? win.webkitAudioContext ?? null
}

export async function enumerateMicrophones(): Promise<MediaDeviceInfo[]> {
  if (typeof navigator === 'undefined' || typeof navigator.mediaDevices?.enumerateDevices !== 'function') {
    return []
  }
  const devices = await navigator.mediaDevices.enumerateDevices()
  return devices.filter((device) => device.kind === 'audioinput' && device.deviceId !== '')
}

export function microphoneConstraints(): MediaTrackConstraints {
  const { inputDeviceId, noiseSuppression, echoCancellation, autoGainControl } = userPrefs.peek()
  return {
    noiseSuppression,
    echoCancellation,
    autoGainControl,
    ...(inputDeviceId ? { deviceId: { ideal: inputDeviceId } } : {}),
  }
}

export interface MicLevelProbeOptions {
  readonly signal?: AbortSignal
  readonly onLevel: (rms: number) => void
  readonly onError?: (message: string) => void
}

export interface MicLevelProbeHandle {
  readonly stop: () => void
}

export async function startMicLevelProbe(
  options: MicLevelProbeOptions,
): Promise<MicLevelProbeHandle | null> {
  const { signal } = options
  if (signal?.aborted) return null
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

  const stopTracks = (media: MediaStream) => {
    for (const track of media.getTracks()) {
      try {
        track.stop()
      } catch { /* ignore */ }
    }
  }

  const stop = () => {
    if (stopped) return
    stopped = true
    signal?.removeEventListener('abort', stop)
    if (rafId !== null && typeof cancelAnimationFrame === 'function') {
      cancelAnimationFrame(rafId)
      rafId = null
    }
    try {
      source?.disconnect()
    } catch { /* ignore */ }
    if (stream) {
      stopTracks(stream)
      stream = null
    }
    if (ctx && ctx.state !== 'closed') {
      void ctx.close().catch(() => {})
      ctx = null
    }
    if (!signal?.aborted) options.onLevel(0)
  }

  signal?.addEventListener('abort', stop, { once: true })
  try {
    const acquiredStream = await navigator.mediaDevices.getUserMedia({ audio: microphoneConstraints() })
    if (stopped) {
      // The browser permission request itself is not abortable.
      stopTracks(acquiredStream)
      return null
    }
    stream = acquiredStream

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
      if (!stopped && typeof requestAnimationFrame === 'function') {
        rafId = requestAnimationFrame(tick)
      }
    }

    tick()
    return { stop }
  } catch (err) {
    stop()
    if (!signal?.aborted) options.onError?.(err instanceof Error ? err.message : String(err))
    return null
  }
}
