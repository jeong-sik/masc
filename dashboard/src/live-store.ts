// Live audit ledger — audit entries pushed over SSE

import { signal } from '@preact/signals'
import type { AuditEntry } from './api/dashboard'

// --- Global audit ledger (O2 Phase 2) ---

const AUDIT_MAX_ENTRIES = 500

/** Append-only ring buffer of live audit entries pushed via SSE. */
export const auditEntries = signal<AuditEntry[]>([])

/** Append a single audit entry from an SSE event.  Trims to the
 *  most recent AUDIT_MAX_ENTRIES to keep memory bounded. */
export function appendAuditEntry(entry: AuditEntry): void {
  const next = [...auditEntries.value, entry]
  auditEntries.value =
    next.length > AUDIT_MAX_ENTRIES
      ? next.slice(next.length - AUDIT_MAX_ENTRIES)
      : next
}
