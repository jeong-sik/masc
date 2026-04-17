// Connector setup guides — surfaced in the dashboard when a sidecar is offline
// so an operator doesn't need to switch to README/Confluence to find the
// platform-side steps that can't be automated. Keep this data-only — the
// renderer lives in setup-guide-card.ts. Source of truth for the steps:
// docs/CONNECTOR-CONFIG-SCHEMA.md.

export interface SetupStep {
  text: string
  // Optional inline external link rendered after the step text.
  link?: { href: string; label: string }
}

export interface ConnectorSetupGuide {
  title: string
  intro: string
  steps: SetupStep[]
  // Bottom-row reference links (docs, libraries, dashboards on the platform side).
  references: Array<{ href: string; label: string }>
}

export const CONNECTOR_SETUP_GUIDES: Record<string, ConnectorSetupGuide> = {
  discord: {
    title: 'Discord 봇 등록',
    intro: 'Bot Token + Message Content Intent + OAuth bot scope가 필요합니다.',
    steps: [
      {
        text: 'Discord Developer Portal에서 새 Application 생성.',
        link: { href: 'https://discord.com/developers/applications', label: 'Developer Portal' },
      },
      { text: 'Bot 탭 → Reset Token → 토큰 복사 (DISCORD_BOT_TOKEN).' },
      { text: 'Bot 탭 → Privileged Gateway Intents → Message Content Intent 활성화.' },
      { text: 'OAuth2 → URL Generator → scope: bot, permissions: Send Messages / Embed Links / Read Message History.' },
      { text: '생성된 URL을 열어 봇을 길드에 초대.' },
    ],
    references: [
      { href: 'https://discordpy.readthedocs.io/', label: 'discord.py docs' },
      { href: 'https://discord.com/developers/docs/topics/gateway#gateway-intents', label: 'Gateway Intents' },
    ],
  },
  imessage: {
    title: 'iMessage 권한 (macOS only)',
    intro: '인증 토큰이 없습니다 — 대신 OS 권한으로 chat.db에 접근합니다.',
    steps: [
      { text: '시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한 → 사용 중인 터미널/iTerm 추가.' },
      { text: 'Messages.app 로그인 후 열어두기 (chat.db에 최근 메시지가 쌓이도록).' },
      { text: '(옵션) self-chat 모드를 쓸 거면 Messages에서 자기 자신과의 대화를 만든 뒤 chat GUID를 IMESSAGE_SELF_CHAT_GUID에 넣기.' },
    ],
    references: [
      { href: 'https://support.apple.com/en-us/guide/mac-help/mh11479/mac', label: 'macOS Privacy guide' },
    ],
  },
  slack: {
    title: 'Slack App + Socket Mode',
    intro: 'Bot Token (xoxb-)와 App-Level Token (xapp-) 둘 다 필요합니다.',
    steps: [
      {
        text: 'api.slack.com/apps에서 Create New App → From scratch.',
        link: { href: 'https://api.slack.com/apps', label: 'Slack apps' },
      },
      { text: 'Basic Information → App-Level Tokens → Generate, scope connections:write → xapp- 토큰을 SLACK_APP_TOKEN에.' },
      { text: 'Socket Mode → Enable Socket Mode 토글.' },
      { text: 'OAuth & Permissions → Bot Token Scopes에 chat:write, app_mentions:read, im:history, im:read 추가 → Install to Workspace → xoxb- 토큰을 SLACK_BOT_TOKEN에.' },
      { text: 'Event Subscriptions → bot events: app_mention, message.im 구독.' },
    ],
    references: [
      { href: 'https://api.slack.com/apis/connections/socket', label: 'Socket Mode docs' },
      { href: 'https://api.slack.com/scopes', label: 'OAuth scope reference' },
    ],
  },
  telegram: {
    title: 'Telegram BotFather',
    intro: '@BotFather 한 명만 거치면 됩니다. Admin user IDs는 옵션.',
    steps: [
      {
        text: 'Telegram에서 @BotFather에게 /newbot 전송 → 이름과 username 입력 → 출력된 토큰을 TELEGRAM_BOT_TOKEN에.',
        link: { href: 'https://t.me/BotFather', label: '@BotFather' },
      },
      { text: '(옵션) /setprivacy → Disable로 두면 봇이 그룹의 모든 메시지를 받음. 기본은 mention-only.' },
      {
        text: '(옵션) @userinfobot에게 본인 계정으로 /start → 출력된 user ID를 TELEGRAM_ADMIN_USER_IDS에 콤마 구분으로 추가.',
        link: { href: 'https://t.me/userinfobot', label: '@userinfobot' },
      },
    ],
    references: [
      { href: 'https://core.telegram.org/bots', label: 'Telegram Bot API' },
    ],
  },
}
