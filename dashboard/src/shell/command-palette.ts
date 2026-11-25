/**
 * Raycast-Style Universal Command Palette (`⌘K` / `Ctrl+K`).
 *
 * Lazily loaded on first `⌘K` open so `@leeoniya/ufuzzy` and command execution
 * schemas stay out of the critical first-load JS chunk.
 *
 * Indexes:
 * - All Proposal A+ routes (`ROUTE_MANIFEST`)
 * - Explicit `Account:` commands (Operator identity & workspace access)
 * - Explicit `Provider:` commands (LLM providers, quotas, failover lanes — zero conflation!)
 * - Explicit `Setting:` keys (Schema-driven runtime config categories)
 * - Theme (`dark | light`) & Static High-Contrast (`data-contrast="high"`) toggles
 * - Direct Shell & Operator actions
 */

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  authSession,
  bootstrapAuthSession,
  type AuthSession,
} from '../core/auth'
import { startObserverStream } from '../core/observer'
import { apiGet, apiMutate } from '../core/transport'
import { parseRuntimeDefaultsResponse } from '../api/schemas/runtime-defaults'
import {
  createCommandSearcher,
  type CommandSearchItem,
} from '../components/primitives/command-search'
import {
  ROUTE_MANIFEST,
  isAdminLockedForSession,
  navigate,
} from '../routes/router'
import { ShellIcon } from './icons'
import {
  activeContrast,
  activeTheme,
  closeCommandPalette,
  commandPaletteOpen,
  pushShellToast,
  recordIncident,
  refreshPendingHitl,
  toggleHighContrast,
  toggleIncidentsOverlay,
  toggleQueueContextOverlay,
  toggleRail,
  toggleThemeMode,
} from './shell-state'

export type CommandGroup = 'Route' | 'Account' | 'Provider' | 'Setting' | 'Theme' | 'Action'

export interface PaletteCommand extends CommandSearchItem {
  readonly group: CommandGroup
  readonly subtitle: string
  readonly shortcut?: string
  readonly locked?: boolean
  readonly run: () => unknown
}

export function buildPaletteCommands(session: AuthSession): readonly PaletteCommand[] {
  const cmds: PaletteCommand[] = []

  // 1. All A+ routes (excluding Account routes duplicated under explicit Account: namespace)
  for (const entry of ROUTE_MANIFEST) {
    if (entry.workspace === 'account') continue
    const locked = isAdminLockedForSession(entry.access, session)
    cmds.push({
      id: `route:${entry.id}`,
      label: entry.label,
      category: entry.workspace,
      keywords: [...entry.keywords, entry.path],
      group: 'Route',
      subtitle: locked ? `${entry.path} · Admin only` : entry.path,
      locked,
      run: () => navigate(entry.path),
    })
  }

  // 2. Account: namespace (Operator Identity & Workspace Access — NEVER LLM Providers)
  const adminLocked = isAdminLockedForSession('admin', session)
  cmds.push(
    {
      id: 'account:profile',
      label: 'Account: Profile, Sessions & Workspaces',
      category: 'Account',
      keywords: ['account', 'whoami', 'login', 'workspace', 'bearer', '계정', '프로필'],
      group: 'Account',
      subtitle: '/account/profile',
      run: () => navigate('/account/profile'),
    },
    {
      id: 'account:pats',
      label: 'Account: Personal Access Tokens (PATs)',
      category: 'Account',
      keywords: ['account', 'pat', 'token', 'mcp', '토큰'],
      group: 'Account',
      subtitle: '/account/pats',
      run: () => navigate('/account/pats'),
    },
    {
      id: 'account:members',
      label: 'Account: Members & Admin Lifecycle',
      category: 'Account',
      keywords: ['account', 'member', 'admin', 'disable', 'revoke', '구성원'],
      group: 'Account',
      subtitle: adminLocked ? '/account/members · Admin only' : '/account/members',
      locked: adminLocked,
      run: () => navigate('/account/members'),
    },
    {
      id: 'account:invites',
      label: 'Account: Invitations',
      category: 'Account',
      keywords: ['account', 'invite', '초대'],
      group: 'Account',
      subtitle: adminLocked ? '/account/invites · Admin only' : '/account/invites',
      locked: adminLocked,
      run: () => navigate('/account/invites'),
    },
    {
      id: 'account:allowlist',
      label: 'Account: Sign-In Allowlist',
      category: 'Account',
      keywords: ['account', 'allowlist', 'google', 'github', '허용'],
      group: 'Account',
      subtitle: adminLocked ? '/account/allowlist · Admin only' : '/account/allowlist',
      locked: adminLocked,
      run: () => navigate('/account/allowlist'),
    },
    {
      id: 'account:reload-session',
      label: 'Account: Refresh Auth Session',
      category: 'Account',
      keywords: ['account', 'session', 'refresh', 'csrf', '재조회'],
      group: 'Account',
      subtitle: 'Re-read /health & session state',
      run: async () => {
        await bootstrapAuthSession()
        void startObserverStream()
        pushShellToast('세션 상태를 다시 확인했습니다.', 'info')
      },
    },
  )

  if (session.kind === 'multi_account_signed_in') {
    cmds.push({
      id: 'account:sign-out',
      label: 'Account: Sign Out',
      category: 'Account',
      keywords: ['account', 'logout', 'signout', '로그아웃'],
      group: 'Account',
      subtitle: 'POST /auth/logout',
      run: async () => {
        const res = await apiMutate('POST', '/auth/logout')
        if (!res.ok && res.error.kind !== 'unauthorized') {
          pushShellToast(`로그아웃 실패: ${res.error.message}`, 'error')
          return
        }
        await bootstrapAuthSession()
        navigate('/account')
        pushShellToast('로그아웃되었습니다.', 'info')
      },
    })
  }

  // 3. Provider: namespace (LLM Subscriptions, API Keys, Quotas & Failover)
  cmds.push(
    {
      id: 'provider:quotas',
      label: 'Provider: Quotas & Rate Limits',
      category: 'Provider',
      keywords: ['provider', 'quota', 'codex', 'claude', 'antigravity', 'glm', 'kimi', '429', '할당량'],
      group: 'Provider',
      subtitle: '/runtime/quotas — Manage LLM Provider keys & subscriptions',
      run: () => navigate('/runtime/quotas'),
    },
    {
      id: 'provider:efficiency',
      label: 'Provider: Prompt Cache & Spend Efficiency',
      category: 'Provider',
      keywords: ['provider', 'cache', 'spend', 'cost', 'token', '캐시'],
      group: 'Provider',
      subtitle: '/runtime/efficiency',
      run: () => navigate('/runtime/efficiency'),
    },
    {
      id: 'provider:lanes',
      label: 'Provider: Failover Lanes & Exact Output',
      category: 'Provider',
      keywords: ['provider', 'lane', 'failover', 'exact', 'fusion', 'model', '레인'],
      group: 'Provider',
      subtitle: '/runtime/lanes',
      run: () => navigate('/runtime/lanes'),
    },
  )

  // 4. Setting: namespace (Schema-Driven Config Keys)
  cmds.push(
    {
      id: 'setting:runtime',
      label: 'Setting: runtime.toml Schema & Diff',
      category: 'Setting',
      keywords: ['setting', 'config', 'runtime', 'toml', '설정'],
      group: 'Setting',
      subtitle: adminLocked ? '/settings · Admin only' : '/settings',
      locked: adminLocked,
      run: () => navigate('/settings'),
    },
    {
      id: 'setting:candle-halflife',
      label: 'Setting: candle.half_life_hours & Pricing Mode',
      category: 'Setting',
      keywords: ['setting', 'candle', 'half_life', 'pricing', '캔들'],
      group: 'Setting',
      subtitle: adminLocked ? '/settings?section=candle · Admin only' : '/settings?section=candle',
      locked: adminLocked,
      run: () => navigate('/settings?section=candle'),
    },
    {
      id: 'setting:sandbox-policy',
      label: 'Setting: sandbox.microvm & Execution Policy',
      category: 'Setting',
      keywords: ['setting', 'sandbox', 'microvm', 'docker', 'ssh', '보안'],
      group: 'Setting',
      subtitle: adminLocked ? '/settings?section=sandbox · Admin only' : '/settings?section=sandbox',
      locked: adminLocked,
      run: () => navigate('/settings?section=sandbox'),
    },
    {
      id: 'setting:keeper-defaults',
      label: 'Setting: keeper.default_lane & Compaction',
      category: 'Setting',
      keywords: ['setting', 'keeper', 'lane', 'compaction', '키퍼'],
      group: 'Setting',
      subtitle: adminLocked ? '/settings?section=keeper · Admin only' : '/settings?section=keeper',
      locked: adminLocked,
      run: () => navigate('/settings?section=keeper'),
    },
  )

  // 5. Theme & High-Contrast Toggles
  const currentTheme = activeTheme.peek()
  const currentContrast = activeContrast.peek()
  cmds.push(
    {
      id: 'theme:toggle',
      label: currentTheme === 'dark'
        ? 'Theme: Switch to Warm Archival Paper (Light)'
        : 'Theme: Switch to Tempered Slate (Dark)',
      category: 'Theme',
      keywords: ['theme', 'dark', 'light', 'paper', 'slate', '테마', '라이트', '다크'],
      group: 'Theme',
      subtitle: `Current: ${currentTheme}`,
      run: () => {
        const next = toggleThemeMode()
        pushShellToast(`테마 변경: ${next === 'light' ? 'Warm Archival Paper (Light)' : 'Tempered Slate (Dark)'}`, 'info')
      },
    },
    {
      id: 'theme:high-contrast',
      label: currentContrast === 'high'
        ? 'Theme: Disable High-Contrast Mode'
        : 'Theme: Enable High-Contrast Mode (APCA Lc ≥ 90)',
      category: 'Theme',
      keywords: ['contrast', 'hc', 'high contrast', 'accessibility', 'a11y', '고대비'],
      group: 'Theme',
      subtitle: `data-contrast="${currentContrast === 'high' ? 'high' : 'normal'}"`,
      run: () => {
        const next = toggleHighContrast()
        pushShellToast(`고대비 모드: ${next === 'high' ? '켜짐 (Lc ≥ 90)' : '기본'}`, 'info')
      },
    },
  )

  // 6. Direct Actions
  cmds.push(
    {
      id: 'action:queue-context',
      label: 'Action: Toggle Queue & Context Quick-Peek',
      category: 'Action',
      keywords: ['queue', 'context', 'ctx', 'peek', '큐', '컨텍스트'],
      group: 'Action',
      subtitle: 'Read-only live queue & context overview',
      shortcut: '⌘T',
      run: () => toggleQueueContextOverlay(),
    },
    {
      id: 'action:incidents',
      label: 'Action: Toggle Historical Incidents (Ch3)',
      category: 'Action',
      keywords: ['incident', 'error', 'alert', 'ch3', '장애', '이력'],
      group: 'Action',
      subtitle: 'Read-only Channel 3 historical incidents',
      shortcut: 'I',
      run: () => toggleIncidentsOverlay(),
    },
    {
      id: 'action:toggle-rail',
      label: 'Action: Toggle Navigation Rail',
      category: 'Action',
      keywords: ['sidebar', 'rail', 'collapse', 'expand', '사이드바'],
      group: 'Action',
      subtitle: '208px expanded ↔ 56px collapsed',
      shortcut: 'B',
      run: () => toggleRail(),
    },
    ...(session.kind === 'single_user_local'
      ? [{
          id: 'action:refresh-hitl',
          label: 'Action: Refresh Pending Approvals & Asks',
          category: 'Action',
          keywords: ['refresh', 'approval', 'ask', 'inbox', '승인', '새로고침'],
          group: 'Action' as const,
          subtitle: 'Fetch /api/v1/keepers/tool-approvals & /asks',
          run: async () => {
            await refreshPendingHitl()
            pushShellToast('승인 및 질문 대기열을 새로고침했습니다.', 'info')
          },
        }]
      : []),
    {
      id: 'action:reconnect-observer',
      label: 'Action: Reconnect Observer SSE Stream',
      category: 'Action',
      keywords: ['sse', 'observer', 'reconnect', 'live', '재연결'],
      group: 'Action',
      subtitle: 'Restart shared observer stream',
      run: () => {
        void startObserverStream()
        pushShellToast('Observer SSE 재연결을 시작했습니다.', 'info')
      },
    },
    {
      id: 'action:operator-snapshot-check',
      label: 'Action: Read Operator Digest Snapshot',
      category: 'Action',
      keywords: ['operator', 'digest', 'probe', 'health', '운영자'],
      group: 'Action',
      subtitle: 'GET /api/v1/operator/digest (read-only)',
      run: async () => {
        const res = await apiGet<Record<string, unknown>>('/api/v1/operator/digest')
        if (!res.ok) {
          recordIncident({
            severity: 'warn',
            source: 'command-palette',
            summary: `Operator digest returned ${res.error.status ?? res.error.kind}`,
            detail: res.error.message,
          })
          pushShellToast(`운영자 다이제스트 조회 실패: ${res.error.message}`, 'warning')
          return
        }
        const status = typeof res.value?.health === 'string'
          ? res.value.health
          : typeof res.value?.status === 'string'
            ? res.value.status
            : 'ok'
        pushShellToast(`Operator digest: ${status}`, 'success')
      },
    },
    {
      id: 'action:runtime-defaults-check',
      label: 'Action: Inspect Resolved Runtime Defaults',
      category: 'Action',
      keywords: ['runtime', 'defaults', 'model', 'routing', '런타임'],
      group: 'Action',
      subtitle: 'GET /api/v1/dashboard/runtime-defaults (read-only)',
      run: async () => {
        const res = await apiGet<unknown>('/api/v1/dashboard/runtime-defaults')
        if (!res.ok) {
          pushShellToast(`런타임 기본값 조회 실패: ${res.error.message}`, 'warning')
          return
        }
        try {
          const parsed = parseRuntimeDefaultsResponse(res.value)
          pushShellToast(
            `Default runtime: ${parsed.default_runtime_id ?? '없음'} (${parsed.runtimes.length} configured)`,
            'success',
          )
        } catch (cause) {
          pushShellToast(`런타임 스키마 확인 필요: ${cause instanceof Error ? cause.message : String(cause)}`, 'warning')
        }
      },
    },
  )

  return cmds
}

function renderHighlightedLabel(label: string, ranges: readonly [number, number][]): VNode {
  if (ranges.length === 0) return html`<span>${label}</span>`
  const parts: (string | VNode)[] = []
  let cursor = 0
  for (const [start, end] of ranges) {
    if (start > cursor) parts.push(label.slice(cursor, start))
    if (end > start) {
      parts.push(html`<mark class="ap-cmdk-mark">${label.slice(start, end)}</mark>`)
      cursor = end
    }
  }
  if (cursor < label.length) parts.push(label.slice(cursor))
  return html`<span>${parts}</span>`
}

export function CommandPalette(): VNode | null {
  const open = commandPaletteOpen.value
  const session = authSession.value
  const [query, setQuery] = useState('')
  const [selectedIdx, setSelectedIdx] = useState(0)
  const inputRef = useRef<HTMLInputElement>(null)
  const listRef = useRef<HTMLDivElement>(null)

  const commands = useMemo(
    () => buildPaletteCommands(session),
    // Recompute when auth kind/role or theme/contrast changes
    [session.kind, session.kind === 'multi_account_signed_in' ? session.role : null, activeTheme.value, activeContrast.value],
  )
  const searcher = useMemo(() => createCommandSearcher(commands), [commands])
  const results = useMemo(() => searcher.search(query, 30), [searcher, query])

  useEffect(() => {
    setSelectedIdx(0)
  }, [query, open])

  useEffect(() => {
    if (!open) return
    setQuery('')
    setSelectedIdx(0)
    queueMicrotask(() => inputRef.current?.focus())
  }, [open])

  useEffect(() => {
    if (!open) return
    const selectedEl = listRef.current?.querySelector('.ap-cmdk-item.is-selected') as HTMLElement | null
    selectedEl?.scrollIntoView?.({ block: 'nearest' })
  }, [selectedIdx, open])

  if (!open) return null

  const execute = (cmd: PaletteCommand | undefined) => {
    if (!cmd) return
    closeCommandPalette()
    void cmd.run()
  }

  const onKeyDown = (event: KeyboardEvent) => {
    if (event.isComposing || event.keyCode === 229) return
    if (event.key === 'Escape') {
      event.preventDefault()
      event.stopPropagation()
      closeCommandPalette()
      return
    }
    if (event.key === 'ArrowDown') {
      event.preventDefault()
      setSelectedIdx((i) => (results.length === 0 ? 0 : (i + 1) % results.length))
      return
    }
    if (event.key === 'ArrowUp') {
      event.preventDefault()
      setSelectedIdx((i) => (results.length === 0 ? 0 : (i - 1 + results.length) % results.length))
      return
    }
    if (event.key === 'Enter') {
      event.preventDefault()
      execute(results[selectedIdx]?.item)
    }
  }

  return html`
    <div
      class="cmdk-backdrop"
      role="presentation"
      data-testid="command-palette-backdrop"
      onClick=${(event: MouseEvent) => {
        if (event.target === event.currentTarget) closeCommandPalette()
      }}
    >
      <div
        class="ap-cmdk-dialog"
        role="dialog"
        aria-modal="true"
        aria-label="명령 팔레트"
        onKeyDown=${onKeyDown}
      >
        <div class="ap-cmdk-input-row">
          <${ShellIcon} name="search" size=${16} className="ap-muted" />
          <input
            ref=${inputRef}
            type="text"
            class="ap-cmdk-input"
            role="combobox"
            aria-expanded="true"
            aria-controls="ap-cmdk-list"
            aria-autocomplete="list"
            placeholder="Search routes, Account:, Provider:, Setting:, theme, or actions…"
            value=${query}
            onInput=${(event: Event) => setQuery((event.currentTarget as HTMLInputElement).value)}
          />
          <kbd class="ap-kbd">ESC</kbd>
        </div>

        <div ref=${listRef} id="ap-cmdk-list" class="ap-cmdk-list" role="listbox" aria-label="명령 결과">
          ${results.length === 0
            ? html`<div class="ap-cmdk-empty">일치하는 명령이 없습니다.</div>`
            : results.map((match, idx) => {
                const { item, labelRanges } = match
                const selected = idx === selectedIdx
                return html`
                  <button
                    key=${item.id}
                    type="button"
                    role="option"
                    aria-selected=${selected ? 'true' : 'false'}
                    class=${`ap-cmdk-item${selected ? ' is-selected' : ''}${item.locked ? ' is-locked' : ''}`}
                    data-command-id=${item.id}
                    onMouseEnter=${() => setSelectedIdx(idx)}
                    onClick=${() => execute(item)}
                  >
                    <div class="ap-cmdk-item-main">
                      <span class="ap-cmdk-group">${item.group}</span>
                      <span class="ap-cmdk-label">
                        ${renderHighlightedLabel(item.label, labelRanges)}
                      </span>
                      ${item.locked && html`<${ShellIcon} name="lock" size=${12} />`}
                    </div>
                    <div class="ap-cmdk-item-meta">
                      <span class="ap-cmdk-sub mono">${item.subtitle}</span>
                      ${item.shortcut && html`<kbd class="ap-kbd">${item.shortcut}</kbd>`}
                    </div>
                  </button>
                `
              })}
        </div>

        <footer class="ap-cmdk-foot">
          <span>↑↓ 이동 · ↵ 실행 · ESC 닫기</span>
          <span class="mono">Account: ≠ Provider:</span>
        </footer>
      </div>
    </div>
  `
}

export default CommandPalette
