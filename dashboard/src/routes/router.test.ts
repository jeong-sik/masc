// @vitest-environment happy-dom
import { beforeEach, describe, expect, it } from 'vitest'
import type { AuthSession } from '../core/auth'
import {
  FOOTER_NAV,
  ROUTE_MANIFEST,
  TRUNK_NAV,
  WORKSPACE_NAV,
  currentRoute,
  evaluateRouteAccess,
  isAdminLockedForSession,
  navigate,
  resetRouterForTests,
  resolveRoute,
} from './router'

const AUTH_METHODS = { google: true, github: true, dev_token: false } as const

describe('Proposal A+ declarative router & RBAC manifest', () => {
  beforeEach(() => {
    window.location.hash = ''
    resetRouterForTests('/pulse')
  })

  it('locks exactly 6 L0 trunks, 2 rail footer anchors, and <=5 L1 sub-tabs per workspace', () => {
    expect(TRUNK_NAV.map((t) => t.id)).toEqual([
      'pulse',
      'work',
      'knowledge',
      'keepers',
      'runtime',
      'infra',
    ])
    expect(FOOTER_NAV.map((f) => f.id)).toEqual(['settings', 'account'])
    for (const nav of WORKSPACE_NAV) {
      expect(nav.subtabs.length).toBeLessThanOrEqual(5)
    }
    expect(ROUTE_MANIFEST.length).toBeGreaterThanOrEqual(22)
  })

  it('resolves canonical A+ routes, Keeper entity tabs, and legacy aliases cleanly', () => {
    expect(resolveRoute('/pulse')).toMatchObject({
      workspace: 'pulse',
      subroute: 'overview',
      supportsTimeWindow: true,
      defaultProvenance: 'LIVE SSE',
    })
    expect(resolveRoute('#/work/candle')).toMatchObject({
      workspace: 'work',
      subroute: 'candle',
      supportsTimeWindow: true,
    })
    expect(resolveRoute('/knowledge/memory')).toMatchObject({
      workspace: 'knowledge',
      subroute: 'memory',
      supportsTimeWindow: true,
    })
    expect(resolveRoute('/keepers/code-reviewer-sister/portrait-candle')).toMatchObject({
      workspace: 'keepers',
      subroute: 'detail',
      entityId: 'code-reviewer-sister',
      entityTab: 'portrait-candle',
    })
    expect(resolveRoute('/keepers/grimja')).toMatchObject({
      workspace: 'keepers',
      entityId: 'grimja',
      entityTab: 'chat',
      defaultProvenance: 'LIVE SSE',
    })
    expect(resolveRoute('/runtime/lanes?mode=exact')).toMatchObject({
      workspace: 'runtime',
      subroute: 'lanes',
      query: { mode: 'exact' },
      supportsTimeWindow: true,
    })
    expect(resolveRoute('/infra/logs')).toMatchObject({
      workspace: 'infra',
      subroute: 'logs',
      access: 'su_read_ma_admin',
      defaultProvenance: 'LIVE SSE',
    })
    expect(resolveRoute('#overview').path).toBe('/pulse')
    expect(resolveRoute('#account').workspace).toBe('account')
    expect(resolveRoute('#logs').path).toBe('/infra/logs')
    expect(resolveRoute('#board').path).toBe('/knowledge/board')
    expect(resolveRoute('#board?post=post%2F42&comment=reply')).toMatchObject({
      path: '/knowledge/board/post%2F42',
      entityId: 'post/42',
      query: { post: 'post/42', comment: 'reply' },
    })
    expect(resolveRoute('/knowledge/board/explicit?post=legacy').entityId).toBe('explicit')
    expect(resolveRoute('/monitoring?section=board').path).toBe('/knowledge/board')
  })

  it('evaluates RBAC fail-closed across all AuthSession states without speculative 403s', () => {
    const workerSession: AuthSession = {
      kind: 'multi_account_signed_in',
      mode: 'multi_account',
      accountId: 'u-worker',
      email: 'w@example.com',
      displayName: 'worker',
      role: 'worker',
      csrfToken: 'csrf',
      authMethods: AUTH_METHODS,
      workspaceId: 'default',
    }
    const adminSession: AuthSession = { ...workerSession, accountId: 'u-admin', role: 'admin' }
    const signedOut: AuthSession = {
      kind: 'multi_account_signed_out',
      mode: 'multi_account',
      authMethods: AUTH_METHODS,
    }
    const singleLocal: AuthSession = {
      kind: 'single_user_local',
      mode: 'single_user',
      tokenPresent: true,
      authMethods: AUTH_METHODS,
      workspaceId: 'default',
    }

    expect(evaluateRouteAccess('public', signedOut)).toEqual({ allowed: true })
    expect(evaluateRouteAccess('member', signedOut)).toEqual({ allowed: false, reason: 'auth_required' })
    expect(evaluateRouteAccess('member', workerSession)).toEqual({ allowed: true })
    expect(evaluateRouteAccess('admin', workerSession)).toEqual({ allowed: false, reason: 'admin_only' })
    expect(isAdminLockedForSession('admin', workerSession)).toBe(true)
    expect(isAdminLockedForSession('admin', adminSession)).toBe(false)
    expect(evaluateRouteAccess('admin', adminSession)).toEqual({ allowed: true })
    expect(evaluateRouteAccess('admin', singleLocal)).toEqual({ allowed: true })

    // Fail-closed across all unauthenticated states and single-user non-admin roles
    const probing: AuthSession = { kind: 'probing' }
    const unavailable: AuthSession = { kind: 'unavailable', reason: 'offline' }
    const singleAuthReq: AuthSession = { kind: 'single_user_auth_required', mode: 'single_user', authMethods: AUTH_METHODS, reason: 'missing_token' }
    const accountChanged: AuthSession = {
      kind: 'account_changed',
      mode: 'multi_account',
      previousAccountId: 'u-1',
      nextAccountId: 'u-2',
      authMethods: AUTH_METHODS,
    }
    const singleWorker: AuthSession = { ...singleLocal, role: 'worker', canTokenAdmin: false }
    const singlePlayer: AuthSession = { ...singleLocal, role: 'player', canTokenAdmin: false }
    const singleAuthDisabled: AuthSession = { ...singleLocal, role: 'admin', canTokenAdmin: false }

    expect(isAdminLockedForSession('admin', probing)).toBe(true)
    expect(isAdminLockedForSession('admin', unavailable)).toBe(true)
    expect(isAdminLockedForSession('admin', signedOut)).toBe(true)
    expect(isAdminLockedForSession('admin', singleAuthReq)).toBe(true)
    expect(isAdminLockedForSession('admin', accountChanged)).toBe(true)
    expect(isAdminLockedForSession('admin', singleWorker)).toBe(true)
    expect(isAdminLockedForSession('admin', singlePlayer)).toBe(true)
    expect(isAdminLockedForSession('admin', singleAuthDisabled)).toBe(true)
    expect(evaluateRouteAccess('admin', singleWorker)).toEqual({ allowed: false, reason: 'admin_only' })
    expect(evaluateRouteAccess('admin', singlePlayer)).toEqual({ allowed: false, reason: 'admin_only' })
    expect(evaluateRouteAccess('admin', singleAuthDisabled)).toEqual({ allowed: false, reason: 'admin_only' })
    // su_read_ma_admin: SU Admin/Worker/auth-disabled + MA Admin allowed; MA Worker & SU Player locked
    expect(evaluateRouteAccess('su_read_ma_admin', singleWorker)).toEqual({ allowed: true })
    expect(evaluateRouteAccess('su_read_ma_admin', singleAuthDisabled)).toEqual({ allowed: true })
    expect(evaluateRouteAccess('su_read_ma_admin', adminSession)).toEqual({ allowed: true })
    expect(evaluateRouteAccess('su_read_ma_admin', workerSession)).toEqual({ allowed: false, reason: 'admin_only' })
    expect(evaluateRouteAccess('su_read_ma_admin', singlePlayer)).toEqual({ allowed: false, reason: 'admin_only' })
    expect(isAdminLockedForSession('su_read_ma_admin', workerSession)).toBe(true)
    expect(isAdminLockedForSession('su_read_ma_admin', singleWorker)).toBe(false)
    expect(isAdminLockedForSession('member', probing)).toBe(false)
  })

  it('syncs navigate() into currentRoute and window.location.hash', () => {
    navigate('/runtime/quotas')
    expect(currentRoute.value.path).toBe('/runtime/quotas')
    expect(window.location.hash).toBe('#/runtime/quotas')
  })
})
