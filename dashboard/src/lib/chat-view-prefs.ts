// Global chat-transcript visibility preferences (SSOT).
//
// These used to be per-mount useState hydrated from bespoke localStorage
// keys inside keeper-shared.ts: all three chat layouts rendered permanent
// toolbar buttons for them, and two mounted panels could drift out of sync
// until remount. They are now module-level persistent signals, surfaced in
// the Tweaks panel next to the other view preferences.

import { persistentSignal } from './persistent-signal'

// Legacy bespoke keys (pre chat-view-prefs). Values were the raw strings
// 'true' / 'false' (not JSON). Read once as the migration default — once a
// user flips a toggle, the persistentSignal key owns the state.
const LEGACY_METADATA_KEY = 'masc_keeper_chat_metadata_visible'
const LEGACY_INTERNAL_KEY = 'masc_keeper_chat_internal_visible'

function legacyBool(key: string): boolean | null {
  try {
    const raw = localStorage.getItem(key)
    if (raw === null) return null
    return raw === 'true'
  } catch {
    return null
  }
}

/** Show per-message metadata (turn ids, timestamps, routing) in transcripts. */
export const chatShowMetadata = persistentSignal<boolean>({
  key: 'dashboard:chat:show-metadata-v1',
  defaultValue: legacyBool(LEGACY_METADATA_KEY) ?? false,
})

/** Show internal (non-conversational) entries in transcripts. */
export const chatShowInternal = persistentSignal<boolean>({
  key: 'dashboard:chat:show-internal-v1',
  defaultValue: legacyBool(LEGACY_INTERNAL_KEY) ?? true,
})
