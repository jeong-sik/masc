---
description: 승인 목록을 전부 읽었을 때의 상태 두 줄
category: keeper
operator_surface: fragment
template_variables: [revision, pending_count]
---

- revision={{revision}} state=complete pending_count={{pending_count}}
- Only listed IDs are pending; absent historical IDs are stale.
