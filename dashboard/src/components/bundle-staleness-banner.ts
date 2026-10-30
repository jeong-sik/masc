// BundleStalenessBanner — a long-lived tab keeps executing the bundle
// it booted with, even after the server starts serving a newer build.
// The stale tab then drives the server through code paths the current
// source no longer has (2026-06-11: a pre-RFC-0203 tab fired
// POST /api/v1/sidecar/stop?name=discord — an endpoint no current UI
// calls — and the operator saw a ghost error). BuildIdentityBadge
// shows the *server's* build; nothing compared it to the bundle the
// tab itself is running. This banner closes that gap.
//
// Detection is purely client-side: Vite stamps a content hash into the
// entry script name (/dashboard/assets/index-<hash>.js). The tab's own
// <script> tag still carries the hash it booted from; re-fetching
// /dashboard returns the index.html the server serves NOW. Different
// hash ⇒ newer bundle. Checks run when the tab regains visibility or
// focus — the moment a stale tab is picked up again — so there is no
// polling loop. A tab that stays visible through a deploy is not
// covered; it will be caught on its next focus cycle.
//
// The banner never reloads on its own: an unprompted reload can eat
// in-progress form state (channel drafts, config edits).

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { ActionButton } from './common/button'

export const newerBundleAvailable = signal(false)
const dismissed = signal(false)

export function resetBundleStalenessState() {
  newerBundleAvailable.value = false
  dismissed.value = false
}

/** Matches the entry-script reference in the served index.html. Only
    <script> tags carry src= (modulepreload chunks use href=), and Vite
    emits exactly one hashed entry per page, so the first src= match is
    the entry bundle. */
const ENTRY_SRC_RE = /src="(\/dashboard\/assets\/index-[\w-]+\.js)"/

/** Pure: extract the hashed entry-bundle path from an index.html
    document. Returns null when no hashed entry is referenced (dev
    server HTML, error pages). */
export function extractEntryBundleSrc(indexHtml: string): string | null {
  const match = indexHtml.match(ENTRY_SRC_RE)
  return match?.[1] ?? null
}

/** The entry-bundle path this tab booted from, read off its own
    <script type="module"> tag. Null under the Vite dev server (which
    serves /src/main.tsx unhashed) — staleness checks are a no-op
    there. */
export function currentEntryBundleSrc(doc: Document = document): string | null {
  const script = doc.querySelector('script[src*="/dashboard/assets/index-"]')
  return script?.getAttribute('src') ?? null
}

/** Compare this tab's entry bundle against the one the server serves
    now; arm the banner signal on mismatch. Probe failures (offline,
    non-200, no hash in the response) never arm the banner — a failed
    probe proves nothing about staleness. */
export async function checkBundleStaleness(
  fetchImpl: typeof fetch = fetch,
  doc: Document = document,
): Promise<void> {
  const own = currentEntryBundleSrc(doc)
  if (own === null) return
  try {
    const res = await fetchImpl('/dashboard', { cache: 'no-store' })
    if (!res.ok) return
    const served = extractEntryBundleSrc(await res.text())
    if (served !== null && served !== own) {
      newerBundleAvailable.value = true
    }
  } catch {
    // Offline or transient network failure — re-checked on next focus.
  }
}

/** Install visibility/focus listeners that re-probe on tab return.
    Returns the uninstaller (for the app root's effect cleanup). */
export function installBundleStalenessWatch(
  doc: Document = document,
  win: Window = window,
): () => void {
  const onReturn = () => {
    if (doc.visibilityState === 'visible') void checkBundleStaleness(fetch, doc)
  }
  doc.addEventListener('visibilitychange', onReturn)
  win.addEventListener('focus', onReturn)
  return () => {
    doc.removeEventListener('visibilitychange', onReturn)
    win.removeEventListener('focus', onReturn)
  }
}

interface BannerProps {
  /** Injected for tests; defaults to a full page reload. */
  reload?: () => void
}

export function BundleStalenessBanner({ reload }: BannerProps = {}) {
  if (!newerBundleAvailable.value || dismissed.value) return null
  const doReload = reload ?? (() => { window.location.reload() })
  return html`
    <div
      data-bundle-staleness-banner
      class="v2-shell-panel fixed bottom-5 left-1/2 z-[var(--z-overlay-toast,3070)] flex -translate-x-1/2 items-center gap-3 rounded-[var(--r-2)] border border-solid border-[var(--warn-20)] bg-[var(--color-bg-surface)] px-4 py-2.5 text-xs text-[var(--color-fg-primary)] shadow-[var(--shadow-panel)]"
      role="status"
    >
      <span>
        새 대시보드 빌드가 배포되었습니다 — 이 탭은 이전 번들을 실행 중입니다.
      </span>
      <${ActionButton}
        variant="primary"
        size="sm"
        ariaLabel="reload to latest dashboard build"
        onClick=${doReload}
      >새로고침<//>
      <${ActionButton}
        variant="ghost"
        size="sm"
        ariaLabel="dismiss stale bundle notice"
        onClick=${() => { dismissed.value = true }}
      >나중에<//>
    </div>
  `
}
