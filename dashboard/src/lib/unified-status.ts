// Unified status resolution — resolves contradictory status sources
// into a single canonical status with Korean label and tooltip.

import { statusLabel } from './status-label.js'
import { UNKNOWN_STATUS_LABEL } from './format-string'
import {
  PHASE_DESCRIPTION_KO,
  PHASE_LABEL_KO,
  toKeeperPhaseToken,
  type KeeperPhaseToken,
} from './fleet-tone'

interface UnifiedStatusResult {
  canonical: string
  label: string
  description: string
  /** Set when `primary` parsed as a keeper display token.
   *
   *  Exists so a caller can pick a tone from `PHASE_TONE` rather than from
   *  `statusBadgeTone` (`components/common/status-badge.ts`), whose switch
   *  was written for task states: it answers `warn` for `running`, `ok`
   *  for `active`, and falls to `neutral` for `crashed` / `dead` /
   *  `draining` / `restarting` /
   *  `unbooted`. A crashed keeper therefore rendered grey there and red on
   *  the fleet panel.
   *
   *  `null` for statuses that are not keeper tokens — `'working'` is the
   *  live example (a UI-derived PulseState). Those keep the generic tone. */
  token: KeeperPhaseToken | null
}

/** The keeper vocabulary wins whenever the status is a keeper token.
 *
 *  `statusLabel` is the generic status vocabulary (tasks, connectors,
 *  fusion runs). Where the two keyspaces overlap they
 *  disagree — `running` is `진행 중` vs
 *  `실행 중` — so the agent detail header used to disagree with the
 *  keepers page about the same keeper. */
function unifiedLabel(primary: string, token: KeeperPhaseToken | null): string {
  return token ? PHASE_LABEL_KO[token] : statusLabel(primary)
}

/**
 * Resolve three independent status sources into one canonical status.
 *
 * Priority:
 *  1. keeper heartbeat status (most authoritative for "is process alive")
 *  2. agent store status (runtime projection)
 *  3. mission signal_truth (activity recency — used as annotation only)
 */
export function resolveUnifiedStatus(
  keeperStatus: string | undefined | null,
  agentStatus: string | undefined | null,
  signalTruth: string | undefined | null,
): UnifiedStatusResult {
  const primary = (keeperStatus ?? agentStatus ?? '').toLowerCase()
  const signal = (signalTruth ?? '').toLowerCase()
  // Parsed once. The arms below keep their own `canonical` values because
  // those are part of this function's contract (`active` stays `active`,
  // `busy` stays `busy`); only the label and the tone hint route through
  // the keeper SSOT.
  const token = toKeeperPhaseToken(primary)

  // Offline / inactive — process not running.
  // Matches agent-status.ts SSOT: isAgentOffline checks the same two tokens.
  if (primary === 'offline' || primary === 'inactive') {
    return {
      canonical: 'offline',
      label: PHASE_LABEL_KO.offline,
      description: signal === 'live'
        ? '프로세스 오프라인 (미션 신호는 최근 수신됨)'
        : '프로세스 오프라인',
      token: 'offline',
    }
  }

  if (primary === 'paused') {
    return {
      canonical: 'paused',
      label: unifiedLabel(primary, token),
      description: signal === 'live'
        ? '일시정지됨 (미션 신호는 최근 수신됨)'
        : '일시정지됨',
      token,
    }
  }

  // Active states. `'working'` is a UI-derived PulseState, not a backend
  // agent status — intentionally outside ACTIVE_STATUSES SSOT, and the one
  // arm here that yields a null token.
  if (primary === 'active' || primary === 'running' || primary === 'busy' || primary === 'working') {
    const desc = signal === 'stale'
      ? '프로세스 활성 (미션 활동은 오래됨)'
      : '프로세스 활성'
    return {
      canonical: primary,
      label: unifiedLabel(primary, token),
      description: desc,
      token,
    }
  }

  // Listening / idle
  if (primary === 'listening' || primary === 'idle') {
    return {
      canonical: primary,
      label: unifiedLabel(primary, token),
      description: signal === 'live'
        ? '대기 중 (미션 신호 수신 중)'
        : '대기 중',
      token,
    }
  }

  // No keeper/agent status — fall back to signal_truth. These describe the
  // mission signal, not a runtime phase, so they carry no keeper token.
  if (!primary && signal) {
    if (signal === 'live') {
      return { canonical: 'live', label: '활성 (신호)', description: '미션 신호만 확인됨 (프로세스 상태 불명)', token: null }
    }
    if (signal === 'stale') {
      return { canonical: 'stale', label: '오래됨', description: '미션 신호 오래됨, 프로세스 상태 불명', token: null }
    }
    if (signal === 'archived') {
      return { canonical: 'archived', label: '보관됨', description: '미션 종료됨', token: null }
    }
  }

  // Every keeper lifecycle token the hand-written arms above do not
  // special-case. Without this the arms covered 4 of the 12 `KeeperPhase`
  // values, and `Failing` / `Draining` / `Stopped` /
  // `Crashed` / `Restarting` / `unbooted` all fell to `unknown` —
  // so the agent detail header rendered `확인 필요` next to a phase badge
  // that said `중지` or `종료됨` for the same keeper (`agent-detail.ts`
  // renders both badges on one line). Measured 2026-07-27: 8 of 12.
  //
  // Placed after the signal-truth arms, not before, because those arms
  // annotate a known status with mission-signal context; this one only
  // fires when no arm claimed the status.
  if (token && token !== 'unknown') {
    return {
      canonical: token,
      label: PHASE_LABEL_KO[token],
      description: PHASE_DESCRIPTION_KO[token],
      token,
    }
  }

  // Unknown
  return {
    canonical: 'unknown',
    label: UNKNOWN_STATUS_LABEL,
    description: '상태 정보 없음',
    token: null,
  }
}
