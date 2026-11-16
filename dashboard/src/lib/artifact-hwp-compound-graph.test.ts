import { expect, it } from 'vitest'
import * as CFB from 'cfb'
import JSZip from 'jszip'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { validateHwpCompoundGraph } from './artifact-hwp-compound-graph'
import { writeHwpTestCompound } from './artifact-hwp-test-fixture'

const free = 0xffffffff, end = 0xfffffffe, fatMarker = 0xfffffffd, sectorBytes = 512, directoryBytes = 128
type Fixture = ReturnType<typeof fixture>
function fixture() {
  const data = writeHwpTestCompound([['largeA', new Uint8Array(8192).fill(1)], ['largeB', new Uint8Array(8192).fill(2)],
    ['smallA', new Uint8Array(128)], ['smallB', new Uint8Array(128)], ['folder/data', new Uint8Array(64)], ['empty', new Uint8Array()]])
  const view = new DataView(data.buffer), parsed = CFB.read(data, { type: 'buffer' })
  const fat = (id: number) => (view.getUint32(76 + Math.floor(id / 128) * 4, true) + 1) * sectorBytes + id % 128 * 4
  const entry = (name: string) => {
    const id = parsed.FileIndex.findIndex(item => item.name === name)
    if (id < 0) throw new Error(`Missing fixture entry ${name}`)
    let sector = view.getUint32(48, true)
    for (let block = 0; block < Math.floor(id / 4); block++) sector = view.getUint32(fat(sector), true)
    return { id, at: (sector + 1) * sectorBytes + id % 4 * directoryBytes, source: parsed.FileIndex[id]! }
  }
  return { data, view, parsed, fat, entry, count: data.length / sectorBytes - 1 }
}
function reject(change: (input: Fixture) => void, message?: string) {
  const input = fixture(); change(input)
  expect(() => validateHwpCompoundGraph(input.data)).toThrow(message)
}

it('accepts FAT/MiniFAT, nested storage, and empty streams without changing bytes', () => {
  const { data } = fixture(), before = data.slice()
  expect(() => validateHwpCompoundGraph(data)).not.toThrow(); expect(data).toEqual(before)
  const backing = new Uint8Array(data.length + 19); backing.set(data, 11)
  expect(() => validateHwpCompoundGraph(backing.subarray(11, 11 + data.length))).not.toThrow()
})

it('rejects the independently reported two-sector FAT cycle reached from a second stream', () => {
  // Review reproducer: FAT[a] = a+1, FAT[a+1] = a, largeB.start = a+1.
  // Never pass these corrupted bytes to CFB.read, whose get_sector_list hangs.
  reject(input => {
    const a = input.entry('largeA').source.start
    input.view.setUint32(input.fat(a), a + 1, true); input.view.setUint32(input.fat(a + 1), a, true)
    input.view.setUint32(input.entry('largeB').at + 116, a + 1, true)
  }, 'FAT 순환')
})

it('checks an unreachable FAT cycle rather than only directory-referenced chains', () => {
  const input = fixture(), data = new Uint8Array(input.data.length + sectorBytes); data.set(input.data)
  new DataView(data.buffer).setUint32(input.fat(input.count), input.count, true)
  expect(() => validateHwpCompoundGraph(data)).toThrow('FAT 순환')
})

it('rejects FAT links outside the physical file and inconsistent metadata markers', () => {
  reject(input => input.view.setUint32(input.fat(input.entry('largeA').source.start), input.count, true), 'FAT sector 참조')
  reject(input => input.view.setUint32(input.fat(0), end, true), 'FAT sector 표식')
  reject(input => input.view.setUint32(input.fat(input.count), end, true), 'FAT 파일 밖 allocation')
})

it('rejects streams with out-of-file starts, shared sectors, and undersized chains', () => {
  reject(input => input.view.setUint32(input.entry('largeA').at + 116, input.count, true), 'stream FAT')
  reject(input => input.view.setUint32(input.entry('largeB').at + 116, input.entry('largeA').source.start, true), '중복 소속')
  reject(input => input.view.setUint32(input.entry('largeA').at + 120, 12288, true), 'stream 크기와 chain 길이')
  reject(input => input.view.setUint32(input.entry('largeA').at + 120, input.data.length + 1, true), 'stream 크기가 물리 파일')
})

it('rejects a stream chain ending in FREESECT and unclaimed allocated sectors', () => {
  reject(input => input.view.setUint32(input.fat(input.entry('largeA').source.start), free, true), 'stream FAT')
  reject(input => input.view.setUint32(input.entry('largeA').at + 116, end, true), 'stream 크기와 chain 길이')
  reject(input => { input.view.setUint32(input.entry('largeA').at + 116, end, true); input.view.setUint32(input.entry('largeA').at + 120, 0, true) }, 'FAT active orphan')
})

it('rejects MiniFAT cycles, out-of-mini-stream references, and overlapping streams', () => {
  reject(input => {
    const mini = (input.view.getUint32(60, true) + 1) * sectorBytes, first = input.entry('smallA').source.start
    input.view.setUint32(mini + first * 4, first + 1, true); input.view.setUint32(mini + (first + 1) * 4, first, true)
  }, 'MiniFAT 순환')
  reject(input => {
    const mini = (input.view.getUint32(60, true) + 1) * sectorBytes, count = Math.ceil(input.entry('Root Entry').source.size / 64)
    input.view.setUint32(mini + input.entry('smallA').source.start * 4, count, true)
  }, 'MiniFAT 범위')
  reject(input => input.view.setUint32(input.entry('smallB').at + 116, input.entry('smallA').source.start, true), '중복 소속')
})

it('checks MiniFAT chain counts and each mini stream size against its physical backing', () => {
  reject(input => input.view.setUint32(64, input.view.getUint32(64, true) + 1, true), 'MiniFAT sector 개수')
  reject(input => input.view.setUint32(input.entry('smallA').at + 120, 4000, true), 'stream 크기와 chain 길이')
  reject(input => input.view.setUint32(input.entry('smallA').at + 116, 0xfffffffa, true), 'mini stream')
  reject(input => input.view.setUint32(input.entry('Root Entry').at + 120, input.entry('Root Entry').source.size - 63, true), 'stream 크기와 chain 길이')
  reject(input => { input.view.setUint32(input.entry('smallA').at + 116, end, true); input.view.setUint32(input.entry('smallA').at + 120, 0, true) }, 'MiniFAT active orphan')
  reject(input => {
    const miniFat = (input.view.getUint32(60, true) + 1) * sectorBytes, count = Math.ceil(input.entry('Root Entry').source.size / 64)
    input.view.setUint32(miniFat + count * 4, end, true)
  }, 'MiniFAT 파일 밖 allocation')
})

it('rejects directory sibling/child cycles and references to another entry twice', () => {
  reject(input => input.view.setUint32(input.entry('largeA').at + 68, input.entry('largeA').id, true), 'directory 범위·순환·중복 소속')
  reject(input => input.view.setUint32(input.entry('folder').at + 76, input.entry('folder').id, true), 'directory 범위·순환·중복 소속')
  reject(input => input.view.setUint32(input.entry('largeA').at + 68, input.entry('smallA').id, true), 'directory 범위·순환·중복 소속')
})

it('rejects directory active orphans, root siblings, and out-of-range IDs', () => {
  reject(input => input.view.setUint32(input.entry('Root Entry').at + 76, free, true), 'directory active orphan')
  reject(input => input.view.setUint32(input.entry('Root Entry').at + 68, input.entry('largeA').id, true), 'directory root')
  reject(input => input.view.setUint32(input.entry('folder').at + 76, input.parsed.FileIndex.length, true), 'directory 범위')
  reject(input => input.view.setUint32(input.entry('largeA').at + 76, input.entry('smallA').id, true), 'stream의 child')
})

it('rejects active data in storage/unallocated entries before cfb can interpret them as streams', () => {
  reject(input => input.view.setUint32(input.entry('folder').at + 120, 8192, true), 'storage stream 필드')
  reject(input => {
    const unused = input.parsed.FileIndex.findIndex(entry => entry.type === 0), blocks = Math.floor(unused / 4)
    let sector = input.view.getUint32(48, true)
    for (let block = 0; block < blocks; block++) sector = input.view.getUint32(input.fat(sector), true)
    input.view.setUint32((sector + 1) * sectorBytes + unused % 4 * directoryBytes + 116, 1, true)
  }, 'directory entry 필드')
})

it('rejects header sector/count mismatches and truncated physical sectors', () => {
  reject(input => input.view.setUint16(30, 12, true), 'header 필드')
  reject(input => input.view.setUint32(72, input.count + 1, true), 'allocation table 개수')
  reject(input => input.view.setUint32(76, input.count, true), 'DIFAT의 FAT 소속')
  reject(input => input.view.setUint32(80, input.view.getUint32(76, true), true), 'DIFAT의 FAT 소속')
  const input = fixture()
  for (const bytes of [input.data.subarray(0, 100), input.data.subarray(0, input.data.length - 1)]) expect(() => validateHwpCompoundGraph(bytes)).toThrow()
})

it('accepts a real DIFAT chain and rejects its cycle or invalid last terminator', () => {
  const data = writeHwpTestCompound([['large', new Uint8Array(8 * 1024 * 1024)]]), view = new DataView(data.buffer)
  expect(view.getUint32(72, true)).toBeGreaterThan(0)
  expect(() => validateHwpCompoundGraph(data)).not.toThrow()
  const difat = view.getUint32(68, true), next = (difat + 2) * sectorBytes - 4
  view.setUint32(next, difat, true)
  expect(() => validateHwpCompoundGraph(data)).toThrow('DIFAT 길이')
  view.setUint32(72, view.getUint32(72, true) + 1, true)
  expect(() => validateHwpCompoundGraph(data)).toThrow('DIFAT 범위·순환')
})

function version4(): Uint8Array {
  const sector = 4096, data = new Uint8Array(5 * sector), view = new DataView(data.buffer)
  data.set([0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]); view.setUint16(24, 0x3e, true); view.setUint16(26, 4, true)
  for (const [at, value] of [[28, 0xfffe], [30, 12], [32, 6]]) view.setUint16(at!, value!, true)
  for (const [at, value] of [[40, 1], [44, 1], [48, 1], [56, 4096], [60, end], [68, end]]) view.setUint32(at!, value!, true)
  for (let at = 76; at < 512; at += 4) view.setUint32(at, free, true)
  view.setUint32(76, 0, true)
  for (let at = sector; at < 2 * sector; at += 4) view.setUint32(at, free, true)
  for (const [id, next] of [fatMarker, end, 3, end].entries()) view.setUint32(sector + id * 4, next, true)
  for (let at = 2 * sector; at < 3 * sector; at += directoryBytes) for (const field of [68, 72, 76]) view.setUint32(at + field, free, true)
  for (const [id, name, type, start, size] of [[0, 'Root Entry', 5, end, 0], [1, 'payload', 2, 2, 8192]] as const) {
    const at = 2 * sector + id * directoryBytes
    Array.from(name).forEach((letter, index) => view.setUint16(at + index * 2, letter.charCodeAt(0), true))
    view.setUint16(at + 64, (name.length + 1) * 2, true); data[at + 66] = type; data[at + 67] = 1
    view.setUint32(at + 116, start, true); view.setBigUint64(at + 120, BigInt(size), true)
  }
  view.setUint32(2 * sector + 76, 1, true)
  return data
}
it('validates 4096-byte v4 sectors, directory counts, and full 64-bit stream sizes', () => {
  const data = version4(), view = new DataView(data.buffer)
  expect(() => validateHwpCompoundGraph(data)).not.toThrow()
  view.setUint32(40, 2, true); expect(() => validateHwpCompoundGraph(data)).toThrow('directory sector 개수'); view.setUint32(40, 1, true)
  view.setUint32(2 * 4096 + directoryBytes + 124, 1, true)
  expect(() => validateHwpCompoundGraph(data)).toThrow('stream 크기가 물리 파일')
})
it('ignores v3 stream-size high DWORDs as MS-CFB requires for older producers', () => {
  const input = fixture(); input.view.setUint32(input.entry('largeA').at + 124, 0xffffffff, true)
  expect(() => validateHwpCompoundGraph(input.data)).not.toThrow()
})

const publicRoot = process.env.MASC_HWP_PUBLIC_SAMPLES, exportsRoot = process.env.MASC_HWP_CORE_EXPORTS
const publicCases = [['column', '세로막대형/묶은세로막대형'], ['bar', '가로막대형/묶은가로막대형'], ['line', '라인/꺽은선형'], ['pie', '원형/2차원원형']] as const
for (const [kind, name] of publicCases) {
  (publicRoot ? it : it.skip)(`validates public ${kind} HWP physical graphs`, () => { expect(() => validateHwpCompoundGraph(readFileSync(join(publicRoot!, `${name}.hwp`)))).not.toThrow() })
  ;(exportsRoot ? it : it.skip)(`validates actual Core 0.9.0 ${kind} OLE physical graphs`, async () => {
    const zip = await JSZip.loadAsync(readFileSync(join(exportsRoot!, `${kind}-core-0.9.0.hwpx`))), bytes = await zip.file('BinData/image1.OLE')!.async('uint8array')
    expect(new DataView(bytes.buffer, bytes.byteOffset, 4).getUint32(0, true)).toBe(bytes.length - 4)
    expect(() => validateHwpCompoundGraph(bytes.subarray(4))).not.toThrow()
  })
}
