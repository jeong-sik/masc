import { expect, it } from 'vitest'
import { hwpCompoundNameKey, indexHwpCompoundStreams } from './artifact-hwp-compound-paths'
import { readHwpCompoundStreams } from './artifact-hwp-compound'
import { writeHwpTestCompound } from './artifact-hwp-test-fixture'
import { validateHwpCompoundGraph } from './artifact-hwp-compound-graph'

const bytes = Uint8Array.of(1, 2, 3)

it('keeps original Map behavior and offers explicit CFB case-insensitive lookup', () => {
  const source = new Map([['FileHeader', bytes], ['BodyText/Section0', bytes]]), files = indexHwpCompoundStreams(source)
  expect(new Map(files)).toEqual(source)
  expect(files.get('fileheader')).toBeUndefined(); expect(files.has('fileheader')).toBe(false)
  expect(files.lookup('fileheader')).toBe(bytes); expect(files.lookup('bOdYtExT/sEcTiOn0')).toBe(bytes)
  expect(files.lookup('bodytext')).toBeUndefined(); expect(files.lookup('missing')).toBeUndefined()
  const seen: string[] = []
  files.forEach((value, key, map) => { expect(value).toBe(bytes); expect(map).toBe(files); seen.push(key) })
  expect(seen).toEqual([...source.keys()])
})

it('indexes complete storage components and final names while preserving original paths', () => {
  const files = indexHwpCompoundStreams(new Map([
    ['bOdYtExT/Section0', bytes], ['BODYTEXT/Nested/Section1', bytes], ['BodyTextual/Section2', bytes],
    ['OOXMLChartContents', bytes], ['Nested/ooxmlchartcontents', bytes],
  ]))
  expect([...files.pathsInStorage('bodytext')].sort()).toEqual(['BODYTEXT/Nested/Section1', 'bOdYtExT/Section0'].sort())
  expect(files.pathsInStorage('body')).toEqual([])
  expect(files.pathsWithName('oOxMlChArTcOnTeNtS')).toEqual(['OOXMLChartContents', 'Nested/ooxmlchartcontents'])
})

it('does not conflate sharp-s or ligature expansions with multiple UTF-16 units', () => {
  const other = Uint8Array.of(4), files = indexHwpCompoundStreams(new Map([['ß', bytes], ['SS', other], ['ﬀ', bytes], ['FF', other]]))
  expect(hwpCompoundNameKey('ß')).not.toBe(hwpCompoundNameKey('SS'))
  expect(files.lookup('ß')).toBe(bytes); expect(files.lookup('ss')).toBe(other)
  expect(files.lookup('ﬀ')).toBe(bytes); expect(files.lookup('ff')).toBe(other)
})

it('uses single-unit Greek uppercase mappings when full uppercase would expand', () => {
  for (const [small, capital] of [['ᾀ', 'ᾈ'], ['ᾐ', 'ᾘ'], ['ᾠ', 'ᾨ'], ['ᾳ', 'ᾼ'], ['ῃ', 'ῌ'], ['ῳ', 'ῼ']]) {
    expect(hwpCompoundNameKey(small!)).toBe(hwpCompoundNameKey(capital!))
  }
  expect(hwpCompoundNameKey('ı')).toBe(hwpCompoundNameKey('I'))
  expect(hwpCompoundNameKey('ſ')).toBe(hwpCompoundNameKey('S'))
})

it('leaves surrogate code units unchanged, including letters with astral case mappings', () => {
  const small = String.fromCodePoint(0x10428), capital = String.fromCodePoint(0x10400)
  expect(small.toUpperCase()).toBe(capital)
  expect(hwpCompoundNameKey(small)).not.toBe(hwpCompoundNameKey(capital))
  const files = indexHwpCompoundStreams(new Map([[small, bytes], [capital, Uint8Array.of(4)]]))
  expect(files.lookup(small)).toBe(bytes); expect(files.lookup(capital)).toEqual(Uint8Array.of(4))
})

it('rejects collisions using the same name key as lookup', () => {
  expect(() => indexHwpCompoundStreams(new Map([['FileHeader', bytes], ['fileheader', bytes]]))).toThrow('경로가 겹칩니다')
  expect(() => indexHwpCompoundStreams(new Map([['Folder', bytes], ['folder/child', bytes]]))).toThrow('storage 경로가 겹칩니다')
  expect(() => indexHwpCompoundStreams(new Map([['ᾳ', bytes], ['ᾼ', bytes]]))).toThrow('경로가 겹칩니다')
})

it('reads mixed-case CFB names and stores sharp-s and SS independently', () => {
  const data = writeHwpTestCompound([['fileheader', bytes], ['bOdYtExT/sEcTiOn0', bytes], ['first', bytes], ['other', Uint8Array.of(4)]]), layout = validateHwpCompoundGraph(data)
  const view = new DataView(data.buffer), decoder = new TextDecoder('utf-16le')
  for (const item of layout.entries) {
    const name = decoder.decode(data.subarray(item.name.offset, item.name.offset + item.name.bytes))
    if (name !== 'first' && name !== 'other') continue
    const replacement = name === 'first' ? 'ß' : 'SS'
    data.fill(0, item.name.offset, item.name.offset + 64)
    for (let index = 0; index < replacement.length; index++) view.setUint16(item.name.offset + index * 2, replacement.charCodeAt(index), true)
    view.setUint16(item.name.offset + 64, (replacement.length + 1) * 2, true)
  }
  const files = readHwpCompoundStreams(data, 'mixed case')
  expect(files.lookup('FileHeader')).toEqual(bytes); expect(files.lookup('BodyText/Section0')).toEqual(bytes)
  expect(files.get('ß')).toEqual(bytes); expect(files.get('SS')).toEqual(Uint8Array.of(4))
})
