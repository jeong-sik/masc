# Tool answer identity, 2026-10-05..06

Evidence for `docs/rfc/RFC-a-tool-declares-what-its-answer-is.md`.
Read-only measurements of the live base path (`~/me/.masc`). The scripts print counts and key names only; no tool output content is copied here.

| File | Command | What it shows |
|---|---|---|
| `memory-write-receipts.json` | `receipt_diff.py <sangsu trace.json> 2077 4463 keeper_memory_write` | sangsu's two loop turns: identical `keeper_memory_write` inputs and the receipt keys that differed between repeats |
| `ledger-scan.json` | `evasion.py ~/me/.masc/tool_calls/2026-10/06.jsonl` | Fleet-wide: same keeper turn, same tool, same input fingerprint, 3+ calls, and whether the output fingerprints ever repeated |

## What the numbers say

1. **`keeper_memory_write` hid a loop from the repeat guard.** In sangsu's two loop turns (atoms 2077..4463) the tool was called 2,355 times with 494 distinct inputs. 482 inputs were written once; 12 were written 156 or 157 times each. For all 12, every output differed. Between two `reobserved` receipts only `recorded_at` and `revision` differed (`memory-write-receipts.json`). The exact-repeat axis needs the output fingerprint to repeat, so it never fired.
2. **The same thing happened once before.** On 2026-08-24 a keeper ran `gh auth status` four times through `Execute`; the outputs differed only in `execution_time_ms`. That case was closed by dropping that one field name from every JSON output before hashing (`measurement_field` in `lib/keeper/keeper_tool_progress_identity.ml`, whose comment records the incident).
3. **No third case shows in the ledger yet.** Ledger rows carry I/O fingerprints since #41234. The first fingerprinted row is 2026-10-06 00:17Z; `05.jsonl` has none. Over 16,174 rows of 2026-10-06 up to about 16:00Z (14,763 with fingerprints), 11 groups of 3+ identical inputs in one turn never repeated an output (`ledger-scan.json`). In 9 of them the changed keys are state: DOS emulator registers and ticks, a board snapshot, file content, Execute output. The other 2 (`BrowserTabs`, `masc_board_post_get`) are not JSON, so their changed keys are unknown. sangsu's loop rows carry no fingerprint (the binary that writes them was not deployed yet), so case 1 is not in this scan.

## Limits

- `evasion.py` compares the ledger's stored `output` field, which is redacted and truncated, so its changed-key list is a hint; the fingerprints themselves are computed from the raw output.
- The scan covers about 16 hours of fingerprinted rows. It shows what happened in that window, not that no other tool can hide a loop.
- `receipt_diff.py` compares the last two outputs of each repeated input, because the first output of a write is usually the insert itself.
