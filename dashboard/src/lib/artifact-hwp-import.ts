import { Either, Schema } from 'effect'
import { hwpWorkerResponse, type HwpImportResult } from './artifact-hwp-message'
import { officeImportLimits } from './artifact-office-xml'

/** A worker belongs to one file read. Closing or replacing that read releases its memory. */
export function importArtifactHwp(data: ArrayBuffer, signal?: AbortSignal): Promise<HwpImportResult> {
  if (data.byteLength > officeImportLimits.inputBytes) return Promise.reject(new Error('가져올 문서는 32 MiB 이하여야 합니다.'))
  if (signal?.aborted) return Promise.reject(new DOMException('파일 가져오기를 취소했습니다.', 'AbortError'))
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL('./artifact-hwp.worker.ts', import.meta.url), { type: 'module' })
    const close = () => { worker.terminate(); signal?.removeEventListener('abort', cancel) }
    const fail = (error: unknown) => { close(); reject(error) }
    const cancel = () => fail(new DOMException('파일 가져오기를 취소했습니다.', 'AbortError'))
    worker.onmessage = (event: MessageEvent<unknown>) => {
      const response = Schema.decodeUnknownEither(hwpWorkerResponse, { onExcessProperty: 'error' })(event.data)
      if (Either.isLeft(response)) { fail(new Error('HWP 변환 결과를 읽을 수 없습니다.')); return }
      close()
      switch (response.right.kind) {
        case 'converted': resolve(response.right.result); return
        case 'failed': reject(new Error(response.right.message)); return
      }
    }
    worker.onerror = (event: ErrorEvent) => fail(new Error(event.message || 'HWP 변환을 실행하지 못했습니다.'))
    worker.onmessageerror = () => fail(new Error('HWP 변환 결과를 전달받지 못했습니다.'))
    signal?.addEventListener('abort', cancel, { once: true })
    try { worker.postMessage(data, [data]) } catch (error) { fail(error) }
  })
}
