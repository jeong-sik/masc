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

const ARTIFACT_ACTION = '같은 소스 커밋의 CI 서버·대시보드 아티팩트를 설치한 뒤 새로고침'

/** Display the server's source and availability verdict without age guesses. */
export function bundleStaleBannerModel(
  surface: DashboardSurfaceHealth | null | undefined,
): BundleStaleBannerModel | null {
  if (!surface) return null
  switch (surface.status) {
    case 'mismatched': {
      const bundle = surface.dashboard_source_commit
      const server = surface.binary_source_commit
      const sources = bundle && server ? ` (대시보드 ${bundle}, 서버 ${server})` : ''
      return {
        message: `대시보드와 서버의 소스 커밋이 다릅니다${sources}.`,
        nextAction: ARTIFACT_ACTION,
      }
    }
    case 'unknown':
      return {
        message: '대시보드 또는 서버의 빌드 소스를 확인할 수 없습니다. 파일 시각으로 일치 여부를 판단하지 않습니다.',
        nextAction: ARTIFACT_ACTION,
      }
    case 'missing':
    case 'unavailable':
      return {
        message: '대시보드 아티팩트가 없거나 검증할 수 없습니다.',
        nextAction: ARTIFACT_ACTION,
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
