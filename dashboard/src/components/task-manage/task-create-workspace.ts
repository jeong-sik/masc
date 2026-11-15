import { getWithResponse } from '../../api/core'
import type { ArtifactWorkspace } from '../../api/published-artifacts'
import { isRecord } from '../common/normalize'

/** Read the actual pair so a mismatched response is distinguishable from a
 * transport failure. The server answers the pair only to a requester it gives
 * a read; any other answer carries no paths and is rejected below. Reading
 * the pair does not authorize receipt data. */
export async function observeReceiptWorkspace(onResponseStatus?: (status: number) => void): Promise<ArtifactWorkspace> {
  const { data: health } = await getWithResponse<unknown>('/health?full=1', { consumeWithinTimeout: true,
    reportCredentialRefusal: false,
    ...(onResponseStatus ? { beforeResponseBody: response => onResponseStatus(response.status) } : {}) })
  if (!isRecord(health) || !isRecord(health.paths)
    || typeof health.paths.effective_base_path !== 'string' || health.paths.effective_base_path.length === 0
    || typeof health.paths.effective_masc_root !== 'string' || health.paths.effective_masc_root.length === 0) {
    throw new Error('작업 공간 관측이 유효하지 않습니다.')
  }
  return { basePath: health.paths.effective_base_path, mascRoot: health.paths.effective_masc_root }
}
