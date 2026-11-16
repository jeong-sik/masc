import { validateHwpCompoundGraph } from './artifact-hwp-compound-graph'
import { officeImportLimits } from './artifact-office-xml'
import { hwpCompoundNameKey, indexHwpCompoundStreams, type HwpCompoundStreams } from './artifact-hwp-compound-paths'

//HIGH-RISK-UNREVIEWED: Copy only validated stream chains, after checking allocation budgets.
/** Return exact relative stream paths and bytes; no CFB library reader or script execution. */
export function readHwpCompoundStreams(data: Uint8Array, label: string): HwpCompoundStreams {
  if (data.byteLength > officeImportLimits.inputBytes) throw new Error('가져올 문서는 32 MiB 이하여야 합니다.')
  const layout = validateHwpCompoundGraph(data), decoder = new TextDecoder('utf-16le', { fatal: true, ignoreBOM: true })
  const name = (location: { readonly offset: number; readonly bytes: number }): string => {
    const value = decoder.decode(data.subarray(location.offset, location.offset + location.bytes))
    if (!value || value === '.' || value === '..' || /[\/\\:!\u0000]/.test(value)) throw new Error(`${label}: CFB 경로가 올바르지 않습니다.`)
    return value
  }
  name(layout.rootName)
  const names = new Map<number, string>(), siblings = new Map<number, Set<string>>(), pathBytes = new Map([[0, 0]])
  let bytes = 0
  // Check the complete inventory before allocating any logical stream buffer.
  for (const entry of layout.entries) {
    const value = name(entry.name), key = hwpCompoundNameKey(value), children = siblings.get(entry.parent) ?? new Set<string>()
    if (children.has(key)) throw new Error(`${label}: CFB 경로가 겹칩니다.`)
    children.add(key); siblings.set(entry.parent, children); names.set(entry.id, value)
    const fullPathBytes = pathBytes.get(entry.parent)! + (entry.parent === 0 ? 0 : 2) + entry.name.bytes
    pathBytes.set(entry.id, fullPathBytes)
    if (entry.kind === 'stream') {
      // Count the returned key's UTF-16 bytes, including '/', before joining it.
      if (entry.size > officeImportLimits.partBytes || bytes + entry.size + fullPathBytes > officeImportLimits.totalBytes) {
        throw new Error('HWP 내부 파일 또는 전체 압축 해제 크기가 가져오기 한도를 넘습니다.')
      }
      bytes += entry.size + fullPathBytes
    }
  }
  const streams = new Map<string, Uint8Array>(), components: string[] = []
  for (const entry of layout.entries) {
    components.length = entry.depth - 1; components.push(names.get(entry.id)!)
    if (entry.kind === 'storage') continue
    const output = new Uint8Array(entry.size), chunkBytes = entry.allocation === 'mini' ? layout.miniSectorBytes : layout.sectorBytes
    let copied = 0
    for (const sector of entry.sectors) {
      const length = Math.min(chunkBytes, output.byteLength - copied)
      if (length === 0) break
      const miniOffset = sector * layout.miniSectorBytes
      const offset = entry.allocation === 'fat' ? (sector + 1) * layout.sectorBytes
        : (layout.miniStreamSectors[Math.floor(miniOffset / layout.sectorBytes)]! + 1) * layout.sectorBytes + miniOffset % layout.sectorBytes
      output.set(data.subarray(offset, offset + length), copied); copied += length
    }
    streams.set(components.join('/'), output)
  }
  return indexHwpCompoundStreams(streams)
}
