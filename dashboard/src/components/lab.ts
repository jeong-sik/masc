import { html } from 'htm/preact'
import { route } from '../router'
import { agents } from '../store'
import { Card } from './common/card'
import { Trpg } from './trpg'
import { AgentAvatar } from './overview/agent-avatar'

function AvatarGallery() {
  const agentList = agents.value
  // Use real agents from store, fall back to empty if none loaded
  const displayAgents = agentList.slice(0, 12)

  if (displayAgents.length === 0) {
    return html`<div class="empty-state">에이전트 데이터를 불러오는 중...</div>`
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
  const surface = route.value.params.surface

  return html`
    <div>
      <${Card} title="Experimental Surface" class="section" semanticId="lab.experimental">
        <div class="monitor-section-head">
          <h2 class="monitor-headline">Lab mode is intentionally outside the main operator console</h2>
          <p class="monitor-subheadline">Experimental features stay here so execution, memory, governance, and command surfaces keep a clear operational meaning.</p>
        </div>
      <//>

      ${surface === 'avatars' ? html`
        <${Card} title="Avatar Gallery" class="section" semanticId="lab.avatars">
          <${AvatarGallery} />
        <//>
      ` : null}

      <${Card} title="TRPG" class="section" semanticId="lab.trpg">
        <${Trpg} />
      <//>
    </div>
  `
}
