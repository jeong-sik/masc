import { fetchToolBlob } from './tool-blob'

export interface ToolBlobReference { readonly sha256: string; readonly bytes: number }

// The text transport must round-trip the exact retained bytes, including UTF-8.
export async function fetchVerifiedToolBlobText(ref: ToolBlobReference, signal?: AbortSignal): Promise<string> {
  const subtle = globalThis.crypto?.subtle
  if (!subtle) throw new Error('이 브라우저에서는 저장된 파일을 검증할 수 없습니다. HTTPS 또는 localhost에서 다시 열어 주세요.')
  const response = await fetchToolBlob(ref.sha256, { signal })
  if (typeof response.content !== 'string') throw new Error('저장된 파일 응답에 텍스트가 없습니다.')
  const bytes = new TextEncoder().encode(response.content)
  const digest = await subtle.digest('SHA-256', bytes)
  const hash = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('')
  if (response.sha256 !== ref.sha256 || response.bytes !== ref.bytes
      || bytes.byteLength !== ref.bytes || hash !== ref.sha256) {
    throw new Error('저장된 파일의 바이트 검증에 실패했습니다. 파일과 기록된 참조가 다르거나 텍스트로 표시할 수 없습니다.')
  }
  return response.content
}
