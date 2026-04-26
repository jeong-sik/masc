// ConnectorOnboardingGrid — rendered when the Channel Gate has not advertised
// a single connector yet (cold-start state). Lays out the 4 known sidecars as
// brand-coloured cards so a new operator can pick which bridge to bring up
// first instead of staring at a blank screen.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { CopyableCode } from './common/copyable-code'
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

/** Pure: map the onboarding Start button's inflight flag to the label
    the operator sees. Reference — Vercel's Deploy button transition:
    the static verb ("Deploy") swaps to a gerund ("Deploying…") the
    moment work begins, so the operator never wonders whether the
    click registered. Kept pure so tests can pin the string table. */
export function onboardingStartLabel(starting: boolean): string {
  return starting ? 'Starting…' : 'Start'
}

function OnboardingCard({ connectorId }: { connectorId: KnownConnectorId }) {
  const cmds = sidecarCommands(connectorId)
  const [starting, setStarting] = useState(false)
  const onStart = async () => {
    if (starting) return
    setStarting(true)
    try {
      await startSidecar(connectorId)
    } finally {
      // startSidecar internally refreshes the snapshot; the card will
      // typically unmount (grid → live panel transition) before we
      // land here. Reset defensively in case the snapshot still shows
      // no connector (e.g. backend error path, toast already shown).
      setStarting(false)
    }
  }
  return html`
    <div class="rounded border border-[var(--white-8)] p-4" style=${connectorAccentStyle(connectorId)}>
      <div class="mb-2 flex items-center justify-between gap-2">
        <div class="flex items-center gap-2">
          <span class="text-base leading-none" aria-hidden="true">${channelIcon(connectorId)}</span>
          <span class="text-sm font-semibold text-[var(--color-fg-primary)]">${CONNECTOR_DISPLAY_NAMES[connectorId]}</span>
        </div>
        <button
          type="button"
          class=${`rounded cursor-pointer transition-all duration-200 font-medium border border-solid border-[var(--accent-30)] bg-[var(--accent-12)] text-[var(--color-fg-secondary)] hover:bg-[var(--accent-20)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent-45)] focus-visible:ring-offset-2 focus-visible:ring-offset-[var(--color-bg-surface)] py-1 px-2 text-3xs ${starting ? 'opacity-50 pointer-events-none' : 'active:scale-[0.97]'}`}
          disabled=${starting}
          aria-busy=${starting ? 'true' : 'false'}
          data-onboarding-start=${connectorId}
          onClick=${() => { void onStart() }}
        >${onboardingStartLabel(starting)}</button>
      </div>
      <div class="text-2xs text-[var(--color-fg-disabled)]">
        <strong>Start</strong>를 누르면 backend가 sidecar를 spawn합니다. 또는 명령을 복사해 새 터미널에서 직접 실행하세요.
      </div>
      <div class="mt-2 grid grid-cols-1 gap-1.5">
        <${CopyableCode} label="start" command=${cmds.start} variant="primary" />
        <${CopyableCode} label="tail logs" command=${cmds.tail} variant="secondary" />
      </div>
      <${SetupGuideCard} connectorId=${connectorId} />
    </div>
  `
}

export function ConnectorOnboardingGrid() {
  return html`
    <div>
      <div class="mb-3">
        <h3 class="text-sm font-semibold text-[var(--color-fg-primary)]">아직 연결된 sidecar가 없습니다</h3>
        <div class="mt-1 text-2xs text-[var(--color-fg-disabled)]">
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
