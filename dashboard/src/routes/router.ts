/**
 * Declarative Proposal A+ Router & RBAC Route Manifest.
 *
 * - 6 L0 Trunks: `pulse`, `work`, `knowledge`, `keepers`, `runtime`, `infra`.
 * - 2 Rail Footer Anchors: `settings` (Admin-only), `account` (Public).
 * - Strict 2-level cap: max 5 L1 sub-tabs per workspace.
 * - Declarative RBAC (`public | member | admin`) aligned with `Auth_gate.decide`
 *   so non-Admin `multi_account` Workers never trigger speculative 403 fetches.
 * - Syncs canonical slash paths via URL hash (`#/work/goals`, `#/keepers/grimja/chat`)
 *   while preserving `?win=24h|7d|30d` in `window.location.search`.
 */

import { signal, type ReadonlySignal } from '@preact/signals'
import type { AuthSession } from '../core/auth'
import type { ViewProvenance } from '../core/observer'
import type { WorkspaceId } from '../workspaces/types'

export type RouteAccess = 'public' | 'member' | 'admin'

export interface L1SubTab {
  readonly id: string
  readonly label: string
  readonly path: string
  readonly access: RouteAccess
  readonly supportsTimeWindow?: boolean
  readonly defaultProvenance?: Exclude<ViewProvenance, 'STREAM_GAP'>
}

export interface WorkspaceNavDef {
  readonly id: WorkspaceId
  readonly label: string
  readonly shortLabel: string
  readonly trunkKey?: '1' | '2' | '3' | '4' | '5' | '6'
  readonly shortcut?: string
  readonly section: 'trunk' | 'footer'
  readonly defaultPath: string
  readonly access: RouteAccess
  readonly supportsTimeWindow?: boolean
  readonly defaultProvenance: Exclude<ViewProvenance, 'STREAM_GAP'>
  readonly subtabs: readonly L1SubTab[]
}

export interface APlusRouteEntry {
  readonly id: string
  readonly workspace: WorkspaceId
  readonly subroute: string
  readonly entityTab?: string
  readonly path: string
  readonly label: string
  readonly keywords: readonly string[]
  readonly access: RouteAccess
  readonly supportsTimeWindow: boolean
  readonly defaultProvenance: Exclude<ViewProvenance, 'STREAM_GAP'>
}

export interface ResolvedRoute {
  readonly path: string
  readonly workspace: WorkspaceId
  readonly subroute: string
  readonly entityId?: string
  readonly entityTab?: string
  readonly query: Readonly<Record<string, string>>
  readonly access: RouteAccess
  readonly supportsTimeWindow: boolean
  readonly defaultProvenance: Exclude<ViewProvenance, 'STREAM_GAP'>
}

export const KEEPER_ENTITY_TABS = [
  'chat',
  'memory',
  'portrait-candle',
  'work-sandbox',
  'config',
] as const

export type KeeperEntityTab = (typeof KEEPER_ENTITY_TABS)[number]

export const KEEPER_ENTITY_TAB_LABELS: Readonly<Record<KeeperEntityTab, string>> = Object.freeze({
  chat: 'Chat',
  memory: 'Memory',
  'portrait-candle': 'Portrait & Candle',
  'work-sandbox': 'Work & Sandbox',
  config: 'Config',
})

export const ACCOUNT_SUBTABS = [
  'profile',
  'pats',
  'members',
  'invites',
  'allowlist',
] as const

export type AccountSubTab = (typeof ACCOUNT_SUBTABS)[number]

/**
 * Locked Proposal A+ Navigation Manifest:
 * 6 L0 Trunks + 2 Rail Footer Anchors, max 5 L1 sub-tabs each.
 */
export const WORKSPACE_NAV: readonly WorkspaceNavDef[] = Object.freeze([
  {
    id: 'pulse',
    label: 'Pulse',
    shortLabel: 'Pulse',
    trunkKey: '1',
    shortcut: '1',
    section: 'trunk',
    defaultPath: '/pulse',
    access: 'member',
    supportsTimeWindow: true,
    defaultProvenance: 'LIVE SSE',
    subtabs: [],
  },
  {
    id: 'work',
    label: 'Work',
    shortLabel: 'Work',
    trunkKey: '2',
    shortcut: '2',
    section: 'trunk',
    defaultPath: '/work/goals',
    access: 'member',
    defaultProvenance: 'SYNCED',
    subtabs: [
      { id: 'goals', label: 'Goals', path: '/work/goals', access: 'member', defaultProvenance: 'SYNCED' },
      { id: 'tasks', label: 'Tasks', path: '/work/tasks', access: 'member', defaultProvenance: 'SYNCED' },
      { id: 'inbox', label: 'Inbox', path: '/work/inbox', access: 'member', defaultProvenance: 'LIVE SSE' },
      { id: 'candle', label: 'Candle', path: '/work/candle', access: 'member', supportsTimeWindow: true, defaultProvenance: 'SYNCED' },
    ],
  },
  {
    id: 'knowledge',
    label: 'Knowledge',
    shortLabel: 'Know',
    trunkKey: '3',
    shortcut: '3',
    section: 'trunk',
    defaultPath: '/knowledge/board',
    access: 'member',
    defaultProvenance: 'SYNCED',
    subtabs: [
      { id: 'board', label: 'Board', path: '/knowledge/board', access: 'member', defaultProvenance: 'SYNCED' },
      { id: 'wiki', label: 'Wiki', path: '/knowledge/wiki', access: 'member', defaultProvenance: 'SYNCED' },
      { id: 'artifacts', label: 'Artifacts', path: '/knowledge/artifacts', access: 'member', defaultProvenance: 'SNAPSHOT' },
      { id: 'memory', label: 'Memory', path: '/knowledge/memory', access: 'member', supportsTimeWindow: true, defaultProvenance: 'SYNCED' },
    ],
  },
  {
    id: 'keepers',
    label: 'Keepers',
    shortLabel: 'Keep',
    trunkKey: '4',
    shortcut: '4',
    section: 'trunk',
    defaultPath: '/keepers',
    access: 'member',
    defaultProvenance: 'LIVE SSE',
    subtabs: [],
  },
  {
    id: 'runtime',
    label: 'Runtime',
    shortLabel: 'Run',
    trunkKey: '5',
    shortcut: '5',
    section: 'trunk',
    defaultPath: '/runtime/quotas',
    access: 'member',
    supportsTimeWindow: true,
    defaultProvenance: 'SYNCED',
    subtabs: [
      { id: 'quotas', label: 'Quotas', path: '/runtime/quotas', access: 'member', supportsTimeWindow: true, defaultProvenance: 'SYNCED' },
      { id: 'efficiency', label: 'Efficiency', path: '/runtime/efficiency', access: 'member', supportsTimeWindow: true, defaultProvenance: 'LIVE SSE' },
      { id: 'lanes', label: 'Lanes', path: '/runtime/lanes', access: 'member', supportsTimeWindow: true, defaultProvenance: 'SYNCED' },
      { id: 'tools', label: 'Tools', path: '/runtime/tools', access: 'member', supportsTimeWindow: true, defaultProvenance: 'LIVE SSE' },
      { id: 'addons', label: 'Add-ons', path: '/runtime/addons', access: 'member', supportsTimeWindow: true, defaultProvenance: 'SYNCED' },
    ],
  },
  {
    id: 'infra',
    label: 'Infra',
    shortLabel: 'Infra',
    trunkKey: '6',
    shortcut: '6',
    section: 'trunk',
    defaultPath: '/infra/sandboxes',
    access: 'admin',
    defaultProvenance: 'SYNCED',
    subtabs: [
      { id: 'sandboxes', label: 'Sandboxes', path: '/infra/sandboxes', access: 'admin', defaultProvenance: 'SYNCED' },
      { id: 'repos', label: 'Repos', path: '/infra/repos', access: 'admin', defaultProvenance: 'SNAPSHOT' },
      { id: 'logs', label: 'Logs', path: '/infra/logs', access: 'admin', defaultProvenance: 'LIVE SSE' },
    ],
  },
  {
    id: 'settings',
    label: 'Settings',
    shortLabel: 'Set',
    shortcut: ',',
    section: 'footer',
    defaultPath: '/settings',
    access: 'admin',
    defaultProvenance: 'SYNCED',
    subtabs: [],
  },
  {
    id: 'account',
    label: 'Account',
    shortLabel: 'Acct',
    section: 'footer',
    defaultPath: '/account',
    access: 'public',
    defaultProvenance: 'SYNCED',
    subtabs: [
      { id: 'profile', label: 'Profile', path: '/account/profile', access: 'public', defaultProvenance: 'SYNCED' },
      { id: 'pats', label: 'Tokens', path: '/account/pats', access: 'member', defaultProvenance: 'SYNCED' },
      { id: 'members', label: 'Members', path: '/account/members', access: 'admin', defaultProvenance: 'SYNCED' },
      { id: 'invites', label: 'Invites', path: '/account/invites', access: 'admin', defaultProvenance: 'SYNCED' },
      { id: 'allowlist', label: 'Allowlist', path: '/account/allowlist', access: 'admin', defaultProvenance: 'SYNCED' },
    ],
  },
])

export const TRUNK_NAV: readonly WorkspaceNavDef[] = Object.freeze(
  WORKSPACE_NAV.filter((entry) => entry.section === 'trunk'),
)

export const FOOTER_NAV: readonly WorkspaceNavDef[] = Object.freeze(
  WORKSPACE_NAV.filter((entry) => entry.section === 'footer'),
)

export const WORKSPACE_NAV_BY_ID: Readonly<Record<WorkspaceId, WorkspaceNavDef>> = Object.freeze(
  Object.fromEntries(WORKSPACE_NAV.map((entry) => [entry.id, entry])) as Record<WorkspaceId, WorkspaceNavDef>,
)

/**
 * All 22+ canonical Proposal A+ routes indexed by `⌘K` Command Palette and RBAC guard.
 */
export const ROUTE_MANIFEST: readonly APlusRouteEntry[] = Object.freeze([
  { id: 'pulse', workspace: 'pulse', subroute: 'overview', path: '/pulse', label: '1 Pulse — Fleet Overview', keywords: ['overview', 'home', 'kpi', 'heartbeat', '펄스', '개요'], access: 'member', supportsTimeWindow: true, defaultProvenance: 'LIVE SSE' },
  { id: 'work-goals', workspace: 'work', subroute: 'goals', path: '/work/goals', label: '2 Work → Goals', keywords: ['goal', 'criterion', 'verification', '목표'], access: 'member', supportsTimeWindow: false, defaultProvenance: 'SYNCED' },
  { id: 'work-tasks', workspace: 'work', subroute: 'tasks', path: '/work/tasks', label: '2 Work → Tasks & Schedules', keywords: ['task', 'schedule', 'backlog', 'cron', '작업', '일정'], access: 'member', supportsTimeWindow: false, defaultProvenance: 'SYNCED' },
  { id: 'work-inbox', workspace: 'work', subroute: 'inbox', path: '/work/inbox', label: '2 Work → Unified Inbox (HITL)', keywords: ['inbox', 'approval', 'ask', 'gate', '승인', '질문', '인박스'], access: 'member', supportsTimeWindow: false, defaultProvenance: 'LIVE SSE' },
  { id: 'work-candle', workspace: 'work', subroute: 'candle', path: '/work/candle', label: '2 Work → Candle & Scorecard', keywords: ['candle', 'ledger', 'reward', 'scorecard', '캔들'], access: 'member', supportsTimeWindow: true, defaultProvenance: 'SYNCED' },
  { id: 'knowledge-board', workspace: 'knowledge', subroute: 'board', path: '/knowledge/board', label: '3 Knowledge → Board', keywords: ['board', 'hearth', 'post', 'comment', '게시판'], access: 'member', supportsTimeWindow: false, defaultProvenance: 'SYNCED' },
  { id: 'knowledge-wiki', workspace: 'knowledge', subroute: 'wiki', path: '/knowledge/wiki', label: '3 Knowledge → Librarian Wiki', keywords: ['wiki', 'lint', 'librarian', '위키'], access: 'member', supportsTimeWindow: false, defaultProvenance: 'SYNCED' },
  { id: 'knowledge-artifacts', workspace: 'knowledge', subroute: 'artifacts', path: '/knowledge/artifacts', label: '3 Knowledge → Artifacts', keywords: ['artifact', 'html', 'markdown', '아티팩트'], access: 'member', supportsTimeWindow: false, defaultProvenance: 'SNAPSHOT' },
  { id: 'knowledge-memory', workspace: 'knowledge', subroute: 'memory', path: '/knowledge/memory', label: '3 Knowledge → World Memory & Diff', keywords: ['memory', 'world', 'conflict', 'diff', '기억', '메모리'], access: 'member', supportsTimeWindow: true, defaultProvenance: 'SYNCED' },
  { id: 'keepers-fleet', workspace: 'keepers', subroute: 'fleet', path: '/keepers', label: '4 Keepers → Fleet Wall', keywords: ['keeper', 'agent', 'fleet', 'chat', '키퍼'], access: 'member', supportsTimeWindow: false, defaultProvenance: 'LIVE SSE' },
  { id: 'runtime-quotas', workspace: 'runtime', subroute: 'quotas', path: '/runtime/quotas', label: '5 Runtime → Provider Quotas & Rate Limits', keywords: ['provider', 'quota', 'rate limit', '429', 'api key', '프로바이더', '할당량'], access: 'member', supportsTimeWindow: true, defaultProvenance: 'SYNCED' },
  { id: 'runtime-efficiency', workspace: 'runtime', subroute: 'efficiency', path: '/runtime/efficiency', label: '5 Runtime → Efficiency & Prompt Cache', keywords: ['cache', 'cost', 'spend', 'velocity', '캐시', '효율'], access: 'member', supportsTimeWindow: true, defaultProvenance: 'LIVE SSE' },
  { id: 'runtime-lanes', workspace: 'runtime', subroute: 'lanes', path: '/runtime/lanes', label: '5 Runtime → Lanes, Exact Output & Fusion', keywords: ['lane', 'failover', 'exact', 'fusion', 'model', '레인'], access: 'member', supportsTimeWindow: true, defaultProvenance: 'SYNCED' },
  { id: 'runtime-tools', workspace: 'runtime', subroute: 'tools', path: '/runtime/tools', label: '5 Runtime → Tools, Skills & Connectors', keywords: ['tool', 'skill', 'connector', 'discord', 'slack', '도구'], access: 'member', supportsTimeWindow: true, defaultProvenance: 'LIVE SSE' },
  { id: 'runtime-addons', workspace: 'runtime', subroute: 'addons', path: '/runtime/addons', label: '5 Runtime → Lane Add-ons & Browser Lane', keywords: ['addon', 'browser', 'plugin', '애드온'], access: 'member', supportsTimeWindow: true, defaultProvenance: 'SYNCED' },
  { id: 'infra-sandboxes', workspace: 'infra', subroute: 'sandboxes', path: '/infra/sandboxes', label: '6 Infra → Sandboxes (MicroVM / SSH / Docker)', keywords: ['sandbox', 'microvm', 'ssh', 'docker', '샌드박스'], access: 'admin', supportsTimeWindow: false, defaultProvenance: 'SYNCED' },
  { id: 'infra-repos', workspace: 'infra', subroute: 'repos', path: '/infra/repos', label: '6 Infra → Repositories & 24h Diffs', keywords: ['repo', 'git', 'diff', '저장소'], access: 'admin', supportsTimeWindow: false, defaultProvenance: 'SNAPSHOT' },
  { id: 'infra-logs', workspace: 'infra', subroute: 'logs', path: '/infra/logs', label: '6 Infra → Live SSE Logs', keywords: ['log', 'logs', 'stream', '로그'], access: 'admin', supportsTimeWindow: false, defaultProvenance: 'LIVE SSE' },
  { id: 'settings', workspace: 'settings', subroute: 'runtime', path: '/settings', label: 'Settings — Schema Config & TOML Patch', keywords: ['setting', 'config', 'toml', 'schema', '설정'], access: 'admin', supportsTimeWindow: false, defaultProvenance: 'SYNCED' },
  { id: 'account-profile', workspace: 'account', subroute: 'profile', path: '/account/profile', label: 'Account: Profile, Sessions & Workspaces', keywords: ['account', 'profile', 'login', 'logout', 'workspace', 'bearer', '계정'], access: 'public', supportsTimeWindow: false, defaultProvenance: 'SYNCED' },
  { id: 'account-pats', workspace: 'account', subroute: 'pats', path: '/account/pats', label: 'Account: Personal Access Tokens (PATs)', keywords: ['account', 'pat', 'token', 'mcp', '토큰'], access: 'member', supportsTimeWindow: false, defaultProvenance: 'SYNCED' },
  { id: 'account-members', workspace: 'account', subroute: 'members', path: '/account/members', label: 'Account: Members & Admin Lifecycle', keywords: ['account', 'member', 'admin', 'disable', 'revoke', '구성원'], access: 'admin', supportsTimeWindow: false, defaultProvenance: 'SYNCED' },
  { id: 'account-invites', workspace: 'account', subroute: 'invites', path: '/account/invites', label: 'Account: Invitations', keywords: ['account', 'invite', '초대'], access: 'admin', supportsTimeWindow: false, defaultProvenance: 'SYNCED' },
  { id: 'account-allowlist', workspace: 'account', subroute: 'allowlist', path: '/account/allowlist', label: 'Account: Sign-In Allowlist', keywords: ['account', 'allowlist', 'google', 'github', '허용 목록'], access: 'admin', supportsTimeWindow: false, defaultProvenance: 'SYNCED' },
])

/**
 * Legacy hash aliases cleanly mapped onto Proposal A+ canonical paths.
 */
const LEGACY_PATH_ALIASES: Readonly<Record<string, string>> = Object.freeze({
  '': '/pulse',
  '/': '/pulse',
  '/overview': '/pulse',
  '/command': '/pulse',
  '/monitoring': '/runtime/efficiency',
  '/monitor': '/runtime/efficiency',
  '/connectors': '/runtime/tools',
  '/tools': '/runtime/tools',
  '/approvals': '/work/inbox',
  '/inbox': '/work/inbox',
  '/gate': '/work/inbox',
  '/goals': '/work/goals',
  '/tasks': '/work/tasks',
  '/schedule': '/work/tasks',
  '/candle': '/work/candle',
  '/board': '/knowledge/board',
  '/wiki': '/knowledge/wiki',
  '/artifacts': '/knowledge/artifacts',
  '/memory': '/knowledge/memory',
  '/logs': '/infra/logs',
  '/sandboxes': '/infra/sandboxes',
  '/repos': '/infra/repos',
  '/config': '/settings',
  '/accounts': '/account',
  '/login': '/account',
})

function parseQueryString(rawQuery: string): Record<string, string> {
  const out: Record<string, string> = {}
  if (!rawQuery) return out
  const params = new URLSearchParams(rawQuery)
  params.forEach((value, key) => {
    out[key] = value
  })
  return out
}

function normalizeRawInput(raw: string): { readonly pathname: string; readonly query: Record<string, string> } {
  const trimmed = raw.trim()
  const withoutHash = trimmed.startsWith('#') ? trimmed.slice(1) : trimmed
  const qIndex = withoutHash.indexOf('?')
  const pathPart = qIndex === -1 ? withoutHash : withoutHash.slice(0, qIndex)
  const queryPart = qIndex === -1 ? '' : withoutHash.slice(qIndex + 1)
  const query = parseQueryString(queryPart)

  let pathname = pathPart.startsWith('/') ? pathPart : `/${pathPart}`
  pathname = pathname.replace(/\/+/g, '/')
  if (pathname.length > 1 && pathname.endsWith('/')) {
    pathname = pathname.slice(0, -1)
  }

  const lower = pathname.toLowerCase()
  const aliased = LEGACY_PATH_ALIASES[lower]
  if (aliased) {
    return { pathname: aliased, query }
  }
  return { pathname, query }
}

export function parseKeeperEntityTab(value: string | undefined): KeeperEntityTab {
  return KEEPER_ENTITY_TABS.find((tab) => tab === value) ?? 'chat'
}

export function resolveRoute(rawInput: string): ResolvedRoute {
  const { pathname, query } = normalizeRawInput(rawInput)
  const segments = pathname.split('/').filter(Boolean)
  const head = (segments[0] ?? 'pulse').toLowerCase()

  if (head === 'pulse') {
    return {
      path: '/pulse',
      workspace: 'pulse',
      subroute: 'overview',
      query,
      access: 'member',
      supportsTimeWindow: true,
      defaultProvenance: 'LIVE SSE',
    }
  }

  if (head === 'work') {
    const valid = WORKSPACE_NAV_BY_ID.work.subtabs
    const requested = (segments[1] ?? 'goals').toLowerCase()
    const tab = valid.find((t) => t.id === requested) ?? valid[0]!
    const entityId = segments[2] ? decodeURIComponent(segments[2]) : undefined
    return {
      path: entityId ? `/work/${tab.id}/${encodeURIComponent(entityId)}` : tab.path,
      workspace: 'work',
      subroute: tab.id,
      entityId,
      query,
      access: tab.access,
      supportsTimeWindow: tab.supportsTimeWindow === true,
      defaultProvenance: tab.defaultProvenance ?? 'SYNCED',
    }
  }

  if (head === 'knowledge') {
    const valid = WORKSPACE_NAV_BY_ID.knowledge.subtabs
    const requested = (segments[1] ?? 'board').toLowerCase()
    const tab = valid.find((t) => t.id === requested) ?? valid[0]!
    const entityId = segments[2] ? decodeURIComponent(segments[2]) : undefined
    return {
      path: entityId ? `/knowledge/${tab.id}/${encodeURIComponent(entityId)}` : tab.path,
      workspace: 'knowledge',
      subroute: tab.id,
      entityId,
      query,
      access: tab.access,
      supportsTimeWindow: tab.supportsTimeWindow === true,
      defaultProvenance: tab.defaultProvenance ?? 'SYNCED',
    }
  }

  if (head === 'keepers') {
    if (!segments[1]) {
      return {
        path: '/keepers',
        workspace: 'keepers',
        subroute: 'fleet',
        query,
        access: 'member',
        supportsTimeWindow: false,
        defaultProvenance: 'LIVE SSE',
      }
    }
    const entityId = decodeURIComponent(segments[1])
    const entityTab = parseKeeperEntityTab(segments[2]?.toLowerCase())
    return {
      path: `/keepers/${encodeURIComponent(entityId)}/${entityTab}`,
      workspace: 'keepers',
      subroute: 'detail',
      entityId,
      entityTab,
      query,
      access: 'member',
      supportsTimeWindow: false,
      defaultProvenance: entityTab === 'chat' ? 'LIVE SSE' : 'SYNCED',
    }
  }

  if (head === 'runtime') {
    const valid = WORKSPACE_NAV_BY_ID.runtime.subtabs
    const requested = (segments[1] ?? 'quotas').toLowerCase()
    const tab = valid.find((t) => t.id === requested) ?? valid[0]!
    return {
      path: tab.path,
      workspace: 'runtime',
      subroute: tab.id,
      query,
      access: tab.access,
      supportsTimeWindow: true,
      defaultProvenance: tab.defaultProvenance ?? 'SYNCED',
    }
  }

  if (head === 'infra') {
    const valid = WORKSPACE_NAV_BY_ID.infra.subtabs
    const requested = (segments[1] ?? 'sandboxes').toLowerCase()
    const tab = valid.find((t) => t.id === requested) ?? valid[0]!
    return {
      path: tab.path,
      workspace: 'infra',
      subroute: tab.id,
      query,
      access: 'admin',
      supportsTimeWindow: false,
      defaultProvenance: tab.defaultProvenance ?? 'SYNCED',
    }
  }

  if (head === 'settings') {
    const sub = segments[1]?.toLowerCase() || 'runtime'
    return {
      path: sub === 'runtime' ? '/settings' : `/settings/${encodeURIComponent(sub)}`,
      workspace: 'settings',
      subroute: sub,
      query,
      access: 'admin',
      supportsTimeWindow: false,
      defaultProvenance: 'SYNCED',
    }
  }

  if (head === 'account') {
    const valid = WORKSPACE_NAV_BY_ID.account.subtabs
    const requested = (segments[1] ?? 'profile').toLowerCase()
    const tab = valid.find((t) => t.id === requested) ?? valid[0]!
    return {
      path: tab.id === 'profile' && !segments[1] ? '/account' : tab.path,
      workspace: 'account',
      subroute: tab.id,
      query,
      access: tab.access,
      supportsTimeWindow: false,
      defaultProvenance: 'SYNCED',
    }
  }

  return {
    path: '/pulse',
    workspace: 'pulse',
    subroute: 'overview',
    query,
    access: 'member',
    supportsTimeWindow: true,
    defaultProvenance: 'LIVE SSE',
  }
}

// ── RBAC Evaluation (Fail-Closed, Zero Speculative 403s) ────────────────

export type RouteGuardDecision =
  | { readonly allowed: true }
  | { readonly allowed: false; readonly reason: 'probing' | 'auth_required' | 'admin_only' | 'account_changed' | 'unavailable' }

/**
 * Judges whether the current `AuthSession` may mount a route with `access`.
 * - `public` routes (e.g. `/account`) always mount.
 * - `single_user_local` operators have full local access (`member` + `admin`).
 * - `multi_account_signed_in`: `role === 'admin'` unlocks `admin`; `worker`/`viewer`
 *   receive `admin_only` WITHOUT mounting or firing speculative 403 requests.
 */
export function evaluateRouteAccess(
  access: RouteAccess,
  session: AuthSession,
): RouteGuardDecision {
  if (access === 'public') return { allowed: true }

  switch (session.kind) {
    case 'probing':
      return { allowed: false, reason: 'probing' }
    case 'unavailable':
      return { allowed: false, reason: 'unavailable' }
    case 'account_changed':
      return { allowed: false, reason: 'account_changed' }
    case 'multi_account_signed_out':
    case 'single_user_auth_required':
      return { allowed: false, reason: 'auth_required' }
    case 'single_user_local':
      return { allowed: true }
    case 'multi_account_signed_in':
      if (access === 'admin' && session.role !== 'admin') {
        return { allowed: false, reason: 'admin_only' }
      }
      return { allowed: true }
  }
}

export function isAdminLockedForSession(access: RouteAccess, session: AuthSession): boolean {
  return (
    access === 'admin'
    && session.kind === 'multi_account_signed_in'
    && session.role !== 'admin'
  )
}

// ── Reactive Hash Router ────────────────────────────────────────────────

function readCurrentHash(): string {
  if (typeof window === 'undefined') return '#/pulse'
  return window.location.hash || '#/pulse'
}

const currentRouteSignal = signal<ResolvedRoute>(resolveRoute(readCurrentHash()))
export const currentRoute: ReadonlySignal<ResolvedRoute> = currentRouteSignal

let hashListenerInstalled = false

export function navigate(rawPath: string, opts: { readonly replace?: boolean } = {}): ResolvedRoute {
  const next = resolveRoute(rawPath)
  const queryEntries = Object.entries(next.query)
  const qs = queryEntries.length > 0
    ? `?${new URLSearchParams(queryEntries).toString()}`
    : ''
  const nextHash = `#${next.path}${qs}`

  currentRouteSignal.value = next

  if (typeof window !== 'undefined') {
    if (opts.replace && typeof window.history?.replaceState === 'function') {
      window.history.replaceState(null, '', `${window.location.pathname}${window.location.search}${nextHash}`)
    } else if (window.location.hash !== nextHash) {
      window.location.hash = nextHash
    }
  }
  return next
}

export function initAPlusRouter(): () => void {
  if (typeof window === 'undefined') return () => {}

  const syncFromLocation = () => {
    currentRouteSignal.value = resolveRoute(readCurrentHash())
  }
  syncFromLocation()

  if (hashListenerInstalled) return () => {}
  hashListenerInstalled = true
  window.addEventListener('hashchange', syncFromLocation)
  window.addEventListener('popstate', syncFromLocation)

  return () => {
    hashListenerInstalled = false
    window.removeEventListener('hashchange', syncFromLocation)
    window.removeEventListener('popstate', syncFromLocation)
  }
}

export function resetRouterForTests(initialPath = '/pulse'): void {
  currentRouteSignal.value = resolveRoute(initialPath)
}
