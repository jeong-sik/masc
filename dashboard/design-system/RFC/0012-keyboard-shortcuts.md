# RFC 0012 — IDE Keyboard Shortcut System

- **Status**: Draft
- **Author**: design-system stewardship
- **Created**: 2026-04-29
- **Depends on**: RFC 0001 (Headless Foundation — `IdGenerator`)
- **Independent of**: RFC 0003 / 0005 / 0008 / 0010. Composes with all
  of them at consumer level.
- **Blocks**: spec §5.5.3 keyboard E2E gate (15 shortcut scenarios),
  Iter 5 jest-axe + render-test infra.

---

## 1. Motivation

Spec §1.3.1 explicitly calls out IDE keyboard shortcuts as
"unimplemented globally":

> `Ctrl+B`(사이드바 토글), `Ctrl+J`(하단 패널 토글), `Ctrl+1~9`(탭 전환),
> `Ctrl+W`(탭 닫기) 등 IDE 필수 단축키는 모두 미구현 상태이다.

Today the dashboard binds shortcuts ad hoc:

- `Cmd+K` for command palette via inline `keydown` on the surface.
- `Esc` handled inside individual modals via local listeners.
- Editor shortcuts (`Cmd+S`, `Cmd+/`) are Monaco's defaults — not
  surfaced anywhere visible.

The result:

- **No global discoverability**: users learn shortcuts by reading
  source.
- **Conflict-prone**: two consumers binding the same chord can both
  fire silently.
- **No `aria-keyshortcuts` exposure**: SR users get no announcement
  of the binding.
- **Modal context confusion**: a global `Esc` competes with a Dialog
  `FocusScope` `Esc`. There's no precedence policy.

This RFC defines `createKeyboardShortcutManager` — a single registry
that owns chord-to-action bindings across the whole app, surfaces
them via `aria-keyshortcuts` on the relevant trigger, and enforces a
precedence policy when scopes overlap.

## 2. Non-Goals

- Replace Monaco's editor-internal shortcuts. Editor binds are inside
  Monaco's keymap; this manager handles **outside-editor** shortcuts.
- Provide a UI for user-customizable keymaps. v1 is hardcoded
  defaults; remap UI is a follow-up.
- Implement the **command palette**. The palette is a separate
  consumer that *uses* this registry; this RFC does not design it.

## 3. Public API

### 3.1 Core

```ts
// headless-core/src/keyboard-shortcuts.ts
export type Modifier = "Mod" | "Shift" | "Alt" | "Ctrl";
// "Mod" = Cmd on macOS, Ctrl on others. Standard CodeMirror /
// Monaco convention; we don't reinvent.

export interface Chord {
  /** Key with consistent casing (e.g. "B", "1", "ArrowLeft", "/"). */
  readonly key: string;
  readonly modifiers: ReadonlyArray<Modifier>;
}

export interface ShortcutDescriptor {
  readonly id: string;                       // "ide.toggle-sidebar"
  readonly chord: Chord;
  /** Human-readable description for command palette + tooltips. */
  readonly description: string;
  /** "global" fires anywhere. Scoped to a region by element ref. */
  readonly scope: "global" | { readonly within: () => HTMLElement | null };
  /** When false, skip during text input fields. Default true. */
  readonly preserveInInputs?: boolean;
  /** Higher number wins on conflict. Default 0. */
  readonly priority?: number;
  /** Action callback. Return value ignored. */
  readonly action: (e: KeyboardEvent) => void;
}

export interface KeyboardShortcutManager {
  register(s: ShortcutDescriptor): () => void;  // returns unregister
  unregisterAll(idPrefix?: string): void;
  getAll(): ReadonlyArray<ShortcutDescriptor>;
  getById(id: string): ShortcutDescriptor | undefined;

  /** Format chord as display string ("Cmd+B" / "Ctrl+B"). */
  formatChord(chord: Chord, platform?: "mac" | "win" | "linux"): string;

  /** Format chord for ARIA `aria-keyshortcuts` (W3C spec format).
   *  Returns space-separated standard token: "Meta+B" / "Control+B". */
  formatAria(chord: Chord): string;

  /** Subscribe to registry changes (palette / settings UI). */
  subscribe(listener: (shortcuts: ReadonlyArray<ShortcutDescriptor>) => void): () => void;
}

export function createKeyboardShortcutManager(): KeyboardShortcutManager;
```

### 3.2 Preact adapter

```ts
// headless-preact/src/use-keyboard-shortcut.ts
export function useKeyboardShortcut(
  manager: KeyboardShortcutManager,
  descriptor: Omit<ShortcutDescriptor, "id">,
  id: string,
): {
  /** Display chord ("⌘+B"). */
  display: string;
  /** ARIA chord for aria-keyshortcuts attribute. */
  aria: string;
};

/** Bind a single global event listener for the registry. Mount once
 *  at the app root. */
export function useKeyboardShortcutHost(manager: KeyboardShortcutManager): void;
```

## 4. Default IDE shortcut set (v1)

These are the registered defaults at app boot. Consumers register
additional scoped shortcuts at mount.

| ID | Chord | Description |
|---|---|---|
| `ide.toggle-sidebar` | `Mod+B` | Toggle file tree sidebar |
| `ide.toggle-panel` | `Mod+J` | Toggle bottom panel (terminal/output) |
| `ide.toggle-terminal` | `Mod+\`` | Focus terminal pane |
| `ide.tab.next` | `Mod+]` (and `Mod+Tab`) | Next editor tab |
| `ide.tab.prev` | `Mod+[` (and `Mod+Shift+Tab`) | Previous editor tab |
| `ide.tab.close` | `Mod+W` | Close active tab |
| `ide.tab.switch.1` … `9` | `Mod+1` … `Mod+9` | Switch to tab N |
| `ide.command-palette` | `F1` (and `Mod+K`) | Open command palette |
| `ide.suggest.trigger` | `Ctrl+Space` | Manually trigger inline suggest |
| `ide.suggest.accept` | `Tab` (scoped to suggestion region) | Accept inline suggest |
| `ide.suggest.reject` | `Escape` (scoped to suggestion region) | Reject inline suggest |
| `ide.search.global` | `Mod+P` | Quick file open / global search |
| `ide.focus.editor` | `Mod+1` (when sidebar focused) | Move focus to editor |
| `ide.focus.sidebar` | `Mod+0` | Move focus to sidebar |
| `ide.zen-mode` | `Mod+K Z` (chord sequence — follow-up) | Toggle distraction-free |

15 shortcuts → matches spec §5.5.3 "15개 키보드 E2E 시나리오 통과"
target.

## 5. Precedence policy

When multiple shortcuts match the same chord:

1. **Scoped wins over global**. A `within: editorRef` shortcut
   intercepts before the global registry sees the event.
2. **Inside-modal wins over outside**. PortalManager top-of-stack
   has precedence — a Dialog's `Esc` consumes the event before the
   global `ide.command-palette.close` can.
3. **Higher `priority` wins** at the same scope level.
4. **Last-registered wins** at same scope + same priority (rare —
   usually a bug; manager logs a warning).

Consumer convention: text-input fields (`<input>`, `<textarea>`,
`contenteditable`) drop **all** shortcuts unless
`preserveInInputs: true`. So `Mod+B` fires while a user is typing
in a name field — but `Tab` (which moves focus) does not steal Tab
inside an input.

## 6. Accessibility

- **`aria-keyshortcuts`**: each consumer that exposes a UI affordance
  for a shortcut (button, menuitem, command palette row) sets
  `aria-keyshortcuts={manager.formatAria(chord)}`. SR users hear
  "Toggle sidebar, Meta+B" on focus.
- **Discoverability via Tooltip (RFC 0006)**: trigger surfaces show a
  tooltip with the display chord. Manager provides
  `manager.formatChord` so display matches the user's platform
  (`⌘+B` on macOS, `Ctrl+B` elsewhere).
- **`aria-live` for state changes**: not used by the manager itself.
  Consumers (sidebar / panel) announce their own state via
  `role="region"` `aria-expanded`.

## 7. Test plan

`headless-core/src/keyboard-shortcuts.test.ts`:

1. **Register / unregister** — manager carries shortcut after
   register; unregister callback removes it.
2. **`getById`** — returns undefined for missing.
3. **`unregisterAll(prefix)`** — removes only matching ids.
4. **Chord match** — synthesizing `KeyboardEvent` with `Meta` + `b`
   triggers `ide.toggle-sidebar` action.
5. **Modifier exact match** — `Meta+B` does not trigger `Meta+Shift+B`
   binding.
6. **`scope: { within: ref }`** — fires only when `event.target` is
   within the ref subtree.
7. **`preserveInInputs: false`** — synthetic `keydown` originating in
   `<input>` does not fire.
8. **Priority tie-break** — two registrations same chord, higher
   priority's action runs.
9. **`formatChord` macOS** — returns `⌘+B`.
10. **`formatChord` Windows / Linux** — returns `Ctrl+B`.
11. **`formatAria`** — returns `Meta+B` (W3C ARIA spec format,
    space-separated tokens).
12. **Dialog precedence** — Dialog open + `Esc` synthetic → Dialog
    handler runs; global `ide.command-palette.close` does not
    (manager respects PortalManager top-of-stack via consumer-
    provided `isAboveStack()` callback in `scope`).

`headless-preact/src/use-keyboard-shortcut.test.tsx`:

13. **Hook lifecycle** — register on mount, unregister on unmount.
14. **`useKeyboardShortcutHost`** — single global listener;
    multiple `useKeyboardShortcut` hooks share it without binding
    duplicate listeners.

`jest-axe` against a button fixture with `aria-keyshortcuts`.

## 8. Migration path

Implementation PR registers all 15 default shortcuts at app boot.
Consumer migrations (separate PRs):

1. Sidebar component listens to `ide.toggle-sidebar`. Surfaces the
   shortcut in its toggle button via Tooltip + `aria-keyshortcuts`.
2. Bottom-panel component → `ide.toggle-panel`.
3. Tabs container → `ide.tab.*` (close / switch).
4. Command palette consumer → `ide.command-palette`.
5. InlineSuggestion (RFC 0011) → consumes the existing `Tab` /
   `Escape` defaults from this RFC's keymap rather than rolling its
   own listener.

## 9. Merge criteria

- [ ] `headless-core/src/keyboard-shortcuts.ts` lands
- [ ] All 12 core + 2 hook tests pass under `vitest --run`
- [ ] `jest-axe` passes on `aria-keyshortcuts` button fixture
- [ ] `headless-preact/src/use-keyboard-shortcut.ts` lands
- [ ] One consumer migrates as proof-of-pattern (Sidebar toggle
      recommended — high visibility, low risk)
- [ ] CHANGELOG entry under v0.5
- [ ] Default 15 shortcuts registered at app boot
- [ ] Playwright E2E covers the 15 scenarios from spec §5.5.3

## 10. Open questions

1. **Chord sequences** — `Mod+K Z` two-key sequences (zen mode) are
   useful but add complexity to the matcher. Defer to v2 RFC?
   Current proposal: yes, defer.
2. **Binding conflicts at registration time** — should `register()`
   throw or warn-and-replace when the same chord is already taken
   at the same scope+priority? Current proposal: warn-and-replace
   for development ergonomics; fail-loud is opt-in via
   `strict: true` option.
3. **User-customizable keymaps** — v1 uses defaults; some operators
   already asked for Vim-style bindings. Defer to v2 RFC; expose
   `manager.register` so plugins can layer alternatives.

These do not block draft acceptance but must close before the
implementation PR opens.
