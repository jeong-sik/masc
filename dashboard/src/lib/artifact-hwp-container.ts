import { Inflate } from 'fflate'
import { officeImportLimits } from './artifact-office-xml'
import { readHwpDocInfo, checkHwpBody } from './artifact-hwp-records'
import { readHwpCompoundStreams } from './artifact-hwp-compound'
import type { HwpCompoundStreams } from './artifact-hwp-compound-paths'

//HIGH-RISK-UNREVIEWED: Bounds and references are checked before the native parser sees untrusted HWP bytes.
const hwpSignature = new TextEncoder().encode('HWP Document File')
const fileHeaderBytes = 256, signatureBytes = 32, compressedFlag = 1
const protectedFlags = 0x02 | 0x04 | 0x10 | 0x100 | 0x400 | 0x2000
const inflateInputBytes = 1024
type Budget = { bytes: number }

function checkSize(size: number, budget: Budget): void {
  if (size > officeImportLimits.partBytes || budget.bytes + size > officeImportLimits.totalBytes) {
    throw new Error('HWP 내부 파일 또는 전체 압축 해제 크기가 가져오기 한도를 넘습니다.')
  }
  budget.bytes += size
}

/** CFB paths retain their exact case and hierarchy; only the root storage name is removed. */
export function readHwpCompound(data: Uint8Array, label: string): HwpCompoundStreams {
  return readHwpCompoundStreams(data, label)
}

function required(streams: HwpCompoundStreams, path: string): Uint8Array {
  const bytes = streams.lookup(path)
  if (bytes === undefined) throw new Error(`HWP 내부 파일이 없습니다: ${path}`)
  return bytes
}

function expand(data: Uint8Array, compressed: boolean, budget: Budget): Uint8Array {
  if (!compressed) { checkSize(data.byteLength, budget); return data }
  let size = 0, final = false
  const chunks: Uint8Array[] = [], inflate = new Inflate((chunk, end) => {
    if (size + chunk.byteLength > officeImportLimits.partBytes) throw new Error('HWP 압축 파일이 파트 크기 한도를 넘습니다.')
    checkSize(chunk.byteLength, budget)
    size += chunk.byteLength; chunks.push(chunk); final = end
  })
  for (let offset = 0; offset < data.byteLength; offset += inflateInputBytes) {
    inflate.push(data.subarray(offset, offset + inflateInputBytes), offset + inflateInputBytes >= data.byteLength)
  }
  if (!final) throw new Error('HWP 압축 스트림이 끝나지 않았습니다.')
  const output = new Uint8Array(size)
  let offset = 0
  for (const chunk of chunks) { output.set(chunk, offset); offset += chunk.byteLength }
  return output
}

/** Validate container, expansion bounds and original record inventory before invoking WASM. */
export function preflightArtifactHwp(data: Uint8Array): void {
  const streams = readHwpCompound(data, 'HWP'), header = required(streams, 'FileHeader')
  if (header.byteLength !== fileHeaderBytes || !hwpSignature.every((byte, index) => header[index] === byte)
    || header.subarray(hwpSignature.length, signatureBytes).some(byte => byte !== 0) || header[35] !== 5) throw new Error('HWP5 문서의 FileHeader가 올바르지 않습니다.')
  const view = new DataView(header.buffer, header.byteOffset, header.byteLength), flags = view.getUint32(36, true)
  if ((flags & protectedFlags) !== 0) throw new Error('암호·DRM·배포 HWP 문서는 가져올 수 없습니다.')
  const compressed = (flags & compressedFlag) !== 0, budget = { bytes: 0 }, docInfo = required(streams, 'DocInfo')
  const consumed = new Set([header, docInfo]), binaryPaths = new Set(streams.pathsInStorage('BinData'))
  checkSize(header.byteLength, budget)
  const info = readHwpDocInfo(expand(docInfo, compressed, budget))
  const sections = streams.pathsInStorage('BodyText')
  if (sections.length !== info.sectionCount) throw new Error('HWP 구역 수와 본문 스트림이 일치하지 않습니다.')
  for (let index = 0; index < info.sectionCount; index++) {
    const path = `BodyText/Section${index}`
    const bytes = required(streams, path)
    checkHwpBody(expand(bytes, compressed, budget), info.binData)
    consumed.add(bytes)
  }
  const bound = new Set<Uint8Array>()
  for (const item of info.binData) {
    const path = `BinData/BIN${item.storageId.toString(16).toUpperCase().padStart(4, '0')}.${item.extension}`
    const bytes = required(streams, path)
    if (bound.has(bytes)) throw new Error('HWP 바이너리 참조가 겹칩니다.')
    bound.add(bytes); consumed.add(bytes)
    expand(bytes, item.compression === 'compressed' || (item.compression === 'default' && compressed), budget)
  }
  for (const [path, bytes] of streams) if (!consumed.has(bytes)) {
    if (binaryPaths.has(path)) throw new Error('HWP 바이너리 스트림의 압축 속성 참조가 없습니다.')
    checkSize(bytes.byteLength, budget)
  }
}
