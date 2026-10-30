import { open } from 'node:fs/promises'

// Inspect the RIFF structure without loading recorded samples into memory.
// Chunk lengths exclude their header and WORD padding (Microsoft RIFF contract).
// This reader deliberately accepts uncompressed PCM/IEEE float WAVE only.
export async function readWaveMetadata(path, expected = {}, { signal } = {}) {
  signal?.throwIfAborted()
  const file = await open(path, 'r')
  const read = async (position, length) => {
    const bytes = Buffer.alloc(length)
    let filled = 0
    while (filled < length) {
      signal?.throwIfAborted()
      const { bytesRead } = await file.read(bytes, filled, length - filled, position + filled)
      signal?.throwIfAborted()
      if (!bytesRead) throw new Error('Truncated WAV chunk')
      filled += bytesRead
    }
    return bytes
  }
  try {
    signal?.throwIfAborted()
    const { size } = await file.stat()
    signal?.throwIfAborted()
    if (size < 12) throw new Error('Truncated WAV header')
    const header = await read(0, 12)
    if (header.toString('ascii', 0, 4) !== 'RIFF' || header.toString('ascii', 8, 12) !== 'WAVE') {
      throw new Error('Unsupported WAV container; expected RIFF/WAVE')
    }
    const end = header.readUInt32LE(4) + 8
    if (end !== size || end < 12) throw new Error('WAV RIFF size does not match file size')
    let format = null, data = null
    for (let offset = 12; offset < end;) {
      signal?.throwIfAborted()
      if (end - offset < 8) throw new Error('Truncated WAV chunk header')
      const chunk = await read(offset, 8)
      const kind = chunk.toString('ascii', 0, 4)
      const length = chunk.readUInt32LE(4)
      const payload = offset + 8
      const next = payload + length + (length & 1)
      if (next > end) throw new Error('WAV chunk exceeds RIFF bounds')
      if (kind === 'fmt ') {
        if (format) throw new Error('Duplicate WAV format chunk')
        if (length < 16) throw new Error('Truncated WAV format')
        const bytes = await read(payload, Math.min(length, 40))
        let tag = bytes.readUInt16LE(0)
        const channels = bytes.readUInt16LE(2)
        const sampleRate = bytes.readUInt32LE(4)
        const byteRate = bytes.readUInt32LE(8)
        const blockAlign = bytes.readUInt16LE(12)
        const bitsPerSample = bytes.readUInt16LE(14)
        let validBits = bitsPerSample
        if (length !== 16 && (length < 18 || bytes.readUInt16LE(16) > length - 18)) throw new Error('Invalid WAV format extension')
        if (tag === 0xfffe) {
          if (length < 40 || bytes.readUInt16LE(16) < 22) throw new Error('Truncated extensible WAV format')
          // Standard PCM/IEEE float SubFormat GUID: {tag}-0000-0010-8000-00aa00389b71.
          const guid = bytes.subarray(24, 40)
          if (guid.subarray(4).toString('hex') !== '00001000800000aa00389b71') throw new Error('Unsupported WAV subformat GUID')
          tag = guid.readUInt32LE(0)
          validBits = bytes.readUInt16LE(18)
        }
        if (tag !== 1 && tag !== 3) throw new Error('Unsupported WAV sample encoding')
        if (!channels || !sampleRate || !bitsPerSample || bitsPerSample % 8
          || !validBits || validBits > bitsPerSample || blockAlign !== channels * bitsPerSample / 8
          || byteRate !== sampleRate * blockAlign || (tag === 3 && ![32, 64].includes(bitsPerSample))) {
          throw new Error('Inconsistent WAV sample format')
        }
        format = { encoding: tag === 1 ? 'pcm' : 'float', channels, sampleRate, bitsPerSample, validBits, blockAlign }
      } else if (kind === 'data') {
        if (data) throw new Error('Duplicate WAV data chunk')
        data = { offset: payload, bytes: length }
      }
      offset = next
    }
    if (!format || !data) throw new Error('Missing WAV format or data chunk')
    if (data.bytes % format.blockAlign) throw new Error('Incomplete WAV sample frame')
    const frames = BigInt(data.bytes / format.blockAlign)
    if ((expected.channels !== undefined && expected.channels !== format.channels)
      || (expected.sampleRate !== undefined && expected.sampleRate !== format.sampleRate)
      || (expected.frames !== undefined && BigInt(expected.frames) !== frames)) {
      throw new Error('WAV metadata does not match capture manifest')
    }
    return { ...format, frames, dataOffset: data.offset, dataBytes: data.bytes }
  } finally { await file.close() }
}
