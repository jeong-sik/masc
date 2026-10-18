import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { readWaveMetadata } from '../wave-file.mjs'

function chunk(kind, bytes) {
  const header = Buffer.alloc(8)
  header.write(kind); header.writeUInt32LE(bytes.length, 4)
  return Buffer.concat([header, bytes, Buffer.alloc(bytes.length & 1)])
}
function wave({ tag = 3, extensible = false, frames = 8, channels = 2, sampleRate = 48000 } = {}) {
  const format = Buffer.alloc(extensible ? 40 : 16)
  format.writeUInt16LE(extensible ? 0xfffe : tag)
  format.writeUInt16LE(channels, 2); format.writeUInt32LE(sampleRate, 4)
  format.writeUInt32LE(sampleRate * channels * 4, 8)
  format.writeUInt16LE(channels * 4, 12); format.writeUInt16LE(32, 14)
  if (extensible) {
    format.writeUInt16LE(22, 16); format.writeUInt16LE(32, 18)
    format.writeUInt32LE(tag, 24)
    Buffer.from('00001000800000aa00389b71', 'hex').copy(format, 28)
  }
  const body = Buffer.concat([Buffer.from('WAVE'), chunk('JUNK', Buffer.alloc(3)), chunk('fmt ', format), chunk('data', Buffer.alloc(frames * channels * 4))])
  const header = Buffer.alloc(8); header.write('RIFF'); header.writeUInt32LE(body.length, 4)
  return Buffer.concat([header, body])
}

test('recorded WAV metadata requires complete frames and the capture rate/channel/frame totals', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'masc-wave-read-'))
  const path = join(directory, 'audio.wav')
  try {
    for (const tag of [1, 3]) for (const extensible of [false, true]) {
      await writeFile(path, wave({ tag, extensible }))
      const info = await readWaveMetadata(path, { channels: 2, sampleRate: 48000, frames: 8n })
      assert.equal(info.encoding, tag === 1 ? 'pcm' : 'float')
      assert.equal(info.frames, 8n)
      assert.equal(info.dataBytes, 64)
      for (const expected of [{ channels: 1 }, { sampleRate: 44100 }, { frames: 9n }]) {
        await assert.rejects(readWaveMetadata(path, expected), /does not match capture/)
      }
    }
    const bytes = await readFile(path)
    await writeFile(path, bytes.subarray(0, -1))
    await assert.rejects(readWaveMetadata(path), /RIFF size/)
    const shortened = bytes.subarray(0, -1)
    shortened.writeUInt32LE(shortened.length - 8, 4)
    await writeFile(path, shortened)
    await assert.rejects(readWaveMetadata(path), /exceeds RIFF/)
    await rm(path)
    await assert.rejects(readWaveMetadata(path), { code: 'ENOENT' })
  } finally { await rm(directory, { recursive: true, force: true }) }
})

test('WAV corruption inside a valid outer RIFF cannot become a playable take', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'masc-wave-corrupt-'))
  const path = join(directory, 'audio.wav')
  try {
    const invalidGuid = wave({ extensible: true })
    invalidGuid[invalidGuid.indexOf(Buffer.from('fmt ')) + 8 + 28] = 1
    await writeFile(path, invalidGuid)
    await assert.rejects(readWaveMetadata(path), /Unsupported WAV subformat/)
    const partialFrame = wave()
    const offset = partialFrame.indexOf(Buffer.from('data'))
    partialFrame.writeUInt32LE(63, offset + 4) // final byte becomes required WORD padding
    await writeFile(path, partialFrame)
    await assert.rejects(readWaveMetadata(path), /Incomplete WAV sample frame/)
    await writeFile(path, wave({ tag: 6 }))
    await assert.rejects(readWaveMetadata(path), /Unsupported WAV sample encoding/)
  } finally { await rm(directory, { recursive: true, force: true }) }
})
