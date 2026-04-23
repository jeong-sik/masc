// Dashboard error notification types

export interface DashboardError {
  id: string
  fingerprint: string
  agentName: string
  taskId: string | null
  message: string
  timestamp: number
  acknowledged: boolean
  count: number
  lastSeen: number
}
