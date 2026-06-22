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
import { isAttentionReason, isNextHumanAction } from './keeper-attention-labels'

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

describe('keeper attention vocabulary drift guard', () => {
  it('extracts a non-empty backend vocabulary (guard self-check)', () => {
    // If extraction silently returns nothing, the coverage assertions below
    // would vacuously pass — assert the emit sites are actually being read.
    expect(statusBridgePairs().length).toBeGreaterThan(4)
    expect(dispositionActions().length).toBeGreaterThan(2)
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

  it('every keeper_turn_disposition next_action has a frontend label', () => {
    const missing = [...new Set(dispositionActions())].filter(
      (action) => !isNextHumanAction(action),
    )
    expect(missing, `next_action codes emitted by the backend with no union arm: ${missing.join(', ')}`).toEqual([])
  })
})
