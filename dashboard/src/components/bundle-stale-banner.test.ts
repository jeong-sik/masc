import { describe, expect, it } from 'vitest'
import { bundleStaleBannerModel, worktreeServerBannerModel } from './bundle-stale-banner'

// The banner's whole contract lives in the model: when the server's own
// dashboard_surface verdict warrants a strip, what it says, and — just as
// load-bearing — when it stays silent.

describe('bundleStaleBannerModel', () => {
  it('names different sources without guessing which is older', () => {
    const model = bundleStaleBannerModel({
      status: 'mismatched', dashboard_source_commit: 'aaaa', binary_source_commit: 'bbbb',
    })
    expect(model?.message).toContain('aaaa')
    expect(model?.message).toContain('bbbb')
    expect(model?.message).not.toContain('낡')
    expect(model?.nextAction).toContain('CI')
    expect(model?.nextAction).not.toContain('pnpm')
  })
  it('keeps unknown provenance separate from missing assets', () => {
    expect(bundleStaleBannerModel({ status: 'unknown' })?.message).toContain('빌드 소스')
    expect(bundleStaleBannerModel({ status: 'missing' })?.message).toContain('아티팩트')
    expect(bundleStaleBannerModel({ status: 'unavailable' })?.message).toContain('검증')
  })
  it('stays silent for matching source and no verdict', () => {
    expect(bundleStaleBannerModel({ status: 'ok', source_provenance: 'declared_build_source' })).toBeNull()
    expect(bundleStaleBannerModel(undefined)).toBeNull()
    expect(bundleStaleBannerModel(null)).toBeNull()
  })
})

describe('worktreeServerBannerModel', () => {
  it('warns with the executable path when the server runs from a worktree', () => {
    const model = worktreeServerBannerModel({
      executable_in_worktree: true,
      executable_path: '/x/masc/.worktrees/feat/a/_build/default/bin/main_eio.exe',
    })
    expect(model).not.toBeNull()
    expect(model!.message).toContain('worktree')
    expect(model!.path).toContain('.worktrees')
  })

  it('stays silent on the root build and on no verdict', () => {
    expect(worktreeServerBannerModel({ executable_in_worktree: false })).toBeNull()
    expect(worktreeServerBannerModel({})).toBeNull()
    expect(worktreeServerBannerModel(null)).toBeNull()
    expect(worktreeServerBannerModel(undefined)).toBeNull()
  })
})
