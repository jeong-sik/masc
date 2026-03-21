// Semantic layer panels removed from dashboard UI.
// This metadata is for AI agents and belongs in tool descriptions,
// not in the human-facing operator dashboard.
// Keeping the export signature so 71 call sites don't need changes.

export function PanelSemanticDetails(_props: {
  panelId: string
  compact?: boolean
  label?: string
}) {
  return null
}
