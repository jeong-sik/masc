// MASC collab web viewer — keeper event rendering (RFC-0471 stack 6).
//
// Ports masc_collab_join's render_event: total over the journaled
// keeper_chat_event variant — anything the host can journal, the guest can
// draw or deliberately skip. Thinking stays host-side; usage counters, pings,
// and stream bookkeeping are skipped, same as chat. Unknown tags decode to a
// visible placeholder, never a silent drop.

export type CollabLineKind =
  | 'run'
  | 'role-user'
  | 'role-assistant'
  | 'text'
  | 'tool'
  | 'approval'
  | 'status'
  | 'media'
  | 'error'
  | 'meta'

export interface CollabLine {
  kind: CollabLineKind
  text: string
}

function shortId(id: string): string {
  return id.length <= 8 ? id : id.slice(0, 8)
}

function truncate(max: number, text: string): string {
  return text.length <= max ? text : `${text.slice(0, max)}…`
}

function splitLines(text: string): string[] {
  return text === '' ? [] : text.split('\n')
}

function deliveryTargetText(target: unknown): string | null {
  if (typeof target !== 'object' || target === null || Array.isArray(target)) return null
  const record = target as Record<string, unknown>
  if (record.kind === 'dashboard') return 'dashboard'
  const channelId = record.channel_id
  if (typeof channelId !== 'string' || channelId === '') return null
  if (record.kind === 'discord') return `discord #${channelId}`
  if (record.kind === 'slack') {
    const threadTs = record.thread_ts
    if (typeof threadTs === 'string' && threadTs !== '') return `slack ${channelId}/${threadTs}`
    return `slack ${channelId}`
  }
  return null
}

function statusKindText(kind: unknown): string | null {
  // Mirrors Keeper_chat_blocks.status_kind_connector_text.
  if (kind === 'continuation_checkpoint') {
    return '작업이 체크포인트에 저장되었습니다. 다음 주기에 이어서 처리합니다.'
  }
  if (kind === 'external_effect_pending') {
    return '승인 대기: 외부 작업을 실행하기 전에 확인이 필요합니다.'
  }
  return null
}

/** Render one journaled `keeper_chat_event` object to viewer lines. */
export function renderCollabEvent(event: unknown): CollabLine[] {
  if (typeof event !== 'object' || event === null || Array.isArray(event)) {
    return [{ kind: 'error', text: '(unreadable event: not an object)' }]
  }
  const record = event as Record<string, unknown>
  const tag = record.type
  const text = (name: string): string | null =>
    typeof record[name] === 'string' ? (record[name] as string) : null
  switch (tag) {
    case 'batch_bound':
    case 'reply_details':
    case 'agent_core_stream_connected':
    case 'agent_core_stream_message_start':
    case 'agent_core_stream_message_delta':
    case 'agent_core_stream_message_stop':
    case 'agent_core_stream_ping':
    case 'agent_core_content_block_start':
    case 'agent_core_content_block_stop':
    case 'agent_core_thinking_delta':
    case 'agent_core_thinking_signature_delta':
    case 'tool_call_args':
    case 'tool_call_end':
      return []
    case 'run_started': {
      const runId = text('run_id')
      if (runId === null) return []
      return [{ kind: 'run', text: `── run ${shortId(runId)} ──` }]
    }
    case 'text_message_start': {
      const role = text('role')
      if (role === 'user') return [{ kind: 'role-user', text: 'you:' }]
      if (role === 'assistant') return [{ kind: 'role-assistant', text: 'keeper:' }]
      return []
    }
    case 'text_delta': {
      const delta = text('delta')
      if (delta === null) return []
      return splitLines(delta).map(line => ({ kind: 'text' as const, text: line }))
    }
    case 'text_message_end':
      return [{ kind: 'text', text: '' }]
    case 'external_effect_completed': {
      const target = deliveryTargetText(record.target)
      if (target === null) return []
      return [{ kind: 'meta', text: `(already delivered to ${target})` }]
    }
    case 'run_finished': {
      const runId = text('run_id')
      if (runId === null) return []
      return [{ kind: 'run', text: `── run ${shortId(runId)} done ──` }]
    }
    case 'event_error': {
      const message = text('message')
      if (message === null) return []
      return [{ kind: 'error', text: `error: ${message}` }]
    }
    case 'continuation_checkpoint': {
      const message = text('message')
      if (message === null) return []
      return [{ kind: 'status', text: `(checkpoint) ${message}` }]
    }
    case 'agent_core_runtime_attempt_started': {
      const attemptIndex = record.attempt_index
      if (attemptIndex === null || attemptIndex === undefined || attemptIndex === 0) return []
      if (typeof attemptIndex !== 'number' || !Number.isInteger(attemptIndex)) return []
      const runtimeId = text('runtime_id')
      const via = runtimeId !== null ? ` via ${shortId(runtimeId)}` : ''
      return [{ kind: 'meta', text: `(retrying: attempt ${attemptIndex}${via})` }]
    }
    case 'agent_core_media_delta': {
      const mediaType = text('media_type')
      const mediaRef = text('media_ref')
      if (mediaType === null || mediaRef === null) return []
      return [{ kind: 'media', text: `(media ${mediaType}: ${mediaRef})` }]
    }
    case 'agent_core_stream_protocol_error':
      return [{ kind: 'error', text: '(stream protocol error)' }]
    case 'tool_call_start': {
      const name = text('tool_call_name')
      if (name === null) return []
      return [{ kind: 'tool', text: `tool: ${name}` }]
    }
    case 'tool_call_args_snapshot': {
      const snapshot = text('snapshot')
      if (snapshot === null) return []
      return [{ kind: 'tool', text: `  args: ${truncate(500, snapshot)}` }]
    }
    case 'tool_approval_requested': {
      const name = text('tool_call_name')
      const question = text('question')
      const because = text('because')
      if (name === null || question === null || because === null) return []
      return [{
        kind: 'approval',
        text: `approval needed (host only): ${name} — ${question} (${because})`,
      }]
    }
    case 'tool_approval_settled': {
      const outcome = text('outcome')
      if (outcome === null) return []
      return [{ kind: 'approval', text: `approval settled: ${outcome}` }]
    }
    case 'tool_result_ready':
      return [{ kind: 'tool', text: '(tool finished)' }]
    case 'link_block': {
      const url = text('url')
      const title = text('title')
      if (url === null || title === null) return []
      return [{ kind: 'media', text: `link: ${title} <${url}>` }]
    }
    case 'image_block': {
      const url = text('url')
      if (url === null) return []
      const caption = text('caption')
      return [{
        kind: 'media',
        text: caption !== null ? `image: ${url} (${caption})` : `image: ${url}`,
      }]
    }
    case 'status_block': {
      const status = statusKindText(record.kind)
      if (status === null) return []
      return [{ kind: 'status', text: `(status) ${status}` }]
    }
    case 'audio_block': {
      const message = text('message_text')
      if (message === null) return []
      return [{ kind: 'media', text: `audio: ${message}` }]
    }
    case 'tool_context_block': {
      const name = text('name')
      const argsSummary = text('args_summary')
      if (name === null || argsSummary === null) return []
      const head: CollabLine = {
        kind: 'tool',
        text: `tool: ${name} (${truncate(300, argsSummary)})`,
      }
      const resultSummary = text('result_summary')
      if (resultSummary === null) return [head]
      return [head, { kind: 'tool', text: `  = ${truncate(500, resultSummary)}` }]
    }
    default:
      return [{ kind: 'meta', text: `(unknown event: ${String(tag)})` }]
  }
}

/** Render one snapshot row (`{seq, ts, event}`). */
export function renderCollabSnapshotRow(row: unknown): CollabLine[] {
  if (typeof row !== 'object' || row === null || Array.isArray(row)) {
    return [{ kind: 'error', text: '(unreadable snapshot row: not an object)' }]
  }
  const event = (row as Record<string, unknown>).event
  if (event === undefined) return [{ kind: 'error', text: '(unreadable snapshot row: no event)' }]
  return renderCollabEvent(event)
}
