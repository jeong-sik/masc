import initialize from '@rhwp/core'
import wasmUrl from '@rhwp/core/rhwp_bg.wasm?url'
import { convertArtifactHwp } from './artifact-hwp-convert'
import type { HwpWorkerResponse } from './artifact-hwp-message'

type WorkerPort = {
  onmessage: ((event: MessageEvent<unknown>) => void) | null;
  postMessage: (response: HwpWorkerResponse) => void;
}
const port: WorkerPort = self
port.onmessage = (event: MessageEvent<unknown>) => {
  const convert = async () => {
    if (!(event.data instanceof ArrayBuffer)) throw new Error('가져올 HWP 파일의 데이터가 올바르지 않습니다.')
    await initialize({ module_or_path: wasmUrl })
    return convertArtifactHwp(new Uint8Array(event.data))
  }
  void convert().then(
    result => port.postMessage({ kind: 'converted', result: { content: result.content, notices: [...result.notices] } }),
    error => port.postMessage({ kind: 'failed', message: error instanceof Error ? error.message
      : typeof error === 'string' ? error : 'HWP 파일을 가져오지 못했습니다.' }),
  )
}
