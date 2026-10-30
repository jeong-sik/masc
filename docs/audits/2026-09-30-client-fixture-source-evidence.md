# Client fixture source evidence

Checked on 2026-09-30 for RFC `clients-read-the-fixture-the-server-wrote`.
This record verifies source changes at the linked immutable heads. It does not
establish historical CI, live UI behavior, or the full weekly defect count.
TU identifiers below are the RFC author's labels for these cases.

| Case | Source change | Immutable primary source |
|---|---|---|
| TU-F01, #39991 | Approval decoder and its handwritten fixtures remove the required `goal_ids` member together. New cases accept the server-shaped row and reject the removed member. | [decoder](https://github.com/jeong-sik/masc/blob/9fcc53a43685321014436c9ddd9af2374533a9e9/dashboard/src/api/board.ts), [tests](https://github.com/jeong-sik/masc/blob/9fcc53a43685321014436c9ddd9af2374533a9e9/dashboard/src/api/board.test.ts) |
| TU-F02, TU-F17, TU-F18, #39996 | The decoder/test delta changes runtime health labels, includes `request_context`, and adds missing delivery provenance variants. | [health decoder](https://github.com/jeong-sik/masc/blob/10eb9d92ce97d6d79a618a47044dfdd9e6e52584/dashboard/src/api/schemas/runtime-probe.ts), [request decoder](https://github.com/jeong-sik/masc/blob/10eb9d92ce97d6d79a618a47044dfdd9e6e52584/dashboard/src/api/dashboard-skills.ts), [delivery decoder](https://github.com/jeong-sik/masc/blob/10eb9d92ce97d6d79a618a47044dfdd9e6e52584/dashboard/src/api/schemas/keeper-chat-delivery-provenance.ts) |
| TU-F04, #39998 | Schedule decoder and three fixture sites replace `fsm.next_due_at_iso` with `fsm.next_due_at`. Missing required summary keys now error; null remains absent. The PTY assertion adds `Next due:`. | [decoder](https://github.com/jeong-sik/masc/blob/9a535e5c5f1be1812610834a412678dbed2d8b4d/bin/masc_tui_loader.ml), [PTY fixture and assertion](https://github.com/jeong-sik/masc/blob/9a535e5c5f1be1812610834a412678dbed2d8b4d/test/test_tui_keyboard_input.py) |

These changes show why a client decoder and a handwritten client fixture can
agree on a field spelling that differs from the server. The proposed contract
requires each server-generated response case to be decoded and its consumed
values compared, with malformed-key and unknown-variant negative controls.
