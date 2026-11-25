import { html } from 'htm/preact'
import { useCallback, useEffect, useState } from 'preact/hooks'
import { InlineSpinner } from '../../components/common/inline-spinner'
import type { ApiError } from '../../core/transport'
import { createManagedAsyncResource } from '../../lib/async-state'
import type { Result } from '../../lib/result'

type KeeperReadResult<T> =
  | { readonly kind: 'received'; readonly data: T | null }
  | { readonly kind: 'failed'; readonly error: ApiError; readonly data: T | null }

export function useKeeperRead<T>(
  fetcher: (signal: AbortSignal) => Promise<Result<T, ApiError>>,
  missingIsAbsent = false,
) {
  const [resource] = useState(() => createManagedAsyncResource<KeeperReadResult<T>>())
  const refresh = useCallback(() => resource.load(async (signal, previous) => {
    const result = await fetcher(signal)
    if (result.ok) return { kind: 'received', data: result.value }
    if (missingIsAbsent && result.error.kind === 'not_found') return { kind: 'received', data: null }
    const clear = result.error.kind === 'unauthorized' || result.error.kind === 'forbidden'
    return { kind: 'failed', error: result.error, data: clear ? null : previous?.data ?? null }
  }), [resource, fetcher, missingIsAbsent])

  useEffect(() => {
    void refresh()
    return () => resource.cancel()
  }, [resource, refresh])

  const { data: result, loading, error } = resource.state.value
  const lastData = result?.data ?? null
  const failure = error ?? (result?.kind === 'failed' && !loading ? result.error.message : null)
  return {
    data: lastData,
    received: !loading && failure === null && result?.kind === 'received',
    loading,
    error: failure,
    refresh,
    accept: (data: T) => resource.reset({ kind: 'received', data }),
  }
}

export function KeeperReadNotice({ label, read }: {
  readonly label: string
  readonly read: { readonly data: unknown; readonly received: boolean; readonly loading: boolean
    readonly error: string | null; readonly refresh: () => Promise<unknown> }
}) {
  const previous = read.data !== null
  if (read.loading) return html`
    <div class="kp-empty" role="status">
      <${InlineSpinner} size="xs" /> ${label} 불러오는 중…${previous ? ' · 마지막 조회 표시 중' : ''}
    </div>`
  if (read.error !== null) return html`
    <div class="kp-lifecycle-bar">
      <span class="ap-error" role="alert">
        ${label} 조회 실패 · ${read.error}${previous ? ' · 마지막 조회 표시 중' : ''}
      </span>
      <button type="button" class="btn-ghost" onClick=${() => void read.refresh()}>${label} 다시 읽기</button>
    </div>`
  if (!read.received) return html`<div class="kp-empty">${label} 조회 대기</div>`
  return null
}
