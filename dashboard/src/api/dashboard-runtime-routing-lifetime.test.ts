import { createHash } from 'node:crypto'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  patchRuntimeLane, patchRuntimeMediaFailover, patchRuntimeRouting,
  type RuntimeTomlRequestOptions,
} from './dashboard-runtime'
import { ensureDevToken } from './dev-token'
import { committedRuntimeTomlConfigFixture } from '../lib/runtime-config-receipt.test-fixture'

vi.mock('./dev-token', () => ({ ensureDevToken: vi.fn(async () => undefined) }))

const source = '# routing receipt fixture\n'
const revision = createHash('sha256').update('runtime_config_source\0' + source).digest('hex')
const receipt = committedRuntimeTomlConfigFixture({
  ok: true, path: '/fixture/runtime.toml', file_name: 'runtime.toml', source_text: source,
  provider_protocols: [{ protocol: 'openai-compatible-http', transport: 'endpoint', semantics: 'http_provider',
    credential_policy: 'optional', requires_non_interactive: false, provider_fields: [], required_provider_fields: [] }],
}, { skills: { state: 'unchanged', input_source_revision: revision,
  snapshot_revision: 'snapshot', catalog_revision: 'catalog', config_state: 'configured' } })
receipt.source_revision = revision
receipt.commit.source_revision = revision

const requests = [
  { name: 'default routing', invoke: (options?: RuntimeTomlRequestOptions) => patchRuntimeRouting('default', 'fixture.primary', options),
    body: { lane: 'default', runtime_id: 'fixture.primary' } },
  { name: 'media failover', invoke: (options?: RuntimeTomlRequestOptions) => patchRuntimeMediaFailover(['fixture.primary', 'fixture.backup'], options),
    body: { lane: 'media_failover', runtime_ids: ['fixture.primary', 'fixture.backup'] } },
  { name: 'candidate lane', invoke: (options?: RuntimeTomlRequestOptions) => patchRuntimeLane('fixture.lane', {
    action: 'set', runtimeIds: ['fixture.primary'], expectedSourceRevision: revision,
  }, options), body: { lane: 'fixture.lane', action: 'set', runtime_ids: ['fixture.primary'], expected_source_revision: revision } },
]

function holdToken() {
  let release!: () => void
  vi.mocked(ensureDevToken).mockImplementationOnce(() => new Promise<void>(resolve => { release = resolve }))
  return () => release()
}

function reply() {
  const fetchMock = vi.fn<typeof fetch>(async () => new Response(JSON.stringify(receipt), {
    status: 200, headers: { 'Content-Type': 'application/json' },
  }))
  vi.stubGlobal('fetch', fetchMock)
  return fetchMock
}

beforeEach(() => { vi.mocked(ensureDevToken).mockReset().mockResolvedValue(undefined) })
afterEach(() => { vi.unstubAllGlobals() })

for (const request of requests) {
  describe(request.name, () => {
    it.each(['unknown workspace', 'A-B-A connection replacement'] as const)(
      'does not dispatch if authority changes during token preparation: %s', async transition => {
        const release = holdToken(), fetchMock = reply()
        const admitted = { workspaceRoot: '/fixture/A' }
        let current: typeof admitted | null = admitted
        const withdrawn = new Error('request authority withdrawn')
        const beforeDispatch = vi.fn(() => { if (current !== admitted) throw withdrawn })
        const pending = request.invoke({ beforeDispatch })
        const rejected = expect(pending).rejects.toBe(withdrawn)
        expect(beforeDispatch).not.toHaveBeenCalled()
        expect(fetchMock).not.toHaveBeenCalled()
        if (transition === 'unknown workspace') current = null
        else { current = { workspaceRoot: '/fixture/B' }; current = { workspaceRoot: '/fixture/A' } }
        release()
        await rejected
        expect(beforeDispatch).toHaveBeenCalledTimes(1)
        expect(fetchMock).not.toHaveBeenCalled()
      },
    )

    it('checks current authority after token preparation and before sending the unchanged wire request', async () => {
      const release = holdToken(), fetchMock = reply()
      const beforeDispatch = vi.fn(() => { expect(fetchMock).not.toHaveBeenCalled() })
      const pending = request.invoke({ beforeDispatch })
      expect(beforeDispatch).not.toHaveBeenCalled()
      release()
      await expect(pending).resolves.toMatchObject({ state: 'committed', commit: receipt.commit })
      expect(beforeDispatch).toHaveBeenCalledTimes(1)
      expect(fetchMock).toHaveBeenCalledTimes(1)
      const [path, init] = fetchMock.mock.calls[0]!
      expect(path).toBe('/api/v1/runtime/config/routing')
      expect(init?.method).toBe('POST')
      expect(JSON.parse(init?.body as string)).toEqual(request.body)
    })

    it('retains the optional-options call contract', async () => {
      const fetchMock = reply()
      await expect(request.invoke()).resolves.toMatchObject({ state: 'committed', commit: receipt.commit })
      expect(fetchMock).toHaveBeenCalledTimes(1)
    })
  })
}
