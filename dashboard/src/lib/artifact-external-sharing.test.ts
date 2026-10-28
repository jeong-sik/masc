import { expect, it } from 'vitest'
import { ArtifactExternalSharing } from './artifact-external-sharing'

const receipt = (id: string) => ({ id, title: 'report', revision: 1, requested: true,
  workspace: { basePath: '/workspace', mascRoot: '/workspace/.masc' } })

it('retires reads begun before or during a share write, then admits a fresh read', () => {
  const shares = new ArtifactExternalSharing()
  const before = shares.observe('a')
  const owner = shares.begin('a', before)!
  const during = shares.observe('a')
  expect(shares.begin('a', during)).toBeNull()
  shares.finish('a', owner, { ...receipt('a'), kind: 'confirmed', outcome: 'applied', shared: true, current: true })
  expect(shares.admits(before)).toBe(false)
  expect(shares.admits(during)).toBe(false)
  expect(shares.admits(shares.observe('a'))).toBe(true)
})

it('retains an unconfirmed outcome for its artifact without blocking another', () => {
  const shares = new ArtifactExternalSharing()
  const owner = shares.begin('a', shares.observe('a'))!
  shares.finish('a', {}, { ...receipt('a'), kind: 'unconfirmed', detail: 'timeout' })
  expect(shares.activity('a')).toBe('pending')
  shares.finish('a', owner, { ...receipt('a'), kind: 'unconfirmed', detail: 'timeout' })
  expect(shares.activity('a')).toBe('unconfirmed')
  expect(shares.begin('a', shares.observe('a'))).toBeNull()
  expect(shares.admits(shares.observe('a'))).toBe(false)
  expect(shares.receipts()).toEqual([{ ...receipt('a'), kind: 'unconfirmed', detail: 'timeout' }])
  expect(shares.begin('b', shares.observe('b'))).not.toBeNull()
})

it('permits a fresh observation when preparation ended before dispatch', () => {
  const shares = new ArtifactExternalSharing()
  const previous = shares.observe('a')
  const owner = shares.begin('a', previous)!
  shares.finish('a', owner, 'not-sent')
  expect(shares.admits(previous)).toBe(false)
  expect(shares.begin('a', shares.observe('a'))).not.toBeNull()
})
