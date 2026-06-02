import { html } from 'htm/preact'
import { render } from 'preact'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'

import { useOperatorMentionContext, type OperatorMentionContext } from './use-operator-mention-context'
import { operatorSnapshot } from '../../operator-store'
import type { OperatorKeeperSnapshot, OperatorSnapshot } from '../../types'

const LISTBOX_ID = 'test-listbox'

function snapshotWithKeepers(keepers: OperatorKeeperSnapshot[]): OperatorSnapshot {
  return {
    root: { paused: false, namespace: 'default' },
    sessions: [],
    keepers,
    recent_messages: [],
    pending_confirms: [],
    available_actions: [],
  } as unknown as OperatorSnapshot
}

function Probe({
  message,
  target,
  dmActive,
  onContext,
}: {
  message: string
  target: string
  dmActive: boolean
  onContext: (ctx: OperatorMentionContext) => void
}) {
  const ctx = useOperatorMentionContext({ message, target, dmActive, listboxId: LISTBOX_ID })
  // Capture synchronously during render — vitest jsdom does not flush
  // useEffect within the await-microtask window the test uses.
  onContext(ctx)
  return html`<div data-testid="probe-online">${ctx.onlineKeeperNames}</div>`
}

describe('useOperatorMentionContext', () => {
  let container: HTMLDivElement
  let captured: OperatorMentionContext | null

  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    captured = null
  })

  afterEach(() => {
    render(null, container)
    container.remove()
    operatorSnapshot.value = null
  })

  it('filters keepers via isKeeperOperatorTargetable (paused stays, offline drops)', async () => {
    operatorSnapshot.value = snapshotWithKeepers([
      { name: 'alpha', status: 'active' } as OperatorKeeperSnapshot,
      { name: 'beta',  status: 'offline' } as OperatorKeeperSnapshot,
      { name: 'gamma', status: 'paused', paused: true } as OperatorKeeperSnapshot,
    ])

    render(
      html`<${Probe} message="" target="" dmActive=${false} onContext=${(c: OperatorMentionContext) => { captured = c }} />`,
      container,
    )

    expect(captured?.onlineKeepers.map(k => k.name).sort()).toEqual(['alpha', 'gamma'])
    expect(captured?.onlineKeeperNames).toBe('alpha\0gamma')
  })

  it('skips mention parsing when dmActive is false', async () => {
    operatorSnapshot.value = snapshotWithKeepers([
      { name: 'alpha', status: 'active' } as OperatorKeeperSnapshot,
    ])

    render(
      html`<${Probe} message="hello @al" target="" dmActive=${false} onContext=${(c: OperatorMentionContext) => { captured = c }} />`,
      container,
    )

    expect(captured?.mentionQuery).toBeNull()
    expect(captured?.mentionMatches).toEqual([])
    expect(captured?.mentionListOpen).toBe(false)
  })

  it('parses mention query and resolves trailing @name target when dmActive', async () => {
    operatorSnapshot.value = snapshotWithKeepers([
      { name: 'alpha', status: 'active' } as OperatorKeeperSnapshot,
      { name: 'beta',  status: 'active' } as OperatorKeeperSnapshot,
    ])

    render(
      html`<${Probe} message="hi @al" target="" dmActive=${true} onContext=${(c: OperatorMentionContext) => { captured = c }} />`,
      container,
    )

    expect(captured?.mentionQuery).toBe('al')
    expect(captured?.mentionMatches.map(m => m.name)).toContain('alpha')
    expect(captured?.mentionListOpen).toBe(true)
  })

  it('routes effective target: trailing mention overrides selected target', async () => {
    operatorSnapshot.value = snapshotWithKeepers([
      { name: 'alpha', status: 'active' } as OperatorKeeperSnapshot,
      { name: 'beta',  status: 'active' } as OperatorKeeperSnapshot,
    ])

    render(
      html`<${Probe} message="ping @beta " target="keeper:alpha" dmActive=${true} onContext=${(c: OperatorMentionContext) => { captured = c }} />`,
      container,
    )

    expect(captured?.selectedKeeper).toBe('alpha')
    expect(captured?.trailingMentionTarget).toBe('beta')
    expect(captured?.effectiveKeeper).toBe('beta')
    expect(captured?.effectiveKeeperOnline).toBe(true)
  })

  it('flags unresolvedTrailingMention when @name does not match any online keeper', async () => {
    operatorSnapshot.value = snapshotWithKeepers([
      { name: 'alpha', status: 'active' } as OperatorKeeperSnapshot,
    ])

    render(
      html`<${Probe} message="@ghost " target="" dmActive=${true} onContext=${(c: OperatorMentionContext) => { captured = c }} />`,
      container,
    )

    expect(captured?.trailingMention).toBe('ghost')
    expect(captured?.trailingMentionTarget).toBeNull()
    expect(captured?.unresolvedTrailingMention).toBe(true)
    expect(captured?.effectiveKeeperOnline).toBe(false)
  })

  it('builds per-option activeMentionOptionId from listboxId', async () => {
    operatorSnapshot.value = snapshotWithKeepers([
      { name: 'alpha', status: 'active' } as OperatorKeeperSnapshot,
    ])

    render(
      html`<${Probe} message="@a" target="" dmActive=${true} onContext=${(c: OperatorMentionContext) => { captured = c }} />`,
      container,
    )

    expect(captured?.activeMentionOptionId).toBe(`${LISTBOX_ID}-option-0`)
  })
})
