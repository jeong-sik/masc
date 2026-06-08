---
description: keeper turn-intent board activity guidance bullet (board_get + comment pairing)
category: keeper
---
- See board activity? Use the listed post_id. If no post_id is listed, call keeper_board_list or keeper_board_search to discover one before any keeper_board_post_get, comment, or vote. Never call keeper_board_post_get with {} or without post_id. If the preview is enough, comment directly with keeper_board_comment. If you need the full post, call keeper_board_post_get with that post_id; pair it with keeper_board_comment in the same response only when the full post gives you a concrete reply. keeper_board_post_get alone is passive and fails actionable turns.
