import { signal } from '@preact/signals'
import type { ArtifactShareOperation, ArtifactWorkspace } from '../api/published-artifacts'

export type PendingShare = {
  operation: ArtifactShareOperation
  workspace: ArtifactWorkspace
  title: string
  revision: number
}

const prefix = 'masc.artifact-share-operation.v1:'
const operationId = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const artifactId = /^artifact-[0-9a-f]{32}$/
const pending = signal<readonly PendingShare[]>([])

function decode(value: unknown): PendingShare | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null
  const record = value as Record<string, unknown>
  if (typeof record.operation !== 'object' || record.operation === null || Array.isArray(record.operation)
    || typeof record.workspace !== 'object' || record.workspace === null || Array.isArray(record.workspace)) return null
  const operation = record.operation as Record<string, unknown>
  const workspace = record.workspace as Record<string, unknown>
  if (typeof operation.id !== 'string' || !artifactId.test(operation.id)
    || typeof operation.operationId !== 'string' || !operationId.test(operation.operationId)
    || typeof operation.expectedVersion !== 'number' || !Number.isSafeInteger(operation.expectedVersion) || operation.expectedVersion < 0
    || typeof operation.expectedArtifactRevision !== 'number' || !Number.isSafeInteger(operation.expectedArtifactRevision) || operation.expectedArtifactRevision <= 0
    || typeof operation.expectedArtifactSha256 !== 'string' || !/^[0-9a-f]{64}$/.test(operation.expectedArtifactSha256)
    || typeof operation.shared !== 'boolean' || typeof record.title !== 'string'
    || typeof record.revision !== 'number' || !Number.isSafeInteger(record.revision) || record.revision <= 0
    || typeof workspace.basePath !== 'string' || !workspace.basePath.startsWith('/')
    || typeof workspace.mascRoot !== 'string' || !workspace.mascRoot.startsWith('/')) return null
  return { operation: { id: operation.id, operationId: operation.operationId,
    expectedVersion: operation.expectedVersion, shared: operation.shared,
    expectedArtifactRevision: operation.expectedArtifactRevision, expectedArtifactSha256: operation.expectedArtifactSha256 },
  workspace: { basePath: workspace.basePath, mascRoot: workspace.mascRoot },
  title: record.title, revision: record.revision }
}

function refresh(): void {
  const records: PendingShare[] = []
  try {
    for (let index = 0; index < localStorage.length; index++) {
      const key = localStorage.key(index)
      if (!key?.startsWith(prefix)) continue
      try {
        const record = decode(JSON.parse(localStorage.getItem(key) ?? 'null'))
        if (record && key === prefix + record.operation.operationId) records.push(record)
      } catch { /* Invalid storage is never dispatched. */ }
    }
  } catch { /* A new operation will be refused when storage cannot be written. */ }
  pending.value = records
}

export function pendingShares(): readonly PendingShare[] { return pending.value }

export function pendingShareIdentity(record: PendingShare): string {
  return JSON.stringify([record.workspace.basePath, record.workspace.mascRoot, record.operation.id,
    record.operation.operationId, record.operation.expectedVersion, record.operation.shared,
    record.operation.expectedArtifactRevision, record.operation.expectedArtifactSha256])
}

export function retainPendingShare(record: PendingShare): void {
  const decoded = decode(record)
  if (!decoded) throw new Error('외부 공유 요청을 보관할 수 없습니다.')
  const key = prefix + decoded.operation.operationId
  const text = JSON.stringify(decoded)
  try {
    const previous = localStorage.getItem(key)
    if (previous !== null && previous !== text) throw new Error('operation identity already exists')
    localStorage.setItem(key, text)
    if (localStorage.getItem(key) !== text) throw new Error('operation was not retained')
  } catch {
    refresh()
    throw new Error('브라우저에 공유 요청을 보관하지 못해 전송하지 않았습니다.')
  }
  refresh()
}

export function forgetPendingShare(record: PendingShare): void {
  const normalized = decode(record)
  if (!normalized) return
  const key = prefix + normalized.operation.operationId
  try {
    if (localStorage.getItem(key) === JSON.stringify(normalized)) localStorage.removeItem(key)
  } catch { /* A retained request can be checked again safely. */ }
  refresh()
}

refresh()
if (typeof window !== 'undefined') window.addEventListener('storage', refresh)
