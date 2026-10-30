import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { SurfaceCard } from './common/card'
import { CopyableCode } from './common/copyable-code'
import { SetupGuideCard } from './setup-guide-card'
const openPanels = signal<Record<string, boolean>>({})
interface InProcessConfigGuide {
  displayName: string
  // One or more env vars the operator sets. The first is the activation
  // credential; additional entries (Slack's outbound bot token) render
  // alongside it. Each is looked up in FIELD_HINTS for a "where to find it" card.
  envVars: string[]
  docsRef: string
  supportsRuntimeToml: boolean
}

const IN_PROCESS_CONFIG_GUIDES: Record<string, InProcessConfigGuide> = {
  telegram: {supportsRuntimeToml:true, displayName: 'Telegram', envVars: ['TELEGRAM_BOT_TOKEN'], docsRef: 'docs/CONNECTOR-CONFIG-SCHEMA.md'},
  imessage: {supportsRuntimeToml:false, displayName: 'iMessage', envVars: [], docsRef: 'docs/CONNECTOR-CONFIG-SCHEMA.md'},
  discord: {
    supportsRuntimeToml: false,
    displayName: 'Discord',
    envVars: ['DISCORD_BOT_TOKEN'],
    docsRef: 'docs/CONNECTOR-CONFIG-SCHEMA.md',
  },
  slack: {
    supportsRuntimeToml: false,
    displayName: 'Slack',
    envVars: ['SLACK_APP_TOKEN', 'SLACK_BOT_TOKEN'],
    docsRef: 'docs/rfc/RFC-0317-slack-builtin-gateway.md',
  },
}

function inProcessConfigGuide(id: string): InProcessConfigGuide | null {
  return IN_PROCESS_CONFIG_GUIDES[id] ?? null
}

interface FieldHint {
  where: string
  url?: string
}

const FIELD_HINTS: Record<string, FieldHint> = {
  DISCORD_BOT_TOKEN: {
    where: 'Discord Developer Portal → Applications → <your app> → Bot → Reset Token',
    url: 'https://discord.com/developers/applications',
  },
  SLACK_BOT_TOKEN: {
    where: 'Slack App → OAuth & Permissions → Bot User OAuth Token (xoxb-…)',
    url: 'https://api.slack.com/apps',
  },
  SLACK_APP_TOKEN: {
    where: 'Slack App → Basic Information → App-Level Tokens → Generate (xapp-…)',
    url: 'https://api.slack.com/apps',
  },
  SLACK_SIGNING_SECRET: {
    where: 'Slack App → Basic Information → App Credentials → Signing Secret',
    url: 'https://api.slack.com/apps',
  },
  TELEGRAM_BOT_TOKEN: {
    where: '@BotFather → /newbot (또는 기존 봇이면 /token)',
    url: 'https://t.me/BotFather',
  },
}

function getFieldHint(name: string): FieldHint | null {
  return FIELD_HINTS[name] ?? null
}

export function ConnectorConfigToggle({connectorId}: {connectorId:string}) {
  return html`<button type="button" aria-expanded=${openPanels.value[connectorId] === true}
    aria-controls=${`connector-config-${connectorId}`}
    onClick=${() => { openPanels.value = {...openPanels.value, [connectorId]: !openPanels.value[connectorId]} }}>⚙ Config</button>`
}
export function ConnectorConfigForm({connectorId}: {connectorId:string}) {
  if (!openPanels.value[connectorId]) return null
  const inProcess = inProcessConfigGuide(connectorId)
  if (inProcess === null) return html`<p>등록되지 않은 채널입니다.</p>`
  if (connectorId === 'imessage') return html`<${SetupGuideCard} connectorId=${connectorId} />`
    return html`
      <${SurfaceCard}
        class="mt-3 !border-[var(--accent-22)] !bg-[var(--accent-12)]/5 !p-3 text-2xs v2-connector-config-form"
        id=${`connector-config-${connectorId}`}
        data-in-process-config-panel
      >
        <div class="mb-2 flex flex-wrap items-center gap-2">
          <span class="text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)]">server in-process</span>
          <span class="font-semibold text-[var(--color-fg-primary)]">${inProcess.displayName} 설정</span>
        </div>
        <div class="text-[var(--color-fg-secondary)]">
          ${inProcess.displayName}는 서버 프로세스 내부 gateway로 실행됩니다. 설정 항목:
          <span class="mx-1 font-mono text-[var(--color-fg-primary)]">${inProcess.envVars.join(', ')}</span>
          ${inProcess.supportsRuntimeToml ? '환경변수 또는 runtime.toml에서 설정하세요.' : '서버 프로세스의 환경변수에 설정하세요.'}
        </div>
        ${inProcess.envVars.map((envVar) => {
          const hint = getFieldHint(envVar)
          return hint === null
            ? null
            : html`
                <${SurfaceCard} class="mt-2 !border-[var(--accent-22)] !bg-[var(--accent-12)]/5 !px-2 !py-1 text-3xs text-[var(--color-accent-fg)]" data-field-hint=${envVar}>
                  <span class="font-mono text-[var(--color-fg-primary)]">${envVar}</span>
                  <span class="ml-1">${hint.where}</span>
                  ${hint.url
                    ? html`
                        <a
                          href=${hint.url}
                          target="_blank"
                          rel="noopener noreferrer"
                          class="v2-mobile-operator-target inline-flex items-center ml-1 underline hover:text-[var(--color-accent-fg)]"
                        >열기 ↗</a>
                      `
                    : null}
                </${SurfaceCard}>
              `
        })}
        <div class="mt-3 border-t border-[var(--color-border-default)] pt-2.5">
          <div class="mb-1 text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)]">
            env
          </div>
          ${inProcess.envVars.map(
            (envVar) => html`
              <div class="mt-1 first:mt-0">
                <${CopyableCode}
                  command=${`${envVar}=<token>`}
                  ariaLabel=${`${inProcess.displayName} in-process env var ${envVar}`}
                />
              </div>
            `,
          )}
          <div class="mt-1 text-3xs text-[var(--color-fg-disabled)]">
            ${inProcess.docsRef} 기준: 서버 환경변수에 설정한 뒤 MASC 서버를 재기동해야 gateway 연결에 반영됩니다.
          </div>
        </div>
      </${SurfaceCard}>
    `
}
export function resetConnectorConfigState() { openPanels.value = {} }
export function openConnectorConfig(id:string) { openPanels.value = {...openPanels.value, [id]:true} }
