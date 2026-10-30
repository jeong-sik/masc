import { html } from 'htm/preact'
import { SurfaceCard } from './common/card'
import { SetupGuideCard } from './setup-guide-card'
import { KNOWN_CONNECTOR_IDS, CONNECTOR_DISPLAY_NAMES, channelIcon, connectorAccentStyle } from './connector-constants'

export function ConnectorOnboardingGrid() {
  return html`<div class="v2-connector-onboarding">
    <p class="mb-3 text-sm">채널 연결을 설정한 뒤 MASC 서버를 재기동하세요.</p>
    <div class="grid grid-cols-2 gap-3 max-[900px]:grid-cols-1">
      ${KNOWN_CONNECTOR_IDS.map(id => html`<${SurfaceCard} style=${connectorAccentStyle(id)}>
        <strong>${channelIcon(id)} ${CONNECTOR_DISPLAY_NAMES[id]}</strong>
        <${SetupGuideCard} connectorId=${id} />
      </${SurfaceCard}>`)}
    </div>
  </div>`
}
