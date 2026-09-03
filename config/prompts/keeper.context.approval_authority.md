---
description: 승인 권한 안내 조각 — 틀(heading/footer)과 상태 3종
category: keeper
operator_surface: fragment
---
### heading
### Current Approval Authority

### footer
- Gate state does not prove effect application.

### state.complete (vars: revision, pending_count)
- revision={{revision}} state=complete pending_count={{pending_count}}
- Only listed IDs are pending; absent historical IDs are stale.

### state.partial (vars: revision, pending_count, read_error_count)
- revision={{revision}} state=partial known_pending_count={{pending_count}} read_error_count={{read_error_count}}
- Missing IDs are unknown, not resolved; re-read Gate before changing conditional constraints.

### state.unavailable (vars: revision)
- revision={{revision}} state=unavailable
- No pending/resolved inference is valid.

