/**
 * RFC-0012 dashboard root shortcut host: single module-level
 * KeyboardShortcutManager instance shared across the dashboard.
 *
 * Wire-in policy (RFC-0012 §8):
 *   - `App` (src/app.ts) calls `useKeyboardShortcutHost(globalShortcutManager)`
 *     once at mount, binding a single document-level keydown listener that
 *     dispatches every event through the manager.
 *   - Consumer modules (command palette, modal Escape, IDE editor binds,
 *     multi-keeper pin promote / unpin) migrate their ad-hoc
 *     keydown listeners onto this manager via `useKeyboardShortcut(...)` in
 *     **separate PRs**. The host can be wired with an empty registry
 *     because `dispatch` returns `false` on no-match and the host does not
 *     `preventDefault` — existing element-scoped keydown listeners keep
 *     working until their owners migrate.
 *
 * Why a module-level singleton:
 *   The manager is reactive (subscribers fire when registrations change)
 *   and consumed from many surfaces. A module-level constant keeps the
 *   import path stable and avoids Context plumbing across the existing
 *   signals-based store layer. SPA mount-once means HMR-stale instances
 *   are not a concern in production.
 *
 * Tests must rely on `unregisterAll()` (no `_reset` API) to keep the
 * singleton's runtime contract identical across test and production.
 */
import { createKeyboardShortcutManager } from '../../design-system/headless-core/keyboard-shortcuts'

export const globalShortcutManager = createKeyboardShortcutManager()
