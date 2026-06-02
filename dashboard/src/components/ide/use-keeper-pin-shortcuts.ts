import { useEffect } from 'preact/hooks'
import type { KeyboardShortcutManager } from '../../../design-system/headless-core/keyboard-shortcuts'
import { promotePinAt, unpinHead } from './multi-keeper-pin-store'

/**
 * RFC-0027 PR-γ-2: register the 5 multi-keeper-pin keyboard shortcuts on
 * the supplied manager and dispose them on unmount.
 *
 * Chord choices avoid RFC-0012 §4 default IDE set:
 *   - `Mod+1..9` is reserved for `ide.tab.switch.1..9` → use `Mod+Shift+1..4`
 *   - `Mod+W` is reserved for `ide.tab.close` → use `Mod+Shift+W` for unpin
 *     (chord matcher `wantsShift !== shiftKey` makes the two distinct)
 *
 * Defaults follow RFC-0012 §3 conventions:
 *   - `scope: 'global'` — promote/unpin should fire from anywhere in the
 *     dashboard, not only when the multi-keeper inspector has focus
 *   - `preserveInInputs: false` — typing `Cmd+Shift+1` in a name field
 *     should NOT promote a pin; user is mid-edit
 *   - manager is injected (not the module-level `globalShortcutManager`)
 *     so tests can supply a `platform: 'mac'` instance and exercise the
 *     production chord matcher without depending on jsdom's empty
 *     `navigator.platform`. Production wiring imports
 *     `globalShortcutManager` and passes it.
 *
 * Idempotent re-mount: re-running the effect re-registers under the same
 * ids, which `KeyboardShortcutManager.register` handles by replacing in
 * place (with a diagnostic warning). Disposers chain by closure.
 */
export function useKeeperPinShortcuts(manager: KeyboardShortcutManager): void {
  useEffect(() => {
    const disposers: Array<() => void> = []

    for (let slot = 1; slot <= 4; slot += 1) {
      const idx = slot
      disposers.push(
        manager.register({
          id: `ide.pin.promote-${idx}`,
          chord: { key: String(idx), modifiers: ['Mod', 'Shift'] },
          description: `Promote pinned keeper #${idx} to head`,
          scope: 'global',
          preserveInInputs: false,
          action: () => promotePinAt(idx),
        }),
      )
    }

    disposers.push(
      manager.register({
        id: 'ide.pin.unpin-head',
        chord: { key: 'w', modifiers: ['Mod', 'Shift'] },
        description: 'Unpin the head pinned keeper',
        scope: 'global',
        preserveInInputs: false,
        action: () => unpinHead(),
      }),
    )

    return () => {
      for (const dispose of disposers) dispose()
    }
  }, [manager])
}
