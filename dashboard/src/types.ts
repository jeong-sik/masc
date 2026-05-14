// MASC Dashboard — Shared type definitions (barrel re-export)
// Domain-specific types are organized in src/types/ subdirectory

export * from './types/core'
export * from './types/error'
export * from './types/governance'
export * from './types/dashboard-execution'
export * from './types/dashboard-mission'
export * from './types/sse'
export * from './types/oas'

// Navigation types live next to the route table in `config/navigation.ts`,
// but tests and downstream code expect them on the `./types` barrel.
export type { NonHomeTabId, DashboardSectionNavItem } from './config/navigation'
