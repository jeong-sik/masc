import { describe, expect, it } from 'vitest'
import { parseLaneInventory } from './lane-inventory'
import fixture from './fixtures/lane-inventory.json'

describe('common Lane inventory wire', () => {
  it('preserves each installation output model reading independently of worker presence', () => {
    const exact_outputs = [
      { output: 'classification', source: 'declared', configuration: { kind: 'configured',
        admitted_slots: ['local.first'], cli_slots: ['cloud.cli'], declared_slots: ['local.first', 'unavailable'],
        declared_cli_slots: ['cloud.cli'], dropped_slots: ['unavailable'], admission_error: 'one runtime refused' } },
      { output: 'briefing', source: 'declared', configuration: { kind: 'unavailable', detail: 'registry unreadable' } },
      { output: 'removed-output', source: 'table_only', configuration: { kind: 'off',
        declared_slots: ['retained.model'], declared_cli_slots: [] } },
    ]
    const row = {
      id: 'declaration//fixture/curator.toml', label: 'curator.toml', purpose: 'Curator',
      selection: { kind: 'declaration', source_path: '/fixture/curator.toml' },
      state: { kind: 'package', instances: [], declaration: { kind: 'valid', enabled: false,
        installation_id: 'custom-curator', run_id: 'scope-not-observation', package_id: 'workspace-curator',
        title: 'Curator', source_revision: 'source', desired_revision: 'desired',
        application: { kind: 'inactive' }, exact_outputs } },
    }
    const parsed = parseLaneInventory({ ...fixture, rows: [...fixture.rows, row] })
    expect(parsed.rows.at(-1)?.state).toMatchObject({ instances: [], declaration: {
      installation_id: 'custom-curator', run_id: 'scope-not-observation', exact_outputs,
    } })
    const withOutputs = (outputs: unknown) => ({ ...fixture, rows: [...fixture.rows,
      { ...row, state: { ...row.state, declaration: { ...row.state.declaration, exact_outputs: outputs } } }] })
    for (const invalid of [undefined, null, [exact_outputs[0], exact_outputs[0]],
      [{ ...exact_outputs[0], source: 'inferred' }], [{ ...exact_outputs[0], output: '' }],
      [{ ...exact_outputs[0], configuration: { kind: 'ready' } }],
    ]) expect(() => parseLaneInventory(withOutputs(invalid))).toThrow()
  })
  it('retains host application independently of worker counts and rejects contradictory activity', () => {
    const row = (enabled: boolean, application: unknown) => ({
      id: 'declaration//fixture/off.toml', label: 'Off package', purpose: 'Observed application',
      selection: { kind: 'declaration', source_path: '/fixture/off.toml' },
      state: { kind: 'package', instances: [], declaration: { kind: 'valid', enabled,
        installation_id: 'off', run_id: 'world', package_id: 'observer', title: 'Observer',
        source_revision: 'file-bytes', desired_revision: 'desired', exact_outputs: [], application } },
    })
    const parse = (enabled: boolean, application: unknown) =>
      parseLaneInventory({ ...fixture, rows: [...fixture.rows, row(enabled, application)] })
    for (const application of [
      { kind: 'inactive' }, { kind: 'cleaning' },
      { kind: 'failed', messages: ['cleanup refused'] },
      { kind: 'unknown', messages: ['not observed'] },
    ]) {
      expect(parse(false, application).rows.at(-1)?.state).toMatchObject({
        instances: [], declaration: { source_revision: 'file-bytes', application },
      })
    }
    expect(() => parse(false, { kind: 'applied', instance_id: 'old' })).toThrow()
    expect(() => parse(true, { kind: 'inactive' })).toThrow()
    expect(() => parse(false, { kind: 'unknown', messages: [] })).toThrow()
    expect(() => parse(false, undefined)).toThrow()
    expect(() => parse(false, { kind: 'missing-worker-means-clean' })).toThrow()
  })
  it('keeps every machine activity independent of publication and rejects missing or malformed activity', () => {
    for (const id of ['machine/msx', 'machine/dos']) {
      for (const activity of ['on', 'off', 'unobserved']) {
        for (const publication of ['no_screen', 'stable', 'running']) {
          const raw = structuredClone(fixture)
          Object.assign(raw.rows.find(item => item.id === id)!.state, { activity, publication })
          expect(parseLaneInventory(raw).rows.find(item => item.id === id)?.state)
            .toEqual({ kind: 'machine', activity, publication })
        }
      }
      for (const activity of [undefined, null, true, 'enabled', '', 1]) {
        const raw = structuredClone(fixture)
        Object.assign(raw.rows.find(item => item.id === id)!.state, { activity })
        expect(() => parseLaneInventory(raw)).toThrow()
      }
      const raw = structuredClone(fixture)
      Reflect.deleteProperty(raw.rows.find(item => item.id === id)!.state, 'activity')
      expect(() => parseLaneInventory(raw)).toThrow()
    }
  })
  it('reads the browser Add-on reading and refuses an unknown one', () => {
    const read = (addon: unknown) => {
      const raw = structuredClone(fixture)
      Object.assign(raw.rows.find(item => item.id === 'browser/live')!.state, { addon })
      return parseLaneInventory(raw).rows.find(item => item.id === 'browser/live')?.state
    }
    expect(read({ kind: 'absent' })).toEqual({ kind: 'browser_clients', activity: 'on', addon: { kind: 'absent' } })
    expect(read({ kind: 'off' })).toEqual({ kind: 'browser_clients', activity: 'on', addon: { kind: 'off' } })
    expect(read({ kind: 'not_running' })).toEqual({ kind: 'browser_clients', activity: 'on', addon: { kind: 'not_running' } })
    expect(read({ kind: 'unavailable', detail: 'worker failed' }))
      .toEqual({ kind: 'browser_clients', activity: 'on', addon: { kind: 'unavailable', detail: 'worker failed' } })
    expect(() => read({ kind: 'maybe' })).toThrow()
    expect(() => read({ kind: 'observed' })).toThrow()
  })
  it('preserves browser activity independently of registration and requires an explicit observation', () => {
    for (const activity of ['on', 'off', 'unobserved']) {
      const raw = structuredClone(fixture)
      const row = raw.rows.find(item => item.id === 'browser/automation')!
      Object.assign(row.state, { activity, addon: { kind: 'observed', registered: true } })
      expect(parseLaneInventory(raw).rows.find(item => item.id === row.id)?.state)
        .toEqual({ kind: 'browser_executor', activity, addon: { kind: 'observed', registered: true } })
    }
    for (const activity of [undefined, null, true, 'enabled']) {
      const raw = structuredClone(fixture)
      for (const row of raw.rows.filter(item => item.selection.kind === 'browser')) {
        Object.assign(row.state, { activity })
      }
      expect(() => parseLaneInventory(raw)).toThrow()
    }
  })
  it('reads the actual TUI fixture contract with every built-in and exact observation', () => {
    const parsed = parseLaneInventory(fixture)
    expect(parsed.rows).toHaveLength(11)
    expect(parsed.exact_snapshot.lanes).toHaveLength(6)
  })
  it('keeps disabled candidates and running observations, rejecting contradictory activity', () => {
    const raw = structuredClone(fixture)
    const lane = raw.exact_snapshot.lanes.find(item => item.lane_id === 'librarian_exact')!
    const row = raw.rows.find(item => item.id === 'exact/librarian_exact')!
    Object.assign(lane, { configured: true, configuration_state: 'off', status: 'off',
      admitted_slots: [], cli_slots: [], dropped_slots: [], admission_error: null,
      declared_slots: ['first', 'second'], declared_cli_slots: ['cli'], running_count: 1 })
    Object.assign(row.state, { configuration: { kind: 'off', declared_slots: ['first', 'second'], declared_cli_slots: ['cli'] } })
    expect(parseLaneInventory(raw).exact_snapshot.lanes.find(item => item.laneId === 'librarian_exact'))
      .toMatchObject({ status: 'off', runningCount: 1, declaredSlots: ['first', 'second'], declaredCliSlots: ['cli'] })
    lane.status = 'running'
    expect(() => parseLaneInventory(raw)).toThrow(/inconsistent admission/)
    lane.status = 'off'; lane.required = true
    expect(() => parseLaneInventory(raw)).toThrow(/inconsistent admission/)
    lane.required = false; lane.declared_slots = ['other']
    expect(() => parseLaneInventory(raw)).toThrow(/disagrees/)
  })
  it('rejects mismatched families, duplicate identities, missing builtins and conflicting exact readings', () => {
    for (const mutate of [
      (value: typeof fixture) => { value.rows.push(value.rows[0]!) },
      (value: typeof fixture) => { value.rows.pop() },
      (value: typeof fixture) => { value.rows[0]!.id = 'exact/other' },
      (value: typeof fixture) => { value.rows[0]!.state.kind = 'machine' },
      (value: typeof fixture) => { value.exact_snapshot.lanes[0]!.admitted_slots = [] },
      (value: typeof fixture) => { value.exact_snapshot.lanes[0]!.configuration_state = 'unavailable' },
    ]) {
      const value = structuredClone(fixture); mutate(value)
      expect(() => parseLaneInventory(value)).toThrow()
    }
  })
  it('keeps off intent and unfinished retained cleanup, rejecting nonboolean flags', () => {
    const packageRow = { id: 'declaration//fixture/lane-addons/demo.toml', label: 'demo.toml', purpose: 'Demo',
      selection: { kind: 'declaration', source_path: '/fixture/lane-addons/demo.toml' },
      state: { kind: 'package', declaration: { kind: 'valid', enabled: false, installation_id: 'demo',
        run_id: 'world', package_id: 'demo-package', title: 'Demo', desired_revision: 'inputs', source_revision: 'source', exact_outputs: [], application: { kind: 'cleaning' } },
      instances: [{ instance_id: 'retained-1', incarnation: 'retained-1', run_id: 'world', package_id: 'demo-package',
        title: 'Demo', package_revision: 'package-rev', presence: 'retained', phase: { kind: 'failed', message: 'cleanup unconfirmed' },
        applied_revision: 'inputs' }] } }
    const raw = { ...fixture, rows: [...fixture.rows, packageRow] }
    expect(parseLaneInventory(raw).rows.at(-1)?.state).toEqual(packageRow.state)
    expect(() => parseLaneInventory({ ...fixture, rows: [...fixture.rows,
      { ...packageRow, state: { ...packageRow.state, instances: [{ ...packageRow.state.instances[0], applied_revision: null }] } }] })).toThrow()
    expect(() => parseLaneInventory({ ...raw, rows: [...raw.rows, packageRow] })).toThrow()
    expect(() => parseLaneInventory({ ...fixture, rows: [...fixture.rows,
      { ...packageRow, state: { ...packageRow.state, declaration: { ...packageRow.state.declaration, enabled: 'false' } } }] })).toThrow()
  })
})
