import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { navigate } from '../../router'
import { requestConfirm } from './confirm-dialog'
import { runGarbageCollection, cleanupZombies } from '../flow-control/flow-control-state'
import { missionSnapshot, missionAgentBriefs, missionKeeperBriefs } from '../../mission-signals'

interface CommandPaletteAction {
  id: string
  title: string
  handler: () => void | Promise<void>
  section?: string
  keywords?: string
}

interface NinjaKeysElement extends HTMLElement {
  data: CommandPaletteAction[]
}

const LIT_DEV_MODE_WARNING =
  'Lit is in dev mode. Not recommended for production! See https://lit.dev/msg/dev-mode for more information.'

function suppressKnownLitDevWarning() {
  const globalScope = window as Window & { litIssuedWarnings?: Set<string> }
  const issuedWarnings = globalScope.litIssuedWarnings ?? new Set<string>()
  issuedWarnings.add(LIT_DEV_MODE_WARNING)
  globalScope.litIssuedWarnings = issuedWarnings
}

export function CommandPalette() {
  const ref = useRef<NinjaKeysElement | null>(null)
  const [ready, setReady] = useState(false)

  useEffect(() => {
    let cancelled = false

    // ninja-keys brings Lit's dev bundle under Vite serve, which emits a
    // known third-party warning that does not indicate a dashboard defect.
    suppressKnownLitDevWarning()
    void import('ninja-keys')
      .then(() => {
        if (!cancelled) setReady(true)
      })
      .catch((error) => {
        console.error('Failed to load ninja-keys', error)
      })

    return () => {
      cancelled = true
    }
  }, [])

  // Sync data whenever the mission snapshot changes
  useEffect(() => {
    if (!ready || !ref.current) return

    const baseActions: CommandPaletteAction[] = [
      {
        id: 'nav-overview',
        title: '상황판으로 이동 (Overview)',
        section: 'Navigation',
        keywords: 'home main board',
        handler: () => navigate('overview')
      },
      {
        id: 'nav-monitoring',
        title: '모니터링으로 이동 (Monitoring)',
        section: 'Navigation',
        keywords: 'status health metrics',
        handler: () => navigate('monitoring')
      },
      {
        id: 'nav-workspace',
        title: '작업 화면으로 이동 (Workspace)',
        section: 'Navigation',
        keywords: 'tasks work',
        handler: () => navigate('workspace')
      },
      {
        id: 'nav-command',
        title: '운영 화면으로 이동 (Operations)',
        section: 'Navigation',
        keywords: 'control admin ops governance intervene',
        handler: () => navigate('command')
      },
      {
        id: 'nav-governance',
        title: '거버넌스로 이동 (Governance)',
        section: 'Navigation',
        keywords: 'approval review hitl judge',
        handler: () => navigate('command', { section: 'governance' })
      },
      {
        id: 'nav-lab',
        title: '실험실로 이동 (Lab)',
        section: 'Navigation',
        keywords: 'experiment test',
        handler: () => navigate('lab')
      },
      {
        id: 'nav-logs',
        title: '로그 뷰어로 이동 (Logs)',
        section: 'Navigation',
        keywords: 'debug output system',
        handler: () => navigate('logs')
      },
      {
        id: 'action-gc',
        title: '유지보수: GC (Garbage Collection) 실행',
        section: 'System Ops',
        keywords: 'clear clean memory',
        handler: async () => {
          const confirmed = await requestConfirm({ title: '유지보수', message: 'GC를 실행합니까?' })
          if (confirmed) void runGarbageCollection()
        }
      },
      {
        id: 'action-zombie',
        title: '유지보수: 좀비 에이전트 정리',
        section: 'System Ops',
        keywords: 'kill process clear',
        handler: async () => {
          const confirmed = await requestConfirm({ title: '유지보수', message: '좀비 에이전트를 정리합니까?', tone: 'danger' })
          if (confirmed) void cleanupZombies()
        }
      }
    ]

    // Add Agents dynamically
    const agents = missionAgentBriefs.value || []
    const agentActions: CommandPaletteAction[] = agents.map(agent => ({
      id: `nav-agent-${agent.agent_name}`,
      title: `에이전트 상세: ${agent.display_name || agent.agent_name}`,
      section: 'Agents',
      keywords: `worker detail status ${agent.status || ''}`,
      handler: () => navigate('overview', { section: 'worker', operation_id: agent.agent_name })
    }))

    // Add Keepers dynamically
    const keepers = missionKeeperBriefs.value || []
    const keeperActions: CommandPaletteAction[] = keepers.map(keeper => ({
      id: `nav-keeper-${keeper.name}`,
      title: `키퍼 상세: ${keeper.name}`,
      section: 'Keepers',
      keywords: `bot detail status ${keeper.status || ''}`,
      handler: () => navigate('overview', { section: 'keeper', operation_id: keeper.name })
    }))

    // Add Sessions dynamically
    const sessions = missionSnapshot.value?.sessions ?? []
    const sessionActions: CommandPaletteAction[] = sessions.map(s => ({
      id: `nav-session-${s.session_id}`,
      title: `세션 확인: ${s.goal || s.session_id}`,
      section: 'Sessions',
      keywords: `task run ${s.status || ''}`,
      handler: () => navigate('workspace', { section: 'session', session_id: s.session_id })
    }))

    ref.current.data = [...baseActions, ...agentActions, ...keeperActions, ...sessionActions]

  }, [ready, missionSnapshot.value, missionAgentBriefs.value, missionKeeperBriefs.value])

  if (!ready) return null

  return html`
    <ninja-keys
      ref=${ref}
      placeholder="명령어 또는 에이전트/세션 검색... (⌘/Ctrl+K)"
      hideBreadcrumbs
      style="
        --ninja-modal-background: var(--bg-panel);
        --ninja-modal-shadow: 0 24px 64px rgba(0,0,0,0.6);
        --ninja-text-color: var(--text-body);
        --ninja-secondary-background-color: var(--white-5);
        --ninja-secondary-text-color: var(--text-muted);
        --ninja-selected-background: var(--white-10);
        --ninja-icon-color: var(--text-muted);
        --ninja-key-background: var(--white-10);
        --ninja-key-text-color: var(--text-strong);
        --ninja-border-bottom: 1px solid var(--border-base);
      "
    ></ninja-keys>
  `
}
