import { html } from 'htm/preact'
import { route } from '../router'
import { agents } from '../store'
import { Card } from './common/card'
import { EmptyState } from './common/empty-state'
import { Trpg } from './trpg'
import { Tools } from './tools'
import { AgentAvatar } from './overview/agent-avatar'

function AvatarGallery() {
  const agentList = agents.value
  // Use real agents from store, fall back to empty if none loaded
  const displayAgents = agentList.slice(0, 12)

  if (displayAgents.length === 0) {
    return html`<${EmptyState} message="에이전트 데이터를 불러오는 중..." compact />`
  }

  return html`
    <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(80px, 1fr)); gap: 16px; padding: 16px 0;">
      ${displayAgents.map((a: { name: string; status?: string; traits?: string[] }) => html`
        <${AgentAvatar}
          key=${a.name}
          name=${a.name}
          status=${a.status ?? 'idle'}
          traits=${a.traits ?? []}
          size="md"
          showName=${true}
        />
      `)}
    </div>
    <div style="margin-top: 16px; display: flex; gap: 24px; flex-wrap: wrap;">
      <div>
        <div style="color: var(--text-muted); font-size: 11px; margin-bottom: 8px;">SIZES</div>
        <div style="display: flex; gap: 12px; align-items: end;">
          ${displayAgents.slice(0, 3).map((a: { name: string }, i: number) => html`
            <${AgentAvatar}
              key=${'size-' + a.name}
              name=${a.name}
              size=${(['sm', 'md', 'lg'] as const)[i]}
              showName=${true}
            />
          `)}
        </div>
      </div>
    </div>
  `
}

export function Lab() {
  const section = route.value.params.section ?? 'tools'

  return html`
    <div>
      ${section === 'tools' ? html`
        <${Tools} />
      ` : null}

      ${section === 'avatars' ? html`
        <${Card} title="아바타 갤러리" class="section mb-4">
          <${AvatarGallery} />
        <//>
      ` : null}

      ${section === 'trpg'
        ? html`
            <${Card} title="TRPG 실험" class="section mb-4">
              <${Trpg} />
            <//>
          `
        : null}
    </div>
  `
}
