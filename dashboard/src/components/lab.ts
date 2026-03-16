import { html } from 'htm/preact'
import { route } from '../router'
import { Card } from './common/card'
import { Trpg } from './trpg'
import { AgentAvatar } from './overview/agent-avatar'

const AVATAR_TEST_AGENTS = [
  { name: 'dreamer', status: 'active', traits: ['creative'] },
  { name: 'sentinel', status: 'busy', traits: ['robot', 'security'] },
  { name: 'chronicler', status: 'idle', traits: ['abstract'] },
  { name: 'harbinger', status: 'listening', traits: ['animal'] },
  { name: 'wanderer', status: 'offline', traits: [] },
  { name: 'architect', status: 'active', traits: ['system'] },
  { name: 'healer', status: 'idle', traits: ['creature'] },
  { name: 'oracle', status: 'busy', traits: ['machine'] },
]

function AvatarGallery() {
  return html`
    <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(80px, 1fr)); gap: 16px; padding: 16px 0;">
      ${AVATAR_TEST_AGENTS.map(a => html`
        <${AgentAvatar}
          key=${a.name}
          name=${a.name}
          status=${a.status}
          traits=${a.traits}
          size="md"
          showName=${true}
        />
      `)}
    </div>
    <div style="margin-top: 16px; display: flex; gap: 24px; flex-wrap: wrap;">
      <div>
        <div style="color: var(--text-muted); font-size: 11px; margin-bottom: 8px;">SIZES</div>
        <div style="display: flex; gap: 12px; align-items: end;">
          <${AgentAvatar} name="size-sm" size="sm" showName=${true} />
          <${AgentAvatar} name="size-md" size="md" showName=${true} />
          <${AgentAvatar} name="size-lg" size="lg" showName=${true} />
        </div>
      </div>
      <div>
        <div style="color: var(--text-muted); font-size: 11px; margin-bottom: 8px;">STATES</div>
        <div style="display: flex; gap: 12px; align-items: end;">
          <${AgentAvatar} name="active" status="active" showName=${true} />
          <${AgentAvatar} name="busy" status="busy" showName=${true} />
          <${AgentAvatar} name="idle" status="idle" showName=${true} />
          <${AgentAvatar} name="listening" status="listening" showName=${true} />
          <${AgentAvatar} name="offline" status="offline" showName=${true} />
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
