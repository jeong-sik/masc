import { DOMParser, type Document, type Element, type Node } from '@xmldom/xmldom'
import JSZip from 'jszip'
import { SaxesParser } from 'saxes'
import { checkOfficeText } from './artifact-office-text'

// JSZip 3.10 exposes this streaming API but omits it from its bundled declarations.
declare module 'jszip' {
  interface JSZipObject { internalStream(type: 'uint8array'): JSZip.JSZipStreamHelper<Uint8Array> }
}

const mebibyte = 1024 * 1024
export const officeImportLimits = Object.freeze({ inputBytes: 32 * mebibyte, partBytes: 16 * mebibyte, totalBytes: 64 * mebibyte })
type ArchiveBudget = { bytes: number }
const archiveBudgets = new WeakMap<JSZip, ArchiveBudget>()

export async function loadOfficeArchive(data: ArrayBuffer | Uint8Array, parent?: JSZip): Promise<JSZip> {
  if (data.byteLength > officeImportLimits.inputBytes) throw new Error('가져올 문서는 32 MiB 이하여야 합니다.')
  const zip = await JSZip.loadAsync(data), budget = parent ? archiveBudgets.get(parent) : undefined
  archiveBudgets.set(zip, budget ?? { bytes: 0 })
  for (const file of Object.values(zip.files)) {
    if (file.unsafeOriginalName !== undefined && file.unsafeOriginalName !== file.name) throw new Error('문서에 압축 파일 밖을 가리키는 경로가 있습니다.')
  }
  return zip
}

export type OfficeXmlElement = Element
export type OfficeXmlDocument = Document
export const officeNs = {
  word: 'http://schemas.openxmlformats.org/wordprocessingml/2006/main',
  drawing: 'http://schemas.openxmlformats.org/drawingml/2006/main',
  chart: 'http://schemas.openxmlformats.org/drawingml/2006/chart',
  relationships: 'http://schemas.openxmlformats.org/officeDocument/2006/relationships',
  packageRelationships: 'http://schemas.openxmlformats.org/package/2006/relationships',
  spreadsheet: 'http://schemas.openxmlformats.org/spreadsheetml/2006/main',
} as const

export function xmlChildren(node: Node, namespace?: string, localName?: string): Element[] {
  return Array.from(node.childNodes).filter((child): child is Element => child.nodeType === 1
    && (namespace === undefined || (child as Element).namespaceURI === namespace)
    && (localName === undefined || (child as Element).localName === localName))
}

export function xmlChild(node: Node, namespace: string, localName: string): Element | undefined {
  const children = xmlChildren(node, namespace, localName)
  if (children.length > 1) throw new Error(`문서의 ${localName} 요소가 겹칩니다.`)
  return children[0]
}

export function xmlDescendants(node: Document | Element, namespace: string, localName: string): Element[] {
  return Array.from(node.getElementsByTagNameNS(namespace, localName))
}

export function parseOfficeXml(text: string, label: string): Document {
  checkOfficeText(text)
  // Check lexical XML and namespace identity before DOM construction can
  // overwrite attributes with the same expanded name but different prefixes.
  const parser = new SaxesParser({ xmlns: true, defaultXMLVersion: '1.0', forceXMLVersion: true, fileName: label })
  parser.on('error', error => { throw error })
  parser.on('doctype', () => { throw new Error(`${label}: DOCTYPE이 있는 문서는 가져올 수 없습니다.`) })
  parser.on('xmldecl', declaration => { if (declaration.version !== '1.0') throw new Error(`${label}: XML 1.0 문서가 필요합니다.`) })
  parser.write(text).close()
  // saxes owns well-formedness. xmldom builds the DOM and warns for valid U+FFFD;
  // that warning is not a syntax error. XML 1.0 only normalizes CR and CRLF.
  const document = new DOMParser({ normalizeLineEndings: source => source.replace(/\r\n?/g, '\n'), onError: (level, message) => {
    if (level === 'warning') return
    throw new Error(`${label}: ${message}`)
  } }).parseFromString(text, 'application/xml')
  if (!document.documentElement) throw new Error(`${label}: XML 본문이 없습니다.`)
  return document
}

export async function readOfficeXml(zip: JSZip, path: string): Promise<Document> {
  return parseOfficeXml(new TextDecoder('utf-8', { fatal: true }).decode(await readOfficeBytes(zip, path)), path)
}

export async function readOfficeBytes(zip: JSZip, path: string): Promise<Uint8Array> {
  const file = zip.file(path)
  if (!file || file.dir) throw new Error(`문서 내부 파일이 없습니다: ${path}`)
  // A repaired ZIP entry name must never turn a traversal target into an owned part.
  if (file.unsafeOriginalName !== undefined && file.unsafeOriginalName !== path) throw new Error(`문서 내부 경로가 올바르지 않습니다: ${path}`)
  const budget = archiveBudgets.get(zip) ?? { bytes: 0 }
  archiveBudgets.set(zip, budget)
  return new Promise((resolve, reject) => {
    const chunks: Uint8Array[] = [], stream = file.internalStream('uint8array')
    let bytes = 0, rejected = false
    stream.on('data', chunk => {
      if (rejected) return
      if (bytes + chunk.byteLength > officeImportLimits.partBytes || budget.bytes + chunk.byteLength > officeImportLimits.totalBytes) {
        rejected = true; stream.pause(); reject(new Error('문서 내부 파일 또는 전체 압축 해제 크기가 가져오기 한도를 넘습니다.')); return
      }
      bytes += chunk.byteLength; budget.bytes += chunk.byteLength; chunks.push(chunk)
    }).on('error', error => { rejected = true; reject(error) }).on('end', () => {
      if (rejected) return
      const output = new Uint8Array(bytes)
      let offset = 0
      for (const chunk of chunks) { output.set(chunk, offset); offset += chunk.byteLength }
      resolve(output)
    }).resume()
  })
}

/** Resolve OPC references inside the archive; this function never fetches a URL. */
export function resolveOfficePart(sourcePath: string, target: string): string {
  let decoded: string
  try { decoded = decodeURIComponent(target) } catch { throw new Error('문서 내부 참조의 인코딩이 올바르지 않습니다.') }
  if (!decoded || /[\\\u0000?#]/.test(decoded) || /^[a-z][a-z0-9+.-]*:/i.test(decoded) || decoded.startsWith('//')) {
    throw new Error(`문서 외부 파일을 읽을 수 없습니다: ${target}`)
  }
  const parts = decoded.startsWith('/') ? [] : sourcePath.split('/').slice(0, -1)
  for (const segment of decoded.split('/')) {
    if (!segment || segment === '.') continue
    if (segment === '..') {
      if (parts.length === 0) throw new Error('문서 내부 참조가 압축 파일 밖을 가리킵니다.')
      parts.pop()
    } else {
      if (segment.includes(':')) throw new Error('문서 내부 경로가 올바르지 않습니다.')
      parts.push(segment)
    }
  }
  if (parts.length === 0) throw new Error('문서 내부 참조가 파일을 가리키지 않습니다.')
  return parts.join('/')
}

export type OfficeRelationship = { readonly id: string; readonly type: string; readonly target: string; readonly external: boolean }
export async function readOfficeRelationships(zip: JSZip, sourcePath: string): Promise<ReadonlyMap<string, OfficeRelationship>> {
  const segments = sourcePath.split('/'), name = segments.pop()!
  const path = [...segments, '_rels', `${name}.rels`].join('/')
  if (!zip.file(path)) return new Map()
  const document = await readOfficeXml(zip, path), root = document.documentElement!
  if (root.namespaceURI !== officeNs.packageRelationships || root.localName !== 'Relationships') throw new Error('문서 관계 파일의 형식이 올바르지 않습니다.')
  const relationships = new Map<string, OfficeRelationship>()
  for (const element of xmlChildren(root)) {
    if (element.namespaceURI !== officeNs.packageRelationships || element.localName !== 'Relationship') throw new Error('알 수 없는 문서 관계입니다.')
    const id = element.getAttribute('Id'), type = element.getAttribute('Type'), target = element.getAttribute('Target'), mode = element.getAttribute('TargetMode')
    if (!id || !type || !target || (mode && mode !== 'Internal' && mode !== 'External') || relationships.has(id)) throw new Error('문서 관계가 누락되었거나 겹칩니다.')
    relationships.set(id, { id, type, target, external: mode === 'External' })
  }
  return relationships
}
