// RFC-0284 judge-node display formatting (i18n). The data layer
// (`classifyFusionJudgeShape` / `normalizeFusionJudgeNodes` in lib/fusion-meta)
// stays language-free; the Korean labels live here in the component layer and
// are shared by both render surfaces — the standalone fusion surface
// (`fusion-surface.ts`) and the inline board evidence card
// (`board/fusion-evidence.ts`) — so the backend role/shape vocabulary has a
// single mapping and cannot drift between the two views.
import type { FusionJudgeNode, FusionJudgeShape } from '../../lib/fusion-meta'

// Display label for a shape classification.
const JUDGE_SHAPE_LABEL: Record<FusionJudgeShape, string> = {
  single: '단일 심판',
  refine: '재검토',
  'judge-of-judges': '심판의 심판',
  custom: '심판 위상',
}

export function judgeShapeLabel(shape: FusionJudgeShape): string {
  return JUDGE_SHAPE_LABEL[shape]
}

// Korean badge for a backend judge role. Unknown roles fall through to the raw
// string so a new backend role still renders (the enum is closed on the backend,
// so this is defensive rather than expected).
export function judgeRoleLabel(role: string): string {
  switch (role) {
    case 'first':
      return '1차'
    case 'meta':
      return '메타'
    case 'refine':
      return '재검토'
    case 'single':
      return '단일'
    default:
      return role
  }
}

// Per-node combined token figure (`Nk tok` / `N tok`), em-dash when no usage.
export function judgeNodeTokenLabel(node: FusionJudgeNode): string {
  const total = (node.inputTokens ?? 0) + (node.outputTokens ?? 0)
  if (total <= 0) return '—'
  return total >= 1000 ? `${(total / 1000).toFixed(1)}k tok` : `${total} tok`
}

// A meaningful node identity, or null. The backend only carries a real model id
// for `first` nodes (the panelist_id); single/refine/meta echo their role string
// as the identity (fusion_sink.ml judge_role_fields), which is redundant with the
// role badge, so suppress it rather than print the role twice.
export function judgeNodeIdentity(node: FusionJudgeNode): string | null {
  return node.identity && node.identity !== node.role ? node.identity : null
}

// Topology chip (label + tooltip) for the run header, derived from the judges
// array shape alone (RFC-0284 §line 27: the frontend must not hardcode a
// topology-name vocabulary keyed off a wire field). `conditional` cannot be told
// apart from `refine` in the observation record — `run.topology` is not recorded
// on the wire (audit-area-4), so a refine shape is labelled `refine` without the
// conditional split. A `custom`/unanticipated shape returns null so the header
// omits the chip rather than inventing a name.
export interface FusionTopologySpec {
  readonly lbl: string
  readonly desc: string
}

const JUDGE_SHAPE_TOPOLOGY: Record<FusionJudgeShape, FusionTopologySpec | null> = {
  single: { lbl: 'simple', desc: 'panel → judge → sink' },
  refine: { lbl: 'refine', desc: 'panel → judge → judge′ 재검토' },
  'judge-of-judges': { lbl: 'judge-of-judges', desc: 'panel → 1차 심판 ×N → meta reconcile' },
  custom: null,
}

export function judgeShapeTopology(shape: FusionJudgeShape): FusionTopologySpec | null {
  return JUDGE_SHAPE_TOPOLOGY[shape]
}
