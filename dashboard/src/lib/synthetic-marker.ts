// Frontend utility for backend `[SYNTHETIC]` marker handling.
//
// The MASC backend synthesizes a deterministic STATE block when a
// model finishes a turn without emitting one (so generation
// continuity is preserved — see
// `lib/keeper/keeper_memory_policy.ml:synthesize_state_from_run_result`
// and the SSOT in `lib/keeper/keeper_synthetic_marker.mli`). The
// synthesized payload is tagged `[SYNTHETIC] ...` so any consumer
// can tell apart model-native output from a backend fallback.
//
// Backend memory search rejects `[SYNTHETIC]` rows via
// `is_meaningful_memory_text` (verified at
// `test/test_keeper_memory.ml:1381`), but the dashboard surface used
// to render the marker raw — operators saw decisions / blocker
// summaries / disposition text prefixed with `[SYNTHETIC]` and had
// to either know what it meant or chase it through the codebase.
//
// This module is the dashboard-side equivalent of the backend SSOT:
// a single detector + a single user-facing label + a tooltip that
// explains the contract.

export const SYNTHETIC_PREFIX = '[SYNTHETIC]'

/**
 * Operator-facing scope label for the synthetic-marker chip. Kept
 * separate from the literal `[SYNTHETIC]` token so a future i18n or
 * naming change has a single edit point.
 */
export const SYNTHETIC_SCOPE_LABEL = '합성 fallback'

/**
 * Tooltip text rendered alongside the synthetic chip. The wording is
 * deliberately blunt about *what this is not* — "마지막 turn 의 실제
 * 모델 출력이 아닙니다" — so operators don't treat the synthesized
 * text as ground truth.
 */
export const SYNTHETIC_TOOLTIP =
  '모델이 STATE 블록을 누락한 turn 에서 backend 가 자동 생성한 fallback 입니다. '
  + '가장 최근 turn 의 실제 모델 출력이 아닐 수 있으며, 다음 non-synthetic generation '
  + '까지 그대로 유지됩니다 (TTL 없음). 의사결정 근거로 사용 전 별도 확인 필요.'

interface ScopedText {
  /** Text with the `[SYNTHETIC]` prefix stripped. Always trimmed. */
  stripped: string
  /** Whether the original text carried the synthetic marker. */
  synthesized: boolean
}

/**
 * Detect and strip the `[SYNTHETIC]` prefix from a text field.
 * Returns the cleaned text plus a boolean for the marker presence.
 *
 * The marker is matched case-sensitively (backend always emits the
 * exact literal `[SYNTHETIC]`) and only as a *prefix* after trim —
 * inline mid-string occurrences are treated as plain text because
 * they could legitimately be quoted content from another keeper.
 */
export function stripSyntheticMarker(
  text: string | null | undefined,
): ScopedText {
  const raw = text ?? ''
  const trimmed = raw.trim()
  if (!trimmed) return { stripped: '', synthesized: false }
  if (trimmed.startsWith(SYNTHETIC_PREFIX)) {
    return {
      stripped: trimmed.slice(SYNTHETIC_PREFIX.length).trim(),
      synthesized: true,
    }
  }
  return { stripped: trimmed, synthesized: false }
}

/**
 * Detect-only variant — returns just the boolean. Use this when the
 * caller wants to render the original text but with a side chip,
 * rather than the stripped form.
 */
export function hasSyntheticMarker(
  text: string | null | undefined,
): boolean {
  return stripSyntheticMarker(text).synthesized
}
