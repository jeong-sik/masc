import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { midi } from '@coderline/alphatab'
import { readScore, renderScore, midiForScore, createAudioExporter } from '../engine.mjs'
import { errorDetail } from '../diagnostics.mjs'

const bass = String.raw`\title "반음 연결 연습"
\tempo 80
\instrument 34
\tuning (G2 D2 A1 E1)
\staff {score tabs}
\ts 4 4
:4 5.3 7.2 7.2 :8 3.2 4.2 |
:2 5.2 {d} :4 r |
:4 7.3 7.2 7.2 :8 5.2 4.2 |
:2 3.2 {d} :4 r`

test('official importer reads bass instrument, tuning, dotted rhythm and rests', () => {
  const { score } = readScore(bass)
  assert.equal(score.tracks.length, 1)
  assert.equal(score.tracks[0].playbackInfo.program, 34)
  assert.equal(score.tracks[0].staves[0].tuning.length, 4)
  assert.equal(score.masterBars.length, 4)
})

test('renders bass through official alphaSkia engraving into PNG pixels', () => {
  const result = renderScore(bass)
  assert.ok(result.pages.length > 0)
  assert.deepEqual([...result.pages[0].png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10])
  assert.ok(result.pages.every(page => page.width > 0 && page.height > 0))
})

test('interactive pages rasterize official systems without allocating one whole-song image', () => {
  const source = Array.from({ length: 40 }, () => ':4 3.3 5.3 7.3 5.3').join(' | ')
  const first = renderScore(source, { width: 600, page: 0 })
  assert.ok(first.pageCount > 1)
  const last = renderScore(source, { width: 600, page: first.pageCount - 1 })
  assert.equal(last.page + 1, first.pageCount)
  assert.equal(last.pages[0].width, 600)
  assert.ok(first.pages[0].height < 1000)
  assert.ok(last.pages[0].height < 1000)
})

test('official MIDI generation produces notes for playback', () => {
  const { midi } = midiForScore(bass, { smf1Mode: true })
  assert.equal(Buffer.from(midi.toBinary()).subarray(0, 4).toString(), 'MThd')
})

test('official synthesizer produces audible PCM, including the score duration', () => {
  const exporter = createAudioExporter(String.raw`\instrument 34 \tuning (G2 D2 A1 E1) :4 5.3 r 7.2 r`)
  let peak = 0
  let samples = 0
  for (let chunk; (chunk = exporter.render(500));) {
    samples += chunk.samples.length
    for (const sample of chunk.samples) {
      assert.ok(Number.isFinite(sample))
      peak = Math.max(peak, Math.abs(sample))
    }
  }
  assert.ok(peak > 0.001, `silent audio: peak ${peak}`)
  assert.ok(samples >= 44100 * 2, `unexpectedly short audio: ${samples}`)
})

test('rejects the screenshot singular staff tab, preserving the actual syntax error', () => {
  assert.throws(() => readScore(String.raw`\instrument 34 \tuning (G2 D2 A1 E1) \staff {score tab} :4 5.3`))
})

test('tie effects sit between note and duration, ahead of the beat length dot', () => {
  const source = readFileSync(new URL('./fixtures/bamseom-solo.atex', import.meta.url), 'utf8')
  const { score } = readScore(source)
  assert.equal(score.title, 'Bamseom Solo')
  assert.equal(score.masterBars.length, 2)
  const ties = []
  for (const track of score.tracks) {
    for (const staff of track.staves) {
      for (const bar of staff.bars) {
        for (const voice of bar.voices) {
          for (const beat of voice.beats) {
            for (const note of beat.notes) {
              if (note.isTieDestination) ties.push(note.fret)
            }
          }
        }
      }
    }
  }
  assert.deepEqual(ties, [7, 5, 3])
  assert.ok(renderScore(source, { page: 0 }).pages[0].png.length > 0)
  try {
    readScore('3.5.8 7.4.8{t} |')
    assert.fail('a tie after the duration was accepted')
  } catch (error) {
    const detail = errorDetail(error)
    assert.match(detail, /AT205/)
    assert.match(detail, /Unrecognized property 't'/)
  }
})

test('official renderer supports independent piano voices and guitar effects', () => {
  const source = String.raw`\title "Ensemble"
\track "Piano" {instrument 0}
\staff {score}
C4.4 D4 E4 F4 |
\staff {score}
\clef bass
C3.2 G2 |
\track "Guitar" {instrument 25}
\staff {score tabs}
\tuning (E4 B3 G3 D3 A2 E2)
:8 3.3{h} 5.3 7.3{v} 5.3 3.3 5.3 7.3 5.3 |`
  const result = renderScore(source)
  assert.equal(result.tracks.length, 2)
  assert.ok(result.pages.length > 0)
})

test('invalid source does not turn into a successful empty score', () => {
  assert.throws(() => readScore(String.raw`\nonexistentDirective 123`))
})

test('solo percussion tracks match isolated parts even when they share MIDI channel 9', () => {
  const parts = [
    String.raw`\track "Kick" \instrument percussion :4 36 36 36 36`,
    String.raw`\track "Snare" \instrument percussion :4 38 38 38 38`,
  ]
  const source = parts.join(' | ')
  assert.deepEqual(readScore(source).score.tracks.map(track => track.playbackInfo.primaryChannel), [9, 9])
  const pcm = (text, tracks) => {
    const chunks = []
    const exporter = createAudioExporter(text, { tracks })
    for (let chunk; (chunk = exporter.render(500));) {
      chunks.push(Buffer.from(chunk.samples.buffer, chunk.samples.byteOffset, chunk.samples.byteLength))
    }
    return Buffer.concat(chunks)
  }
  const kick = pcm(source, [0])
  const snare = pcm(source, [1])
  assert.deepEqual(kick, pcm(parts[0]))
  assert.deepEqual(snare, pcm(parts[1]))
  assert.notDeepEqual(kick, snare)
})

test('selected tracks retain global repeat and tempo order without accepting missing tracks', () => {
  const source = String.raw`\tempo 80 \track "First" \ro :4 0.6 r r r | \tempo 120 \rc 2 0.6 r r r |
\track "Second" :4 3.3 r r r | 5.3 r r r`
  const full = midiForScore(source)
  const selected = midiForScore(source, { tracks: [1] })
  assert.equal(selected.score.tracks.length, 2)
  assert.equal(selected.score.tracks[1].name, 'Second')
  assert.equal(selected.score.tracks[1].index, 1)
  assert.deepEqual(
    selected.generator.tickLookup.masterBars.map(bar => [bar.start, bar.end, bar.masterBar.index, bar.tempoChanges]),
    full.generator.tickLookup.masterBars.map(bar => [bar.start, bar.end, bar.masterBar.index, bar.tempoChanges]),
  )
  for (const tracks of [[], [-1], [2], [0.5]]) {
    assert.throws(() => createAudioExporter(source, { tracks }), /existing score track indices/)
  }
})

test('solo retains full-score pickup and grace timing plus channel/global events', () => {
  const sources = [
    String.raw`\tempo 80 \track "Long pickup" \ac :4 0.6 0.6 | :4 0.6 r r r |
\track "Short pickup" :4 3.3 | :4 5.3 r r r`,
    String.raw`\tempo 80 \track "Grace" :8 3.3{gr} 3.3 4.3 5.3 | :4 0.6 r r r |
\track "Plain" :4 3.3 r r r | :4 5.3 r r r`,
  ]
  for (const source of sources) {
    const full = midiForScore(source)
    const selected = midiForScore(source, { tracks: [1] })
    assert.equal(selected.midi.format, full.midi.format)
    assert.equal(selected.midi.division, full.midi.division)
    assert.equal(selected.midi.tickShift, full.midi.tickShift)
    const grid = value => value.generator.tickLookup.masterBars.map(bar =>
      [bar.start, bar.end, bar.masterBar.index, bar.tempoChanges])
    assert.deepEqual(grid(selected), grid(full))
    // Every retained event must keep its full-score order and original tick,
    // including the unselected track 0's global end/tempo and channel state.
    let cursor = 0
    for (const event of selected.midi.events) {
      while (cursor < full.midi.events.length
        && JSON.stringify(full.midi.events[cursor]) !== JSON.stringify(event)) cursor++
      assert.ok(cursor < full.midi.events.length)
      cursor++
    }
    const selectedNotes = selected.midi.events.filter(event =>
      event.type === midi.MidiEventType.NoteOn || event.type === midi.MidiEventType.NoteOff)
    assert.ok(selectedNotes.length > 0)
    assert.ok(selectedNotes.every(event => event.track === 1))
    const globalTypes = new Set([midi.MidiEventType.TimeSignature, midi.MidiEventType.TempoChange,
      midi.MidiEventType.EndOfTrack, midi.MidiEventType.ProgramChange, midi.MidiEventType.ControlChange])
    const channelAndGlobal = events => events.filter(event => globalTypes.has(event.type))
    assert.deepEqual(channelAndGlobal(selected.midi.events), channelAndGlobal(full.midi.events))
  }
})
