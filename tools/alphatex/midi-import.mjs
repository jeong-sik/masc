import { importMidiSource } from './midi-source.mjs'
import { importMidiClip } from './midi-clip-source.mjs'

// The binary envelope selects its format; a suffix never changes its meaning.
export function importMidiDocument(bytes, options) {
  const data = Buffer.from(bytes)
  return data.subarray(0, 8).equals(Buffer.from('SMF2CLIP'))
    ? importMidiClip(data, options) : importMidiSource(data, options)
}
