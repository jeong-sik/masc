// RFC-0050 PR-1 — extracted from cost-dashboard.ts.
// Pure data types + guards + route helpers. No render dependencies.

export type ViewMode = 'model' | 'keeper'
export type CostFocus = 'agent' | 'matrix' | 'latency'
export type AuditFocus = 'actor' | 'summary'

export type CostView = 'cost' | 'heuristics' | 'stress' | 'audit' | 'decisions'

export const COST_VIEWS: CostView[] = ['cost', 'heuristics', 'stress', 'audit', 'decisions']
export const COST_FOCUSES: CostFocus[] = ['agent', 'matrix', 'latency']
export const AUDIT_FOCUSES: AuditFocus[] = ['actor', 'summary']

export function isCostView(v: string | undefined): v is CostView {
  return !!v && (COST_VIEWS as string[]).includes(v)
}

export function isCostFocus(v: string | undefined): v is CostFocus {
  return !!v && (COST_FOCUSES as string[]).includes(v)
}

export function viewModeForCostFocus(focus: CostFocus | null): ViewMode {
  return focus === 'agent' ? 'keeper' : 'model'
}

export function isAuditFocus(v: string | undefined): v is AuditFocus {
  return !!v && (AUDIT_FOCUSES as string[]).includes(v)
}

export function auditRouteParams(focus: 'ledger' | AuditFocus): Record<string, string> {
  return focus === 'ledger'
    ? { section: 'runtime', view: 'audit' }
    : { section: 'runtime', view: 'audit', focus }
}
