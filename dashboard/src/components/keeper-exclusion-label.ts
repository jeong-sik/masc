import type { KeeperAutobootExclusionReason } from '../types/core'

function isKeeperAutobootExclusionReason(
  reason: string,
): reason is KeeperAutobootExclusionReason {
  return reason === 'declarative_autoboot_disabled'
    || reason === 'paused'
    || reason === 'autoboot_disabled'
}

/** Map backend autoboot exclusion reasons to Korean operator-facing labels.
 *
 * Mirrors `Keeper_runtime.autoboot_exclusion_reason` (OCaml):
 *   - declarative_autoboot_disabled — keepers/<name>.toml autoboot_enabled=false
 *   - autoboot_disabled             — meta autoboot_enabled=false (no toml default)
 *   - paused                         — supervisor paused (covered by dedicated paused UI)
 *
 * `paused` returns null here because the roster and detail strip already render
 * a dedicated 일시정지 badge; only the "autoboot off" cases need a distinct
 * label so an operator sees *why* a keeper is not booting/proactive. */
export function keeperExclusionLabel(
  reason: KeeperAutobootExclusionReason | string | null | undefined,
): string | null {
  if (!reason) return null
  if (!isKeeperAutobootExclusionReason(reason)) return '부팅 제외'
  switch (reason) {
    case 'declarative_autoboot_disabled':
      return '시작 시 부팅 안 함'
    case 'autoboot_disabled':
      return '수동 부팅 해제'
    case 'paused':
      return null
    default:
      return reason satisfies never
  }
}
