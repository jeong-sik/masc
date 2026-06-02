import { h } from 'preact'
import { cleanup, render, screen } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { MentionInbox, buildMentionInboxModel, extractMentionTargets, mentionTargetCandidates } from './mention-inbox'
import { messages, shellAuthSummary } from '../../store'
import type { DashboardShellAuthSummary, Message } from '../../types'

import '@testing-library/jest-dom'

function auth(overrides: Partial<DashboardShellAuthSummary> = {}): DashboardShellAuthSummary {
  return {
    enabled: true,
    require_token: false,
    default_role: null,
    token_present: true,
    token_valid: true,
    token_agent: 'dashboard',
    requested_agent: null,
    effective_agent: 'dashboard',
    effective_role: 'admin',
    auth_error_code: null,
    auth_error_detail: null,
    can_keeper_msg: true,
    keeper_msg_error: null,
    ...overrides,
  }
}

function message(overrides: Partial<Message> & { content: string }): Message {
  const { content, ...rest } = overrides
  return {
    from: 'keeper',
    content,
    timestamp: '2026-05-06T03:00:00Z',
    ...rest,
  }
}

describe('mention inbox helpers', () => {
  it('extracts unique @targets without treating emails as mentions', () => {
    expect(extractMentionTargets('ping @dashboard and @sangsu, not user@example.com, again @dashboard')).toEqual([
      'dashboard',
      'sangsu',
    ])
  })

  it('builds for-me and other mention lanes from execution messages', () => {
    const model = buildMentionInboxModel(
      [
        message({ id: 'plain', content: 'plain broadcast' }),
        message({ id: 'mine', content: '@dashboard please inspect', seq: 2 }),
        message({ id: 'other', content: '@sangsu has context', seq: 3 }),
        message({ id: 'typed', type: 'message.mentioned', content: 'explicit event without target', seq: 4 }),
      ],
      ['dashboard'],
    )

    expect(model.forMe.map(row => row.message.id)).toEqual(['mine'])
    expect(model.others.map(row => row.message.id)).toEqual(['typed', 'other'])
  })

  it('deduplicates auth and actor aliases as current mention targets', () => {
    expect(mentionTargetCandidates(auth({ token_agent: 'DASHBOARD', effective_agent: 'dashboard' }), 'dashboard')).toEqual([
      'dashboard',
      'operator',
    ])
  })
})

describe('MentionInbox', () => {
  afterEach(() => {
    cleanup()
    messages.value = []
    shellAuthSummary.value = null
  })

  beforeEach(() => {
    messages.value = []
    shellAuthSummary.value = auth()
  })

  it('renders separate for-me and other mention lanes', () => {
    messages.value = [
      message({ id: 'm-1', from: 'sojin', content: '@dashboard review this' }),
      message({ id: 'm-2', from: 'ani', content: '@sangsu I left notes' }),
    ]

    render(h(MentionInbox, null))

    expect(screen.getByRole('heading', { name: 'Mention inbox' })).toBeInTheDocument()
    expect(screen.getByLabelText('For me')).toHaveTextContent('@dashboard')
    expect(screen.getByLabelText('Other mentions')).toHaveTextContent('@sangsu')
  })

  it('marks messages carrying state blocks', () => {
    messages.value = [
      message({
        id: 'm-state',
        content: '@dashboard [STATE]\nGoal: land C2 mention inbox\n[/STATE]\nready',
      }),
    ]

    render(h(MentionInbox, null))

    expect(screen.getByText('STATE')).toBeInTheDocument()
    expect(screen.queryByText('Goal: land C2 mention inbox')).not.toBeInTheDocument()
  })
})
