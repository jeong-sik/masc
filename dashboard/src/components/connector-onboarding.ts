// ConnectorOnboardingGrid — rendered when the Channel Gate has not advertised
// a single connector yet (cold-start state). Lays out the 4 known sidecars as
// brand-coloured cards so a new operator can pick which bridge to bring up
// first instead of staring at a blank screen.

import { html } from 'htm/preact'
import { CopyableCode } from './common/copyable-code'
import { ActionButton } from './common/button'
import { SetupGuideCard } from './setup-guide-card'
import {
  channelIcon,
  connectorAccentStyle,
  sidecarCommands,
  startSidecar,
  CONNECTOR_DISPLAY_NAMES,
  KNOWN_CONNECTOR_IDS,
  type KnownConnectorId,
} from './connector-status'
import { ConnectorBulkActions } from './connector-overview-strip'

function OnboardingCard({ connectorId }: { connectorId: KnownConnectorId }) {
  const cmds = sidecarCommands(connectorId)
  return html`
    <div class="rounded-xl border border-[var(--white-8)] p-4" style=${connectorAccentStyle(connectorId)}>
      <div class="mb-2 flex items-center justify-between gap-2">
        <div class="flex items-center gap-2">
          <span class="text-base leading-none" aria-hidden="true">${channelIcon(connectorId)}</span>
          <span class="text-sm font-semibold text-[var(--text-body)]">${CONNECTOR_DISPLAY_NAMES[connectorId]}</span>
        </div>
        <${ActionButton}
          variant="primary"
          size="sm"
          onClick=${() => { void startSidecar(connectorId) }}
        >Start<//>
      </div>
      <div class="text-[11px] text-[var(--text-dim)]">
        <strong>Start</strong>를 누르면 backend가 sidecar를 spawn합니다. 또는 명령을 복사해 새 터미널에서 직접 실행하세요.
      </div>
      <div class="mt-2 grid grid-cols-1 gap-1.5">
        <${CopyableCode} label="start" command=${cmds.start} />
        <${CopyableCode} label="tail logs" command=${cmds.tail} />
      </div>
      <${SetupGuideCard} connectorId=${connectorId} />
    </div>
  `
}

export function ConnectorOnboardingGrid() {
  return html`
    <div>
      <div class="mb-3">
        <h3 class="text-sm font-semibold text-[var(--text-body)]">아직 연결된 sidecar가 없습니다</h3>
        <div class="mt-1 text-[11px] text-[var(--text-dim)]">
          4개의 채널 sidecar를 켤 수 있습니다. 카드의 시작 명령을 복사해 새 터미널에서 실행하거나, 아래
          <strong>Start All</strong>로 한 번에 spawn하세요. spawn 후 이 화면이 라이브 상태로 갱신됩니다.
        </div>
      </div>
      <${ConnectorBulkActions} connectors=${[]} />
      <div class="grid grid-cols-2 gap-3 max-[900px]:grid-cols-1">
        ${KNOWN_CONNECTOR_IDS.map(id => html`<${OnboardingCard} connectorId=${id} />`)}
      </div>
    </div>
  `
}
