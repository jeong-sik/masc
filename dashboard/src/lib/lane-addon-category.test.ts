import { describe, expect, it } from 'vitest'
import { parseLaneAddonSnapshot } from '../api/lane-addons'
import { parseLaneInventory } from '../api/lane-inventory'
import fixture from '../api/fixtures/lane-inventory.json'
import { categoryGroup, groupAddonCategories, inventoryCategory, workerCategory } from './lane-addon-category'
import { laneTargetFor } from './lane-navigation'

const current = { id: 'neutral', source_path: '/workspace/neutral.toml', enabled: true,
  source_revision: 'file', desired_revision: 'inputs', applied_revision: 'inputs', instance_id: 'original',
  ui_category: 'browser', application: { kind: 'applied', instance_id: 'original' } }
const original = { instance_id: 'original', incarnation: 'original', run_id: 'run', addon_id: 'voice-browser-memory',
  title: 'Names are not categories', revision: '1', runtime_presence: 'live', action_schema: null,
  package: { ui_category: 'analysis', outputs: {}, binding_schema: null, presentation: { description: null, readings: [] } },
  configuration: { id: current.id, source_path: current.source_path, revision: 'inputs' },
  phase: { kind: 'attached' }, observation_seq: 0, rows_count: 0 }
const inspection = { configuration: { directory: '/workspace', complete: true, issues: [], declarations: [current] },
  instances: [original], rows: [], coverage: [] }
const row = { id: `declaration/${current.source_path}`, label: 'Names are not categories', purpose: 'fixture',
  selection: { kind: 'declaration', source_path: current.source_path },
  state: { kind: 'package', declaration: { kind: 'valid', enabled: true, installation_id: current.id,
    run_id: 'run', package_id: 'voice-browser-memory', title: 'Names are not categories', desired_revision: 'inputs',
    ui_category: 'browser', source_revision: 'file', exact_outputs: [], application: current.application },
  instances: [{ instance_id: 'original', incarnation: 'original', run_id: 'run', package_id: 'voice-browser-memory',
    title: 'Names are not categories', package_revision: '1', ui_category: 'analysis', presence: 'live',
    phase: { kind: 'attached' }, applied_revision: 'inputs' }] } }

describe('category ownership and stable navigation', () => {
  it('groups built-in routes by the server role while preserving their original navigation targets', () => {
    const rows = parseLaneInventory(fixture).rows
    for (const row of rows) {
      const before = laneTargetFor(row, '/workspace')
      const groups = groupAddonCategories([row], inventoryCategory)
      expect(groups.flatMap(group => group.items)).toEqual([row])
      expect(laneTargetFor(groups[0]!.items[0]!, '/workspace')).toEqual(before)
      expect(inventoryCategory(row)).toBe(row.ui_category)
    }
  })
  it('uses supplied builtin display metadata without changing the original navigation target', () => {
    const browser = fixture.rows.find(row => row.id === 'browser/live')!
    const read = (row: unknown) => parseLaneInventory({ ...fixture,
      rows: fixture.rows.map(original => original.id === browser.id ? row : original) }).rows.find(row => row.id === browser.id)!
    const original = read(browser), reclassified = read({ ...browser, ui_category: 'analysis' })
    expect(inventoryCategory(reclassified)).toBe('analysis')
    expect(laneTargetFor(reclassified, '/workspace')).toEqual(laneTargetFor(original, '/workspace'))
    expect(reclassified.state).toEqual(original.state)
    const { ui_category: _role, ...withoutRole } = browser
    expect(inventoryCategory(read(withoutRole))).toBe('unclassified')
    for (const ui_category of [null, 'unknown', 1]) {
      expect(() => read({ ...browser, ui_category })).toThrow()
    }
  })
  it('uses the exact current owner for live workers and preserves retained originals', () => {
    const parsed = parseLaneAddonSnapshot(inspection), worker = parsed.instances[0]!
    expect(workerCategory(parsed, worker)).toBe('browser')
    expect(workerCategory(parsed, { ...worker, runtime_presence: 'retained' })).toBe('analysis')
    const configuration = parsed.configuration!
    const declaration = configuration.declarations[0]!
    for (const declarations of [[], [{ ...declaration, source_path: '/workspace/renamed.toml' }],
      [{ ...declaration, id: 'other' }], [declaration, declaration]]) {
      expect(workerCategory({ ...parsed, configuration: { ...configuration, declarations } }, worker)).toBe('unavailable')
    }
    expect(workerCategory({ ...parsed, configuration: { ...configuration, complete: false } }, worker)).toBe('unavailable')
    const { ui_category: _category, ...unclassified } = declaration
    expect(workerCategory({ ...parsed, configuration: { ...configuration, declarations: [unclassified] } }, worker)).toBe('unclassified')
    expect(worker.package.ui_category).toBe('analysis')
  })
  it('does not borrow historical roles when a current declaration is invalid, absent or unread', () => {
    for (const declaration of [{ kind: 'invalid', messages: ['invalid manifest'] }, { kind: 'absent' }, { kind: 'unobserved' }]) {
      const parsed = parseLaneInventory({ ...fixture, rows: [...fixture.rows, { ...row, state: { ...row.state, declaration } }] })
      expect(inventoryCategory(parsed.rows.at(-1)!)).toBe('unavailable')
    }
    expect(categoryGroup(undefined)).toBe('unclassified')
  })
  it('regroups the same declaration without changing its real navigation target or selecting a replacement', () => {
    const parse = (category: string) => parseLaneInventory({ ...fixture, rows: [...fixture.rows,
      { ...row, state: { ...row.state, declaration: { ...row.state.declaration, ui_category: category } } }] }).rows.at(-1)!
    const originalRow = parse('browser'), changedRow = parse('voice_media')
    const target = laneTargetFor(originalRow, '/workspace')
    const groups = groupAddonCategories([changedRow], inventoryCategory, 'voice_media')
    expect(groups[0]?.items[0]).toBe(changedRow)
    expect(laneTargetFor(groups[0]!.items[0]!, '/workspace')).toEqual(target)
    expect(groupAddonCategories([changedRow], inventoryCategory, 'browser')).toEqual([])
    expect(laneTargetFor(changedRow, '/workspace')).toEqual({ workspace: '/workspace', kind: 'declaration',
      path: current.source_path, installation: current.id })
  })
})
