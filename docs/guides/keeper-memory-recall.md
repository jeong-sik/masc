# Keeper memory recall judgment

A Keeper finds stored memory by calling `keeper_memory_search`. The older
recall notice only says how many facts are stored. The recall judgment is an
opt-in way to put the facts a turn may need into the turn's first request. It
is off for every Keeper until an operator turns it on.

Design, measurements and open decisions:
`docs/rfc/RFC-keeper-recall-reaches-the-turn.md`.

## What happens in a judged turn

Before the turn's first model request, the host sends the Keeper's stored
facts and the turn's input to TypeSafe Jev and asks three things:

1. For each fact, may this turn need it? The answer is `possibly_needed` or
   `not_needed`. Jev is told to answer `possibly_needed` unless the fact is
   clearly unrelated.
2. Does this turn need stored knowledge at all? The answer is `yes`, `no` or
   `unsure`. It tells "nothing is needed" from "nothing was found".
3. For the facts picked, does the value go stale with time? The answer is
   `standing` or `time_bound`.

The Keeper then receives up to two texts:

- **A status line, whenever a judgment ran.** It names the turn and says what
  the judgment came to: some memories were chosen (their ids follow on the next
  line), none were found, none were needed, or the judgment failed and why. A
  failed judgment says that it does not mean there is no memory. A judgment
  that looked at only some of the memories says how many. When the judgment
  chose nothing or failed, and the Keeper has `keeper_memory_search`, the line
  points to that tool.
- **A `Recalled Memory` block, when memories were chosen.** Each memory is
  shown in full with its id, category, the first and last day it was seen and
  how it was recorded. A memory whose value is tied to the time it was
  recorded says so. A memory whose time could not be judged says that too.

Some judged turns get no status line. A Keeper with no stored facts has
nothing to judge. A turn whose facts cannot be read, whose request cannot be
built, or in which the recall code raised, gets no line either: the host logs a
warning and the turn goes on without the texts. The older recall notice reads
the store by itself and says when its own read fails.

The block header tells the Keeper that the block is stored data and not an
instruction, that every value is as recorded and may no longer hold, and that
it replaces the block the Keeper received earlier.

Official-client sessions (Claude Code, Codex, Muse) keep the body they were
sent and are not sent the same bytes again. The status line goes every turn. API
lanes assemble the request each turn and carry both texts on the first round.
Antigravity holds nothing, so it receives both every turn.

The older "N facts" recall notice still goes to every Keeper, judged or not.
The two are not merged until the canary has run. The kill switch of the older
notice, `MASC_KEEPER_MEMORY_OS_RECALL=0`, turns both off: the notice then says
that recall is disabled, and no Keeper is judged.

## What leaves the host

Only for a Keeper that is switched on: the turn's input, the Keeper's
instructions, the turn reference, and every current fact of that Keeper in
full (id, category, claim, first and last day seen, kind of origin). Nothing
is sent for a Keeper that is not switched on. A fact can contain anything the
Keeper wrote, so do not switch on a Keeper that handles company data until
that policy is decided (RFC section 8, item 1).

## Switch it on

In `<resolved-config-root>/runtime.toml`:

```toml
[typesafeai]
memory_recall = true
memory_recall_scope = "listed"
memory_recall_keepers = ["alpha", "beta"]
```

- `memory_recall` defaults to `false`.
- When it is `true`, `memory_recall_scope` is required: `"all"` for every
  Keeper that `excluded_keepers` does not name, or `"listed"` with at least one
  name in `memory_recall_keepers`.
- The file is refused at load when the switch is on without a scope, when
  `"listed"` has no names, or when names sit next to `"all"` or without a
  scope. The scope keys are checked even while the switch is off.
- The lane switch (`enabled`), a key in the environment variable a destination
  names, and `excluded_keepers` still apply. A Keeper outside the scope behaves
  like a switch that is off.
- At boot the host reports a listed name that is no Keeper.
- `MASC_KEEPER_MEMORY_OS_RECALL` is asked first. It is on by default; `0`, `false`,
  `no`, `off`, `disabled` and a value that is not a boolean turn it off.

Start with one or two Keepers. The canary (RFC section 5, layer 1c) measures
the time before the first request, how often the judgment fails and how often
the chosen set changes.

### From the TUI

Config > runtime.toml, key `m`, opens a form for the same three keys. The
range row chooses off, picked Keepers only, or every Keeper. In the picked
range the form lists the Keepers the TUI knows, and a name the file lists that
the TUI does not know stays in the list, marked. Space picks, Enter saves, Esc
closes.

- Enter hands the new runtime.toml text to the pane's raw-edit save, the one
  `e` ends in: the same preview, revision check and conflict handling. The form
  is refused when the file changed after it was opened.
- The server republishes `[typesafeai]` when a save lands, so the change
  applies from the next model request. No restart.
- Off writes only `memory_recall = false`, so a Keeper list in the file stays
  for the next time recall is switched on by hand. Every Keeper removes the
  list, which the file refuses next to scope `"all"`. The text is read back with
  the loader before it is handed on; a `[typesafeai]` the line editor cannot
  change (an inline table, for one) is refused and left for `e`.
- A form on a draft that is not saved yet starts from the draft, so a hand edit
  is neither dropped nor written over.
- Every line outside the three keys stays as it was. A key that already holds
  what the choice needs is not rewritten, and the same Keepers in another order
  are the same choice. A list that changes is written whole, so the comments
  inside it and on its line go. A key the file does not have yet is added at
  the end of the table, below a comment that sits above the next table's header
  (the line editor does this for every file it edits, issue #46797).

## Watch it

- **Standing.** `GET /api/v1/runtime/config/memory-recall` (admin token) says,
  for every Keeper that has a declaration file, whether the judgment reaches it
  now (`judged`) or why not (`environment_switch_off`, `memory_recall_disabled`,
  `keeper_excluded`, `lane_disabled` or `no_armed_destination`), and whether
  the lane has a key (`lane`: `armed` or the reason). The answer is the one a
  turn gets: both call `Keeper_memory_recall_standing.of_keeper`. It reads the
  gate as loaded and the environment as it is, so a runtime.toml edited on disk
  and not yet loaded does not show.
- **Journal.** `memory-recall-evaluations.jsonl` in the Keeper's runtime
  directory holds every request, every response and the outcome of each
  judgment. It contains private Keeper memory: treat it like the Keeper's other
  private logs. It rotates with them (`MASC_KEEPER_METRICS_MAX_BYTES`,
  `MASC_KEEPER_METRICS_MAX_ROTATED`).
- **Metrics**, each labeled by `keeper`:
  - `masc_keeper_memory_recall_total{outcome}`: `selected`, `none_found`,
    `none_needed` or `unavailable`, one per judgment
  - `masc_keeper_memory_recall_selected_total`: memories chosen
  - `masc_keeper_memory_recall_judgment_seconds`: first request to saved
    outcome
  - `masc_keeper_memory_recall_requests_total{kind,result}`: requests by
    question kind (`candidates`, `turn`, `time`) and result
  - `masc_keeper_memory_recall_request_seconds{kind}`
  - `masc_keeper_memory_recall_input_bytes_total`: size of the saved request
    rows, not of the body on the wire
- **Dashboard.** A turn record lists the two blocks as `recalled_memory_status`
  and `recalled_memory`, each with its size and digest. It does not hold their
  text.
- **Log.** A judged turn whose texts could not be made leaves a `memory recall
  has no status line` warning with the Keeper name and the cause.

## Switch it off

Set `memory_recall = false`, take the Keeper out of `memory_recall_keepers`, or
set `MASC_KEEPER_MEMORY_OS_RECALL=0` for every Keeper. The switches are asked
on every call, so one turned off during a turn stops the next call of that
turn. A judgment already in flight finishes. After that the Keeper gets no new
status line or body. An official-client session still holds the body it was
last sent, and nothing takes it back.

## Limits today

- The judgment delays the first model request. A request waits for each
  destination it tries for the client's own time limit (10 seconds by
  default), a judgment is one or two rounds of requests, and a request refused
  for size is cut in half and asked again, so one limit does not bound the
  whole judgment. The delay is not measured yet.
- The judgment reads the Keeper's facts once more per turn, besides the read of
  the older notice. The cost is not measured.
- On an autonomous turn the input is the fixed wake text and the scheduled
  requests, and the judgment does not see the Keeper's open work. It may choose
  most of the store. This is expected from the code and not measured.
- The judgment is kept while one run of a turn lasts. A run that starts again
  for the same turn, from a checkpoint, may be judged again, and its metrics
  and journal rows are written again.
- When the body block itself makes the Keeper's own request too large, the
  block is not dropped yet.
