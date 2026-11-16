import * as CFB from 'cfb'

/** Write fixture allocation padding and empty starts per MS-CFB; never repair production input. */
export function writeHwpTestCompound(entries: Iterable<readonly [string, Uint8Array]>): Uint8Array {
  const container = CFB.utils.cfb_new()
  for (const [name, bytes] of entries) CFB.utils.cfb_add(container, name, bytes)
  const encoded: unknown = CFB.write(container, { type: 'buffer', fileType: 'cfb' })
  if (!(encoded instanceof Uint8Array)) throw new Error('Test CFB writer did not return bytes.')
  const data = Uint8Array.from(encoded), view = new DataView(data.buffer)
  const sectorBytes = 2 ** view.getUint16(30, true), count = data.byteLength / sectorBytes - 1, words = sectorBytes / 4
  const free = 0xffffffff, end = 0xfffffffe, fats: number[] = []
  const add = (offset: number, length: number) => {
    for (let index = 0; index < length; index++) { const id = view.getUint32(offset + index * 4, true); if (id !== free) fats.push(id) }
  }
  add(76, 109)
  let difat = view.getUint32(68, true)
  for (let index = 0; index < view.getUint32(72, true); index++) {
    add((difat + 1) * sectorBytes, words - 1)
    difat = view.getUint32((difat + 2) * sectorBytes - 4, true)
  }
  // cfb@1.2.2 writes ENDOFCHAIN here; MS-CFB §2.3 requires FREESECT past EOF.
  for (let table = 0; table < fats.length; table++) for (let word = 0; word < words; word++) {
    if (table * words + word >= count) view.setUint32((fats[table]! + 1) * sectorBytes + word * 4, free, true)
  }
  const nextSector = (id: number) => view.getUint32((fats[Math.floor(id / words)]! + 1) * sectorBytes + id % words * 4, true)
  const root = (view.getUint32(48, true) + 1) * sectorBytes, miniCount = Math.ceil(view.getUint32(root + 120, true) / 64)
  let miniFat = view.getUint32(60, true)
  for (let block = 0; block < view.getUint32(64, true); block++) {
    for (let word = 0; word < words; word++) if (block * words + word >= miniCount) view.setUint32((miniFat + 1) * sectorBytes + word * 4, free, true)
    miniFat = nextSector(miniFat)
  }
  let directory = view.getUint32(48, true)
  for (let traversed = 0; directory !== end && traversed < count; traversed++) {
    const offset = (directory + 1) * sectorBytes
    for (let within = 0; within < sectorBytes; within += 128) {
      if (data[offset + within + 66] === 2 && view.getUint32(offset + within + 120, true) === 0) {
        view.setUint32(offset + within + 116, end, true)
      }
    }
    directory = nextSector(directory)
  }
  return data
}

/** Independently authored CFB: repeated storage/empty-stream siblings, plus one FAT payload. */
export function writeDeepHwpTestCompound(storageName: string, streamName: string, levels: number, payloadBytes: number): Uint8Array {
  const sectorBytes = 512, directoryBytes = 128, words = sectorBytes / 4, free = 0xffffffff, end = 0xfffffffe
  const directorySectors = Math.ceil((levels * 2 + 2) * directoryBytes / sectorBytes), payloadSectors = Math.ceil(payloadBytes / sectorBytes)
  const fatSectors = Math.ceil((directorySectors + payloadSectors) / (words - 1)), count = fatSectors + directorySectors + payloadSectors
  if (fatSectors > 109 || payloadBytes < 4096 || levels < 1) throw new Error('Deep fixture requires header DIFAT and a regular FAT payload.')
  const data = new Uint8Array((count + 1) * sectorBytes), view = new DataView(data.buffer), directory = fatSectors, payload = directory + directorySectors
  data.set([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1])
  for (const [at, value] of [[24, 0x3e], [26, 3], [28, 0xfffe], [30, 9], [32, 6]] as const) view.setUint16(at, value, true)
  for (const [at, value] of [[44, fatSectors], [48, directory], [56, 4096], [60, end], [68, end]] as const) view.setUint32(at, value, true)
  for (let index = 0; index < 109; index++) view.setUint32(76 + index * 4, index < fatSectors ? index : free, true)
  data.fill(255, sectorBytes, (fatSectors + 1) * sectorBytes)
  const fat = (id: number, next: number) => view.setUint32((Math.floor(id / words) + 1) * sectorBytes + id % words * 4, next, true)
  for (let id = 0; id < count; id++) fat(id, id < fatSectors ? 0xfffffffd
    : id === directory + directorySectors - 1 || id === count - 1 ? end : id + 1)
  const directoryAt = (id: number) => (directory + 1) * sectorBytes + id * directoryBytes
  for (let id = 0; id < directorySectors * sectorBytes / directoryBytes; id++) {
    for (const field of [68, 72, 76]) view.setUint32(directoryAt(id) + field, free, true)
  }
  const entry = (id: number, name: string, type: 1 | 2 | 5, start: number, size: number) => {
    const at = directoryAt(id)
    if (name.length > 31) throw new Error('Fixture name exceeds MS-CFB UTF-16 extent.')
    for (let index = 0; index < name.length; index++) view.setUint16(at + index * 2, name.charCodeAt(index), true)
    view.setUint16(at + 64, (name.length + 1) * 2, true); data[at + 66] = type; data[at + 67] = 1
    view.setUint32(at + 116, start, true); view.setUint32(at + 120, size, true)
  }
  entry(0, 'Root Entry', 5, end, 0); view.setUint32(directoryAt(0) + 76, 1, true)
  for (let index = 0; index < levels; index++) {
    const storage = index * 2 + 1, stream = storage + 1
    entry(storage, storageName, 1, 0, 0); entry(stream, streamName, 2, end, 0)
    view.setUint32(directoryAt(storage) + 72, stream, true)
    if (index + 1 < levels) view.setUint32(directoryAt(storage) + 76, storage + 2, true)
  }
  const payloadId = levels * 2 + 1
  entry(payloadId, 'payload', 2, payload, payloadBytes); view.setUint32(directoryAt(2) + 72, payloadId, true)
  for (let index = 0; index < payloadBytes; index++) data[(payload + 1) * sectorBytes + index] = index % 251
  return data
}
