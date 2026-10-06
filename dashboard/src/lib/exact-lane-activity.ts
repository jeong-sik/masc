import { getStaticTOMLValue, parseTOML } from 'toml-eslint-parser'
import type { StandaloneLaneSnapshotRow } from '../api/dashboard-standalone-lanes'
import { isRecord } from './type-guards'
import { setRuntimeTomlKey } from './runtime-toml-config'

export type ExactActivityLane = Pick<StandaloneLaneSnapshotRow, 'laneId' | 'required'>
export type ExactActivity = { enabled: boolean; slots: string[]; cliSlots: string[] }

export function readExactActivity(source: string, lane: ExactActivityLane): ExactActivity {
  let value: unknown = getStaticTOMLValue(parseTOML(source, { tomlVersion: '1.0' }))
  for (const key of ['runtime', 'exact_output_lanes', lane.laneId]) {
    if (!isRecord(value) || !Object.hasOwn(value, key)) throw new Error('Lane 설정이 없습니다. Runtime 설정에서 후보를 먼저 추가하세요.')
    value = value[key]
  }
  if (!isRecord(value)) throw new Error('Lane 설정은 TOML table이어야 합니다.')
  const table = value
  const enabled = Object.hasOwn(table, 'enabled') ? table.enabled : true
  if (typeof enabled !== 'boolean') throw new Error('enabled는 true 또는 false여야 합니다.')
  function candidates(key: string): string[] {
    const items = table[key]
    if (items === undefined) return []
    if (!Array.isArray(items) || !items.every((item): item is string => typeof item === 'string' && item.trim() !== ''))
      throw new Error(`${key}는 후보 이름 목록이어야 합니다.`)
    return items
  }
  return { enabled, slots: candidates('slots'), cliSlots: candidates('cli_slots') }
}

/** Edit only this value's parsed source range; preserve inline/quoted/dotted
 * table spellings, comments, candidate order and all unrelated source. */
export function writeExactActivity(source: string, lane: ExactActivityLane, enabled: boolean): string {
  const current = readExactActivity(source, lane)
  if (lane.required && !enabled) throw new Error('필수 Lane은 끌 수 없습니다.')
  if (enabled && current.slots.length === 0 && current.cliSlots.length === 0)
    throw new Error('Lane을 켜려면 후보를 먼저 추가하세요.')
  return setRuntimeTomlKey(source, `runtime.exact_output_lanes.${lane.laneId}`, 'enabled', enabled)
}
