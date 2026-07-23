import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { navigate, route } from '../../router'
import { requestConfirm } from './confirm-dialog'
import { runGarbageCollection } from '../flow-control/flow-control-state'
import { missionSnapshot, missionAgentBriefs, missionKeeperBriefs } from '../../mission-signals'
import { formatCommandTargetSection, formatCommandTargetSummary } from '../../runtime-counts'

interface CommandPaletteAction {
  id: string
  title: string
  handler: () => void | Promise<void>
  section?: string
  keywords?: string
}

interface NinjaKeysElement extends HTMLElement {
  data: CommandPaletteAction[]
  open: (options?: { parent?: string }) => void
}

interface CommandPaletteProps {
  openOnMount?: boolean
}

const LIT_DEV_MODE_WARNING =
  'Lit is in dev mode. Not recommended for production! See https://lit.dev/msg/dev-mode for more information.'

function suppressKnownLitDevWarning() {
  const globalScope = window as Window & { litIssuedWarnings?: Set<string> }
  const issuedWarnings = globalScope.litIssuedWarnings ?? new Set<string>()
  issuedWarnings.add(LIT_DEV_MODE_WARNING)
  globalScope.litIssuedWarnings = issuedWarnings
}

export function CommandPalette({ openOnMount = false }: CommandPaletteProps = {}) {
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
        title: '작업 화면으로 이동 (Work)',
        section: 'Navigation',
        keywords: 'tasks work',
        handler: () => navigate('workspace')
      },
      {
        id: 'nav-command',
        title: '운영 화면으로 이동 (Operations)',
        section: 'Navigation',
        keywords: 'control admin ops gate hitl intervene',
        handler: () => navigate('command')
      },
      {
        id: 'nav-gate',
        title: 'Gate·HITL로 이동',
        section: 'Navigation',
        keywords: 'approval review hitl judge',
        handler: () => navigate('command', { section: 'operations', view: 'gate' })
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
        id: 'ide-toggle-rails',
        title: route.value.params.rails === 'hidden' ? 'IDE rails 보이기' : 'IDE rails 숨기기',
        section: 'IDE',
        keywords: 'code ide rails layout conversation activity toggle',
        handler: () => {
          const next: Record<string, string> = { ...route.value.params, section: 'ide-shell' }
          if (next.rails === 'hidden') {
            delete next.rails
          } else {
            next.rails = 'hidden'
          }
          navigate('code', next)
        }
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
      }
    ]

    // Add Agents dynamically
    const agents = missionAgentBriefs.value || []
    const keepers = missionKeeperBriefs.value || []
    const sessions = missionSnapshot.value?.sessions ?? []
    const commandTargetSummary = formatCommandTargetSummary({
      agents: agents.length,
      keepers: keepers.length,
      sessions: sessions.length,
    })
    const agentActions: CommandPaletteAction[] = agents.map(agent => ({
      id: `nav-agent-${agent.agent_name}`,
      title: `에이전트 상세: ${agent.display_name || agent.agent_name}`,
      section: formatCommandTargetSection('agent', agents.length),
      keywords: `worker detail status command target mission ${commandTargetSummary} ${agent.status || ''}`,
      handler: () => navigate('monitoring', { section: 'agents', agent: agent.agent_name })
    }))

    // Add Keepers dynamically
    const keeperActions: CommandPaletteAction[] = keepers.map(keeper => ({
      id: `nav-keeper-${keeper.name}`,
      title: `키퍼 상세: ${keeper.name}`,
      section: formatCommandTargetSection('keeper', keepers.length),
      keywords: `bot detail status command target mission ${commandTargetSummary} ${keeper.status || ''}`,
      handler: () => navigate('monitoring', { section: 'agents', keeper: keeper.name })
    }))

    // Add Sessions dynamically
    const sessionActions: CommandPaletteAction[] = sessions.map(s => ({
      id: `nav-session-${s.session_id}`,
      title: `세션 확인: ${s.goal || s.session_id}`,
      section: formatCommandTargetSection('session', sessions.length),
      keywords: `task run command target mission ${commandTargetSummary} ${s.status || ''}`,
      handler: () => navigate('monitoring', { section: 'fleet-health', view: 'event-log', session_id: s.session_id })
    }))

    ref.current.data = [...baseActions, ...agentActions, ...keeperActions, ...sessionActions]

  }, [ready, route.value, missionSnapshot.value, missionAgentBriefs.value, missionKeeperBriefs.value])

  useEffect(() => {
    if (!ready || !openOnMount) return
    const handle = window.setTimeout(() => {
      ref.current?.open()
    }, 0)
    return () => window.clearTimeout(handle)
  }, [ready, openOnMount])

  if (!ready) return null

  return html`
    <ninja-keys
      ref=${ref}
      placeholder="명령어 또는 command target 검색... (⌘/Ctrl+K)"
      hideBreadcrumbs
      style="
        --ninja-modal-background: var(--color-bg-surface);
        --ninja-modal-shadow: 0 24px 64px rgba(0,0,0,0.6);
        --ninja-text-color: var(--color-fg-primary);
        --ninja-secondary-background-color: var(--white-5);
        --ninja-secondary-text-color: var(--color-fg-muted);
        --ninja-selected-background: var(--white-10);
        --ninja-icon-color: var(--color-fg-muted);
        --ninja-key-background: var(--white-10);
        --ninja-key-text-color: var(--color-fg-secondary);
        --ninja-border-bottom: 1px solid var(--color-border-default);
      "
    ></ninja-keys>
  `
}
