/**
 * IDE workspace store — app-lifetime singleton accessor.
 *
 * Why this exists: `IdeShell` is hard-unmounted whenever the user leaves the
 * `code` tab (DashboardMain renders `LazyIdeShell` only in `case 'code'`, and
 * the surface wrapper is keyed on `currentTab`). A per-instance
 * `createIdeDataWorkspaceStore()` therefore disposed on navigation and rebuilt
 * fresh on return, wiping tree expansion, repo selection, diff, and file
 * content. The module-level signals in `ide-state.ts` (activeIdeFile,
 * ideContextFocus) survive precisely because they are module-scoped; this
 * module gives the *workspace* store the same app-lifetime scope.
 *
 * Lazy construction is mandatory: `createIdeDataWorkspaceStore()` fires a
 * `fetchRepositoriesList()` network call and installs a signal `effect()` at
 * construction time. Constructing at import time would run those before the
 * IDE is ever opened (and, in the pure-eval import chain, before `window`
 * exists). The getter constructs on first access — i.e. the first IDE mount.
 *
 * Cycle-safety: this module imports ONLY `./ide-data-workspace-store`, which
 * already sits below `ide-shell` and touches no router/window at module eval.
 * It deliberately does NOT live in `ide-state.ts` (which must stay pure
 * signals/types per its own header) and does not import the router.
 */

import {
  createIdeDataWorkspaceStore,
  type IdeDataWorkspaceStore,
} from './ide-data-workspace-store'

let instance: IdeDataWorkspaceStore | null = null

/**
 * Return the app-lifetime IDE workspace store, constructing it on first call.
 * Idempotent: repeated calls (e.g. across IdeShell remounts) return the same
 * instance, so tree/repo/diff/content state persists across tab navigation.
 */
export function getIdeDataWorkspaceStore(): IdeDataWorkspaceStore {
  if (instance === null) {
    instance = createIdeDataWorkspaceStore()
  }
  return instance
}

/**
 * Dispose and clear the singleton. Test-only: production never disposes the
 * store (it is intentionally app-lifetime). Vitest suites that construct a
 * store must call this in afterEach to avoid leaking the live SSE
 * registration and signal effect across tests.
 */
export function resetIdeDataWorkspaceStoreForTest(): void {
  if (instance !== null) {
    instance.dispose()
    instance = null
  }
}
