import { fetchVerifiedToolBlobText } from './verified-tool-blob'

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
  const [before, after] = await Promise.all([
    fetchVerifiedToolBlobText(refs.before, signal),
    fetchVerifiedToolBlobText(refs.after, signal),
  ])
  return { before, after }
}
