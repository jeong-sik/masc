import { Schema } from 'effect'
import { get } from './core'
import { LANE_IDS, parseStandaloneLanesSnapshot } from './dashboard-standalone-lanes'

const text = Schema.NonEmptyString
const texts = Schema.Array(text)
const count = Schema.Int.pipe(Schema.nonNegative())
const configuration = Schema.Union(
  Schema.Struct({ kind: Schema.Literal('off'), declared_slots: texts, declared_cli_slots: texts }),
  Schema.Struct({ kind: Schema.Literal('configured'), admitted_slots: texts, cli_slots: texts,
    declared_slots: texts, declared_cli_slots: texts, dropped_slots: texts, admission_error: Schema.NullOr(Schema.String) }),
  Schema.Struct({ kind: Schema.Literal('unconfigured', 'unavailable'), detail: Schema.String }),
)
const declaration = Schema.Union(
  Schema.Struct({ kind: Schema.Literal('valid'), enabled: Schema.Boolean, installation_id: text,
    run_id: text, package_id: text, title: text, desired_revision: text }),
  Schema.Struct({ kind: Schema.Literal('invalid'), messages: Schema.NonEmptyArray(Schema.String) }),
  Schema.Struct({ kind: Schema.Literal('absent', 'unobserved') }),
)
const phase = Schema.Union(
  Schema.Struct({ kind: Schema.Literal('attached', 'observing', 'detaching', 'detached') }),
  Schema.Struct({ kind: Schema.Literal('failed'), message: Schema.String }),
)
const instance = Schema.Struct({ instance_id: text, incarnation: text, run_id: text, package_id: text,
  title: text, package_revision: text, presence: Schema.Literal('live', 'retained'), phase,
  applied_revision: Schema.NullOr(text) })
const common = { id: text, label: text, purpose: text }
const row = Schema.Union(
  Schema.Struct({ ...common, selection: Schema.Struct({ kind: Schema.Literal('exact'), lane_id: Schema.Literal(...LANE_IDS) }),
    state: Schema.Struct({ kind: Schema.Literal('exact'), configuration }) }),
  Schema.Struct({ ...common, selection: Schema.Struct({ kind: Schema.Literal('browser'), lane: Schema.Literal('live') }),
    state: Schema.Struct({ kind: Schema.Literal('browser_clients'), activity: Schema.Literal('on', 'off', 'unobserved'), connected_clients: count }) }),
  Schema.Struct({ ...common, selection: Schema.Struct({ kind: Schema.Literal('browser'), lane: Schema.Literal('automation', 'stagehand') }),
    state: Schema.Struct({ kind: Schema.Literal('browser_executor'), activity: Schema.Literal('on', 'off', 'unobserved'), registered: Schema.Boolean }) }),
  Schema.Struct({ ...common, selection: Schema.Struct({ kind: Schema.Literal('machine'), machine: Schema.Literal('msx', 'dos') }),
    state: Schema.Struct({ kind: Schema.Literal('machine'), publication: Schema.Literal('no_screen', 'stable', 'running') }) }),
  Schema.Struct({ ...common, selection: Schema.Struct({ kind: Schema.Literal('declaration'), source_path: text }),
    state: Schema.Struct({ kind: Schema.Literal('package'), declaration, instances: Schema.Array(instance) }) }),
  Schema.Struct({ ...common, selection: Schema.Struct({ kind: Schema.Literal('manual_instance'), instance_id: text, incarnation: text }),
    state: Schema.Struct({ kind: Schema.Literal('package'), declaration: Schema.Null, instances: Schema.Array(instance) }) }),
)
const snapshot = Schema.Struct({ schema: Schema.Literal('masc.lane-inventory/v1'),
  observed_at: Schema.Number.pipe(Schema.finite()), rows: Schema.Array(row), exact_snapshot: Schema.Unknown,
  package_read: Schema.Struct({ directory: text, complete: Schema.Boolean, owner_present: Schema.Boolean,
    issues: Schema.Array(Schema.Struct({ source_path: text, message: Schema.String })) }) })
export type LaneInventoryRow = Schema.Schema.Type<typeof row>

export function parseLaneInventory(raw: unknown) {
  const parsed = Schema.decodeUnknownSync(snapshot)(raw)
  const exact = parseStandaloneLanesSnapshot(parsed.exact_snapshot)
  const ids = new Set<string>(), workers = new Set<string>()
  const builtins = new Set([...LANE_IDS.map(id => `exact/${id}`), 'browser/live', 'browser/automation',
    'browser/stagehand', 'machine/msx', 'machine/dos'])
  for (const item of parsed.rows) {
    const selection = item.selection
    let expected: string
    switch (selection.kind) {
      case 'exact': expected = `exact/${selection.lane_id}`; break
      case 'browser': expected = `browser/${selection.lane}`; break
      case 'machine': expected = `machine/${selection.machine}`; break
      case 'declaration': expected = `declaration/${selection.source_path}`; break
      case 'manual_instance': expected = `instance/${selection.instance_id}`; break
    }
    if (item.id !== expected || ids.has(item.id)) throw new Error('Lane inventory has conflicting row identity')
    ids.add(item.id); builtins.delete(item.id)
    if (selection.kind === 'exact' && item.state.kind === 'exact') {
      const observed = exact.lanes.find(lane => lane.laneId === selection.lane_id)
      const config = item.state.configuration
      const same = (left: readonly string[], right: readonly string[]) =>
        left.length === right.length && left.every((value, index) => value === right[index])
      let agrees = false
      if (observed) {
        switch (config.kind) {
          case 'configured':
            agrees = observed.configured === true && observed.configurationState ===
              (config.admission_error !== null || config.admitted_slots.length + config.cli_slots.length === 0 ? 'degraded' : 'ready')
              && same(config.admitted_slots, observed.admittedSlots) && same(config.cli_slots, observed.cliSlots)
              && same(config.declared_slots, observed.declaredSlots) && same(config.declared_cli_slots, observed.declaredCliSlots)
              && same(config.dropped_slots, observed.droppedSlots) && config.admission_error === observed.admissionError
            break
          case 'off':
            agrees = observed.configurationState === 'off'
              && same(config.declared_slots, observed.declaredSlots) && same(config.declared_cli_slots, observed.declaredCliSlots)
            break
          case 'unconfigured':
          case 'unavailable':
            agrees = config.kind === observed.configurationState && config.detail === observed.admissionError
            break
        }
      }
      if (!agrees) {
        throw new Error('Lane inventory exact reading disagrees with configuration')
      }
    }
    if (item.state.kind === 'package') {
      for (const worker of item.state.instances) {
        if (workers.has(worker.instance_id) || worker.phase.kind === 'detached') {
          throw new Error('Lane inventory has conflicting or detached current worker')
        }
        workers.add(worker.instance_id)
        if (selection.kind === 'declaration' && worker.applied_revision === null) {
          throw new Error('Lane inventory declared worker has no applied revision')
        }
      }
      if (selection.kind === 'manual_instance') {
        const [worker] = item.state.instances
        if (item.state.instances.length !== 1 || !worker || worker.instance_id !== selection.instance_id
          || worker.incarnation !== selection.incarnation || worker.applied_revision !== null) {
          throw new Error('Lane inventory manual instance does not match its owner')
        }
      }
    }
  }
  if (builtins.size) throw new Error('Lane inventory is missing built-in rows')
  return { ...parsed, exact_snapshot: exact }
}
export type LaneInventory = ReturnType<typeof parseLaneInventory>
export async function fetchLaneInventory(signal?: AbortSignal): Promise<LaneInventory> {
  return parseLaneInventory(await get<unknown>('/api/v1/lanes', { signal }))
}
