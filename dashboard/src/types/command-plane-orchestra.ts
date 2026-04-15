import type {
  CommandPlaneOperationRecord,
  CommandPlaneMicroarchSummary,
  CommandPlaneTopologySummary,
  CommandPlaneTopologyResponse,
  CommandPlaneOperationsResponse,
  CommandPlaneDetachmentsResponse,
  CommandPlaneAlertsResponse,
  CommandPlaneDecisionsResponse,
  CommandPlaneCapacityResponse,
  CommandPlaneTracesResponse,
  CommandPlaneSurface,
} from './command-plane-core'
import type {
  CommandPlaneSwarmStatus,
  CommandPlaneSwarmProof,
} from './command-plane-swarm'

export interface ChainRuntimeStatus {
  chain_id?: string | null
  started_at?: number | null
  progress?: number | null
  elapsed_sec?: number | null
}

export interface ChainHistoryEventSummary {
  event: string
  chain_id?: string | null
  timestamp?: string | null
  duration_ms?: number | null
  message?: string | null
  tokens?: number | null
}

export interface CommandPlaneChainRunNode {
  id: string
  type?: string
  status?: string
  duration_ms?: number | null
  error?: string | null
}

export interface CommandPlaneChainRun {
  run_id?: string | null
  chain_id: string
  duration_ms?: number | null
  success?: boolean | null
  mermaid?: string
  nodes: CommandPlaneChainRunNode[]
}

export interface CommandPlaneChainOverlay {
  operation: CommandPlaneOperationRecord
  runtime?: ChainRuntimeStatus | null
  history?: ChainHistoryEventSummary | null
  mermaid?: string | null
  preview_run?: CommandPlaneChainRun | null
}

export interface CommandPlaneChainConnection {
  status: 'connected' | 'degraded' | 'disconnected' | string
  base_url?: string | null
  message?: string | null
}

export interface CommandPlaneChainSummary {
  version?: string
  generated_at?: string
  connection: CommandPlaneChainConnection
  summary?: {
    linked_operations?: number
    active_chains?: number
    running_operations?: number
    recent_failures?: number
    last_history_event_at?: string | null
  }
  operations: CommandPlaneChainOverlay[]
  recent_history: ChainHistoryEventSummary[]
}

export interface CommandPlaneChainRunResponse {
  run?: CommandPlaneChainRun | null
}

export interface CommandPlaneHelpDocLink {
  title: string
  path: string
}

export interface CommandPlaneHelpConcept {
  id: string
  title: string
  summary: string
}

export interface CommandPlaneHelpStep {
  id: string
  title: string
  tool: string
  summary: string
  success_signals: string[]
  pitfalls: string[]
}

export interface CommandPlaneHelpPath {
  id: string
  title: string
  summary: string
  when_to_use: string
  steps: CommandPlaneHelpStep[]
}

export interface CommandPlaneHelpToolGroup {
  id: string
  title: string
  description: string
  tools: string[]
}

export interface CommandPlaneHelpPitfall {
  id: string
  title: string
  symptom: string
  why: string
  fix_tool: string
  fix_summary: string
}

export interface CommandPlaneHelpExample {
  id: string
  title: string
  path_id: string
  transport: string
  request: unknown
  response: unknown
  notes: string[]
}

export interface CommandPlaneHelpResponse {
  version?: string
  generated_at?: string
  docs: CommandPlaneHelpDocLink[]
  concepts: CommandPlaneHelpConcept[]
  golden_paths: CommandPlaneHelpPath[]
  tool_groups: CommandPlaneHelpToolGroup[]
  pitfalls: CommandPlaneHelpPitfall[]
  examples: CommandPlaneHelpExample[]
}

export interface CommandPlaneSnapshot {
  version?: string
  generated_at?: string
  topology: CommandPlaneTopologyResponse
  operations: CommandPlaneOperationsResponse
  detachments: CommandPlaneDetachmentsResponse
  alerts: CommandPlaneAlertsResponse
  decisions: CommandPlaneDecisionsResponse
  capacity: CommandPlaneCapacityResponse
  traces: CommandPlaneTracesResponse
  swarm_status?: CommandPlaneSwarmStatus
}

export interface CommandPlaneSummarySnapshot {
  version?: string
  generated_at?: string
  topology: {
    version?: string
    generated_at?: string
    source?: string
    summary?: CommandPlaneTopologySummary
  }
  operations: {
    version?: string
    generated_at?: string
    summary?: CommandPlaneOperationsResponse['summary']
    microarch?: CommandPlaneMicroarchSummary
  }
  detachments: {
    version?: string
    generated_at?: string
    summary?: CommandPlaneDetachmentsResponse['summary']
  }
  alerts: {
    version?: string
    generated_at?: string
    summary?: CommandPlaneAlertsResponse['summary']
  }
  decisions: {
    version?: string
    generated_at?: string
    summary?: CommandPlaneDecisionsResponse['summary']
  }
  swarm_status?: CommandPlaneSwarmStatus
  swarm_proof?: CommandPlaneSwarmProof
}

export interface CommandPlaneOrchestraFact {
  label: string
  value: string
}

export interface CommandPlaneOrchestraNode {
  id: string
  kind: 'namespace' | 'session' | 'operation' | 'detachment' | 'lane' | 'worker' | 'keeper' | string
  label: string
  subtitle?: string | null
  status?: string | null
  tone: 'ok' | 'warn' | 'bad' | string
  pulse?: string | null
  provenance: 'truth' | 'derived' | 'fallback' | string
  visual_class?: string
  glyph?: string
  parent_id?: string | null
  lane_id?: string | null
  link_tab?: 'command' | 'intervene' | string | null
  link_surface?: CommandPlaneSurface | string | null
  link_params?: Record<string, string>
  facts: CommandPlaneOrchestraFact[]
}

export interface CommandPlaneOrchestraEdge {
  id: string
  source: string
  target: string
  kind: string
  label?: string | null
  tone: 'ok' | 'warn' | 'bad' | string
  provenance: 'truth' | 'derived' | 'fallback' | string
  animated?: boolean
}

export interface CommandPlaneOrchestraSignal {
  id: string
  kind: string
  label: string
  detail?: string | null
  tone: 'ok' | 'warn' | 'bad' | string
  provenance: 'truth' | 'derived' | 'fallback' | string
  source_id?: string | null
  target_id?: string | null
  suggested_surface?: CommandPlaneSurface | string | null
  suggested_params?: Record<string, string>
}

export interface CommandPlaneOrchestraFocus {
  target_kind: 'node' | 'signal' | string
  target_id: string
  label: string
  reason: string
  suggested_surface?: CommandPlaneSurface | string | null
  suggested_params?: Record<string, string>
}

export interface CommandPlaneOrchestraResponse {
  version?: string
  generated_at?: string
  namespace: {
    project?: string
    cluster?: string
    paused?: boolean
    pause_reason?: string | null
    agent_count?: number
    task_count?: number
    message_count?: number
  }
  summary?: {
    session_count?: number
    operation_count?: number
    detachment_count?: number
    lane_count?: number
    worker_count?: number
    keeper_count?: number
    signal_count?: number
    alert_count?: number
  }
  nodes: CommandPlaneOrchestraNode[]
  edges: CommandPlaneOrchestraEdge[]
  signals: CommandPlaneOrchestraSignal[]
  focus?: CommandPlaneOrchestraFocus | null
  swarm_status?: CommandPlaneSwarmStatus
  swarm_proof?: CommandPlaneSwarmProof
  truth_notes?: string[]
}
