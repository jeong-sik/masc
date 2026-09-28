import { describe, expect, it } from 'vitest'
import { renderCollabEvent, renderCollabSnapshotRow } from './collab-events'

describe('renderCollabEvent', () => {
  it('draws run boundaries with short ids', () => {
    expect(renderCollabEvent({ type: 'run_started', run_id: 'abcdef123456', thread_id: 't' }))
      .toEqual([{ kind: 'run', text: '── run abcdef12 ──' }])
    expect(renderCollabEvent({ type: 'run_finished', run_id: 'ab' }))
      .toEqual([{ kind: 'run', text: '── run ab done ──' }])
  })

  it('draws role headers and text deltas line by line', () => {
    expect(renderCollabEvent({ type: 'text_message_start', message_id: 'm', role: 'user' }))
      .toEqual([{ kind: 'role-user', text: 'you:' }])
    expect(renderCollabEvent({ type: 'text_message_start', message_id: 'm', role: 'assistant' }))
      .toEqual([{ kind: 'role-assistant', text: 'keeper:' }])
    expect(renderCollabEvent({ type: 'text_delta', delta: 'a\nb' })).toEqual([
      { kind: 'text', text: 'a' },
      { kind: 'text', text: 'b' },
    ])
    expect(renderCollabEvent({ type: 'text_message_end' })).toEqual([{ kind: 'text', text: '' }])
  })

  it('skips thinking, usage, pings, and stream bookkeeping', () => {
    const skipped = [
      { type: 'batch_bound', operation_id: 'o', execution_id: 'e' },
      { type: 'reply_details', reply: 'r', turn_outcome: 'visible_reply', turn_ref: 't' },
      { type: 'agent_core_stream_connected' },
      { type: 'agent_core_stream_message_start', provider_message_id: 'p', model: 'm' },
      { type: 'agent_core_stream_message_delta' },
      { type: 'agent_core_stream_message_stop' },
      { type: 'agent_core_stream_ping' },
      { type: 'agent_core_content_block_start', index: 0, content_type: 'text' },
      { type: 'agent_core_content_block_stop', index: 0 },
      { type: 'agent_core_thinking_delta', index: 0, delta: 'hmm' },
      { type: 'agent_core_thinking_signature_delta', index: 0, signature_bytes: 4 },
      { type: 'tool_call_args', occurrence: {}, delta: 'x' },
      { type: 'tool_call_end', occurrence: {} },
    ]
    for (const event of skipped) expect(renderCollabEvent(event)).toEqual([])
  })

  it('draws tools, approvals, and results', () => {
    expect(renderCollabEvent({ type: 'tool_call_start', occurrence: {}, tool_call_name: 'bash' }))
      .toEqual([{ kind: 'tool', text: 'tool: bash' }])
    expect(renderCollabEvent({ type: 'tool_call_args_snapshot', occurrence: {}, snapshot: 'ls' }))
      .toEqual([{ kind: 'tool', text: '  args: ls' }])
    expect(renderCollabEvent({
      type: 'tool_approval_requested', tool_call_id: 'c', tool_call_name: 'bash',
      args: '{}', question: 'Run?', because: 'deploy',
    })).toEqual([{
      kind: 'approval',
      text: 'approval needed (host only): bash — Run? (deploy)',
    }])
    expect(renderCollabEvent({ type: 'tool_approval_settled', tool_call_id: 'c', outcome: 'approved' }))
      .toEqual([{ kind: 'approval', text: 'approval settled: approved' }])
    expect(renderCollabEvent({ type: 'tool_result_ready', occurrence: {}, execution_id: 'e' }))
      .toEqual([{ kind: 'tool', text: '(tool finished)' }])
  })

  it('draws retries only past the first attempt', () => {
    expect(renderCollabEvent({
      type: 'agent_core_runtime_attempt_started', runtime_id: 'r1', attempt_index: 2,
    })).toEqual([{ kind: 'meta', text: '(retrying: attempt 2 via r1)' }])
    expect(renderCollabEvent({
      type: 'agent_core_runtime_attempt_started', attempt_index: 0,
    })).toEqual([])
    expect(renderCollabEvent({ type: 'agent_core_runtime_attempt_started' })).toEqual([])
  })

  it('draws blocks and delivery notes', () => {
    expect(renderCollabEvent({
      type: 'external_effect_completed', target: { kind: 'slack', channel_id: 'C1', thread_ts: 't' },
    })).toEqual([{ kind: 'meta', text: '(already delivered to slack C1/t)' }])
    expect(renderCollabEvent({
      type: 'external_effect_completed', target: { kind: 'dashboard' },
    })).toEqual([{ kind: 'meta', text: '(already delivered to dashboard)' }])
    expect(renderCollabEvent({ type: 'link_block', url: 'https://x', title: 'X' }))
      .toEqual([{ kind: 'media', text: 'link: X <https://x>' }])
    expect(renderCollabEvent({ type: 'image_block', url: 'https://i', caption: 'cap' }))
      .toEqual([{ kind: 'media', text: 'image: https://i (cap)' }])
    expect(renderCollabEvent({ type: 'status_block', kind: 'continuation_checkpoint' })[0]?.kind)
      .toBe('status')
    expect(renderCollabEvent({ type: 'audio_block', token: 't', mime: 'm', message_text: 'hi' }))
      .toEqual([{ kind: 'media', text: 'audio: hi' }])
    expect(renderCollabEvent({
      type: 'tool_context_block', tool_call_id: 'c', name: 'bash',
      args_summary: 'ls', result_summary: 'ok',
    })).toEqual([
      { kind: 'tool', text: 'tool: bash (ls)' },
      { kind: 'tool', text: '  = ok' },
    ])
  })

  it('names unknown tags instead of dropping them', () => {
    expect(renderCollabEvent({ type: 'future_block', x: 1 })).toEqual([
      { kind: 'meta', text: '(unknown event: future_block)' },
    ])
  })
})

describe('renderCollabSnapshotRow', () => {
  it('renders the row event', () => {
    expect(renderCollabSnapshotRow({
      seq: 1, ts: 1.0, event: { type: 'text_delta', delta: 'hi' },
    })).toEqual([{ kind: 'text', text: 'hi' }])
  })

  it('flags unreadable rows visibly', () => {
    expect(renderCollabSnapshotRow(null)[0]?.kind).toBe('error')
    expect(renderCollabSnapshotRow({ seq: 1 })[0]?.kind).toBe('error')
  })
})
