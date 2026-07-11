// @vitest-environment jsdom

import { describe, it, expect } from 'vitest'
import { html } from 'htm/preact'
import { render } from 'preact'
import { timelineEventLabel, ToolCallEventRow } from './agent-detail-timeline'
import type { AgentTimelineEvent } from '../api'

describe('timelineEventLabel', () => {
  it('returns Korean label for joined', () => {
    expect(timelineEventLabel('joined')).toBe('참가')
  })

  it('returns Korean labels for task events', () => {
    expect(timelineEventLabel('task_claimed')).toBe('태스크 수임')
    expect(timelineEventLabel('task_started')).toBe('태스크 시작')
    expect(timelineEventLabel('task_completed')).toBe('태스크 완료')
    expect(timelineEventLabel('task_cancelled')).toBe('태스크 취소')
  })

  it('returns Korean label for broadcast', () => {
    expect(timelineEventLabel('broadcast')).toBe('공지')
  })

  it('returns Korean label for tool_call', () => {
    expect(timelineEventLabel('tool_call')).toBe('도구 호출')
  })

  it('returns the type string itself for unknown types', () => {
    expect(timelineEventLabel('unknown')).toBe('unknown')
    expect(timelineEventLabel('')).toBe('')
    expect(timelineEventLabel('custom_event')).toBe('custom_event')
  })
})

describe('ToolCallEventRow source badge', () => {
  const toolCallEvent = (detail: Record<string, unknown>): AgentTimelineEvent => ({
    ts: '',
    type: 'tool_call',
    detail,
  })

  const renderRow = (evt: AgentTimelineEvent): HTMLElement => {
    const host = document.createElement('div')
    render(html`<${ToolCallEventRow} evt=${evt} idx=${0} />`, host)
    return host
  }

  it('marks keeper in-turn executions (keeper.tool_exec producer)', () => {
    const host = renderRow(
      toolCallEvent({ tool_name: 'masc_status', success: true, source: 'keeper_in_turn' }),
    )
    const badge = host.querySelector('[data-tool-source="keeper_in_turn"]')
    expect(badge).not.toBeNull()
    expect(badge?.textContent).toBe('턴 내')
  })

  it('renders no source badge when the source is absent (external tool.called)', () => {
    const host = renderRow(
      toolCallEvent({ tool_name: 'external_tool', success: true, source: null }),
    )
    expect(host.querySelector('[data-tool-source]')).toBeNull()
    expect(host.textContent).toContain('external_tool')
  })
})

