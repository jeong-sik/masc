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

// Korean badge for a backend judge role. Covers the closed six-role enum
// (fusion_types.ml judge_role: Single | Refine_pass | First | Meta | Stage_meta |
// Final_meta); the staged-JoJ reducers (`stage_meta` / `final_meta`) share the
// "심판" wording of the others. Unknown roles fall through to the raw string so a
// new backend role still renders (defensive rather than expected).
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
    case 'stage_meta':
      return '단계 심판'
    case 'final_meta':
      return '최종 심판'
    default:
      return role
  }
}

// Elapsed wall-clock of a failed judge node (`Ns`, one decimal), or null when the
// node carries no timing (successful nodes, or older payloads). Shared by both
// render surfaces so a slow failure reads the same way in each.
export function judgeNodeElapsedLabel(node: FusionJudgeNode): string | null {
  return node.elapsedS != null ? `${node.elapsedS.toFixed(1)}s` : null
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
