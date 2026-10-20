// What the approval screen can honestly say about a tool input.
//
// Approve and Always-approve execute the whole stored input, bound to
// `input_hash`. `input_preview` is the server's cut-down copy (strings
// shortened, the result cut again and redacted), so a person who reads only the
// preview can approve text they never saw. This module decides, from the two
// fields the server sends, whether the preview is the whole input.
//
// The decision does not depend on the preview's length limit: it compares the
// preview with the compact serialization of the full input, so a longer or
// shorter server limit changes nothing here. A preview that merely differs
// (whitespace, redaction, escaping) counts as partial, which errs toward
// showing more.

import type { KeeperApprovalQueueItem } from '../../types'

export type ApprovalInputDisclosure =
  /** The preview is the whole input; nothing is hidden. */
  | { kind: 'preview_is_whole' }
  /** The full input was sent and differs from the preview. */
  | { kind: 'preview_is_partial'; fullText: string }
  /** The server sent no full input, so the preview is all there is and it may be cut. */
  | { kind: 'full_input_not_sent' }

// Characters that draw nothing or reorder what is drawn around them: zero-width
// and joiner marks, bidirectional embeddings, overrides and isolates, the byte
// order mark, the soft hyphen and the tag block. In text a person approves they
// would let the screen and the executed input differ, so each is written out as
// its code point.
const INVISIBLE_OR_REORDERING =
  /[\u00AD\u061C\u180E\u200B-\u200F\u202A-\u202E\u2060-\u2064\u2066-\u2069\uFEFF]|[\u{E0000}-\u{E007F}]/gu

function showInvisible(text: string): string {
  return text.replace(INVISIBLE_OR_REORDERING, ch => {
    const code = ch.codePointAt(0) ?? 0
    return `\u27E6U+${code.toString(16).toUpperCase().padStart(4, '0')}\u27E7`
  })
}

/** A string input reads as itself (a command keeps its line breaks); anything
 *  else is pretty-printed JSON. Invisible and reordering characters are shown
 *  by code point. */
function readableText(input: unknown): string {
  return showInvisible(typeof input === 'string' ? input : (JSON.stringify(input, null, 2) ?? ''))
}

export function approvalInputDisclosure(
  item: Pick<KeeperApprovalQueueItem, 'input' | 'input_preview'>,
): ApprovalInputDisclosure {
  if (item.input === undefined) return { kind: 'full_input_not_sent' }
  const compact = JSON.stringify(item.input)
  const preview = item.input_preview?.trim() ?? ''
  if (compact !== undefined && preview === compact) return { kind: 'preview_is_whole' }
  return { kind: 'preview_is_partial', fullText: readableText(item.input) }
}

/** Approve and Always-approve wait until the person has read the full input to
 *  its end. Every disclosure kind is named, so a new one fails typecheck here
 *  instead of silently not holding the decision. */
export function decisionWaitsForFullInput(
  disclosure: ApprovalInputDisclosure,
  fullInputRead: boolean,
): boolean {
  switch (disclosure.kind) {
    case 'preview_is_partial': return !fullInputRead
    case 'preview_is_whole': return false
    // Nothing was sent to read; the screen says so instead of holding.
    case 'full_input_not_sent': return false
  }
}
