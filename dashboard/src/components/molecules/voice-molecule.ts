// keeper-v2 design voice-memo molecule — Voice from
// prototypes/keeper-v2/molecules.jsx, fed by the live ChatVoiceBlock
// (src/types/core.ts). Playback is real: the play button only appears when the
// block carries an audio payload (`src`), and the playhead is driven by the
// <audio> element's own timeupdate — no simulated scrubbing.

import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import type { ChatVoiceBlock } from '../../types'

function isSafeAudioSrc(url: string): boolean {
  try {
    const u = new URL(url, typeof window !== 'undefined' ? window.location.href : 'http://localhost')
    if (u.protocol === 'http:' || u.protocol === 'https:' || u.protocol === 'blob:') return true
  } catch {
    // fall through to the data: check
  }
  return url.slice(0, 64).toLowerCase().startsWith('data:audio/')
}

function formatVoiceClock(seconds: number): string {
  return `${Math.floor(seconds / 60)}:${String(Math.round(seconds) % 60).padStart(2, '0')}`
}

export function MoleculeVoice({
  secs,
  wave,
  via,
  size,
  transcript,
  src,
  sttLabel = '받아쓰기',
}: ChatVoiceBlock & { sttLabel?: string }): VNode {
  const safeSrc = src && isSafeAudioSrc(src) ? src : null
  const audioRef = useRef<HTMLAudioElement | null>(null)
  const [playing, setPlaying] = useState(false)
  const [prog, setProg] = useState(0)

  useEffect(() => () => {
    audioRef.current?.pause()
    audioRef.current = null
  }, [])

  const toggle = () => {
    if (!safeSrc) return
    if (!audioRef.current) {
      audioRef.current = new Audio(safeSrc)
      audioRef.current.addEventListener('timeupdate', () => {
        const a = audioRef.current
        if (a && Number.isFinite(a.duration) && a.duration > 0) setProg(a.currentTime / a.duration)
      })
      audioRef.current.addEventListener('ended', () => {
        setPlaying(false)
        setProg(1)
      })
    }
    const a = audioRef.current
    if (playing) {
      a.pause()
      setPlaying(false)
    } else {
      if (prog >= 1) {
        a.currentTime = 0
        setProg(0)
      }
      void a.play().catch(() => setPlaying(false))
      setPlaying(true)
    }
  }

  const bars = useMemo(() => wave ?? [], [wave])
  const playedBars = Math.floor(prog * bars.length)
  const totalSecs = secs ?? (audioRef.current && Number.isFinite(audioRef.current.duration) ? audioRef.current.duration : null)
  const durLabel = totalSecs != null
    ? formatVoiceClock(playing || prog > 0 ? prog * totalSecs : totalSecs)
    : null

  return html`
    <div class="voice">
      <div class="voice-row">
        ${safeSrc
          ? html`
              <button
                type="button"
                class="voice-play ${playing ? 'on' : ''}"
                onClick=${toggle}
                aria-label=${playing ? '일시정지' : '재생'}
              >
                ${playing ? '❙❙' : '▶'}
              </button>
            `
          : null}
        ${bars.length > 0
          ? html`
              <div class="voice-wave">
                ${bars.map((h, i) => html`
                  <span
                    key=${i}
                    class="vbar ${i < playedBars ? 'on' : ''}"
                    style=${{ height: `${Math.round(5 + h * 21)}px` }}
                  />
                `)}
              </div>
            `
          : null}
        ${durLabel ? html`<span class="voice-dur mono">${durLabel}</span>` : null}
      </div>
      ${via || size
        ? html`
            <div class="voice-meta">
              ${via ? html`<span class="voice-via">◌ ${via}</span>` : null}
              ${size ? html`<span class="mono">${size}</span>` : null}
            </div>
          `
        : null}
      ${transcript
        ? html`
            <div class="voice-tx">
              <span class="voice-tx-k">${sttLabel}</span>
              <span class="voice-tx-v">${transcript}</span>
            </div>
          `
        : null}
    </div>
  `
}
