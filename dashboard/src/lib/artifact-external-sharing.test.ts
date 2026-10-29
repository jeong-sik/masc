import { afterEach, beforeEach, expect, it } from 'vitest'
import { ArtifactExternalSharing, type ShareOutcome } from './artifact-external-sharing'
import { forgetPendingShare, retainPendingShare, type PendingShare } from './artifact-share-recovery'

const base = '/workspace'
const workspace = { basePath: base, mascRoot: `${base}/.masc` }
const id = `artifact-${'a'.repeat(32)}`
const record = (suffix = '000000000001', basePath = base): PendingShare => ({
  operation: { id, operationId: `01890e2a-4c8e-7b21-9f3c-${suffix}`, expectedVersion: 0, shared: true,
    expectedArtifactRevision: 1, expectedArtifactSha256: 'a'.repeat(64) },
  title: 'report', revision: 1, workspace: { basePath, mascRoot: `${basePath}/.masc` },
})
const outcome = (pending: PendingShare, kind: 'confirmed' | 'unconfirmed'): ShareOutcome => {
  const common = { id: pending.operation.id, title: pending.title, revision: pending.revision,
    requested: pending.operation.shared, operationId: pending.operation.operationId,
    expectedVersion: pending.operation.expectedVersion, operation: pending.operation, workspace: pending.workspace }
  return kind === 'confirmed' ? { ...common, kind, outcome: 'applied', shared: true, current: true }
    : { ...common, kind, detail: 'timeout', pending }
}
beforeEach(() => { localStorage.clear(); window.dispatchEvent(new StorageEvent('storage')) })
afterEach(() => { localStorage.clear(); window.dispatchEvent(new StorageEvent('storage')) })

it('retires reads begun before or during a share write, then admits a fresh read', () => {
  const shares = new ArtifactExternalSharing(), pending = record()
  const before = shares.observe(id, workspace)
  const owner = shares.begin(id, workspace, before)!
  shares.attachPending(id, workspace, owner, pending)
  const during = shares.observe(id, workspace)
  expect(shares.begin(id, workspace, during)).toBeNull()
  shares.finish(id, workspace, owner, outcome(pending, 'confirmed'))
  expect(shares.admits(before)).toBe(false)
  expect(shares.admits(during)).toBe(false)
  expect(shares.admits(shares.observe(id, workspace))).toBe(true)
})

it('keeps the exact uncertain operation after another tab removes its durable copy', () => {
  const shares = new ArtifactExternalSharing(), pending = record()
  const owner = shares.begin(id, workspace, shares.observe(id, workspace))!
  retainPendingShare(pending)
  shares.attachPending(id, workspace, owner, pending)
  shares.finish(id, workspace, owner, outcome(pending, 'unconfirmed'))
  forgetPendingShare(pending)
  expect(shares.activity(id, workspace)).toBe('unconfirmed')
  expect(shares.pendingInThisTab()).toEqual([pending])
  const recovery = shares.beginRecovery(pending)!
  shares.finish(id, workspace, recovery, outcome(pending, 'confirmed'))
  expect(shares.activity(id, workspace)).toBe('ready')
  expect(shares.receipts()).toEqual([outcome(pending, 'confirmed')])
})

it('keeps another unresolved operation and does not block a different workspace', () => {
  const shares = new ArtifactExternalSharing(), first = record(), second = record('000000000002')
  const firstOwner = shares.beginRecovery(first)!
  shares.finish(id, workspace, firstOwner, outcome(first, 'unconfirmed'))
  const secondOwner = shares.beginRecovery(second)!
  shares.finish(id, workspace, secondOwner, outcome(second, 'confirmed'))
  expect(shares.pendingInThisTab()).toEqual([first])
  expect(shares.activity(id, workspace)).toBe('unconfirmed')
  const other = { basePath: base, mascRoot: '/other-root' }
  expect(shares.activity(id, other)).toBe('ready')
  expect(shares.admits(shares.observe(id, other))).toBe(true)
})

it('permits a fresh observation when preparation ended before dispatch', () => {
  const shares = new ArtifactExternalSharing(), previous = shares.observe(id, workspace)
  const owner = shares.begin(id, workspace, previous)!
  shares.finish(id, workspace, owner, 'not-sent')
  expect(shares.admits(previous)).toBe(false)
  expect(shares.begin(id, workspace, shares.observe(id, workspace))).not.toBeNull()
})

it('keeps confirmed evidence when a redundant recheck times out', () => {
  const shares = new ArtifactExternalSharing(), first = record(), other = record('000000000002')
  const original = shares.beginRecovery(first)!
  shares.finish(id, workspace, original, outcome(first, 'confirmed'))
  retainPendingShare(first)
  const retry = shares.beginRecovery(first)!
  shares.finish(id, workspace, retry, outcome(first, 'unconfirmed'))
  expect(shares.receipts()).toEqual([outcome(first, 'confirmed')])
  expect(shares.activity(id, workspace)).toBe('ready')
  const otherOwner = shares.beginRecovery(other)!
  shares.finish(id, workspace, otherOwner, outcome(other, 'unconfirmed'))
  expect(shares.activity(id, workspace)).toBe('unconfirmed')
  expect(shares.pendingInThisTab()).toEqual([other])
})
