//HIGH-RISK-UNREVIEWED: Original records must not disappear through a tolerant native parser.
import { readHwpTextControls } from './artifact-hwp-text'
import { checkOfficeTableGrid, type OfficeTableCellBounds } from './artifact-office-table-grid'
import { hwpxTableLimits } from './artifact-hwpx-template'
const tag = { properties: 16, binData: 18, paragraph: 66, text: 67, chars: 68, lines: 69, ranges: 70,
  control: 71, list: 72, page: 73, footnoteStyle: 74, pageBorder: 75, shape: 76, table: 77, ole: 84, picture: 85 } as const
const extendedSize = 0xFFF, headerBytes = 4, listPrefixBytes = 8, cellBytes = 34, oleReferenceOffset = 12, pictureReferenceOffset = 71
// @rhwp/core 0.9.0 (c9095c5), parser/body_text.rs: 65th simultaneous PARA_HEADER ancestor is otherwise dropped.
const maximumCoreParagraphAncestors = 64
type Record = { tag: number; level: number; data: Uint8Array }
export type HwpBinData = { readonly storageId: number; readonly extension: string; readonly type: 'image' | 'ole'; readonly compression: 'default' | 'compressed' | 'plain' }
type Cell = OfficeTableCellBounds
type Control = { level: number } & ({ kind: 'section' | 'columns' | 'number' | 'layout' }
  | { kind: 'table'; rows: number; columns: number; cells: Cell[]; seen: boolean; list: boolean }
  | { kind: 'graphic'; shape: 'image' | 'ole' | null; seen: boolean; list: boolean })
type Paragraph = { level: number; count: number; children: Set<number>; textControls: readonly number[] | null; controls: number[] }

function view(data: Uint8Array): DataView { return new DataView(data.buffer, data.byteOffset, data.byteLength) }
function* records(data: Uint8Array): Generator<Record> {
  const bytes = view(data)
  for (let offset = 0; offset < data.byteLength;) {
    if (offset + headerBytes > data.byteLength) throw new Error('HWP 레코드 헤더가 잘렸습니다.')
    const header = bytes.getUint32(offset, true); offset += headerBytes
    let size = header >>> 20
    if (size === extendedSize) {
      if (offset + headerBytes > data.byteLength) throw new Error('HWP 레코드 확장 길이가 없습니다.')
      size = bytes.getUint32(offset, true); offset += headerBytes
    }
    if (size > data.byteLength - offset) throw new Error('HWP 레코드 본문이 잘렸습니다.')
    yield { tag: header & 0x3FF, level: (header >>> 10) & 0x3FF, data: data.subarray(offset, offset + size) }
    offset += size
  }
}

export function readHwpDocInfo(data: Uint8Array): { sectionCount: number; binData: readonly HwpBinData[] } {
  let sectionCount: number | undefined
  const binData: HwpBinData[] = []
  for (const record of records(data)) {
    if (record.tag === tag.properties) {
      if (sectionCount !== undefined || record.level !== 0 || record.data.byteLength < 26) throw new Error('HWP 문서 속성이 없거나 겹칩니다.')
      sectionCount = view(record.data).getUint16(0, true)
    } else if (record.tag === tag.binData) {
      if (record.level !== 1 || record.data.byteLength < 4) throw new Error('HWP 바이너리 참조의 소속 또는 길이가 올바르지 않습니다.')
      const bytes = view(record.data), flags = bytes.getUint16(0, true), storageId = bytes.getUint16(2, true)
      let type: HwpBinData['type'], compression: HwpBinData['compression']
      switch (flags & 0xF) {
        case 1: type = 'image'; break
        case 2: type = 'ole'; break
        default: throw new Error('외부 파일 또는 알 수 없는 HWP 바이너리 종류입니다.')
      }
      switch ((flags >>> 4) & 3) {
        case 0: compression = 'default'; break
        case 1: compression = 'compressed'; break
        case 2: compression = 'plain'; break
        default: throw new Error('알 수 없는 HWP 바이너리 압축 속성입니다.')
      }
      let extension = 'OLE'
      // Native Hancom STORAGE records may include the same UTF-16 extension field as EMBEDDING.
      if (type === 'image' || record.data.byteLength !== 4) {
        if (record.data.byteLength < 6) throw new Error('HWP 그림 확장자 길이가 없습니다.')
        const size = bytes.getUint16(4, true) * 2
        if (!size || size + 6 !== record.data.byteLength) throw new Error('HWP 그림 확장자가 잘렸습니다.')
        extension = new TextDecoder('utf-16le', { fatal: true, ignoreBOM: true }).decode(record.data.subarray(6))
      }
      if (!storageId || !/^[a-zA-Z0-9]+$/.test(extension)) throw new Error('HWP 바이너리 참조 경로가 올바르지 않습니다.')
      binData.push({ storageId, extension, type, compression })
    }
  }
  if (sectionCount === undefined || sectionCount === 0) throw new Error('HWP 구역 수가 없습니다.')
  return { sectionCount, binData }
}

function controlKind(id: number): Control['kind'] {
  // HWP FourCC values are encoded as a little-endian DWORD in CTRL_HEADER.
  switch (id) {
    case 0x73656364: return 'section' // secd
    case 0x636F6C64: return 'columns' // cold
    case 0x74626C20: return 'table' // tbl
    case 0x67736F20: return 'graphic' // gso
    case 0x61746E6F: case 0x6E776E6F: return 'number' // atno, nwno
    case 0x70676E70: case 0x70676374: case 0x70676864: return 'layout' // pgnp, pgct, pghd
    default: throw new Error('지원하지 않는 원본 HWP 컨트롤입니다.')
  }
}

function closeControl(control: Control): void {
  if (control.kind === 'graphic' && (!control.shape || !control.seen)) throw new Error('HWP 그림 또는 OLE 본문이 없습니다.')
  if (control.kind !== 'table') return
  if (!control.seen || !control.rows || !control.columns) throw new Error('HWP 표의 크기가 없습니다.')
  checkOfficeTableGrid(control.rows, control.columns, control.cells, 'HWP 표')
}
function closeParagraph(paragraph: Paragraph): void {
  const text = paragraph.textControls
  if ((text === null && paragraph.controls.length) || (text !== null && (text.length !== paragraph.controls.length || text.some((id, index) => id !== paragraph.controls[index])))) {
    throw new Error('HWP 본문 제어 문자와 컨트롤 참조가 일치하지 않습니다.')
  }
}

/** This is an inventory check, not a replacement text/layout parser. Unknown content never reaches Core. */
export function checkHwpBody(data: Uint8Array, binData: readonly HwpBinData[]): void {
  const controls: Control[] = []
  const hierarchy: Record[] = [], paragraphStack: Paragraph[] = []
  let paragraphs = 0
  for (const record of records(data)) {
    while (paragraphStack.length && paragraphStack.at(-1)!.level >= record.level) closeParagraph(paragraphStack.pop()!)
    while (controls.length && controls.at(-1)!.level >= record.level) closeControl(controls.pop()!)
    while (hierarchy.length && hierarchy.at(-1)!.level >= record.level) hierarchy.pop()
    const parent = hierarchy.at(-1), paragraph = paragraphStack.at(-1)
    if (record.level > 0 && (!parent || record.level !== parent.level + 1
      || ![tag.paragraph, tag.control, tag.list, tag.shape].some(candidate => candidate === parent.tag))) throw new Error('HWP 레코드의 부모 또는 깊이가 올바르지 않습니다.')
    hierarchy.push(record)
    const owner = controls.at(-1), bytes = view(record.data)
    switch (record.tag) {
      case tag.paragraph:
        if (paragraphStack.length >= maximumCoreParagraphAncestors) throw new Error('HWP 중첩 문단이 현재 변환기의 지원 깊이를 넘습니다.')
        if (record.data.byteLength < 12) throw new Error('HWP 문단 헤더가 잘렸습니다.')
        if (record.level === 0) paragraphs++
        else if (!owner || (owner.kind !== 'table' && owner.kind !== 'graphic') || !owner.list
          || (parent?.tag !== tag.list && parent?.tag !== tag.control)) throw new Error('지원하지 않는 HWP 개체 안에 본문 문단이 있습니다.')
        paragraphStack.push({ level: record.level, count: bytes.getUint32(0, true) & 0x7FFFFFFF, children: new Set(), textControls: null, controls: [] })
        break
      case tag.text: case tag.chars: case tag.lines: case tag.ranges:
        if (!paragraph || parent?.tag !== tag.paragraph || record.level !== paragraph.level + 1 || paragraph.children.has(record.tag)) throw new Error('HWP 문단의 직접 자식 레코드가 없거나 겹칩니다.')
        paragraph.children.add(record.tag)
        if (record.tag === tag.text) {
          if (record.data.byteLength / 2 !== paragraph.count) throw new Error('HWP 문단의 UTF-16 길이가 일치하지 않습니다.')
          paragraph.textControls = readHwpTextControls(record.data)
          for (const id of paragraph.textControls) controlKind(id)
        }
        break
      case tag.control: {
        if (record.data.byteLength < 4 || !paragraph || parent?.tag !== tag.paragraph) throw new Error('HWP 컨트롤 ID 또는 본문 소속이 올바르지 않습니다.')
        const id = bytes.getUint32(0, true), kind = controlKind(id), level = record.level
        paragraph.controls.push(id)
        controls.push(kind === 'table' ? { kind, level, rows: 0, columns: 0, cells: [], seen: false, list: false }
          : kind === 'graphic' ? { kind, level, shape: null, seen: false, list: false } : { kind, level })
        break
      }
      case tag.list:
        if (record.data.byteLength < listPrefixBytes || !owner || (owner.kind !== 'table' && owner.kind !== 'graphic')
          || parent?.tag !== tag.control || record.level !== owner.level + 1) throw new Error('지원하지 않는 HWP 문단 목록입니다.')
        owner.list = true
        if (owner.kind === 'graphic' && owner.shape !== null) throw new Error('그리기 개체 내부의 HWP 본문은 가져올 수 없습니다.')
        if (owner.kind === 'table' && owner.seen) {
          if (record.data.byteLength < cellBytes) throw new Error('HWP 셀 속성이 잘렸습니다.')
          owner.cells.push({ column: bytes.getUint16(8, true), row: bytes.getUint16(10, true), columns: bytes.getUint16(12, true), rows: bytes.getUint16(14, true) })
        }
        break
      case tag.table:
        if (!owner || owner.kind !== 'table' || owner.seen || record.data.byteLength < 18
          || parent?.tag !== tag.control || record.level !== owner.level + 1) throw new Error('HWP 표 속성이 없거나 겹칩니다.')
        owner.rows = bytes.getUint16(4, true); owner.columns = bytes.getUint16(6, true); owner.seen = true; owner.list = false
        // Reject axes the destination cannot import before Core expands cell spans into its logical grid.
        if (owner.rows > hwpxTableLimits.rows || owner.columns > hwpxTableLimits.columns) {
          throw new Error('HWP 표의 행·열 수가 가져오기 지원 범위를 넘습니다.')
        }
        break
      case tag.shape:
        if (!owner || owner.kind !== 'graphic' || owner.shape !== null || record.data.byteLength < 4
          || parent?.tag !== tag.control || record.level !== owner.level + 1) throw new Error('HWP 그리기 개체 속성이 올바르지 않습니다.')
        switch (bytes.getUint32(0, true)) {
          case 0x24706963: owner.shape = 'image'; break // $pic
          case 0x246F6C65: owner.shape = 'ole'; break // $ole
          default: throw new Error('지원하지 않는 원본 HWP 도형입니다.')
        }
        break
      case tag.ole: case tag.picture: {
        const type = record.tag === tag.ole ? 'ole' : 'image', offset = type === 'ole' ? oleReferenceOffset : pictureReferenceOffset, width = type === 'ole' ? 4 : 2
        if (!owner || owner.kind !== 'graphic' || owner.shape !== type || owner.seen || record.data.byteLength < offset + width
          || parent?.tag !== tag.shape || record.level !== owner.level + 2) throw new Error('HWP 그림 또는 OLE 참조가 올바르지 않습니다.')
        const id = type === 'ole' ? bytes.getUint32(offset, true) : bytes.getUint16(offset, true)
        if (!id || !binData[id - 1] || binData[id - 1]!.type !== type) throw new Error('HWP 그림 또는 OLE의 바이너리 참조가 없습니다.')
        owner.seen = true; break
      }
      case tag.page: case tag.footnoteStyle: case tag.pageBorder:
        if (!owner || owner.kind !== 'section' || parent?.tag !== tag.control || record.level !== owner.level + 1) throw new Error('HWP 레이아웃 속성의 소속이 올바르지 않습니다.')
        break
      default: throw new Error('지원하지 않는 원본 HWP 본문 레코드입니다.')
    }
  }
  while (paragraphStack.length) closeParagraph(paragraphStack.pop()!)
  while (controls.length) closeControl(controls.pop()!)
  if (!paragraphs) throw new Error('HWP 본문 문단이 없습니다.')
}
