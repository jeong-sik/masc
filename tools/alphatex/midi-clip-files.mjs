import { open, link, unlink } from 'node:fs/promises'
import { resolve, dirname, join, basename } from 'node:path'
import { randomUUID } from 'node:crypto'
import { midiClipChunks } from './midi-clip-source.mjs'

// Exclusive publication: cancel/failure never leaves a playable partial file,
// and a racing writer keeps its own path. Long clock gaps stream with backpressure.
export async function exportMidiClip(path, document, { signal } = {}) {
  path = resolve(path)
  const temporary = join(dirname(path), `.${basename(path)}.${randomUUID()}.part`)
  signal?.throwIfAborted()
  const file = await open(temporary, 'wx', 0o600)
  try {
    for (const bytes of midiClipChunks(document)) {
      signal?.throwIfAborted()
      let offset = 0
      while (offset < bytes.length) {
        signal?.throwIfAborted()
        const { bytesWritten } = await file.write(bytes, offset, bytes.length - offset)
        if (!bytesWritten) throw new Error('MIDI Clip export made no progress')
        offset += bytesWritten
      }
    }
    await file.sync(); await file.close(); signal?.throwIfAborted()
    await link(temporary, path)
    const directory = await open(dirname(path), 'r')
    try { await directory.sync() } finally { await directory.close() }
    return path
  } finally {
    await file.close()
    await unlink(temporary)
  }
}
