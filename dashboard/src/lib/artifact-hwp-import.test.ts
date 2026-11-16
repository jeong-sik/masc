import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { importArtifactHwp } from './artifact-hwp-import'
import { officeImportLimits } from './artifact-office-xml'

const workers: ImportWorker[] = []
class ImportWorker {
  onmessage: ((event: MessageEvent<unknown>) => void) | null = null
  onerror: ((event: ErrorEvent) => void) | null = null
  onmessageerror: (() => void) | null = null
  postMessage = vi.fn<(data: ArrayBuffer, transfer: Transferable[]) => void>()
  terminate = vi.fn()
  constructor(readonly url: URL, readonly options: WorkerOptions) { workers.push(this) }
  receive(data: unknown) { this.onmessage?.(new MessageEvent('message', { data })) }
}
beforeEach(() => { workers.splice(0); vi.stubGlobal('Worker', ImportWorker) })
afterEach(() => { vi.unstubAllGlobals() })

it('transfers one input buffer and releases the worker after the converted draft arrives', async () => {
  const data = new ArrayBuffer(16), converted = importArtifactHwp(data, new AbortController().signal)
  const worker = workers[0]!
  expect(worker.postMessage).toHaveBeenCalledExactlyOnceWith(data, [data])
  worker.receive({ kind: 'converted', result: { content: '<p>문서</p>', notices: [] } })
  await expect(converted).resolves.toEqual({ content: '<p>문서</p>', notices: [] })
  expect(worker.terminate).toHaveBeenCalledTimes(1)
})

it('terminates an aborted read and rejects a later worker result', async () => {
  const controller = new AbortController(), converted = importArtifactHwp(new ArrayBuffer(0), controller.signal)
  const assertion = expect(converted).rejects.toMatchObject({ name: 'AbortError' })
  controller.abort()
  workers[0]!.receive({ kind: 'converted', result: { content: '<p>이전 결과</p>', notices: [] } })
  await assertion
  expect(workers[0]!.terminate).toHaveBeenCalled()
})

it('never starts the engine for an already cancelled file read', async () => {
  const controller = new AbortController()
  controller.abort()
  await expect(importArtifactHwp(new ArrayBuffer(0), controller.signal)).rejects.toMatchObject({ name: 'AbortError' })
  expect(workers).toHaveLength(0)
})

it('never starts the engine for a file over the shared input limit', async () => {
  await expect(importArtifactHwp(new ArrayBuffer(officeImportLimits.inputBytes + 1), new AbortController().signal)).rejects.toThrow('32 MiB')
  expect(workers).toHaveLength(0)
})

for (const malformed of [undefined, { kind: 'converted', result: { content: '', notices: [1] } },
  { kind: 'ignored', result: { content: '', notices: [] } }]) {
  it('rejects an unreadable worker response and releases the worker', async () => {
    const converted = importArtifactHwp(new ArrayBuffer(0), new AbortController().signal)
    const assertion = expect(converted).rejects.toThrow('변환 결과를 읽을 수 없습니다')
    workers[0]!.receive(malformed)
    await assertion
    expect(workers[0]!.terminate).toHaveBeenCalledTimes(1)
  })
}

it('propagates a document failure without producing a draft', async () => {
  const converted = importArtifactHwp(new ArrayBuffer(0), new AbortController().signal)
  const assertion = expect(converted).rejects.toThrow('지원하지 않는 차트입니다.')
  workers[0]!.receive({ kind: 'failed', message: '지원하지 않는 차트입니다.' })
  await assertion
  expect(workers[0]!.terminate).toHaveBeenCalledTimes(1)
})

it('settles a worker startup failure and releases its resources', async () => {
  const converted = importArtifactHwp(new ArrayBuffer(0), new AbortController().signal)
  const assertion = expect(converted).rejects.toThrow('worker failed')
  workers[0]!.onerror?.(new ErrorEvent('error', { message: 'worker failed' }))
  await assertion
  expect(workers[0]!.terminate).toHaveBeenCalledTimes(1)
})
