import { afterEach, expect, it, vi } from 'vitest'
import { discoverSetupModels, importAntigravityAccount, prepareSetupModel, saveSetupSelections } from './runtime-setup'

afterEach(() => { vi.useRealTimers(); vi.unstubAllGlobals() })
const source = { integration_id: 'fixture' }
const model = { id: 'model', label: 'Model', context: 1024, tools: true }
const cases = [
  { name: 'model discovery', invoke: (signal: AbortSignal) => discoverSetupModels(source, { signal }), receipt: { models: [model] } },
  { name: 'selected context', invoke: (signal: AbortSignal) => prepareSetupModel(source, model, false, { signal }), receipt: { model: 'model', context: 1024 } },
  { name: 'account import', invoke: (signal: AbortSignal) => importAntigravityAccount('fixture', { signal }), receipt: { schema: 'masc.web_setup_account.v1', account_ref: 'a'.repeat(64), account_imported: true, invocation_verified: false, catalog: { models: [model] } } },
  { name: 'verified model save', invoke: (signal: AbortSignal) => saveSetupSelections('revision', [{ kind: 'existing', id: 'fixture.model', label: 'Model' }], { signal }), receipt: { configured: true, readiness: 'verified', runtime_id: 'fixture.model', runtime_ids: ['fixture.model'] } },
]
for (const entry of cases) {
  it(`${entry.name} survives the ordinary POST deadline and accepts its eventual receipt`, async () => {
    vi.useFakeTimers()
    let complete!: (response: Response) => void
    let observed: AbortSignal | null | undefined
    vi.stubGlobal('fetch', vi.fn((_path, init: RequestInit) => {
      observed = init.signal
      return new Promise<Response>((resolve, reject) => {
        complete = resolve
        init.signal?.addEventListener('abort', () => reject(new DOMException('cancelled', 'AbortError')), { once: true })
      })
    }))
    const controller = new AbortController()
    let settled = false
    const pending = entry.invoke(controller.signal).finally(() => { settled = true })
    await vi.advanceTimersByTimeAsync(30_001)
    expect(settled).toBe(false); expect(observed?.aborted).toBe(false)
    complete(new Response(JSON.stringify(entry.receipt), { status: 200, headers: { 'Content-Type': 'application/json' } }))
    await pending
    expect(settled).toBe(true)
  })
}
it('propagates only explicit caller cancellation while a model preparation is pending', async () => {
  vi.stubGlobal('fetch', vi.fn((_path, init: RequestInit) => new Promise<Response>((_resolve, reject) => {
    init.signal?.addEventListener('abort', () => reject(new DOMException('operator cancelled', 'AbortError')), { once: true })
  })))
  const controller = new AbortController()
  const pending = prepareSetupModel(source, model, true, { signal: controller.signal })
  controller.abort()
  await expect(pending).rejects.toMatchObject({ name: 'AbortError' })
})
