import {
  callMcpTool,
  runOperatorAction,
  sendKeeperMessageDetailed,
  streamKeeperMessage,
} from './api'
import { invalidateDashboardCache, refreshDashboard } from './store'
import type {
  KeeperConversationDelivery,
  KeeperDiagnostic,
  KeeperStatusDetail,
} from './types'
import {
  activeKeeperName,
  keeperActionErrors,
  keeperHydrating,
  keeperProbing,
  keeperRecovering,
  keeperSending,
  keeperStatusDetails,
  keeperStreamStartedAt,
  keeperThreads,
  appendThreadEntry,
  clearActiveStream,
  finalizeAssistantEntry,
  normalizeKeeperProbeResult,
  normalizeKeeperRecoverResult,
  normalizeStatusDetail,
  setActiveStream,
  setRecordValue,
  setStatusDetail,
  updateDiagnostic,
} from './keeper-state'
import { abortKeeperThreadMessage, applyKeeperStreamEvent } from './keeper-stream'

async function refreshDashboardState(): Promise<void> {
  invalidateDashboardCache()
  try {
    await refreshDashboard({ force: true })
  } catch (err) {
    console.warn('[keeper-runtime] dashboard refresh failed', err)
  }
}

export function selectKeeper(name: string): void {
  activeKeeperName.value = name.trim()
}

export async function hydrateKeeperStatus(name: string, force = false): Promise<KeeperStatusDetail | null> {
  const keeperName = name.trim()
  if (!keeperName) return null
  if (!force && keeperStatusDetails.value[keeperName]) return keeperStatusDetails.value[keeperName]
  setRecordValue(keeperHydrating, keeperName, true)
  setRecordValue(keeperActionErrors, keeperName, null)
  try {
    const text = await callMcpTool('masc_keeper_status', {
      name: keeperName,
      fast: false,
      include_context: true,
      include_metrics_overview: true,
      include_memory_bank: false,
      include_history_tail: true,
      include_compaction_history: false,
      tail_turns: 5,
      tail_messages: 50,
    })
    let parsed: unknown = null
    try {
      parsed = JSON.parse(text)
    } catch {
      parsed = null
    }
    const detail = normalizeStatusDetail(keeperName, text, parsed)
    setStatusDetail(keeperName, detail)
    return detail
  } catch (err) {
    const message = err instanceof Error ? err.message : `Failed to inspect ${keeperName}`
    console.warn(`[keeper] hydration failed for ${keeperName}:`, message)
    setRecordValue(keeperActionErrors, keeperName, message)
    return null
  } finally {
    setRecordValue(keeperHydrating, keeperName, false)
  }
}

export async function loadFullKeeperHistory(name: string): Promise<void> {
  const keeperName = name.trim()
  if (!keeperName) return
  setRecordValue(keeperHydrating, keeperName, true)
  try {
    const text = await callMcpTool('masc_keeper_status', {
      name: keeperName,
      fast: true,
      include_context: false,
      include_metrics_overview: false,
      include_memory_bank: false,
      include_history_tail: true,
      include_compaction_history: false,
      tail_turns: 0,
      tail_messages: 200,
    })
    let parsed: unknown = null
    try { parsed = JSON.parse(text) } catch { parsed = null }
    const detail = normalizeStatusDetail(keeperName, text, parsed)
    setStatusDetail(keeperName, detail)
  } catch (err) {
    console.warn(`[keeper] full history load failed for ${keeperName}`, err instanceof Error ? err.message : err)
  } finally {
    setRecordValue(keeperHydrating, keeperName, false)
  }
}

export async function sendKeeperThreadMessage(name: string, prompt: string): Promise<void> {
  const keeperName = name.trim()
  const message = prompt.trim()
  if (!keeperName || !message) return
  abortKeeperThreadMessage(keeperName)
  const localId = `local-${Date.now()}`
  const assistantId = `reply-${Date.now()}`
  appendThreadEntry(keeperName, {
    id: localId,
    role: 'user',
    source: 'direct_user',
    label: 'You',
    text: message,
    timestamp: new Date().toISOString(),
    delivery: 'sending',
    streamState: null,
    details: null,
  })
  appendThreadEntry(keeperName, {
    id: assistantId,
    role: 'assistant',
    source: 'direct_assistant',
    label: keeperName,
    text: '',
    rawText: '',
    timestamp: null,
    delivery: 'sending',
    streamState: 'opening',
    details: null,
  })
  setRecordValue(keeperSending, keeperName, true)
  setRecordValue(keeperActionErrors, keeperName, null)
  setRecordValue(keeperStreamStartedAt, keeperName, Date.now())
  const controller = new AbortController()
  setActiveStream(keeperName, assistantId, controller)
  let idleTimeoutId: ReturnType<typeof setInterval> | null = null
  try {
    finalizeAssistantEntry(keeperName, localId, { delivery: 'delivered' })

    let lastEventAt = Date.now()
    idleTimeoutId = setInterval(() => {
      if (Date.now() - lastEventAt > 120_000) {
        if (idleTimeoutId != null) clearInterval(idleTimeoutId)
        idleTimeoutId = null
        abortKeeperThreadMessage(keeperName)
      }
    }, 5_000)

    await streamKeeperMessage(keeperName, message, undefined, {
      signal: controller.signal,
      onEvent: event => {
        lastEventAt = Date.now()
        const error = applyKeeperStreamEvent(keeperName, assistantId, event)
        if (error) {
          throw new Error(error)
        }
      },
    })

    const finalEntry =
      (keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantId) ?? null
    const finalText = finalEntry?.text.trim() || '(empty reply)'

    finalizeAssistantEntry(keeperName, assistantId, {
      text: finalText,
      delivery: 'delivered',
      streamState: null,
      timestamp: new Date().toISOString(),
      error: null,
    })
    updateDiagnostic(keeperName, {
      last_reply_status: 'delivered',
      last_reply_at: new Date().toISOString(),
      last_reply_preview: finalText.slice(0, 200),
      last_error: null,
    })
  } catch (err) {
    const isAbort =
      err instanceof Error && err.name === 'AbortError'
    if (isAbort) {
      finalizeAssistantEntry(keeperName, assistantId, {
        delivery: 'timeout',
        streamState: null,
        error: 'Stream cancelled',
        timestamp: new Date().toISOString(),
      })
      updateDiagnostic(keeperName, {
        last_reply_status: 'error',
        last_error: 'Stream cancelled',
      })
      setRecordValue(keeperActionErrors, keeperName, 'Stream cancelled')
      throw err
    }

    const fallbackAllowed =
      !((keeperThreads.value[keeperName] ?? []).find(entry => entry.id === assistantId)?.text.trim())

    if (fallbackAllowed) {
      try {
        const reply = await sendKeeperMessageDetailed(keeperName, message)
        finalizeAssistantEntry(keeperName, assistantId, {
          text: reply.text.trim() || '(empty reply)',
          rawText: reply.details?.replyText ?? (reply.text.trim() || '(empty reply)'),
          delivery: 'delivered',
          streamState: null,
          details: reply.details,
          error: null,
          timestamp: new Date().toISOString(),
        })
        finalizeAssistantEntry(keeperName, localId, { delivery: 'delivered', error: null })
        updateDiagnostic(keeperName, {
          last_reply_status: 'delivered',
          last_reply_at: new Date().toISOString(),
          last_reply_preview: (reply.text.trim() || '(empty reply)').slice(0, 200),
          last_error: null,
        })
        await refreshDashboardState()
        return
      } catch (fallbackErr) {
        console.warn(`[keeper] stream fallback also failed for ${keeperName}`, fallbackErr instanceof Error ? fallbackErr.message : fallbackErr)
      }
    }

    const errorMessage =
      err instanceof Error ? err.message : `Failed to send direct message to ${keeperName}`
    finalizeAssistantEntry(keeperName, assistantId, {
      delivery: 'error' as KeeperConversationDelivery,
      streamState: null,
      error: errorMessage,
      timestamp: new Date().toISOString(),
    })
    finalizeAssistantEntry(keeperName, localId, {
      delivery: 'error' as KeeperConversationDelivery,
      error: errorMessage,
    })
    updateDiagnostic(keeperName, {
      last_reply_status: 'error',
      last_error: errorMessage,
    })
    setRecordValue(keeperActionErrors, keeperName, errorMessage)
    throw err
  } finally {
    if (idleTimeoutId != null) clearInterval(idleTimeoutId)
    clearActiveStream(keeperName)
    setRecordValue(keeperSending, keeperName, false)
    setRecordValue(keeperStreamStartedAt, keeperName, null)
    await refreshDashboardState()
  }
}

export async function probeKeeperRuntime(name: string, actor: string): Promise<KeeperDiagnostic | null> {
  const keeperName = name.trim()
  if (!keeperName) return null
  setRecordValue(keeperProbing, keeperName, true)
  setRecordValue(keeperActionErrors, keeperName, null)
  try {
    const response = await runOperatorAction({
      actor,
      action_type: 'keeper_probe',
      target_type: 'keeper',
      target_id: keeperName,
      payload: {},
    })
    const result = normalizeKeeperProbeResult(response.result)
    const diagnostic = result?.diagnostic ?? null
    if (diagnostic) {
      const existing = keeperStatusDetails.value[keeperName]
      setStatusDetail(keeperName, {
        name: keeperName,
        diagnostic,
        history: existing?.history ?? keeperThreads.value[keeperName] ?? [],
        rawText: existing?.rawText ?? '',
        rawStatus: response.result,
        loadedAt: new Date().toISOString(),
      })
    }
    await refreshDashboardState()
    return diagnostic
  } catch (err) {
    const message = err instanceof Error ? err.message : `Failed to probe ${keeperName}`
    console.warn(`[keeper] probe failed for ${keeperName}:`, message)
    setRecordValue(keeperActionErrors, keeperName, message)
    throw err
  } finally {
    setRecordValue(keeperProbing, keeperName, false)
  }
}

export async function recoverKeeperRuntime(name: string, actor: string): Promise<KeeperDiagnostic | null> {
  const keeperName = name.trim()
  if (!keeperName) return null
  setRecordValue(keeperRecovering, keeperName, true)
  setRecordValue(keeperActionErrors, keeperName, null)
  try {
    const response = await runOperatorAction({
      actor,
      action_type: 'keeper_recover',
      target_type: 'keeper',
      target_id: keeperName,
      payload: {},
    })
    const result = normalizeKeeperRecoverResult(response.result)
    const after = result?.after ?? null
    if (after) {
      const existing = keeperStatusDetails.value[keeperName]
      setStatusDetail(keeperName, {
        name: keeperName,
        diagnostic: after,
        history: existing?.history ?? keeperThreads.value[keeperName] ?? [],
        rawText: existing?.rawText ?? '',
        rawStatus: response.result,
        loadedAt: new Date().toISOString(),
      })
    }
    await refreshDashboardState()
    return after
  } catch (err) {
    const message = err instanceof Error ? err.message : `Failed to recover ${keeperName}`
    console.warn(`[keeper] recovery failed for ${keeperName}:`, message)
    setRecordValue(keeperActionErrors, keeperName, message)
    throw err
  } finally {
    setRecordValue(keeperRecovering, keeperName, false)
  }
}
