// MASC collab web viewer — welcome/snapshot/live assembly (RFC-0471 stack 6).
//
// Exact port of Collab_guest_join.feed: live entries may arrive before their
// welcome, and the snapshot overlaps them, so entries arriving before the
// snapshot completes buffer and join the snapshot by (op, op_seq) when the
// final chunk lands. A second welcome updates state without resetting the
// join; chunks outside a snapshot are dropped rather than mis-ordered.

import type {
  CollabEntry,
  CollabFrame,
  CollabLiveState,
  CollabTranscript,
} from './collab-wire'

export interface CollabWelcomeInfo {
  keeper: string
  operation: string
  readOnly: boolean
}

export type CollabJoinEvent =
  | { kind: 'snapshot-row'; row: unknown }
  | { kind: 'live-entry'; entry: CollabEntry }
  | { kind: 'state'; state: CollabLiveState; welcome: CollabWelcomeInfo | null }
  | { kind: 'transcript'; transcript: CollabTranscript }
  | { kind: 'bye'; reason: string }
  | { kind: 'error-frame'; message: string }

type JoinPhase =
  | { kind: 'awaiting-welcome'; buffered: CollabEntry[] }
  | { kind: 'snapshot'; op: string; seen: Set<string>; buffered: CollabEntry[] }
  | { kind: 'live'; seen: Set<string> }

export interface CollabJoin {
  phase: JoinPhase
}

export function createCollabJoin(): CollabJoin {
  return { phase: { kind: 'awaiting-welcome', buffered: [] } }
}

function opSeqKey(op: string, opSeq: number): string {
  return `${op}\0${opSeq}`
}

function snapshotRowSeq(row: unknown): number | null {
  if (typeof row !== 'object' || row === null || Array.isArray(row)) return null
  const seq = (row as Record<string, unknown>).seq
  return typeof seq === 'number' && Number.isInteger(seq) ? seq : null
}

export function feedCollabJoin(join: CollabJoin, frame: CollabFrame): CollabJoinEvent[] {
  switch (frame.kind) {
    case 'state':
      return [{ kind: 'state', state: frame, welcome: null }]
    case 'transcript':
      return [{ kind: 'transcript', transcript: frame }]
    case 'bye':
      return [{ kind: 'bye', reason: frame.reason }]
    case 'error':
      return [{ kind: 'error-frame', message: frame.message }]
    case 'hello':
    case 'prompt':
    case 'abort':
    case 'fetch-transcript':
      // Guest-bound frames never come from the host.
      return []
    case 'welcome': {
      const state: CollabLiveState = {
        kind: 'state',
        active: frame.active,
        guests: frame.guests,
      }
      const welcome: CollabWelcomeInfo = {
        keeper: frame.keeper,
        operation: frame.operation,
        readOnly: frame.readOnly,
      }
      if (join.phase.kind === 'awaiting-welcome') {
        join.phase = {
          kind: 'snapshot',
          op: frame.operation,
          seen: new Set(),
          buffered: join.phase.buffered,
        }
      }
      // A second welcome updates state without resetting the join.
      return [{ kind: 'state', state, welcome }]
    }
    case 'entry': {
      const phase = join.phase
      if (phase.kind === 'live') {
        if (phase.seen.has(opSeqKey(frame.op, frame.opSeq))) return []
        return [{ kind: 'live-entry', entry: frame }]
      }
      phase.buffered.push(frame)
      return []
    }
    case 'snapshot-chunk': {
      const phase = join.phase
      if (phase.kind !== 'snapshot') {
        // Chunks outside a snapshot carry rows for no join in progress;
        // dropping them beats mis-ordering the view.
        return []
      }
      for (const row of frame.entries) {
        const seq = snapshotRowSeq(row)
        if (seq !== null) phase.seen.add(opSeqKey(phase.op, seq))
      }
      const rows: CollabJoinEvent[] = frame.entries.map(row => ({ kind: 'snapshot-row' as const, row }))
      if (!frame.final) return rows
      const fresh = phase.buffered.filter(
        entry => !phase.seen.has(opSeqKey(entry.op, entry.opSeq)),
      )
      join.phase = { kind: 'live', seen: phase.seen }
      return [...rows, ...fresh.map(entry => ({ kind: 'live-entry' as const, entry }))]
    }
  }
}
