/** Hand-written TypeScript types derived from proto/masc_coordination.proto.
 *
 * These are used by the grpc-web transport until protoc codegen is wired.
 */

export interface JoinRequest {
  agentName: string
  capabilities: string[]
  metadata: Record<string, string>
}

export interface JoinResponse {
  success: boolean
  message: string
  sessionId: string
  activeAgents: AgentInfo[]
}

export interface LeaveRequest {
  agentName: string
  sessionId: string
}

export interface LeaveResponse {
  success: boolean
  message: string
}

export interface HeartbeatPing {
  agentName: string
  sessionId: string
  timestampMs: number
  currentTaskId?: string
}

export interface HeartbeatAck {
  timestampMs: number
  activeAgentCount: number
  pendingTaskCount: number
  directives: string[]
}

export interface SubscribeRequest {
  agentName: string
  sessionId: string
  eventTypes?: string[]
  sinceSeq?: number
}

export interface Event {
  seq: number
  eventType: string
  sourceAgent: string
  timestampMs: number
  payloadJson: string
}

export interface ToolCallRequest {
  agentName: string
  sessionId: string
  toolName: string
  argumentsJson: string
}

export interface ToolCallResponse {
  success: boolean
  resultJson: string
  errorMessage: string
  errorCode: number
}

export interface BroadcastRequest {
  agentName: string
  message: string
  mentions?: string[]
}

export interface BroadcastResponse {
  success: boolean
  seq: number
}

export interface StatusRequest {
  // empty for now
}

export interface StatusResponse {
  agents: AgentInfo[]
  tasks: TaskInfo[]
  messageCount: number
  roomPath: string
}

export interface AgentInfo {
  name: string
  status: string
  capabilities: string[]
  lastHeartbeatMs: number
  joinedAtMs: number
  currentTaskId?: string
}

export interface TaskInfo {
  id: string
  title: string
  status: string
  assignedTo: string
  priority: number
}
