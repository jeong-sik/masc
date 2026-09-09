import { fetchToolBlob } from './tool-blob'

interface SnapshotRef { readonly sha256: string; readonly bytes: number }
export interface EditSnapshots { readonly before: SnapshotRef; readonly after: SnapshotRef }
export type EditSnapshotReceipt =
  | ({ readonly status: 'stored' } & EditSnapshots)
  | { readonly status: 'unavailable'; readonly detail: string }

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown> : null
}

function snapshotRef(value: unknown): SnapshotRef | null {
  const blob = record(record(value)?._blob)
  if (!blob || typeof blob.sha256 !== 'string' || blob.sha256.length !== 64
      || !Array.from(blob.sha256).every(c => '0123456789abcdef'.includes(c))
      || typeof blob.bytes !== 'number' || !Number.isSafeInteger(blob.bytes) || blob.bytes < 0) return null
  return { sha256: blob.sha256, bytes: blob.bytes }
}

export function parseEditSnapshots(value: unknown): EditSnapshotReceipt | null {
  const source = record(value)
  if (source?.status === 'unavailable') {
    return typeof source.detail === 'string' ? { status: 'unavailable', detail: source.detail } : null
  }
  if (source?.status !== 'stored') return null
  const before = snapshotRef(source.before)
  const after = snapshotRef(source.after)
  return before && after ? { status: 'stored', before, after } : null
}

// JSON transport must round-trip the stored bytes before claiming exact text.
// Invalid UTF-8 or corrupt/mismatched responses remain explicit failures.
export async function fetchEditSnapshots(refs: EditSnapshots, signal?: AbortSignal) {
  const subtle = globalThis.crypto?.subtle
  if (!subtle) {
    throw new Error('이 브라우저 환경에서는 편집 원본의 바이트를 검증할 수 없습니다. HTTPS 또는 localhost에서 다시 열어 주세요.')
  }
  async function read(ref: SnapshotRef): Promise<string> {
    const response = await fetchToolBlob(ref.sha256, { signal })
    if (typeof response.content !== 'string') throw new Error('편집 원본 응답에 텍스트가 없습니다.')
    const bytes = new TextEncoder().encode(response.content)
    const digest = await subtle.digest('SHA-256', bytes)
    const hash = Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('')
    if (response.sha256 !== ref.sha256 || response.bytes !== ref.bytes
        || bytes.byteLength !== ref.bytes || hash !== ref.sha256) {
      throw new Error('편집 원본의 바이트 검증에 실패했습니다. 텍스트로 표시할 수 없는 파일이거나 저장된 참조와 응답이 다릅니다.')
    }
    return response.content
  }
  const [before, after] = await Promise.all([read(refs.before), read(refs.after)])
  return { before, after }
}
