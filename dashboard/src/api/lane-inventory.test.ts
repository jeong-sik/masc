import { describe, expect, it } from 'vitest'
import { parseLaneInventory } from './lane-inventory'
import fixture from './fixtures/lane-inventory.json'

describe('common Lane inventory wire', () => {
  it('reads the actual TUI fixture contract with every built-in and exact observation', () => {
    const parsed = parseLaneInventory(fixture)
    expect(parsed.rows).toHaveLength(12)
    expect(parsed.exact_snapshot.lanes).toHaveLength(7)
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
        run_id: 'world', package_id: 'demo-package', title: 'Demo', desired_revision: 'inputs' },
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
