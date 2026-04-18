// Unified status resolution — resolves contradictory status sources
// into a single canonical status with Korean label and tooltip.

import { statusLabel } from './status-label.js'

interface UnifiedStatusResult {
  canonical: string
  label: string
  description: string
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

  // Offline / inactive — process not running
  if (primary === 'offline' || primary === 'inactive') {
    return {
      canonical: 'offline',
      label: '오프라인',
      description: signal === 'live'
        ? '프로세스 오프라인 (미션 신호는 최근 수신됨)'
        : '프로세스 오프라인',
    }
  }

  // Active states
  if (primary === 'active' || primary === 'running' || primary === 'busy' || primary === 'working') {
    const desc = signal === 'stale'
      ? '프로세스 활성 (미션 활동은 오래됨)'
      : '프로세스 활성'
    return {
      canonical: primary,
      label: statusLabel(primary),
      description: desc,
    }
  }

  // Listening / idle
  if (primary === 'listening' || primary === 'idle') {
    return {
      canonical: primary,
      label: statusLabel(primary),
      description: signal === 'live'
        ? '대기 중 (미션 신호 수신 중)'
        : '대기 중',
    }
  }

  // Compacting / handoff — transitional
  if (primary === 'compacting' || primary === 'handoff') {
    return {
      canonical: primary,
      label: statusLabel(primary),
      description: primary === 'compacting' ? '컨텍스트 압축 중' : '핸드오프 진행 중',
    }
  }

  // No keeper/agent status — fall back to signal_truth
  if (!primary && signal) {
    if (signal === 'live') {
      return { canonical: 'live', label: '활성 (신호)', description: '미션 신호만 확인됨 (프로세스 상태 불명)' }
    }
    if (signal === 'stale') {
      return { canonical: 'stale', label: '오래됨', description: '미션 신호 오래됨, 프로세스 상태 불명' }
    }
    if (signal === 'archived') {
      return { canonical: 'archived', label: '보관됨', description: '미션 종료됨' }
    }
  }

  // Unknown
  return {
    canonical: 'unknown',
    label: '확인 필요',
    description: '상태 정보 없음',
  }
}
