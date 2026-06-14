/**
 * Voice input for the keeper-chat composer (RFC-0236 P1).
 *
 * The dashboard captures speech with {@link MediaRecorder} and uploads the raw
 * audio bytes to `POST /api/v1/voice/transcribe`. The server runs ElevenLabs
 * Scribe v2 (already provisioned in voice_config.json) and returns `{text}`;
 * the composer fills its draft with that text. Nothing about the audio is
 * persisted — only the resulting text, sent later through the existing path.
 *
 * This module owns the MediaRecorder lifecycle so the composer component stays
 * a thin shell: a mic button bound to {@link useVoiceInput} plus a status hint.
 */
import { useCallback, useEffect, useRef, useState } from 'preact/hooks'
import { authHeaders, fetchWithTimeout } from '../../api/core'

export type VoiceInputState = 'idle' | 'recording' | 'transcribing'

export interface TranscribeResult {
  /** The transcribed utterance. Empty string on a no-speech capture. */
  readonly text: string
  /** Scribe's detected language code, when the server returns one. */
  readonly languageCode: string | null
}

const TRANSCRIBE_TIMEOUT_MS = 60_000

/** Upload a recorded clip and return the transcribed text. */
export async function transcribeAudio(blob: Blob): Promise<TranscribeResult> {
  const res = await fetchWithTimeout(
    '/api/v1/voice/transcribe',
    {
      method: 'POST',
      headers: { ...authHeaders(), 'content-type': blob.type || 'audio/webm' },
      body: blob,
    },
    TRANSCRIBE_TIMEOUT_MS,
  )
  if (!res.ok) {
    let detail = `${res.status} ${res.statusText}`
    try {
      const err = (await res.json()) as { error?: string }
      if (typeof err?.error === 'string' && err.error !== '') detail = err.error
    } catch {
      // Body was not JSON; keep the status-line detail.
    }
    throw new Error(detail)
  }
  const json = (await res.json()) as { text?: unknown; language_code?: unknown }
  const text = typeof json.text === 'string' ? json.text : ''
  const languageCode = typeof json.language_code === 'string' ? json.language_code : null
  return { text, languageCode }
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
  /** Called with the transcribed text once Scribe returns. */
  readonly onTranscribed: (text: string) => void
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
export function useVoiceInput({ onTranscribed, onError }: UseVoiceInputOptions): UseVoiceInput {
  const [state, setState] = useState<VoiceInputState>('idle')
  const recorderRef = useRef<MediaRecorder | null>(null)
  const streamRef = useRef<MediaStream | null>(null)
  const chunksRef = useRef<Blob[]>([])
  // Keep the latest callbacks without re-arming the recorder on every render.
  const onTranscribedRef = useRef(onTranscribed)
  const onErrorRef = useRef(onError)
  onTranscribedRef.current = onTranscribed
  onErrorRef.current = onError

  const supported = voiceInputSupported()

  const stopStream = useCallback(() => {
    streamRef.current?.getTracks().forEach((t) => t.stop())
    streamRef.current = null
  }, [])

  const fail = useCallback(
    (message: string) => {
      stopStream()
      recorderRef.current = null
      chunksRef.current = []
      setState('idle')
      onErrorRef.current?.(message)
    },
    [stopStream],
  )

  const stop = useCallback(() => {
    const recorder = recorderRef.current
    if (!recorder || recorder.state === 'inactive') return
    // The actual transcribe happens in the onstop handler below.
    recorder.stop()
  }, [])

  const start = useCallback(async () => {
    if (!supported) {
      onErrorRef.current?.('이 브라우저에서는 음성 입력을 지원하지 않습니다.')
      return
    }
    if (state !== 'idle') return
    chunksRef.current = []
    let stream: MediaStream
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch (err) {
      const e = err as DOMException
      const message =
        e?.name === 'NotAllowedError'
          ? '마이크 권한이 거부되었습니다. 브라우저 설정에서 허용하세요.'
          : `마이크를 열 수 없습니다: ${e?.message ?? '알 수 없는 오류'}`
      fail(message)
      return
    }
    streamRef.current = stream
    const recorder = new MediaRecorder(stream)
    recorderRef.current = recorder
    recorder.ondataavailable = (event: BlobEvent) => {
      if (event.data.size > 0) chunksRef.current.push(event.data)
    }
    recorder.onstop = () => {
      const mimeType = recorder.mimeType || 'audio/webm'
      const blob = new Blob(chunksRef.current, { type: mimeType })
      chunksRef.current = []
      stopStream()
      recorderRef.current = null
      if (blob.size === 0) {
        setState('idle')
        onErrorRef.current?.('녹음된 오디오가 없습니다.')
        return
      }
      setState('transcribing')
      transcribeAudio(blob)
        .then((result) => {
          setState('idle')
          if (result.text === '') {
            onErrorRef.current?.('음성을 인식하지 못했습니다. 다시 말해주세요.')
            return
          }
          onTranscribedRef.current(result.text)
        })
        .catch((err: unknown) => {
          const e = err as Error
          fail(`전사 실패: ${e?.message ?? '알 수 없는 오류'}`)
        })
    }
    recorder.onerror = () => {
      fail('녹음 중 오류가 발생했습니다.')
    }
    recorder.start()
    setState('recording')
  }, [supported, state, fail, stopStream])

  // Release the mic if the composer unmounts mid-recording.
  useEffect(() => stopStream, [stopStream])

  return { state, supported, start, stop }
}
