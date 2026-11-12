import { useLayoutEffect, useRef } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import { currentStoredTokenRevision } from '../api/core'
import { storedTokenRevision } from '../api/token-revision'
import { modelMetricsStreamPath, subscribeModelMetricsStream, type ModelMetricsQuery } from '../api/model-metrics-stream'
import type { DashboardRuntimeModelMetricsResponse } from '../api/dashboard-runtime'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../store'
import type { QueryStreamSubscription } from './query-observation-stream'

export type ModelMetricsReading =
  | { kind: 'loading' }
  | { kind: 'error'; message: string }
  | { kind: 'ready'; value: DashboardRuntimeModelMetricsResponse; receivedAt: Date; readError: string | null }

export function useModelMetrics(query: ModelMetricsQuery, enabled = true) {
  const authority = executionWorkspaceAuthority.value
  const credential = storedTokenRevision.value
  const key = modelMetricsStreamPath(query)
  const subscription = useRef<{
    owner: QueryStreamSubscription; authority: ExecutionWorkspaceAuthority; credential: number; key: string
  } | null>(null)
  const reading = useSignal<{
    authority: ExecutionWorkspaceAuthority; credential: number; key: string; state: ModelMetricsReading
  } | null>(null)
  useLayoutEffect(() => {
    if (!enabled || authority === null) return
    let active = true
    const current = () => active && executionWorkspaceAuthority.peek() === authority
      && currentStoredTokenRevision() === credential
    const publish = (state: ModelMetricsReading) => {
      if (current()) reading.value = { authority, credential, key, state }
    }
    const owner = subscribeModelMetricsStream(query, {
      onReset: () => publish({ kind: 'loading' }),
      onFrame: value => publish({ kind: 'ready', value, receivedAt: new Date(), readError: null }),
      onError: error => {
        const previous = reading.peek()
        if (previous?.authority === authority && previous.credential === credential && previous.key === key
          && previous.state.kind === 'ready') {
          publish({ ...previous.state, readError: error.message })
        } else publish({ kind: 'error', message: error.message })
      },
    })
    subscription.current = { owner, authority, credential, key }
    return () => {
      active = false
      owner()
      if (subscription.current?.owner === owner) subscription.current = null
    }
  }, [authority, credential, key, enabled])
  const observed = reading.value
  const state: ModelMetricsReading = authority === null
    ? { kind: 'error', message: '작업공간을 확인한 뒤 통계를 읽을 수 있습니다.' }
    : enabled && observed?.authority === authority && observed.credential === credential && observed.key === key
      ? observed.state : { kind: 'loading' }
  const refresh = () => {
    const current = subscription.current
    if (enabled && current?.authority === authority && current.credential === credential && current.key === key)
      current.owner.refresh()
  }
  return { state, refresh }
}
