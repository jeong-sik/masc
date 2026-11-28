import { describe, expect, it } from 'vitest'
import {
  decodePresetDeleted,
  decodePresetListing,
  decodePresetRestored,
  decodePresetSaved,
  decodePresetShow,
  isValidPresetName,
} from './presets-wire'
import { committedRuntime, listing, manifest, restored, show } from './presets-wire.test-fixture'

describe('presets at the wire boundary', () => {
  it('reads the listing, unreadable directories included', () => {
    const decoded = decodePresetListing(listing(['default', '_autosave'], [{ name: 'broken', reason: 'manifest.json: invalid JSON' }]))
    expect(decoded.presets.map(p => p.name)).toEqual(['default', '_autosave'])
    expect(decoded.unreadable).toEqual([{ name: 'broken', reason: 'manifest.json: invalid JSON' }])
  })

  it('reads a preset with lane settings it did not record, removes or sets', () => {
    const decoded = decodePresetShow(show('default'))
    const [recorded, removed] = decoded.preset.lanes
    expect(recorded?.max_output_tokens).toBe(4096)
    expect(recorded && 'thinking' in recorded).toBe(false)
    expect(removed?.thinking).toBeNull()
    expect(decoded.saved_settings).toEqual({ status: 'differs' })
  })

  it('refuses words it does not know', () => {
    expect(() => decodePresetShow(show('default', { saved_settings: { status: 'stale' } }))).toThrow()
    expect(() => decodePresetShow(show('default', { saved_settings: { status: 'unavailable' } }))).toThrow()
    expect(() => decodePresetShow(show('default', { default_prompts: { status: 'differs' } }))).toThrow()
    expect(() => decodePresetListing({ ok: true, presets: [] })).toThrow()
    expect(() => decodePresetRestored(restored('default', { status: 'partial' }))).toThrow()
  })

  it('reads a restore report, a committed runtime with its warnings included', () => {
    const plain = decodePresetRestored(restored('default'))
    expect(plain.report.runtime).toEqual({ status: 'unchanged' })
    expect(plain.report.instructions.skipped).toEqual([{ key: 'muse', reason: 'keeper TOML not found' }])
    const committed = decodePresetRestored(restored('default', committedRuntime)).report.runtime
    if (committed.status !== 'committed') throw new Error(`expected committed, got ${committed.status}`)
    expect(committed.commit.durability).toBe('unconfirmed')
    expect(committed.commit.warnings).toEqual([{ code: 'lock_release_unconfirmed', detail: 'flock release returned EIO' }])
    expect(committed.exact_output_registry.status).toBe('unpublished')
  })

  it('reads the save and delete answers and refuses ok:false', () => {
    expect(decodePresetSaved({ ok: true, preset: manifest('night') }).preset.name).toBe('night')
    expect(decodePresetDeleted({ ok: true, deleted: 'night' }).deleted).toBe('night')
    expect(() => decodePresetSaved({ ok: false, error: 'preset night already exists' })).toThrow()
  })

  it('accepts the names the server accepts', () => {
    expect(['default', 'before-2026.10.07', '_autosave'].every(isValidPresetName)).toBe(true)
    expect(['', '.', '..', 'a b', 'a/b', '한글'].some(isValidPresetName)).toBe(false)
  })
})
