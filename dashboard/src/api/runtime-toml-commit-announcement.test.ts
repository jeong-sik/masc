import { createHash } from 'node:crypto'
import { effect } from '@preact/signals'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { applyFusionConfigEdit } from './dashboard-fusion'
import {
  patchRuntimeAssignment, patchRuntimeExactSlot, patchRuntimeLane, patchRuntimeMediaFailover, patchRuntimeRouting,
  saveRuntimeTomlConfig,
} from './dashboard-runtime'
import { saveSetupCredential } from './onboarding'
import { saveSetupSelections } from './runtime-setup'
import { committedRuntimeTomlConfigFixture } from '../lib/runtime-config-receipt.test-fixture'
import { runtimeTomlSourceGeneration } from '../lib/runtime-toml-source-generation'

vi.mock('./dev-token', () => ({ ensureDevToken: vi.fn(async () => undefined) }))

const source = '# commit announcement fixture\n'
const revision = createHash('sha256').update('runtime_config_source\0' + source).digest('hex')
const receipt = committedRuntimeTomlConfigFixture({
  ok: true, path: '/fixture/runtime.toml', file_name: 'runtime.toml', source_text: source,
  provider_protocols: [{ protocol: 'openai-compatible-http', transport: 'endpoint', semantics: 'http_provider',
    credential_policy: 'optional', requires_non_interactive: false, provider_fields: [], required_provider_fields: [] }],
}, { skills: { state: 'unchanged', input_source_revision: revision,
  snapshot_revision: 'snapshot', catalog_revision: 'catalog', config_state: 'configured' } })
receipt.source_revision = revision
receipt.commit.source_revision = revision
const assignmentRevision = { state: 'runtime_config_present', source_revision: revision, assignment: { state: 'missing' } } as const

function reply(body: unknown, status = 200) {
  vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify(body), {
    status, headers: { 'Content-Type': 'application/json' },
  })))
}

afterEach(() => { vi.unstubAllGlobals() })

describe('runtime.toml write receipts', () => {
  it.each([
    ['raw save', () => saveRuntimeTomlConfig(source, revision, { expectedSourcePath: '/fixture/runtime.toml' })],
    ['routing', () => patchRuntimeRouting('default', 'fixture.primary')],
    ['media failover', () => patchRuntimeMediaFailover(['fixture.primary'])],
    ['candidate lane', () => patchRuntimeLane('fixture.lane', { action: 'remove' })],
    ['exact slot', () => patchRuntimeExactSlot('judge', 'append', 'fixture.primary')],
    ['assignment', () => patchRuntimeAssignment('keeper', 'fixture.primary', assignmentRevision)],
    ['fusion edit', () => applyFusionConfigEdit(revision, { kind: 'delete_preset', name: 'trio' })],
  ] as const)('%s tells every screen once, whether or not its sender still waits', async (_name, write) => {
    reply(receipt)
    const before = runtimeTomlSourceGeneration.peek()
    await write()
    expect(runtimeTomlSourceGeneration.peek()).toBe(before + 1)
  })

  it('a model connection save tells every screen once', async () => {
    reply({ configured: true, commit: { durability: 'durable', warnings: [] }, readiness: 'verified',
      runtime_id: 'fixture.model', runtime_ids: ['fixture.model'] })
    const before = runtimeTomlSourceGeneration.peek()
    await saveSetupSelections('revision', [{ kind: 'existing', id: 'fixture.model', label: 'Model' }])
    expect(runtimeTomlSourceGeneration.peek()).toBe(before + 1)
  })

  it('a model connection save whose answer is unreadable still tells every screen once its commit is recorded', async () => {
    reply({ configured: true, commit: { durability: 'durable', warnings: [] }, readiness: 'unknown' })
    const before = runtimeTomlSourceGeneration.peek()
    await expect(saveSetupSelections('revision', [{ kind: 'existing', id: 'fixture.model', label: 'Model' }])).rejects.toThrow()
    expect(runtimeTomlSourceGeneration.peek()).toBe(before + 1)
  })

  it('an applied API key tells every screen once', async () => {
    reply({ ok: true, configured: true, verification: 'not_run' })
    const before = runtimeTomlSourceGeneration.peek()
    await saveSetupCredential('fixture-provider', 'secret', revision)
    expect(runtimeTomlSourceGeneration.peek()).toBe(before + 1)
  })

  it.each([
    ['a refused API key', () => {
      reply({ ok: false, error: 'Select a configured provider and enter its API key.' }, 400)
      return saveSetupCredential('fixture-provider', 'secret', revision)
    }],
    ['a refused raw save', () => {
      reply({ error: 'runtime.toml changed', code: 'revision_conflict',
        current: { source_path: '/fixture/runtime.toml', source_text: '# other\n', source_revision: 'b'.repeat(64) } }, 409)
      return saveRuntimeTomlConfig(source, revision, { expectedSourcePath: '/fixture/runtime.toml' })
    }],
    ['a refused fusion edit', () => {
      reply({ ok: false, error: { code: 'configuration_changed', message: 'changed' } }, 409)
      return applyFusionConfigEdit(revision, { kind: 'delete_preset', name: 'trio' })
    }],
    ['an assignment that changed nothing', () => {
      reply({ ok: true, applied: false, assignment_revision: assignmentRevision })
      return patchRuntimeAssignment('keeper', 'fixture.primary', assignmentRevision)
    }],
  ] as const)('%s tells no one', async (_name, write) => {
    const before = runtimeTomlSourceGeneration.peek()
    await write().catch(() => undefined)
    expect(runtimeTomlSourceGeneration.peek()).toBe(before)
  })

  it('lets the writer take the new generation before any screen hears it', async () => {
    reply(receipt)
    let adopted = -1
    const heard: boolean[] = []
    const stop = effect(() => { heard.push(runtimeTomlSourceGeneration.value === adopted) })
    heard.length = 0
    await patchRuntimeRouting('default', 'fixture.primary', {
      onCommitted: () => { adopted = runtimeTomlSourceGeneration.peek() },
    })
    stop()
    expect(heard).toEqual([true])
  })
})
