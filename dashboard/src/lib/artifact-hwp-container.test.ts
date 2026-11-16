import { expect, it } from 'vitest'
import { deflateSync, inflateSync } from 'fflate'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { readHwpCompound, preflightArtifactHwp } from './artifact-hwp-container'
import { officeImportLimits } from './artifact-office-xml'
import { hwpxTableLimits } from './artifact-hwpx-template'
import { writeHwpTestCompound as compound } from './artifact-hwp-test-fixture'

const encoder = new TextEncoder(), decoder = new TextDecoder(), paragraphHeader = new Uint8Array(24)
const id = { section: 0x73656364, columns: 0x636F6C64, table: 0x74626C20, graphic: 0x67736F20, ole: 0x246F6C65, picture: 0x24706963, unknown: 0x3F3F3F3F } as const
function bytes(...parts: readonly Uint8Array[]): Uint8Array {
  const output = new Uint8Array(parts.reduce((size, part) => size + part.byteLength, 0)); let offset = 0
  for (const part of parts) { output.set(part, offset); offset += part.byteLength }
  return output
}
function words(...values: number[]): Uint8Array { const data = new Uint8Array(values.length * 4), view = new DataView(data.buffer); values.forEach((value, index) => view.setUint32(index * 4, value, true)); return data }
function paragraph(count = 0): Uint8Array { const data = paragraphHeader.slice(); new DataView(data.buffer).setUint32(0, count, true); return data }
function controlText(control: number): Uint8Array {
  const data = new Uint8Array(18), view = new DataView(data.buffer); view.setUint16(0, 0xB, true); view.setUint32(2, control, true); view.setUint16(14, 0xB, true); view.setUint16(16, 13, true)
  return data
}
function record(tag: number, level: number, payload: Uint8Array): Uint8Array {
  return payload.byteLength >= 0xFFF ? bytes(words(tag | (level << 10) | 0xFFF00000, payload.byteLength), payload)
    : bytes(words(tag | (level << 10) | (payload.byteLength << 20)), payload)
}
function fileHeader(flags = 0): Uint8Array {
  const header = new Uint8Array(256); header.set(encoder.encode('HWP Document File')); header[35] = 5
  new DataView(header.buffer).setUint32(36, flags, true); return header
}
function documentProperties(sections = 1): Uint8Array {
  const properties = new Uint8Array(26); new DataView(properties.buffer).setUint16(0, sections, true)
  return record(16, 0, properties)
}
function binding(flags = 2, storageId = 1): Uint8Array {
  const data = new Uint8Array(4), view = new DataView(data.buffer); view.setUint16(0, flags, true); view.setUint16(2, storageId, true)
  return record(18, 1, data)
}
function source(options: { header?: Uint8Array; info?: Uint8Array; body?: Uint8Array; sections?: readonly string[]; binary?: readonly Uint8Array[] } = {}): Uint8Array {
  const header = options.header ?? fileHeader(), compressed = Boolean(header[36]! & 1), pack = (data: Uint8Array) => compressed ? deflateSync(data) : data
  return compound([['FileHeader', header], ['DocInfo', pack(options.info ?? documentProperties())],
    ...(options.sections ?? ['Section0']).map(name => [`BodyText/${name}`, pack(options.body ?? record(66, 0, paragraphHeader))] as const),
    ...(options.binary ?? []).map((data, index) => [`BinData/BIN${(index + 1).toString(16).toUpperCase().padStart(4, '0')}.OLE`, data] as const)])
}
function patchName(data: Uint8Array, before: string, after: string): Uint8Array {
  const output = data.slice(), view = new DataView(output.buffer), sectorSize = 2 ** view.getUint16(30, true), directory = (view.getUint32(48, true) + 1) * sectorSize
  for (let offset = directory; offset < directory + sectorSize; offset += 128) {
    const length = view.getUint16(offset + 64, true), name = new TextDecoder('utf-16le').decode(output.subarray(offset, offset + Math.max(0, length - 2)))
    if (name !== before) continue
    output.fill(0, offset, offset + 64)
    Array.from(after).forEach((character, index) => view.setUint16(offset + index * 2, character.charCodeAt(0), true))
    view.setUint16(offset + 64, (after.length + 1) * 2, true); return output
  }
  throw new Error('Fixture directory entry not found')
}

it('returns exact relative CFB stream paths without the root storage name', () => {
  const streams = readHwpCompound(compound([['OOXMLChartContents', encoder.encode('<chart/>')], ['nested/Contents', Uint8Array.of(1, 2)]]), 'fixture')
  expect(decoder.decode(streams.get('OOXMLChartContents'))).toBe('<chart/>'); expect(streams.get('nested/Contents')).toEqual(Uint8Array.of(1, 2))
  expect([...streams.keys()].some(path => path.startsWith('Root Entry/'))).toBe(false)
})
it('refuses ZIP bytes even though the CFB package also reads ZIP', () => { expect(() => readHwpCompound(Uint8Array.of(0x50, 0x4B, 3, 4), 'fixture')).toThrow() })
for (const name of ['../outside', '..\\outside', 'https:outside']) it(`refuses a CFB path ${name}`, () => {
  expect(() => readHwpCompound(patchName(compound([['safe', Uint8Array.of(1)]]), 'safe', name), 'fixture')).toThrow()
})
it('refuses duplicate CFB names including case-insensitive collisions', () => {
  const input = compound([['alpha', Uint8Array.of(1)], ['bravo', Uint8Array.of(2)]])
  expect(() => readHwpCompound(patchName(input, 'bravo', 'ALPHA'), 'fixture')).toThrow()
})
it('refuses a truncated CFB stream instead of supplying shorter bytes', () => {
  const input = compound([['large', new Uint8Array(8192)]]); expect(() => readHwpCompound(input.subarray(0, input.byteLength - 4096), 'fixture')).toThrow()
})
it('accepts plain and document-compressed record streams', () => {
  expect(() => preflightArtifactHwp(source())).not.toThrow(); expect(() => preflightArtifactHwp(source({ header: fileHeader(1) }))).not.toThrow()
})
it('resolves document, section and BinData paths with CFB case-insensitive identity', () => {
  const input = source({ info: bytes(documentProperties(), binding()), binary: [Uint8Array.of(1)] })
  const streams = readHwpCompound(input, 'case fixture')
  const renamed = compound([...streams].map(([path, data]) => [path.toLowerCase(), data] as const))
  expect(() => preflightArtifactHwp(renamed)).not.toThrow()
})
for (const flag of [2, 4, 16, 256, 1024, 8192]) it(`refuses protected FileHeader flag ${flag}`, () => { expect(() => preflightArtifactHwp(source({ header: fileHeader(flag) }))).toThrow() })
for (const fault of ['signature', 'version', 'length']) it(`refuses FileHeader ${fault}`, () => {
  let header = fileHeader()
  if (fault === 'signature') header[0] = 0
  if (fault === 'version') header[35] = 3
  if (fault === 'length') header = header.slice(0, -1)
  expect(() => preflightArtifactHwp(source({ header }))).toThrow()
})
it('accepts stored EncryptVersion 4 when the encryption flag is absent', () => {
  const header = fileHeader(); new DataView(header.buffer).setUint32(44, 4, true)
  expect(() => preflightArtifactHwp(source({ header }))).not.toThrow()
})
for (const sections of [[], ['Section1'], ['Section00'], ['Section0', 'Section2']]) it(`refuses missing or unordered section references ${sections.join(',')}`, () => {
  expect(() => preflightArtifactHwp(source({ info: documentProperties(Math.max(1, sections.length)), sections }))).toThrow()
})
for (const info of [new Uint8Array(), bytes(documentProperties(), documentProperties()), bytes(documentProperties(), Uint8Array.of(1)), words(0xFFF00012)]) {
  it('refuses missing, duplicated or truncated DocInfo records', () => { expect(() => preflightArtifactHwp(source({ info }))).toThrow() })
}
for (const flags of [0, 3, 0x32]) it(`refuses external or unknown BinData flags ${flags}`, () => {
  expect(() => preflightArtifactHwp(source({ info: bytes(documentProperties(), binding(flags)), binary: [Uint8Array.of(1)] }))).toThrow()
})
it('refuses missing, duplicate and unbound BinData streams', () => {
  expect(() => preflightArtifactHwp(source({ info: bytes(documentProperties(), binding()) }))).toThrow()
  expect(() => preflightArtifactHwp(source({ info: bytes(documentProperties(), binding(), binding()), binary: [Uint8Array.of(1)] }))).toThrow()
  expect(() => preflightArtifactHwp(source({ binary: [Uint8Array.of(1)] }))).toThrow()
})
it('uses forced BinData compression even in an uncompressed document', () => {
  expect(() => preflightArtifactHwp(source({ info: bytes(documentProperties(), binding(0x12)), binary: [deflateSync(encoder.encode('payload'))] }))).not.toThrow()
  expect(() => preflightArtifactHwp(source({ info: bytes(documentProperties(), binding(0x12)), binary: [Uint8Array.of(255)] }))).toThrow()
})
it('accepts the native 12-byte STORAGE reference with UTF-16 OLE extension', () => {
  const native = Uint8Array.of(2, 0, 1, 0, 3, 0, 0x4F, 0, 0x4C, 0, 0x45, 0)
  expect(() => preflightArtifactHwp(source({ info: bytes(documentProperties(), record(18, 1, native)), binary: [Uint8Array.of(1)] }))).not.toThrow()
})
it('honours NoCompress without guessing from a deflate-looking BinData payload', () => {
  const bomb = deflateSync(new Uint8Array(officeImportLimits.partBytes + 1))
  expect(() => preflightArtifactHwp(source({ header: fileHeader(1), info: bytes(documentProperties(), binding(0x22)), binary: [bomb] }))).not.toThrow()
})
it('refuses an expanded BinData part before accumulating the over-limit output chunk', () => {
  const input = source({ info: bytes(documentProperties(), binding(0x12)), binary: [deflateSync(new Uint8Array(officeImportLimits.partBytes + 1))] })
  expect(() => preflightArtifactHwp(input)).toThrow()
})
it('shares the expanded aggregate budget across BinData streams', () => {
  const data = deflateSync(new Uint8Array(officeImportLimits.partBytes)), info = bytes(documentProperties(), ...Array.from({ length: 4 }, (_, index) => binding(0x12, index + 1)))
  expect(() => preflightArtifactHwp(source({ info, binary: [data, data, data, data] }))).toThrow()
})
it('refuses oversized input and raw CFB parts', () => {
  expect(() => readHwpCompound(new Uint8Array(officeImportLimits.inputBytes + 1), 'fixture')).toThrow()
  expect(() => readHwpCompound(compound([['large', new Uint8Array(officeImportLimits.partBytes + 1)]]), 'fixture')).toThrow()
})

for (const body of [record(71, 1, words(id.unknown)), record(95, 1, words(1)), record(87, 1, words(1)), bytes(record(71, 1, words(id.graphic)), record(76, 2, words(0x24726563)))]) {
  it('refuses original unsupported controls, shapes and opaque body records before native conversion', () => { expect(() => preflightArtifactHwp(source({ body: bytes(record(66, 0, paragraphHeader), body) }))).toThrow() })
}
it('validates original OLE reference indices without recovering a missing slot', () => {
  const payload = words(1, 7200, 7200, 2), body = bytes(record(66, 0, paragraph(9)), record(67, 1, controlText(id.graphic)), record(71, 1, words(id.graphic)), record(76, 2, words(id.ole)), record(84, 3, payload))
  expect(() => preflightArtifactHwp(source({ body, info: bytes(documentProperties(), binding()), binary: [Uint8Array.of(1)] }))).toThrow('바이너리 참조')
})
function tableBody(cells: readonly { column: number; row: number; columns: number; rows: number }[], dimensions = { rows: 1, columns: 1 }): Uint8Array {
  const shape = new Uint8Array(18); new DataView(shape.buffer).setUint16(4, dimensions.rows, true); new DataView(shape.buffer).setUint16(6, dimensions.columns, true)
  return bytes(record(66, 0, paragraph(9)), record(67, 1, controlText(id.table)), record(71, 1, words(id.table)), record(77, 2, shape), ...cells.flatMap(cell => {
    const data = new Uint8Array(34), view = new DataView(data.buffer)
    for (const [index, value] of [cell.column, cell.row, cell.columns, cell.rows].entries()) view.setUint16(8 + index * 2, value, true)
    return [record(72, 2, data), record(66, 3, paragraphHeader)]
  }))
}
it('accepts a complete table grid and rejects missing, overlapping or zero-span cells', () => {
  const cell = { column: 0, row: 0, columns: 1, rows: 1 }
  expect(() => preflightArtifactHwp(source({ body: tableBody([cell]) }))).not.toThrow()
  for (const cells of [[], [cell, cell], [{ ...cell, rows: 0 }], [{ ...cell, columns: 2 }]]) expect(() => preflightArtifactHwp(source({ body: tableBody(cells) }))).toThrow()
})
for (const dimensions of [hwpxTableLimits, { rows: 4001, columns: hwpxTableLimits.columns }]) {
  it(`accepts supported table axes ${dimensions.rows}x${dimensions.columns} without imposing a grid area cap`, () => {
    const cell = { row: 0, column: 0, ...dimensions }
    expect(() => preflightArtifactHwp(source({ body: tableBody([cell], dimensions) }))).not.toThrow()
  })
}
const maximumHwpTableAxis = 0xFFFF
for (const dimensions of [{ rows: hwpxTableLimits.rows + 1, columns: 1 }, { rows: 1, columns: hwpxTableLimits.columns + 1 },
  { rows: maximumHwpTableAxis, columns: maximumHwpTableAxis }]) {
  it(`refuses unsupported destination table axes ${dimensions.rows}x${dimensions.columns} before native conversion`, () => {
    const cell = { row: 0, column: 0, ...dimensions }
    expect(() => preflightArtifactHwp(source({ body: tableBody([cell], dimensions) }))).toThrow('행·열 수가 가져오기 지원 범위를')
  })
}
it('accepts 64 active paragraph ancestors and refuses the 65th upstream parser boundary', () => {
  const nested = (depth: number): Uint8Array => {
    const parts: Uint8Array[] = [], table = new Uint8Array(18), cell = new Uint8Array(34)
    new DataView(table.buffer).setUint16(4, 1, true); new DataView(table.buffer).setUint16(6, 1, true)
    new DataView(cell.buffer).setUint16(12, 1, true); new DataView(cell.buffer).setUint16(14, 1, true)
    for (let index = 0; index < depth; index++) {
      const level = index * 2; parts.push(record(66, level, paragraph(index + 1 < depth ? 9 : 0)))
      if (index + 1 < depth) parts.push(record(67, level + 1, controlText(id.table)), record(71, level + 1, words(id.table)), record(77, level + 2, table), record(72, level + 2, cell))
    }
    return bytes(...parts)
  }
  expect(() => preflightArtifactHwp(source({ body: nested(64) }))).not.toThrow()
  expect(() => preflightArtifactHwp(source({ body: nested(65) }))).toThrow('지원 깊이')
})
it('refuses orphan, wrongly nested and duplicate paragraph leaf records', () => {
  const text = Uint8Array.of(65, 0, 13, 0)
  for (const tail of [record(67, 2, text), bytes(record(67, 1, text), record(67, 1, text)), bytes(record(67, 1, text), record(68, 2, words(0)))]) {
    expect(() => preflightArtifactHwp(source({ body: bytes(record(66, 0, paragraph(2)), tail) }))).toThrow()
  }
})
for (const tag of [68, 69]) it(`refuses duplicate direct paragraph formatting record ${tag}`, () => {
  const metadata = record(tag, 1, words(0, 0))
  expect(() => preflightArtifactHwp(source({ body: bytes(record(66, 0, paragraphHeader), metadata, metadata) }))).toThrow()
})
for (const text of [Uint8Array.of(0, 0xD8, 13, 0), Uint8Array.of(0, 0xDC, 13, 0), Uint8Array.of(0xB, 0, 0, 0), bytes(controlText(id.graphic).slice(0, 14), Uint8Array.of(2, 0, 13, 0))]) {
  it('refuses original unpaired UTF-16 or malformed eight-WCHAR controls', () => {
    expect(() => preflightArtifactHwp(source({ body: bytes(record(66, 0, paragraph(text.length / 2)), record(67, 1, text)) }))).toThrow()
  })
}

const publicRoot = process.env.MASC_HWP_PUBLIC_SAMPLES
const publicTest = publicRoot ? it : it.skip
const publicFiles = ['세로막대형/묶은세로막대형.hwp', '가로막대형/묶은가로막대형.hwp', '라인/꺽은선형.hwp', '원형/2차원원형.hwp']
// Optional local public corpus: the normal suite uses synthetic CFB, never private documents or machine paths.
for (const name of publicFiles) publicTest(`preflights public HWP ${name}`, () => {
  const data = new Uint8Array(readFileSync(join(publicRoot!, name)))
  expect(readHwpCompound(data, name).has('BinData/BIN0001.OLE')).toBe(true); expect(() => preflightArtifactHwp(data)).not.toThrow()
})
publicTest('rejects the public source chart when both original GSO IDs become unknown despite a native loss report of zero', () => {
  const streams = new Map(readHwpCompound(new Uint8Array(readFileSync(join(publicRoot!, publicFiles[0]!))), 'public source'))
  const body = inflateSync(streams.get('BodyText/Section0')!), view = new DataView(body.buffer, body.byteOffset, body.byteLength)
  let replacements = 0
  for (let offset = 0; offset < body.byteLength;) {
    const header = view.getUint32(offset, true), tag = header & 0x3FF; let size = header >>> 20; offset += 4
    if (size === 0xFFF) { size = view.getUint32(offset, true); offset += 4 }
    if (tag === 71 && view.getUint32(offset, true) === id.graphic) { view.setUint32(offset, id.unknown, true); replacements++ }
    if (tag === 67) for (let index = offset; index + 6 <= offset + size; index += 2) {
      if (view.getUint16(index, true) === 0xB && view.getUint32(index + 2, true) === id.graphic) { view.setUint32(index + 2, id.unknown, true); replacements++ }
    }
    offset += size
  }
  expect(replacements).toBe(2); streams.set('BodyText/Section0', deflateSync(body))
  expect(() => preflightArtifactHwp(compound(streams))).toThrow()
})
for (const fault of ['level', 'surrogate']) publicTest(`refuses the public table cell ${fault} mutation that a tolerant native parser silently loses`, () => {
  const original = new Uint8Array(readFileSync(join(publicRoot!, '..', 'table-001.hwp')))
  expect(() => preflightArtifactHwp(original)).not.toThrow()
  const streams = new Map(readHwpCompound(original, 'public table')), raw = streams.get('BodyText/Section0')!
  const compressed = Boolean(streams.get('FileHeader')![36]! & 1), body = compressed ? inflateSync(raw) : raw.slice(), view = new DataView(body.buffer, body.byteOffset, body.byteLength)
  let found = false
  for (let offset = 0; offset < body.byteLength;) {
    const start = offset, header = view.getUint32(offset, true); let size = header >>> 20; offset += 4
    if (size === 0xFFF) { size = view.getUint32(offset, true); offset += 4 }
    if ((header & 0x3FF) === 67 && new TextDecoder('utf-16le').decode(body.subarray(offset, offset + size)) === '구 분\r') {
      if (fault === 'level') view.setUint32(start, ((header & ~(0x3FF << 10)) | ((((header >>> 10) & 0x3FF) + 1) << 10)) >>> 0, true)
      else view.setUint16(offset, 0xD800, true)
      found = true; break
    }
    offset += size
  }
  expect(found).toBe(true); streams.set('BodyText/Section0', compressed ? deflateSync(body) : body)
  expect(() => preflightArtifactHwp(compound(streams))).toThrow()
})
