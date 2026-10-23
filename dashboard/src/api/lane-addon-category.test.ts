import { describe, expect, it } from 'vitest'
import { LANE_ADDON_CATEGORIES } from './lane-addon-category'
import { parseLaneAddonSnapshot } from './lane-addons'
import { parseLaneInventory } from './lane-inventory'
import { parseLanePackageCatalog, parseLanePackagePreview } from './lane-package-catalog'
import fixture from './fixtures/lane-inventory.json'

const declaration = { id: 'custom', source_path: '/workspace/custom.toml', enabled: true,
  source_revision: 'file', desired_revision: 'inputs', applied_revision: 'inputs', instance_id: 'original',
  application: { kind: 'applied', instance_id: 'original' } }
const worker = { instance_id: 'original', incarnation: 'original', run_id: 'run', addon_id: 'arbitrary',
  title: 'Unrelated title', revision: '1', runtime_presence: 'live', action_schema: null,
  package: { outputs: {}, binding_schema: null, presentation: { description: null, readings: [] } },
  configuration: { id: declaration.id, source_path: declaration.source_path, revision: 'inputs' },
  phase: { kind: 'attached' }, observation_seq: 0, rows_count: 0 }
const inspection = { configuration: { directory: '/workspace', complete: true, issues: [], declarations: [declaration] },
  instances: [worker], rows: [], coverage: [] }
const inventoryRow = { id: 'declaration//workspace/custom.toml', label: 'custom', purpose: 'fixture',
  selection: { kind: 'declaration', source_path: declaration.source_path },
  state: { kind: 'package', declaration: { kind: 'valid', enabled: true, installation_id: declaration.id,
    run_id: 'run', package_id: 'arbitrary', title: 'Unrelated title', desired_revision: 'inputs',
    source_revision: 'file', exact_outputs: [], application: declaration.application }, instances: [] } }
const catalogEntry = { kind: 'package', manifest_path: '/workspace/pkg/lane.toml', title: 'Unrelated title',
  revision: '1', description: null }
const catalog = { directory: '/workspace', parent: null, entries: [catalogEntry] }
const preview = { manifest_path: catalogEntry.manifest_path, package: { title: 'Unrelated title', revision: '1', binding_schema: null },
  execution: { kind: 'host_process' } }

describe('declared Addon role at actual API boundaries', () => {
  it('keeps current and original categories independently through Inspect', () => {
    const parsed = parseLaneAddonSnapshot({ ...inspection,
      configuration: { ...inspection.configuration, declarations: [{ ...declaration, ui_category: 'browser' }] },
      instances: [{ ...worker, package: { ...worker.package, ui_category: 'analysis' } }] })
    expect(parsed.configuration?.declarations[0]?.ui_category).toBe('browser')
    expect(parsed.instances[0]?.package.ui_category).toBe('analysis')
    expect(parsed.instances[0]?.configuration).toEqual(worker.configuration)
  })
  it.each(LANE_ADDON_CATEGORIES)('retains explicit %s across catalog, preview and common inventory', category => {
    expect(parseLanePackageCatalog({ ...catalog, entries: [{ ...catalogEntry, ui_category: category }] }).entries[0])
      .toMatchObject({ ui_category: category, manifest_path: catalogEntry.manifest_path })
    expect(parseLanePackagePreview({ ...preview, package: { ...preview.package, ui_category: category } }).package.ui_category).toBe(category)
    const parsed = parseLaneInventory({ ...fixture, rows: [...fixture.rows,
      { ...inventoryRow, state: { ...inventoryRow.state, declaration: { ...inventoryRow.state.declaration, ui_category: category } } }] })
    expect(parsed.rows.at(-1)?.state).toMatchObject({ declaration: { ui_category: category, installation_id: declaration.id } })
  })
  it('accepts omission alone and refuses invalid values instead of losing the role', () => {
    expect(parseLanePackagePreview(preview).package).not.toHaveProperty('ui_category')
    expect(parseLanePackageCatalog(catalog).entries[0]).not.toHaveProperty('ui_category')
    expect(parseLaneAddonSnapshot(inspection).instances[0]?.package).not.toHaveProperty('ui_category')
    for (const value of [null, undefined, 'unknown', '', ' browser', true, [], {}]) {
      expect(() => parseLanePackagePreview({ ...preview, package: { ...preview.package, ui_category: value } })).toThrow()
      expect(() => parseLanePackageCatalog({ ...catalog, entries: [{ ...catalogEntry, ui_category: value }] })).toThrow()
      expect(() => parseLaneAddonSnapshot({ ...inspection,
        configuration: { ...inspection.configuration, declarations: [{ ...declaration, ui_category: value }] } })).toThrow()
      expect(() => parseLaneAddonSnapshot({ ...inspection,
        instances: [{ ...worker, package: { ...worker.package, ui_category: value } }] })).toThrow()
      expect(() => parseLaneInventory({ ...fixture, rows: [...fixture.rows,
        { ...inventoryRow, state: { ...inventoryRow.state, declaration: { ...inventoryRow.state.declaration, ui_category: value } } }] })).toThrow()
    }
  })
})
