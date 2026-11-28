// The subscriptions a signed-in person may connect on the account server, as
// `GET /api/v1/auth/integrations` lists them
// (lib/server/server_person_integrations.mli, `answer`): each provider of
// runtime.toml the person may use, how it is connected (`login` through its
// official client, `key` with an API key), and whether the server refuses its
// calls. The Quotas tab lists them under the person's connected accounts, so a
// person with no account yet sees what to connect instead of an empty list.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import type { MultiAccountIntegration } from './types'

export type ConnectWay = 'login' | 'key'

export type CallState =
  | { readonly kind: 'allowed' }
  | { readonly kind: 'refused'; readonly code: string | null }

export interface PersonConnectRow {
  readonly integrationId: string
  readonly displayName: string
  /** The ways the server offers, in its order. */
  readonly ways: readonly ConnectWay[]
  /** Labels the server sent that this page does not know. Shown, not acted on. */
  readonly unknownWays: readonly string[]
  readonly calls: CallState
  /** The person already holds an account of this provider. */
  readonly connected: boolean
}

function connectWayOf(label: string): ConnectWay | null {
  switch (label) {
    case 'login':
      return 'login'
    case 'key':
      return 'key'
    default:
      return null
  }
}

function callStateOf(integration: MultiAccountIntegration): CallState {
  return integration.calls === 'refused'
    ? { kind: 'refused', code: integration.refusal ?? null }
    : { kind: 'allowed' }
}

export function personConnectRows(
  integrations: readonly MultiAccountIntegration[],
  connectedIntegrationIds: ReadonlySet<string>,
): readonly PersonConnectRow[] {
  return integrations.map((integration) => {
    const ways: ConnectWay[] = []
    const unknownWays: string[] = []
    for (const label of integration.connect) {
      const way = connectWayOf(label)
      if (way === null) unknownWays.push(label)
      else if (!ways.includes(way)) ways.push(way)
    }
    return {
      integrationId: integration.integration_id,
      displayName: integration.display_name,
      ways,
      unknownWays,
      calls: callStateOf(integration),
      connected: connectedIntegrationIds.has(integration.integration_id),
    }
  })
}

/** The rows a person can connect with an API key now: the key way is offered
    and the server does not refuse the provider's calls. */
export function keyConnectableRows(rows: readonly PersonConnectRow[]): readonly PersonConnectRow[] {
  return rows.filter((row) => row.calls.kind === 'allowed' && row.ways.includes('key'))
}

export function PersonConnectList({
  rows,
  busy,
  onLogin,
  onKey,
}: {
  readonly rows: readonly PersonConnectRow[]
  readonly busy: boolean
  readonly onLogin: (integrationId: string) => void
  readonly onKey: (integrationId: string) => void
}): VNode {
  return html`
    <div data-testid="person-connect-list" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
      <div style=${{ fontWeight: 600, fontSize: 'var(--fs-12)', color: 'var(--fg-2)' }}>연결할 수 있는 구독</div>
      ${rows.length === 0
        ? html`<div class="dtable-absent">이 서버의 runtime.toml 에 사람이 연결할 수 있는 제공자가 없어요.</div>`
        : rows.map((row) => html`
            <div
              key=${row.integrationId}
              data-testid="person-connect-row"
              style=${{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 'var(--sp-2)', padding: 'var(--sp-2)', border: '1px solid var(--line-1)', borderRadius: 'var(--radius-sm)', flexWrap: 'wrap' }}
            >
              <div>
                <div style=${{ fontWeight: 600, fontSize: 'var(--fs-13)' }}>${row.displayName}</div>
                <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
                  ${row.integrationId}${row.connected ? ' · 연결됨' : ''}
                  ${row.calls.kind === 'refused' ? ` · 서버가 호출을 거절해요${row.calls.code ? ` (${row.calls.code})` : ''}` : ''}
                  ${row.unknownWays.length > 0 ? ` · 모르는 연결 방식: ${row.unknownWays.join(', ')}` : ''}
                </div>
              </div>
              ${row.calls.kind === 'allowed' && html`
                <div style=${{ display: 'flex', gap: 'var(--sp-1)', flexWrap: 'wrap' }}>
                  ${row.ways.map((way) => way === 'login'
                    ? html`<button key="login" type="button" class="btn-ghost" disabled=${busy} onClick=${() => onLogin(row.integrationId)}>로그인으로 연결</button>`
                    : html`<button key="key" type="button" class="btn-ghost" disabled=${busy} onClick=${() => onKey(row.integrationId)}>API 키로 연결</button>`)}
                </div>
              `}
            </div>
          `)}
    </div>
  `
}
