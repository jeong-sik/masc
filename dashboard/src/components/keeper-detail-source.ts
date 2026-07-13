import { missionKeeperBriefs } from '../mission-signals'
import type {
  DashboardMissionKeeperBrief,
  Keeper,
} from '../types'

export function resolveKeeperMissionBrief(
  keeper: Pick<Keeper, 'name' | 'agent_name'>,
): DashboardMissionKeeperBrief | null {
  return missionKeeperBriefs.value.find(brief =>
    brief.name === keeper.name
      || (brief.agent_name && keeper.agent_name && brief.agent_name === keeper.agent_name))
    ?? null
}

interface KeeperObservedToolAuditSnapshot {
  source: 'mission_brief' | 'dashboard_summary' | 'none'
  latestToolNames: string[]
  latestToolCallCount: number | null
  toolAuditSource: string | null
  toolAuditAt: string | null
}

export function resolveKeeperObservedToolAudit(
  keeper: Pick<Keeper, 'latest_tool_names' | 'latest_tool_call_count' | 'tool_audit_source' | 'tool_audit_at'>,
  missionBrief: DashboardMissionKeeperBrief | null,
): KeeperObservedToolAuditSnapshot {
  const hasMissionAudit =
    missionBrief != null && (
      (missionBrief.latest_tool_names?.length ?? 0) > 0
      || missionBrief.latest_tool_call_count != null
      || !!missionBrief.tool_audit_source?.trim()
      || !!missionBrief.tool_audit_at?.trim()
    )

  if (hasMissionAudit && missionBrief) {
    return {
      source: 'mission_brief',
      latestToolNames: missionBrief.latest_tool_names ?? [],
      latestToolCallCount: missionBrief.latest_tool_call_count ?? null,
      toolAuditSource: missionBrief.tool_audit_source ?? null,
      toolAuditAt: missionBrief.tool_audit_at ?? null,
    }
  }

  const hasDashboardAudit =
    (keeper.latest_tool_names?.length ?? 0) > 0
    || keeper.latest_tool_call_count != null
    || !!keeper.tool_audit_source?.trim()
    || !!keeper.tool_audit_at?.trim()

  if (hasDashboardAudit) {
    return {
      source: 'dashboard_summary',
      latestToolNames: keeper.latest_tool_names ?? [],
      latestToolCallCount: keeper.latest_tool_call_count ?? null,
      toolAuditSource: keeper.tool_audit_source ?? null,
      toolAuditAt: keeper.tool_audit_at ?? null,
    }
  }

  return {
    source: 'none',
    latestToolNames: [],
    latestToolCallCount: null,
    toolAuditSource: null,
    toolAuditAt: null,
  }
}
