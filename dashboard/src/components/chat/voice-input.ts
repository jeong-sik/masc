/**
 * Voice input for the keeper-chat composer (RFC-0236 P1).
 *
 * The dashboard captures speech with {@link MediaRecorder}, re-encodes it as
 * 16 kHz mono WAV ({@link recordingToWav}), and uploads the bytes to
 * `POST /api/v1/voice/transcribe`. The server transcribes with the workspace's
 * `[voice.stt]` endpoints and returns `{text}`; the composer fills its draft
 * with that text. Nothing about the audio is persisted — only the resulting
 * text, sent later through the existing path.
 *
 * This module owns the MediaRecorder lifecycle so the composer component stays
 * a thin shell: a mic button bound to {@link useVoiceInput} plus a status hint.
 */
import { useCallback, useLayoutEffect, useRef, useState } from 'preact/hooks'
import { authHeaders, fetchControlPlane, currentStoredTokenRevision, subscribeStoredTokenChanges } from '../../api/core'
import { recordingToWav } from './voice-wav'

import type { VoicePreparationPhase } from '../../keeper-chat-store'
export type VoiceInputState = 'idle' | VoicePreparationPhase

export interface TranscribeResult {
  /** The transcribed utterance. Empty string on a no-speech capture. */
  readonly text: string
  /** Scribe's detected language code, when the server returns one. */
  readonly languageCode: string | null
}

/** Upload audio under the caller's lifetime and the admitted credential epoch. */
export async function transcribeAudio(blob: Blob, options: { signal?: AbortSignal } = {}): Promise<TranscribeResult> {
  const controller = new AbortController()
  const signal = options.signal ? AbortSignal.any([controller.signal, options.signal]) : controller.signal
  const releaseAuth = subscribeStoredTokenChanges(() => controller.abort())
  try {
    signal.throwIfAborted()
    const res = await fetchControlPlane('/api/v1/voice/transcribe', {
      method: 'POST',
      headers: { ...authHeaders(), 'content-type': blob.type || 'audio/webm' },
      body: blob,
      signal,
    })
    signal.throwIfAborted()
    if (!res.ok) {
      let detail = `${res.status} ${res.statusText}`
      try {
        const err = (await res.json()) as { error?: string }
        if (typeof err?.error === 'string' && err.error !== '') detail = err.error
      } catch (error) {
        signal.throwIfAborted()
      }
      signal.throwIfAborted()
      throw new Error(detail)
    }
    const json = (await res.json()) as { text?: unknown; language_code?: unknown }
    signal.throwIfAborted()
    return {
      text: typeof json.text === 'string' ? json.text : '',
      languageCode: typeof json.language_code === 'string' ? json.language_code : null,
    }
  } finally {
    releaseAuth()
  }
}

/** True where MediaRecorder + getUserMedia are usable (excludes old Safari). */
export function voiceInputSupported(): boolean {
  return (
    typeof navigator !== 'undefined' &&
    typeof navigator.mediaDevices?.getUserMedia === 'function' &&
    typeof MediaRecorder !== 'undefined'
  )
}

export interface UseVoiceInputOptions {
  /** Host context ownership captured when recording is admitted. */
  readonly isCurrent?: () => boolean
  /** Admit one voice operation before requesting a microphone. */
  readonly onAdmitted?: (id: symbol) => boolean
  readonly onPhaseChanged?: (id: symbol, phase: VoicePreparationPhase) => void
  readonly onSettled?: (id: symbol) => void
  /** Adopt the completed text under the original operation identity. */
  readonly onTranscribed: (text: string, id: symbol) => void
  /** Called with a human-readable error string on capture/upload failure. */
  readonly onError?: (message: string) => void
}

export interface UseVoiceInput {
  readonly state: VoiceInputState
  readonly supported: boolean
  /** Begin a capture; resolves when recording actually starts. No-op if busy. */
  readonly start: () => Promise<void>
  /** Stop the active capture and transcribe it. No-op when not recording. */
  readonly stop: () => void
}

/**
 * MediaRecorder lifecycle as a Preact hook. The hook keeps a single recorder
 * at a time and tears down its MediaStream on every exit path (stop, error,
 * unmount) so the mic indicator never lingers.
 */
interface VoiceSession {
  readonly id: symbol
  settled: boolean
  readonly controller: AbortController
  readonly authRevision: number
  readonly options: UseVoiceInputOptions
  releaseAuth: () => void
  stream: MediaStream | null
  recorder: MediaRecorder | null
  chunks: Blob[]
}

export function useVoiceInput(options: UseVoiceInputOptions): UseVoiceInput {
  const [state, setState] = useState<VoiceInputState>('idle')
  const mounted = useRef(false)
  const active = useRef<VoiceSession | null>(null)
  const supported = voiceInputSupported()

  const release = useCallback((session: VoiceSession, cancel: boolean) => {
    const wasActive = active.current === session
    if (wasActive) active.current = null
    session.releaseAuth()
    if (cancel) session.controller.abort()
    const recorder = session.recorder
    session.recorder = null
    try {
      if (recorder) {
        recorder.ondataavailable = null
        recorder.onstop = null
        recorder.onerror = null
        if (recorder.state === 'recording' || recorder.state === 'paused') recorder.stop()
      }
    } finally {
      session.stream?.getTracks().forEach(track => track.stop())
      session.stream = null
      session.chunks = []
      if (mounted.current && wasActive) setState('idle')
      if (!session.settled) {
        session.settled = true
        session.options.onSettled?.(session.id)
      }
    }
  }, [])

  const owns = (session: VoiceSession) => mounted.current && active.current === session
    && !session.controller.signal.aborted
    && session.authRevision === currentStoredTokenRevision()
    && session.options.isCurrent?.() !== false

  useLayoutEffect(() => {
    mounted.current = true
    return () => {
      mounted.current = false
      if (active.current) release(active.current, true)
    }
  }, [release])
  useLayoutEffect(() => {
    if (active.current && !owns(active.current)) release(active.current, true)
  })

  const stop = useCallback(() => {
    const session = active.current
    if (!session || !owns(session)) {
      if (session) release(session, true)
      return
    }
    if (session.recorder?.state === 'recording') session.recorder.stop()
  }, [release])

  const start = async () => {
    if (!mounted.current || active.current || options.isCurrent?.() === false) return
    if (!supported) {
      options.onError?.('이 브라우저에서는 음성 입력을 지원하지 않습니다.')
      return
    }
    const session: VoiceSession = {
      id: Symbol('voice input'), settled: false, controller: new AbortController(), authRevision: currentStoredTokenRevision(), options,
      releaseAuth: () => {}, stream: null, recorder: null, chunks: [],
    }
    active.current = session
    if (session.options.onAdmitted?.(session.id) === false) { release(session, true); return }
    session.releaseAuth = subscribeStoredTokenChanges(() => release(session, true))
    setState('acquiring')
    const fail = (message: string) => {
      const present = owns(session)
      release(session, true)
      if (present) session.options.onError?.(message)
    }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      if (!owns(session)) {
        stream.getTracks().forEach(track => track.stop())
        release(session, true)
        return
      }
      session.stream = stream
      const recorder = new MediaRecorder(stream)
      session.recorder = recorder
      recorder.ondataavailable = (event: BlobEvent) => {
        if (owns(session) && event.data.size > 0) session.chunks.push(event.data)
      }
      recorder.onstop = () => {
        if (!owns(session)) { release(session, true); return }
        const blob = new Blob(session.chunks, { type: recorder.mimeType || 'audio/webm' })
        session.chunks = []
        session.stream?.getTracks().forEach(track => track.stop())
        session.stream = null
        if (blob.size === 0) { fail('녹음된 오디오 없음'); return }
        setState('transcribing')
        session.options.onPhaseChanged?.(session.id, 'transcribing')
        void (async () => {
          try {
            const wav = await recordingToWav(blob)
            if (!owns(session)) { release(session, true); return }
            const result = await transcribeAudio(wav, { signal: session.controller.signal })
            if (!owns(session)) { release(session, true); return }
            try {
              if (result.text === '') session.options.onError?.('음성을 인식하지 못했습니다. 다시 말해주세요.')
              else session.options.onTranscribed(result.text, session.id)
            } finally { release(session, false) }
          } catch (error) {
            fail(`전사 실패: ${error instanceof Error ? error.message : '알 수 없는 오류'}`)
          }
        })()
      }
      recorder.onerror = () => fail('녹음 중 오류가 발생했습니다.')
      recorder.start()
      setState('recording')
      session.options.onPhaseChanged?.(session.id, 'recording')
    } catch (error) {
      const e = error as DOMException
      fail(e?.name === 'NotAllowedError'
        ? '마이크 권한이 거부되었습니다. 브라우저 설정에서 허용하세요.'
        : `마이크를 열 수 없습니다: ${e?.message ?? '알 수 없는 오류'}`)
    }
  }

  return { state, supported, start, stop }
}
