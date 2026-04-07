import { signal } from '@preact/signals'
import type {
  CommandPlaneChainRunResponse,
  CommandPlaneChainSummary,
  CommandPlaneHelpResponse,
  CommandPlaneSnapshot,
  CommandPlaneSummarySnapshot,
  CommandPlaneSurface,
} from './types'

export const commandPlaneSummary = signal<CommandPlaneSummarySnapshot | null>(null)
export const commandPlaneSnapshot = signal<CommandPlaneSnapshot | null>(null)
export const commandPlaneLoading = signal(false)
export const commandPlaneDetailLoading = signal(false)
export const commandPlaneError = signal<string | null>(null)
export const commandPlaneDetailError = signal<string | null>(null)
export const commandPlaneActionBusy = signal<string | null>(null)
export const commandPlaneActionError = signal<string | null>(null)
export const commandPlaneSurface = signal<CommandPlaneSurface>('operations')
export const commandPlaneHelp = signal<CommandPlaneHelpResponse | null>(null)
export const commandPlaneHelpLoading = signal(false)
export const commandPlaneHelpError = signal<string | null>(null)
export const commandPlaneChainSummary = signal<CommandPlaneChainSummary | null>(null)
export const commandPlaneChainLoading = signal(false)
export const commandPlaneChainError = signal<string | null>(null)
export const commandPlaneChainRun = signal<CommandPlaneChainRunResponse | null>(null)
export const commandPlaneChainRunLoading = signal(false)
export const commandPlaneChainRunError = signal<string | null>(null)
export const commandPlaneChainFocusOperationId = signal<string | null>(null)
