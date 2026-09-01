---
description: 승인 목록 일부를 읽지 못했을 때의 상태 두 줄
category: keeper
operator_surface: fragment
template_variables: [revision, pending_count, read_error_count]
---

- revision={{revision}} state=partial known_pending_count={{pending_count}} read_error_count={{read_error_count}}
- Missing IDs are unknown, not resolved; re-read Gate before changing conditional constraints.
