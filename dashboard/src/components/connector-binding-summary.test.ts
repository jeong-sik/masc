// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import { ConnectorBindingSummary } from './connector-binding-summary'
import type { DiscordConfiguredBinding, ConnectorNames } from '../api/gate'

const binding = (ch: string, kp: string): DiscordConfiguredBinding =>
  ({ channel_id: ch, keeper_name: kp } as DiscordConfiguredBinding)

const names: ConnectorNames = {
  channel_names: { '111': 'general', '222': 'ops' },
  channel_to_guild: { '111': 'g1', '222': 'g1' },
  guild_names: { g1: 'Acme' },
} as ConnectorNames

describe('ConnectorBindingSummary', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
  })
  afterEach(() => { document.body.removeChild(container) })

  it('renders nothing when bindings array is empty', () => {
    render(html`<${ConnectorBindingSummary} connectorId="discord" bindings=${[]} names=${names} />`, container)
    expect(container.querySelector('[data-binding-summary]')).toBeNull()
  })

  it('renders one <li> per binding with humanized channel name', () => {
    render(
      html`<${ConnectorBindingSummary}
        connectorId="discord"
        bindings=${[binding('111', 'kpr-a'), binding('222', 'kpr-b')]}
        names=${names}
      />`,
      container,
    )
    const items = container.querySelectorAll('[data-binding-summary] li')
    expect(items.length).toBe(2)
    expect(items[0]!.textContent).toContain('kpr-a')
    expect(items[0]!.textContent).toContain('#general')
    expect(items[1]!.textContent).toContain('#ops')
  })

  it('falls back to raw channel_id when names is undefined', () => {
    render(
      html`<${ConnectorBindingSummary}
        connectorId="discord"
        bindings=${[binding('9999', 'kpr-x')]}
        names=${undefined}
      />`,
      container,
    )
    const li = container.querySelector('[data-binding-summary] li')
    expect(li?.textContent).toContain('9999')
  })

  it('collapses after 6 bindings to a "+N more" link', () => {
    const many = Array.from({ length: 10 }, (_, i) => binding(String(i), `kpr-${i}`))
    render(
      html`<${ConnectorBindingSummary} connectorId="discord" bindings=${many} names=${undefined} />`,
      container,
    )
    const items = container.querySelectorAll('[data-binding-summary] li')
    expect(items.length).toBe(7) // 6 visible + 1 overflow row
    const overflow = items[items.length - 1]!.textContent ?? ''
    expect(overflow).toContain('+4 more')
  })
})
