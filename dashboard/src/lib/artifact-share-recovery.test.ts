import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { forgetPendingShare, pendingShares, retainPendingShare, type PendingShare } from './artifact-share-recovery'

const record: PendingShare = {
  operation: { id: `artifact-${'a'.repeat(32)}`, operationId: '01890e2a-4c8e-7b21-9f3c-000000000031', expectedVersion: 3, shared: true,
    expectedArtifactRevision: 2, expectedArtifactSha256: 'a'.repeat(64) },
  workspace: { basePath: '/workspace', mascRoot: '/workspace/.masc' }, title: 'document', revision: 2,
}

beforeEach(() => { localStorage.clear(); window.dispatchEvent(new StorageEvent('storage')) })
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); localStorage.clear(); window.dispatchEvent(new StorageEvent('storage')) })

it('retains the exact workspace-bound operation across a storage refresh', () => {
  retainPendingShare(record)
  window.dispatchEvent(new StorageEvent('storage'))
  expect(pendingShares()).toEqual([record])
  forgetPendingShare(record)
  expect(pendingShares()).toEqual([])
})

it('refuses preparation when the operation cannot be retained', () => {
  vi.stubGlobal('localStorage', { length: 0, key: () => null, getItem: () => null,
    setItem: () => { throw new Error('quota') } })
  expect(() => retainPendingShare(record)).toThrow('전송하지 않았습니다')
  expect(pendingShares()).toEqual([])
})

it('does not dispatch malformed or identity-mismatched stored data', () => {
  localStorage.setItem('masc.artifact-share-operation.v1:other-id', JSON.stringify(record))
  window.dispatchEvent(new StorageEvent('storage'))
  expect(pendingShares()).toEqual([])
})
