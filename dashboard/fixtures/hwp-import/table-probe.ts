import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join, resolve } from 'node:path'
import { initSync } from '@rhwp/core'
import { inflateSync } from 'fflate'
import { parseFragment, defaultTreeAdapter as tree, type DefaultTreeAdapterTypes as Nodes } from 'parse5'
import type { ArtifactDocument } from '../../src/api/published-artifacts'
import { readHwpCompound } from '../../src/lib/artifact-hwp-container'
import { convertArtifactHwp } from '../../src/lib/artifact-hwp-convert'
import { importArtifactHwpx } from '../../src/lib/artifact-hwpx-import'
import { importArtifactDocx } from '../../src/lib/artifact-docx-import'
import { artifactHwpxFile } from '../../src/lib/artifact-hwpx-export'
import { artifactWordFile } from '../../src/lib/artifact-word-export'

const [samplesArgument, outputArgument] = process.argv.slice(2)
if (!samplesArgument || !outputArgument) throw new Error('Usage: pnpm exec tsx fixtures/hwp-import/table-probe.ts <rhwp/samples> <output-directory>')
const samples = resolve(samplesArgument), output = resolve(outputArgument)
mkdirSync(output, { recursive: true })
const require = createRequire(import.meta.url), wasm = readFileSync(require.resolve('@rhwp/core/rhwp_bg.wasm'))
initSync({ module: wasm })
const digest = (bytes: Uint8Array) => createHash('sha256').update(bytes).digest('hex')
type Cell = { row: number; column: number; rows: number; columns: number; text: string }
type Table = { rows: number; columns: number; cells: Cell[] }

/** Read original TABLE/LIST_HEADER/PARA_TEXT fields independently of the WASM table serializer. */
function sourceTables(input: Uint8Array): Table[] {
  const streams = readHwpCompound(input, 'probe'), header = streams.get('FileHeader')!
  const compressed = Boolean(header[36]! & 1), result: Table[] = []
  for (const [path, stored] of streams) if (/^BodyText\/Section\d+$/.test(path)) {
    const data = compressed ? inflateSync(stored) : stored, view = new DataView(data.buffer, data.byteOffset, data.byteLength)
    const stack: { level: number; table: Table; cell: Cell | null }[] = []
    for (let offset = 0; offset < data.byteLength;) {
      const record = view.getUint32(offset, true), tag = record & 0x3ff, level = (record >>> 10) & 0x3ff
      let size = record >>> 20; offset += 4
      if (size === 0xfff) { size = view.getUint32(offset, true); offset += 4 }
      const at = offset; offset += size
      while (stack.length && stack.at(-1)!.level >= level) stack.pop()
      if (tag === 71 && view.getUint32(at, true) === 0x74626c20) {
        const table: Table = { rows: 0, columns: 0, cells: [] }
        result.push(table); stack.push({ level, table, cell: null }); continue
      }
      const owner = stack.at(-1)
      if (!owner) continue
      if (tag === 77 && level === owner.level + 1) {
        owner.table.rows = view.getUint16(at + 4, true); owner.table.columns = view.getUint16(at + 6, true)
      } else if (tag === 72 && level === owner.level + 1 && owner.table.rows > 0) {
        owner.cell = { column: view.getUint16(at + 8, true), row: view.getUint16(at + 10, true),
          columns: view.getUint16(at + 12, true), rows: view.getUint16(at + 14, true), text: '' }
        owner.table.cells.push(owner.cell)
      } else if (tag === 67 && owner.cell) {
        for (let position = at; position < at + size; position += 2) {
          const unit = view.getUint16(position, true)
          if (unit >= 32) owner.cell.text += String.fromCharCode(unit)
          else if (unit === 9) { owner.cell.text += '\t'; position += 14 }
          else if (unit === 10) owner.cell.text += '\n'
          else if (unit !== 0 && unit !== 13) {
            // These public fixtures contain only table controls in cell paragraphs.
            assert.equal(unit, 11, `Unaccounted fixture text control ${unit}`); position += 14
          }
        }
      }
    }
  }
  return result.map(table => ({ ...table, cells: table.cells.sort((a, b) => a.row - b.row || a.column - b.column) }))
}

function htmlTables(content: string): Table[] {
  const result: Table[] = []
  const children = (node: Nodes.ParentNode) => node.childNodes.filter(tree.isElementNode)
  const attribute = (element: Nodes.Element, name: string) => Number(tree.getAttrList(element).find(attr => attr.name === name)?.value ?? '1')
  function text(node: Nodes.ParentNode): string {
    return node.childNodes.map(child => tree.isTextNode(child) ? child.value : tree.isElementNode(child)
      ? child.tagName === 'table' ? '' : child.tagName === 'br' ? '\n' : text(child) : '').join('')
  }
  function visit(node: Nodes.ParentNode): void {
    for (const element of children(node)) {
      if (element.tagName === 'table') {
        const rowElements = children(element).flatMap(child => ['tbody', 'thead', 'tfoot'].includes(child.tagName) ? children(child) : [child]).filter(child => child.tagName === 'tr')
        const occupied = new Map<number, number>(), cells: Cell[] = []
        let columns = 0
        for (const [row, tr] of rowElements.entries()) {
          let column = 0
          for (const td of children(tr).filter(child => child.tagName === 'td' || child.tagName === 'th')) {
            while ((occupied.get(column) ?? 0) > row) column++
            const rows = attribute(td, 'rowspan'), span = attribute(td, 'colspan')
            cells.push({ row, column, rows, columns: span, text: text(td) })
            for (let col = column; col < column + span; col++) occupied.set(col, row + rows)
            column += span; columns = Math.max(columns, column)
          }
        }
        result.push({ rows: rowElements.length, columns, cells })
      }
      visit(element)
    }
  }
  visit(parseFragment(content)); return result
}
function document(content: string): ArtifactDocument {
  const artifact = { id: `artifact-${'e'.repeat(32)}`, revision: 1, title: '기존 HWP 표 대조', summary: '공개 원본 셀과 병합 확인', format: 'html' as const,
    author: 'fixture', created_at: '2026-11-16T00:00:00Z', task_id: null, goal_id: null, url: '/', body: { _blob: { sha256: 'f'.repeat(64) } } }
  return { content, artifact, revisions: [artifact] }
}

const results = []
for (const name of ['table-001.hwp']) {
  const input = new Uint8Array(readFileSync(join(samples, name))), expected = sourceTables(input)
  const imported = await convertArtifactHwp(input)
  assert.ok(expected.length > 0)
  assert.deepEqual(htmlTables(imported.content), expected, `${name}: original cell values, coordinates and merged spans`)
  const marker = 'HWP 셀 수정 확인', first = expected[0]!.cells.find(cell => cell.text.length > 0)!
  assert.ok(first)
  const content = imported.content.replace(first.text, marker)
  assert.notEqual(content, imported.content)
  const edited = htmlTables(content)
  const exports: { format: string; sha256: string }[] = []
  for (const format of ['hwpx', 'docx'] as const) {
    const file = await (format === 'hwpx' ? artifactHwpxFile : artifactWordFile)(document(content))
    const returned = await (format === 'hwpx' ? importArtifactHwpx : importArtifactDocx)(file.data)
    assert.deepEqual(htmlTables(returned.content), edited, `${name}: edited complete table via ${format}`)
    const bytes = new Uint8Array(file.data), path = join(output, `${name}-edited.${format}`)
    writeFileSync(path, bytes); exports.push({ format, sha256: digest(bytes) })
  }
  results.push({ name, inputSha256: digest(input), tables: expected, exports })
}
const report = { observedAt: new Date().toISOString(), engine: '@rhwp/core@0.9.0', wasmSha256: digest(wasm), results,
  scope: 'Original HWP record cells against imported HTML, followed by edited Office roundtrips. Native Hancom/Word and browser downloads unverified.' }
writeFileSync(join(output, 'tables.json'), JSON.stringify(report, null, 2))
console.log(JSON.stringify({ files: results.length, tables: results.reduce((count, row) => count + row.tables.length, 0),
  cells: results.reduce((count, row) => count + row.tables.reduce((total, table) => total + table.cells.length, 0), 0), exportsReimported: results.length * 2 }))
