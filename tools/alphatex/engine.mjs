import * as alphaTab from '@coderline/alphatab'
import * as alphaSkia from '@coderline/alphaskia'
import { createRequire } from 'node:module'
import { dirname, join } from 'node:path'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

export const engineVersion = JSON.parse(readFileSync(new URL('../package.json', import.meta.resolve('@coderline/alphatab')), 'utf8')).version
const musicFont = fileURLToPath(import.meta.resolve('@coderline/alphatab/font/Bravura.otf'))
let graphicsReady = false

function enableGraphics() {
  if (graphicsReady) return
  const platform = { darwin: 'macos', linux: 'linux', win32: 'windows' }[process.platform]
  if (!platform) throw new Error(`alphaSkia has no native package for ${process.platform}`)
  // Resolve from alphaSkia's own dependencies, including pnpm's isolated
  // layout. Its default search assumes hoisted node_modules.
  const require = createRequire(import.meta.resolve('@coderline/alphaskia'))
  const platformPackage = require.resolve(`@coderline/alphaskia-${platform}/package.json`)
  alphaSkia.addSearchPaths(join(dirname(platformPackage), 'lib'))
  alphaSkia.AlphaSkiaCanvas.switchToOperatingSystemFonts()
  const font = readFileSync(musicFont)
  alphaTab.Environment.enableAlphaSkia(font.buffer.slice(font.byteOffset, font.byteOffset + font.byteLength), alphaSkia)
  graphicsReady = true
}

export function readScore(source) {
  const settings = new alphaTab.Settings()
  const importer = new alphaTab.importer.AlphaTexImporter()
  importer.logErrors = false
  importer.initFromString(source, settings)
  const score = importer.readScore()
  return { score, settings }
}

export function renderScore(source, { width = 1000, scale = 1, tracks, page } = {}) {
  enableGraphics()
  const { score, settings } = readScore(source)
  settings.core.engine = 'skia'
  settings.core.enableLazyLoading = true
  settings.display.scale = scale
  const renderer = new alphaTab.rendering.ScoreRenderer(settings)
  renderer.width = width
  const parts = []
  renderer.partialLayoutFinished.on(result => parts.push(result))
  let canvas
  try {
    renderer.renderScore(score, tracks ?? score.tracks.map(track => track.index))
    if (parts.length === 0) throw new Error('alphaTab produced no score image')
    // Use official system boundaries for interactive pages. Only the selected
    // system is rasterized, so a long song does not allocate a song-sized PNG.
    // Explicit file export (page omitted) retains the official whole layout.
    const systems = parts.flatMap((part, index) => part.firstMasterBarIndex >= 0 ? [index] : [])
    const boundaries = [0, ...systems.slice(1), parts.length]
    const pageCount = boundaries.length - 1
    const selectedPage = Math.max(0, Math.min(page ?? 0, pageCount - 1))
    const selectedParts = page === undefined ? parts : parts.slice(boundaries[selectedPage], boundaries[selectedPage + 1])
    const top = page === undefined || selectedPage === 0 ? 0 : selectedParts[0].y
    const height = Math.ceil(Math.max(...selectedParts.map(part => part.y + part.height)) - top)
    canvas = new alphaSkia.AlphaSkiaCanvas()
    canvas.beginRender(width, height)
    canvas.color = alphaSkia.AlphaSkiaCanvas.rgbaToColor(255, 255, 255, 255)
    canvas.fillRect(0, 0, width, height)
    renderer.partialRenderFinished.on(result => {
      try { canvas.drawImage(result.renderResult, result.x, result.y - top, result.width, result.height) }
      finally { result.renderResult[Symbol.dispose]() }
    })
    for (const part of selectedParts) renderer.renderResult(part.id)
    const pixels = canvas.endRender()
    let png
    try { png = pixels.toPng() } finally { pixels[Symbol.dispose]() }
    if (!png) throw new Error('alphaSkia could not encode the score PNG')
    return {
      version: engineVersion, title: score.title,
      tracks: score.tracks.map(track => ({ index: track.index, name: track.name })),
      page: selectedPage, pageCount,
      pages: [{ png: new Uint8Array(png), width, height }],
    }
  } finally {
    renderer.destroy()
    canvas?.[Symbol.dispose]()
  }
}

export function midiForScore(source, { smf1Mode = false } = {}) {
  const { score, settings } = readScore(source)
  const midi = new alphaTab.midi.MidiFile()
  const handler = new alphaTab.midi.AlphaSynthMidiFileHandler(midi, smf1Mode)
  const generator = new alphaTab.midi.MidiFileGenerator(score, settings, handler)
  generator.generate()
  return { score, midi, generator }
}

export function createAudioExporter(source, { soundfont, tracks, sampleRate = 44100 } = {}) {
  const { score, midi, generator } = midiForScore(source)
  const options = new alphaTab.synth.AudioExportOptions()
  options.sampleRate = sampleRate
  options.soundFonts = [soundfont ?? readFileSync(fileURLToPath(import.meta.resolve('@coderline/alphatab/soundfont/sonivox.sf2')))]
  options.useSyncPoints = false
  if (tracks) {
    for (const track of score.tracks) {
      const volume = tracks.includes(track.index) ? 1 : 0
      options.trackVolume.set(track.playbackInfo.primaryChannel, volume)
      options.trackVolume.set(track.playbackInfo.secondaryChannel, volume)
    }
  }
  // Exporting is synchronous and does not require a browser AudioContext.
  // AlphaSynth still requires an output when constructed; no playback output
  // is opened here. Audio is delivered by the exporter's render() below.
  const unusedEvent = { on() {}, off() {} }
  const synth = new alphaTab.synth.AlphaSynth({
    sampleRate, ready: unusedEvent, sampleRequest: unusedEvent,
    samplesPlayed: unusedEvent, open() {},
  }, 0)
  return synth.exportAudio(options, midi, generator.syncPoints, generator.transpositionPitches)
}
