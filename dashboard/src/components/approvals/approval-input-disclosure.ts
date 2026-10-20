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

/** A string input reads as itself (a command keeps its line breaks); anything
 *  else is pretty-printed JSON. */
function readableText(input: unknown): string {
  return typeof input === 'string' ? input : (JSON.stringify(input, null, 2) ?? '')
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

/** Approve and Always-approve wait until the person has opened the full input. */
export function decisionWaitsForFullInput(
  disclosure: ApprovalInputDisclosure,
  fullInputOpened: boolean,
): boolean {
  return disclosure.kind === 'preview_is_partial' && !fullInputOpened
}
