// Build-time drift guard for the keeper attention vocabulary.
//
// The backend is the single source of truth for `attention_reason` /
// `next_human_action` wire codes — they are string literals emitted from OCaml.
// keeper-attention-labels.ts hand-mirrors that vocabulary, and that mirror
// silently drifted before: the backend emitted `stale_turn_timeout` for a
// release while the frontend union had no arm for it, so the dashboard showed
// the raw English token instead of a Korean label.
//
// This test reads the actual backend emit sites and asserts every token they
// produce is a known union member here. It is the build-time enforcement the
// review asked for: when the backend adds or renames a code, this fails until
// the union/labels are updated, rather than failing silently at runtime in a
// dev console nobody is watching.
//
// It is sourced from the backend files (not a hand-copied list), so it cannot
// itself drift the way a duplicated constant would.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'
import { describe, it, expect } from 'vitest'
import {
  isAttentionReason,
  isNextHumanAction,
} from './keeper-attention-labels'

const here = dirname(fileURLToPath(import.meta.url))
// dashboard/src/lib → repo root is three levels up.
const repoRoot = resolve(here, '../../..')

function read(rel: string): string {
  return readFileSync(resolve(repoRoot, rel), 'utf8')
}

// keeper_status_bridge.ml emits attention as `true, Some "<reason>", Some
// "<action>"` triples inside the needs_attention block. Capturing the `true,`
// prefix scopes the match to that block and excludes unrelated `Some "…"` pairs.
function statusBridgePairs(): Array<{ reason: string; action: string }> {
  const src = read('lib/keeper/keeper_status_bridge.ml')
  const re = /true,\s*Some "([a-z_]+)",\s*Some "([a-z_]+)"/g
  const pairs: Array<{ reason: string; action: string }> = []
  for (let m = re.exec(src); m !== null; m = re.exec(src)) {
    const [, reason, action] = m
    if (reason && action) pairs.push({ reason, action })
  }
  return pairs
}

// keeper_status_bridge.ml `attention_fields_with_runtime_trust` can also emit
// standalone `Some "<action>"` fallbacks (e.g. when runtime_trust has no
// next_human_action / latest_next_action). These are not part of the `true,`
// triples above, so scan that function body separately.
function statusBridgeStandaloneActions(): string[] {
  const src = read('lib/keeper/keeper_status_bridge.ml')
  const start = src.indexOf('let attention_fields_with_runtime_trust')
  expect(
    start,
    'attention_fields_with_runtime_trust present in keeper_status_bridge.ml',
  ).toBeGreaterThan(-1)
  const body = src.slice(start, src.indexOf(';;', start))
  return [...body.matchAll(/Some "([a-z_]+)"/g)]
    .map((m) => m[1])
    .filter((token): token is string => token !== undefined)
}

// keeper_turn_disposition.ml `next_action` returns `Some "<action>"` per arm.
// Scope to that function body so `to_wire` / label arms are not picked up.
function dispositionActions(): string[] {
  const src = read('lib/keeper/keeper_turn_disposition.ml')
  const start = src.indexOf('let next_action = function')
  expect(start, 'next_action function present in keeper_turn_disposition.ml').toBeGreaterThan(-1)
  const body = src.slice(start, src.indexOf(';;', start))
  return [...body.matchAll(/Some "([a-z_]+)"/g)]
    .map((m) => m[1])
    .filter((token): token is string => token !== undefined)
}

function executionReceiptAttentionReasons(): string[] {
  const src = read('lib/keeper/keeper_execution_receipt.ml')
  const start = src.indexOf('let operator_disposition_reason_to_string = function')
  expect(
    start,
    'operator_disposition_reason_to_string present in keeper_execution_receipt.ml',
  ).toBeGreaterThan(-1)
  const body = src.slice(start, src.indexOf(';;', start))
  return [...body.matchAll(/-> "([a-z_]+)"/g)]
    .map((m) => m[1])
    .filter((token): token is string => token !== undefined)
}

// keeper_runtime_trust_snapshot.ml only promotes receipt disposition reasons to
// `attention_reason` when the derived display disposition needs attention.
// These receipt reasons are tied to pass/skipped dispositions and should stay
// out of the attention label union unless the backend changes that contract.
const EXECUTION_RECEIPT_PASS_ONLY_REASONS: ReadonlySet<string> = new Set([
  'healthy',
  'runtime_fallback',
  'phase_skipped',
  'input_required',
])

describe('keeper attention vocabulary drift guard', () => {
  it('extracts a non-empty backend vocabulary (guard self-check)', () => {
    // If extraction silently returns nothing, the coverage assertions below
    // would vacuously pass — assert the emit sites are actually being read.
    expect(statusBridgePairs().length).toBeGreaterThan(4)
    expect(statusBridgeStandaloneActions().length).toBeGreaterThan(0)
    expect(dispositionActions().length).toBeGreaterThan(2)
    expect(executionReceiptAttentionReasons().length).toBeGreaterThan(4)
  })

  it('every keeper_status_bridge attention_reason has a frontend label', () => {
    const missing = [...new Set(statusBridgePairs().map((p) => p.reason))].filter(
      (reason) => !isAttentionReason(reason),
    )
    expect(missing, `attention_reason codes emitted by the backend with no union arm: ${missing.join(', ')}`).toEqual([])
  })

  it('every keeper_status_bridge next_human_action has a frontend label', () => {
    const missing = [...new Set(statusBridgePairs().map((p) => p.action))].filter(
      (action) => !isNextHumanAction(action),
    )
    expect(missing, `next_human_action codes emitted by the backend with no union arm: ${missing.join(', ')}`).toEqual([])
  })

  it('every keeper_status_bridge standalone next_human_action fallback has a frontend label', () => {
    const missing = [...new Set(statusBridgeStandaloneActions())].filter(
      (action) => !isNextHumanAction(action),
    )
    expect(
      missing,
      `standalone next_human_action fallbacks with no union arm: ${missing.join(', ')}`,
    ).toEqual([])
  })

  it('every keeper_turn_disposition next_action has a frontend label', () => {
    const missing = [...new Set(dispositionActions())].filter(
      (action) => !isNextHumanAction(action),
    )
    expect(missing, `next_action codes emitted by the backend with no union arm: ${missing.join(', ')}`).toEqual([])
  })

  it('every dashboard attention-worthy execution receipt reason has a frontend label', () => {
    const attentionWorthy = executionReceiptAttentionReasons().filter(
      (reason) => !EXECUTION_RECEIPT_PASS_ONLY_REASONS.has(reason),
    )
    const missing = [...new Set(attentionWorthy)].filter((reason) => !isAttentionReason(reason))
    expect(
      missing,
      `execution receipt attention_reason codes with no union arm: ${missing.join(', ')}`,
    ).toEqual([])
  })

})
