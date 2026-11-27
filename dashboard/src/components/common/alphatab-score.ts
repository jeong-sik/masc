/**
 * Shared AlphaTab notation renderer & built-in Web Audio synthesizer player.
 *
 * Powers both:
 * 1. `<AlphaTexScoreView>` — renders ```` ```alphatex ```` / ```` ```atex ```` blocks
 *    with dark/light theme colors, ResizeObserver width handling, StaveProfile
 *    switching (`악보+탭` / `탭` / `악보`), click-to-zoom lightbox, explicit parse
 *    diagnostics, and built-in Web Audio playback via lazy-fetched `sonivox.sf2`.
 * 2. `<MidiScorePlayer>` — plays `audio/midi` attachments inline via Web Audio
 *    + `sonivox.sf2` with Play/Pause/Stop/Seek, BPM & track readout, and an
 *    optional `"악보 보기"` inline notation toggle.
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import type * as AlphaTabNs from '@coderline/alphatab'
import soundFontUrl from '@coderline/alphatab/soundfont/sonivox.sf2?url'
import { ChatPreviewModal } from '../primitives/chat-preview-modal'

export type AlphaTabModule = typeof AlphaTabNs
export type ScoreProfileChoice = 'score-tab' | 'tab' | 'score'

const MIN_SCORE_WIDTH_PX = 560
const RESIZE_DEBOUNCE_MS = 140
const SYNTH_BUFFER_MS = 320
const AUDIO_CHUNK_FRAMES = 4096
const AUDIO_SCHEDULE_AHEAD_SEC = 0.25
const AUDIO_PUMP_INTERVAL_MS = 45

let cachedAlphaTabPromise: Promise<AlphaTabModule> | null = null
let cachedSoundFontPromise: Promise<Uint8Array> | null = null

export function loadAlphaTab(): Promise<AlphaTabModule> {
  if (!cachedAlphaTabPromise) {
    cachedAlphaTabPromise = import('@coderline/alphatab').catch((err) => {
      cachedAlphaTabPromise = null
      throw err
    })
  }
  return cachedAlphaTabPromise
}

export function loadSoundFontBytes(): Promise<Uint8Array> {
  if (!cachedSoundFontPromise) {
    cachedSoundFontPromise = fetch(soundFontUrl)
      .then((res) => {
        if (!res.ok) {
          throw new Error(`사운드폰트 로드 실패 (HTTP ${res.status})`)
        }
        return res.arrayBuffer()
      })
      .then((buf) => new Uint8Array(buf))
      .catch((err) => {
        cachedSoundFontPromise = null
        throw err
      })
  }
  return cachedSoundFontPromise
}

export interface AlphaTabThemePalette {
  readonly mainGlyph: string
  readonly secondaryGlyph: string
  readonly staffLine: string
  readonly barSeparator: string
  readonly barNumber: string
  readonly scoreInfo: string
  readonly isLight: boolean
}

const DARK_FALLBACK_PALETTE: AlphaTabThemePalette = {
  mainGlyph: '#e8e4dc',
  secondaryGlyph: '#a8a298',
  staffLine: '#635d54',
  barSeparator: '#877f73',
  barNumber: '#d4a65a',
  scoreInfo: '#d7d2c8',
  isLight: false,
}

const LIGHT_FALLBACK_PALETTE: AlphaTabThemePalette = {
  mainGlyph: '#1c1a17',
  secondaryGlyph: '#524d45',
  staffLine: '#9e978c',
  barSeparator: '#756e64',
  barNumber: '#8c6118',
  scoreInfo: '#2d2a25',
  isLight: true,
}

let colorProbeCtx: CanvasRenderingContext2D | null | undefined

function getColorProbeContext(): CanvasRenderingContext2D | null {
  if (colorProbeCtx !== undefined) return colorProbeCtx
  if (typeof document === 'undefined') {
    colorProbeCtx = null
    return null
  }
  try {
    const canvas = document.createElement('canvas')
    canvas.width = 1
    canvas.height = 1
    colorProbeCtx = canvas.getContext('2d', { willReadFrequently: true })
  } catch {
    colorProbeCtx = null
  }
  return colorProbeCtx
}

const RGB_RE = /^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:\s*[,/]\s*([\d.]+%?))?\s*\)$/i
const HEX_RE = /^#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$/i

/**
 * Convert a CSS color value (including OKLCH tokens) into a `#rrggbb` or
 * `rgba(...)` string accepted by `alphaTab.model.Color.fromJson`.
 */
export function resolveCssColorToRgba(rawColor: string | null | undefined, fallback: string): string {
  const trimmed = rawColor?.trim()
  if (!trimmed) return fallback
  if (HEX_RE.test(trimmed) || RGB_RE.test(trimmed)) return trimmed

  const ctx = getColorProbeContext()
  if (!ctx) return fallback
  try {
    ctx.clearRect(0, 0, 1, 1)
    ctx.fillStyle = '#000000'
    ctx.fillStyle = trimmed
    const normalized = ctx.fillStyle
    if (HEX_RE.test(normalized) || RGB_RE.test(normalized)) {
      return normalized
    }
    ctx.fillRect(0, 0, 1, 1)
    const data = ctx.getImageData(0, 0, 1, 1).data
    if (data && data.length >= 4 && data[3]! > 0) {
      const a = Math.round((data[3]! / 255) * 100) / 100
      return a < 1 ? `rgba(${data[0]},${data[1]},${data[2]},${a})` : `rgb(${data[0]},${data[1]},${data[2]})`
    }
  } catch {
    // Fall back when jsdom/canvas does not implement 2D rendering or OKLCH.
  }
  return fallback
}

function isLightDocumentTheme(host: HTMLElement | null): boolean {
  if (typeof document === 'undefined') return false
  const themeAttr = host?.closest('[data-theme]')?.getAttribute('data-theme')
    ?? document.documentElement.getAttribute('data-theme')
  if (themeAttr === 'light') return true
  if (themeAttr === 'dark') return false
  if (typeof window !== 'undefined' && typeof window.matchMedia === 'function') {
    try {
      return window.matchMedia('(prefers-color-scheme: light)').matches
    } catch {
      return false
    }
  }
  return false
}

export function resolveAlphaTabThemePalette(host: HTMLElement | null): AlphaTabThemePalette {
  const isLight = isLightDocumentTheme(host)
  const fallback = isLight ? LIGHT_FALLBACK_PALETTE : DARK_FALLBACK_PALETTE
  if (!host || typeof getComputedStyle !== 'function') return fallback
  const styles = getComputedStyle(host)
  return {
    mainGlyph: resolveCssColorToRgba(styles.getPropertyValue('--fg-1'), fallback.mainGlyph),
    secondaryGlyph: resolveCssColorToRgba(styles.getPropertyValue('--fg-2'), fallback.secondaryGlyph),
    staffLine: resolveCssColorToRgba(styles.getPropertyValue('--line-2'), fallback.staffLine),
    barSeparator: resolveCssColorToRgba(styles.getPropertyValue('--fg-3'), fallback.barSeparator),
    barNumber: resolveCssColorToRgba(styles.getPropertyValue('--accent-brass-bright'), fallback.barNumber),
    scoreInfo: resolveCssColorToRgba(styles.getPropertyValue('--fg-2'), fallback.scoreInfo),
    isLight,
  }
}

export function applyAlphaTabPalette(
  alphaTab: AlphaTabModule,
  settings: AlphaTabNs.Settings,
  palette: AlphaTabThemePalette,
): void {
  const fromJson = alphaTab.model.Color.fromJson.bind(alphaTab.model.Color)
  const resources = settings.display.resources
  const main = fromJson(palette.mainGlyph)
  const secondary = fromJson(palette.secondaryGlyph)
  const staff = fromJson(palette.staffLine)
  const barSep = fromJson(palette.barSeparator)
  const barNum = fromJson(palette.barNumber)
  const info = fromJson(palette.scoreInfo)
  if (main) resources.mainGlyphColor = main
  if (secondary) resources.secondaryGlyphColor = secondary
  if (staff) resources.staffLineColor = staff
  if (barSep) resources.barSeparatorColor = barSep
  if (barNum) resources.barNumberColor = barNum
  if (info) resources.scoreInfoColor = info
}

export function pickDefaultScoreProfile(score: AlphaTabNs.model.Score): ScoreProfileChoice {
  const hasFretted = score.tracks.some((track) =>
    track.staves.some((staff) =>
      !staff.isPercussion && (staff.isStringed || staff.showTablature || staff.tuning.length > 0),
    ),
  )
  return hasFretted ? 'score-tab' : 'score'
}

export function toAlphaTabStaveProfile(
  alphaTab: AlphaTabModule,
  profile: ScoreProfileChoice,
): AlphaTabNs.StaveProfile {
  switch (profile) {
    case 'tab':
      return alphaTab.StaveProfile.Tab
    case 'score':
      return alphaTab.StaveProfile.Score
    case 'score-tab':
    default:
      return alphaTab.StaveProfile.ScoreTab
  }
}

export function measureScoreRenderWidth(host: HTMLElement | null): number {
  if (!host) return MIN_SCORE_WIDTH_PX
  const candidate = host.clientWidth || host.parentElement?.clientWidth || 0
  return Math.max(candidate, MIN_SCORE_WIDTH_PX)
}

export interface AlphaTexDiagnosticSummary {
  readonly message: string
  readonly details: readonly string[]
}

export function formatAlphaTexError(err: unknown): AlphaTexDiagnosticSummary {
  const fallbackMessage = err instanceof Error && err.message.trim()
    ? err.message.trim()
    : 'AlphaTex 악보를 해석하지 못했습니다.'

  if (err && typeof err === 'object' && 'iterateDiagnostics' in err && typeof err.iterateDiagnostics === 'function') {
    const details: string[] = []
    try {
      for (const diag of err.iterateDiagnostics() as Iterable<{
        start?: { line?: number; col?: number }
        message?: string
      }>) {
        const line = diag.start?.line
        const col = diag.start?.col
        const loc = typeof line === 'number'
          ? typeof col === 'number'
            ? `L${line}:${col}`
            : `L${line}`
          : null
        const msg = diag.message?.trim()
        if (msg) details.push(loc ? `${loc} — ${msg}` : msg)
        if (details.length >= 4) break
      }
    } catch {
      // Ignore diagnostic iteration failures and fall back to message.
    }
    if (details.length > 0) {
      return { message: fallbackMessage, details }
    }
  }

  return { message: fallbackMessage, details: [] }
}

/**
 * Render an already-parsed AlphaTab `Score` into an array of SVG markup chunks.
 */
export function renderScoreToSvgChunks(
  alphaTab: AlphaTabModule,
  score: AlphaTabNs.model.Score,
  width: number,
  profile: ScoreProfileChoice,
  palette: AlphaTabThemePalette,
): readonly string[] {
  const settings = new alphaTab.Settings()
  settings.core.engine = 'svg'
  settings.core.useWorkers = false
  settings.display.staveProfile = toAlphaTabStaveProfile(alphaTab, profile)
  settings.display.scale = 0.9
  settings.display.stretchForce = 0.9
  applyAlphaTabPalette(alphaTab, settings, palette)

  const renderer = new alphaTab.rendering.ScoreRenderer(settings)
  renderer.width = Math.max(width, MIN_SCORE_WIDTH_PX)

  const chunks: string[] = []
  let renderError: Error | null = null
  renderer.partialLayoutFinished.on((ev) => {
    if (ev.id) {
      renderer.renderResult(ev.id)
    }
  })
  renderer.partialRenderFinished.on((ev) => {
    if (typeof ev.renderResult === 'string' && ev.renderResult.length > 0) {
      chunks.push(ev.renderResult)
    }
  })
  renderer.renderFinished.on((ev) => {
    if (typeof ev.renderResult === 'string' && ev.renderResult.length > 0) {
      chunks.push(ev.renderResult)
    }
  })
  renderer.error.on((e) => {
    renderError = e
  })

  try {
    renderer.renderScore(score, score.tracks.length > 0 ? [0] : [])
  } finally {
    renderer.destroy()
  }

  if (renderError) throw renderError
  return chunks
}

export function parseAlphaTexScore(
  alphaTab: AlphaTabModule,
  source: string,
): AlphaTabNs.model.Score {
  const settings = new alphaTab.Settings()
  settings.core.engine = 'svg'
  settings.core.useWorkers = false
  const importer = new alphaTab.importer.AlphaTexImporter()
  importer.logErrors = false
  importer.initFromString(source, settings)
  return importer.readScore()
}

export interface ParsedSmfBundle {
  readonly midiFile: AlphaTabNs.midi.MidiFile
  readonly tempoBpm: number
  readonly trackCount: number
  readonly title: string | null
  readonly notationAlphaTex: string | null
}

const MIDI_PITCH_NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'] as const

function midiKeyToAlphaTexPitch(key: number): string {
  const clamped = Math.max(0, Math.min(127, Math.round(key)))
  const name = MIDI_PITCH_NAMES[clamped % 12]!
  const octave = Math.floor(clamped / 12) - 1
  return `${name}${octave}`
}

function durationTicksToAlphaTex(ticks: number, division: number): number {
  const beats = ticks / Math.max(division, 1)
  if (beats >= 3) return 1
  if (beats >= 1.5) return 2
  if (beats >= 0.75) return 4
  if (beats >= 0.375) return 8
  return 16
}

function readUint16BE(data: Uint8Array, offset: number): number {
  return ((data[offset] ?? 0) << 8) | (data[offset + 1] ?? 0)
}

function readUint32BE(data: Uint8Array, offset: number): number {
  return (
    (((data[offset] ?? 0) << 24) >>> 0)
    + ((data[offset + 1] ?? 0) << 16)
    + ((data[offset + 2] ?? 0) << 8)
    + (data[offset + 3] ?? 0)
  )
}

function readAscii4(data: Uint8Array, offset: number): string {
  return String.fromCharCode(
    data[offset] ?? 0,
    data[offset + 1] ?? 0,
    data[offset + 2] ?? 0,
    data[offset + 3] ?? 0,
  )
}

function readVlq(data: Uint8Array, start: number, end: number): { value: number; next: number } {
  let value = 0
  let pos = start
  for (let i = 0; i < 4 && pos < end; i += 1) {
    const byte = data[pos++]!
    value = (value << 7) | (byte & 0x7f)
    if ((byte & 0x80) === 0) break
  }
  return { value, next: pos }
}

/**
 * Parse a Standard MIDI File (SMF Format 0 or 1) binary buffer into an
 * `alphaTab.midi.MidiFile` ready for `AlphaSynth` playback plus metadata and
 * a notation preview AlphaTex string.
 */
export function parseSmfBytes(
  alphaTab: AlphaTabModule,
  bytes: Uint8Array,
): ParsedSmfBundle {
  if (bytes.byteLength < 14 || readAscii4(bytes, 0) !== 'MThd') {
    throw new Error('유효한 Standard MIDI(MThd) 파일 헤더가 아닙니다.')
  }
  const headerLen = readUint32BE(bytes, 4)
  if (headerLen < 6 || 8 + headerLen > bytes.byteLength) {
    throw new Error('MIDI 헤더 길이가 손상되었습니다.')
  }
  const declaredTracks = readUint16BE(bytes, 10)
  const rawDivision = readUint16BE(bytes, 12)
  const division = (rawDivision & 0x8000) !== 0 ? 480 : Math.max(1, rawDivision)

  const midiFile = new alphaTab.midi.MidiFile()
  midiFile.division = division
  const handler = new alphaTab.midi.AlphaSynthMidiFileHandler(midiFile)

  let pos = 8 + headerLen
  let parsedTrackCount = 0
  let firstTempoBpm = 120
  let sawTempo = false
  let firstTitle: string | null = null

  interface CapturedNote {
    readonly start: number
    readonly duration: number
    readonly key: number
  }
  const previewNotes: CapturedNote[] = []

  while (pos + 8 <= bytes.byteLength) {
    const chunkId = readAscii4(bytes, pos)
    const chunkLen = readUint32BE(bytes, pos + 4)
    const chunkStart = pos + 8
    const chunkEnd = Math.min(bytes.byteLength, chunkStart + chunkLen)
    pos = chunkEnd

    if (chunkId !== 'MTrk') continue
    const trackIdx = parsedTrackCount
    parsedTrackCount += 1

    let cur = chunkStart
    let absTick = 0
    let runningStatus = 0
    const activeNotes = new Map<string, { start: number; velocity: number }>()

    while (cur < chunkEnd) {
      const vlq = readVlq(bytes, cur, chunkEnd)
      absTick += vlq.value
      cur = vlq.next
      if (cur >= chunkEnd) break

      let status = bytes[cur]!
      if (status < 0x80) {
        if (runningStatus === 0) break
        status = runningStatus
      } else {
        cur += 1
        if (status < 0xf0) runningStatus = status
      }

      if (status === 0xff) {
        if (cur >= chunkEnd) break
        const metaType = bytes[cur++]!
        const lenInfo = readVlq(bytes, cur, chunkEnd)
        const metaStart = lenInfo.next
        const metaEnd = Math.min(chunkEnd, metaStart + lenInfo.value)
        cur = metaEnd

        if (metaType === 0x51 && metaEnd - metaStart >= 3) {
          const usPerQuarter = ((bytes[metaStart]! << 16) | (bytes[metaStart + 1]! << 8) | bytes[metaStart + 2]!)
          if (usPerQuarter > 0) {
            const bpm = Math.max(20, Math.min(400, Math.round(60_000_000 / usPerQuarter)))
            handler.addTempo(absTick, bpm)
            if (!sawTempo) {
              firstTempoBpm = bpm
              sawTempo = true
            }
          }
        } else if (metaType === 0x58 && metaEnd - metaStart >= 2) {
          const num = bytes[metaStart]!
          const den = 1 << Math.min(6, bytes[metaStart + 1]!)
          handler.addTimeSignature(absTick, num, den)
        } else if (metaType === 0x03 && !firstTitle && metaEnd > metaStart) {
          const rawName = new TextDecoder('utf-8', { fatal: false })
            .decode(bytes.subarray(metaStart, metaEnd))
            .trim()
          if (rawName) firstTitle = rawName
        } else if (metaType === 0x2f) {
          break
        }
        continue
      }

      if (status === 0xf0 || status === 0xf7) {
        const lenInfo = readVlq(bytes, cur, chunkEnd)
        cur = Math.min(chunkEnd, lenInfo.next + lenInfo.value)
        continue
      }

      const eventKind = status & 0xf0
      const channel = status & 0x0f

      if (eventKind === 0x90 || eventKind === 0x80) {
        if (cur + 1 >= chunkEnd) break
        const key = bytes[cur++]! & 0x7f
        const vel = bytes[cur++]! & 0x7f
        const noteKey = `${channel}:${key}`
        if (eventKind === 0x90 && vel > 0) {
          const prev = activeNotes.get(noteKey)
          if (prev) {
            const dur = Math.max(1, absTick - prev.start)
            handler.addNote(trackIdx, prev.start, dur, key, prev.velocity, channel)
            if (channel !== 9 && previewNotes.length < 96) {
              previewNotes.push({ start: prev.start, duration: dur, key })
            }
          }
          activeNotes.set(noteKey, { start: absTick, velocity: vel })
        } else {
          const started = activeNotes.get(noteKey)
          if (started) {
            activeNotes.delete(noteKey)
            const dur = Math.max(1, absTick - started.start)
            handler.addNote(trackIdx, started.start, dur, key, started.velocity, channel)
            if (channel !== 9 && previewNotes.length < 96) {
              previewNotes.push({ start: started.start, duration: dur, key })
            }
          }
        }
      } else if (eventKind === 0xb0) {
        if (cur + 1 >= chunkEnd) break
        const controller = bytes[cur++]! & 0x7f
        const value = bytes[cur++]! & 0x7f
        handler.addControlChange(trackIdx, absTick, channel, controller as AlphaTabNs.midi.ControllerType, value)
      } else if (eventKind === 0xc0) {
        if (cur >= chunkEnd) break
        const program = bytes[cur++]! & 0x7f
        handler.addProgramChange(trackIdx, absTick, channel, program)
      } else if (eventKind === 0xe0) {
        if (cur + 1 >= chunkEnd) break
        const lsb = bytes[cur++]! & 0x7f
        const msb = bytes[cur++]! & 0x7f
        handler.addBend(trackIdx, absTick, channel, ((msb << 7) | lsb) - 8192)
      } else if (eventKind === 0xa0) {
        cur = Math.min(chunkEnd, cur + 2)
      } else if (eventKind === 0xd0) {
        cur = Math.min(chunkEnd, cur + 1)
      }
    }

    // Close any hanging notes at end of track
    for (const [noteKey, started] of activeNotes) {
      const [chStr, keyStr] = noteKey.split(':')
      const channel = Number(chStr)
      const key = Number(keyStr)
      const dur = Math.max(division / 4, absTick - started.start)
      handler.addNote(trackIdx, started.start, dur, key, started.velocity, channel)
      if (channel !== 9 && previewNotes.length < 96) {
        previewNotes.push({ start: started.start, duration: dur, key })
      }
    }

    handler.finishTrack(trackIdx, Math.max(absTick, division))
  }

  if (parsedTrackCount === 0) {
    throw new Error('MIDI 트랙(MTrk)을 찾지 못했습니다.')
  }
  if (!sawTempo) {
    handler.addTempo(0, firstTempoBpm)
  }

  let notationAlphaTex: string | null = null
  if (previewNotes.length > 0) {
    previewNotes.sort((a, b) => a.start - b.start)
    const tokens = previewNotes.slice(0, 48).map((n) => {
      const dur = durationTicksToAlphaTex(n.duration, division)
      return `${midiKeyToAlphaTexPitch(n.key)}.${dur}`
    })
    const safeTitle = (firstTitle ?? 'MIDI').replace(/"/g, "'")
    notationAlphaTex = `\\title "${safeTitle}" \\tempo ${firstTempoBpm} \\instrument piano . ${tokens.join(' ')}`
  }

  return {
    midiFile,
    tempoBpm: firstTempoBpm,
    trackCount: Math.max(parsedTrackCount, declaredTracks),
    title: firstTitle,
    notationAlphaTex,
  }
}

export function buildMidiFileFromScore(
  alphaTab: AlphaTabModule,
  score: AlphaTabNs.model.Score,
): AlphaTabNs.midi.MidiFile {
  const settings = new alphaTab.Settings()
  const midi = new alphaTab.midi.MidiFile()
  const handler = new alphaTab.midi.AlphaSynthMidiFileHandler(midi)
  const generator = new alphaTab.midi.MidiFileGenerator(score, settings, handler)
  generator.generate()
  return midi
}

/* ─── Minimal Typed EventEmitter for ISynthOutput ─── */

class SimpleEmitter {
  private readonly listeners = new Set<() => void>()
  on(fn: () => void): () => void {
    this.listeners.add(fn)
    return () => this.listeners.delete(fn)
  }
  off(fn: () => void): void {
    this.listeners.delete(fn)
  }
  trigger(): void {
    for (const fn of Array.from(this.listeners)) fn()
  }
}

class SimpleEmitterOfT<T> {
  private readonly listeners = new Set<(arg: T) => void>()
  on(fn: (arg: T) => void): () => void {
    this.listeners.add(fn)
    return () => this.listeners.delete(fn)
  }
  off(fn: (arg: T) => void): void {
    this.listeners.delete(fn)
  }
  trigger(arg: T): void {
    for (const fn of Array.from(this.listeners)) fn(arg)
  }
}

function resolveAudioContextCtor(): (new () => AudioContext) | null {
  if (typeof window === 'undefined') return null
  const w = window as unknown as {
    AudioContext?: new () => AudioContext
    webkitAudioContext?: new () => AudioContext
  }
  return w.AudioContext ?? w.webkitAudioContext ?? null
}

/**
 * Self-contained Web Audio `ISynthOutput` backed by `AudioBufferSourceNode`
 * scheduling. Runs without external AudioWorklet/Worker script URLs so it works
 * cleanly under any Vite base path or CSP.
 */
class WebAudioSynthOutput implements AlphaTabNs.synth.ISynthOutput {
  readonly ready = new SimpleEmitter()
  readonly samplesPlayed = new SimpleEmitterOfT<number>()
  readonly sampleRequest = new SimpleEmitter()

  private ctx: AudioContext | null = null
  private sampleQueue: Float32Array[] = []
  private queuedFrames = 0
  private playing = false
  private destroyed = false
  private nextScheduleTime = 0
  private pumpTimer: number | null = null
  private activeSources = new Set<AudioBufferSourceNode>()
  private targetBufferFrames = 44100 * 0.35

  get sampleRate(): number {
    return this.ctx?.sampleRate ?? 44100
  }

  open(bufferTimeInMilliseconds: number): void {
    const AudioCtx = resolveAudioContextCtor()
    if (!AudioCtx) {
      throw new Error('이 환경에서는 Web Audio API(AudioContext)를 사용할 수 없습니다.')
    }
    if (!this.ctx) {
      this.ctx = new AudioCtx()
    }
    this.targetBufferFrames = Math.max(
      AUDIO_CHUNK_FRAMES * 2,
      Math.round((this.sampleRate * Math.max(bufferTimeInMilliseconds, 200)) / 1000),
    )
    this.ready.trigger()
  }

  activate(): void {
    if (this.ctx && this.ctx.state === 'suspended') {
      void this.ctx.resume()
    }
  }

  play(): void {
    if (this.destroyed || !this.ctx) return
    if (this.ctx.state === 'suspended') {
      void this.ctx.resume()
    }
    this.playing = true
    this.nextScheduleTime = Math.max(this.ctx.currentTime + 0.03, this.nextScheduleTime)
    this.requestMoreSamples()
    this.scheduleLoop()
    if (this.pumpTimer === null && typeof window !== 'undefined') {
      this.pumpTimer = window.setInterval(() => this.scheduleLoop(), AUDIO_PUMP_INTERVAL_MS)
    }
  }

  pause(): void {
    this.playing = false
    if (this.pumpTimer !== null && typeof window !== 'undefined') {
      window.clearInterval(this.pumpTimer)
      this.pumpTimer = null
    }
    this.stopActiveSources()
  }

  addSamples(samples: Float32Array): void {
    if (this.destroyed || samples.length === 0) return
    this.sampleQueue.push(samples)
    this.queuedFrames += Math.floor(samples.length / 2)
  }

  resetSamples(): void {
    this.sampleQueue = []
    this.queuedFrames = 0
    this.stopActiveSources()
    if (this.ctx) {
      this.nextScheduleTime = this.ctx.currentTime + 0.03
    }
  }

  destroy(): void {
    this.destroyed = true
    this.pause()
    this.sampleQueue = []
    this.queuedFrames = 0
    if (this.ctx) {
      const toClose = this.ctx
      this.ctx = null
      void toClose.close().catch(() => {})
    }
  }

  async enumerateOutputDevices(): Promise<AlphaTabNs.synth.ISynthOutputDevice[]> {
    return []
  }

  async setOutputDevice(): Promise<void> {
    // Default system audio output.
  }

  async getOutputDevice(): Promise<AlphaTabNs.synth.ISynthOutputDevice | null> {
    return null
  }

  private stopActiveSources(): void {
    for (const src of this.activeSources) {
      try {
        src.stop()
        src.disconnect()
      } catch {
        // Ignore already-stopped nodes.
      }
    }
    this.activeSources.clear()
  }

  private requestMoreSamples(): void {
    let guard = 0
    while (this.playing && !this.destroyed && this.queuedFrames < this.targetBufferFrames && guard < 12) {
      const before = this.queuedFrames
      this.sampleRequest.trigger()
      guard += 1
      if (this.queuedFrames <= before) break
    }
  }

  private dequeueInterleavedFrames(frameCount: number): Float32Array | null {
    const available = Math.min(frameCount, this.queuedFrames)
    if (available <= 0) return null
    const out = new Float32Array(available * 2)
    let writtenSamples = 0
    const targetSamples = available * 2
    while (writtenSamples < targetSamples && this.sampleQueue.length > 0) {
      const head = this.sampleQueue[0]!
      const needed = targetSamples - writtenSamples
      if (head.length <= needed) {
        out.set(head, writtenSamples)
        writtenSamples += head.length
        this.sampleQueue.shift()
      } else {
        out.set(head.subarray(0, needed), writtenSamples)
        this.sampleQueue[0] = head.subarray(needed)
        writtenSamples += needed
      }
    }
    this.queuedFrames = Math.max(0, this.queuedFrames - available)
    return out
  }

  private scheduleLoop(): void {
    if (!this.playing || this.destroyed || !this.ctx) return
    this.requestMoreSamples()

    const now = this.ctx.currentTime
    if (this.nextScheduleTime < now + 0.015) {
      this.nextScheduleTime = now + 0.02
    }

    while (this.playing && this.nextScheduleTime < now + AUDIO_SCHEDULE_AHEAD_SEC && this.queuedFrames > 0) {
      const frames = Math.min(AUDIO_CHUNK_FRAMES, this.queuedFrames)
      const interleaved = this.dequeueInterleavedFrames(frames)
      if (!interleaved) break

      const audioBuffer = this.ctx.createBuffer(2, frames, this.ctx.sampleRate)
      const left = audioBuffer.getChannelData(0)
      const right = audioBuffer.getChannelData(1)
      for (let i = 0; i < frames; i += 1) {
        left[i] = interleaved[i * 2] ?? 0
        right[i] = interleaved[i * 2 + 1] ?? 0
      }

      const source = this.ctx.createBufferSource()
      source.buffer = audioBuffer
      source.connect(this.ctx.destination)
      this.activeSources.add(source)
      source.onended = () => {
        this.activeSources.delete(source)
        if (!this.destroyed) {
          this.samplesPlayed.trigger(frames)
        }
      }
      source.start(this.nextScheduleTime)
      this.nextScheduleTime += frames / this.ctx.sampleRate
      this.requestMoreSamples()
    }
  }
}

export function formatPlaybackTime(ms: number): string {
  if (!Number.isFinite(ms) || ms <= 0) return '0:00'
  const totalSec = Math.floor(ms / 1000)
  const mins = Math.floor(totalSec / 60)
  const secs = totalSec % 60
  return `${mins}:${secs.toString().padStart(2, '0')}`
}

interface SynthPlayerHookResult {
  readonly status: 'idle' | 'loading' | 'playing' | 'paused' | 'error'
  readonly error: string | null
  readonly currentTimeMs: number
  readonly endTimeMs: number
  readonly tempo: number | null
  readonly playPause: () => void
  readonly stop: () => void
  readonly seekToMs: (ms: number) => void
}

function useMidiSynthPlayer(
  midiProvider: (() => AlphaTabNs.midi.MidiFile) | null,
  alphaTab: AlphaTabModule | null,
  tempoBpm: number | null,
  resetKey: unknown,
): SynthPlayerHookResult {
  const [status, setStatus] = useState<'idle' | 'loading' | 'playing' | 'paused' | 'error'>('idle')
  const [error, setError] = useState<string | null>(null)
  const [currentTimeMs, setCurrentTimeMs] = useState(0)
  const [endTimeMs, setEndTimeMs] = useState(0)
  const synthRef = useRef<AlphaTabNs.synth.AlphaSynth | null>(null)
  const mountedRef = useRef(true)

  const tempo = useMemo(
    () => (typeof tempoBpm === 'number' && Number.isFinite(tempoBpm) && tempoBpm > 0 ? Math.round(tempoBpm) : null),
    [tempoBpm],
  )

  const destroySynth = useCallback(() => {
    const existing = synthRef.current
    synthRef.current = null
    if (existing) {
      try {
        existing.stop()
        existing.destroy()
      } catch {
        // Ignore teardown errors.
      }
    }
  }, [])

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
      destroySynth()
    }
  }, [destroySynth])

  // Reset synth whenever the backing score/MIDI changes.
  useEffect(() => {
    destroySynth()
    setStatus('idle')
    setError(null)
    setCurrentTimeMs(0)
    setEndTimeMs(0)
  }, [resetKey, destroySynth])

  const ensureSynthAndPlay = useCallback(async () => {
    if (!midiProvider || !alphaTab) return
    if (synthRef.current) {
      synthRef.current.playPause()
      return
    }
    if (!resolveAudioContextCtor()) {
      setStatus('error')
      setError('이 브라우저/환경에서는 Web Audio 재생을 지원하지 않습니다.')
      return
    }

    setStatus('loading')
    setError(null)

    try {
      const soundFontBytes = await loadSoundFontBytes()
      if (!mountedRef.current) return

      const output = new WebAudioSynthOutput()
      const synth = new alphaTab.synth.AlphaSynth(output, SYNTH_BUFFER_MS)
      synthRef.current = synth

      synth.stateChanged.on((ev) => {
        if (!mountedRef.current) return
        if (ev.state === alphaTab.synth.PlayerState.Playing) {
          setStatus('playing')
        } else if (ev.stopped) {
          setStatus('idle')
          setCurrentTimeMs(0)
        } else {
          setStatus('paused')
        }
      })

      synth.positionChanged.on((ev) => {
        if (!mountedRef.current) return
        setCurrentTimeMs(ev.currentTime)
        if (ev.endTime > 0) setEndTimeMs(ev.endTime)
      })

      synth.finished.on(() => {
        if (!mountedRef.current) return
        setStatus('idle')
        setCurrentTimeMs(0)
      })

      synth.soundFontLoadFailed.on((e) => {
        if (!mountedRef.current) return
        setStatus('error')
        setError(`사운드폰트 로드 실패: ${e.message}`)
      })

      synth.midiLoadFailed.on((e) => {
        if (!mountedRef.current) return
        setStatus('error')
        setError(`MIDI 트랙 생성 실패: ${e.message}`)
      })

      synth.midiLoaded.on((ev) => {
        if (!mountedRef.current) return
        if (ev.endTime > 0) setEndTimeMs(ev.endTime)
      })

      const midi = midiProvider()
      synth.loadSoundFont(soundFontBytes, false)
      synth.loadMidiFile(midi)
      synth.play()
    } catch (err) {
      destroySynth()
      if (!mountedRef.current) return
      setStatus('error')
      setError(err instanceof Error ? err.message : '오디오 합성 재생 초기화에 실패했습니다.')
    }
  }, [alphaTab, destroySynth, midiProvider])

  const playPause = useCallback(() => {
    void ensureSynthAndPlay()
  }, [ensureSynthAndPlay])

  const stop = useCallback(() => {
    const synth = synthRef.current
    if (!synth) return
    synth.stop()
    setStatus('idle')
    setCurrentTimeMs(0)
  }, [])

  const seekToMs = useCallback((ms: number) => {
    const synth = synthRef.current
    if (!synth) return
    synth.timePosition = Math.max(0, ms)
    setCurrentTimeMs(Math.max(0, ms))
  }, [])

  return {
    status,
    error,
    currentTimeMs,
    endTimeMs,
    tempo,
    playPause,
    stop,
    seekToMs,
  }
}

/* ─── Shared SVG Score Canvas Renderer ─── */

function ScoreSvgSurface({
  alphaTab,
  score,
  profile,
  onClickZoom,
}: {
  readonly alphaTab: AlphaTabModule
  readonly score: AlphaTabNs.model.Score
  readonly profile: ScoreProfileChoice
  readonly onClickZoom?: () => void
}) {
  const hostRef = useRef<HTMLDivElement>(null)
  const [chunks, setChunks] = useState<readonly string[]>([])
  const [renderError, setRenderError] = useState<string | null>(null)
  const [widthTick, setWidthTick] = useState(0)

  useEffect(() => {
    const host = hostRef.current
    if (!host || typeof ResizeObserver === 'undefined') return
    let lastWidth = measureScoreRenderWidth(host)
    let timer: number | null = null
    const ro = new ResizeObserver(() => {
      const nextWidth = measureScoreRenderWidth(host)
      if (Math.abs(nextWidth - lastWidth) < 24) return
      lastWidth = nextWidth
      if (timer !== null && typeof window !== 'undefined') window.clearTimeout(timer)
      timer = window.setTimeout(() => setWidthTick((n) => n + 1), RESIZE_DEBOUNCE_MS)
    })
    ro.observe(host)
    return () => {
      ro.disconnect()
      if (timer !== null && typeof window !== 'undefined') window.clearTimeout(timer)
    }
  }, [])

  useEffect(() => {
    const host = hostRef.current
    try {
      const width = measureScoreRenderWidth(host)
      const palette = resolveAlphaTabThemePalette(host)
      const nextChunks = renderScoreToSvgChunks(alphaTab, score, width, profile, palette)
      setChunks(nextChunks)
      setRenderError(null)
    } catch (err) {
      setChunks([])
      setRenderError(err instanceof Error ? err.message : '악보 SVG 렌더링에 실패했습니다.')
    }
  }, [alphaTab, score, profile, widthTick])

  useEffect(() => {
    const host = hostRef.current
    if (!host) return
    host.innerHTML = chunks.join('')
  }, [chunks])

  if (renderError) {
    return html`
      <div class="rich-code-error" role="alert" data-testid="alphatex-render-error">
        <strong>악보 렌더링 오류:</strong> ${renderError}
      </div>
    `
  }

  return html`
    <div
      ref=${hostRef}
      class=${`rich-code-score${onClickZoom ? ' is-zoomable' : ''}`}
      data-testid="alphatex-score-svg"
      onClick=${onClickZoom}
      title=${onClickZoom ? '클릭하여 악보 확대 보기' : undefined}
    />
  `
}

function SynthTransportBar({
  player,
  label,
}: {
  readonly player: SynthPlayerHookResult
  readonly label?: string
}) {
  const isPlaying = player.status === 'playing'
  const isLoading = player.status === 'loading'
  const hasSeek = player.endTimeMs > 0

  return html`
    <div class="rich-synth-bar" data-testid="alphatab-synth-bar">
      <button
        type="button"
        class="rich-code-btn is-primary"
        disabled=${isLoading}
        onClick=${player.playPause}
        aria-label=${isPlaying ? '일시정지' : '악보 재생'}
      >
        ${isLoading ? '불러오는 중…' : isPlaying ? '⏸ 일시정지' : '▶ 재생'}
      </button>
      <button
        type="button"
        class="rich-code-btn"
        disabled=${player.status === 'idle' || isLoading}
        onClick=${player.stop}
        aria-label="정지"
      >
        ■ 정지
      </button>
      <input
        type="range"
        class="rich-synth-seek"
        min=${0}
        max=${Math.max(player.endTimeMs, 1)}
        value=${Math.min(player.currentTimeMs, Math.max(player.endTimeMs, 1))}
        disabled=${!hasSeek}
        aria-label="재생 위치"
        onInput=${(e: Event) => {
          const val = Number((e.currentTarget as HTMLInputElement).value)
          if (Number.isFinite(val)) player.seekToMs(val)
        }}
      />
      <span class="rich-synth-time mono">
        ${formatPlaybackTime(player.currentTimeMs)} / ${formatPlaybackTime(player.endTimeMs)}
      </span>
      ${player.tempo !== null && html`
        <span class="rich-synth-badge mono">♩=${player.tempo}</span>
      `}
      ${label && html`<span class="rich-synth-badge mono">${label}</span>`}
      ${player.error && html`
        <div class="rich-synth-error" role="alert" data-testid="alphatab-synth-error">
          ${player.error}
        </div>
      `}
    </div>
  `
}

/* ─── 1. AlphaTex Code Block Viewer ─── */

export interface AlphaTexScoreViewProps {
  readonly source: string
  readonly showSourceToggle?: boolean
}

const PROFILE_OPTIONS: ReadonlyArray<{ readonly id: ScoreProfileChoice; readonly label: string }> = [
  { id: 'score-tab', label: '악보+탭' },
  { id: 'tab', label: '탭' },
  { id: 'score', label: '악보' },
]

export function AlphaTexScoreView({ source, showSourceToggle = true }: AlphaTexScoreViewProps) {
  const [alphaTab, setAlphaTab] = useState<AlphaTabModule | null>(null)
  const [score, setScore] = useState<AlphaTabNs.model.Score | null>(null)
  const [parseError, setParseError] = useState<AlphaTexDiagnosticSummary | null>(null)
  const [loading, setLoading] = useState(true)
  const [profile, setProfile] = useState<ScoreProfileChoice>('score-tab')
  const [zoomOpen, setZoomOpen] = useState(false)

  useEffect(() => {
    let active = true
    setLoading(true)
    setParseError(null)
    setScore(null)

    void loadAlphaTab()
      .then((mod) => {
        if (!active) return
        setAlphaTab(mod)
        try {
          const parsed = parseAlphaTexScore(mod, source)
          if (!active) return
          setScore(parsed)
          setProfile(pickDefaultScoreProfile(parsed))
          setParseError(null)
        } catch (err) {
          if (!active) return
          setScore(null)
          setParseError(formatAlphaTexError(err))
        }
      })
      .catch((err) => {
        if (!active) return
        setParseError(formatAlphaTexError(err))
      })
      .finally(() => {
        if (active) setLoading(false)
      })

    return () => {
      active = false
    }
  }, [source])

  const midiProvider = useMemo(
    () => (score && alphaTab ? () => buildMidiFileFromScore(alphaTab, score) : null),
    [score, alphaTab],
  )
  const player = useMidiSynthPlayer(midiProvider, alphaTab, score?.tempo ?? null, score)
  const scoreTitle = score?.title?.trim() || 'AlphaTex 악보'
  const trackCountLabel = score && score.tracks.length > 0 ? `${score.tracks.length} 트랙` : undefined

  if (loading) {
    return html`
      <div class="rich-code-card" data-kind="alphatex" data-testid="alphatex-card">
        <div class="rich-code-loading">악보 렌더링 준비 중…</div>
      </div>
    `
  }

  if (parseError || !score || !alphaTab) {
    return html`
      <div class="rich-code-card is-error" data-kind="alphatex" data-testid="alphatex-error-card">
        <div class="rich-code-toolbar">
          <span class="rich-code-badge mono">ALPHATEX · 오류</span>
        </div>
        <div class="rich-code-error" role="alert">
          <div><strong>AlphaTex 구문 오류:</strong> ${parseError?.message ?? '악보를 해석하지 못했습니다.'}</div>
          ${parseError && parseError.details.length > 0 && html`
            <ul class="rich-code-error-list mono">
              ${parseError.details.map((line, i) => html`<li key=${i}>${line}</li>`)}
            </ul>
          `}
        </div>
        <pre class="rich-code-source-fallback"><code>${source}</code></pre>
      </div>
    `
  }

  return html`
    <div class="rich-code-card" data-kind="alphatex" data-testid="alphatex-card">
      <div class="rich-code-toolbar">
        <div class="rich-code-toolbar-left">
          <span class="rich-code-badge mono">ALPHATEX</span>
          ${score.title && html`<span class="rich-code-title">${score.title}</span>`}
        </div>
        <div class="rich-code-toolbar-right">
          <div class="rich-code-segmented" role="group" aria-label="악보 표시 형식">
            ${PROFILE_OPTIONS.map((opt) => html`
              <button
                key=${opt.id}
                type="button"
                class=${`rich-code-seg-btn${profile === opt.id ? ' is-active' : ''}`}
                aria-pressed=${profile === opt.id ? 'true' : 'false'}
                onClick=${() => setProfile(opt.id)}
              >
                ${opt.label}
              </button>
            `)}
          </div>
          <button
            type="button"
            class="rich-code-btn"
            onClick=${() => setZoomOpen(true)}
            aria-label="악보 확대 보기"
          >
            확대
          </button>
        </div>
      </div>

      <${SynthTransportBar} player=${player} label=${trackCountLabel} />

      <${ScoreSvgSurface}
        alphaTab=${alphaTab}
        score=${score}
        profile=${profile}
        onClickZoom=${() => setZoomOpen(true)}
      />

      ${showSourceToggle && html`
        <details class="rich-code-source">
          <summary>원본 AlphaTex 보기</summary>
          <pre><code>${source}</code></pre>
        </details>
      `}

      ${zoomOpen && html`
        <${ChatPreviewModal}
          title=${scoreTitle}
          subtitle=${[trackCountLabel, player.tempo ? `♩=${player.tempo}` : null].filter(Boolean).join(' · ') || undefined}
          onClose=${() => setZoomOpen(false)}
        >
          <div class="rich-code-modal-score">
            <${ScoreSvgSurface} alphaTab=${alphaTab} score=${score} profile=${profile} />
          </div>
        <//>
      `}
    </div>
  `
}

/* ─── 2. Inline SMF / MIDI Attachment Player ─── */

export interface MidiScorePlayerProps {
  readonly bytes: Uint8Array
  readonly title?: string
}

export function MidiScorePlayer({ bytes, title = 'MIDI 오디오' }: MidiScorePlayerProps) {
  const [alphaTab, setAlphaTab] = useState<AlphaTabModule | null>(null)
  const [bundle, setBundle] = useState<ParsedSmfBundle | null>(null)
  const [notationScore, setNotationScore] = useState<AlphaTabNs.model.Score | null>(null)
  const [parseError, setParseError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [showNotation, setShowNotation] = useState(false)
  const [profile, setProfile] = useState<ScoreProfileChoice>('score')

  useEffect(() => {
    let active = true
    setLoading(true)
    setParseError(null)
    setBundle(null)
    setNotationScore(null)

    void loadAlphaTab()
      .then((mod) => {
        if (!active) return
        setAlphaTab(mod)
        try {
          const parsed = parseSmfBytes(mod, bytes)
          if (!active) return
          setBundle(parsed)
          if (parsed.notationAlphaTex) {
            try {
              const previewScore = parseAlphaTexScore(mod, parsed.notationAlphaTex)
              setNotationScore(previewScore)
              setProfile('score')
            } catch {
              setNotationScore(null)
            }
          }
          setParseError(null)
        } catch (err) {
          if (!active) return
          setParseError(err instanceof Error ? err.message : 'MIDI 파일을 해석하지 못했습니다.')
        }
      })
      .catch((err) => {
        if (!active) return
        setParseError(err instanceof Error ? err.message : 'MIDI 엔진 로드에 실패했습니다.')
      })
      .finally(() => {
        if (active) setLoading(false)
      })

    return () => {
      active = false
    }
  }, [bytes])

  const midiProvider = useMemo(
    () => (bundle ? () => bundle.midiFile : null),
    [bundle],
  )
  const player = useMidiSynthPlayer(midiProvider, alphaTab, bundle?.tempoBpm ?? null, bundle)
  const trackCount = bundle?.trackCount ?? 0

  if (loading) {
    return html`<div class="rich-code-loading" data-testid="midi-player-loading">MIDI 분석 중…</div>`
  }

  if (parseError || !bundle || !alphaTab) {
    return html`
      <div class="rich-code-error" role="alert" data-testid="midi-player-error">
        MIDI 재생 불가 (${title}): ${parseError ?? '알 수 없는 오류'}
      </div>
    `
  }

  return html`
    <div class="att-midi-player" data-testid="midi-player">
      <${SynthTransportBar}
        player=${player}
        label=${trackCount > 0 ? `${trackCount} 트랙` : undefined}
      />
      ${notationScore && html`
        <div class="att-midi-actions">
          <button
            type="button"
            class="rich-code-btn"
            aria-expanded=${showNotation ? 'true' : 'false'}
            onClick=${() => setShowNotation((v) => !v)}
          >
            ${showNotation ? '악보 숨기기' : '악보 보기'}
          </button>
          ${showNotation && html`
            <div class="rich-code-segmented" role="group" aria-label="MIDI 악보 형식">
              ${PROFILE_OPTIONS.map((opt) => html`
                <button
                  key=${opt.id}
                  type="button"
                  class=${`rich-code-seg-btn${profile === opt.id ? ' is-active' : ''}`}
                  aria-pressed=${profile === opt.id ? 'true' : 'false'}
                  onClick=${() => setProfile(opt.id)}
                >
                  ${opt.label}
                </button>
              `)}
            </div>
          `}
        </div>
      `}
      ${showNotation && notationScore && html`
        <${ScoreSvgSurface} alphaTab=${alphaTab} score=${notationScore} profile=${profile} />
      `}
    </div>
  `
}
