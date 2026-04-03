import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { navigate } from '../../router'
import { requestConfirm } from './confirm-dialog'
import { runGarbageCollection, cleanupZombies } from '../flow-control/flow-control-state'

interface CommandPaletteAction {
  id: string
  title: string
  handler: () => void | Promise<void>
}

interface NinjaKeysElement extends HTMLElement {
  data: CommandPaletteAction[]
}

export function CommandPalette() {
  const ref = useRef<NinjaKeysElement | null>(null)
  const [ready, setReady] = useState(false)

  useEffect(() => {
    let cancelled = false

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

  useEffect(() => {
    if (!ready || !ref.current) return
    const frameId = window.requestAnimationFrame(() => {
      if (!ref.current) return
      ref.current.data = [
      {
        id: 'nav-overview',
        title: '상황판으로 이동 (Overview)',
        handler: () => navigate('overview')
      },
      {
        id: 'nav-monitoring',
        title: '모니터링으로 이동 (Monitoring)',
        handler: () => navigate('monitoring')
      },
      {
        id: 'nav-workspace',
        title: '작업 화면으로 이동 (Workspace)',
        handler: () => navigate('workspace')
      },
      {
        id: 'nav-command',
        title: '운영 개입으로 이동 (Command Plane)',
        handler: () => navigate('command')
      },
      {
        id: 'nav-lab',
        title: '실험실로 이동 (Lab)',
        handler: () => navigate('lab')
      },
      {
        id: 'nav-logs',
        title: '로그 뷰어로 이동 (Logs)',
        handler: () => navigate('logs')
      },
      {
        id: 'action-gc',
        title: '유지보수: GC (Garbage Collection) 실행',
        handler: async () => {
          const confirmed = await requestConfirm({ title: '유지보수', message: 'GC를 실행합니까?' })
          if (confirmed) void runGarbageCollection()
        }
      },
      {
        id: 'action-zombie',
        title: '유지보수: 좀비 에이전트 정리',
        handler: async () => {
          const confirmed = await requestConfirm({ title: '유지보수', message: '좀비 에이전트를 정리합니까?', tone: 'danger' })
          if (confirmed) void cleanupZombies()
        }
      }
      ]
    })

    return () => {
      window.cancelAnimationFrame(frameId)
    }
  }, [ready])

  if (!ready) return null

  return html`
    <ninja-keys
      ref=${ref}
      placeholder="명령어를 검색하세요... (⌘/Ctrl+K)"
      hideBreadcrumbs
      style="
        --ninja-modal-background: rgba(13, 21, 38, 0.98);
        --ninja-modal-shadow: 0 24px 64px rgba(0,0,0,0.6);
        --ninja-text-color: var(--text-body);
        --ninja-secondary-background-color: var(--white-4);
        --ninja-secondary-text-color: var(--text-muted);
        --ninja-selected-background: var(--white-10);
        --ninja-icon-color: var(--text-muted);
        --ninja-key-background: var(--white-5);
        --ninja-key-text-color: var(--text-strong);
        --ninja-border-bottom: 1px solid var(--card-border);
      "
    ></ninja-keys>
  `
}
