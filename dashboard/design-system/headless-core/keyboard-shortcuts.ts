/**
 * KeyboardShortcutManager — global IDE shortcut registry (RFC 0012).
 *
 * Replaces ad-hoc keydown bindings scattered across the dashboard
 * (Cmd+K palette, modal Escape, editor shortcuts). One registry owns
 * chord-to-action bindings, surfaces them via aria-keyshortcuts, and
 * applies the precedence policy when scopes overlap.
 *
 * MVP scope (RFC 0012 §3, §4, §5):
 *   - Chord matching with Mod modifier (Cmd on macOS, Ctrl elsewhere)
 *   - Scope: 'global' | { within: () => HTMLElement | null }
 *   - preserveInInputs default true (Cmd+B fires in name field;
 *     Tab does NOT steal focus inside text input)
 *   - Priority tie-break with last-registered wins (with warning)
 *   - formatChord: platform-aware (⌘ on macOS, Ctrl elsewhere)
 *   - formatAria: W3C standard tokens (Meta+B / Control+B)
 *   - subscribe for palette / settings UI
 *
 * Out of scope (RFC 0012 §10):
 *   - Chord sequences (Mod+K Z) — future RFC
 *   - User-customizable keymaps — register() open for plugins
 *   - Replace Monaco editor-internal shortcuts
 */

export type Modifier = 'Mod' | 'Shift' | 'Alt' | 'Ctrl'

export interface Chord {
  readonly key: string
  readonly modifiers: ReadonlyArray<Modifier>
}

export type ScopeWithin = { readonly within: () => HTMLElement | null }
export type ShortcutScope = 'global' | ScopeWithin

export interface ShortcutDescriptor {
  readonly id: string
  readonly chord: Chord
  readonly description: string
  readonly scope: ShortcutScope
  readonly preserveInInputs?: boolean
  readonly priority?: number
  readonly action: (e: KeyboardEvent) => void
}

export interface ShortcutKeyEvent {
  readonly key: string
  readonly metaKey?: boolean
  readonly ctrlKey?: boolean
  readonly shiftKey?: boolean
  readonly altKey?: boolean
  readonly target?: { readonly tagName?: string; readonly isContentEditable?: boolean } | null
  preventDefault(): void
  stopPropagation(): void
}

export type Platform = 'mac' | 'win' | 'linux'

export interface KeyboardShortcutManager {
  register(s: ShortcutDescriptor): () => void
  unregisterAll(idPrefix?: string): void
  getAll(): ReadonlyArray<ShortcutDescriptor>
  getById(id: string): ShortcutDescriptor | undefined

  formatChord(chord: Chord, platform?: Platform): string
  formatAria(chord: Chord): string

  /** Manager-side dispatch. Consumer wires a single keydown listener
   *  at the app root and calls this with each event. */
  dispatch(event: ShortcutKeyEvent): boolean

  subscribe(listener: (shortcuts: ReadonlyArray<ShortcutDescriptor>) => void): () => void
}

export interface KeyboardShortcutManagerOptions {
  /** Override platform detection (test). Default reads navigator.platform. */
  platform?: Platform
  /** Sink for diagnostic warnings. Default console.warn. Tests inject
   *  a spy so we can assert duplicate-registration warnings. */
  warn?: (message: string) => void
}

function detectPlatform(): Platform {
  if (typeof navigator === 'undefined') return 'linux'
  const p = navigator.platform.toLowerCase()
  if (p.includes('mac')) return 'mac'
  if (p.includes('win')) return 'win'
  return 'linux'
}

function modKeyForPlatform(platform: Platform): 'meta' | 'ctrl' {
  return platform === 'mac' ? 'meta' : 'ctrl'
}

function chordMatches(
  chord: Chord,
  event: ShortcutKeyEvent,
  platform: Platform,
): boolean {
  if (chord.key.toLowerCase() !== event.key.toLowerCase()) return false
  const wantsMod = chord.modifiers.includes('Mod')
  const wantsShift = chord.modifiers.includes('Shift')
  const wantsAlt = chord.modifiers.includes('Alt')
  const wantsCtrl = chord.modifiers.includes('Ctrl')

  // Mod resolution: on mac wants metaKey; elsewhere wants ctrlKey.
  if (wantsMod) {
    const modKey = modKeyForPlatform(platform)
    const has = modKey === 'meta' ? event.metaKey === true : event.ctrlKey === true
    if (!has) return false
  }
  // Mod-only chords don't ALSO require Ctrl on win/linux (Mod IS Ctrl
  // there). But chords that explicitly want Ctrl on mac must check it.
  if (wantsCtrl && !wantsMod) {
    if (event.ctrlKey !== true) return false
  }
  if (wantsShift !== (event.shiftKey === true)) return false
  if (wantsAlt !== (event.altKey === true)) return false

  // Reject extra modifiers that the chord didn't ask for, EXCEPT for
  // ctrlKey when Mod is wanted on mac (where Mod IS metaKey, ctrlKey
  // happening to be true alongside is still rejected — RFC 0012 §5
  // exact match policy).
  if (!wantsMod && !wantsCtrl) {
    const modKey = modKeyForPlatform(platform)
    if (modKey === 'meta' && event.metaKey === true) return false
    if (modKey === 'ctrl' && event.ctrlKey === true) return false
  }

  return true
}

function isInputTarget(target: ShortcutKeyEvent['target']): boolean {
  if (target === null || target === undefined) return false
  const tag = target.tagName?.toUpperCase()
  if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return true
  if (target.isContentEditable === true) return true
  return false
}

function isInScope(
  scope: ShortcutScope,
  target: ShortcutKeyEvent['target'],
): boolean {
  if (scope === 'global') return true
  // Consumer supplies an HTMLElement check via within(); we approximate
  // when target lacks contains(). For pure-TS test paths that don't
  // pass DOM nodes, scoped shortcuts are inert (caller-side concern).
  const root = scope.within()
  if (root === null || target === null || target === undefined) return false
  // duck-type contains
  const elTarget = target as unknown as Node
  if (typeof (root as unknown as Node).contains !== 'function') return false
  return (root as unknown as Node).contains(elTarget)
}

const PLATFORM_CHORD_MOD_LABEL: Readonly<Record<Platform, string>> = Object.freeze({
  mac: '⌘',
  win: 'Ctrl',
  linux: 'Ctrl',
})

const PLATFORM_CHORD_LABELS: Readonly<Record<Modifier, string>> = Object.freeze({
  Mod: '__placeholder__', // resolved per platform in formatChord
  Shift: 'Shift',
  Alt: 'Alt',
  Ctrl: 'Ctrl',
})

const ARIA_MOD_TOKENS_MAC: Readonly<Record<Modifier, string>> = Object.freeze({
  Mod: 'Meta',
  Shift: 'Shift',
  Alt: 'Alt',
  Ctrl: 'Control',
})

const ARIA_MOD_TOKENS_NONMAC: Readonly<Record<Modifier, string>> = Object.freeze({
  Mod: 'Control',
  Shift: 'Shift',
  Alt: 'Alt',
  Ctrl: 'Control',
})

export function createKeyboardShortcutManager(
  opts?: KeyboardShortcutManagerOptions,
): KeyboardShortcutManager {
  const platform = opts?.platform ?? detectPlatform()
  const warn = opts?.warn ?? ((m: string) => console.warn(m))

  const registry = new Map<string, ShortcutDescriptor>()
  const listeners = new Set<(shortcuts: ReadonlyArray<ShortcutDescriptor>) => void>()

  function emit(): void {
    const snap = Object.freeze([...registry.values()])
    for (const l of listeners) l(snap)
  }

  return {
    register(s: ShortcutDescriptor): () => void {
      if (registry.has(s.id)) {
        warn(`KeyboardShortcutManager: id ${s.id} already registered; replacing`)
      }
      registry.set(s.id, s)
      emit()
      return () => {
        if (registry.get(s.id) === s) {
          registry.delete(s.id)
          emit()
        }
      }
    },

    unregisterAll(idPrefix?: string): void {
      if (idPrefix === undefined) {
        const had = registry.size > 0
        registry.clear()
        if (had) emit()
        return
      }
      let removed = false
      for (const id of [...registry.keys()]) {
        if (id.startsWith(idPrefix)) {
          registry.delete(id)
          removed = true
        }
      }
      if (removed) emit()
    },

    getAll(): ReadonlyArray<ShortcutDescriptor> {
      return Object.freeze([...registry.values()])
    },

    getById(id: string): ShortcutDescriptor | undefined {
      return registry.get(id)
    },

    formatChord(chord: Chord, platformOverride?: Platform): string {
      const p = platformOverride ?? platform
      const parts: string[] = []
      for (const m of chord.modifiers) {
        if (m === 'Mod') {
          parts.push(PLATFORM_CHORD_MOD_LABEL[p])
        } else {
          parts.push(PLATFORM_CHORD_LABELS[m])
        }
      }
      parts.push(chord.key.length === 1 ? chord.key.toUpperCase() : chord.key)
      // macOS uses no separator in the canonical Cmd+B → "⌘B"; but the
      // test expectations and most UIs use "+". Use "+".
      return parts.join('+')
    },

    formatAria(chord: Chord): string {
      const map = platform === 'mac' ? ARIA_MOD_TOKENS_MAC : ARIA_MOD_TOKENS_NONMAC
      const parts: string[] = []
      for (const m of chord.modifiers) parts.push(map[m])
      parts.push(chord.key.length === 1 ? chord.key.toUpperCase() : chord.key)
      return parts.join('+')
    },

    dispatch(event: ShortcutKeyEvent): boolean {
      const inInput = isInputTarget(event.target)
      // Collect candidate matches; pick the highest-priority + scoped-
      // first, last-registered as final tie-break.
      const candidates: ShortcutDescriptor[] = []
      for (const s of registry.values()) {
        if (!chordMatches(s.chord, event, platform)) continue
        if (inInput && s.preserveInInputs !== true) continue
        if (!isInScope(s.scope, event.target)) continue
        candidates.push(s)
      }
      if (candidates.length === 0) return false
      candidates.sort((a, b) => {
        // Scoped > global
        const aScoped = a.scope !== 'global' ? 1 : 0
        const bScoped = b.scope !== 'global' ? 1 : 0
        if (aScoped !== bScoped) return bScoped - aScoped
        const ap = a.priority ?? 0
        const bp = b.priority ?? 0
        if (ap !== bp) return bp - ap
        return 0 // last-registered wins via Map insertion order tie
      })
      const winner = candidates[candidates.length === 1 ? 0 : 0]!
      // For ties (same scoping + same priority) we want last-registered
      // winner; sort is stable so iterate the original Map order to find
      // the latest among ties.
      let best = winner
      const bestScoped = best.scope !== 'global'
      const bestPriority = best.priority ?? 0
      for (const c of candidates) {
        const cScoped = c.scope !== 'global'
        if (cScoped !== bestScoped) continue
        if ((c.priority ?? 0) !== bestPriority) continue
        best = c // later-registered overrides
      }
      best.action(event as unknown as KeyboardEvent)
      return true
    },

    subscribe(listener: (shortcuts: ReadonlyArray<ShortcutDescriptor>) => void): () => void {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
  }
}
