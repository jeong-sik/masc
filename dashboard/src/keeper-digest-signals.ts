import { signal } from '@preact/signals'
import type { KeeperCatchupDigest } from './api/schemas/keeper-catchup-digest'

// Per-keeper since-last-seen digest state. Flat Record signals keyed by keeper
// name, mirroring the keeperThreads / keeperHydrating shape in keeper-state.ts.
// The digest is fetched once per panel mount with the baseline cursor captured
// at that moment; the value's `since_unix` echo is the frozen anchor the card
// and the unread divider render against (so a later cursor advance does not move
// them mid-visit).
export const keeperCatchupDigests = signal<Record<string, KeeperCatchupDigest | null>>({})
export const keeperDigestLoading = signal<Record<string, boolean>>({})
export const keeperDigestError = signal<Record<string, string | null>>({})
