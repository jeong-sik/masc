import type {
  KeeperApprovalAuditEvent,
  KeeperApprovalAuditReceipt,
} from '../types'
import { isRecord } from './type-guards'

const APPROVAL_AUDIT_EVENTS = new Set<KeeperApprovalAuditEvent>([
  'pending',
  'resolved',
  'summary_updated',
  'rule_created',
  'rule_deleted',
  'grant_consumed',
  'gate_allowed',
  'gate_exact_rule_expired',
  'gate_exact_rule_store_degraded',
  'gate_grant_unavailable',
  'auto_judge_operator_retry_started',
  'auto_judge_block_observation_superseded',
  'auto_judge_restart_worker_recovered',
  'auto_judge_restart_judgment_recovered',
])

function isApprovalAuditEvent(value: unknown): value is KeeperApprovalAuditEvent {
  return typeof value === 'string'
    && APPROVAL_AUDIT_EVENTS.has(value as KeeperApprovalAuditEvent)
}

export function normalizeKeeperApprovalAuditReceipt(
  raw: unknown,
): KeeperApprovalAuditReceipt | null {
  if (!isRecord(raw) || !isApprovalAuditEvent(raw.event)) return null
  if (raw.recorded === true && Object.keys(raw).length === 2) {
    return { event: raw.event, recorded: true }
  }
  if (
    raw.recorded === true
    && Object.keys(raw).length === 3
    && isRecord(raw.cleanup_failure)
    && raw.cleanup_failure.stage === 'append_cleanup'
    && typeof raw.cleanup_failure.detail === 'string'
    && raw.cleanup_failure.detail.trim() !== ''
    && Object.keys(raw.cleanup_failure).length === 2
  ) {
    return {
      event: raw.event,
      recorded: true,
      cleanup_failure: {
        stage: 'append_cleanup',
        detail: raw.cleanup_failure.detail,
      },
    }
  }
  if (
    raw.recorded === false
    && (raw.stage === 'store_create' || raw.stage === 'append')
    && typeof raw.detail === 'string'
    && raw.detail.trim() !== ''
    && Object.keys(raw).length === 4
  ) {
    return {
      event: raw.event,
      recorded: false,
      stage: raw.stage,
      detail: raw.detail,
    }
  }
  return null
}
