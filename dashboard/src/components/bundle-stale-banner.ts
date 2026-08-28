// The bundle-generation banner: the screen says when it is older than the
// server serving it.
//
// The server already knows — /health carries dashboard_surface with "stale"
// (build-stamp older than the server binary) or "missing" (no stamp to
// compare) — but that verdict only lived in a JSON nobody watches while
// using the UI. The cost of not surfacing it is an operator reading an old
// screen as the current one: a merged feature "isn't there", a removed
// control still renders (2026-08-27: an evening of "merged? 흠" against a
// bundle three merges behind). One strip under the top bar closes that.
//
// Absent field (an older server) renders nothing: with no verdict there is
// nothing true to warn about, and a banner that cries on "unknown" would be
// permanently on somewhere.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { useEffect } from 'preact/hooks'
import { X } from 'lucide-preact'
import type { DashboardSurfaceHealth } from '../api'
import {
  dashboardFullHealth,
  subscribeDashboardFullHealthRefresh,
} from './dashboard-full-health-state'

const bannerDismissed = signal(false)

// Test-only helper, mirroring auth-status.ts: module-level signals need a
// reset seam so *.test.ts files stay isolated.
export function __resetForTests(): void {
  bannerDismissed.value = false
}

export interface BundleStaleBannerModel {
  message: string
  nextAction: string
}

const REBUILD_ACTION = 'cd dashboard && pnpm run build 후 새로고침'

function stampClock(iso: string | undefined): string | null {
  if (!iso) return null
  // The ISO instant is exact but unreadable at a glance; the clock part is
  // what tells "this morning's bundle" from "last week's".
  const match = /T(\d{2}:\d{2})/.exec(iso)
  return match ? match[1]! : iso
}

/** What the strip should say, or null when the screen is current — or when
 *  the server gave no verdict (older server: unknown is not stale). */
export function bundleStaleBannerModel(
  surface: DashboardSurfaceHealth | null | undefined,
): BundleStaleBannerModel | null {
  if (!surface) return null
  switch (surface.status) {
    case 'stale': {
      const bundle = stampClock(surface.build_stamp_at)
      const server = stampClock(surface.binary_built_at)
      const generations =
        bundle && server ? ` (번들 ${bundle} < 서버 ${server})` : ''
      return {
        message: `지금 보고 있는 대시보드가 서버보다 낡았습니다${generations} — 새 기능이 화면에 없을 수 있어요.`,
        nextAction: surface.next_action?.trim() || REBUILD_ACTION,
      }
    }
    case 'missing':
      return {
        message:
          '대시보드 번들의 build-stamp 가 없어 이 화면이 최신인지 확인할 수 없습니다.',
        nextAction: surface.next_action?.trim() || REBUILD_ACTION,
      }
    default:
      return null
  }
}

// ── worktree-server banner ─────────────────────────────────────────
//
// The sibling generation warning: not "this screen is old" but "the server
// itself is a working tree's build". Two restarts on 2026-08-27 kept an
// old-generation worktree exe on the live port and every "merged feature is
// not there" that evening traced back to it. The server now judges its own
// executable path (health build.executable_in_worktree); this strip makes
// the verdict visible where the operator already is.

const worktreeBannerDismissed = signal(false)

export function __resetWorktreeBannerForTests(): void {
  worktreeBannerDismissed.value = false
}

/** The one-line warning, or null when the server runs the root build — or
 *  when an older server carries no verdict (unknown is neither lane). */
export function worktreeServerBannerModel(
  build: { executable_in_worktree?: boolean; executable_path?: string } | null | undefined,
): { message: string; path: string | null } | null {
  if (!build || build.executable_in_worktree !== true) return null
  return {
    message:
      '지금 서버가 작업 중인 worktree 의 빌드로 떠 있습니다 — 라이브는 root 빌드로 재시작하는 것이 안전해요.',
    path: build.executable_path?.trim() || null,
  }
}

export function WorktreeServerBanner() {
  useEffect(() => subscribeDashboardFullHealthRefresh(), [])
  const model = worktreeServerBannerModel(dashboardFullHealth.value?.build)
  if (worktreeBannerDismissed.value || !model) return null

  return html`
    <div
      role="alert"
      data-testid="worktree-server-banner"
      class="shrink-0 flex items-center justify-between gap-3 px-4 py-2 bg-[var(--warn-10)] border-b border-[var(--warn-20)] text-sm font-medium text-[var(--warn-fg)] v2-shell-panel"
    >
      <span>
        ${model.message}
        ${model.path
          ? html` <code class="font-mono text-xs opacity-80">${model.path}</code>`
          : null}
      </span>
      <button
        type="button"
        class="flex size-6 shrink-0 items-center justify-center rounded-[var(--r-1)] text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-elevated)] hover:text-[var(--color-fg-primary)] cursor-pointer transition-colors v2-shell-action"
        aria-label="worktree 서버 경고 닫기"
        onClick=${() => { worktreeBannerDismissed.value = true }}
      ><${X} size=${14} /><//>
    </div>
  `
}

export function BundleStaleBanner() {
  useEffect(() => subscribeDashboardFullHealthRefresh(), [])
  const model = bundleStaleBannerModel(dashboardFullHealth.value?.dashboard_surface)
  if (bannerDismissed.value || !model) return null

  return html`
    <div
      role="alert"
      data-testid="bundle-stale-banner"
      class="shrink-0 flex items-center justify-between gap-3 px-4 py-2 bg-[var(--warn-10)] border-b border-[var(--warn-20)] text-sm font-medium text-[var(--warn-fg)] v2-shell-panel"
    >
      <span>
        ${model.message}
        ${' '}
        <code class="font-mono text-xs opacity-80">${model.nextAction}</code>
      </span>
      <button
        type="button"
        class="flex size-6 shrink-0 items-center justify-center rounded-[var(--r-1)] text-[var(--color-fg-muted)] hover:bg-[var(--color-bg-elevated)] hover:text-[var(--color-fg-primary)] cursor-pointer transition-colors v2-shell-action"
        aria-label="번들 경고 닫기"
        onClick=${() => { bannerDismissed.value = true }}
      ><${X} size=${14} /><//>
    </div>
  `
}
