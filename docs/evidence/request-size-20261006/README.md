# Request size, 2026-10-05..06

Evidence for `docs/rfc/RFC-a-request-carries-what-the-librarian-has-not-read.md`.
All numbers come from the live base path (`~/me/.masc`), read-only, with `measure.py` and `turn_composition.py`. The scripts print counts and sizes only; no message content is copied here. The 2026-10-06 log was still being written: files built from it cover 00:00 to about 15:00 UTC.

| File | Command | What it shows |
|---|---|---|
| `unfinished.json` | `measure.py unfinished ~/me/.masc 2026-10-06` | Atoms saved by turns that did not finish, as the next finished turn's line states them |
| `restarts.json` | `measure.py restarts ~/me/.masc 2026-10-06` | The first Agent-Core request after each keeper boot, and how many atoms of unfinished turns it carried |
| `sangsu-span.json` | `measure.py span ~/me/.masc sangsu 2026-10-05T18:00 2026-10-06T02:50` | One keeper's calls and tokens, grouped by the `total_turns` value each call logged |
| `sangsu-writes.json` | `measure.py writes <trace.json> 2077 3686` and `3686 4463` | What those calls were |
| `sangsu-composition.json` | `turn_composition.py <trace.json> 2077 3686` | Byte composition of the first loop turn's atoms |
| `turns.json` | `measure.py turns ~/me/.masc 2026-10-06` | Model calls per Keeper turn, split at keeper boots |
| `carried-you-never-change.txt` | `measure.py carried ~/me/.masc 2026-10-06 you-never-change 05:20 09:30` | Where each request's carried range opened across five turns of one keeper |
| `turn612-composition.json` | `turn_composition.py <trace.json> 3887 4211` | Byte composition of those five turns' atoms |
| `seed-by-path.txt` | log lines 10:11:34 and 10:11:50 | Two requests whose ranges opened on the same atom: one on an Agent Core runtime, one an official-client seed |
| `muse-session.json` | `measure.py session <session.jsonl>` | One Muse host session resumed for 33 Keeper turns |
| `muse-fresh.json` | `measure.py fresh <session.jsonl> 70000,100000,130000` | The same calls if each turn had started a fresh host session from a seed |

## What the numbers say

1. **The turn after an unfinished turn picks up its atoms, verbatim, by design.** A turn writes its turn-boundary line only when it finishes. After a failure past a saved checkpoint stage the same run does not retry; the next keeper cycle does (`keeper_turn_driver.ml`, "retry deferred after typed AGENT_CORE checkpoint stage … the next keeper cycle remains eligible"). The completed boundary stays where the last finished turn left it, so the next turn's requests carry the unfinished turn's atoms with their tool results verbatim (#37602 keeps resumed work out of demotion; Librarian RFC §4.6 records why a turn's start is not a safe lower bound). The Librarian reads them once a later finished turn's line states where it started.
   - 2026-10-06 (to 15:00Z): 105 such spans across 23 keepers, 6,586 atoms (`unfinished.json`). The server booted 11 times; 143 of the 189 first requests after a boot carried atoms of an unfinished turn (`restarts.json`).
   - you-never-change: an operator chat turn started at 05:21. Restarts at 06:46, 07:21, 07:52 and 08:58 each cancelled the running turn. A cancelled turn does not advance the turn number, so all five turns logged `total_turns=612`, and the four after the restarts used `turn_boundary=boundary:3887`. Their first requests carried 45, 89, 157 and 275 atoms (194 KB, 325 KB, 557 KB, 971 KB). The turn that started at 09:00 finished at 09:17. The next request used boundary 4210, and the five turns' 324 atoms (3887..4211) went out demoted in 570 KB (`carried-you-never-change.txt`).
2. **One keeper spent 1.33 billion tokens in under nine hours, most of it a loop and its resumption.** sangsu, 2026-10-05 18:00 to 10-06 02:50 (`sangsu-span.json`, `sangsu-writes.json`):
   - 18:14 to 19:57: one turn, 1,608 calls, 637.7 M tokens, up to 686,047 per call. 1,579 of its tool calls were `keeper_memory_write` (494 inserted, 1,085 re-observed an existing fact). The Ollama session limit ended it with a 429.
   - 19:57 to 21:00: the next 57 turns failed at once on the same 429. Their requests already carried 1,610 atoms (2,382,953 bytes).
   - 21:00 to 00:15: one turn, 776 calls, 641.1 M tokens, up to 966,863 per call. Every call was `keeper_memory_write` on 12 titles, and all 776 re-observed an existing fact. Its requests opened at boundary 2077 and carried the 18:14 turn's 1,609 atoms verbatim. It ended on a 429.
   - 01:24 to 01:32: 12 calls, 11.8 M tokens; a boot at 01:32:33 cut that turn. 01:33 to 02:49: 43 calls, 43.1 M tokens, up to 1,015,783 per call, on glm-5.3-flash through glm-coding and ollama_cloud. Both logged `total_turns=4043`. The line written at 02:49 stated a start of 4476, 2,399 atoms past the previous line's end (2077).
   - The 21:00 turn's first call carried 691,265 tokens; the 18:14 turn's first call carried 37,309. Taking the difference, 653,956 tokens, as what each call inherited, the 776 calls re-sent about 507 M tokens of the 18:14 turn: 79 % of the turn's 641.1 M. This assumes the fixed parts of the request stayed the same size; `reserved_bytes` was 97,969 at 18:14 and 98,616 from 19:58.
   - The Librarian did not read the 18:14 turn: no line stated its end. Its passes were also refused on quota at 18:04..18:27 and 23:20 (`claude_code` 429) and at 01:20 (Ollama 429). A pass at 19:20 succeeded and changed no fact.
   - Body demotion would not have shrunk much of it. In the first loop turn's atoms (2,329,373 bytes in the trace encoding) tool results were 56.0 % and tool-call arguments 39.1 %, but the median result was 641 bytes (`sangsu-composition.json`). RFC-0363 demotes a result only when a saturated marker (up to 1,154 bytes) is smaller than its body.
3. **Long turns exist without restarts, but fewer than the turn counter suggested.** Split at keeper boots, 2026-10-06 (to 15:00Z) had 1,291 turns: calls per turn p50 1, p90 23, p99 80, max 123. 35 turns made 50 calls or more, 3 made 100 or more (`turns.json`). An earlier count that grouped by `total_turns` alone reported max 319; that "turn" was the five you-never-change turns above.
4. **Inside a turn every result stays verbatim.** In the five you-never-change turns (atoms 3887..4211, 1,394,920 bytes in the trace encoding), tool results were 53.2 %, reasoning 31.5 %, tool-call arguments 13.7 %, assistant text 1.4 %, user input 0.1 %. 335 tool results: p50 1,324 B, p90 4,293 B, max 27,913 B (`turn612-composition.json`).
5. **An official-client seed carries bodies in full.** At 10:11 two requests opened on atom 4238: on an Agent Core runtime, 136 atoms in 191,230 bytes (body demotion on); in a Muse seed, 137 atoms in 848,823 bytes (`context_owner=official_client applied=false`). The official path also carries one more atom and the working-state message, so this is not a same-input comparison.
6. **A resumed host session keeps every turn until the host compacts.** One Muse session ran 33 Keeper turns: 447 model calls, 139.8 M input tokens (94.7 % cached), mean 312,796 and max 393,922 tokens per call. The largest request was 1,584,353 bytes. Of that, 515 KB was earlier user inputs (including a 307 KB start seed), 557 KB earlier assistant output and 426 KB tool results.
7. **Starting each turn fresh would have carried less.** If each of the 33 turns had started a fresh host session from a seed of 70 k, 100 k or 130 k tokens, the same calls would carry 39.7 M, 53.1 M or 66.5 M input tokens: 28 %, 38 % or 48 % of what was sent. The seeds would be sent uncached each turn (2.3 M to 4.3 M tokens; the session's actual uncached input was 7.4 M). The model leaves out caching inside a turn and the cost of a worse host memory, which makes fresh sessions look cheaper than they are. It is an upper bound on the saving.

## Limits

- Subscription quotas (Muse, Claude Code, Ollama Cloud) do not publish how cached tokens count, so token totals are not quota.
- `tokens=` on a `turn=` log line is one call's input plus output (`total_tok` in `lib/keeper/keeper_hooks_agent_core.ml`). The sangsu totals sum that value.
- `transmitted_bytes` measures masc's own message encoding (`Keeper_context_core.message_measurer`), reasoning blocks included. The wire serializer then drops reasoning the model row does not replay: the deepseek-v4 rows on ollama_cloud replay it only for tool-call assistant messages after the latest user message (`reasoning_replay = "latest_user_turn_tool_calls"`, `packages/agent_core/models.toml`). Each request logged in finding 1 opened on a user message, so it replayed no reasoning; the logged bytes overstate its wire size by the reasoning it carried.
- `turn_composition.py` sizes blocks in the trace file's encoding, which is not masc's message encoding. Shares are comparable to each other, not to `transmitted_bytes`.
- `unfinished` reads only lines recorded on the given day, and `turns_without_line` counts skipped turn numbers. A cancelled turn does not advance the number, so the five you-never-change turns count as 0.
- `restarts` reports one request per keeper per boot. A span that survives several boots appears once per boot, so its atoms are not summed.
- `turns` counts an official-client turn as one call, because those turns log one `turn=` line with the turn total. The Muse session in finding 6 made 447 calls over 33 turns.
- That the 21:00 sangsu turn continued the loop because it carried the earlier turn's calls is a hypothesis. Nothing here measures it.
