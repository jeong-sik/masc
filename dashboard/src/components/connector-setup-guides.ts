// Setup guides surfaced in the dashboard. Originally just connector
// onboarding (sidecars), now also covers in-process operator setup like
// the hardened Docker sandbox for keeper playgrounds. The renderer in
// setup-guide-card.ts is data-driven and does not care what the id means.
// Keep this file data-only. Source of truth for connector steps:
// docs/CONNECTOR-CONFIG-SCHEMA.md.

interface SetupStep {
  text: string
  // Optional inline external link rendered after the step text.
  link?: { href: string; label: string }
}

interface ConnectorSetupGuide {
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
  // Not a connector — operator preflight when flipping a keeper's
  // sandbox_profile to docker in the config panel. Steps are
  // manual verification commands because (a) we don't want the dashboard
  // server spawning docker itself for this, and (b) "run this locally and
  // confirm" matches the other setup-guide entries and reuses the same
  // renderer without a new component.
  sandbox_hardened: {
    title: 'Keeper Docker Sandbox 프리플라이트',
    intro:
      "keeper의 sandbox_profile을 'docker'로 바꾸면 다음 keeper_bash 호출부터 container에서 실행됩니다. 먼저 호스트 Docker가 준비됐는지 확인하세요.",
    steps: [
      {
        text: '터미널에서 `docker info` → daemon이 응답하는지 확인. 실패하면 Docker Desktop/engine을 먼저 실행.',
      },
      {
        text: '핀된 이미지 풀: `docker pull ubuntu:24.04@sha256:cdb5fd928fced577cfecf12c8966e830fcdf42ee481fb0b91904eeddc2fe5eff`. (이미지 경로 override는 env var `MASC_KEEPER_SANDBOX_DOCKER_IMAGE`.)',
      },
      {
        text: '(강화 모드) rootless 여부 확인: `docker info --format {{json .SecurityOptions}}` 결과에 `rootless`가 포함되어야 `MASC_KEEPER_SANDBOX_REQUIRE_ROOTLESS=true` 환경에서 keeper_bash가 통과합니다. 기본값은 `false`라 생략 가능.',
      },
      {
        text: '(옵션) userns 확인: 같은 명령 출력에서 `userns` 키 유무를 확인. `MASC_KEEPER_SANDBOX_REQUIRE_USERNS=true`일 때만 필수.',
      },
      {
        text: "메모리/프로세스 한도 기본값 확인: `MASC_KEEPER_SANDBOX_MEMORY=2g`, `MASC_KEEPER_SANDBOX_PIDS_LIMIT=128`, `MASC_KEEPER_SANDBOX_TMPFS_SIZE=256m`. 사용 keeper가 더 필요하면 서버 기동 env에서 조정.",
      },
      {
        text: "sandbox_profile을 'docker'로 저장한 뒤 해당 keeper의 다음 keeper_bash 호출 로그를 확인. 실패하면 sandbox_last_error 필드가 이 화면 위쪽에 노출됩니다.",
      },
    ],
    references: [
      { href: 'https://docs.docker.com/engine/security/rootless/', label: 'Docker rootless mode' },
      { href: 'https://docs.docker.com/engine/security/userns-remap/', label: 'Docker userns remap' },
    ],
  },
}
