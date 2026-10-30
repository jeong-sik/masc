// @vitest-environment jsdom

import { html } from 'htm/preact'
import { render } from 'preact'
import { fireEvent } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import type { KeeperConversationEntry, SurfaceRef } from '../../types'
import { ChatTranscript } from './primitives'
import {
  buildChatContextScope,
  ChatContextScopeRow,
  ChatSpeakerHandle,
  speakerHandleLabel,
} from './message-context-scope'

const DISCORD_SURFACE: SurfaceRef = {
  kind: 'discord',
  guild_id: 'guild-1',
  channel_id: 'chan-9',
}

function entry(overrides: Partial<KeeperConversationEntry>): KeeperConversationEntry {
  return {
    id: 'm0',
    role: 'user',
    source: 'direct_user',
    label: 'operator',
    text: 'text',
    timestamp: '2026-08-23T13:50:00Z',
    delivery: 'history',
    ...overrides,
  } as KeeperConversationEntry
}

function channelEntry(
  id: string,
  timestamp: string,
  text: string,
  overrides: Partial<KeeperConversationEntry> = {},
): KeeperConversationEntry {
  return entry({
    id,
    timestamp,
    text,
    surface: DISCORD_SURFACE,
    conversationId: 'conv-1',
    ...overrides,
  })
}

let container: HTMLDivElement | null = null

afterEach(() => {
  if (!container) return
  render(null, container)
  container.remove()
  container = null
})

function mount(vnode: Parameters<typeof render>[0]) {
  container = document.createElement('div')
  document.body.appendChild(container)
  render(vnode, container)
  return container
}

describe('buildChatContextScope', () => {
  it('returns null for dashboard/agent surfaces and rows without channel coordinates', () => {
    const e = entry({ id: 'm1' })
    expect(buildChatContextScope(e, [e])).toBeNull()

    const dashboard = entry({ id: 'm2', surface: { kind: 'dashboard', session_id: 's1' } })
    expect(buildChatContextScope(dashboard, [dashboard])).toBeNull()

    const agent = entry({ id: 'm3', surface: { kind: 'agent', channel_id: 'c1' } })
    expect(buildChatContextScope(agent, [agent])).toBeNull()

    const noChannel = entry({ id: 'm4', surface: { kind: 'discord', guild_id: 'g' } })
    expect(buildChatContextScope(noChannel, [noChannel])).toBeNull()
  })

  it('groups rows by conversation_id and derives count, range and preview from the transcript', () => {
    const target = channelEntry('m3', '2026-08-23T14:05:00Z', 'ok 그럼 호출부도 내가 같이 정리할게요.', {
      speakerName: 'sangsu',
      speakerId: 'sangsu',
    })
    const transcript = [
      channelEntry('m1', '2026-08-23T13:50:00Z', 'writer fd 누수 건 보고 있는데', { speakerName: 'sangsu' }),
      channelEntry('m2', '2026-08-23T13:58:00Z', 'fiber 취소가 핵심이라 그게 맞아요.', { role: 'assistant', label: 'claude' }),
      target,
      channelEntry('m9', '2026-08-23T15:00:00Z', '다른 채널', { conversationId: 'conv-2' }),
      entry({ id: 'm10', timestamp: '2026-08-23T14:00:00Z', text: '대시보드 직접 메시지' }),
    ]
    const scope = buildChatContextScope(target, transcript)
    expect(scope).not.toBeNull()
    expect(scope!.channel).toBe('#chan-9')
    expect(scope!.guild).toBe('guild-1')
    expect(scope!.via).toBe('discord')
    expect(scope!.msgs).toBe(3)
    expect(scope!.range).toMatch(/^\d{2}:\d{2}–\d{2}:\d{2}$/)
    expect(scope!.preview).toHaveLength(3)
    expect(scope!.preview[0]!.who).toBe('@sangsu')
    expect(scope!.preview[1]!.who).toBe('claude')
    expect(scope!.preview[2]!.text).toContain('호출부')
  })

  it('prefers surface.label for the channel name when the connector supplies one', () => {
    const e = channelEntry('m1', '2026-08-23T13:50:00Z', '본문', {
      surface: { ...DISCORD_SURFACE, label: '#core-eng' },
    })
    expect(buildChatContextScope(e, [e])!.channel).toBe('#core-eng')
  })

  it('falls back to channel coordinates when conversation_id is absent', () => {
    const target = entry({
      id: 'm2',
      timestamp: '2026-08-23T14:00:00Z',
      text: '두 번째',
      surface: DISCORD_SURFACE,
    })
    const transcript = [
      entry({ id: 'm1', timestamp: '2026-08-23T13:55:00Z', text: '첫 번째', surface: DISCORD_SURFACE }),
      target,
    ]
    const scope = buildChatContextScope(target, transcript)
    expect(scope!.msgs).toBe(2)
  })

  it('collapses a single-message scope to a single timestamp and caps preview at 3 rows', () => {
    const target = channelEntry('m5', '2026-08-23T14:05:00Z', '다섯')
    const transcript = [
      channelEntry('m1', '2026-08-23T13:50:00Z', '하나'),
      channelEntry('m2', '2026-08-23T13:51:00Z', '둘'),
      channelEntry('m3', '2026-08-23T13:52:00Z', '셋'),
      channelEntry('m4', '2026-08-23T13:53:00Z', '넷'),
      target,
    ]
    const scope = buildChatContextScope(target, transcript)
    expect(scope!.msgs).toBe(5)
    expect(scope!.preview).toHaveLength(3)
    expect(scope!.preview[0]!.text).toBe('셋')

    const solo = buildChatContextScope(target, [target])
    expect(solo!.range).toMatch(/^\d{2}:\d{2}$/)
    expect(solo!.preview).toHaveLength(1)
  })
})

describe('speakerHandleLabel', () => {
  it('renders the @handle only when both nick and handle exist on a user row', () => {
    expect(speakerHandleLabel(entry({ speakerName: 'sangsu', speakerId: 'sangsu' }))).toBe('@sangsu')
    expect(speakerHandleLabel(entry({ speakerName: 'sangsu' }))).toBeNull()
    expect(speakerHandleLabel(entry({ speakerId: 'sangsu' }))).toBeNull()
    expect(speakerHandleLabel(entry({ role: 'assistant', speakerName: 'sangsu', speakerId: 'sangsu' }))).toBeNull()
  })

  it('keeps an already-prefixed handle as-is', () => {
    expect(speakerHandleLabel(entry({ speakerName: 'sangsu', speakerId: '@sangsu' }))).toBe('@sangsu')
  })
})

describe('ChatSpeakerHandle', () => {
  it('renders the design whoh span with the handle', () => {
    const el = mount(html`<${ChatSpeakerHandle} entry=${entry({ speakerName: 'sangsu', speakerId: 'sangsu' })} />`)
    const handle = el.querySelector('.whoh')
    expect(handle?.textContent).toBe('@sangsu')
  })
})

describe('ChatContextScopeRow', () => {
  function scopeFor() {
    const target = channelEntry('m2', '2026-08-23T14:05:00Z', '호출부 정리', { speakerName: 'sangsu' })
    const transcript = [
      channelEntry('m1', '2026-08-23T13:50:00Z', 'fd 누수 보고', { speakerName: 'sangsu' }),
      target,
    ]
    return buildChatContextScope(target, transcript)!
  }

  it('renders the ctx-from head with channel, count and range', () => {
    const el = mount(html`<${ChatContextScopeRow} scope=${scopeFor()} />`)
    const head = el.querySelector('.ctx-from')
    expect(head).not.toBeNull()
    expect(head!.textContent).toContain('#chan-9')
    expect(head!.textContent).toContain('맥락 포함 · 메시지 2개')
    expect(el.querySelector('.cf-view')?.textContent).toBe('범위 보기')
    expect(el.querySelector('.cf-detail')).toBeNull()
  })

  it('expands the cf-detail preview on 범위 보기 and collapses on 접기', () => {
    const el = mount(html`<${ChatContextScopeRow} scope=${scopeFor()} />`)
    fireEvent.click(el.querySelector('.cf-view')!)

    const detail = el.querySelector('.cf-detail')
    expect(detail).not.toBeNull()
    expect(detail!.querySelector('.cf-detail-h')?.textContent).toContain('discord 가 가져온 2개 중 일부')
    const rows = detail!.querySelectorAll('.cf-msg')
    expect(rows).toHaveLength(2)
    expect(rows[0]!.querySelector('.cf-who')?.textContent).toBe('@sangsu')
    expect(rows[0]!.querySelector('.cf-text')?.textContent).toContain('fd 누수')
    expect(rows[0]!.querySelector('.cf-ts')).not.toBeNull()
    expect(el.querySelector('.cf-view')?.textContent).toBe('접기')

    fireEvent.click(el.querySelector('.cf-view')!)
    expect(el.querySelector('.cf-detail')).toBeNull()
  })
})

describe('ChatTranscript wiring', () => {
  it('renders the ctx-from strip only on connector-channel messages', () => {
    const channelMsg = channelEntry('m1', '2026-08-23T13:50:00Z', '채널 메시지', { speakerName: 'sangsu', speakerId: 'sangsu' })
    const directMsg = entry({ id: 'm2', timestamp: '2026-08-23T14:00:00Z', text: '대시보드 메시지' })
    const el = mount(html`
      <${ChatTranscript}
        entries=${[channelMsg, directMsg]}
        emptyText="없음"
        variant="messenger"
      />
    `)
    const strip = el.querySelector('.ctx-from')
    expect(strip).not.toBeNull()
    expect(strip!.textContent).toContain('맥락 포함 · 메시지 1개')
    // The dashboard-authored row carries no channel surface → no strip, but
    // the speaker handle still renders on the connector user row.
    expect(el.querySelectorAll('.ctx-from')).toHaveLength(1)
    expect(el.querySelector('.whoh')?.textContent).toBe('@sangsu')
  })

  it('renders neither strip nor handle for dashboard-only transcripts', () => {
    const directMsg = entry({ id: 'm1', timestamp: '2026-08-23T14:00:00Z', text: '안녕' })
    const el = mount(html`
      <${ChatTranscript} entries=${[directMsg]} emptyText="없음" variant="messenger" />
    `)
    expect(el.querySelector('.ctx-from')).toBeNull()
    expect(el.querySelector('.whoh')).toBeNull()
  })
})
