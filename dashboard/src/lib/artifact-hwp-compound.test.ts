import { expect, it, vi } from 'vitest'
import * as CFB from 'cfb'
import { readHwpCompoundStreams } from './artifact-hwp-compound'
import { validateHwpCompoundGraph, type CompoundEntry, type CompoundLayout } from './artifact-hwp-compound-graph'
import { writeHwpTestCompound, writeDeepHwpTestCompound } from './artifact-hwp-test-fixture'
import { officeImportLimits } from './artifact-office-xml'

const end = 0xfffffffe
const payload = (size: number, offset = 0) => Uint8Array.from({ length: size }, (_, index) => (index + offset) % 251)
function fixture() {
  const expected = new Map([['largeA', payload(8192)], ['largeB', payload(4099, 7)], ['smallA', payload(1049, 3)],
    ['smallB', payload(707, 13)], ['folder/data', payload(71, 23)], ['folder/한글😀', payload(19)], ['empty', new Uint8Array()]])
  const data = writeHwpTestCompound(expected)
  return { data, expected, layout: validateHwpCompoundGraph(data) }
}
function entry(data: Uint8Array, layout: CompoundLayout, name: string): CompoundEntry {
  const decoder = new TextDecoder('utf-16le', { fatal: true, ignoreBOM: true })
  const found = layout.entries.find(item => decoder.decode(data.subarray(item.name.offset, item.name.offset + item.name.bytes)) === name)
  if (!found) throw new Error(`Missing fixture entry ${name}`)
  return found
}
function setName(data: Uint8Array, offset: number, name: string) {
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength)
  data.fill(0, offset, offset + 64)
  for (let index = 0; index < name.length; index++) view.setUint16(offset + index * 2, name.charCodeAt(index), true)
  view.setUint16(offset + 64, (name.length + 1) * 2, true)
}
function reverseFatChain(data: Uint8Array, layout: CompoundLayout, chain: readonly number[], directoryOffset: number) {
  const original = data.slice(), reversed = [...chain].reverse(), view = new DataView(data.buffer)
  const words = layout.sectorBytes / 4
  for (let index = 0; index < chain.length; index++) {
    const from = (chain[index]! + 1) * layout.sectorBytes, to = (reversed[index]! + 1) * layout.sectorBytes
    data.set(original.subarray(from, from + layout.sectorBytes), to)
    const fat = view.getUint32(76 + Math.floor(reversed[index]! / words) * 4, true)
    view.setUint32((fat + 1) * layout.sectorBytes + reversed[index]! % words * 4, reversed[index + 1] ?? end, true)
  }
  view.setUint32(directoryOffset + 116, reversed[0]!, true)
}
function expectPayloads(data: Uint8Array, expected: ReadonlyMap<string, Uint8Array>) {
  const result = readHwpCompoundStreams(data, 'fixture')
  for (const [name, bytes] of expected) {
    expect(result.get(name)).toEqual(bytes)
    expect(result.get(name)!.buffer).not.toBe(data.buffer)
    expect('l' in result.get(name)!).toBe(false)
  }
  return result
}

it('reads exact nested Unicode paths, empty streams, and independently written bytes', () => {
  const { data, expected } = fixture(), before = data.slice(), actual = expectPayloads(data, expected)
  const independent = CFB.read(data, { type: 'buffer' }), prefix = independent.FullPaths[0]!
  const oracle = new Map(independent.FileIndex.flatMap((item, index) => item.type === 2
    ? [[independent.FullPaths[index]!.slice(prefix.length), item.size === 0 ? new Uint8Array() : Uint8Array.from(item.content)] as const] : []))
  expect(new Map(actual)).toEqual(oracle); expect(data).toEqual(before)
  const backing = new Uint8Array(data.length + 17); backing.set(data, 9)
  expectPayloads(backing.subarray(9, data.length + 9), expected)
})

it('reads a valid reverse FAT chain without copying suffixes or sharing input memory', () => {
  const { data, expected, layout } = fixture(), large = entry(data, layout, 'largeA')
  if (large.kind !== 'stream') throw new Error('Missing large stream')
  reverseFatChain(data, layout, large.sectors, large.name.offset)
  const validated = validateHwpCompoundGraph(data), set = vi.spyOn(Uint8Array.prototype, 'set')
  let copied = 0
  try {
    const result = readHwpCompoundStreams(data, 'reverse FAT')
    copied = set.mock.calls.reduce((bytes, [source]) => bytes + source.length, 0)
    for (const [name, bytes] of expected) expect(result.get(name)).toEqual(bytes)
  } finally { set.mockRestore() }
  expect(copied).toBe(validated.entries.reduce((bytes, item) => bytes + (item.kind === 'stream' ? item.size : 0), 0))
})

it('maps mini sectors directly through a valid reverse root mini-stream FAT chain', () => {
  const { data, expected, layout } = fixture()
  expect(layout.miniStreamSectors.length).toBeGreaterThan(1)
  reverseFatChain(data, layout, layout.miniStreamSectors, layout.rootName.offset)
  expectPayloads(data, expected)
})

it('reads a valid reverse MiniFAT chain across root physical-sector boundaries', () => {
  const { data, expected, layout } = fixture(), small = entry(data, layout, 'smallA'), original = data.slice(), view = new DataView(data.buffer)
  if (small.kind !== 'stream' || small.allocation !== 'mini') throw new Error('Missing mini stream')
  const reversed = [...small.sectors].reverse(), miniFat = (view.getUint32(60, true) + 1) * layout.sectorBytes
  const physical = (id: number) => (layout.miniStreamSectors[Math.floor(id * layout.miniSectorBytes / layout.sectorBytes)]! + 1) * layout.sectorBytes
    + id * layout.miniSectorBytes % layout.sectorBytes
  for (let index = 0; index < small.sectors.length; index++) {
    data.set(original.subarray(physical(small.sectors[index]!), physical(small.sectors[index]!) + layout.miniSectorBytes), physical(reversed[index]!))
    view.setUint32(miniFat + reversed[index]! * 4, reversed[index + 1] ?? end, true)
  }
  view.setUint32(small.name.offset + 116, reversed[0]!, true)
  expectPayloads(data, expected)
})

it('rejects a partial mini sector in the middle while accepting the same partial sector at the end', () => {
  const payload = Uint8Array.from({ length: 128 }, (_, index) => index + 1)
  const data = writeHwpTestCompound([['payload123', payload]]), layout = validateHwpCompoundGraph(data)
  const item = entry(data, layout, 'payload123'), view = new DataView(data.buffer)
  if (item.kind !== 'stream') throw new Error('Missing fixture stream')
  expect(item.sectors).toHaveLength(2)
  const first = item.sectors[0]!, last = item.sectors[1]!, miniFat = (view.getUint32(60, true) + 1) * layout.sectorBytes
  view.setUint32(layout.rootName.offset + 120, last * layout.miniSectorBytes + 32, true)
  view.setUint32(item.name.offset + 120, 96, true)
  expect(readHwpCompoundStreams(data, 'last partial').get('payload123')).toEqual(payload.subarray(0, 96))
  view.setUint32(item.name.offset + 116, last, true)
  view.setUint32(miniFat + last * 4, first, true); view.setUint32(miniFat + first * 4, end, true)
  expect(() => readHwpCompoundStreams(data, 'middle partial')).toThrow('stream 크기와 chain 길이')
})

it('copies only declared bytes from an overlong chain, but validates its complete unused tail', () => {
  const { data, layout, expected } = fixture(), item = entry(data, layout, 'largeA'), view = new DataView(data.buffer)
  if (item.kind !== 'stream') throw new Error('Missing fixture stream')
  view.setUint32(item.name.offset + 120, 4096, true)
  expect(readHwpCompoundStreams(data, 'unused FAT tail').get('largeA')).toEqual(expected.get('largeA')!.subarray(0, 4096))
  const last = item.sectors.at(-1)!, fat = view.getUint32(76, true)
  view.setUint32((fat + 1) * layout.sectorBytes + last * 4, last, true)
  expect(() => readHwpCompoundStreams(data, 'bad unused FAT tail')).toThrow('FAT 순환')
})

it('checks the entire stream budget before allocating logical stream buffers', () => {
  const data = writeHwpTestCompound([['large', new Uint8Array(officeImportLimits.partBytes + 1)]]), set = vi.spyOn(Uint8Array.prototype, 'set')
  try {
    expect(() => readHwpCompoundStreams(data, 'large part')).toThrow('가져오기 한도')
    expect(set).not.toHaveBeenCalled()
  } finally { set.mockRestore() }
  expect(() => readHwpCompoundStreams(new Uint8Array(officeImportLimits.inputBytes + 1), 'large input')).toThrow('32 MiB')
})

it('rejects malformed UTF-16 instead of replacing directory-name characters', () => {
  for (const bad of [String.fromCharCode(0xd800), String.fromCharCode(0xdc00)]) {
    const { data, layout } = fixture(); setName(data, entry(data, layout, 'largeA').name.offset, bad)
    expect(() => readHwpCompoundStreams(data, 'UTF-16')).toThrow()
  }
})

for (const name of ['', '.', '..', 'a/b', 'a\\b', 'a:b', 'a!b', 'a\u0000b']) it(`rejects illegal path component ${JSON.stringify(name)}`, () => {
  const { data, layout } = fixture(); setName(data, entry(data, layout, 'largeA').name.offset, name)
  expect(() => readHwpCompoundStreams(data, 'path')).toThrow('CFB 경로')
})

it('rejects case-insensitive collisions in one storage, while preserving names in different storages', () => {
  const { data, layout } = fixture(); setName(data, entry(data, layout, 'largeB').name.offset, 'LARGEA')
  expect(() => readHwpCompoundStreams(data, 'collision')).toThrow('CFB 경로가 겹칩니다')
  const other = fixture(); setName(other.data, entry(other.data, other.layout, 'smallB').name.offset, 'data')
  const streams = readHwpCompoundStreams(other.data, 'different parent')
  expect(streams.get('data')).toEqual(other.expected.get('smallB')); expect(streams.get('folder/data')).toEqual(other.expected.get('folder/data'))
})

it('validates root UTF-16 and preserves leading BOM characters in other names', () => {
  const { data, layout } = fixture(); setName(data, layout.rootName.offset, String.fromCharCode(0xd800))
  expect(() => readHwpCompoundStreams(data, 'root')).toThrow()
  const valid = fixture(); setName(valid.data, entry(valid.data, valid.layout, 'smallB').name.offset, '\uFEFFdata')
  expect(readHwpCompoundStreams(valid.data, 'BOM').get('\uFEFFdata')).toEqual(valid.expected.get('smallB'))
})

for (const [storage, stream] of [['a', 'b'], ['가', '나'], ['😀', '😃']] as const) {
  it(`counts ${storage}/${stream} fullpath UTF-16 allocation at the aggregate limit before joining paths`, () => {
    // Each depth contributes one empty-stream key: storage/.../stream.
    const keyBytes = (levels: number) => 2 * (levels * stream.length + (storage.length + 1) * levels * (levels - 1) / 2)
    const payloadKeyBytes = 'payload'.length * 2
    let levels = Math.floor(Math.sqrt(officeImportLimits.totalBytes / (storage.length + 1)))
    while (officeImportLimits.totalBytes - keyBytes(levels) - payloadKeyBytes < 4096) levels--
    const payloadBytes = officeImportLimits.totalBytes - keyBytes(levels) - payloadKeyBytes
    const data = writeDeepHwpTestCompound(storage, stream, levels, payloadBytes), layout = validateHwpCompoundGraph(data)
    expect(keyBytes(levels) + payloadBytes + payloadKeyBytes).toBe(officeImportLimits.totalBytes)
    expect(readHwpCompoundStreams(data, 'exact aggregate limit').get('payload')!.length).toBe(payloadBytes)
    const payload = entry(data, layout, 'payload'), view = new DataView(data.buffer)
    view.setUint32(payload.name.offset + 120, payloadBytes + 1, true)
    const join = vi.spyOn(Array.prototype, 'join'); let error: unknown, joins = -1
    try { readHwpCompoundStreams(data, 'one byte over aggregate limit') } catch (caught) { error = caught }
    finally { joins = join.mock.calls.length; join.mockRestore() }
    if (!(error instanceof Error)) throw new Error('Expected the aggregate allocation limit to reject this fixture.')
    expect(error.message).toContain('가져오기 한도'); expect(joins).toBe(0)
  })
}
