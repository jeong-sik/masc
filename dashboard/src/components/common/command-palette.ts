// MASC v2 — command palette (⌘K), rebuilt on the design's cmdk-* markup
// (prototype palette.jsx). The cmdk-* classes it emits are styled by the
// loaded v2 stylesheets; the vendored ds-dashboard-kit sheet that once
// carried them was never imported and has been removed.
//
// With a query the palette merges the deep index — goals, tasks, Gate
// approvals, fusion runs, board posts, connectors — over the live signals
// those surfaces already hydrate. Entries navigate to the surface; no entry
// fabricates a status the server did not send.
//
// State lives in signals (useSignal/useComputed) rather than useMemo with
// signal reads in the deps array: render-phase .value reads inside useMemo
// fight the @preact/signals render integration (updates remount the tree),
// while computed signals re-derive and re-render through the integration's
// own subscription path.

import { html } from 'htm/preact'
import { Fragment } from 'preact'
import { useEffect, useRef } from 'preact/hooks'
import { useComputed, useSignal } from '@preact/signals'
import { navigate, navigateToPost, route } from '../../router'
import { requestConfirm } from './confirm-dialog'
import { runGarbageCollection } from '../flow-control/flow-control-state'
import { missionAgentBriefs, missionKeeperBriefs } from '../../mission-signals'
import { formatCommandTargetSection } from '../../runtime-counts'
import { shellAuthSummary, boardPosts, fusionRuns } from '../../store'
import { gateData } from '../gate-signals'
import { goalTreeData } from '../../goal-tree-state'
import { dashboardAuthAccess } from '../../lib/dashboard-auth-access'
import { surfaceLabel } from '../v2/nav-rail-v2'
import { V2_PRIMARY_SURFACE_IDS } from '../../config/navigation'
import { toggleCopilotDock } from '../copilot-dock'
import { globalShortcutManager } from '../../lib/global-shortcut-manager'
import { CONNECTOR_DISPLAY_NAMES, KNOWN_CONNECTOR_IDS } from '../connector-status'
import type { GoalTreeNode, GoalTreeTask, TabId } from '../../types'

interface PaletteEntry {
  id: string
  group: string
  kind:
    | 'action'
    | 'surface'
    | 'keeper'
    | 'agent'
    | 'goal'
    | 'task'
    | 'approval'
    | 'fusion'
    | 'post'
    | 'connector'
  title: string
  sub: string
  glyph: string
  run: () => void | Promise<void>
}

interface CommandPaletteProps {
  openOnMount?: boolean
}

function flattenGoalTree(nodes: readonly GoalTreeNode[]): Array<{ node: GoalTreeNode; tasks: readonly GoalTreeTask[] }> {
  const out: Array<{ node: GoalTreeNode; tasks: readonly GoalTreeTask[] }> = []
  const stack = [...nodes]
  while (stack.length > 0) {
    const node = stack.pop() as GoalTreeNode
    out.push({ node, tasks: node.tasks ?? [] })
    for (const child of node.children ?? []) stack.push(child)
  }
  return out
}

export function CommandPalette({ openOnMount = false }: CommandPaletteProps = {}) {
  const open = useSignal(openOnMount)
  const q = useSignal('')
  const sel = useSignal(0)
  const inputRef = useRef<HTMLInputElement | null>(null)
  const listRef = useRef<HTMLDivElement | null>(null)

  // app.ts bootstraps the first ⌘K while this component is unmounted; once
  // mounted it owns the chord itself so ⌘K re-toggles for the rest of the
  // session (the dock registers its ⌘J the same way).
  useEffect(() => {
    const dispose = globalShortcutManager.register({
      id: 'command-palette.toggle',
      chord: { key: 'k', modifiers: ['Mod'] },
      description: 'Toggle Command Palette',
      scope: 'global',
      preserveInInputs: true,
      action: () => {
        open.value = !open.value
        if (open.value) {
          q.value = ''
          sel.value = 0
        }
      },
    })
    return dispose
  }, [])

  // Focus only. Signal writes live in the event handlers above/below, not in
  // effects: writing a component-bound signal inside useEffect triggers the
  // @preact/signals cycle guard and permanently stops this component's
  // signal-driven re-renders (found via test bisection — arrows stopped
  // moving the selection with no error surfaced).
  useEffect(() => {
    if (!open.value) return
    const handle = window.setTimeout(() => inputRef.current?.focus(), 20)
    return () => window.clearTimeout(handle)
  }, [open.value])

  const base = useComputed<PaletteEntry[]>(() => {
    const cmds: PaletteEntry[] = []
    const approvals = gateData.value?.approval_queue ?? null
    const pending = approvals?.length ?? 0

    cmds.push({
      id: 'action-chat-dock',
      group: '명령',
      kind: 'action',
      title: 'Chat 열기',
      sub: '⌘J · 보조 패널',
      glyph: '◈',
      run: () => toggleCopilotDock(),
    })
    cmds.push({
      id: 'action-gate-queue',
      group: '명령',
      kind: 'action',
      title: 'Gate 큐 열기',
      sub: pending > 0 ? `${pending}건 대기` : '비어 있음',
      glyph: '✓',
      run: () => navigate('approvals'),
    })

    const maintenanceAccess = dashboardAuthAccess(shellAuthSummary.value, 'admin')
    if (maintenanceAccess.allowed) {
      cmds.push({
        id: 'action-gc',
        group: '명령',
        kind: 'action',
        title: '유지보수: GC (Garbage Collection) 실행',
        sub: '확인 후 실행',
        glyph: '↻',
        run: async () => {
          const confirmed = await requestConfirm({ title: '유지보수', message: 'GC를 실행합니까?' })
          if (confirmed) void runGarbageCollection()
        },
      })
    }

    cmds.push({
      id: 'ide-toggle-rails',
      group: '명령',
      kind: 'action',
      title: route.value.params.rails === 'hidden' ? 'IDE rails 보이기' : 'IDE rails 숨기기',
      sub: 'code · ide rails layout',
      glyph: '▤',
      run: () => {
        const next: Record<string, string> = { ...route.value.params, section: 'ide-shell' }
        if (next.rails === 'hidden') {
          delete next.rails
        } else {
          next.rails = 'hidden'
        }
        navigate('code', next)
      },
    })

    for (const tab of V2_PRIMARY_SURFACE_IDS) {
      cmds.push({
        id: `nav-${tab}`,
        group: '이동',
        kind: 'surface',
        title: surfaceLabel(tab as TabId),
        sub: `${tab} 표면으로`,
        glyph: '→',
        run: () => navigate(tab),
      })
    }

    const keepers = missionKeeperBriefs.value || []
    const agents = missionAgentBriefs.value || []
    for (const keeper of keepers) {
      cmds.push({
        id: `nav-keeper-${keeper.name}`,
        group: formatCommandTargetSection('keeper', keepers.length),
        kind: 'keeper',
        title: keeper.name,
        sub: keeper.status || '키퍼 상세',
        glyph: '◆',
        run: () => navigate('monitoring', { section: 'agents', keeper: keeper.name }),
      })
    }
    for (const agent of agents) {
      cmds.push({
        id: `nav-agent-${agent.agent_name}`,
        group: formatCommandTargetSection('agent', agents.length),
        kind: 'agent',
        title: agent.display_name || agent.agent_name,
        sub: agent.status || '에이전트 상세',
        glyph: '◇',
        run: () => navigate('monitoring', { section: 'agents', agent: agent.agent_name }),
      })
    }
    return cmds
  })

  // deep index — 쿼리가 있을 때만 base 에 합쳐 보인다 (prototype palette.jsx).
  const deep = useComputed<PaletteEntry[]>(() => {
    const cmds: PaletteEntry[] = []

    for (const { node, tasks } of flattenGoalTree(goalTreeData.value?.tree ?? [])) {
      cmds.push({
        id: `goal-${node.id}`,
        group: '목표',
        kind: 'goal',
        title: node.title,
        sub: `${node.id} · P${node.priority}`,
        glyph: '◐',
        run: () => navigate('workspace', { section: 'planning', view: 'goal-tree' }),
      })
      for (const task of tasks) {
        cmds.push({
          id: `task-${task.id}`,
          group: 'Task',
          kind: 'task',
          title: task.title,
          sub: `${task.id} · ${task.assignee ?? '미배정'}`,
          glyph: '▣',
          run: () => navigate('workspace', { section: 'planning', view: 'goal-tree' }),
        })
      }
    }

    for (const item of gateData.value?.approval_queue ?? []) {
      cmds.push({
        id: `approval-${item.id}`,
        group: 'Gate',
        kind: 'approval',
        title: item.input_preview || `${item.tool_name} 승인`,
        sub: `${item.keeper_name} · ${item.tool_name}`,
        glyph: '✓',
        run: () => navigate('approvals'),
      })
    }

    for (const runRecord of fusionRuns.value ?? []) {
      cmds.push({
        id: `fusion-${runRecord.runId}`,
        group: 'Fusion',
        kind: 'fusion',
        title: runRecord.preset,
        sub: `${runRecord.runId} · ${runRecord.keeper} · ${runRecord.status}`,
        glyph: '◈',
        run: () => navigate('fusion', { run_id: runRecord.runId }),
      })
    }

    for (const post of boardPosts.value ?? []) {
      cmds.push({
        id: `post-${post.id}`,
        group: '보드',
        kind: 'post',
        title: post.title,
        sub: `${post.hearth ?? 'board'} · ${post.author}`,
        glyph: '❗',
        run: () => navigateToPost(post.id),
      })
    }

    for (const id of KNOWN_CONNECTOR_IDS) {
      cmds.push({
        id: `connector-${id}`,
        group: '커넥터',
        kind: 'connector',
        title: CONNECTOR_DISPLAY_NAMES[id] ?? id,
        sub: `${id} 커넥터 표면으로`,
        glyph: '❗',
        run: () => navigate('connectors', { connector: id }),
      })
    }
    return cmds
  })

  const items = useComputed<PaletteEntry[]>(() => {
    const ql = q.value.trim().toLowerCase()
    if (!ql) return base.value
    return base.value.concat(deep.value).filter(entry =>
      entry.title.toLowerCase().includes(ql)
      || entry.sub.toLowerCase().includes(ql)
      || entry.group.toLowerCase().includes(ql))
  })

  useEffect(() => {
    const el = listRef.current?.querySelector('.cmdk-item.sel')
    if (el) el.scrollIntoView({ block: 'nearest' })
  }, [sel.value, items.value])

  if (!open.value) return null

  const fire = (entry: PaletteEntry | undefined) => {
    if (!entry) return
    void entry.run()
    open.value = false
  }

  const onKeyDown = (e: KeyboardEvent) => {
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      sel.value = Math.min(items.value.length - 1, sel.value + 1)
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      sel.value = Math.max(0, sel.value - 1)
    } else if (e.key === 'Enter') {
      e.preventDefault()
      fire(items.value[sel.value])
    } else if (e.key === 'Escape') {
      e.preventDefault()
      open.value = false
    }
  }

  let lastGroup: string | null = null

  return html`
    <div class="cmdk-backdrop" onClick=${() => { open.value = false }}>
      <div
        class="cmdk"
        role="dialog"
        aria-modal="true"
        aria-label="명령 팔레트"
        onClick=${(e: Event) => e.stopPropagation()}
      >
        <div class="cmdk-input-row">
          <span class="cmdk-glyph" aria-hidden="true">⌘K</span>
          <input
            ref=${inputRef}
            class="cmdk-input"
            type="text"
            aria-label="명령 검색"
            placeholder="keeper · task · 승인 · fusion · 보드 … 검색"
            value=${q.value}
            onInput=${(e: Event) => {
              q.value = (e.target as HTMLInputElement).value
              sel.value = 0
            }}
            onKeyDown=${onKeyDown}
          />
          <kbd class="cmdk-esc">esc</kbd>
        </div>
        <div class="cmdk-list" ref=${listRef} role="listbox" aria-label="명령 목록">
          ${items.value.length === 0
            ? html`<div class="cmdk-empty">일치하는 명령이 없습니다</div>`
            : items.value.map((entry, i) => {
                const head = entry.group !== lastGroup ? entry.group : null
                lastGroup = entry.group
                return html`
                  <${Fragment} key=${entry.id}>
                    ${head ? html`<div class="cmdk-group" role="presentation">${head}</div>` : null}
                    <div
                      class=${`cmdk-item ${entry.kind} ${i === sel.value ? 'sel' : ''}`}
                      role="option"
                      aria-selected=${i === sel.value}
                      data-entry-id=${entry.id}
                      onMouseEnter=${() => { sel.value = i }}
                      onClick=${() => fire(entry)}
                    >
                      <span class="cmdk-item-glyph" aria-hidden="true">${entry.glyph}</span>
                      <div class="cmdk-item-body">
                        <div class="cmdk-item-t">${entry.title}</div>
                        <div class="cmdk-item-sub">${entry.sub}</div>
                      </div>
                      <span class="cmdk-chord" aria-hidden="true">${i === sel.value ? '↵' : ''}</span>
                    </div>
                  <//>
                `
              })}
        </div>
        <div class="cmdk-foot">
          <span><kbd>↑</kbd><kbd>↓</kbd> 이동</span>
          <span><kbd>↵</kbd> 실행</span>
          <span><kbd>esc</kbd> 닫기</span>
        </div>
      </div>
    </div>
  `
}
