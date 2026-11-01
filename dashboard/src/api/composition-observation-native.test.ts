import { createHash } from 'node:crypto'
import { afterEach, describe, expect, it, vi } from 'vitest'
import native from '../../../test/fixtures/skill-nested-native-observation.json'
import { decodeNestedData, fetchAsyncRequestStatus, type NestedChild } from './composition-observation'
import { skillActivationFrameSha256 } from './dashboard-tools-prompts'

// These are selected, unchanged native test payloads, not manufactured wire
// examples. The fixture records the original stdout and extracted-file hashes.
function childrenOf(value: unknown): readonly NestedChild[] {
  const reading = decodeNestedData(value)
  expect(reading.kind).toBe('observed')
  if (reading.kind !== 'observed') throw new Error(`Native observation was ${reading.kind}`)
  return reading.children
}

function expectCompletedChild(child: NestedChild, alias: string, runId: string, parentToolUseId: string): void {
  expect(child.alias).toBe(alias)
  expect(child.reference).toEqual(native.skill.reference)
  expect(child.execution).toBe('inline')
  expect(child.arguments).toEqual({ kind: 'fixed', value: {} })
  expect(child.disposition).toBe('completed')
  expect(child.cause).toBeNull()
  expect(child.admission.kind).toBe('recorded')
  if (child.admission.kind !== 'recorded') throw new Error('Missing actual admission')
  expect(child.admission.tool_use_id).toBe(`composition-skill:${JSON.stringify([runId, 'run-nested', alias])}`)
  expect(child.admission.activation.invocation).toEqual({ kind: 'nested_composition',
    origin: { kind: 'task_composition', task_ids: ['task-nested'] }, tool_name: 'keeper_composition_run',
    scope: { parent_tool_use_id: parentToolUseId, composition_run_id: runId, alias } })
  expect(skillActivationFrameSha256(child.admission.activation)).toBe(child.admission.frame_sha256)
  expect(child.nodes.map(node => ({ node_id: node.node_id, origin: node.origin,
    disposition: node.disposition, effect: node.effect_disposition, validation: node.validation_error }))).toEqual(
    ['lane-a', 'lane-b'].map(source => ({ node_id: JSON.stringify([alias, source]), origin: { source },
      disposition: 'completed', effect: null, validation: null })))
  expect(child.nodes.every(node => node.tool_use_id !== null)).toBe(true)
  expect(child.exports).toEqual([{ name: 'profile', node_id: JSON.stringify([alias, 'lane-a']), pointer: '/profile',
    value: { available: true, value: 'docker' } }])
}

afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks() })

describe('actual native nested-observation parity', () => {
  it('records native provenance and keeps document bytes distinct from the typed revision', () => {
    expect(native.schema).toBe('masc.nested-native-dashboard-parity/v1')
    expect(native.provenance.native_source_head).toBe('26e713fa41de5f6a96a8a98597ea96c95cef523a')
    expect(native.provenance.workflow_run_id).toBe(41291355669)
    expect(native.provenance.native_suite_cases).toEqual({ test_keeper_composition_nested: 14,
      test_tui_chat_call_reader: 11, test_tui_async_request_details: 2 })
    expect(createHash('sha256').update(native.skill.source, 'utf8').digest('hex')).toBe(native.skill.source_utf8_sha256)
    expect(native.skill.source_utf8_sha256).toBe('16d761952b1ecd2e0a2e588080f909676b14886d728e92915694bb27b88fca68')
    expect(native.skill.reference).toEqual({ identity: { source_id: 'fixture', package_id: 'nested-read', name: 'nested-read' },
      content_revision: '45eb9509e7073bac18e4e997e9e5bf6288889364e6dc5103e53e3317b823dfe8' })
    expect(native.skill.reference.content_revision).not.toBe(native.skill.source_utf8_sha256)
    expect(Object.hasOwn(native.cases.async_completed, 'result')).toBe(false)
    expect(Object.hasOwn(native.cases.async_completed, 'request_record')).toBe(false)
  })

  it('decodes both native completed children with exact admission, mapping, nodes and values', () => {
    const proof = native.cases.inline_completed
    expect(proof.execution).toBe('inline')
    expect(proof.success).toBe(true)
    const children = childrenOf(proof.result)
    expect(children.map(child => child.alias)).toEqual(['left', 'right'])
    proof.result.nested_scopes.forEach((actual, index) => {
      const child = children[index]!
      expectCompletedChild(child, actual.scope.alias, proof.result.composition_run_id, 'run-nested')
      expect(child.admission).toEqual({ kind: 'recorded', tool_use_id: actual.admission.skill_tool_use_id,
        activation: actual.admission.activation, frame_sha256: actual.admission.activation_frame_sha256 })
      expect(child.nodes.map(node => ({ source: 'source' in node.origin ? node.origin.source : null,
        expanded: node.node_id }))).toEqual(actual.scope.scope.node_mapping)
      expect(child.nodes.map(node => node.tool_use_id)).toEqual(actual.nodes.map(node => node.tool_use_id))
    })
    expect(proof.result.exports).toEqual({ answer: { available: true, value: 'docker' } })
  })

  it('preserves native admission rejection and unstarted descendants alongside completed siblings', () => {
    const proof = native.cases.inline_admission_rejected
    expect(proof.success).toBe(false)
    expect(proof.rejected_child).toBe(true)
    const children = childrenOf(proof.result)
    expect(children.map(child => [child.alias, child.disposition])).toEqual([
      ['left', 'completed'], ['right', 'completed'], ['reject', 'admission_rejected'], ['blocked', 'not_started'],
    ])
    for (const child of children.slice(0, 2)) expectCompletedChild(child, child.alias, proof.result.composition_run_id, 'run-nested')
    const rejected = children[2]!, blocked = children[3]!
    expect(rejected.reference).toEqual(native.skill.reference)
    expect(rejected.admission).toEqual({ kind: 'rejected', rejection: { kind: 'nested_activation_rejected',
      error: { code: 'runtime_attempt_missing', detail: 'Skill activation arrived before a concrete runtime attempt was selected' } } })
    expect(rejected.cause).toEqual({ kind: 'tool_did_not_complete', node_id: '["reject","lane-a"]' })
    expect(rejected.nodes.map(node => [node.disposition, node.effect_disposition])).toEqual([
      ['failed', 'proven_pre_effect'], ['failed', 'proven_pre_effect'],
    ])
    expect(rejected.nodes.every(node => node.tool_use_id !== null)).toBe(true)
    expect(blocked.reference).toEqual(native.skill.reference)
    expect(blocked.admission).toEqual({ kind: 'not_attempted' })
    expect(blocked.cause).toBeNull()
    expect(blocked.nodes.map(node => [node.disposition, node.tool_use_id, node.effect_disposition])).toEqual([
      [null, null, null], [null, null, null],
    ])
    for (const child of [rejected, blocked]) {
      const nodeId = JSON.stringify([child.alias, 'lane-a'])
      expect(child.exports).toEqual([{ name: 'profile', node_id: nodeId, pointer: '/profile', value: {
        available: false, error: { kind: 'producer_unavailable', node_id: nodeId },
      } }])
      const actual = proof.result.nested_scopes.find(item => item.scope.alias === child.alias)!
      expect(child.nodes.map(node => ({ source: 'source' in node.origin ? node.origin.source : null,
        expanded: node.node_id }))).toEqual(actual.scope.scope.node_mapping)
    }
    expect(proof.result.cause).toMatchObject({ kind: 'tool_did_not_complete', node: {
      node_id: '["reject","lane-a"]', disposition: 'failed', failure_effect_disposition: 'proven_pre_effect',
      effect_disposition: 'proven_pre_effect',
    } })
    expect(proof.result.effect_disposition).toBe('proven_pre_effect')
    // An independent export remains available even though the parent failed.
    expect(proof.result.exports).toEqual({ answer: { available: true, value: 'docker' } })
  })

  it('reads the full canonical native async status without confusing its newer logical owner with physical completion', async () => {
    const proof = native.cases.async_completed
    expect(proof.execution).toBe('async')
    expect(proof.success).toBe(true)
    const physical = proof.status_response.request
    const identity = { submitted_by: physical.submitted_by, request_id: physical.request_id, keeper_name: physical.keeper_name }
    const fetch = vi.fn().mockResolvedValue(Response.json(proof.status_response))
    vi.stubGlobal('fetch', fetch)
    const controller = new AbortController()
    const status = await fetchAsyncRequestStatus(identity, { signal: controller.signal })
    expect(status.status).toBe('observed')
    if (status.status !== 'observed') throw new Error('Actual canonical status was rejected')
    expect(status.request).toEqual(physical)
    expect(status.request).toMatchObject({ status: 'done', ok: true, request_id: 'kmsg-4e8b11245ab78f212cb75fa90ceb206a' })
    expect(physical.completed_at).toBeGreaterThan(physical.submitted_at)
    const logical = physical.continuation.observation
    expect(logical.composition_run_id).toBe(physical.request_context.composition_run_id)
    expect(logical.source_task_id).toBe(physical.request_context.source_task_id)
    expect(logical.owner).toEqual({ request_id: 'kmsg-8405e2aae01616ecb3d373bc97ebc419', generation: 2 })
    expect(logical.owner.request_id).not.toBe(physical.request_id)
    expect(logical.observed_at).toBeGreaterThan(physical.completed_at)
    expect(logical.resolution).toBeNull()
    expect(status.nested.kind).toBe('observed')
    if (status.nested.kind !== 'observed') throw new Error('Actual async children were not observed')
    expect(status.nested.children.map(child => child.alias)).toEqual(['left', 'right'])
    physical.result.nested_scopes.forEach((actual, index) => {
      const child = status.nested.kind === 'observed' ? status.nested.children[index]! : null
      if (child === null) throw new Error('Missing native child')
      expectCompletedChild(child, actual.scope.alias, logical.composition_run_id, `composition-result:${logical.composition_run_id}`)
      expect(child.admission).toEqual({ kind: 'recorded', tool_use_id: actual.admission.skill_tool_use_id,
        activation: actual.admission.activation, frame_sha256: actual.admission.activation_frame_sha256 })
      expect(child.nodes.map(node => ({ source: 'source' in node.origin ? node.origin.source : null,
        expanded: node.node_id }))).toEqual(actual.scope.scope.node_mapping)
      expect(child.nodes.map(node => node.tool_use_id)).toEqual(actual.nodes.map(node => node.tool_use_id))
    })
    expect(fetch).toHaveBeenCalledExactlyOnceWith('/api/v1/async-requests/status?submitted_by=fixture&request_id=kmsg-4e8b11245ab78f212cb75fa90ceb206a',
      expect.objectContaining({ signal: expect.any(AbortSignal) }))
  })
})
