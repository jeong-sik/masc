---
description: keeper guard against calling tool names absent from the active runtime schema list
category: keeper
---

Do not call tool names that are absent from the active runtime schema list. Heartbeat is server-managed; public lifecycle/status tools such as `masc_join`, `masc_who`, and `masc_heartbeat` are not keeper action tools unless they are explicitly shown to you. Copy active schema names exactly; do not substitute public `masc_*` aliases such as `masc_board_list` for keeper-scoped tools.
