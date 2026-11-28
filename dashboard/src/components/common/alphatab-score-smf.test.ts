// @vitest-environment node
import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import * as alphaTab from '@coderline/alphatab'
import { describe, expect, it } from 'vitest'
import { parseSmfBytes } from './alphatab-score'

const soundFont = new Uint8Array(
  readFileSync(createRequire(import.meta.url).resolve('@coderline/alphatab/soundfont/sonivox.sf2')),
)

/** Format 0 SMF: one quarter note, preceded by `setup` events at tick 0. */
function smf(channel: number, key: number, setup: readonly number[] = []): Uint8Array {
  const track = [
    ...setup,
    0x00, 0x90 | channel, key, 0x50,
    0x81, 0x40, 0x80 | channel, key, 0x00,
    0x00, 0xff, 0x2f, 0x00,
  ]
  return new Uint8Array([
    0x4d, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0, 192,
    0x4d, 0x54, 0x72, 0x6b, 0, 0, 0, track.length,
    ...track,
  ])
}

/** Renders the start of the file through the real synth with a sample sink for output. */
function render(bytes: Uint8Array): number[] {
  const emitter = () => {
    const listeners = new Set<(value?: unknown) => void>()
    return {
      on: (fn: (value?: unknown) => void) => {
        listeners.add(fn)
        return () => listeners.delete(fn)
      },
      off: (fn: (value?: unknown) => void) => listeners.delete(fn),
      trigger: (value?: unknown) => listeners.forEach((fn) => fn(value)),
    }
  }
  const samples: number[] = []
  const output = {
    ready: emitter(),
    samplesPlayed: emitter(),
    sampleRequest: emitter(),
    sampleRate: 44100,
    open() { this.ready.trigger() },
    activate() {},
    play() {},
    pause() {},
    destroy() {},
    resetSamples() {},
    addSamples(chunk: Float32Array) { samples.push(...chunk) },
  }
  const synth = new alphaTab.synth.AlphaSynth(output as unknown as alphaTab.synth.ISynthOutput, 320)
  synth.loadSoundFont(soundFont, false)
  synth.loadMidiFile(parseSmfBytes(alphaTab, bytes).midiFile)
  expect(synth.play()).toBe(true)
  for (let i = 0; i < 8; i += 1) output.sampleRequest.trigger()
  synth.destroy()
  return samples
}

function expectAudible(samples: readonly number[]): void {
  expect(samples.length).toBeGreaterThan(0)
  expect(samples.every(Number.isFinite)).toBe(true)
  expect(samples.some((sample) => Math.abs(sample) > 0.01)).toBe(true)
}

describe('parseSmfBytes playback', () => {
  it('is audible when the file names no instrument', () => {
    expectAudible(render(smf(0, 69)))
  })

  it('is audible on the percussion channel when the file names no kit', () => {
    expectAudible(render(smf(9, 38)))
  })

  it('keeps the instrument the file names at the first tick', () => {
    const unnamed = render(smf(0, 69))
    const piano = render(smf(0, 69, [0x00, 0xc0, 0]))
    const violin = render(smf(0, 69, [0x00, 0xc0, 40]))
    expectAudible(violin)
    expect(piano).toEqual(unnamed)
    expect(violin).not.toEqual(unnamed)
  })
})
