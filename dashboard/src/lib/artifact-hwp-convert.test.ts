import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { beforeAll, expect, it } from 'vitest'
import { initSync } from '@rhwp/core'
import JSZip from 'jszip'
import { convertArtifactHwp } from './artifact-hwp-convert'
import { importArtifactHwpx } from './artifact-hwpx-import'
import { artifactHwpxFile } from './artifact-hwpx-export'
import type { ArtifactDocument } from '../api/published-artifacts'
import { hwpxNs } from './artifact-hwpx-template'
import { parseOfficeXml, xmlDescendants } from './artifact-office-xml'
import { writeHwpTestCompound } from './artifact-hwp-test-fixture'
import { validateHwpCompoundGraph } from './artifact-hwp-compound-graph'

beforeAll(() => {
  const require = createRequire(import.meta.url)
  initSync({ module: new Uint8Array(readFileSync(require.resolve('@rhwp/core/rhwp_bg.wasm'))).buffer })
})

function hwp(text: string): Uint8Array {
  // Independent HWP5 records: paragraph count uses UTF-16 storage units, including TAB's eight WCHARs.
  const units: number[] = []
  for (let index = 0; index < text.length; index++) {
    const unit = text.charCodeAt(index)
    if (unit === 9) units.push(9, 0, 0, 0, 0, 0, 0, 9)
    else if (unit === 0x00a0) units.push(0x001e)
    else if (unit === 0x2007) units.push(0x001f)
    else units.push(unit)
  }
  units.push(13)
  const encoded = new Uint8Array(units.length * 2), encodedView = new DataView(encoded.buffer)
  units.forEach((unit, index) => encodedView.setUint16(index * 2, unit, true))
  const header = new Uint8Array(256), properties = new Uint8Array(26), paragraph = new Uint8Array(22)
  header.set(new TextEncoder().encode('HWP Document File')); header.set([7, 1, 0, 5], 32)
  new DataView(properties.buffer).setUint16(0, 1, true)
  new DataView(paragraph.buffer).setUint32(0, units.length | 0x80000000, true)
  new DataView(paragraph.buffer).setUint16(12, 1, true)
  function record(tag: number, level: number, payload: Uint8Array): Uint8Array {
    const output = new Uint8Array(4 + payload.byteLength)
    new DataView(output.buffer).setUint32(0, tag | (level << 10) | (payload.byteLength << 20), true)
    output.set(payload, 4); return output
  }
  const concatenate = (parts: readonly Uint8Array[]) => {
    const output = new Uint8Array(parts.reduce((size, part) => size + part.byteLength, 0)); let at = 0
    for (const part of parts) { output.set(part, at); at += part.byteLength }
    return output
  }
  const string = (value: string) => {
    const output = new Uint8Array(2 + value.length * 2), view = new DataView(output.buffer)
    view.setUint16(0, value.length, true)
    for (let index = 0; index < value.length; index++) view.setUint16(2 + index * 2, value.charCodeAt(index), true)
    return output
  }
  const ids = new Uint8Array(60), idView = new DataView(ids.buffer)
  for (const index of [1, 2, 3, 4, 5, 6, 7, 9, 10, 13, 14]) idView.setUint32(index * 4, 1, true)
  const character = new Uint8Array(68), characterView = new DataView(character.buffer)
  character.fill(100, 14, 21); character.fill(100, 28, 35)
  characterView.setInt32(42, 1000, true); characterView.setUint32(60, 0xffffffff, true)
  const paragraphStyle = new Uint8Array(46)
  new DataView(paragraphStyle.buffer).setInt32(24, 160, true)
  const styleProperties = new Uint8Array(10)
  new DataView(styleProperties.buffer).setUint16(2, 1042, true)
  const info = concatenate([record(16, 0, properties), record(17, 0, ids),
    ...Array.from({ length: 7 }, () => record(19, 1, concatenate([Uint8Array.of(0), string('Arial')]))),
    record(21, 1, character), record(22, 1, new Uint8Array(8)), record(25, 1, paragraphStyle),
    record(26, 1, concatenate([string('본문'), string('Normal'), styleProperties]))])
  const parts = [record(66, 0, paragraph), record(67, 1, encoded), record(68, 1, new Uint8Array(8))]
  return writeHwpTestCompound([['FileHeader', header], ['DocInfo', info], ['BodyText/Section0', concatenate(parts)]])
}

for (const text of ['기존 한글 문서', 'A\tB', '한글 😀 𠮷', '앞\u00a0뒤', '앞\u2007뒤']) {
  it(`uses the pinned WASM to import independent HWP5 records containing ${JSON.stringify(text)}`, async () => {
    const input = hwp(text), saved = input.slice()
    const result = await convertArtifactHwp(input)
    expect(result.content).toContain(text)
    expect(input).toEqual(saved)
  })
}

function document(content: string): ArtifactDocument {
  const artifact = { id: `artifact-${'a'.repeat(32)}`, revision: 1, title: '본문', summary: '원고', format: 'html' as const,
    author: 'fixture', created_at: '2026-11-16T00:00:00Z', task_id: null, goal_id: null, url: '/', body: { _blob: { sha256: 'b'.repeat(64) } } }
  return { content, artifact, revisions: [artifact] }
}
it('refuses an equation with text in HWP mode instead of returning only the text', async () => {
  const generated = await artifactHwpxFile(document('<p>본문</p>'))
  const zip = await JSZip.loadAsync(generated.data), file = zip.file('Contents/section0.xml')!
  const xml = parseOfficeXml(await file.async('string'), file.name)
  const run = xmlDescendants(xml, hwpxNs.paragraph, 'run')[0]!
  const equation = xml.createElementNS(hwpxNs.paragraph, 'hp:equation'), script = xml.createElementNS(hwpxNs.paragraph, 'hp:script')
  script.appendChild(xml.createTextNode('x+y')); equation.appendChild(script); run.appendChild(equation)
  zip.file(file.name, xml.toString())
  let calls = 0
  const source = { kind: 'hwp5' as const, readOleChart: async () => { calls++; throw new Error('Equation must not use an OLE reader') } }
  await expect(importArtifactHwpx(await zip.generateAsync({ type: 'uint8array' }), source)).rejects.toThrow('equation')
  expect(calls).toBe(0)
})

it('rejects non-HWP input before creating a document', async () => {
  await expect(convertArtifactHwp(new TextEncoder().encode('a renamed text file'))).rejects.toThrow()
})

const publicRoot = process.env.MASC_HWP_PUBLIC_SAMPLES
const publicTest = publicRoot ? it : it.skip
publicTest('converts a native HWP with differently cased compound entry names without changing its content', async () => {
  const original = new Uint8Array(readFileSync(join(publicRoot!, '세로막대형/묶은세로막대형.hwp'))), input = original.slice()
  const layout = validateHwpCompoundGraph(input), view = new DataView(input.buffer), decoder = new TextDecoder('utf-16le', { fatal: true })
  const structuralNames = new Set(['FileHeader', 'DocInfo', 'BodyText', 'Section0', 'BinData', 'BIN0001.OLE'])
  let changed = 0
  for (const entry of layout.entries) {
    const name = decoder.decode(input.subarray(entry.name.offset, entry.name.offset + entry.name.bytes))
    if (!structuralNames.has(name)) continue
    const lower = name.toLowerCase()
    for (let index = 0; index < lower.length; index++) view.setUint16(entry.name.offset + index * 2, lower.charCodeAt(index), true)
    changed++
  }
  expect(changed).toBe(structuralNames.size)
  expect(await convertArtifactHwp(input)).toEqual(await convertArtifactHwp(original))
})
