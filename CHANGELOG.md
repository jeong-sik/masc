# Changelog

## [Unreleased]

### Changed

- The TUI reads a connector's `gateway_state` and `poll_state` as closed
  variants instead of strings, rejects a value the server's state machines
  never produce, and decides whether the Channels pane's Runtime state row
  repeats the connection badge by matching constructors rather than comparing
  lowercased words. The runtime picker's kind badge width is measured from
  the badge strings instead of being written as 7 in three places (#38050).
- The runtime failover concept is now named the **Runtime Candidate Order** in
  the TUI: the lane key help and status strings say "candidate order" where
  they said "failover" — the `e` key help and its label on the lane sheet
  (`masc_tui_keys.ml`), the picker's status line on the chat pane and in the
  route editor (`masc_tui_render.ml`), and the in-row status of a keeper whose
  turn moved to its next runtime candidate
  (`masc_tui_keeper_chat_transcript.ml`). The runtime detail panel's
  `Failover Chain:` label now reads `Candidate Chain:`, matching the
  `Head Candidate:` label beside it (`masc_tui_render.ml`). The `(no runtime lanes configured)`
  empty state and the `pick a runtime lane` help now say "runtime candidate
  order", matching the glossary's Runtime Candidate Order entry; the shipped
  `config/runtime.toml` section comment says "Runtime candidate orders" (#37918).
  The `[runtime].media_failover` key, which orders the vision fleet and is a
  different mechanism, is unchanged — its screen strings keep the key name,
  and the glossary now carries a `media_failover` entry fencing it from the
  renamed concept.

### Fixed

- A settled Skill row no longer wears the mark for a turn still working. `Skill_delivered` — the state whose row reads `전달됨, 도구 안 씀` — was drawn in the live tone, so a finished history line carried the hollow diamond `◇` and read as a skill still in progress among the settled lines around it. It weighed more once the SKILL word left the row (#36870) and the mark became the only signal on that axis. Delivered and used are the two ends of one life and now share the settled mark `◆`; which of the two it was is what the row's words say. The tone is named `Skill_settled` rather than after one of the states it covers (#36883).
- The planning projection counts a Task awaiting verification as its own state instead of folding it into `in_progress`. The live Backlog row read `in_progress=21` for 14 Tasks being worked and 7 waiting on a verifier, while the Task Review tab beside it counted those same 7, so one screen gave the same Tasks two numbers and the word naming the wait was the one the count hid. `task_backlog` now carries `awaiting_verification`, and the TUI's Backlog row draws it with the mark its Task rows wear (#37995).
- The Keepers fleet row says when its task-owner scan came up short. The scan reports what it could not read, and only a backlog failure moves the fleet status off `ok`, so a Keeper whose profile did not load left its tasks out of the count with nothing on the row saying so. The count now carries its own shortfall: `task owner without fiber 0+ (2 sources unread)`, the `+` because the number is a lower bound over the sources that could be read (#38012).
- The chat status area no longer reserves a row it does not draw. The pane skips the in-flight row for the request the live transcript is already drawing — that transcript says the phase, the age and the tools, and a second row put a second age and an opaque request id above the `ACTIVE TURN` line — but the row budget counted every in-flight request. With one message in flight, which is the ordinary case, the area held a row nobody drew: a blank line under the status rows and the footer one row off from what was on screen. The pane and the budget now read the same list (#37741).
- The Identity tab no longer repeats the keys its footer draws. The sentence above the service list spelled them because the title row carried the hint and cut it (#35539); the keys have since moved to the footer, which draws all six at 120 columns and gives up `/:filter` and `R:refresh` at 80 with `?` naming what it dropped (#38011).
- The Approvals title counts what its tab badge counts. The badge is the sum of the approval rows and the questions Keepers have open, and the Overview row reads the same helper, but the title counted the approval rows alone: with one open question the tab read `Approvals·1` and the screen it opened read `MASC Approvals (0)`. The title now reads `(1 question)`, naming the kind beside the three approval kinds (#38006).
- A repository whose clone or fetch failed says what went wrong. The failure is stamped on the repository with the git message and the route writes it to the wire, but nothing read it: the Workspace surface drew `error` in a nine-cell column and the cause was on no screen. The status is now read as the closed type the store keeps, with the cause inside it, and the selected row's context draws it (#38002).
- The Board title counts what the board holds rather than the listing page it drew. The listing is one server page of fifty with no key past it, so a board of 109 posts read `MASC Board (50)` and the 59 posts off the page left no trace; the title now reads `(50 of 109)`, and `(41)` where the page carries everything (#37999).
- Transcript tail recovery reads a missing checkpoint ref as `Already_dispatchable`, as its interface promised, instead of failing the recovery as `Checkpoint_unavailable` on a keeper whose session directory holds no checkpoint yet. A ref that cannot be read, names another identity or session, or cannot be locked still fails it (#37904).
- A `cd` operand in a keeper's Execute call is checked to exist only under the Host and Docker sandboxes, where the host filesystem is what the command sees. Microvm, SSH and delegated sandboxes keep their checkouts in the guest, so the host check refused every `cd <checkout>` on those keepers with a path error. The containment check still applies under every sandbox (#37908).
- On the official-client lanes (Claude Code, Codex, Antigravity) the Librarian working state now carries its own marker too, so a request that holds both it and the turn's context carrier no longer fails the composition check as a repeated carrier (`keeper_official_client_host.ml`, #38033).
- A Librarian working state carried into a keeper's next request no longer wears the extra-system-context tag. The prompt-context check counted that tag and found two carriers, so it reported `prompt_context_presence_mismatch` or `prompt_context_carrier_repeated` on every request and left the turn record's `input_components` empty. The working state now carries its own `masc.librarian_working_state.v1` tag, and the tail window pins it the same way (#37894).
- The verification queue (`GET /api/v1/verification/requests?view=awaiting`) says which verdict each row waits on: `intent` is `complete` or `cancel`, read from the task the row names, and `null` in the history view, which has no backlog join. A cancellation waits on the same queue as a completion and only an operator's verdict clears it, so a reader could not tell the seven cancel requests waiting since 2026-09-19 from completion requests (#37965).
- The TUI's Task Review list draws a `VERDICT` column (`complete` or `cancel`) between the task id and the submitter, and the request detail says `Waits on: cancel -- only an operator's verdict clears it` for a cancellation. The list used to draw a cancellation request and a completion request as the same row, so the one row only an operator could clear looked like every other (#37965).
- A boot replay of a durable HITL delivery, and an operator resubmitting the same decision, no longer write a second `resolved` row to the approval audit ledger or announce the decision again. Both send the wake again and log `hitl resolution redelivered approval=… occasion=boot_replay|same_request_resubmitted`. One approval for an offline keeper had nineteen `resolved` rows across twenty-one boots on 2026-09-22, so a count of the ledger read as nineteen decisions for one click (#37964).


## [0.36.0] - 2026-09-22

> Before you upgrade: read the five items under **Upgrade notes** — the keeper system prompt's new worldview slot and role tags (#37753), the removed `--dup-threshold` purge option (#37751), the new Fusion `deliberation_evidence` shape that earlier run records do not read as (#37783), the required `--keeper` argument of `masc-checkpoint-purge` (#37802), and the continuity-lag keys the keeper memory health payload now carries, which a TUI or dashboard from the other side of that change refuses (#37856).

### Upgrade notes

- The shared keeper prompt (`keeper`) no longer carries a value system, and the `keeper.instructions.custom` slot is gone: a keeper's `instructions` now sit in `<role>` tags as written, with no heading in front. What a world values goes in the new `keeper.worldview` slot, whose default says no value system is set and each keeper's role decides. An operator override of `keeper` still replaces the whole shared body, so to take the new body, move any worldview text from that override into `keeper.worldview` and clear the `keeper` override. Restart the server right after installing the binary: until it restarts, an old server reads the new prompt files and cannot find `keeper.instructions.custom`, which fails the turns of every keeper that has instructions (#37753).
- `masc-checkpoint-purge` no longer takes `--dup-threshold`; a call that still passes it fails with `unknown argument`. The purge report no longer has `duplicates_dropped` or `reasoning_messages_dropped`, and the dashboard purge table drops the matching column, because a purge no longer removes messages (#37751).
- Fusion run records saved before this version do not read as the new `deliberation_evidence` shape, which now carries `seat_routes`; there is no compatibility reader for them (#37783).
- `masc-checkpoint-purge` now takes `--keeper <name>`; the keeper's meta names the trace and `--trace` only cross-checks it. A call with `--trace` alone exits 1. The tool used to look for the keeper's Librarian position, boundary log and continuity snapshot under the checkpoint's `agent_name`, which on a live keeper is the agent's runtime id, so it never found them and `--apply` moved no position (#37770).
- The keeper memory health payload (`/api/v1/dashboard/keeper-memory-health`) carries the Librarian's continuity lag: `continuity_unread_atoms` on each keeper's `librarian` object, and `librarian_continuity_unread_atoms` with `librarian_continuity_unmeasured` in `totals`. The TUI and the dashboard check the payload's key set exactly, so a server and a TUI or dashboard from different sides of this change do not draw the Memory screen, in either direction: the TUI shows the Memory header as failed and the dashboard shows the health panel's error. Upgrade the server together with the TUI and the dashboard, and roll them back together (#37856, #37863).

### Added

- Keeper memory health now reports where the Librarian has read to, and where a snapshot it is rewriting from atom 0 has to reach, beside the cut a request starts at. A snapshot that stopped moving while the position kept going is what the turn carries, and the cut alone could not say so: the numbers were in the logs only. The TUI Memory screen prints the position and how far past the cut it sits (#37793).
- A Fusion judge seat (single, refine, JOJ first pass, meta and stage meta) can name an official-client runtime (Claude Code, Codex or Antigravity); the judge then runs as a one-turn CLI call, the same path a panel seat takes, instead of failing every run with `Build_error`. Its token usage is recorded as unmeasured and its tool record as `Official_client_uninstrumented` (#37768).
- A Fusion seat (panel or any judge role) takes a route name, resolved the way a keeper assignment is: a `[runtime.lanes.<name>]` names candidates that are tried in order until one answers, a runtime id names that one. HTTP and official-client runtimes can share one list. The deliberation evidence and the Board meta record which candidate answered each seat and which failed before it, as `seat_routes`. A route that does not resolve fails the run as `Unknown_route` or `Route_unavailable` instead of falling back to a default runtime (#37783).
- One Fusion run can name its own judge and panel without editing `runtime.toml`: the `masc_fusion` tool and `POST /api/v1/keepers/<name>/fusion` take `judge` (one route name) and `panel` (route names), and `fusion_run --topology` takes `--judge` and `--panel`. A route that does not resolve, or a roster the preset's own checks reject, fails the call instead of being read as "unchanged" (#37809).
- Fusion presets are edited through typed operations instead of raw file text: `POST /api/v1/runtime/config/fusion` (CanAdmin) takes `set_settings`, `upsert_preset`, `delete_preset` or `rename_preset`, refuses a seat route that does not resolve and the deletion of the preset an enabled `[fusion]` still names as its default, and commits through the same validation, atomic replace and audit record as a raw save. The dashboard's Fusion settings panel edits panel and judge seats, their system prompts, timeout, output token limit, first-pass judges and grouped panels this way, and adds, renames or deletes a preset. Each save carries the revision it read, so a file changed in between is refused as `configuration_changed` instead of overwritten (#37794, #37819).
- The TUI's `tools:full` view opens an Execute call with its exit status and elapsed time, then its output and stderr, instead of the whole JSON result envelope. An output stored as an artifact shows its digest and size, and a timed-out call shows its limit on the status line. A served input or output longer than eight lines shows its first eight and a `… +N lines · Keeper Calls (t)` line in place of the rest (#37766, #37792, #37803).
- In the TUI, the skill calls of one turn fold into a single counted row (`msx-observe ×3`) the way tool calls already did, and a composition's row says it ran rather than that it was read (#37820).
- The TUI's `journal:full` view draws each Memory journal revision's facts in two columns — sign and category on the left, the claim wrapped at word boundaries on the right (#37764).
- In a chat pane at least 96 columns wide, lines that arrive from another keeper, another person or a connector start a third of the way across the pane, so they sit apart from the operator's messages and the keeper's replies; narrower panes keep one column (#37773).
- The catalog and the shipped `config/runtime.toml` carry nine more OpenRouter models, each probed before its row was written: `claude-fable-5.1`, `claude-haiku-4.5`, `gpt-6-astra`, `gpt-5.6-terra`, `gpt-5.6-luna`, `gemini-3.1-pro-preview`, `grok-4.7`, `qwen3.8-flash` and `glm-5.3-flashx`. The rows record what the probes found, such as a model that refuses a required or named `tool_choice` or rejects reasoning effort `none`, and `glm-5.3-flashx` declares no structured output. OpenRouter `minimax-m3` is not bound, because at effort `high` and above it answers with empty content; its Ollama Cloud binding stays (#37782, #37789).
- Z.AI coding-plan (`glm-coding`) models `glm-5.2`, `glm-5.1`, `glm-5-turbo`, `glm-5`, `glm-4.7`, `glm-4.6`, `glm-4.5` and `glm-4.5-air` have their own catalog rows, so they no longer fall back to the glm defaults of a 200000-token window and 40960 output tokens. The catalog gives `kimi-for-coding` a 1048576-token window and adds a `k3-256k` row. The shipped `config/runtime.toml` binds every subscription and coding-plan model (Claude Code, Codex, Antigravity, `glm-coding`, `kimi_coding`, Ollama Cloud) and marks the binding the install wizard picks with `wizard-default` (#37767).
- In the TUI, a failed operator action — a `Ctrl-V` paste with no image, a `/find`, `/queue`, `/steer` or `/preset` call missing its argument, an image that cannot be opened, a voice failure — is shown on the current pane's footer for a few seconds and written to the event log, instead of being left as an error line in the chat history. A request the server refused still appears in the history (#37796).
- In the TUI's summary chat view, a Librarian pass that keeps failing is named once on the header's status line, as `Librarian failing ×N since HH:MM:SS · <kind>`, instead of as a journal row between every turn; the full view still shows each failed pass (#37798).
- An official-client keeper request (Claude Code, Antigravity) starts where the Librarian read to, as an Agent-Core request already did, and carries the working state in place of the atoms that position covers, instead of resending the conversation the keeper's memory already holds. The latest of the three positions wins: the Librarian's, the lane's own cut and the last turn's seed (#37619).
- The TUI Fusion screen can start a run: `a` opens a form for the Keeper, preset, topology, prompt and web tools, posts it, and selects the new run once the list carries it. A preset the topology cannot run comes back as the server's own sentence (#37823).
- A Fusion run's detail lists its seat routes: the route each panel and judge seat was given, the runtime that answered it, and every candidate that failed before that one. Runs recorded without routes draw no block (#37823).
- The Memory screen shows how far each keeper's continuity snapshot trails the Librarian's read position, beside the durable drain's unread count: the TUI keeper line says `continuity behind N`, the Memory header and the dashboard totals strip sum it over the fleet. A lag that could not be taken, because there is no snapshot, the file does not read, the snapshot names another trace or it sits ahead of the position, reads as `?` and is counted as unmeasured rather than as zero, and the fleet sum covers only the keepers it was taken for (#37856).
- The TUI writes why a session ended to its own log, one line per session in `.masc/logs/masc-tui-<pid>.log`: `[masc-tui] exit: normal (quit key)`, `[masc-tui] exit: normal (signal SIGTERM)` or `[masc-tui] exit: abnormal (exception ...)` — grep the `[masc-tui] exit:` prefix to collect them and nothing else. A normal end is the operator or the session's owner asking for it — the `q` key, a second `Ctrl-C`, or a terminate signal — and an abnormal one is an uncaught exception, or `no cause was recorded` if a session somehow leaves without naming one. A cause longer than 200 bytes is cut on a character boundary and the row ends in `[+N bytes]`, so one runaway backtrace cannot make the line unreadable. The per-PID log held only the boot lines, so a session that ended left no reason behind: roughly a hundred files a day and none said why (task-754).

### Changed

- The shared keeper prompt is organized around the situations where a keeper's default goes wrong — a default stance, continuity across turns, where to speak, working with other keepers, finishing, setbacks and boundaries — and names the tools each one uses. The system prompt is assembled as system, worldview, the world's articles, identity, workspace and role. The identity, workspace and constitution blocks are written in Korean, and the English draft the prompt editor loads (`keeper.en`) mirrors the shared body (#37753).
- Checkpoint purge (dashboard and `masc-checkpoint-purge`) keeps every message, and keeps byte-exact the last atom, the reply each completed turn ended on, and whatever a fitting Librarian working state covers, so the Librarian position, turn-boundary lines, working state and request front all still match the purged checkpoint. The report counts stripped reasoning blocks and cleared tool results; a dashboard apply keeps new Librarian units out until it finishes (#37751).
- `masc login` prints only the MCP token variable and `MASC_DASHBOARD_URL`. It no longer prints `MASC_OPERATOR_AGENT` or `MASC_OPERATOR_TOKEN`, which no request path accepted (#37769).
- The shipped `trio` preset's judge seat names the new `fusion-judge` lane instead of a single runtime. Its first candidate is the runtime the seat already used, so the choice is unchanged; a limit, a refusal or a failure now falls through to two further candidates on other providers instead of failing the deliberation. `quorum` and `council` keep their own meta judges. A test holds every shipped preset's seat names to the lanes and `[provider.model]` bindings the same file declares (#37829).
- The TUI Overview's TUI Session Events pane marks an error event with `✗` after its clock, the glyph the chat pane uses for a failure. Every event used to draw the same row whatever its level, so a failed credential mint and a first install waiting for its workspace could be told apart only by reading the sentence. The mark is a shape, so it also shows under `NO_COLOR`; other levels draw as before (task-1685).
- The TUI's three Skills panes read as counts and columns instead of ledger fields. The call surface draws flow numbers only for a composition and `why loaded` only where a Keeper profile or a Task chose the skill, marking anything else `unattributed` in the warning color. A skill record names its scope on one line and counts `triggered / delivered / handed off / actions` underneath, dropping every all-zero row. Usage is one right-aligned row per keeper with its last use in terminal time, instead of every keeper strung onto one line (#37830).

### Fixed
- A Librarian continuity pass that a provider refused now reads less on the next pass instead of starting over. The pass used to ask whether the refusal was about size, read that verdict from whichever slot the walk happened to end on, and keep the answer only until the pass ended; a keeper whose continuity snapshot no longer fits its history prepares from atom 0, so every pass offered the whole backlog, halved it twice and died, and one keeper read nothing for a day. The width it narrowed to is now carried to the next pass and released only once the backlog is read to its end, the unit is cut at that width rather than at the midpoint below it, and the verdict is taken from every failure in the walk. A pass reads less only when something it met says the size is why it stopped: an HTTP refusal for a quota, an overload, a server or network error, an authentication, authorization or payment refusal, or an absent model, a candidate a slot turned away for its own reasons, a snapshot that failed to commit, and a pass that recorded no cause at all all leave the width where it is. A provider error that is not an HTTP refusal, such as a dropped connection or a hard quota reported without one, still narrows, because the provider library reports all of them as one cause (#37899). A failed pass no longer retries in place: it records the narrower width and waits for the next signal (#37793).

- A Fusion run records an official-client timeout as a timeout instead of a provider error, and runs every panel seat in its own fiber instead of starting the CLI seats after the HTTP ones finish (#37768, #37783).
- A keeper request that starts at the last completed turn records that turn's boundary as its `turn_start` `end_atom`, instead of the atom where the clamped range opens; the next-request forecast does the same (#37757).
- A first install's TUI waits for its workspace instead of printing a `masc login` command it does not need: a base path that holds no workspace yet is told apart from a mint that failed, and only the second one asks the operator to act (#37813).
- Saving `runtime.toml` — raw save, its preview, routing and assignment edits, the TUI key save — now rejects a `[fusion]` section that does not load, such as `panel = []`, a preset without a judge, a `default_preset` that names no preset, or `min_answered` above the panel seat count; before, one such save made every later Fusion run fail with `fusion config invalid` until the file was fixed by hand. Server boot does not run this check (#37787).
- The TUI's `metadata:full` title line no longer shows the request id, and the mark's color and weight end at the mark instead of running into the rule (#37780).
- A keeper whose turn-boundary store cannot be read, or matches no boundary of its history, no longer sends its whole history as if the last completed turn ended at atom 0. The request opens on the newest atom alone and its origin says `turn_start_unknown` with the reader's reason, in the TUI band and the request forecast as well (#37746).
- A Librarian working state that cannot be read, cannot be checked against the turn-boundary log, or covers conversation bytes that changed no longer refuses every Agent-Core turn. The request starts at the Librarian's read position, or at the turn's own boundary, as it does when the working state no longer fits, and the reason is logged as a warning. A refused turn also ran no Librarian round, so a working state whose covered bytes changed was never written again; a working-state file or boundary log that cannot be read now leaves turns running and names the file to fix (#37762).
- A Fusion panel or judge seat on an Antigravity runtime receives its system prompt (the panel's group prompt, the judge prompt, a JOJ first-pass perspective) ahead of the question, as a keeper turn does; before, the prompt was dropped and the seat answered without its perspective (#37784).
- The summarized journal row no longer ends in `· Ctrl-N`, and an empty composer line no longer prints the voice key hint; the footer and the chat help table carry those keys (#37786).
- Checkpoint purge recovery of a structurally broken checkpoint no longer leaves the Librarian stopped. The recovery drops the history from the break on and moved the Librarian's read position to the new end, which is inside a turn when the break is, so no turn-boundary line stated it and every later pass stopped with "read position has no matching turn boundary". With a Librarian position in the trace, the recovery now ends the history at the last turn end a boundary line the position has counted states, and is refused when there is none. The durable consumer and the purge answer "does a line state this position" with one lookup, `Keeper_turn_boundaries.witness_line` (#37772).
- `masc-checkpoint-purge` reads and moves the Librarian position, boundary log and continuity snapshot of the keeper named by `--keeper`, instead of a directory named after the checkpoint's `agent_name` that does not exist (#37770).
- While the Librarian writes a working state again from atom 0, one completed turn per round, a request no longer starts at the end of that partial working state and resends everything after it. The working state records where a request starts without it (the Librarian's read position when it fits the history, else the end of the last completed turn), measured again each round, and is not used until its end reaches that point; until then the request starts there with no working state. A working state one or more turns behind the read position is still used, since nothing else carries those turns. An earlier release cannot read a working state saved during such a rewrite: before rolling back, stop the server and remove that keeper's `librarian-continuity.json` (#37795).
- A provider runtime failure that is not a timeout (a repeated generation the lane already moved past, a rate limit, a quota, an auth refusal) is shown as its own code and detail. The status used to label it a catch-all and tell the operator to inspect a typed cause the code already named. The boundary's non-timeout classification is now called `No_timeout_observed`, which is all it ever meant (#37806).
- Setup and the runtime find an official client (Claude Code, Codex, Antigravity) the same way: on `PATH` as the shell does, else where its official installer writes it (`~/.local/bin`, or `CODEX_INSTALL_DIR` for Codex), and a link stays a link. Before, the setup wizard looked in `~/.local/bin` but the runtime spawned the configured name through `PATH` alone, so a terminal that had not picked up the installer's PATH change could select a signed-in Claude Code and then fail its verification with `executable "claude" was not found`; the wizard's list also said "CLI needs installation" for it, and stored the link's versioned target, which a client update removes. `masc runtime-client-path` prints the answer. The masc subcommands the web setup calls (`runtime-codex-models`, `runtime-antigravity-account`, `runtime-antigravity-models`, `runtime-antigravity-context`) resolve their `--cli-path` the same way, so a server started from a shell without `~/.local/bin` on `PATH` no longer answers "not found" there (#37747).
- Keeper: a keeper whose history holds an image no longer loses every turn on a runtime that cannot see one. The Librarian's continuity choice is checked again before each request, and that check was holding a candidate to the checkpoint's bytes while the candidate had been handed a reading of the image in the image's place (RFC-0265 media degrade). With the image inside the atoms the snapshot covers, every request of that candidate was refused with `Covered conversation changed during dispatch`: `pr-updater` answered nothing on 66 dispatches on 2026-09-21 and 30 more the next day, 15 of them after walking its whole lane. The check is now taken from the list each candidate starts from, so it answers whether that list changed in flight, which is what it was written for. Which continuity the turn chose is unchanged, and a covered message that really changes still refuses (#37812).
- An Antigravity keeper request built from a Librarian snapshot is refused instead of sent when the pinned working state fills the byte budget and leaves no atom for this turn to answer. Such a request used to go out as a preamble and a summary with no turn in it. Every other front still allows an empty history (#37835).

### Internal

- `Fusion_config_writer` rewrites one preset's region of `runtime.toml` from typed values and leaves every other byte alone: comments follow the key or entry they sit above, `[[panels]]`/`[[judges]]` entries are recognized by label and route and, failing that, paired in order, so adding a route to an unlabelled group keeps the entry's comments and unknown keys; a preset written without its own table header, or with inline `panels`/`judges` arrays in its body, is refused as `Unaddressable_preset`. CRLF files and files without a final newline come back byte-identical when nothing changed. It is a pure function with no caller yet (#37790, #37805).
- The `SYSTEM INSTRUCTIONS:` / `CURRENT GOAL:` frame that Antigravity input carries, since the CLI has no system prompt slot, lives in one module (`Antigravity_input_frame`) for the keeper turn and the Fusion one-shot turn (#37800).

## [0.35.22] - 2026-09-22

> Before you upgrade: read the three items under **Upgrade notes** — TypeSafe AI settings moved into `runtime.toml` (#37453), the renamed configuration failure reason (#37457), and the removed tool-call `success` field (#37487).

### Upgrade notes

- TypeSafe AI settings now live in `runtime.toml` under `[typesafeai]`; the previous `MASC_TYPESAFEAI_*` environment variables are no longer read. Only `TYPESAFEAI_API_KEY` stays in the environment (#37453).
- Operator-facing failure reasons now separate invalid configuration from provider authorization refusal. Tooling that reads the old `preflight_config_error` reason must read the new reasons instead (#37457).
- Tool-call log rows no longer carry the top-level `success` boolean. Every new row records `wire_outcome` (`unknown` when nothing was observed); tooling that reads `success` should read the typed disposition or `wire_outcome` instead (#37487).

### Added

- DOS graphics sessions now show whether a frame contains visible pixels and support a click action for mouse-driven games (#37402).
- The librarian preserves committed Memory snapshots and completed-run evidence when cancellation arrives after the commit (#37464).
- Runtime details now show every provider-supplied probe limitation, so operators can see what a reachability check does not prove (#37346).
- The runtime lane list now distinguishes declared lanes from one-candidate runtime fallback lanes and hides the latter from the keeper picker (#37475).
- Large JEV requests over HTTP/2 now flush their complete bodies reliably instead of failing with a protocol error (#37500).
- Librarian publishing can review received-work context against its source material and explicitly withhold only the derived publication when revision is needed (#37512).
- Skill reads can include exact JEV applicability advice in the model-visible content, with inspectable advice receipts in the TUI (#37514).
- The Board read view shows comments in a column beside the post on terminals 120 columns or wider, and keeps the stacked layout on narrower screens (#36821).
- With wire capture on, each provider request now records how its message list differs from the previous request, so cache misses can be traced to the change that caused them (#36961).
- The Lanes screen can now remove an exact-lane slot and move it up or down, not only append one; slots the catalog rejected are kept in the file (#37482).

### Changed

- A checkpoint purge now removes the keeper's continuity snapshot along with moving the Librarian position, since the rewrite leaves the snapshot in the old atom numbering; the purge result and the CLI say whether one was removed (#37755).
- A keeper request with no Librarian snapshot that fits the current history starts at the Librarian's read position when that position is a place in the history, and otherwise, with no seed, at the end of the last completed turn, instead of carrying the whole history; official-client lanes without a seed start at that boundary too. The Memory screen and dashboard show the position-only case as `absorbed`. The turn-record and forecast origin `whole_history` is replaced by `turn_start` with its `end_atom`, and the Memory screen's continuity input `uncompressed` by `without_snapshot` (#37734, #37745).
- The TUI chat header labels a model the stream named without a runtime id as `model:`, and only an announced runtime id as `turn:`; a model name is no longer shown as the runtime.
- In the TUI's `metadata:full` view, a keeper's replies, reasoning, tool calls and skills from one request share one title line instead of one per block. Inside a turn the clock line is drawn only when the minute changes, and a keeper's own chat no longer repeats its name in the title; the inline and bare views are unchanged (#37754).
- The next-request band names the wake line in the same estimated tokens as its other figures instead of bytes.
- The Context pane's title says how long ago its reading was received; the pane refreshes only by hand, so a reading from before the current turn is no longer indistinguishable from a current one.
- The Librarian absorb gate no longer applies absorptions unjudged when it is switched on but cannot ask the judgment model (`[typesafeai] enabled = false`, or no armed destination): the sources stay current and the new claims still apply. A gate switched off, or an excluded Keeper, applies the answer as before. Typesafeai gate unavailability now names the declared switch or exclusion before the lane's own state.
- In the TUI, a queued line sent again, `/run-next`, and Enter before the Keeper's chat control token arrives now only ask for first place in the queue; they no longer cancel the Keeper's running autonomous turn. Stopping a turn stays an explicit act (Esc, `/steer`).
- A provider response with no text, thinking, or tool call is now settled as an observed response instead of being retried as an unseen server failure (#37206).
- Gateway readers now document and consistently treat cancellation as an intentional shutdown rather than a connection failure (#37481).
- The owner-child cancellation marker is retained only after both cancellation paths were verified, making the lifecycle evidence match the runtime tree (#37488).
- The release workflow now publishes the matching CHANGELOG section as part of the release page body (#37470).
- OAuth client registrations now read and honor secret expiration, re-registering stale or incomplete confidential clients while preserving public clients (#37496).
- Thirteen seed capability entries that no consumer read were removed from the shipped `config/runtime.toml`. An existing installation's own `runtime.toml` is untouched and needs no edit (#37491).
- History lines written for official-client turns (Codex app server, Antigravity, Claude Code) now carry the turn they belong to, record tool observations, and are appended durably (#37521).
- The librarian now reads official-client turns from those history lines instead of only the turn's final assistant answer (#37527).

### Fixed

- Setup fixture substitutions now fail at the exact changed fixture location instead of silently passing and blaming the wrong field (#37434).
- The cancel guard now follows complete handler arm lists and recognizes both exception-arm forms, eliminating false positives from comments and distant cancellation arms (#37495).
- The strict runtime-config check now excludes vendored warning policy from MASC's warning gate without weakening MASC source checks (#37315).
- Raw trace retention now uses the strict TurnRecord format and stops before deleting rows that predate the required response-observed field (#37465).
- A Keeper whose native session is held for recovery now shows the stored reason and recovery ID in its status instead of a generic invalid-configuration error (#37235).
- Keepers waiting for explicit session recovery are no longer counted as automatic retries; the Dashboard and TUI show them separately and fleet health reports them as needing operator action (#37236).
- Remote Keepers now use one resolved workspace for the request boundary, command working directory, and file tools, so the three can no longer disagree (#37325).
- A turn's decision record now states the degraded-retry result exactly as the execution receipt does, instead of inferring it from a runtime change (#37446).

### Internal

- Added regression coverage for DOS click registration, mutation classification, and the no-machine refusal path (#37489).
- Added explicit tests for the TUI's GitHub-token text-input ownership while typing (#37502).
- Removed two unhandled resource-scope callback exceptions and documented the remaining intentional catch points (#37473).
- Split the gateway cancellation guard's measurement fixtures from the runtime behavior so the guard reports its actual arm set (#37476).
- Improved release smoke diagnostics to report whether a timed-out boot process was still alive or had already crashed (#37509).
- Added tests for model identifier properties and catalog lookup (#37026).
- Edited-test selection now fails when it cannot select a suite, instead of passing silently (#37507).
- The TUI calls-table test now counts the recorded tool output rather than its digest (#37539).

## [0.35.21] - 2026-09-21

### Upgrade notes

- Keeper: stop the server, delete `<base-path>/.masc/keepers/*/turn-records`, then install. A deployment with `MASC_CLUSTER_NAME` set to anything but `default` keeps its records under `<base-path>/.masc/clusters/<cluster>/keepers/*/turn-records` instead (`Workspace_utils.masc_root_dir_from`), and `masc-check-runtime-deployment-preflight` reads the default path only, so it does not catch what was left in a named cluster. A turn record's window now carries `front_atom_digest`, and the decoder requires that key on every record, so no record an earlier release wrote decodes; the old server writes a record every turn, so delete the folders only once it has stopped. `scripts/deploy.sh` stops the old server before its deployment preflight runs and then refuses to install when a row does not decode, so a missed reset leaves no server running; the `Dockerfile` image's entrypoint runs the same preflight and does not start the server. The release installer installs that preflight as `masc-check-runtime-deployment-preflight` but does not run it, and the `Dockerfile.oneclick` image starts the server without it: with either, run `masc-check-runtime-deployment-preflight --base-path <base-path>` before starting the new server, which does not refuse old records at boot — it skips them when it seeds a keeper's first request, and the raw-trace retention sweep stops at the first one with only a warning. The dashboard's turn history, the raw traces nothing references any more (the first retention sweep collects them) and each keeper's first-turn seed go with the records, so each keeper's first turn after the upgrade sends its whole history. An Antigravity keeper is the exception: `Keeper_antigravity_runtime.capacity_bounded_model_input_projection` runs on every request that is not a resume, so its first fresh request is cut to the `max-prompt-bytes` that release now requires. Rolling back to an older binary needs the same reset, because the older decoder refuses the new key as unknown; there is no compatibility reader or strip script (#36955).
- Keeper: a keeper whose checkpoint file exists but cannot be read stops turning. Each turn ends with the read error, which names the file, before a prompt is built or a model called; it used to start from an empty history and write it over the file at its first save. A missing checkpoint and an explicit version cut still start fresh. The deploy preflight does not read checkpoints, and there is no repair command yet: restore the file from a copy while the server is stopped, or remove the keeper (#37089).
- Runtime: a model binding refuses keys it does not read. A key under `[<provider>.<model>]` outside the binding keys — a misspelling such as `context-high-water-token`, a line nothing reads such as `max-request-body-bytes`, or a nested table — is a load error at that path, and the message lists the keys a binding takes. A non-table value directly under a provider table is refused the same way. These keys were dropped without a word before, so deleting the line changes nothing that ran (#36906).
- Runtime: a keeper runs only on the runtimes its lane names. `[runtime].default` is no longer appended to every lane, and an assignment that names a runtime no lane declares walks that runtime alone; `[runtime].default` only names the runtime of a keeper with no assignment (#37064). An image turn picks among the lane's own candidates, and when none of them takes images the turn runs on the lane with the image described in text; `[runtime].media_failover` is only the list `keeper_analyze_image` and the image describer read (#37066). A direct message turn that ends with no progress is no longer run again on every tool-capable runtime in the catalog once its lane is walked (#37069). A keeper that should fail over to another runtime needs a `[runtime.lanes]` entry listing it. What only that rotation filled goes with it: `masc_keeper_runtime_rotation_total`, the `source="fallback"` series of `masc_keeper_runtime_selected_total`, the "Fallback Reasons" and "Runtime Rotations / min" Grafana panels, the receipt's `rotation_attempts`, and the `keeper.is_retry` span attribute (#37081, #37082).
- Config: move into `runtime.toml` what `<base-path>/.masc/config/agent-core-models-overlay.toml` says that the embedded catalog does not, then delete the file. Nothing loads it — neither the model catalog nor the exact-output resolver — and no boot error names it, because no reader is left to raise one; a copy left in the config root sits there looking live. The embedded catalog now carries the rows deployments kept in their overlays, including `glm-coding` `glm-5.3` and `glm-5.3-flash`, `ollama_cloud` `glm-5.3-flash`, `deepseek-v4.1-flash` and `kimi-k3`, and the `kimi_coding` provider with `k3` and `kimi-for-coding`. For anything else: the API key variable an overlay provider named in `api_key_env` goes in the provider's `[providers.<id>.credentials]` table as `type = "env"` and `key = "<VARIABLE>"`; an endpoint the catalog has no provider row for names its dialect with `kind` on its `[providers.<id>]` table — a `messages-http` provider without one is refused, and an `openai-compatible-http` one without one is spoken to as plain OpenAI-compatible; a model the catalog does not carry is declared with a `[models.<id>.capabilities]` table, and without one its binding is dropped at boot, or the server refuses to start when `[runtime].default`, an assignment, a lane or `media_failover` names it. A custom request path an overlay provider set has no `runtime.toml` key (#37016, #37009, #37013).
- Setup: HTTP connections an older install wizard wrote no longer load, because their model facts lived in the overlay and their bindings have no `[models.<id>.capabilities]` table; they are dropped at boot, or stop the server when a route names them. Delete their `setup_*` provider, model and binding entries from `runtime.toml` and run the wizard again, which writes the table. Delete them first: a connection's id now comes from the parsed answers rather than the JSON that carried them, so the same answers produce a different `setup_*` id, and the wizard appends the new id beside the old entry (#37016).
- Exact output: a lane slot is a `runtime.toml` binding id (`<provider>.<model>`) resolved against the AGENT_CORE catalog, and the slot takes the rest from that binding too: the provider's `connect-timeout-s` is its connection and response-header deadline and the provider's optional `exact-body-timeout-s` bounds the whole request below, the key it sends is the environment variable the provider names in `credentials`, which must be `type = "env"` because `server_runtime_bootstrap.ml` maps a `file` or `inline` credential to an empty variable name and `exact_output_resolver.ml` reads that as needing no credential, so those slots send no authorization header while the ordinary runtime still works, and thinking is on when the model's `thinking-support` is true. A slot whose provider declares no `connect-timeout-s` is refused at plan admission as `missing_deadline` before any request goes out, so set `connect-timeout-s` on every provider an exact-output lane names. A slot whose binding the catalog does not resolve is ignored with a WARN at boot, a subscription CLI runtime is not a slot (name it in `cli_slots`), and when `hitl_auto_judge` or `board_attention_exact` is left with no slot and no `cli_slots` the server refuses to start. The 0.35.20 overlay turned thinking off for its DeepSeek V4 Flash targets, noting that with thinking on the answer arrived in the thinking field with empty content; the seed `runtime.toml` declares `thinking-support = true` for those models, and exact output with thinking on has not been measured again (#36984, #37009, #37016).
- Exact output: `[runtime.exact_output_lanes.verifier_exact].slots` takes runtime ids only. A lane name there is a load error naming the entry; it used to load and then fail every judgement, because verification dispatches the slot id itself (#37075).
- Sandbox: a microVM guest resolves memory and CPU independently. `[keeper] microvm_memory` and `microvm_cpus` win per dimension, followed by the process's `MASC_KEEPER_MICROVM_MEMORY` and `MASC_KEEPER_MICROVM_CPUS`, the workspace `[sandbox] microvm_memory` and `microvm_cpus` in `runtime.toml`, and finally `2g` and `4`. Before this release, a guest without an explicit microVM memory value took `MASC_KEEPER_SANDBOX_MEMORY`, the Docker lane's cap, and an unset CPU count passed no `--cpus`; it now uses those microVM defaults. A running guest of a different size is replaced the next time the keeper's sandbox starts. The memory value takes a unit, `<n>m` or `<n>g` (`512m`, `8g`); a bare number, which the container runtimes read as bytes, is refused, and a value that does not parse stops the guest from starting with the setting named, where it used to be handed to the runtime as written (#36973).
- TypeSafe AI: the lane's settings move from the environment into the `[typesafeai]` table of `runtime.toml` — `enabled`, `endpoint`, `model`, `board_attention`, `absorb_gate`, and `excluded_keepers` (keepers neither gate ever asks the vendor about; a name that is no keeper is reported at boot). `MASC_TYPESAFEAI_ENABLED`, `MASC_TYPESAFEAI_ENDPOINT`, `MASC_TYPESAFEAI_MODEL`, `MASC_TYPESAFEAI_BOARD_ATTENTION_ENABLED` and `MASC_TYPESAFEAI_ABSORB_GATE_ENABLED` are no longer read; only `TYPESAFEAI_API_KEY` stays in the environment. A deployment that set any of them writes the table instead. A misspelt key in the table is a load error.
- TypeSafe AI: `[typesafeai]` names its servers in `destinations`, an ordered array of `{ endpoint, model, api_key_env }`. The `endpoint` and `model` keys are gone and are a load error (`unknown [typesafeai] key`); a deployment that set either writes one destination instead, and a table without `destinations` still means TypeSafe's own server with `TYPESAFEAI_API_KEY`. Each destination reads its key from the variable it names, and one whose variable is empty is left out. A request moves to the next destination whenever one does not answer or refuses, whatever the refusal says, because each destination is asked for its own model id and keeps its own limits; a destination left out for lack of a key is reported at boot. OpenRouter's `https://openrouter.ai/api/v1/systemone` with model `~typesafe/jev-latest` and `api_key_env = "OPENROUTER_API_KEY"` works as a second destination. The `missing_api_key` skip reason is now `no_armed_destination`; the standalone-lane Jev readiness JSON carries `destinations` (a list of `{destination_uri, model}`, in walk order) instead of `model`; the absorb gate and context review records list `request.destinations` instead of `request.endpoint` and `request.model`, and a failed evaluation's `failure` is `{kind: "every_destination_refused", attempts: [...]}`. There is no reader for the old shapes.
- Board attention: set `[typesafeai] enabled = false` if the server's environment carries `TYPESAFEAI_API_KEY` and Board posts should not leave the machine. A non-blank key alone turns on a first pass that, when the `board_attention_exact` lane has an HTTP slot, sends the Board post and the keeper's context to TypeSafe AI's Jev (`https://api.typesafe.ai/v1/systemone`, overridable with `[typesafeai] endpoint`). Without the key nothing changes (#36970).
- Keeper: the turn-record reset above also covers a second required key. A record now carries `response_observed_model_input`, the runtime paired with the exact window that received a typed provider response, and the decoder requires the key on every record, `null` where a turn received none. A record an earlier release wrote is refused rather than read as though its latest attempted window had been accepted, so the same folders go; rolling back needs the same reset, because the older decoder refuses the key as unknown (#37245).
- Librarian: the turn-boundary and read-position files move under the selected cluster. `<config-root>/keepers/<keeper>.turn-boundaries.jsonl` and `<keeper>.librarian-progress.json` become `<masc-root>/keepers/<keeper>/turn-boundaries.jsonl` and `librarian-progress.json`, where `<config-root>` is what `MASC_CONFIG_DIR` resolves to and `<masc-root>` is `<base-path>/.masc` or `<base-path>/.masc/clusters/<cluster>` when `MASC_CLUSTER_NAME` names one, one pair per cluster where two clusters sharing `MASC_CONFIG_DIR` wrote one. Nothing reads the old flat files — there is no migration, path branch or compatibility reader — so delete them after the upgrade. Each keeper starts with no recorded boundary and no read position, and `masc-librarian-replay` reports a missing store as a failed read instead of replaying zero keepers (#37181).
- Memory: a `cited` row in `<config-root>/keepers/<keeper>.memory-events.jsonl` no longer decodes. `keeper_memory_retract` stored its record as `Cited` and drew it as `Cited N`, which read as a citation; a retraction is now the nullary `Retracted`, JSON `kind: "retracted"`, counted as `retracted_count`, and a row that keeps `kind: "cited"`, or keeps the `tool` payload beside the new kind, is `Malformed (Unknown_token)`. The read continues to the next line and the API lists the row in `events_unreadable_lines`, so each keeper's retraction count drops to what it records from here. There is no compatibility reader. To keep the old rows, stop the server, rewrite their `kind` to `retracted` and drop their `tool` field, then start it: one live workspace held 132 such rows across 14 of its 27 sidecars. A converted copy must not be written over a file a running server is still appending to (#37105).
- Antigravity: every Antigravity model row needs `max-prompt-bytes`. A binding whose model does not declare it is refused as `InvalidConfig(max_prompt_bytes)` instead of sending whatever the history has grown to, so add each row's measured ceiling to `runtime.toml` before installing; an existing install's rows are left as they are, and the seed declares 2,078,915 bytes for its 3.7 model, the largest prompt agy 1.2.6 was measured to carry end to end. This narrows the ceiling removal above (#37007): a fresh session's history is cut to the newest atoms that fit, on atom boundaries and keeping a tool call with its result, and the rendered prompt is checked against the declared count again just before dispatch. Three long-running keepers had been failing every first turn with `no renderable messages: all steps in trajectory are cleared` at 21.9-48.5 MB (#37224).
- Exact output: `[runtime.exact_output_lanes.verifier_exact].cli_slots` is checked at load, as `slots` already is. An entry that is not a declared runtime id is dropped with a warning naming it, and the lane keeps the slots that can judge; it used to load every entry and then end every review with `Evaluator_unavailable`, because the check ran only at judgement time (#37167). Refusing the whole load was tried first and reverted: installs from v0.35.15 to v0.35.20 wrote exactly such a slot for Codex and Antigravity users, so the refusal left those configurations unopenable with no way to fix them from inside MASC (#37374).
- Runtime: `supports-tool-choice` under `[<provider>.<model>]` no longer overrides the catalog. It collapsed three separate capabilities into one flag — whether the model takes `tool_choice` at all, whether it takes `required`, and whether it takes a named tool — so an operator who met a 400 on `required` and wrote `false` also lost `auto`. A model the catalog carries takes all three from the catalog; a model it does not carry still declares them separately in `[models.<id>.capabilities]`. Two live bindings had been differing from the catalog this way, `deepseek.deepseek-v4-flash` and `glm-coding.glm-5-3`. A `supports-tool-choice` line under the binding is now a load error, because the strict binding check above (#36906) takes it as a key no binding reads; the field that still loads and is now ignored is the one in `[models.<id>.capabilities]`, as the other `supports-*` fields on a catalogued model already were, and the dashboard's tool-choice-override row and its `tool-override:` chip go with the field the server stopped sending (#37044, #37016).
- Board: with the server stopped, look for `board_posts.jsonl.1` and `board_comments.jsonl.1` under the selected cluster's root — `<base-path>/.masc`, or `<base-path>/.masc/clusters/<cluster>` when `MASC_CLUSTER_NAME` names one, which is what `Board_paths.board_masc_dir` resolves. Do not move either file over the one beside it: each can hold rows the other does not. `.1` is the whole snapshot as it stood at the rename, and the file beside it was started by the next single-row append (`Board_core_persist.append_post`), so it carries rows written after that. Merge them by post or comment id and keep one copy of each. A row that appears only in `.1` may have been dropped on purpose: the whole rewrite (`Board_core_persist.rewrite_posts`) removes an orphan row an aborted append left on disk, so check such a row against the board before restoring it. `board_posts.jsonl` is the single snapshot of the whole board and is written whole, but an append also renamed it to `.1` once it passed 10 MiB, and the loader reads only the unsuffixed name, so a restart between that rename and the next whole write read an empty board. The rename is gone, and with it `rotate_if_needed` and `max_jsonl_bytes`; a `.1` an earlier release left is not merged back, and nothing will write one again. On 2026-09-19 a restart ten seconds after such a rename emptied the listing of 4,042 posts, and 225 votes left the vote log for good (#37163).
- Rollback: going back to 0.35.20 needs the turn-record reset above, and 0.35.20 also refuses a keeper TOML that sets the new `microvm_memory` or `microvm_cpus` keys and cannot decode a Board attention judgement Jev answered (`vendor_system_one`) (#36973, #36970).
- Librarian: the dashboard's checkpoint purge can stall a keeper's Librarian for good. The purge compares only the checkpoint's final `(end_atom, last_atom_digest)`, so a rewrite that changes an earlier atom the persisted Librarian progress points at is applied anyway, and every later read then refuses that progress with a position mismatch and only warns. Nothing re-bases or resets it. Until #37361 is fixed, stop a keeper's Librarian from being purged rather than recovering it afterwards (#37208, #37361).

### Known issues

- Release verification: this release was tagged with the release candidate's `behavior / test suite` job red. What was verified still holds: the candidate's installation jobs passed on all four platforms, and both Linux jobs printed a passing `masc.first_keeper_turn.v1` receipt, so installing this release and taking a first Keeper turn are covered. The behavior suite is not covered. It has failed on all four candidate runs since 2026-09-17, and the visible failure is a harness one rather than a named test -- two PTY suites print their passing line and the harness then raises `BrokenPipeError`, so the runner cannot say which test failed and prints no failure header. Whether anything else fails behind it is unknown: the handler-cleanup fix that was expected to cure this landed before the last two runs and they failed the same way. No user-facing defect has been traced to this, and none is claimed to be absent either: the suite did not report. Follow #37461 for the investigation; a later release will state whether anything user-facing was behind it.

### Added

- Keeper: an official client's start seed begins where the Librarian read, like the Agent Core lane's does. Claude Code and Antigravity carry the saved working state in place of the atoms it summarises, and their `model input carried range` line reports `origin=librarian_snapshot`; when no working state fits but the Librarian's read position does, they start there with nothing carried for the atoms before it (`origin=librarian_progress`). The official-client lanes take the same continuity choice the Agent Core lane makes each turn rather than reading the snapshot a second time. The Librarian's position is used when it is at or past the range the last completed turn carried, or the lane's own cut when no such range holds, so the range never moves back behind either; with neither, the range starts at the end of the last completed turn as before, and it always carries the newest atom, so a history the Librarian read to the end arrives with the turn it has to answer beside the summary. The request can still grow by the working state, which no cut may drop; a declared window it does not fit refuses the request, as for any pinned message. A list the turn's choice no longer describes refuses the request on these lanes as it does on the Agent Core lane, instead of going out from the seed. The Memory screen's prepared-input reading (dashboard and TUI) now records these lanes' requests too, in the same words as Agent Core's: `summarized`, `absorbed`, `without_snapshot`, or `not_applied` when the seed or the lane's own cut sat past the Librarian's point; before, it only ever showed the last Agent Core request.
- Keeper: every line under a trace's `history.jsonl` and `history.internal.jsonl` names the turn that wrote it (`turn_ref`) and its `kind` (`message` or `tool_observation`). An official-client turn also leaves one `tool_observation` line per tool call it made — the canonical tool name and the outcome, no arguments and no result body — in `history.internal.jsonl`, before its turn-boundary line. Appends hold the same locks and fsync as the turn-boundary log, so an append a crash cut short is truncated by the next one instead of leaving a torn row. A line that cannot be written is logged and counted (`masc_keeper_history_fragment_failures_total{keeper,site}`) and the turn goes on. Lines written before this change carry no `turn_ref`; a reader that selects by turn identity does not see them.
- Librarian: official-client turns are read from disk like Agent-Core turns. An end line whose position is `No_atom_history` names a turn whose words are the `turn_ref`-tagged lines of its trace's `history.jsonl` and `history.internal.jsonl`; a pass hands the Librarian those fragments and the atoms of Agent-Core turns in the order their end lines were appended, and commits them together. The position among official turns is a line of the turn-boundary log, kept in `<keepers_dir>/<keeper>/librarian-official-progress.json` beside the atom position and removed with it by a purge. A turn of either kind now only wakes the durable consumer after its end line; the turn-end closure that carried an official-client turn's reply in memory is gone. Lines written before turn-named history are passed without a model call; a refused history line after the first named one stops that keeper's pass with `Fragment_line_unreadable` and is never skipped. A refused turn-boundary line beyond the official position stops the pass too (`Official_range_stopped`), for every keeper, and stays stopped until a purge: the line may be an official turn's end line, whose words are still on disk, so no later restart lifts it the way one lifts the atom stop.
- Runtime: `POST /api/v1/runtime/config/routing` takes an `action`. `set`, the default, writes the candidates of an existing lane or runtime and still refuses an unknown name. `create` makes a new lane and refuses a name that is already a lane, a declared runtime id, or a route name it reads as one (`default`, `media_failover`, a declared `exact/...`). An `exact/` name it cannot read is not refused: it becomes a lane under that literal name, which `set` and `remove` then cannot address because they read the prefix as a route, so it has to be removed from the file by hand (#37417). `remove` deletes a declared lane and refuses, naming each one, while a `[runtime.assignments]` keeper or `[runtime].default` still routes to it; a lane written as an inline table is refused. All three take the same lock, whole-file validation, atomic write and audit record (#37075).
- TUI: the Runtime Lanes screen edits lanes. `a` names a new lane and creates it with the first runtime picked, `x` removes the candidate under the cursor, `J` and `K` move it down and up, and `D` twice removes the lane. The server's refusal is drawn as it was sent on a `lane write refused:` row, and while a write and its reload are outstanding the writing keys send nothing and say why (#37085).
- Keeper: a microVM guest's size can be set per keeper with `[keeper] microvm_memory` and `microvm_cpus` in the keeper TOML, and per workspace with `[sandbox] microvm_memory` and `microvm_cpus` in `runtime.toml`; the two axes resolve separately. The boot argv and the sandbox status on the dashboard and TUI read the same resolved size, and `--cpus` is always passed. A running guest booted with a different image or size is replaced the next time the keeper's sandbox starts, and the log names what differed, so a `sandbox_image` change no longer waits for a server restart (#36973).
- Memory: when a Librarian claim absorbs current facts, their text is kept. The answer names them in `absorbs` (an empty array when none), an answer that names an unknown id, an id also in `dropped` or an id twice is refused whole, and the absorbed facts leave the snapshot only after a row `{recorded_at, trace_id, memory_id, into, fact}` is written to `<keeper>.memory-absorbed.jsonl`; a failed write fails the commit (#36937). `keeper_memory_search` reads that file with `source=absorbed`, and `source=all` reads it after the current facts and before the conversation history. A result carries `into` and `into_current`, and lines it cannot read are listed in `absorbed_unreadable_lines` (#36948).
- Keeper: `<masc-root>/keepers/<keeper>/turn-boundaries.jsonl` records where each finished turn left the durable history (`turn_ended`, with the atom count and the digest of the last atom), and a `history_restarted` line after `masc_keeper_clear`, at the start of a turn on an empty history, and after the first accepted save of a turn that started fresh because its saved checkpoint version was superseded. A Librarian wake reads it together with `librarian-progress.json` (`Keeper_librarian_durable_consumer`), and `masc-librarian-replay` reads it too, so removing or repairing it by hand can leave retained progress pointing at a boundary that is gone and stop durable memory consumption. It is append-only, never trimmed, and removed with a keeper purge. A line that cannot be written never fails the turn or the clear; it is logged at ERROR and counted in `masc_keeper_turn_boundary_failures_total` (#37020, #37024, #37027, #37030).
- Board attention: with `TYPESAFEAI_API_KEY` set, TypeSafe AI's Jev answers first. A `relevant` answer is kept without an LLM call, and `not_relevant`, a failed call or an answer that does not decode goes to the existing LLM lane, including its declared CLI fallbacks after the HTTP slots are exhausted. The flow's terminal log entry is written after that lane finishes and carries a `jev` object saying what Jev answered and, after `not_relevant`, what the HTTP or CLI fallback decided (#36970, #37180).
- TUI: `Enter` on a Memory fact opens the whole claim across the terminal; `j`/`k`, `PgUp`/`PgDn` and `g`/`G` move through it, `Esc` returns to the list, and the `?` sheet lists both screens' keys (#36960, #36983).
- TUI: Mermaid `stateDiagram` and `stateDiagram-v2` render — direction, `[*]` start and end states, labelled transitions, and state descriptions and aliases — where they were refused as unsupported; styling statements and notes are skipped (#36964).
- TUI: a turn block's head carries its span, `16:38→` while it runs and `16:38→16:41` once settled, wrapped inside the block's width so the gutter does not widen (#37011).
- TUI: a Goal waiting in `Awaiting_confirmation` can be confirmed from the Planning detail. The first `a` reads the proven evidence from `GET /api/v1/goals/confirmation` and shows it; the second sends that exact criterion, request and verifier run to `POST /api/v1/goals/confirmation`, and a proof that changed in between is refused. While the confirmation is being sent further presses send nothing, and a reply that arrives after cancelling or moving to another Goal does not arm it again. Before this the TUI had no way to send the human's final confirmation, so a proven Goal stopped there (#37076).
- Runtime: a provider declares `exact-body-timeout-s`, a positive finite number of seconds bounding a whole exact-output HTTP request — connection, headers and the complete body — where `connect-timeout-s` keeps its connection and response-header meaning. Omitting it leaves the target with no body deadline, as before. Each visited candidate carries its own, so HTTP waits add up across a lane's candidates; it is not a budget for a whole Librarian pass, its callbacks, its CLI tail or Memory processing. The server reads the value when bootstrap rebuilds the exact targets, saving the file does not replace an existing target, and the dashboard draws it beside the connection timeout (#37203).
- Keeper: `keeper_skill_validate` takes an `artifact` and a `package_id`, fetches that exported artifact and runs the editor's own Instruction/Composition parser and 1 MiB authoring limit over it, answering with the artifact and package it verified or the exact rejection. A keeper could export a proposed SKILL.md but had nothing to check it with before an administrator published it, which stays on the CanAdmin editor path; the tool publishes nothing, changes no source or snapshot, runs no composition and certifies no safety (#37317).
- Memory: an absorbed result carries the `basis` its original fact was stored with, under `source=absorbed` and `source=all`, so a fact absorbed from a Board post or comment keeps the source id that supported it. The stored format is unchanged and a new claim does not inherit its material's basis (#37303).
- Runtime: `POST /api/v1/runtime/config/routing` takes `append`, which reads the declared slots of an `exact/<name>` lane under the write lock and adds one to the end, refusing an id already declared. The TUI's exact-lane picker sends that one slot instead of the list it drew: the screen shows only the slots the registry admitted, so sending the drawn list back deleted every declared slot the registry had dropped, one per append (#37167).
- TUI: `stateDiagram` renders composite states — `state Parent { ... }`, a `direction` inside the block, and a block that opens on a state already named — and the `<<choice>>`, `<<fork>>` and `<<join>>` pseudo-states, with `[*]` scoped to its own composite. A composite that would end up inside itself is refused (#36965). Node shapes are drawn apart: `[[subroutine]]` in double lines, `[(database)]` as a cylinder, `([stadium])` and `((circle))` rounded, `{diamond}` as before (#36967).
- Bench: a binding declares `disable-parallel-tool-use` under `[<provider>.<model>]`, which reaches Anthropic's `tool_choice.disable_parallel_tool_use` or OpenAI's `parallel_tool_calls = false`. Terminal-Bench arms b, c and d had turned parallel calls off by editing a model capability, which left the catalogued runtime's capability in place and sent no suppression field at all. Omitted or false keeps the previous behaviour, and a provider whose catalog row does not declare `supports_parallel_tool_suppression` — everything but native `claude` and `openai-responses` — refuses the key rather than sending a request it cannot honour (#37090).
- Librarian: absorbing several memories into one claim keeps a source sentence the claim does not carry. Each source sentence is judged by TypeSafe AI's Noul, and one sentence below 0.5 excludes that source from the absorption while the new claim and the other changes still apply. With no key, with the check disabled, or on an HTTP or response error, the absorption list applies as before. The design is in `docs/rfc/RFC-librarian-absorb-gate.md` (#37369).
- Memory: `keeper_memory_search` called without `source` reads the absorbed sources as well as the current memory, where it used to read the current memory alone; `source = "all"` adds the conversation on top. A keeper asking about something it once knew could get "nothing" back after the Librarian folded that memory into a claim. Measured on this workspace on 2026-09-21 over 945 calls: 755 empty results became 669 (#37360).
- Librarian: typed input and result documents for continuity measurement, with question and answer preparation, per-step failure and the Noul observation each kept as their own state. No threshold, gate or coverage figure is added, and this carries no CLI or TUI entry point of its own (#37393).
- Librarian: a measurement path records how answers hold up against explicit synthetic context snapshots. Each case asks a fixed question or one generated from its reference and answers from only the question, the facts and the unread text; TypeSafe Noul records the probability of the stated answer. Six cases ship, covering retained and absent controls, paraphrased and partial rules, unread-only evidence and generated questions. No threshold or coverage percentage is inferred (#37401).
- TUI: `/measurement <SHA256>` opens a saved Librarian continuity measurement report. It checks the artifact's identity, byte count and content hash before drawing, and says which of those failed when one does; the detail frame shows scored, failed and incomplete counts with a bounded preview of probabilities, questions, answers, response models and failed stages. The 64 KiB preview states when it truncates and names the complete report file. No probability threshold or Librarian verdict is added (#37397).

### Changed

- Keeper: the carried-range ledger measures only requests that carry no turn context. A turn's first request carries recall, the briefing and the time outside any atom, so it is recorded as unmeasured and the next request measures those atoms; the ledger JSON says which with `turn_context`. The high-water mark is checked once per candidate per turn, at its start, instead of after every response, so a keeper near its mark no longer empties the history it has just measured and sends the next request of the same turn without cache (#36903).
- Keeper: the tool array is the same before and after a turn that loads a tool. A tool loaded through `keeper_tool_search` is placed where the next turn's bundle places it, after `keeper_tool_search` in entry order, instead of at the end, and the tool search description lists every name, loaded or not, so it no longer changes when a tool is loaded (#36944).
- Keeper: a chat task whose last candidate ran a tool and saved the result to the checkpoint continues on that same path after a transient failure — 429, overload, 5xx, a dropped connection, a timeout, or a quota with a stated reset — from the latest checkpoint, so tools already run are not run again. It waits for a recorded rest where there is one. Heartbeat work is not continued (#36971). A generation the provider cut off — a choice that ends with `finish_reason: "error"` and no error object, or a stream that ends without a stop reason — is `Provider_interrupted` and continues the same way; a malformed, unknown or oversized stream event stays terminal (#36975).
- Keeper: max-tokens truncation recovery asks the candidate's request admission whether thinking can be turned off before retrying without it. Where it cannot, as on Grok, Kimi k3 and k2.7-code, GLM-5.3 or an effort ladder with no `none`, the rejected response is dropped instead and the manifest's `thinking` reads `cannot_be_disabled` (#36985).
- Keeper: `masc_keeper_clear` runs in the Keeper Owner's exclusive maintenance slot, so a running turn can no longer save the old history over a clear; while a turn runs the clear is refused without interrupting it. A save that turned out stale, a failed save and an unreadable keeper meta are errors that say whether the disk changed, where they reported "cleared N" before, and the dashboard shows them as an error (#37024, #37096).
- Catalog: the `openrouter` provider declares the effort ladder OpenRouter accepts for every model it routes, without `none`, and its model rows inherit it (#36991). The `ollama_cloud` DeepSeek rows and `kimi-k2.6` replay reasoning only for the tool-call bundle of the current user turn, not every past turn's thinking (#36981, #36969).
- Antigravity: the lane hands over the whole history instead of cutting it to `max-prompt-bytes`, and reports the window as whole, because agy 1.2.6 passed a 2,078,915-byte prompt through intact (#37007). The same release puts a ceiling back: an Antigravity model row must declare `max-prompt-bytes`, and a fresh session's history is cut to fit it, so read the upgrade note for #37224 with this. The answer is shown as the model writes it: the `text_delta` of each `step_update` is drawn instead of the whole response at the end (#37002).
- Verification: the judge sees the submission's evidence posture and whether an evidence lookup succeeded, with the lookup result. The guard that replaced the judge's verdict with none after a note-only submission is gone, so a verdict is no longer turned into a slot failover (#36954).
- Setup: the seed `runtime.toml` drops `glm-coding.glm-4-7-coding` and `glm-coding.glm-5-turbo`, retired names the Z.AI coding endpoint answers with another model, and three unreferenced duplicate `ollama_cloud` bindings, and adds `ollama_cloud.ollama-cloud-deepseek-v4-1-flash` (#37005). Its `glm-coding` provider declares `connect-timeout-s = 1200.0` (#36984), and its `glm-coding.glm-5-3` binding declares `context-high-water-tokens = 100000`, `context-low-water-tokens = 70000` and `max-concurrent = 4` (#37083).
- Keeper: an official client opens a new session from where the last finished turn started, not from the oldest atom. Antigravity and Claude Code read the same seed the turn's Agent Core candidates read, check that the current history opens that position with the same message, and project from that atom; a seed the history does not open is dropped and the whole history goes, as on the first turn after a boot. A front a refusal moved in this turn wins over the seed, and Claude Code's declared `max-prompt-bytes` cut wins where it cuts deeper. On 2026-09-18 `msx-retro-mania` handed over 11,447 atoms (45 MB) on every start while a kimi candidate in the same turn sent 7; every start above 13.3 MB failed and every start at or below 11.9 MB ran. Antigravity's front only advances when a new response observation moves it, so a history that keeps growing can fail repeatedly from the same front (#37271).
- Keeper: a refusal narrows only the candidate that was refused. The process-wide model-input ledger took the narrowed range, so the next warm turn inherited a range that had never received a response; only a response observation moves the shared range now, and a new turn starts from that runtime's last observed one. The global `Table.move_front` entry point is gone (#37242). Inside a turn the front a refusal moved is carried to the next candidate even when that candidate has a usage ledger of its own, and the later of the two positions is used; a position the current history no longer opens is dropped with a WARN naming the reason and the seed (#37073).
- Keeper: the NEXT REQUEST forecast applies the turn-boundary policy before it reports. It drew the observed ledger front even where the next turn's high and low water marks would move it — for a ledger with front 0, total 1300 and marks 1200/600 it said front 0 where the turn starts at atom 8. The measured last count and the ledger itself are unchanged, and the forecast writes no front back (#37243).
- Keeper: a turn that froze an unfinished suffix and asked to continue on a deferred lane runs on the next cycle. The heartbeat only skipped its sleep, and an empty event queue then decided not to run a turn, so the suffix could wait the normal cadence after the log said it would continue without waiting; samples taken after a restart ran from 4 to 603 seconds. A periodic boundary that falls due in the same cycle is consumed there instead of drifting, and the lifecycle, pause, stop, intake-error and path-rest gates are unchanged (#37274).
- Runtime: a model whose row says `supports_native_streaming = false` is dispatched as sync JSON even when the keeper installs its progress observer, which used to select SSE and end an ordinary JSON response as `sse/incomplete_stream`. Those turns have no live SSE preview and no SSE progress events, and no synthetic events are emitted; tool and lifecycle observation over the event bus is unchanged, and a streaming-capable model keeps SSE and its answer deltas (#37323).
- Memory: `keeper_memory_search` answers a query whose words sit apart in a claim. Results holding the whole query as one run come first, then results holding every ASCII-space-separated piece of it somewhere, and `limit` applies once to that whole order. This is substring matching, not word matching: `cat task-1` matches `concatenate task-10`, and `alpha, tuesday` splits on the space so its first piece carries the comma (#37270).
- Librarian: the prompt asks a claim that absorbs several facts to carry what its material said. The output field called every claim one sentence, which applied to a combined claim too, and the prompt told the model the originals could be found again by search — of 1,178 `keeper_memory_search` calls, none had used `source="absorbed"`. A single-fact claim is still one sentence; a combined claim takes as many as its material's conditions, figures and lessons need, and the sentence left in its place says only that the material leaves the current memory. In a replay of operational material, scored two separate ways, a combined claim's median length went from 816 to 1,052 characters; a group of five or more facts still loses much of what they said (#37124).
- Librarian: the current facts it reads carry `origin.kind` and `basis`, so it can see which facts came in through the Board and which premises support a retained fact. Support is shown as lists of the same `mN` ids the input already uses, `null` for a missing premise, and rules sharing a premise list appear once. Stored derivations and support evaluation are unchanged (#37234).
- Dashboard: a chat message opens a turn record only through an exact reference. A fresh message, or an assistant that failed before it got a reference, used to open whatever turn was within thirty minutes of it; an unreferenced message says `턴 연결 정보 없음` and the list stays open for a manual pick (#37260).
- Dashboard: a turn's token figure is read with its scope. A count the writer marked cumulative or of unknown scope was divided by the context limit and priced as one request — a writer's 18,000 cumulative tokens drew `13.7%` and `$0.003` — and both now read `미상` beside the named scope, with the original count and context limit kept. Per-request counts are calculated as before, in the Turn Inspector and the Memory Inspector (#37264).
- Task: an activity event follows the status the task committed. A cancellation request left the task in `AwaitingVerification` while activity announced `task.cancelled`, and the operator's approval of that cancellation then emitted `task.approved`, which moved the graph to `Done`; a request is now `Submit_for_verification`, a settled cancellation `Cancelled`, and an approved completion stays `Approved`. The graph's works_on edge and the task span read the event's `producer`, the agent that did the work, where they looked for an `assignee` the event does not carry (#37134).
- Bench: a Terminal-Bench dist is admitted from one manifest. A refresh that failed or was interrupted could leave a newer `.version` marker beside mixed or unverified binaries; downloads are staged, each runnable binary's embedded build commit is verified, and one manifest is published last and owns the release version, source commit, platform and binary hashes. `.version` is no longer read as a second authority, and a missing or unknown manifest field, an unsupported architecture, a digest that drifted or a release below the bootstrap floor fails closed. A trial's receipt records the source commit and the digest of the binary it selected (#37314).
- Bench: a task's own Skills reach the keeper. Harbor passes them in `skills_dir` and the adapters dropped it, so `cumulative-layout-shift` ran without the `agent-browser` package it was given; the directory is exposed as a separate read-only `terminal-bench-task` Skill source, and installation fails unless the public catalog confirms the exact package identities. A trial with no `skills_dir` renders byte for byte as before (#37286). An arm b, c or d whose runtime provider cannot declare the parallel-tool policy is refused locally instead of after upload — the exact Terminal-Bench 4.0 run reached `KeeperUpFailed` with no tool calls — and the check reads the catalog providers `claude` and `openai-responses` rather than the CLI names `anthropic` and `openai` (#37322).
- Librarian: a wake reads the completed turns a keeper's durable stores record, instead of only what the turn that woke it carried. A range runs from the last recorded read position to the newest completed-turn boundary, the memory commit is receipted in `<keepers-dir>/<keeper>.librarian-range-commit.json`, and a range that fails is retried from the first cut point rather than as one large pass. Known limits at this tag, all confirmed against the merge commit: a checkpoint purge can strand the read position (#37361), a trace that completes turns between the recorded one and the current one is skipped and its turns are never read (#37362), the durable drain runs before official-client evidence a handoff kept, which reverses the order two passes reach memory in (#37363), and the external-attention log is cut by wall clock, so an item stamped before a turn boundary but appended after it falls outside every interval (#37364) (#37208).
- Keeper: a turn that carried its whole history no longer offers a starting atom to the next official-client session. The seed was read as `total_atoms - transmitted_atoms`, which is 0 for a lane that sends everything, and 0 was taken as "start here" rather than "nothing was skipped". A lane that walks through Codex and back therefore made the next start carry the whole history again (#37356).
- Board attention: the dashboard and the TUI name the answer's source as Exact, CLI or Vendor System One. A run that finished through Vendor System One keeps `selected_slot` empty by design, and that was drawn as unrecorded attribution (#37296).
- Context: the inspectors say when a displayed history range has no runtime recorded against it. After a failover a turn can keep an earlier candidate's range while its row names a later runtime; the dashboard called that range transmitted and the TUI said it was sent this turn (#37258).
- TUI: the NEXT REQUEST band stays on screen when the turn history is empty or its read fails. The forecast is measured separately and used to disappear with the history error (#37347).
- Board: the Board JEV status reads the same on the server, the TUI and the Dashboard. `CONFIGURED` means an API model is set, not that a call or a credential check succeeded; `OFF` means Board judgement is switched off; a CLI-only lane and a lane that is not ready each show their reason. A valid key with the Board switch off no longer reads as configured. Blank or whitespace-only endpoint and model values are normalized in the shared config, so the HTTP client's defaults change along with the display. The `masc.standalone_llm_lanes.v2` payload carries a typed `configured` field and has no compatibility reader (#37339).

### Fixed

- Librarian: an offline checkpoint purge moves the Librarian's read position with the checkpoint instead of leaving it against the old numbering (RFC librarian-lifecycle §10-2, #37361). The dashboard action and `masc-checkpoint-purge --apply` refuse the rewrite while the position is short of the history's end or its final digest names another same-length history, and otherwise install the checkpoint and then write the position at the rewritten end, its `boundary_lines_seen` untouched; the preview names the refusal in its warnings. The dashboard cancels and awaits the server-owned Librarian lane before the two writes; the CLI takes the workspace writer lease and refuses while a server holds it. This deliberately replaces the old boundaries-file-presence gate: a boundary log may remain because `boundary_lines_seen` is preserved, while the typed atom position proves whether the rewrite would skip unread history. The old check compared only the checkpoint's final atom, so a rewrite that changed an earlier one was installed and every later read stopped on the mismatch. The `LibrarianRead-purge-trim*` models in `specs/bug-models/` have their code counterparts in `test_keeper_checkpoint_purge.ml`, one test per rule the models measure.
- Librarian: the keeper memory health surfaces say how far behind each keeper's Librarian is standing (RFC librarian-lifecycle §4.9, invariant I4). Every row carries the state its last pass ended in, the unread turns behind each read position, when the pass took that count, the time the Librarian last wrote the snapshot, and the kind on the journal's last failure. The counters they replace — the lane-busy gauge and the cadence counter — were totals since the server booted, which said whether anything had ever gone wrong and never whether this keeper is behind now. A count that could not be taken is sent as null and printed as `unread ?`, not as zero. The health schema is `keeper.memory_os.current_health.v5`; the TUI Memory header and the dashboard panel read the new shape, and the `librarian_lane_busy` alert becomes `librarian_stopped`.
- Keeper: the carried front is judged by its atom number and the SHA-256 of the message that opens it, not by the atom count. An attempt that saved one atom fewer no longer throws the front away and sends the whole history, a history of the same length whose last message changed no longer charges usage to atoms the ledger never counted, and a refusal is retried only when eviction actually moved the front (#36955).
- Keeper: a refusal whose reason MASC cannot classify narrows the carried range like a classified overflow (#36977). The narrowed front lasts into the next turn only when the narrowed request is answered: `Keeper_carried_front.of_records` seeds from `response_observed_model_input`, so a refusal that never received a response leaves the next turn nothing to start from. A refusal that was not about size moves the front the same way, and a front only moves toward the newest atom, so that keeper does not carry the atoms it passed again. To carry them again, stop the server, delete `<keeper>/turn-records` under the selected cluster's root — `<base-path>/.masc`, or `<base-path>/.masc/clusters/<cluster>` when `MASC_CLUSTER_NAME` names one — and start it; that keeper's turn history on the dashboard goes with the records. The next candidate in the same turn starts from the front a refusal moved instead of the whole history (#36986), and the turn records Claude Code, Codex and Antigravity leave are read as fronts (#36997).
- Claude Code: a prompt the CLI refuses before sending — `terminal_reason` `blocking_limit` ("Prompt is too long") or `rapid_refill_breaker` — is a context-window overflow and takes the halve-and-retry path. It was a generic provider failure whose recovery opened a new session and sent the whole history again every cycle (#37063).
- Storage: a durable JSONL append without an offset check cuts a torn last line, left by a crash mid-append, under the path lock, syncs, and continues, with a WARN naming the path and the bytes cut. The absorbed-memory store, approval audit, chat event log, channel gate bindings, run registry and turn boundaries no longer refuse every later append after one crash; an append that checks the end offset still refuses (#36999).
- Schedule: an interval wake that was durably queued before owner activation or acceptance failed is retried on the next tick instead of deferring itself forever (#37100).
- Schedule: `POST /api/v1/tools/masc_schedule_cancel` records the authenticated caller as the canceller and overwrites the `cancelled_by_*` fields in the request, where a token for one actor could name another; the response carries the recorded actor (#37149).
- Health: a readable keeper queue whose owner lifecycle could not be looked up is no longer reported as a storage read failure. Queue storage reads alone set `counts_complete` and `read_errors`, and the owner cause is kept in `owner_lifecycle_detail` on the keeper and backlog rows, so its pending work stays counted and is still flagged for the operator. The served summary's `schema` moves to `masc.keeper_event_queue.fleet_summary.v7` and the raw summary to `v5`; the queue's stored files are unchanged (#37125).
- Librarian: when every API slot is refused while its request is built, as with `missing_deadline`, the walk continues into the declared `cli_slots` (#37070); a slot the preflight excluded is no longer executed (#37147); and every working context in the output schema needs at least one source, as the domain parser already required (#37099).
- Keeper: a restart seeds from the window that received a response. A turn can take a response from candidate A and then make a narrower request to B that never answers; the record held only the latest attempted window, so a restart could seed from B's refused range — A answers `[0;8]`, B is refused at `[8;12]`, and the restart kept `[8;12]`. The record pairs the answering runtime with its exact window, an official client certifies a prepared window only where it reports `Whole_input_transmitted`, and a resume the vendor holds claims no local range. The ambiguous `Unfinished_turn` seed origin is gone (#37245). A window observed from a runtime since removed from the catalog is still read, because the trace, the atom index and the opening message's SHA-256 decide it and catalog membership is not evidence; removing a runtime used to send that keeper back to an older seed or the whole history at its next restart (#37248).
- Keeper: the heartbeat keeps the current failure cause. Failure accounting replaced the typed terminal cause with a consecutive-failure count, and a later cycle exception could leave an older configuration error on screen; the cause is published after the owner commit, the heartbeat retains it, a new cycle exception replaces it, and a success clears both it and the count (#37212).
- Keeper: `delete_history` removes checkpoint archives only. It accepted any real filename under the current trace, so a request could delete `history.jsonl`, `history.internal.jsonl` or the canonical checkpoint generated for that keeper; a name that is not an archive is reported in the existing `missing_snapshot_ids` list, and deleting an archive hardlink still leaves the canonical file alone (#37145).
- Exact output: a complete provider 5xx, and an HTTP 2xx whose body missed its deadline, reach the lane's next declared candidate, with the failed one settled and released first. An incomplete non-success refusal stays terminal, and an incomplete successful body never becomes output or a provider trace (#37319). A candidate's declared `reasoning-effort` reaches its exact target, provider config and request plan: it survived for ordinary keeper requests and was dropped when the exact target was built, which with thinking on rejected a Librarian request before dispatch as `Enable_not_encodable`. Low and high produce different frozen identities and request bodies, and a captured target does not change when the registry is republished (#37326).
- Board attention: the CLI tail runs inside the exact run, so a judgement a CLI slot answered completes that run with the CLI slot and its output. The flow closed its record at the HTTP failure and the worker called the CLI afterwards — on 2026-09-19 all twelve judgements a CLI slot made were recorded as `failed, selected_slot=glm` — and the failure reason was flattened away on its path to the record. Only provider exhaustion and an advanceable final HTTP failure walk the tail now: a failure that cannot start or record its attempt ends as `flow_bookkeeping_failure` without calling a second transport, where every execution failure used to walk it. When every CLI slot fails, the original HTTP failure and evidence are kept and each CLI failure is logged (#37180, #37292).
- Board, Goal and Context: a write records the actor its credential was authorized as. The routes authorized a bearer token and then rebuilt the acting name from client headers, so a token owned by A could publish, vote, own a sub-board or drop a Goal as B; post, comment, both votes, sub-board create, update and delete, and Goal transitions take the actor from the authorization callback, and sub-board ownership checks read that same actor. A tokenless request keeps the existing admission rules and its local attribution, which is not an authenticated identity (#37327, #37342). A Board context request to a keeper answers HTTP 202 with the operation id the owner stored: the adapter read `request_id`, `keeper_name` and `status` from a producer that emits `operation_id` and `state`, so an accepted request returned HTTP 500 after it had already been stored, inviting another submission. The dashboard reads the same two fields and names the keeper that took it (#37343).
- Audit: a tool-host failure report names its reporter. The body's `agent_name` was stored as the audit event's `actor`, so reporting B's failure with A's token left the log and the event display saying B reported it; the authenticated reporter is recorded as the actor and the body's agent is kept as `reported_agent` beside the existing failure envelope. Records already written are not rewritten (#37277).
- Dashboard: a keeper that has never booted no longer turns the whole execution screen into a 500. A keeper declared in config but never started appears as a declaration row with `status: "unbooted"` and no diagnostic; building the continuity summary read its `health_state` as `""` and raised, and that raise came from the place the whole summary list is built. Declaration rows are filtered out by a typed row kind, the strict health check still applies to running rows and now names the keeper it rejects, and the server's live refresh path calls the builder instead of its own copy of it. `/api/v1/dashboard/execution` had been failing between 600 and 1,509 times a day since 2026-09-17 (#37122).
- Dashboard: a keeper lifecycle event that throws no longer loses the rest of its batch. One guard covered the whole batch, so the first exception — an unknown status in a cached row, for instance — dropped every event behind it and the execution screen kept showing a booting or stopped keeper in its old state, with one `keeper lifecycle listener iteration failed:` line to show for it. Events are handled one at a time in arrival order, each failure logged with the keeper name, the event and a backtrace before the next one is taken, and `Eio.Cancel.Cancelled` is re-raised rather than counted. The subscription's dropped count is read per drain, and a drop, an undecodable payload or a failed refresh invalidates that keeper's dashboard caches whole, so the next read rebuilds them from the current state (#37230).
- Dashboard: a current turn record decodes. The decoder required `generation`, which the writer does not emit, and rejected the `usage_scope` and optional `tool_surface_ref` it does emit, so no current record was readable; unknown and invalid fields are still rejected (#37262).
- Dashboard: a declared temperature of `0.65` is drawn as `0.65` where runtime parameter details rounded it to `1` — counts keep their grouping (`131,072`) and settings such as the temperature and both connection timeouts are drawn as set (#37205). The current runtime blocker is drawn once, where the alert strip repeated it under both 런타임 차단 and 정지 원인 (#37223). `+ New Skill` appears on a ready catalog that holds no Skills, so the first one can be created through the existing source, create and refresh path (#37289).
- TUI: Keeper Info shows the current runtime failure, which it omitted even where the registry and the detailed status carried it, and clears it when the production success reset clears the cause; the historical `last_error` stays separate (#37226). A failed exact run shows the code and explanation the registry retained, in the TUI and on the dashboard, where both omitted them; a successful run has no failure line (#37328).
- TUI: the Approvals surface stays in the ring when a keeper has an open question and nothing waits for approval. Visibility, the badge count and the alert colour counted approval rows alone, so a question could sit unseen — one went about eight hours and was answered from the dashboard instead (#37060).
- TUI: the runtime picker tells apart bindings that differ only in reasoning effort. Six `claude_code.claude-sonnet-5` rows drew alike: the 24-column TARGET cell cut `-low`, `-high` and `-max` off the end, the model cell read the same on every row, and the declared effort was not in the data the screen received. Each runtime carries `declared_reasoning_effort` — the value the binding declared, `null` for none set — the decoder requires it and refuses an unknown value, and the id is drawn from both ends so the suffix survives a narrow terminal. An operator picking `code-reviewer` had been given `-medium` by mistake (#37115). The lane editor's notice no longer follows the cursor onto another screen, a move key pressed while a write is outstanding is refused as such instead of answered from the old list, and the list-may-be-stale line stays until that list is read again (#37167).
- Memory: `keeper_memory_search` searches the retained history before it cuts to the limit. History read a fixed raw tail and then took the first 50 or 20 user messages, and working context was capped at 100, so stored messages — including the newest ones inside those tails — could disappear before the query ran. The query and full-body duplicates are filtered while the chunked reader scans, stopping at the requested limit, reading working context, then the current trace, then previous traces in recorded order, each newest first. Undecodable rows and unreadable trace files are listed in `history_read_errors`, and an incomplete empty search does not claim `no_match` (#37297). Two messages sharing their first 100 bytes are no longer folded into one, because the whole extracted text is compared (#37290).
- Librarian: replay reads the checkpoint of the cluster it is replaying. It selects the current trace from the active cluster's typed metadata and reads the checkpoint from the writer's cluster runtime root, where it used another root and could pick another cluster's last turn when keepers share `MASC_CONFIG_DIR`; missing, unreadable or non-current metadata is reported as a skip, and nothing is repaired or created (#37130).
- CLI: `masc-checkpoint-purge --base <workspace>` finds the checkpoints a keeper saved. It read `<workspace>/traces` instead of the selected cluster's runtime root and so found none, with `--base` and `MASC_BASE_PATH` alike; `--apply` writes its backup under that same root, and the dry run stays the default (#37144).
- iMessage: a cursor file that cannot be read fails the connector's startup through its existing `cursor unreadable` path, where the `Sys_error` escaped the startup boundary. A missing cursor still starts at 0, a valid one still reads its ROWID, and malformed JSON is still refused (#37142).
- CI: a suite a PR edited directly is built and run before the suites selected from module names, dune stanzas, guard paths or source references. Both sets were merged into one sorted list, so on #37105 `test_tui_keyboard_input.py` arrived 396th and got the last 238 seconds of the 1,080-second step, and the check failed twice without reaching the changed assertion. Attributed suites still run, and anything the remaining budget cannot reach is still reported by name as a failure (#37268). The installed first-turn acceptance's release-evidence provider owns a non-secret inline credential, so its loopback smoke no longer fails the credential gate before it reaches the fixture (#37316).
- Board: a vote whose post or comment did not load is kept. `load_persisted_votes` skipped it, and the next whole flush rewrote `board_votes.jsonl` without it, so a load that missed its targets turned into deletion; deleting a post already takes its votes with it, which makes a missing target at load time a target that failed to load. Vote counts have never counted a vote with no target (#37163).
- Keeper: a retained front survives turns that recorded no response observation. The cold seed reader read the most recent 200 rows, so after 200 rows without one an observed front vanished from cold request composition and from the next-request forecast, both falling back to the whole history. The retained turn store is searched backwards on the same trace until the last response observation and stops at the first match, and the forecast reads that same seed once, only where a candidate has no valid warm ledger; where there is no match the search can visit every retained row. Trace and digest validation are unchanged, decoder failures are counted only among the rows visited before the match, and a turn number a direct retry reused takes its last stored observation (#37250).
- Keeper: a Board entry that cannot be read this tick no longer hides readable work behind it. Intake spent an admission slot before reading a source, so one transient failure could starve every later source on every tick; slots are now counted as sources are admitted, and a transient read costs none (#37257).
- Retention: raw-trace cleanup keeps running when a recent turn record comes from before a hard cut. The sweep required every recent row to satisfy the whole current TurnRecord schema and stopped at the first that did not, leaving orphan traces on disk. It now decodes the stable keeper, trace and run-reference projection, and a malformed reachability root still stops it before anything is deleted (#37345).
- TUI: an authored Skill's name is parsed with the canonical decoder (#37406).
- TypeSafe AI: a Score keeps its probability level keys (#37377).
- Runtime: a candidate refused for access keeps the evidence of that refusal (#37227).
- Lanes: Docker control commands are bounded (#37305).
- CLI: checkpoint purge keeps its working-directory fallback (#37215).
- Librarian: a CLI fallback failure keeps its evidence (#37191).
- Retry: a `retry-after` given as a JSON integer is read (#37384).
- Exact output: a `[runtime.exact_output_lanes.verifier_exact].slots` entry that names no configured runtime is dropped with a warning naming it, as `cli_slots` entries already are, and the lane keeps the slots that can judge. Nothing checked those ids against the runtime table before: publication admits a slot through `Exact_output.admit_target_ref`, which answers whether the id is a catalog target, not whether a runtime is configured for it. An id in the catalog and absent from the runtime table therefore published and then failed every judgement it was given (#37395).
- Observability: the metric store no longer swallows `Eio.Cancel.Cancelled`. `best_effort` caught it with `| exn ->`, so a counter incremented inside a cancelled fiber turned the cancellation into one warning line and the caller carried on, against the rule in RFC-0106 (#37371).
- Librarian: a failure that cannot move to the next candidate, such as an HTTP 200 whose provider response is malformed, is no longer handed to the CLI fallback, where a CLI answer turned it into a success. The original error and its dispatch class are kept; candidate exhaustion and domain refusals still fall back (#37411, #37421).
- HITL: Auto Judge no longer runs its CLI fallback after an HTTP exact flow ends in a failure it must stop at. It used to deliver the CLI's approve summary for a malformed HTTP 200 response; the original HTTP attempt is now kept and quarantined (#37413, #37421).
- Librarian: Official-client input that is refused before the Librarian runtime is entered, by a failed Memory snapshot read or a pre-run configuration check, is kept for the next wake. It used to be recorded as run and dropped, so restoring the snapshot could not retry it (#37161).
- Keeper: `masc_keeper_clear` no longer reports nothing to clear, and no longer resets the failure streak, when a checkpoint exists but cannot be read or parsed. Only a missing file counts as nothing to clear; any other read error is returned with the checkpoint path, and the file, the restart marker and the failure state are left as they were (#37121).
- TUI: a long action result no longer disappears from the footer. It keeps its full text when it fits and is cut with a truncation marker otherwise, after warnings, search and the required keys keep their room (#37414).
- TUI: creating a Composition with `C` checks the authored source the way the server does before sending it, so a frontmatter name that differs from the Composition body's name is shown on screen instead of coming back as a server refusal (#37420).
- TUI: a lane-run payload shows each top-level field as its own labeled preview, so a large first field no longer hides the results after it. When the 65,536-byte preview budget cannot hold every field whole, each keeps a minimum preview and the count of omitted fields is stated (#37418).
- TUI: PageDown and PageUp on a lane run move by the payload rows actually on screen, so no rows are skipped between pages; at 180×42 rows 29–32 used to be skipped (#37426).
- Dashboard: the FSM hub no longer shows `retry applied -> <runtime>` when a turn only set a lane aside for the next turn. A keeper receipt records the lane a turn took up (`degraded_retry_applied`, set only when that turn reached the provider on it) and the lane it set aside (`degraded_retry_deferred`) separately, each with its own runtime and reason, and the hub shows both (#37375).
- TUI: the Overview summary row counts open questions the way the Approvals ring and badge already do, so the two no longer show different numbers while a question waits (#37329).
- Server: eight catch-alls in the server no longer swallow `Eio.Cancel.Cancelled`. A cancelled fiber in a dashboard cache-invalidation callback, the IDE LSP proxy, an IDE file load, a forked runtime route or keeper-persistence startup used to turn cancellation into a warning line while the caller carried on (#37451).
- Keeper chat: a `keeper_artifact_transfer materialize` call now shows up in the keeper chat's file changes and in the audit transcript. The handler has two actions and only the action decides whether bytes are written, so classifying by handler alone dropped every materialize from those surfaces; the row now carries the blob's sha256 and byte count rather than its body, because the body is not in the call input (#36827).
- Keeper: a cancelled turn is no longer swallowed by observer error handling. Four places in `lib/keeper` caught every exception around an installed callback and logged it, which turned `Eio.Cancel.Cancelled` into a log line and let the turn carry on as if nothing had been cancelled; those observers now let cancellation through (#37437).
- Config: the seed `config/runtime.toml` no longer declares `supports-response-format-json = false` for `minimax-m3` under the `ollama_cloud` provider. That binding speaks Ollama Cloud's `/v1` wire, which does take the field; the declaration described MiniMax's own Chat API instead. Nothing a request carries changes -- the catalog already supplied this model's capabilities, so the line never reached a request -- the file now says what the runtime does (#37450).
- Runtime: for a provider the model catalog does not know, a capability key left out of `[models.<id>.capabilities]` now follows the wire's preset, as the configuration documentation always said; it used to read as `false`. Media keys (image and the like) still stay off unless declared. A `top-k` or `min-p` used without a declaration still fails to load, and the error now says whether the capability is false or simply not declared. The runtime's declared-capability endpoint reports an undeclared key as `null` rather than `false`. Models the catalog knows resolve exactly as before, so no deployment config needs to change (#37443).
- Keeper: clearing a keeper's context (`masc_keeper_clear`) now also ends its Claude Code, Codex or Antigravity session. It used to empty only MASC's own history, so the next turn resumed the provider session and the model could carry on the conversation the operator had just cleared. A checkpoint that cannot be read is now reported as a failure with both stores left untouched, instead of being treated as empty (#37168).
- Dashboard: a stop request in the verify queue can be approved. Approval used to require every completion clause to be confirmed, and a stop has none, so the button stayed locked. Completion requests are still gated on every clause, and a request whose intent is missing or unknown is treated as a completion (#37006).
- Librarian: a run's detail in the TUI now shows the evidence behind JEV's absorption decision -- the disposition, the skip or failure reason, the requested and returned models, and the raw values -- read from the same durable record after a restart. A reply that fails to decode keeps its real HTTP status and raw body. A cancelled Librarian request no longer leaves its run marked `running`, and a JEV evaluation that completed before a later request was cancelled is kept (#37409, #37432).
- TUI: measurement reports and retained lane-run details enforce their 4 MiB limit while the response is still arriving, including a response that never finishes. An oversized reply is refused with its HTTP status, never shown as a partial success, and its connection is closed rather than reused (#37439).
- Runtime: eighteen more places let a cancellation through instead of logging it and carrying on (#37459). In five places where letting it through had also skipped cleanup, that cleanup now runs on the cancelled path too -- for example, a stored request is given its `Lost` state instead of being left without one, and an already-launched lane is no longer detached from the registry when a lifecycle notice fails (#37471).
- Observability: each recorded tool call now carries `wire_outcome` (`ok`, `error` or `unknown`) beside its execution disposition. A tool can finish at MASC's dispatch boundary and then fail while its result is delivered to the model -- when artifact storage fails, for example -- and the row used to show only the disposition and a `success` flag taken from the later response, which read as a contradiction. The disposition stays the authority: a committed effect stays `completed` even when delivery fails afterwards. Every row carries the field; a row without an observed outcome records `unknown` rather than leaving the field out (#37306).

## [0.35.20] - 2026-09-17

### Upgrade notes

- Runtime: a lane walks its declared order, and the sticky last-good candidate is gone. The walk used to remember the candidate that last succeeded and try it first for an hour, renewing on every success and shared across keepers, so once a fallback answered the lane never returned to its head while the fallback kept answering. Demotion is now only by quota and 429/402 backpressure — a head that rests walks behind its siblings until its release — and `MASC_LANE_PREFERENCE_TTL_S` is gone. The TUI's active/sticky row and its star, the dashboard's sticky note, badge and settings block go with it, and the next-request forecast schema is `masc.keeper.next-request-forecast.v5`, without the preferred entry (#36874, #36858, #36881).
- Runtime: `[runtime.assignments]` names a lane. A lane was reachable only when the value carried its head binding's runtime id; a value that names a lane now resolves to the lane's entry candidate, and two ladders can start at the same runtime. Every config that loaded before still loads, and a lane carrying a name of its own turns a dangling assignment into a load error instead of silently walking `[head; [runtime].default]` with nothing reported. A route resolves to the binding a turn opens first wherever a binding is needed — the effective tool surface and the briefing's input ceiling — where both were handed the label and the first answered `runtime_not_concrete` (#36824).
- Keeper: a turn's admitted event batch is bounded. The heartbeat stimulus intake admits at most `max_events` selections — default 32, `MASC_KEEPER_ADMISSION_MAX_EVENTS` — and the selections past the bound stay pending for a later turn instead of being dropped. A recurrence whose `interval_sec` is below sixty seconds is refused when the schedule is created rather than accepted and then firing without limit; records already on the ledger keep their interval until the operator edits them, because the decoder enforces only structural validity. The settings projection reads the bound it had registered but never projected (#29365, #36890).
- Config: `config/prompts/corrective-grammar-v0.3.md` is gone. It was a keeper's working draft that the installer copied into every config root and re-copied on each boot; removing it here removes it from every runtime config root at the next boot. Standing conclusions belong in runtime-local articles written through `keeper_constitution_write`, which carry author and evidence and never leave the workspace that holds them (#36888).
- Exec shim: the config file and the `env_file=` it names must be owned by root or by the account the shim runs as, and neither their group nor every user may write them. A request against a file that fails the rule is refused with `remote_ssh_shim_config_error`, and the detail names the file with its owner uid or its mode; both are judged from the opened descriptor before a byte is read. The ssh bootstrap installs the config root-owned `0644` and the microvm server writes it `0644`. A config edited by hand into a group- or world-writable mode is fixed with `chown root:root` and `chmod 0644`; rerunning bootstrap resets the mode but keeps the owner of an existing file (#36924).

### Added

- Setup: the seed `runtime.toml` declares Claude Code, Codex and Antigravity as live catalog entries — their model rows, their bindings, and the max-prompt-bytes ceilings the live fleet learned (524,288 for Claude Code, 131,072 for Antigravity). No lane or default references them and assignment stays the operator's; whether a runtime can run is what `masc doctor` and a dispatch refusal report, not the catalog's presence. A file credential path that starts with `~/` is expanded to HOME when `runtime.toml` is read, so the seed copied verbatim into a workspace keeps Antigravity's home-directory token reachable (#36745).
- Setup: Apple Container readiness reads the configured kernel from the same service reply the Rosetta question reads, and a Mac with none configured is a missing prerequisite instead of sailing past readiness and dying at image preparation. The prerequisites catalog offers `container system kernel set --recommended` — no admin — and quick setup takes it once the service is up, before the verified install (#36889).
- Exec shim: `env_file=` names a file of `NAME=VALUE` lines in docker's `--env-file` grammar, values taken byte for byte, that every payload runs with. It sits between the shim's base environment and the request values `env_allowlist` admits, and the request denylist does not apply to it. The file may not declare `PATH`, which `path=` owns, the GitHub token names, or `GH_CONFIG_DIR` and `GIT_TERMINAL_PROMPT`, which the runner sets for each request. A CRLF line loses its trailing carriage return, a FIFO, device or directory at the path is refused before it is read, and an error names the file and line number, never the line's text. A 0.35.19 shim refuses `env_file=` as an unknown key, so upgrade the shim before the config names one (#36919, #36924).

### Changed

- TUI: the NEXT REQUEST band lists every candidate of the lane in the order a fresh cycle walks them, and says for each where it stands and whether its path rests. The band forecast the keeper's bound runtime alone, so a keeper whose lane was on its second or fourth candidate saw a request that would never go out. The assembly is drawn for the first walker alone, and turn records are read once per forecast instead of once per candidate (#36867, #36881).
- TUI: the memory screens read the recall block, not the snapshot file. The column is headed RECALL and measures the strings a keeper injects — rendered facts, and per-source facts with their invalidations — where the old figure was the JSON file's size on disk, `first_seen` and punctuation included, and an unreadable snapshot reported the size of a file it could not parse instead of 0. Both memory surfaces read the figure in tokens through the same estimate the context inspector uses, because the window and its marks are tokens; attachment sizes and the heap figure stay in bytes (#36876).
- Keeper: the forecast counts a message's bytes without building them. The projection measured every message by encoding it to a string — twice, once for the window and once as pinned or atom — and on the live code-reviewer keeper, whose durable history is 15,212 messages, the endpoint took 1.0-1.25 s per call, mostly on the main domain where every keeper turn also lives. The count is pinned against the string writer, and a test fails if allocation grows with the bytes measured (#36853).
- Keeper: a recorded skill activation stops decoding the ledger a second time. `[record]` wrote the next ledger, read the written file back and decoded it again to compare one revision string — on the msx keeper's 844-activation ledger an activation moved 2.7 MB of JSON while holding the session lock a checkpoint save also needs. The ledger `[record]` returns is now the answer, and a test checks the codec reads back what it writes (#36814).
- Keeper: an internal failure's message is its payload. The summary read `internal: Internal error: ...`, the category label twice, because agent-core renders Internal and Internal_carried as "Internal error: <payload>"; those two constructors now hand over the payload, and every other family keeps agent-core's own sentence, which names the specific failure (#36793).
- TUI: brightness serves hierarchy in the chat. Speech leads and chrome recedes: work and journal bodies sit one rung below speech, the gutter clock, the civil-hour rail and the breadcrumb are chrome, and a dim body's link restore, its reopened tool tree and a failure reset re-assert the rung they sit in. Finished work folds to one line, and the lane word goes because the lane mark already names it (#36866, #36870).

### Fixed

- TUI: a loader's inflight flag clears when `fork_daemon` throws synchronously. `Eio.Fiber.fork_daemon` raises `Invalid_argument` in the caller when the root switch has finished, so a key handler racing teardown left the pane loading forever and the surface stuck; `Masc_tui_fork_guard.launch` re-raises cancellation untouched and runs the loaders' failure move on any other synchronous throw, at all nine launch sites (#36872).
- Dashboard: the reject form no longer fabricates a reason. It substituted the literal '사유 미기재' whenever the reason was blank, so the verdict always carried a non-empty reason and defeated the server's own non-empty guard; an empty submit now shows an inline message and does not call the mutation (#36878).
- Keeper: the silent lane-switch fallback logs. When no server root switch is installed, both the keepalive and the supervised launch substituted the turn-scoped `ctx.sw` with nothing distinguishing the case; both now log a WARN naming the keeper and stating the substitution, and the launch tries the root switch first as its sibling already did (#36871).
- Tools: a blob export's parent-dir mkdir failure is normalized to the blob store's `Sys_error` contract, so it surfaces with a readable OS reason instead of escaping the handler's arm (#36880).
- CI: the stanza reader collects `(deps (source_tree ...))` entries it silently dropped, so a suite that depends on a directory target is built and run (#36733).
- Exec shim: an argv payload's program is looked up in the endpoint's `path=`. The shim looked it up in its own `PATH`, so `path=` reached only `sh -c` payloads and a tool that lived only in a declared directory was not found (#36916).
- Agent core: an OpenAI-compatible response whose choice ends with `finish_reason: "error"` is a provider error, in a stream and in a complete response. When its error object's numeric `code` is 429 or a 5xx, the result is an HTTP error of that status, classified like the same status before a stream starts; any other error is `Provider_reported_error`. It used to end the turn as `UnrecognizedStopReason`, which no lane retried. A 200 response carrying a top-level `error` object is `Provider_reported_error` instead of HTTP 400, and a complete response the parser cannot read is `Provider_parse_error` (#36920, #36922).

## [0.35.19] - 2026-09-16

### Upgrade notes

- Keeper: an Agent-Core-lane request is composed from the pair's carried range, measured in tokens, instead of a byte cut. A `runtime.toml` binding takes `context-high-water-tokens` and `context-low-water-tokens` together: after a response whose counted total passes the high-water mark, the oldest measured blocks leave the carried front until the projected total is at or below the low-water mark. Load refuses a high-water mark above the model's resolved `max-context`. A binding that declares neither mark keeps every atom until a provider refusal moves its front, which is the behaviour of a workspace that changes nothing. `max-request-body-bytes` no longer sizes how much history goes out; it admits or refuses the serialized request, and a refusal moves the front and retries the same candidate before the lane rotates (#36709, #36803, #36808, #36822).
- Config: `[turn] context_window_tokens` and `MASC_KEEPER_CONTEXT_WINDOW_TOKENS` are gone. A `runtime.toml` whose `[turn]` still declares the key fails to load on this binary — an unknown `[turn]` key is a load error — so remove the line before upgrading. A workspace that declares neither the old key nor the new marks is unaffected (#36822).
- TUI: run `masc-tui` and the server from this release together. Keeper health has a fourth value, `failing`, and a `masc-tui` built before this release refuses a keeper list that carries it. A chat event page now answers with `next_since_offset` beside its seq cursor, and this release's `masc-tui` refuses a page that has no `next_since_offset` (#36693, #36701).
- Checkpoint: a session keeps three history snapshots instead of twelve. Each entry is a whole checkpoint of the session, and the older ones go at the next save, so turns further back can no longer be inspected or restored and the dashboard checkpoint list shows three (#36772).
- Schedule: the ledger drops a finished schedule whose last recorded activity is more than seven days old, with its wakes and notes. Its last activity is the newest of its own requested and due times, the wakes it ran and the notes written on it, so a schedule someone is still writing notes on is kept. `prune_completed` still forgets every finished schedule at once when an operator asks (#36775).
- Server: the feature flag registry's read surfaces are gone. `/health` no longer carries a `feature_flags` section, `GET /api/v1/dashboard/feature-health` is removed, and the dashboard's feature-health page, its hidden monitoring route and the inspector's features tab are deleted with it. The flags themselves are unchanged — same environment variables, same defaults, same strict parsing for `MASC_HTTP_AUTH_STRICT` — and every reader now reads the env contract directly (#36813).
### Added

- Keeper: `GET /api/v1/keepers/:name/next-request` reports what the keeper's next request would carry, without firing a turn. It reads the pair's carried front, the binding's marks and the last counted total, in tokens, and reports the atoms the next request would start from, together with the tool schemas and keeper instructions as the newest completed turn on the keeper's own runtime measured them and the pinned blocks as the newest first-round composition measured them, whichever lane recorded it. A runtime with compositions but no first-round one is refused with that reason instead of read as unpinned, and the band names the lane beside the turn when it is not the candidate's. Nothing dispatches, advances a board cursor or consumes an operator note, and only the keeper's bound runtime is forecast. The MASC Context screen draws the answer as a NEXT REQUEST band under HOW FAR BACK; a server that does not serve the endpoint is named in the band (#36757, #36760, #36788, #36800, #36804, #36822).
- Setup: where Claude Code is on `PATH` and the journey would open at step 1, setup shows a plan first — the workspace step 1 would offer, Claude Code with `claude-sonnet-5`, text only, and the sandbox (Apple Container where the host supports it, else a running Docker, else chosen in step 4). `Start quick setup` runs it to the end with no further questions; `Choose each step` is the journey as it was. Quick setup keeps every check the screens have: the model is verified with a real response and tool call, and a failed check offers the same sign-in, retry and "choose connections again". For Apple Container it takes each action the prerequisite catalog offers at most once, so a service that never becomes ready ends in the step 4 screen instead of a loop, and any step it cannot decide hands back to that step's screen. Building the plan only reads. Without Claude Code, or without a readable sandbox catalog, no plan is offered (#36747).
- Verification: `GET /api/v1/verification/requests` takes `view=awaiting` and `offset`. The store has no removal path, so the endpoint answered with every request ever submitted; `view=awaiting` joins on the `verification_id` each awaiting task carries, so a task re-submitted several times draws the one record it waits on. `offset` pages the store, with `total`, `returned` and `truncated` beside the rows. An id the backlog waits on that names no record is counted and listed rather than dropped, an unreadable backlog answers with an empty queue carrying its reason instead of the unfiltered store, and a backlog read from the `.last-good` snapshot says so. No `view` is the full history at offset 0, as before (#36790, #36797).
- TUI: Task Review opens on the queue of what is waiting, and `h` moves to the full history and back. `<` and `>` page the history, and forward is refused unless the server says a further page exists. The row under the list says which list it is and where in it — `awaiting 76`, or `history 201-400 of 1401 · > next page`. A backlog that could not be read draws its reason under the empty list, an id waiting on a record the store does not hold is drawn too, and a queue computed from a snapshot says so; all three used to be indistinguishable from "nothing is waiting". Changing the view or the page clears the cursor, the scroll, the open detail and any half-armed approve, and is refused while a load is out (#36792, #36797).
- TUI: the agenda panel behind `;` opens the work it counts, instead of only scrolling and closing. `j` and `k` walk the rows that lead somewhere and step over the prose between them, and `Enter` opens the row — the verify queue for a stop waiting to be granted, the task itself for work held by an agent with no Keeper queue, Approvals for a keeper holding a tool call. `;` opens on the first row that leads somewhere, so the first `Enter` answers something (#36794, #36797).
### Changed

- Keeper: what a request carries is decided by position in the pair's ledger, not by an estimated size. The front is the ledger's front while the process holds one, else the range the runtime's last completed turn carried, else the newest suffix the request-body cap admits. A provider context overflow and a byte-axis refusal move the front by the same eviction walk and retry the same candidate. Before the first usage is counted there is nothing measured to evict, so a refusal narrows the range toward the newest atom by halves and returns the refusal once a single atom is left; no size is estimated. The official-client lanes keep their own byte halving (#36709, #36803, #36808, #36822).
- TUI: the MASC Context screen reads in tokens. The three bands are named for the question each answers: `WHAT WENT IN` for the pieces the request was built from, `THIS REQUEST, AS SENT` for the provider's count of it beside the estimate from the body MASC sent, and `HOW FAR BACK` for how much of the kept conversation it carried. The composition rows, the request tab's items, the proof tab's rows and the skill delivery row on the Tools screen are drawn as `≈N tok`, with the bytes they were read from beside the sentence that names the ratio. The ratio is this record's own body over its per-request count, else the median of the page's rows that carried both, else a fleet median; a conversation-cumulative or unknown-scope count never becomes the ratio, and the sentence says which of those it refused. Disk sizes, such as memory snapshots and checkpoints, stay in bytes (#36685, #36692, #36707, #36724, #36742, #36806).
- Keeper: eleven built-ins are no longer carried on every Agent-Core-lane request. `keeper_artifact_transfer`, `keeper_constitution_remove`, `keeper_constitution_write`, `keeper_spawn`, `keeper_spawn_read`, `keeper_spawn_wait`, `keeper_task_create`, `keeper_tasks_audit`, `keeper_workspace_memory_read`, `masc_dashboard` and `masc_goal_list` move to the names-only list inside `keeper_tool_search`, and a Keeper that needs one loads it by name. `keeper_tools_list` stays always-loaded, because it is how a Keeper reaches a deferred tool by name. Official-client lanes carry the full array as before (#36681, #36773).
- Keeper: a failed terminal tool effect carries a named cause instead of a diagnostic string. The `detail` field of `terminal_effect_failed` is an object that says which producer failed — a tool, a composition node with the executor's cause, a missing receipt, an unstored or oversized output, a failed delivery, a failed boundary observation, a rejected recovery proposal, or Agent Core's own terminal effect — with tool names labelled by namespace. A run that succeeded but retained a failed terminal effect now reports that typed failure rather than an untyped internal error (#36752).
- Keeper: an OpenAI-compatible stream's reasoning block joins its token-sized text details when it closes. Adjacent details are joined only when both are objects of type `reasoning.text` carrying just type, text, format and index, with equal type, format and index; the joined detail keeps the first fragment's fields and concatenates the texts in order. A detail with any other field, type, format or index is kept as it arrived. Whitespace-only tokens are kept, so a block with no `reasoning_content` no longer loses its spaces and newlines. Checkpoints already on disk keep their fragments (#36654).
- TUI: a reading is spelled one way wherever it is drawn. Metrics' pulse card and the sections under it name an unobserved source with the same words (#36643) and read a span on the ladder the rest of the TUI uses, so a snapshot is "7s ago", not "7.6s ago" (#36661). The Lanes screen draws its p50 to one precision in the column and in the detail below it (#36671). The schedule and log detail panes spell section headings in caps like the other fifteen in that file (#36657). The chat's memory row drops the prefix in front of a sentence that already names the memory journal, and the one failure that did not name itself now does (#36682). Config / Runtime / Clients lists `p / Esc` as one binding rather than two rows that do the same thing (#36705).
- TUI: rows stop repeating what is already on screen. The Browser Lane's last row is empty, because the title above it already names the lane, its source, its browser and the read status (#36731). Config / params leads with the file its overrides persist in, which nothing else on that screen names, and drops the `Enter` hint the footer is pinned to keep (#36649). The File marks legend in the `?` sheet names the folder arrow beside the seven file kinds (#36674).
- Keeper: the keeper state diagram's `Running --> Failing` edge names the two things that enter Failing, a failed heartbeat or turn and an archived credential. It named an event the state machine does not have (#36734).
- TUI: the fleet header's failing counter prints its partition — retrying, where a clean turn returns the keeper to Running, and configuration-blocked, which no retry fixes — and names the configuration-blocked keepers, since that is the failing subset an operator has to act on. The health section carries the turn-configuration-error count and names unscoped, beside the autoboot-scoped pair it already shipped, so the two parts add up to the failing count for a keeper booted on request as well (#36818).
### Fixed

- Setup: a Mac without Rosetta learns so at the sandbox step instead of while imp's image is built. Apple Container builds images in a VM that uses Rosetta unless its configuration sets `[build] rosetta = false`, so a service that answered still failed every build with Virtualization's "Rosetta is not installed". The step reads Rosetta's installer receipt, and only where Rosetta is absent the builder's own setting, then offers the two ways past it: build images without Rosetta, which writes `rosetta = false` under `[build]` in Apple Container's user `config.toml` and restarts its service, or install Rosetta with `softwareupdate --install-rosetta`. A service that is absent or stopped keeps its install and start actions (#36746).
- Setup: on a Mac without Rosetta, the sandbox step reports that Apple Container's image builder cannot start, instead of reading the service as ready and failing later while preparing imp's image. Choosing that row offers two ways past it: `Build images without Rosetta` writes `rosetta = false` under `[build]` in Apple Container's user `config.toml` (`$XDG_CONFIG_HOME/container/config.toml`, else `~/.config/container`) and restarts the service, which reads that file only when it starts; `Install Rosetta` runs `softwareupdate --install-rosetta`, which shows Apple's license. The edit keeps the file's other lines, comments and permissions, follows a symlink to its target, and is refused before anything restarts when the file is not TOML. Where Rosetta is installed the builder starts whatever the setting says, so a Mac that was ready stays ready, and a service that is absent or stopped keeps its own installers (#36746).
- Keeper: a turn whose chat adapter left early — a failed connector, a missing token, an operator interrupt — no longer holds the turn open. The turn's event bus is a 512-event window, and an adapter that stopped reading left the publisher parked in it for good, so the turn never returned and the Owner's turn slot was never released. The bus now records that no reader follows and releases every parked publisher; publish and close then skip the bus while the journal, which is the durable record, keeps being written. Adapters with nothing to project no longer fork a fiber whose only job was to discard events (#36723, #36727).
- Keeper: a composition node that fails goes back to the model whenever the same tool called directly would, instead of ending the provider turn. That holds when every settled node has a committed receipt, every plan node is an ordinary atomic tool, the cause is a failed node, and each failed node either returns to the model when called directly or is read-only for the input it ran with. Terminal, nested and async graphs, deferred nodes, and plan, observation or completion failures keep the terminal fence. A returning failure that cannot publish its recovery evidence fences only post-effect and unknown failures, so a refusal that changed nothing no longer ends a turn (#36715, #36735).
- MSX: a lane refusal reaches the Keeper as a refusal. Every `masc_msx_*` refusal is declared as having taken no effect, so a macro pressed into an empty lane returns "call `masc_msx_load` first" instead of closing the request as a fenced effect. A press that raises now releases the keys it put down, and an edge is recorded in the ledger in memory only after the file took it, so a write the disk refuses raises instead of leaving the machine and later checkpoints holding an input the ledger file never took (#36665, #36679, #36696).
- Keeper: a rate limit or hard quota rests the path it hit, not the whole keeper. The rest length comes from the failure's own hint (at least 1 second), the floor for an unstated throttle and the cap for an unstated hard quota; the keepalive cadence is no longer an input. The keeper waits only while the path it would send next rests: a serving head of the walk order takes a pending input with no sleep, and a wait also covers the moment a fresh walk of the assignment can start on a serving head. The chat lane and the heartbeat read one next-dispatch decision, so capacity backpressure still holds a chat retry, and a wake still cannot re-dispatch a resting path (#36628).
- Keeper: a keeper in the Failing phase reads health `failing`, not `healthy`. Health is projected from the registry phase, and the TUI marks a failing keeper `!`, the dashboard raises attention for it and counts it as running, and the briefing ranks it with offline. Its next action is `Probe`, read the latest error, because the Failing phase says turns are failing and not that a restart fixes them; `keeper_recover` stays available for an operator who has read the error (#36693, #36702).
- Runtime: a Claude Code turn records its newest API call's token usage, not the sum over every call the turn made. Each call carries the whole context again as cache reads, so a turn of many tool rounds recorded several times the window, the context observation refused the figure, and the TUI drew an occupancy above 100%. Cost is unaffected on this lane (#36725).
- Runtime: interrupting a turn that is probing the Antigravity context window ends it. The probe waited for the CLI under cancellation protection, so an interrupt was ignored until the probe's own timeout expired. The private home is still removed on the way out (#36668).
- Redactor: a credential that appears before a prefix listed earlier is redacted. The scan took the first prefix in list order and copied everything before it as written, so `key=SECRET Bearer OTHER` kept the first secret. The text before the chosen prefix is now redacted the same way, what a prefix claims is unchanged, and a prefix with no token after it is left as written. The scan also no longer goes quadratic on a long run of one prefix ahead of another (#36756).
- Keeper: crash records queued when the server goes down are written. The drain fiber is cancelled by the closing switch, so the records for the shutdown — the ones keepers enqueue as they exit — were the ones most likely to be lost; a release hook now writes the queued tail. Taking an event and writing it is one protected step, so a cancellation leaves the record in the queue rather than nowhere, and the uncancellable stretch is one append rather than the whole queue (#36636, #36641).
- Server: a normal shutdown no longer waits out a timer. The startup watchdog and the completion authority's two retry timers only sleep and then check something, and nothing joins them; forked as ordinary fibers they were joined rather than cancelled when their switch returned, so a returning switch parked for a full interval (#36673, #36675).
- Server: an interrupt during HTTP connection-pool cleanup no longer strands clients. Eviction and shutdown take the whole idle set out of the pool and then walk it; a cancellation at the first client left the rest never signalled, their daemons never torn down, and their sockets held to process exit while the eviction counter had already been raised. Cleanup now delivers the stop signal to every client under protection and returns, and only shutdown, which owns one client at a time, joins. A request whose body was read in full is no longer reported as a timeout because of a cancellation in its release tail (#36664, #36676, #36683).
- Server: a domain-pool job that submits another job runs it inline instead of queueing behind itself. `Domain_pool.submit_cpu`/`submit_io` did not set the worker mark, so a nested submit queued a second job and waited for it; on a one-domain pool, or whenever every worker held such a job, the workers waited forever. Keeper recovery work was one such caller (#36698).
- Checkpoint: decoding a checkpoint with an invalid value nested deep inside returns. The validator re-checked a failing element under its own scope at every level of nesting, so a bad leaf 32 levels down was checked 2^34 times. The scope is now built while validating and spelled out only in the error, and the error text is unchanged (#36749).
- Schedule: a requested, due or expiry time that is not finite is refused when the schedule is created. `due_at_unix: 1e400` parses to infinity and was accepted, and every later write of the whole ledger then failed. A ledger that cannot be encoded is reported as a persistence failure without touching either file (#36763).
- Keeper: a chat event page's two cursors are checked as one pair. An empty page whose rows all lie at or before `since_seq` now hands back `next_offset`, so polling with that pair is accepted once the journal grows instead of being refused as `cursor_mismatch`. A held offset is checked at both ends, so an offset ahead of its seq no longer skips the rows between them with a 200, and an offset with no held seq is refused. The three cursor refusal codes are spelled once and the TUI reads them as typed reasons rather than an unreadable body (#36748).
- Browser: `BrowserSession` status with no session open also reports the driver's own readiness, as `driver.ready` with `driver.message`, or `driver.error` when the driver does not answer. A bare `{"open": false}` read as a broken lane both when the lane was fine and when a driver was holding a session this server did not know. Status still never fails on a closed session, and an open session's status issues no request (#36642).
- Blob store: a read that does not return validated bytes lets the next put write the blob again. A cached range read of a removed file, and a read error at the blob path such as a symlink or `EACCES`, both kept the address, so after a put learned to skip an address this process had already written the blob stayed broken for the life of the process (#36655, #36667).
- TUI: stepping through turns in the context inspector stops the read it replaced. Each `[` or `]` press started a read that resolves hundreds of blob artifacts, and a replaced read kept running with its answer discarded, so stepping quickly queued that work several times over. Closing the pane stops the read in flight (#36744).
- TUI: a turn observation leaves the Activity ring with the calls it numbers. Observations had a retention budget of their own, so they outlived their calls by hundreds of calls; an observation held that long still answered for its ordinal, and a session created without a checkpoint that reached the same ordinal opened a running row under a keeper turn that had settled long ago (#36640).
- TUI: pressing `l` or `v` on Logs redraws something when the read fails. The header drew the level floor only when a snapshot came back, so with the read failing the frame was identical to the one before it. The floor now rides a failed read when something is set, and the header stops restating that `verbose` is the floor being DEBUG (#36637).
- Server: reads that held the scheduler domain now run on the domain pool and decode only what they answer. A chat event page decodes the rows it serves and carries a byte-offset cursor, and a page resumed from a held seq bisects to it rather than decoding every row before it (#36701, #36758). A memory journal read parses only its tail, in one job, and names each row by its byte offset (#36686, #36697). One turn's provider input resolves its blobs and encodes its body on the pool, and the scan for a turn with no snapshot stops at an older turn of the same trace instead of decoding the whole store (#36740, #36741). `GET /chat/history` encodes on the CPU executor (#36753), the history window drops a row by marking it rather than rebuilding the window (#36754), a backwards JSONL scan copies a long row once rather than once per read (#36750), an event queue snapshot is built, sanitised and printed in one job (#36706), an operator snapshot is encoded once for its broadcast (#36764), and a memory commit parses and prints its snapshot on the pool (#36780).
- Keeper: work that was repeated on every turn is kept. A chat history read remembers what each unchanged raw-trace run said, keyed by the run and valid while the file keeps its device, inode, size and modification time, and a keeper's derived caches go stale on its own tool calls rather than on any keeper's (#36761, #36762). Model input demotion finds each marker's body in a table instead of scanning every aged tool result (#36647). A checkpoint's SHA-256 runs inside the pool job that encodes or decodes it, fed in 1 MiB slices so the hashing domain reaches its poll points (#36677, #36695). A put of bytes this process already wrote returns the reference without rewriting the file (#36655). Checkpoint validation builds an element's scope and its mismatch lists only when it fails (#36749). A schedule store mutation encodes the ledger once, compact, on the pool, and a runner tick that emits no signal leaves the seen-key file alone (#36751, #36763).
- TUI: a history load asks the server for no journal the session already holds. Only one request of a batch counted as held, so every other request's journal was fetched again on each load, about once a second (#36759).
- Runtime: a Claude Code turn no longer sends every masc tool schema inline on every request. The CLI narrows its built-ins to exactly the names `--tools` lists and defers MCP tool schemas only while its own `ToolSearch` is among them, and masc passed an empty list for the `none` posture and `Read,Glob,Grep` for `read`, so deferral was off. `ToolSearch` is now named in `--tools`. Measured 2026-09-16 in the fleet's own argv shape against a probe server carrying 203 tools: 176,928 input tokens for the first request without the name, 8,926 with it. The tool reads no local state and reaches no network, so `none` keeps its meaning (#36798).
- Keeper: the seven deferred tools whose description ran past the summary budget are offered as whole sentences. `keeper_artifact_transfer`, `keeper_constitution_remove`, `keeper_constitution_write`, `keeper_spawn`, `keeper_tasks_audit`, `keeper_workspace_memory_read` and `masc_dashboard` had a first line longer than the 80-byte summary, so the `keeper_tool_search` listing — which is what a Keeper picks a deferred tool from — cut it mid-word. Each now opens with a complete sentence (#36781).
- Keeper: a fenced provider attempt carries a typed cause instead of a rendered error string. `Provider_attempt_effect_fenced` and `Tool_correction_lost` built their `diagnostic` by rendering the inner error, so a carried MASC error's own JSON landed inside a JSON string and each wrap added another layer of escaping — on 2026-09-15 the sentence "no MSX machine is loaded" arrived under nested escaped quotes. The cause is now a nested object the codec refuses to read as a string, a deferred composition node is reported by kind with its deferral data in the payload rather than as a failure message, and the chat row keeps its badge whether the stop was fenced or not (#36785).
- Keeper: a turn the host stopped and a runtime connection that closed are typed values, not sentences the chat pane searched the failure row for. Both were flattened into an internal string, so a reworded message made the pane quietly wrong, and only the Codex runtime spelled the closed-connection sentence — the Claude Code runtime's identical failure drew nothing. Both now carry the runtime id, a runtime-reported interrupt is told apart from a MASC shutdown instead of both reading "Runtime shutdown interrupted this turn", and a boundary observation builds a sentence from the value rather than printing the wire label. Rotation is unchanged, and a client that never started still reads as unavailable (#36805).
- TUI: the fleet header stops listing a failing keeper as not running. The line subtracted the Running-phase list from the bootable one, so a keeper in the Failing phase landed under "not running" while the row under it showed its keepalive turning. It now subtracts the keepers that hold a live fiber, Running or Failing (#36818).
- Task: a nested task field that cannot be read is told apart from one that was never written. A `handoff_context` or `reclaim_policy` that failed to decode folded into `None`, so an unreadable field read as absent; the two are now separate values, and the backlog decode names the dropped fields per task in the log. `skills`, `contract` and `execution_links` still refuse the whole decode (#36787).
- Checkpoint: a save no longer builds a second copy of the whole document. The memoized encoder joined its pieces with `String.concat` and handed the writer one string, straight into the major heap; it now returns the pieces and the durable writer appends them to the temp file in order. On the live server the canonical checkpoints are 111MB and 107MB, and 2.19GB of them were rewritten over a 240-second window. The write is otherwise unchanged — the same atomic temp-fsync-rename and the same encode failure — and an empty piece no longer ends the payload (#36786, #36789).
- Keeper: model input demotion no longer hashes every aged tool result on the turn's own domain. Demotion puts each aged body back through the blob store on every provider request, and since the store stopped rewriting an address this process had already written, what was left was a SHA-256 over each whole body — one uninterrupted run of 0.7 to 1.6 seconds per request on the main domain, which is the `/health` probe's worst case. The bodies are now addressed in one pool job, and an attempt reuses the addresses it already holds, so the hashing runs once per attempt rather than on each of the 62 to 83 requests an attempt makes. A write the store refuses puts back the bytes the address was taken from (#36799).
## [0.35.18] - 2026-09-15

### Upgrade notes

- Browser: `[browser] webdriver_url` in `runtime.toml` is not read. Set `[browser] geckodriver` to the driver executable's absolute path; until then automation stays off and the server logs `automation has no browser.geckodriver` (#36594).
- Server: exact lane runs are recorded in `.masc/exact-lane-runs-v6.jsonl`. `exact-lane-runs-v5.jsonl` is not read, so runs recorded by 0.35.17 do not appear on the dashboard or in the TUI (#36596).

### Added

- Skills: `work-intake` ships as a builtin composition (`keeper_compose_work-intake`). One call reads the tasks `in_progress` and the tasks `claimed` (10 each), the 10 board posts with the latest activity without automation posts, the caller's questions still waiting for an answer, and the caller's own schedules that are `scheduled`, `due` or `running` (10 each); if one read fails, the call fails naming it and the later reads do not run. Its tool description tells the Keeper how to read the result: a question no longer listed was answered or withdrawn and is read first, a listed schedule that does the same work means doing it twice, a task another Keeper holds is not its to start, and a tasks list with `truncated=true` continues with `next_cursor`. A workspace whose `.masc/skills/work-intake` already holds a Skill without an installation receipt keeps that Skill; remove it for `masc init` or server start to install the builtin (#36502).
- Operator: tasks that only the operator can move are listed from one projection on three surfaces. A row is a cancel claim waiting for a verdict, with the producer's reason; a task `claimed` or `in_progress` under a name that has no Keeper queue, such as an ended MCP session; or a task whose producer's Keeper record does not decode. The TUI agenda strip counts these rows in the same waiting count as Keeper calls waiting on the operator, and its overlay adds a "Stuck on you" section with the five longest waits, how long each has waited, and a line counting the rest that names `masc_operator_digest`. `masc_dashboard`'s attention section lists the first two kinds as critical and the third as a warning, with the next step for each, and the web verify queue shows a cancel claim's reason on its card. A cancel claim submitted from this release keeps its reason in the verification record, which `/api/v1/verification/requests` returns as `cancellation_reason`; claims submitted earlier show no reason (#36513, #36529).
- Setup: `scripts/install-local-build.sh` builds `masc`, `masc-tui` and `masc-browser-host` from a source checkout, a worktree included, and installs them into `~/.local/bin` (`--prefix`). It then runs `install-host.sh` again with the new `masc-browser-host`, under the same host name, for every Firefox native messaging manifest whose launcher is a workspace's `.masc/browser-lane/host/launch`, and leaves other manifests alone. It also stops the host processes started from those workspaces, so the extension reconnects after five seconds and starts the new copy. With no registered host it installs only the binaries and says so. An unknown option is refused before anything is installed (#36576).

### Fixed

- Setup: choosing Claude Code in the first `masc setup` run from a terminal now completes the response and tool check. Setup runs each runtime's verification child in its own process group, which makes it a background job of that terminal. Such a child now reads `/dev/null` as standard input instead of the terminal. It is no longer stopped by `SIGTTIN` on its first read and then ended with `SIGKILL` before writing its report, which had left setup with only `Runtime setup did not finish`. The rule covers every child MASC starts in its own process group, through the Eio process manager or the Unix fallback: standard input that would be a terminal becomes `/dev/null`, and a pipe or file passed as standard input is kept. A child that has to read the terminal, such as the installer's prerequisite runner, stays in the foreground group (#36621).
- Setup: when setup still fails, the setup screen shows why. A failed stage validation or verification is summarised on one line that names the signal, such as `Runtime "ID" verification returned no readable report (killed by SIGKILL; REASON)` or `stopped by SIGSTOP`; a signal without a name is written `signal N`. The child's log goes to the `detail` field of the `masc.runtime_setup_error.v1` receipt, which neither the setup screen nor the runtime setup HTTP responses print. When the screen still cannot show the error sentence, it shows `Runtime setup did not finish (KIND)` with the receipt's `kind`, or `(exit N)` when the answer has no setup error schema (#36603).
- Skills: server start, and the probe commands that bootstrap a config root, only add builtin Skill packages: they install a package whose directory is missing and write a receipt for a tree that already equals this release. Replacing an unmodified package, retiring a receipted package this release no longer ships, and setting the release's permissions on an unreceipted tree whose files and bytes already match run only in `masc init --skills-only`; server start logs each as a pending warning naming `masc init --skills-only --base-path BASE` and changes no installed tree, so two binaries with different packages on one base path (a worktree build beside a release, an older release beside a newer one) leave each other's packages in place. Server start skips this pass when `MASC_CONFIG_DIR` is set or `MASC_CONFIG_BOOTSTRAP` is `skip` or `empty`. Server start takes the installer lock only when it has something to write and never waits for it: when another installation holds it, start logs that nothing was reconciled and continues. `masc init` and `skills-refresh --apply` wait for the lock and print which lock on standard error, and the installer script lets that line reach the terminal. Each package keeps one backup at `.masc/skill-packages/previous/PACKAGE`, which the next replacement or retirement replaces, and `skills-refresh --apply` says so when it prints the backup path. A replacement or retirement stopped at any step loses neither the installed tree nor the backup: a note under `.masc/skill-packages/moving/` records the tree being moved, `masc init` finishes or reports each note before it clears `.masc/skill-packages/staging/`, and a package whose note cannot be resolved is not replaced or retired. A package whose files do not match its receipt is reported as edited since installation or published by a replacement that stopped before recording it. Backups kept directly under `.masc/skill-packages/` by 0.35.17 are not moved or deleted (#36514, #36531, #36539).
- Keeper: a board comment notification row that reports `new_replies_since_own=N` carries `new_replies_comment_offset`, the `comment_offset` at which `masc_board_post_get` starts on the oldest of those N replies, with `oldest_new_reply_id` and `newest_new_reply_id`, in place of the `new_reply_ids` list, so the row stays the same size however long the thread grows. The replies counted are the comments after the Keeper's latest own comment in thread order, and board comments with the same timestamp are ordered by comment id, so every read of a thread returns the same order (#36504).
- Board: a `masc_board_post_get` comment page is sized to where its result goes: up to 65,536 bytes when a Keeper on an Agent-Core lane reads it, and 16,384 bytes for an official-client lane, a composition node, and MCP or HTTP callers. The page is text whose first line gives its range and where to continue, such as `[comments 0-11 of 40. Read the rest with comment_offset=12.]` or `[comments 12-39 of 40. No comments after this page.]`, followed by the thread. The same position is in the result metadata under `masc.comment_page`, and MCP results carry handler metadata in `_meta`. `comment_offset` and `comment_limit` must be integers, an integer-valued number such as `50.0` is accepted, and any other value is refused naming the argument. A reply nested deeper than five levels, or whose parent is not on the page, names its parent id. An offset past the last comment is refused with the thread's current comment count, and a TTL sweep's removals and lowered reply counts are written at the next board flush (#36518, #36556).
- Keeper: a composition argument outside a string parameter's `enum` is refused by Agent-Core's input-schema check with a validation error before any node runs, not with `argument_outside_enum`. An `enum` member that is empty, has leading or trailing whitespace, contains a line break or contains `|` is a load error, because a provider that cannot carry `enum` receives the members as `one of: a | b` in the parameter description (#36507, #36517, #36527).
- Keeper: a composition checks each node input made only of literals and parameters against that node tool's full input schema, `enum` and `const` included, before any node runs, so a `prior-art` call whose `query` is too long for the board search fails before the memory search runs; an input that reads another node's output is checked when its node runs. The MCP server's `tools/call` check and the dashboard schedule routes use the same Agent-Core check: a value outside a tool's `enum` or `const` is refused with `reason: invalid_args` before the handler runs, a property typed `["string", "null"]` accepts `null`, and an `integer` property accepts an integer-valued number such as `3.0` (#36543).
- Keeper: a failed `keeper_memory_write` or `keeper_memory_retract` returns to the model and does not end the turn, including a failure after the store committed. The failure result carries `effect_disposition` and a `what_committed` sentence chosen by the error kind:
  - for a refused input or a `fact_not_found` retraction, nothing was committed, and the retraction result also lists why the id may be absent;
  - for `commit_receipt_inconsistent`, a new revision was committed without the claim;
  - for `persistence_failed`, the write may or may not have committed and memory should be searched first. The sentence also says how a repeat behaves: for an ordinary fact, the same title and content make the same fact; for a source-bound one, the same `source_path` replaces that path's claim.

  A `keeper_memory_write` refused with `derivation_incomplete`, `derivation_invalid` or `unsupported_derivation` also carries `rejected_field` and `expected`. `rejected_field` names the field to change, `rule_id`, `premise_ids` or the element that broke the rule, such as `premise_ids[1]`, and `expected` says what that field takes. A premise that is not a memory identity is quoted back with the shape (`"sha256:"` followed by 64 lowercase hex digits), together with the note that `keeper_memory_search` and a successful `keeper_memory_write` return one. `unsupported_derivation` says to write the missing premises first, or to write the claim without `rule_id` and `premise_ids` (#36510, #36521, #36532, #36578).
- Browser: a browser host started without `--server`, `MASC_HTTP_BASE_URL` or `MASC_HTTP_PORT` reads the workspace port again after a failed request, stays on its current server while that server answers `POST /browser-lane/ping` with the lane token, and moves only to a server that answers; a host given any of the three keeps that address. A result the server answered with an error, 400, 413 and 5xx included, is not sent again and the host returns to polling; only a result that may not have reached the server is sent again. `install-host.sh` writes `launch.json` beside the launcher with `destination` and `launcher_sha256`, and the lane check reads that declaration: a launcher without it is `undeclared`, so a host installed by 0.35.17 needs `install-host.sh` run again and the extension reloaded. The `host` object on `no_live_client` and `selected_client_disconnected` carries `launcher`, `workspace_port`, `workspace_port_error`, `serving_port` (the port this server's listener bound), `polling_hosts`, `verdict` and `message`. `verdict` is `connected` while a host polls this server, `aligned` when the declared launcher's workspace port equals the bound port, `unverified` when no server in the process knows its port, as in `masc doctor`, `absent` when nothing is installed, and otherwise `misconfigured`; the dashboard onboarding check counts `connected` and `aligned` as satisfied and `unverified` as needing verification. A browser that disconnects after it was selected returns `selected_client_disconnected` with `clients` and `host` from BrowserTabs, BrowserRead in every mode and BrowserInteract (#36516, #36537).

- Browser: the MASC server starts and stops the automation lane's geckodriver itself. `[browser] geckodriver` in `runtime.toml` names the driver executable by absolute path, and `binary` requires it. `webdriver_url` is not read: a `runtime.toml` that sets only `webdriver_url` leaves automation off, and the server logs `automation has no browser.geckodriver`. One that also sets `binary` logs `browser.geckodriver is required when browser.binary is configured`, and automation stays off. The server starts the driver on a free loopback port with `--websocket-port 0` and `--profile-root .masc/browser-lane/profiles`. It waits up to 10 seconds for `/status` or the driver's exit, writes the driver's output to `.masc/browser-lane/geckodriver.log`, and records the driver's pid in `.masc/browser-lane/geckodriver-owner.json`. When the server stops, it:
  - closes the session;
  - stops the driver's process group;
  - stops by pid any browser still using a profile under that root, including a browser that relaunched itself outside the group after a crash (`SIGTERM`, then `SIGKILL` after 5 seconds);
  - removes the record.

  A server that finds a record left by a server that died stops that driver first, but only when the process table still shows the recorded executable at that pid. It then stops browsers still using the profile root, and only after that clears the root; when the process table cannot be read, the profiles are kept. So a session a dead server left open does not refuse the next server's `open` with `Session is already started` (#36594, #36612).
- Runtime: an OpenAI-compatible binding, such as `openai_chat`, `ollama` or `ollama_cloud`, whose model has no capability catalog window uses the `max-context` its `runtime.toml` row declares, reported with source `override`, instead of being clamped to 128,000 tokens; such a binding without `max-context` is refused when `runtime.toml` is loaded. Response telemetry's `effective_context_window` is the window the request was sized against, the configured `max-context` first and the model row's window otherwise, so the Keeper turn log's `context_max` and the dashboard's effective window are filled for these models (#36512, #36538).
- Runtime: on the antigravity lane, writing the prompt to the CLI runs inside the window the first read uses, which is the admission timeout capped by the wall-clock ceiling. When a CLI answers without reading a prompt larger than the pipe buffer, the turn ends with a timeout as that window closes, instead of being held until the CLI exits (#36595).
- Agent core: after a stream's first token, a `ping` event such as Anthropic's `event: ping` with `data: {"type":"ping"}` no longer restarts the inter-token idle budget, so a provider that keeps sending pings without producing output ends at the idle timeout instead of running until the turn deadline, one hour when the model sets no `turn-timeout-s` (#36557); and when the admission window is narrower than the first-event budget, the token count before a stream is timed on the admission window's clock (#36563).
- Server: when `runtime.toml` cannot be read or has no valid runtime, the model setup message ends with `Cause:` and the load error in the boot log, `/health`'s `model_runtime`, the `/api/v1/runtime/setup/resume` response, `keeper up` refusals and Keeper boot refusals; a failed resume replaces the cause with that attempt's error (#36533).

- Server: when its client closes standard input, `masc-stdio` flushes the board, runs its shutdown hooks and exits. It cancels the background lanes it started, such as the workspace memory curator, instead of staying up with no client (#36602, #36609).
- Server: exact lane run records are kept in `.masc/exact-lane-runs-v6.jsonl`. Each run's input and output are written first to `.masc/exact-lane-run-payloads/RUN_ID/input-SHA256.json` and `output-SHA256.json` with mode 0600, and the log row keeps each payload's size and SHA-256. A run detail read opens only that run's files, not the whole log. This covers `GET /api/v1/dashboard/exact-lane-runs/RUN_ID`, the TUI lane run detail and the Librarian input view. The read reports:
  - `missing_registration` or `missing_completion` for a missing file;
  - `source_unavailable` for an unreadable one;
  - `invalid_payload` for a file whose size or SHA-256 differs from the row, or that is not JSON.

  A run that retention evicts loses its payload directory. At server start, a replay that reads the whole log with no malformed line removes payload files that no retained row names. A replay stopped by a read error or a torn last line removes nothing. When a second registration under the same run id fails to append, the first registration's input stays readable. A run id that is not one plain path segment is refused before anything is written. `exact-lane-runs-v5.jsonl` is not read or converted, so runs recorded by 0.35.17 do not appear on the dashboard or in the TUI, and the operator can delete that file (#36596, #36613).
- Schedule: `masc_schedule_create` and `masc_schedule_update` take exactly one of `due_in_sec` (whole seconds from when the server runs the call, at least 1), `due_at_iso` or `due_at_unix`. Two or more are refused with `error_kind: "due_inputs_conflict"`, and none with `due_input_missing` unless a daily or cron recurrence derives the first due time, which it counts from the call; `requested_at_unix` is only recorded. A due input of the wrong type is refused instead of read as absent. `masc_schedule_update` refuses a changed due time before the current second with `due_already_past` and `stored_due_at_iso`, and accepts the stored due time sent back unchanged. A caller the MCP endpoint cannot name, with no `_agent_name` and no token, is refused with `caller_unidentified` for `owner=self` and for create, update and note add without `scheduled_by_id` or `author_id`. `masc_schedule_list` accepts `status=active` for every non-terminal status; a `limit` outside 1 to 200 on `masc_schedule_list` and `masc_schedule_notes_list` is refused with `argument_out_of_range`; and `next_cursor` is bound to the `owner`, `owner_name` and `status` it was issued for, so a cursor sent with other filters is refused with `cursor_mismatch` and an empty or unissued cursor is refused (#36547).
- Task: when a completion verdict rejects a submission whose producer has no Keeper queue, such as an ended MCP client session, the task returns to `todo` instead of staying `in_progress` under that name. It is released only while still `claimed` or `in_progress` under the producer, the release is recorded under the authority that judged it, and the handoff says why the task came back, with the rejection reason and verification id. The route is checked again under the backlog lock without rewriting any Keeper file, so a Keeper queue that appears in between keeps the task for delivery. A release that fails reading, writing or locking the backlog stays pending and is retried; one whose task id or authority cannot be used is dropped with an error log (#36500, #36552, #36555, #36560).
- Keeper: health is `healthy`, `idle` or `offline`: `offline` when the keepalive is not running, `idle` when it runs with no turn recorded, and `healthy` otherwise. The time since the last heartbeat line does not affect any of these:
  - health;
  - `next_action_path` and `recoverable`;
  - the surface status (`active`, `idle` or `offline`);
  - the TUI roster mark (`●` healthy, `·` idle, `×` offline, `○` paused, `-` unread);
  - `masc_keeper_list` rows.

  So a Keeper in a turn longer than six minutes is not reported `stale`. Keeper status JSON carries no `last_heartbeat`, `last_heartbeat_age_s`, `heartbeat_stale_after_s` or `heartbeat_observation_error`. Keeper diagnostics in `masc_keeper_list` rows, the dashboard and operator snapshots carry no `continuity_state`. Their `summary` is chosen from health alone, including in the first minute after a keepalive starts, and the dashboard's diagnostic chips and state label show health alone. The dashboard draws a Keeper's status from its registry phase: a `Running` Keeper shows as running, and `Crashed`, `Restarting` and `Failing` show those words. It has no heartbeat-lost badge or stale count, and takes activity times from the last activity, tool audit or turn. The TUI Overview has no inactive count. A `masc-tui` from this release refuses a keeper list that reports another health value, such as `stale` from a server still running 0.35.17 (#36548, #36549, #36550, #36590).
- Keeper: an interrupt ends a turn that is waiting for its own Keeper owner to answer, such as a turn that asked the owner to wait until it is idle, so that turn releases its slot instead of leaving every later message to report that the previous turn has not finished. Claiming the next chat operation still completes when an interrupt arrives, so the claimed operation is not left `Running` until the next boot (#36542, #36551, #36645, #36666).
- Keeper: a board attention worker that fails in the same scheduler pass as its lane stops logs its fatal error (`board attention worker stopped`) instead of the lane recording only a stop (#36572).
- Keeper: a microVM sandbox guest name is at most 63 characters, the limit Apple `container` accepts. A longer name keeps `masc-keeper-vm`, the network mode and the base-path hash, shortens the Keeper name, and ends with the first 16 hex characters of the full name's SHA-256, so one Keeper always gets the same name. A Keeper whose guest name used to reach 64 characters or more now boots, instead of failing every Read and Execute with `microvm_start_failed` and `is not a valid container ID`. Names of 63 characters or fewer and all Docker container names are unchanged. Every microVM start failure message begins with `microvm_start_failed:`, and a failed boot command reads `microvm_start_failed: boot exit=N: OUTPUT` (#36468).
- CLI: no command, server, installer or Keeper sandbox launcher reads or sets `MASC_BASE_PATH_INPUT`; the workspace comes from `--base-path` or `MASC_BASE_PATH` and then the current directory and recorded default, so every command and the server's guard choose the same workspace in one environment, and the start command the installer prints sets `MASC_BASE_PATH` alone (#36565).
- Server: a bounded wait that keeps an answer arriving as its window closes, as used by the server, dashboard, browser lane and host, HTTP client, LSP client, process waits and voice, counts its window from the call, including time the work spends before it first pauses (#36506).
- Keeper: on a long history, measuring the model input before each provider request reuses the size of a message measured earlier in the attempt, even when the request rebuilds the message records. Every checkpoint save of a turn, the save that finalizes the turn included, encodes and validates only the messages added since the turn's previous save, and the checkpoint bytes are unchanged. At the start of a turn, the walk over the history's tool calls reuses the fingerprints that Keeper's previous walk computed and keeps only the pairs still in its history. Before, a long history outgrew the 8 MiB table every Keeper shares, and most fingerprints were computed again (#36523, #36544, #36581, #36593).
- TUI: the Activity pane draws one row per Keeper turn instead of one `unsettled` row per provider call inside it, and finishing the turn settles that row. A long reply's stream frames do not split the turn back into unnumbered rows. `turn N` on this pane is always the Keeper turn number: Actions and Everything rows print no number for a call or for a turn start, ready or end, and the event detail labels the agent session's call ordinal `Agent session turn` (#36577, #36608).

- TUI: the `?` cheat sheet has `Prompt marks` and `Param marks` sections for the first column of `Config / prompts` and `Config / params`:
  - `*` your override, and an unmarked row is the file;
  - `⊘` saved but not applied, so the file is used;
  - `!` no prompt file behind the key;
  - `●` a value you set, with the default shown beside it;
  - `○` the registered default (#36615).

### Documentation

- Skills: the builtin `browser-lanes` Skill tells a Keeper to:
  - read a site reference again in a new turn;
  - use a site Skill listed separately in Available Skills together with the bundled reference, following that Skill where the two differ.

  Its connection reference says the server starts and stops geckodriver from `[browser] geckodriver`, so a Keeper does not start or stop the driver. `browser-live-follow-read` says a login page or an unrelated destination stays unverified, and a read that still shows the original URL or document means navigation has not happened. `browser-navigate-read` names `keeper_compose_browser-live-follow-read` only for when the tool list has it. The frontmatter description of both browser compositions equals their tool description, so `keeper_capability_search` shows the same text. `run-and-read` says `exit` is kind `exited` with a `code`, or kind `signalled` with a `signal`. `skill-authoring` says:
  - a composition checks literal and parameter inputs before any node runs;
  - the runtime puts the current time as `[Temporal]` in a turn's first provider request, and a request after tool results does not repeat it (#36499, #36505, #36543, #36594).
- Skills: `docs/guides/builtin-skill-updates.md` lists what `masc init` and server start each do per package state, and describes the backup, staging, move note and lock rules. `docs/SKILLS.md` says:
  - Agent-Core refuses an `enum` value outside the list, and names which members are load errors;
  - `[Temporal]` arrives in a turn's first request and not in a request after tool results (#36499, #36507, #36514, #36517, #36527, #36531, #36539).
- Browser: `connectors/browser/host/README.md`, `docs/design/browser-lane.md` and the browser lanes guide describe `launch.json`, when a host moves to another server, and running `install-host.sh` again for a host installed without the declaration. The host README also describes `scripts/install-local-build.sh`. The browser lanes guide (English and Korean), `docs/design/browser-lane-examples.md` and `docs/design/native-firefox-lane.md` set `[browser] geckodriver` and say the server starts the driver. `docs/design/native-firefox-lane.md` also describes the owner record, the driver log, and how the server stops browsers under `.masc/browser-lane/profiles` (#36516, #36537, #36576, #36594, #36612).

## [0.35.17] - 2026-09-15

### Added

- Runtime: a model row can declare `reasoning-uncontrolled = true` to send no reasoning control and leave the depth to the provider's default. On `ollama.com/v1`, which turns reasoning on when a request carries no `reasoning_effort`, a reasoning-capable model row must declare `reasoning-effort` or `reasoning-uncontrolled = true`: a row with neither is refused at request time with a message naming both, and a row with both is refused when `runtime.toml` is read. The shipped `ollama_cloud` rows declare `reasoning-uncontrolled = true`, so they send the same requests as before (#36412, #36424, #36438).
- Keeper: on an autonomous lane, a person's chat queued behind a turn that has not received its first streaming event takes the turn slot; the attempt yields without a checkpoint and its wake stays pending for the next cycle. A turn that has started streaming is not preempted (#36344).
- TUI: the help sheet explains the seven file marks the Code tree draws (#36381).
- Tool call log: a delegated image subcall's observations join the parent tool call, and each vision candidate attempt records a `started` row and, when the parent call is cancelled, a `cancelled` row with `reason: parent_cancelled` (#36361, #36406).
- Keeper: a composition Skill parameter declared `type = "string"` can list `enum = [...]`. The tool's input schema carries the values, a value outside the list is refused with `argument_outside_enum` before the plan is bound, and an empty list, a repeated value or `enum` on another type is a load error (#36482). The builtin browser compositions use it: `browser-navigate-read` navigates an automation tab and reads the landing page, and `browser-live-follow-read` follows an observed same-tab link in the live browser and reads the destination, each with a required `mode` of `scene` or `regions`. Their tool descriptions tell the Keeper to retry `BrowserRead` alone when only the read failed, that `follow_link` does not run page click handlers, and that a matching URL does not show the page is ready (#36484).
- Skills: six Keeper Skills ship as builtins. `run-and-read` (`keeper_compose_run-and-read`) runs one `sh -c` command line, waits up to `timeout_sec`, and returns the exit status, stdout and stderr in one call; a command still running at the bound is reported `timed_out` with its handle, and empty output then is not a failure. `prior-art` (`keeper_compose_prior-art`) looks one phrase up in memory facts (up to 5), library document titles and board posts (up to 10) in one call. `verify-before-claiming-done`, `root-cause-first`, `diagram-in-chat` and `skill-authoring` are instruction Skills for checking a completion claim against a command run just now, finding a cause before fixing, drawing mermaid diagrams the TUI renderer can draw, and writing a Skill the parser admits. `root-cause-first` carries a reference file adapted from obra/superpowers under MIT, listed in `THIRD-PARTY-LICENSES.md` (#36486).
- Keeper: a board comment notification row that reports `new_replies_since_own=N` also carries `new_reply_ids`, the ids of those N replies oldest first, so a Keeper can tell which of them it already read (#36485).

### Fixed

- Setup: bare `masc` opens the existing imp conversation when the only invalid check is the browser lane, such as a launcher pointing at an old port, instead of starting again at "1 · Your workspace". Checks imp needs, such as the model connection and the imp declaration, still send it to setup, and `masc doctor --json` reports the decision as `opening` (#36442).
- CLI: inside a workspace, `masc init`, `masc start`, non-terminal `masc`, the stdio server and the commands that share the `--base-path` option (such as `login`, `token`, `mcp-config` and `runtime-*`) use that workspace instead of exiting with `MASC_BASE_PATH is not set`. The workspace is chosen in one order: `--base-path`, `MASC_BASE_PATH`, a current directory that contains `.masc/config`, then the recorded default when it contains `.masc/config`. With none of them, the command prints the current directory, any recorded default it skipped and why, and the three ways to choose one; a relative path given while the current directory cannot be read is refused (#36447).
- CLI: `masc doctor`, non-terminal `masc setup` and `masc-tui` choose the workspace in the same order as `masc start`, so doctor and the setup screen suggest the workspace the current directory is in. `masc-tui` outside a workspace explains how to choose one instead of opening on the current directory, and non-terminal `setup` without a workspace is refused with the same guidance and a line to run `masc setup` in a terminal (#36448).
- Installer: only an install run from a terminal records the machine's default workspace, so a scripted install such as a release verification into a temporary directory no longer replaces `~/.config/masc/default-base-path`, and `masc setup` records it only from a terminal. The setup screen records a directory picked with "Choose another directory", so the next `masc` does not suggest `~/MASC` again when setup stopped at the model step; the installer suggests `$HOME/MASC` for a new workspace instead of `$HOME`; and a recorded default is used only when it contains `.masc/config` (#36450).
- Skills: server start and `masc init` reconcile the builtin Skill packages with the binary on every config root, including an existing one. A missing package is installed; an unmodified package with an installation receipt is replaced, with the previous tree kept under `.masc/skill-packages/`; a package whose files already match this release gets a receipt without file changes; and a receipted package this release no longer ships is moved under `.masc/skill-packages/`. A package edited since installation, one without a receipt whose files differ, and one that cannot be inspected are kept and named with a `masc skills-refresh` hint; a package without a receipt is never removed, and nothing deletes the kept previous trees. `masc init` prints one line per package, and when a package could not be reconciled it exits 1 and does not record the default workspace; server start logs the same lines, kept and failed packages as warnings, and keeps starting (#36488).
- Server: the fleet scan decides whether a keeper should run with the rule boot uses, so a paused keeper still holding a task no longer turns the fleet `degraded` with `active_task_owner_without_executable_fiber`. A task held by a keeper that boot skips (paused, autoboot disabled, manual activation) is an advisory `excluded_keeper_active_task_owners` row, and a keeper whose profile cannot be read is named in `active_task_owner_scan_errors` instead of being read as disabled (#36411).
- Schedule: `masc_schedule_create` refuses a due time before the current second, measured when the tool is called, with `error_kind: "due_already_past"`, `due_at_iso` and `now_iso`; a due time in the current second is accepted. Cancelling or updating a schedule that is running or finished is refused with `error_kind: "transition_refused"`, `current_status`, `attempted` (`cancel` or `modify`) and `last_wake`. `masc_schedule_list` requires `owner` (`self`, `wake_target`, `scheduled_by` or `all`, with `owner_name` for the two named ones) and refuses a call without it by naming the accepted values; it returns summary rows in `schedule_id` order, 50 by default and at most 200, with `next_cursor` while more rows remain, and `masc_schedule_get` returns the full request (#36480).
- Board: `masc_board_post_get` stops adding comments to a page before the result passes the inline tool result limit (16,384 bytes), so a long thread is read inline page by page instead of arriving as a stored blob. Each page ends with `[comment page: offset=… shown=… total=… next_offset=…]`, `next_offset=none` marks the last page, and a page after the first names the post in one line without its body. An offset below 0 or past the last comment, and a `comment_limit` outside 1 to 100, are refused with the thread's comment count and valid offsets. The `[N replies]` header counts the comments the read returns, replies nested deeper than five levels are drawn at the deepest indent, and the TTL sweep lowers a post's reply count when it removes a comment (#36483).
- Runtime: a stream ended because the model repeated one reasoning unit is reported as "model repeated itself" and attributed to the runtime binding, not as a provider wire error or a provider integration defect. Later candidates in the lane that serve the same model, matched by the served `api-name`, are refused before dispatch, so the lane moves to a different model (#36382).
- Keeper: `keeper_memory_write` and `keeper_memory_retract` are ordinary serial writes: a successful call lets the turn continue, and they can share a batch with other tool calls. A failure after the memory was stored still ends the turn, so the same memory is not recorded twice; a failure before storing, or one whose effect is unknown, returns to the model as an error. A successful result carries the committed snapshot `revision` (#36479).
- Keeper: a tool call whose handler declares progress does not count toward the five identical calls that yield the turn; `masc_msx_step` and `masc_msx_press` declare progress, `masc_msx_step_until_change` does when the screen changed, and `masc_msx_screen` does not (#36335); and after an autonomous cycle yields on a repeated tool call, the next cycle's loop guard does not count those judged calls again, so the first identical call of the new turn is not yielded (#36386).
- Keeper: while a turn waits for a bounded provider admission permit, the attempt watchdog does not count the wait as no progress and measures silence from the moment the wait ends, so a turn queued behind another keeper's stream ends as a `Queue` timeout at the admission bound (#36331, #36334); and a permit is returned when its holder is cancelled while another domain holds the scheduler lock, which could block a one-permit endpoint with `MASC_SERVING_DOMAIN_ENABLED` on (#36350).
- Agent core: on bindings that count tokens before sending (Anthropic, Kimi, models with serving constraints), the count-tokens permit wait and round trip ahead of a stream run within the stream's admission and first-event budgets and end as `Queue` or `First_token` instead of waiting for the keeper watchdog; the measurement and the completion after it spend the one call and admission window the route opened; and a stream request over the context that also used up the window ends as `ContextOverflow` instead of a retryable timeout (#36321, #36393, #36444, #36449).
- Agent core: a 4xx or 5xx refusal whose body does not arrive within the window keeps its status and `Retry-After` on both the stream and sync paths, instead of becoming a `First_token` or `Wall_clock` timeout (#36326, #36338); and the missing body is classified `Refusal_body_not_received`, which is retryable, so the keeper rotates to the next candidate instead of ending the turn (#36415).
- Agent core: a non-streaming completion applies the provider's `connect-timeout-s` to the connection, request and status line, and ends as an `http_operation` timeout against a server that accepts the connection and never answers (#36355); and an idle stall after an Anthropic text block closes is reported as `streaming_answer`, not `streaming_tool_call`, without counting a completed tool call (#36368).
- Agent core: a provider response, count-tokens answer or explicit-deadline HTTP answer (model lists, provider files, image and voice generation) that arrives in the same scheduler pass as its deadline is the result instead of a timeout, and an attempt that finishes as the watchdog judges it stalled keeps its answer (#36340, #36428); response headers returned as the pre-header window closes are used, and a refusal body already buffered with them is read (#36414); and a stream line already received when the read budget closed is read, including one still held in the HTTP client's buffers such as a first event that came in the same chunk as the headers, while a line the read had to wait for is not (#36423, #36478).
- Keeper: a result that arrives as its wait ends is kept for an official-client (Claude Code, Codex app server, Antigravity) wire line at the idle window (#36364); a child process that exits at its timeout or during its TERM grace, which was reported as a timeout or killed (#36373); an owner response, or a command handed to the owner, as the owner closes (#36374, #36436); and an operator approval at its timeout, an Antigravity answer as an abort arrives, a librarian lane drain and the backend key index (#36376).
- Server: work that finishes as its window closes is kept for proactive refresh, the operator digest and snapshot, dashboard partial responses, namespace truth, link previews and the boot dashboard pre-warm; an execution surface refresh no longer overwrites a recorded success with a timeout error, the execute-output SSE stream no longer drops an event, and the IDE LSP proxy no longer reports an initialized language server as failed (#36432). Spawned program waits, LSP workspace answers, egress proxy request heads, `masc runtime-verify` and the local runtime compatibility check no longer report a finished result as timed out (#36431), and `masc runtime-verify` starts the runtime through the process manager the server uses (#36387). `masc setup` no longer reports a server that became ready at the window edge as not ready, and an OTel export the collector accepted at the window edge is not sent a second time (#36436). A forced execution surface refresh that already published its result keeps it when rebuilding the response body afterwards fails or runs out of time, and a parameterized operator digest request that runs out of time keeps serving the last good digest instead of serving `{"error":"timeout"}` from the cache for 60 seconds (#36495).
- Dashboard: a compute or render that finishes as its window closes is returned, so a panel whose compute lands on the window edge no longer opens its timeout circuit or shows "render timed out" (#36416); and `/api/v1/tool-metrics` and the runtime info screen no longer carry the `runtime_metrics` list, which was always empty, or export the `masc_runtime_metrics_eviction_total` and `masc_runtime_audit_failure_total` counters, which nothing incremented (#36453).
- HTTP client: a request, response body or new connection that completes as its window closes is used instead of reported as `timeout`, `idle timeout` or `connect timeout`, so identity tools such as GitHub and Slack writes no longer report an answered call as outcome unknown; the sync entry points apply the pool's one request window (#36359, #36396).
- Browser: an answer or command that arrives as its window passes is kept by the browser lane, where a command taken at that moment was dropped (#36363); by the native messaging host, where an extension reply sent at its `deadlineMs` was replaced by "extension reply timed out" (#36401); and by the Firefox BiDi peer and downloads session, which disconnected on such a reply (#36433). A BiDi WebSocket upgrade the peer refuses, or a handshake that does not finish in its window, is a connection error instead of an uncaught exception that ended the host (#36473), BiDi metadata past its window is a named host error instead of a stack trace (#36401), and the host no longer exits 0 without a reason when Firefox closes stdin as the server refuses the poll (#36419).
- Browser: `connectors/browser/install-host.sh` writes a launcher without `--server`. A host started without `--server` or `MASC_HTTP_BASE_URL` reads the port from the workspace `connection.toml` again after a failed poll or result request, so it reaches a server that restarted on another port without reinstalling; a host given either keeps that address, and a launcher installed with a fixed port keeps it until `install-host.sh` is run again and the extension is reloaded. When no browser can take a command, BrowserTabs, BrowserRead and BrowserInteract return `no_live_client` when none is connected, `selected_client_disconnected` when the chosen `clientId` has gone, and `ambiguous_browser_clients` when several are connected and none was chosen. The first two carry a `host` object (`launcher`, `launcher_port`, `workspace_port`, `verdict`, `message`) with the cause `masc doctor` reports for the same launcher, such as a port that differs from the workspace, and a `retry` sentence saying only the operator can change it. BrowserRead in `scene`, `regions` and `screenshot` mode reads only the browser it selected (#36481).
- Voice: a Voice MCP answer that arrives as its window closes is the answer, so endpoint failover no longer speaks the same sentence again on the next endpoint (#36397).
- Config: a stream idle or first-event budget above 3600 seconds is refused where it is read, naming the `provider_call_deadline_sec` ceiling that has to cover it, instead of being refused at boot (#36342); and an out-of-range keeper timeout refusal quotes the value as written, so `29.9999999` is no longer shown as `30` (#36369).
- Exec shim: the sandbox probe reports seccomp user notification on an unprivileged Linux host that supports it, instead of reporting it unavailable (#36319).
- TUI: the empty Schedules list says `press n to create one` (#36446); the keeper chat row for a request the server has not accepted says `sent; not accepted yet` instead of `waiting for the run to start` (#36456); and the feed status reads `closed N`, where N is the frame count, instead of `closed after N` (#36389).
- TUI: the help sheet names the Schedules surface `Schedules` (#36375), lists all nine Keeper detail tabs (#36362), lists `a` for answering a Keeper's question on Approvals (#36358), and keeps the lane configuration reference under `e` instead of on every lane's detail pane (#36370); and its key column is measured in terminal cells, so mark meanings start in one column (#36324).
- TUI: the Activity title drops its dot when the tab strip draws nothing (#36439); the Standalone lanes heading keeps its observed time at narrow widths (#36417); the Config paths row writes a masc root under the base path as `<base>/.masc` (#36354); the Config title yields to the tab strip so the current pane name is not cut (#36327); Planning's Backlog says `in_progress` (#36356); Board heading rows draw a hint whole or not at all (#36341); the Approvals meta row draws `expires` in the terminal's time zone like `created` (#36357); the asks refusal names its surface once (#36352); and a labelled field reads `load failed` or `not loaded` without brackets (#36320).

### Documentation

- Install: README and INSTALL state the workspace order (`--base-path`, `MASC_BASE_PATH`, a current directory with `.masc/config`, then the default recorded from a terminal; parent directories are not searched), the installer's suggested path and when a default is recorded, and that the arrow-key setup screens cancel with Ctrl-C while `q` types into the filter (#36450, #36451).
- Skills: the web UI design, implementation and verification guides are one `frontend-change` skill; the Slack and public social site guides are site references inside `browser-lanes`; and the MSX observer add-on's skill is named `msx-observation-rows`, so installing the add-on no longer leaves it hidden behind the built-in `msx-observe` (#36460).
- Skills: `docs/SKILLS.md` says when work belongs in a Tool, a composition Skill or an instruction Skill; that a Keeper sees a composition's TOML `description` and parameter descriptions but not the SKILL.md body; that a node input left empty takes the tool's defaults; that a fence syntax error, a second fence or a rejected composition plan creates no tool and leaves the body as an instruction Skill, with the reason in `/api/v1/skills`; and how a string parameter declares `enum` (#36482, #36486). `docs/SKILLS-FLOW.md` describes creating a Skill with `c` or `C` on the TUI Tools screen (#36486).

## [0.35.16] - 2026-09-14

### Added

- Browser Lane: observed landmarks carry a closed semantic role with unknown roles kept explicit, and scene nodes keep their nearest observed article or main ancestor, which the TUI draws as a compact `[article] Label` boundary and copies with the element context (#36013, #36045).
- Browser Lane TUI: `N`/`P` move between observed article regions, from the regions scene and from the content scene through article ancestors, and boundaries show each article's ordinal (#36029, #36067, #36068).
- Browser Lane TUI: `J`/`K` scroll the page from the text reader with URL and document identity checks, an observed tab can be opened directly instead of cycling, and a refreshed scene shows its scroll offset and what changed since the previous observation (#36016, #36069, #36070, #36071).
- Browser Lane TUI: the scene text renders observed heading levels, keeps block spacing, joins inline fragments of one block into one row, keeps the selected region's role and label through scroll, click and copied context, and the status line counts articles, other regions, links, controls and images instead of raw nodes (#36040, #36042, #36044, #36061, #36036, #36038).
- Goals: `masc_goal_list`, `masc_goal_transition`, `masc_goal_upsert` and the goal HTTP routes answer an unreadable goal store with a typed `goal_store_unavailable` error instead of an empty list, `not_found` or an internal error (#36060).
- Lanes: the overview draws lanes as one header row and measured columns, so failure counts stay on screen beside the Activity pane (#36062).
- TUI: the `:` palette reaches Runtime, Changes and every Config pane (#36095).
- Lanes: the TUI guides subscribing a Keeper to retained output references and shows the output position each subscription has acknowledged (#36007).
- Runtime and Lanes: both screens share one three-tab console of Keeper Lanes, All Runtimes and Standalone, matching the `p`-key cycle; lane rows draw their fallback tree with the sticky winner marked, keeper assignments and live telemetry lead the detail column, and the Keeper list and detail show the assigned runtime target, the model context and an inherited default (#36107, #36120).
- TUI: the keeper runtime picker assigns a lane and a model (#36099).
- Voice: the voice pane gives a keeper its own voice (#36109), and the setup wizard offers `say` and `whisper-cli` (#36115).
- Dashboard: an unreadable goal store is parsed as its own type, shows as an alert and locks the creation form instead of rendering an empty list (RFC-0444) (#36089).
- Lane workspace: the five-view workspace is promoted, and add-on inspection takes the focus pane (#35761).
- TUI: user input is auto-promoted to the next turn, and a shortcut inspects the input queue (#36123).
- Keeper: pending inputs are organized into Librarian working contexts (#36142).
- Browser Lane: the lane host follows the workspace connection port (#36133).
- TUI: the transport list has a way in again (#36217).
- TUI: the progress row opens with what the model is doing now and how long it has been silent (#36192).
- Keeper: the prompt and the goal verifier name an unreadable goal store with its reason and file (RFC-0444) (#36126).
- Agent core: a caller's call deadline reaches the Sync pipeline's admission wait (#36223), a stream's admission wait is bounded and named `Queue` (#36232), and the phase before the response headers runs under the first-event budget, connection included (#36204).
- Schedule: a new occurrence supersedes the schedule's earlier pending occurrences in the keeper queue (#36230), and pending occurrences of one schedule collapse into one queue row (#36222).
- Lanes: the DOS chain packages declare the binding contract their installer and workers already require (#36237).
- TUI: the `/queue` snapshot reads as a timeline with ages, spans and the reason nothing drains (#36226).
- Lanes: `e` freezes the marked lane rows and names the Keeper that receives the reference (#36248).
- TUI: a press opens a call from the Activity pane, and the row marks how that call was dispatched (#36255).
- TUI: a skill row says how far the skill got, and the help sheet explains every chat mark (#36268).
- Exec shim: the sandbox probe reports whether seccomp user notification is available (#36229).

### Fixed

- Keeper chat: Esc cancels the exact request that owns the turn, including one stalled in its HTTP reader, and Enter submits an interactive update in one admission instead of needing a separate priority command. Waiting inputs run together in accepted order, a stop acknowledgement still pending holds new input, and a reconnect does not repeat a control effect (#36035).
- Keeper chat: `/queue` shows waiting inputs with sender and order and can pause, resume, edit, cancel and reorder them; an edited input keeps its identity and the media it was sent with. A cooperative continuation keeps its original identity, and Codex and Claude sessions carry updated instructions without losing their vendor session (#36035).
- Runtime: an Antigravity tool step that runs longer than `turn-timeout-s` completes instead of ending the turn; the wall-clock ceiling still bounds it (#36056).
- Keeper: the Codex app server, Claude Code and Antigravity runtimes return a served turn without waiting for a background child to release stderr, which an orphaned MCP server could hold open indefinitely (#36017).
- Keeper: a long Claude Code turn is no longer ended as a protocol error after 256 informational frames, or 32 before admission; the idle and wall-clock deadlines bound the turn, and an unknown frame type is still refused (#36019).
- Keeper: a failed stream is reported once. A stream timeout quarantines its open tool block like every other attempt failure, an incomplete or repeating stream no longer adds a second diagnostic, and a close cancelled while the event bus is full leaves the bus closable (#36027, #36048, #36024).
- Keeper: a keeper with no `keepers/<name>.toml` fails to load with `Declaration_not_found` instead of booting on empty defaults, and a `tools.deny` entry that names no model-visible tool refuses the load instead of logging a warning at turn setup (#36066).
- Runtime: a Gemini or Vertex Gemini provider's capabilities are looked up only under its declared provider id. An operator's own catalog row is no longer hidden by the bare `gemini` row, and a Gemini provider with no row of its own now stops at the boot capability check like every other API format instead of borrowing that row (#36080).
- Anthropic: a model with no thinking policy in the catalog or manifest is sent as having none, instead of being given the adaptive default policy (#36081).
- Runtime: setup reads `masc runtime-verify` output through the verification type instead of comparing string fields, and keeps the reason a verification child process failed (#36065).
- Sandbox: a declaration error says whether `imp.toml` could not be read or is invalid, with the underlying reason, instead of one of two fixed sentences; a microVM profile that names no backend is refused rather than given `Apple_container` because of the host (#36053).
- Keeper: a lifecycle reservation that is gone when a removal releases it is reported as a removal conflict rather than as removed (#36033).
- Capability vocabulary: the six single-value parsers refuse the empty string instead of reading it as a value (#36034).
- TUI: tab strips keep the current entry on the row when entries overflow, and the Memory category row is drawn with the same strip (#36021, #36051).
- TUI: control keys, the tool approval mode and a schedule's wake status and actor kind are spelled the way the key table and the server contracts spell them (#36037, #36031, #36008, #36004).
- TUI: the Board draft footers come from the key table and its pane row stays on the draft; the Task Review title states a full page's count once; the Planning rollup counts only phases that have goals (#36049, #36047, #36015).
- TUI: the Fusion detail footer names `K` and `B`, which the detail already answered, and the run list row states only the run's own progress, failure or retained evidence (#36055).
- Browser Lane TUI: a paragraph with two or more inline elements reads as one row again (#36077).
- Setup: the web configuration's connection kind is a typed provider variant, and a route's status code is decided from the typed error rather than from a string table (#36082).
- TUI: the Board read keys are on the footer instead of a second row inside the post, and Code and Resources put their gap row above the title the way every other screen does (#36088, #36076).
- TUI: the Approvals title counts only the kinds that have rows; a verification request's Created uses the terminal clock and its reading note wraps; a keeper's Last 24h draws no zeros when no metrics rows were read; the Memory detail blocks start their values in one column (#36079, #36064, #36085, #36083).
- TUI: the Overview names its cluster and project without padding, the Config paths row keeps the binary age and the tail of each path, and the acting pane stays off both Activity tabs (#36012, #36025, #36018).
- Voice: each endpoint is asked for its own model, a provider model id for `elevenlabs_direct` and `openai_compat` and a ggml path for `whisper_cli`, so one workspace can mix local whisper with a remote endpoint; `voice-local-setup` no longer refuses the mixed setup, and the wizard no longer rewrites the model an existing endpoint was receiving (#36098).
- Keeper: a provider sub-call runs under the keeper's no-progress threshold (#36094), and the Codex idle window stays off while a tool item is open (#36086).
- Tool call log: a read index that cannot be opened is an error, not an empty list (#36091).
- Browser: an unsubscribed BiDi event, a frame without its source context, and a first-tab guess are refused instead of accepted (#36052).
- Dashboard: the stream protocol's error kinds are one list held equal to the backend's (#36026).
- TUI: the Fusion title leaves a running count of zero out; the Schedules count and the next wake share one row; and Planning names the goals that left the list with no outcome (#36111, #36104, #36118).
- TUI: Clients, Connectors and the Activity feed name their columns in capitals, and the Activity pane waits for a row that uses its column names before drawing them (#36103, #36100).
- Setup: a failed verification prints its own reason, the failure code and the client's account of what it looked for, and Ctrl-C leaves the wizard as a cancelled setup with existing connections preserved instead of a traceback (#36151).
- Gate: a sandbox's refused rule is carried as a typed reason instead of stderr text (#36032).
- Agent core: the first-event budget is one window to the first token (#36149), and the budget stays armed until the first token-bearing event (#36114).
- Keeper: the interrupt token names the child that holds the turn slot (#36014); a chat stop cancels the turn and nothing else (#36005); and control yields only to ready queue successors (#36130).
- Keeper chat: the quiet leave belongs to the chat surface (#36132), and a section the pane could not read is reported as unread rather than drawn as empty (#36135).
- Voice: the setup wizard writes the voice where the section can read it (#36124).
- Streaming: the parser reads only the reasoning members the catalog declares (#36139).
- Verification: unread image artifacts stay in the verdict record (#36127).
- MSX: press fields are parsed at the boundary and the presser comes from actor auth (#36128).
- Keeper chat: Enter queues the line to run next instead of interrupting the running turn (#36209), and the chat operation store waits out a concurrent writer instead of letting one SQLITE_BUSY fence chat for the rest of the process (#36218); an unavailable store is retried at the next command or meta commit, not only at a drain wake (#36187), and an idle wake reopens the store and clears the fence (#36165).
- Keeper: an operator interrupt of the autonomous turn is a typed outcome instead of a keepalive fiber crash (#36172); a timed-out write is not offered for a blind retry (#36162); a reasoning delta counts as progress to the attempt watchdog (#36169); a reasoning block that chants one unit ends the stream (#36193); the provider-call no-progress threshold has a failsafe floor (#36181); and a call deadline bounds the wait for an admission permit, which the keeper sub-call uses (#36157).
- Keeper: a Failing-phase keeper is a running keepalive rather than an offline one (#36207); the identity transports are built from a clock and the MCP session runs under the keeper threshold (#36141); and a program-defined native posture no longer reads a keeper declaration (#36147).
- Runtime: the verify command's timeout reaches the HTTP arm (#36212); the two opt-in deadlines are read live and reject malformed values, and the probe CLI applies runtime.toml (#36164).
- Notify: the mention notifier is one bounded process, found without a probe (#36176).
- TUI: guided Lane operations are restored in the workspace (#35999); live replies are shown for promoted queue requests (#36159); a running turn always has a stop handle (#36030); and the chat header writes `gate: ` with the space its row uses (#36112).
- TUI: the Keepers title says whether its reading is live (#36216); the Lanes failure row says what failed once (#36211); the empty-page note stops repeating the verdict above it (#36208); the diff pane draws the same failure note as every other page (#36201); the Schedules list names its six columns above them (#36191); the Attention panel's empty note starts where its rows do (#36171); Task Review draws its header and rows from one column set (#36168); the Clients title walks its path with one separator (#36163); and the footer keeps the key that opens a row, not only the ones that leave (#36156).
- Agent core: an https host is a TLS peer by name or by address, never nameless (#36238); the reasoning repeat rule reads 64 KiB and a miss keeps its window (#36231); and `call_timeout_s` is declared everywhere the runtime config record lives (#36228).
- Lanes: an action commits its package output once and no longer forces a second observation (#36227).
- TUI: a slash command's usage wraps on the cheat sheet instead of being cut (#36234), and a labelled field reads the failed word from where the title does (#36225).
- TUI: the active runtime row states its one timestamp once (#36155); the Context row stops opening with the word its label already said (#36152); the Activity legend stops naming a mark no row draws (#36148); the screen says its timezone once, not on five rows (#36143); and the Overview names each transport path once, marking the one in use (#36136).
- Agent core: a slot granted in the same instant a waiter's deadline passes is owned by that waiter instead of dropped, so an endpoint declaring one permit no longer stays saturated for the life of the process (#36279); and a refusal's body is read inside the pre-header window (#36261).
- Keeper: a process with no clock refuses the attempt in the name of the deadline it could not set (#36257); a no-progress threshold shorter than a stream budget the operator declared is refused, while a floored budget is left as the ceiling it is (#36265, #36275); and an out-of-range keeper timeout is refused rather than clamped, so an env override and `runtime.toml` give one answer (#36286).
- Keeper Owner: metadata faults and operation-store faults hold separate slots, so an operation store under repair no longer refuses the keeper's own metadata commits (#36270); and fence recovery reopens under a non-chat child, not only when idle (#36260).
- Runtime: `runtime-verify` installs the process clock its deadlines need, so a verification request carrying a body deadline is no longer refused as unenforceable (#36287); and the verify command bounds its HTTP arm on its own clock (#36263).
- Schedule: one call cancels every pending occurrence of a schedule (#36254), and a `delivery=none` interval wake reads its own clock so occurrences follow consumption (#36249).
- Keeper: `run_named` injects the stream idle bound itself (#36250), and a redacted thinking block counts as production rather than a carrier frame (#36271).
- Keeper: a chat request the restart cut off leaves a failure row in the transcript (#36291); the transcript window trims old tool rows, never the conversation (#36292); and `run_named` reads the body-timeout override itself (#36293).
- Agent core: the first-event budget is one window from the request (#36289), and an idle gap after the first output keeps its state and its telemetry (#36283).
- Tasks: new tasks are named in the list page and the keeper frame (#36273).
- TUI: modal page keys move by the window height (#36304); the Activity row keeps the filter that makes Enter mean something (#36301); a rejection the server answered is not reported as a lost connection (#36300); the Runtime row leads with the lane fact, not the keeper assignment (#36288); the Lane Add-ons and Connectors footers name the keys those surfaces answer (#36295); and a tab strip draws no wider than the width it was given (#36290).
- Lane add-ons: the package preview reads only manifests inside the workspace (#36269).
- Dashboard: the keeper runtime panel stays on screen when the server reports fail-safe floors (#36247).
- TUI: the Metrics safety block says what failed once instead of twice (#36253); an opened call's facts row leads with the disposition and fits the pane (#36262); the Planning title keeps its clock and badge (#36264); and the title's tab strip leaves room for what sits to its right (#36246).

### Documentation

- Browser skills route read-only public social pages through TUI scenes and keep live region composition free of site-specific instructions (#36022, #36041).
- Keeper: the pre-dispatch profile load no longer promises empty defaults for a missing keeper declaration (#36078).

## [0.35.15] - 2026-09-13

### Fixed

- Keeper: a refused Gate binding is reported as bad input rather than a broken store, a resumed native thread is not rewritten on every turn, and the Gate's original source is restored exactly after its store comes back (#35720, #35719, #35748).
- Keeper: interrupted manifest and runtime assignment writes are recovered, the sandbox is asked for a bounded read instead of trimming a whole file, and peer artifact export has a size limit (#35366, #35675, #35718).
- Composition continues after a read failure that was durably recorded (#35703).
- Server: dashboard observations no longer spend the agent operation quota, and every quota call site names its classification. A lease whose recorded process is gone says so (#35724, #35839, #35596).
- Runtime: a provider that needs no key is told apart from one with no catalog entry, anonymous discovery endpoints are told apart from unknown providers, and runtime files resolve from the admitted canonical base (#35715, #35767, #35794).
- `masc runtime-verify` passes a secure random source to Antigravity readiness checks, which failed without one; the argument is now required (#35899).
- HTTP client: pool error messages keep an Eio error's context on one line (#35831).
- Fusion: runs include the active Task contract and Goal criteria by default, original deliberation is retrieved by canonical run id, and a decision names only the Task its run was requested for (#35501, #35511, #35843).
- Verifier: review tools are confined and original PDF inspection is bounded (#35387).
- Voice: setup no longer overwrites per-Keeper voices, configures hearing as well as speech, and a second `voice-local-setup` run keeps the voice where the first put it. `voice-verify` works with `--base-path` (#35725, #35775, #35787, #35795).
- Voice: an endpoint's declared kind chooses its transport, so an id that spells another provider's name no longer reaches that provider (#35526).
- Voice: `voice-verify` and `voice-local-setup` refuse a `say` voice this machine does not list; `say` itself speaks in another voice without failing (#35870, #35874).
- Voice: whisper-cli rejects audio it cannot read before running, naming the format; the dashboard microphone uploads 16 kHz mono WAV so whisper-cli workspaces transcribe it; a clip is labelled WAVE or MP3 by what it is, and a reply that played nowhere is reported as synthesized rather than spoken (#35800, #35806, #35717, #35827).
- Voice: a command that could not run is no longer reported as not installed, running `voice-local-setup` before `init` explains itself instead of printing a raw `Sys_error`, a padded endpoint id names the endpoint it removes, and a hearing plan includes the recorder it needs rather than only a transcriber, naming it when it is missing (#35749, #35763, #35732, #35733).
- Browser: malformed arguments are input failures, a followed document is read after Firefox commits it, screenshots stay current while gestures are preserved, and the viewport follows shared-tab navigation (#35682, #35771, #35704, #35708).
- Release: Linux lifecycle evidence runs in the build container, and native Lane composition stages its Python resources (#35696, #35766).
- IDE: the loaded activity window is distinguished from the workspace total, and conversation sources survive a failed refresh (#35667, #35664).
- Bench: an unpriced Keeper turn is counted, not treated as free (#35835).
- TUI: pressing Ctrl-Y (speak) on macOS no longer kills the TUI (#35849).
- TUI: observed work can be stopped and my queued message put first, active Keeper work shows behind queued chat, `send_on_stop` sends from the chat pane, and the first quit key names the unsent messages a second press drops (#35653, #35635, #35854, #35858).
- TUI: a list that was not read, or whose read failed, no longer reads as empty or quiet: Keepers roster, agenda, answering panel, Browser Lane picker, Resources, Keeper Runs, Tools, Overview Pulse and Attention, Metrics memory health, presets, Config titles and Board (#35756, #35804, #35805, #35829, #35832, #35852, #35884, #35890, #35861, #35897, #35900, #35822, #35797). A refused read shows the server's sentence rather than its raw body (#35873).
- TUI: footers, hint rows and the cheat sheet take their keys from the key table and spell them the same way (#35638, #35734, #35759, #35774, #35807, #35418, #35842, #35844, #35848, #35859, #35877, #35878, #35879, #35876, #35903, #35905, #35830).
- TUI: overlays, pickers and panes draw through the shared surface and overlay frame, and tab strips draw one way (#35792, #35812, #35847, #35863, #35868, #35869, #35871, #35825, #35856, #35810).
- TUI: timestamps and last-seen times read in the terminal's zone, a Board post with no time has no age, and ages past a hundred days keep the day count in six cells (#35888, #35893, #35886, #35891).
- TUI: a manual refresh keeps the readings and scroll on screen, list selection stays visible across resizes and mode changes, the Memory facts selection stays inside the drawn viewport, expanded tool details stay expanded across a refresh, Esc on the Memory table clears its filter before leaving, a retry on a direct image link drops the body it cached, the Code file pane asks for the directory it moved into, palette slot answers are read rather than typed, the palette lists each destination once, the themes and models lists take the page keys, and the TUI and setup keep why a server they started exited before it was ready (#35914, #35908, #35909, #35907, #35841, #35836, #35821, #35779, #35846, #35902, #35864).
- TUI: the chat header separates phase from runtime, `/about` states only what it was given, `/burn` shows cost, a conflict warning leads the footer, counts use one pluralisation helper, and the truncation mark is one mark that keeps the port in diagnostics (#35802, #35798, #35865, #35862, #35867, #35396).
- TUI: row counts in Task Review, Changes and Logs match the rows drawn; copied context includes the selected browser target action; the cheat sheet wraps an entry instead of cutting it, puts each section title above its keys and uses one heading style; smaller label and layout corrections across Activity, Keepers, Planning, Goals, Memory, Code and Browser Lane (#35790, #35686, #35896, #35786, #35818, #35731, #35769, #35776, #35840, #35850, #35851, #35872, #35881, #35882, #35883, #35892, #35895, #35722).
- HTTP pool: preserve DNS/TCP failures under one connection deadline, reclaim failed or cancelled client sockets, and connect through the address that passed the TCP probe without pinning later DNS reconnects (#35381, #35389, #35394).
- HTTP pool: propagate internal client-scope failures to buffered and streaming request waits instead of leaving callers waiting for an optional timeout (#35423).
- Installation: keep the selected workspace across working-directory changes, preserve the existing default when server startup fails, and leave unrelated defaults intact during purge (#35376).
- Keeper: constitution tools return the standard `ok` response envelope used by other tools (#35451).
- Keeper: time spent running tools or delegated image analysis is no longer attributed to a silent parent provider; inference monitoring resumes when the provider lease is reacquired (#35454).
- TUI: terminal and superseded tool calls no longer remain waiting for a result. The header distinguishes the observed turn runtime from configuration and clears stale runtime identity at a new attempt (#35455).
- Runtime loading keeps typed configuration failures through to doctor diagnostics (#35378, #35417, #35435).
- TUI: preserve critical Attention text, avoid empty source hints, clarify schedule failures, and use consistent footer/help key labels (#35411, #35421, #35430, #35436, #35439).
- TUI: replace the Keepers screen's orphaned bottom box corners with a section divider (#35414).
- Chat: persist tool execution results before completion events and refuse stale cached or trace-only output when exact result retrieval fails (#35919, #35924).
- Keeper: pause admission when interrupting chat, and allow cancellation during official-client MCP tool dispatch (#35928, #35936).
- Agent core: use the same provider-turn ordinal in hooks, tracing and diagnostic logs, including resumed turns; avoid duplicate INFO completion records (#35348).
- Keeper: treat inventory shutdown as a normal shutdown boundary, and describe scheduled verification retries accurately (#35347, #35352).
- TUI: open the original page URL when an inline image cannot be drawn; retain cached input after converter failures and offer an explicit retry for refused previews (#35346, #35349, #35525).
- TUI: finish known-lost-terminal cleanup without further terminal output, keep Git overlay scrolling within its geometry, and draw dividers using the terminal-aware palette (#35345, #35351, #35463).
- TUI: distinguish Memory loading failures from waiting and name fields rejected by strict response decoding (#35457, #35460).
- Board: relay MSX events on media changes and include verification identity in verification post titles (#35350).
- Keeper: attribute failed cycles to the dispatched runtime candidate and distinguish verification retry from terminal stop causes in logs and Board reports (#35353, #35354).
- Schedules: reject due wakes whose owner is absent from the authoritative Keeper store (#35361).

### Added

- Voice: an endpoint is asked which voices it has (ElevenLabs over HTTP with every catalogue page under one deadline, `say` through its own list), and the TUI voice pane names the endpoints it has (#35483, #35437).
- Voice: setup asks for a voice during installation, with voice that runs without a server; a probe names the voice it asked for and can probe as a Keeper (#35631, #35665).
- Verifier: a configured official-client verifier runs the selected direct runtime for completion verification, without expanding a same-named lane or falling back to another runtime (#35372).
- Verifier: original MP4 streams with full decode results, original PPTX slides, notes and rendered pages, and original Board and Fusion sources can be inspected (#35532, #35578, #35536).
- Setup: PDF tools are installed and checked as prerequisites, and workspace presentation dependencies are prepared (#35409, #35565).
- Keeper: a direct execution held at a Gate continues in its original official-client session (#35742).
- Vision: declared official-client image candidates are supported (#35405).
- Memory: a workspace curator runs after committed memory changes and refreshes after persisted prompt changes; published workspace proposals are exposed to Keeper turns; the dashboard distinguishes the curator prompt and input contract (#35688, #35702, #35693, #35698).
- Lanes: installation TOML is editable from the Dashboard and Keepers, the TUI manages TOML Lane packages and generic actions, a generic sampled value difference package ships, and MSX input history is retained with captured frames (#35588, #35672, #35687, #35701).
- Browser: `masc-browser-host --bidi-url` attaches to an explicitly enabled loopback Firefox BiDi endpoint for shared live input (#35819).
- Server: the endpoint probe answers over HTTP/2 (#35676).
- TUI: the palette reaches both halves of Task Review, a detail read that is waiting says how long it has waited, `/` says how many entries matched and stays after Enter, the composer row on every surface names the slash command being typed, and Lane Add-ons open from the Lanes screen (#35668, #35502, #35410, #35910, #35915).
- Voice: two endpoint kinds that speak and listen without a server, a setup wizard that asks only the questions it needs, a listing that asks every endpoint whether it answers and reports what each one said, and a writer that edits the voice section instead of regenerating it (#35507, #35427, #35425, #35382).
- Lanes: observation packages install from TOML, expose their Skills through the existing Keeper catalog, connect package outputs through TOML world inputs, and carry optional world actions with retained artifact bytes. A self-contained DOS world package ships as one of them (#35465, #35482, #35497, #35521, #35522).
- Browser: compose navigation with landing-page region observations (#35513).
- TUI Metrics: show retained Task throughput and lead time per assignee; these are Task observations, not a count of Keeper cycles (#35357).
- Goals: record creation events and recover names and lifetime observations for goals no longer in the active store; show that history in Planning (#35375, #35388, #35408).
- TUI: fold the turn dashboard to its progress line, retain questions requiring an answer, and use Ctrl-S to expand it with terminal flow control disabled (#35458).
- TUI: chat holds one timeline, with promoted and NEXT rows inside the flow rather than beside it (#35492).
- TUI: the keeper detail screen shows its tabs and stops saying its hints twice (#35490).
- Skills: builtin packages refresh as complete packages (#35442).
- TOML line editor: array-of-tables entries are addressed by an identifying key rather than by position (#35365).
- Voice: setup runs over HTTP and refuses unknown input by name, every endpoint is probed over HTTP rather than only from the CLI, and an endpoint can be asked which voices it has (#35431, #35609, #35629).
- Lanes: a DOS machine lives on the server behind seven masc_dos_* tools, MSX observations reach frame progress through TOML, and named package outputs connect the same way (#35548, #35562, #35572).
- Browser: the navigate-content composition ships, and tool receipts retain the scenes a TUI review reads (#35620, #35546).
- TUI: the Board column's marks carry names, and the help sheet holds the same words (#35528).
- Benchmarks: arm K also runs on opencode, without Anthropic credentials (#35406).
- Official clients: deliver supported image tool results with validated MIME/base64 content and retained failure receipts (#35384).
- CLI: `masc inspect-file` inspects original PDF, PPTX and MP4 files without changing Task or Goal state (#35921).

### Changed

- Skills: browser observation recovery loads on demand (#35695).
- Documentation: one-command installation with the sandbox installation guidance, talking to `imp` by voice with a runbook measured on a new workspace, and RFC-0450 on the witness ledger (#35537, #35880, #35815, #35491).

### Verification limits

- Native `inspect-file` tests passed all nine cases on macOS and Linux for #35921. End-to-end official-client attachment, image tool-result and follow-up conversation verification remains deferred; this release does not claim that matrix passed.

### Documentation

- Align the benchmark's arm A description with its actual kimi-cli runner (#35395).
- Update the G1 revision 2 contract and registration evidence, and document proposed typed Goal-store failures and explicit next-actor outcomes (#35485, #35524, #35479, #35480).
- Align the documentation site's installation version with the published release, record browser composition measurements and shared-page limits, and document the proposed refusal of submissions without a contract (#35529, #35531, #35477).

## [0.35.14] - 2026-09-12

### Added

- World constitution: articles, the append-only ledger they fold from, and the prompt slot every keeper in a world reads (RFC-0442) (#35327).
- Tools inventory shows each tool's exact description, expanded in place (#35390).
- The resident local Qwen3.8-27B is a runtime a lane can name (#35325).
- TUI: browser actions are navigable and the selection stays visible (#35383).

### Fixed

- Nested Keeper tool schemas reach the model wire intact instead of being rebuilt from flat parameters, which dropped enum, bounds and nested properties (#35385).
- TUI: ongoing work is shown alongside pending approvals (#35360).
- TUI: two chat guards were answering about a file they no longer read (#35371).
- Lanes: recent slice rows stay ahead of historical coverage (#35367).
- A failed Claude Code turn logs why it failed, not only its kind (#35342).
- Benchmark arm A runs harbor's kimi-cli; terminus-2 is retired (#35343).

### Performance

- TUI Code diff colouring no longer walks the open file to find a row: 107ms to 0.007ms (#35341).

### Changed

- TUI chat surface moved into its own library (#35334).

### Docs

- RFC-0442: a world's norms are ratified by keeper agreement rather than by a PR, kept in a base_path ledger and projected through the system prompt (#35322).
- RFC-0443: runtime lifecycle is not a provider stream event (#35355).
- corrective-grammar v0.3: title and tone settled for lane distribution (#35315).

## [0.35.13] - 2026-09-12

### Added

- TUI: the open question reaches its own ends (#35332).
- TUI: the Fusion runs and the Changes list answer `/` (#35324).
- TUI: jump to the first and last row, and page keys move a full page (#35317).
- One registry type for durable event-queue store generations (#35308).
- The resolved runtime list carries each runtime's quota life state (#35312).
- G1 matrix harness execution mode and its checker CLI (#35297).
- Terminal-Bench harness with MASC arms, a Claude Code model lane, and arm K that offers the keeper fleet as MCP tools (#35311).
- CI gates wire field and variant removals that arrive without a compatibility story (#35285).

### Fixed

- The TUI chat view stated four things that did not match the run (#35326).
- Exact preflights are no longer rejected over the injected default header (#35279).
- `verifier_exact` is excluded from `cli_slots`, and CLI runtimes are rejected at completion authority (#35300).
- A finished-but-broken structured reply advances the candidate walk instead of ending it (#35301).
- Named routing lanes accept a `runtime_ids` array body (#35298).
- The dashboard probes with the provider's own auth header and states the Vertex skip (#35296).
- The setup journey names each invalid check with its own reason instead of restarting the questions, and a save that died in validation no longer reports a saved workspace (#35336).

### Performance

- TUI list windowing slices once: 170ms to 4ms per second of scrolling at 21k rows (#35331).
- TUI row search: 297ms to 5ms per key at 21k rows (#35320).

### Changed

- Dead dependencies purged across activity_graph, ag_ui, backend, model_inference_metrics, operator, autonomous, exec, local_runtime_pool, task, tool_surface, dashboard_utils, board_types, keeper_contract, keeper_metrics, ide, pulse, exec_policy, benchmark, discovery_cache, and agent_core (#35318, #35316, #35313, #35310, #35302).
- Dead runtime store methods, serializations, unused exports, and legacy graphql environment variables removed, 338 lines (#35294).
- Dummy `Relation_materializer`, dead callbacks, and a fake portal spec removed (#35299).
- Phantom graphql route removed and spec typos fixed (#35329).
- Stale fictions purged from keeper specs, snapshot defaults, and invariants (#35328).
- gRPC default-off truth aligned and the obsolete workspace pause spec retired (#35323).
- Rubric taxonomy and spec inventory drift reconciled (#35330).
- Rejection constructors named in the llm_provider preflight inline tests (#35284).

### Docs

- RFC: TOML as the declarative system and the wire vocabulary authority (#35314).
- RFC: a runtime load failure keeps its shape until the screen (#35339).

## [0.35.12] - 2026-09-12

### Added

- Tool-result images reach vision models as user-media followups on the OpenAI-compatible, Ollama, and Gemini wires; a model without declared image capability degrades the image to a named placeholder instead of a rejected request (#35162).
- Verifier inspects contained image evidence with the actual judge model (#35171).
- Keepers hand generated binary artifacts to peers through the workspace blob store without either side touching the other's host paths (#35155).
- `masc_schedule_note_add` / `masc_schedule_notes_list` tools for durable schedule notes (task-381) (#35237).
- Setup installs and launches verified Docker Desktop from selection (#35151), and continues saved sandbox setup in a Docker group session (#35156).
- Setup installs selected official CLI clients without Homebrew (#35165).
- CLI setup uses the native runtime identity and an atomic batch writer (#35164).
- Each workspace HTTP port persists across fresh processes (#35241).
- Setup selection shows exact model release evidence (#35143).
- Lane add-on containers publish lifecycle events on the MASC bus — first slice of an experimental surface (#35242).

### Fixed

- Nested tool-result documents and audio degrade at every wire instead of leaking or rejecting (#35252).
- Positive `Retry-After` hints floor at 1.0s to prevent a rapid-fire retry loop (#35253).
- Reasoning efforts and thinking control propagate through the exact catalog binding (#35254).
- Model preparation requests stay alive until completion or explicit cancellation (#35238).
- OpenRouter rows accepting effort `none` declare their control format (#35258).
- A single librarian slot projection failure no longer kills the whole exact lane (#35234).
- Evidence retains complete binary snapshots beyond text preview limits (#35170).
- TUI repairs from PR #35230 review findings F2-F4 (#35235).
- Keeper dispatch tests check their Docker mount premise and initialize the prompt directory (#35251).

### Performance

- TUI turns and chat history inflight guards; IDE file activity cached (#35257).
- Board attention quarantine caching and comprehensive TUI inflight guards (#35244).
- Dashboard snapshot cache thrashing eliminated; operator TUI inflight guards (#35243).
- Keeper file-change scanning with a raw pre-filter and sliding window pruning (#35239).

### Docs

- Corrective grammar v0.2 catalog of measured failure cases and its follow-up (#35249, #35256).
- RFC: event spine and event source contract (#35240).


## [0.35.11] - 2026-09-11

### Added

- Prioritize detected connections and allow Enter selection in setup (#35137).

### Fixed

- Restore `runtime-codex-models` command and `--provider` option in `runtime-model-list` dropped during merge conflict resolution (#35233).
- Keeper chat line display: turn timestamp ranges and queued line state (#35230).


## [0.35.10] - 2026-09-11

### Added

- Native Google Vertex Gemini bearer transport and live publisher model discovery (#35094).
- Verify Antigravity official client response and private MCP challenge roundtrip (#35103).
- Choose graceful server upgrade and free available ports in setup (#35133).
- Observe Antigravity context without prompt in onboarding journey (#35135).
- Append failover slot to standalone lanes from the Lanes screen (#35227).
- Per-game MSX skills: Sangokushi-2 knowledge and end-command composition (#35228).

### Fixed

- Declare `ocaml-msx` in `dune-project` and regenerate `masc.opam` to fix CI native build failures (#35215).
- Count unclassified event backlog entries whose keeper owner cannot be resolved in fleet health (#35214).
- Add missing `--private-credentials` flag to `masc runtime-wizard-catalog` CLI (#35133).


## [0.35.9] - 2026-09-11

### Added

- Keeper Chat TUI indicates active and failover runtime during turn execution and in history (#35224).
  - Past attempts in chat history show supersession badges and earlier runtime IDs (`↺N (<runtime_id>)`, `*(attempt N: `<runtime_id>`)*`).
  - Active turn phase text distinguishes between provider endpoint connection (`connecting to [<runtime_id>]`) and token streaming (`streaming from [<runtime_id>]`).
  - Failover retries preserve the failover badge during multi-tool execution and reasoning phases (`failover [<runtime_id>] (attempt N)`).
  - Rate limit (429) and execution errors unambiguously attribute the failed runtime ID (`[<runtime_id>] <message>`).
- Native Google Vertex Gemini bearer transport primitives (#35087).
- AWS Bedrock official SDK Converse streaming and discovery bridge (#35099).
- Automatic Application Default Credentials (ADC) token refresh at provider HTTP boundaries (#35091).
- Interactive Antigravity account and model discovery in `masc setup` (#35130, #35108).
- Workspace upgrade recovery backup and restore prompts (#35127).
- Model setup resumption in existing running workspace owner (#35123, #35111).
- Model setup restoration from web settings (#35129).
- Real-time search filter in installer runtime picker (#35206).
- Automatic `masc` environment configuration in fresh shell sessions (#35126).
- OpenRouter DeepSeek-v4.1-flash runtime and catalog row (#35150).
- Automatic tracking of model release evidence and calendar recency (#35107).
- Browser and MSX owner passive observation mode without taking control (#35120).

### Fixed

- Prevent file descriptor leak against dead server connections (#35046).
- Gate media tool execution to verified runtimes only (#35179, #35136).
- Recover chat dropped by empty carrier rows with exponential retry backoff (#35145).
- Prevent MSX tick poll from leaving the Kitty pixel surface stale (#35199).
- Stop discarding reservation release outcome upon keeper removal (#35212).
- Demote historical tool results on uncapped runtimes (#35219).

## [0.35.8] - 2026-09-11

### Fixed

- The max-tokens truncation recovery no longer dies in request validation on runtimes that declare `reasoning-effort`. The recovery retries the turn with thinking disabled, but the re-dispatched candidate still carried the runtime's `reasoning_effort`, which the Anthropic wire rejects (`cannot set reasoning_effort when enable_thinking=false`) — the retry now strips effort from the candidate alongside `enable_thinking`/`preserve_thinking`, so the continuation it was built to rescue actually runs (#35195).

## [0.35.7] - 2026-09-11

### Fixed

- Anthropic keeper lanes no longer fail every turn with `Invalid request: 'temperature' may only be set to 1 when thinking is enabled or in adaptive mode` for models whose capability row declares `ignored_sampling_parameters`. The Anthropic reasoning-dialect arm hardcoded its transport shape and never consulted the model's capability record, so the declaration was silently dropped and `temperature`/`top_p` reached the wire unconditionally; the dialect now derives its sampling policy from the capability record, and the Anthropic request builder routes `temperature`/`top_p`/`top_k` through the shared sampling-field gate (a dropped field logs the existing one-shot WARN) (#35193).

## [0.35.6] - 2026-09-10

### Fixed

- Anthropic keeper lanes no longer fail every turn with `400: input_schema does not support oneOf, allOf, or anyOf at the top level`. The Anthropic request builder now projects each tool's `input_schema` to drop top-level combinators (the `tool_execute` argv-or-script rule rendered one); nested combinators and the dispatcher's own validation are unchanged, the Kimi endpoint served through the same backend keeps its schema verbatim, and a combinator-only schema gains a synthesized `type: "object"` (#35168).

### Added

- Keeper TOML gains `[keeper.tools] deny = [...]`: a per-keeper list of model-visible built-in tool names (e.g. `keeper_spawn`, `masc_keeper_delegate`) removed from the keeper's capability surface entirely — unlisted to the model, absent from the turn's dispatch bundle, and refused by the frozen-surface admission if named anyway. Deny entries matching no model-visible tool are logged as `keeper_tool_deny_unnamed`, and the dashboard effective-tool-surface projection reports the active list (#35169).

## [0.35.5] - 2026-09-10

### Installation

- Run `masc` and `masc start` without repeating `--base-path` or exporting `MASC_BASE_PATH`. `masc setup` and `masc init` record the workspace they prepared, an explicit `masc start --base-path` records it too, and the server accepts that recorded workspace at startup. A record whose path no longer holds a `.masc` directory is ignored, and the error says which record was skipped and why.
- Choose the sandbox imp runs its turns on: `masc setup --sandbox-profile docker|microvm|remote_ssh`, with `--microvm-backend` for the microVM runtime. The chosen profile is written into imp's keeper file, and setup checks what that profile needs on this host. With no flag it reads the profile imp already declares instead of asking for Docker regardless.
- Read what a missing sandbox dependency was. An absent `docker` reported `create_process docker: No such file or directory`; it now names Docker and points at Apple Container together with the flags that move imp onto it.

### Health

- See which section set the overall status, and read only the reasons an operator has to answer.

## [0.35.4] - 2026-09-10

### Installation and startup

- Start up when a saved model catalog overlay carries entries the current binary no longer understands. Unknown fields and dead entries are skipped with a warning that names the file and the entry, instead of refusing to boot — a fresh install over an older workspace hit that refusal.
- Say when a failure is the configuration, not the model connection. A config load error now names the file and the parse problem instead of the blanket "Model connection failed" that pointed operators at the wrong fix.

## [0.35.3] - 2026-09-10

### Installation

- Boot a fresh install on the connection the wizard preselects. Choosing it left the exact-output lanes with no catalog target, and the server refused to start.
- Finish installing over an existing workspace when reselecting a connection or resetting configuration. The installer aborted at that point on macOS's own bash.
- Say which client problem stopped a model verification: no sign-in, a client that would not start, or an invalid binding. All three read as one message before, and the client's own account of what it looked for is now shown.

### Keeper and runtime

- Declare the structured output of Read, Grep, Write and Edit as types rather than free-form text.
- Name the wall-clock escape out of a turn that is waiting on a tool result.
- Show Keeper identity values by default; credential markers keep their own boundary.

### Shell execution

- Run `$( )` command substitution. Its result is one argv element and is never re-split.
- Refuse the `eval`, `source` and `.` builtins by name.

### Terminal UI

- Group the params screen by the surface catalog the registry already declares.
- Draw surface frames in the spectator view.
- Keep the TITLE columns aligned when a goal phase is shown.

## [0.35.2] - 2026-09-10

### Installation and model connections

- Select multiple runtime connections and models with arrow keys and checkboxes, then choose imp's primary model and fallback order. Preserve existing connections when adding or reselecting models.
- Require a real response and harmless tool roundtrip before the interactive wizard publishes selected connections. Preserve existing settings when verification fails and offer retry, exclusion, or selection again.
- Discover installed Ollama models and effective context windows; use exact existing connection metadata and single-model llama.cpp server context before asking for advanced manual input.
- Support observed Claude Code API-key, token and gateway authentication, plus Codex API-key and provider-managed configurations. Keep authentication evidence separate from configuration presence.
- Check existing Keeper and Goal state before setup writes. Offer an unused workspace when old state cannot be decoded, preserving the original files.
- Isolate Codex's readiness probe from inherited tool servers using a private connection/auth configuration. This connectivity probe does not establish full imp sandbox acceptance by itself.

## [0.35.1] - 2026-09-09

### Installation

- Choose Claude Code and Codex models from numbered choices, including Claude Sonnet 5 and GPT-6 Astra. Use observed client context limits when available and exact catalog context otherwise; keep explicit custom-model setup available.
- Upgrade older stable binaries without requiring `--force`, preserving workspace configuration. Separate installer options from PATH setup and make script inspection optional instead of blocking installation in a pager.
- Package the macOS Python runtime and non-system shared libraries with immutable, checksummed release files so installing MASC does not require Homebrew. Keep Docker and model-runtime authentication as explicit prerequisites.

### Verification

- Verify imp conversations and required tools in the same fresh workspace produced by the installer. Preserve selected runtime and keeper configuration, reject prior imp evidence, and bind successful measurements to new requests and the observed model.

## [0.35.0] - 2026-09-09

### Fresh state required

Two contract changes after 0.34.0 do not read state written before them. The
server does not convert old state; it refuses the file and says so in the boot
log and in the tool result. Delete or rewrite these files before the new
binary starts.

- Keeper profiles, `<base>/.masc/config/keepers/*.toml` (#34392): `[keeper]`
  takes `activation_mode = "manual" | "on_demand" | "autonomous"`. A profile
  that still carries `autoboot_enabled` or `proactive_enabled` is rejected as
  `unknown keeper TOML keys`; the message now lists the accepted keys. Rewrite
  the profile, or recreate the Keeper with `masc_keeper_up`.
- Goal store, `<base>/.masc/goals.json`, `goal_verifications.json`,
  `goal-verification-runs.jsonl` and their `.last-good` mirrors (#34459):
  every Goal row needs `criterion_revision`, every verdict needs `request_id`
  and `criterion`. One row without them makes the whole file undecodable, and
  `masc_goal_list` returns the decode error with the file path. Delete the
  files to start with an empty Goal store.

### Installation and setup

- Add `masc setup` to prepare the default Docker image, verify workspace server identity, authenticate the local operator, start the existing `imp`, and open the TUI. Preserve the Keeper manifest and stop only a server started by setup; `--no-tui` leaves it running.
- Bind the selected runtime to internal helper lanes for single-runtime installations, including CLI-only Claude Code and Codex judgment paths with durable provenance. Use installed catalog context sizes for known CLI models.
- Add a real-model onboarding acceptance runner that checks conversation, persisted Board posts and Tasks, sandbox directory execution receipts, and web fetch results. Keep these evidence checks separate from release publication and final native artifact acceptance; adding the runner does not establish either result.

- Include the corrected macOS dependency bootstrap, Python executable selection, and loader diagnostics in the same source release as the binaries.
- Ask for a workspace on terminal installs; preserve explicit paths and existing workspaces. Add program-only uninstall, explicit workspace data removal, and dry-run.
- Ship a disabled starter Keeper (`imp`) for manual activation after model and sandbox setup.
- Add explicit llama.cpp, vLLM, Claude Code, Codex, and Antigravity setup choices using catalog metadata for known CLI models and explicit metadata for other connections; validate staged configuration before applying it.
- Validate runtime default changes with the same workspace capability catalog and overlay used by server startup.
- Run documentation and installer checks without waiting for OCaml preparation; new global tags no longer invalidate checks on unchanged branches.

### Keeper and operator interfaces

- Add TUI Keeper deletion, connector trigger-policy selection, preset inspection, and clearer fleet state.
- Add browser development source-context selection and Dashboard goal selection.
- Surface scheduled wake outcomes, preserve operator prompt overrides, and repair prompt assembly and duplicate owner wake handling.
- Improve JSONL recovery and subprocess cancellation/foreground process-group cleanup; prevent host environment expansion into sandbox command arguments.
- Extend MSX disk image loading and playback presentation.
## [0.34.0] - 2026-09-08

### Installation and distribution

- Update the release-attached `install.sh` with automatic macOS dependency setup and an early binary startup check that exposes loader errors. Interactive first installs can enter the official Homebrew setup. The published 0.34.0 binaries and source tag remain unchanged; installer provenance is recorded in the release notes.

- Ship the browser native host with the server, TUI, preflight tools and matched dashboard.
- Add Intel macOS release assets and require every advertised platform build to pass.
- Exercise Linux installation in a fresh Ubuntu 24.04 container as well as native runners.
- Preserve operator configuration during `--force` upgrades; `--reset-config` explicitly resets seeded configuration.
- Document prerequisites, installed files, first use, optional integrations and upgrades in `docs/INSTALL.md`.

- Repair interactive provider selection, explicit-provider configuration changes and login-probe reporting. Invalid input can be corrected; unsupported probes remain unverified.
- Correct Keeper TOML and MCP bearer-header examples, including generated Claude Desktop configuration, and complete source/browser onboarding instructions.

- Route `sandbox-image --runtime nerdctl_kata` to nerdctl rather than Docker, and add release image/tool smoke. Linux Kata work volumes now use idempotent native managed directories with explicit capacity limitations.
- Document initial prompts, skill discovery and empty/default team rosters; stop assuming fresh Keepers already have GitHub credentials.

- Include source-bound recovery transmission (#34245) and built-in `browser-lanes` Skill packages (#34256) from main. Upgrade seeding preserves operator packages while installing new built-ins.

- Close short-lived HTTP pools before `keeper-create` returns, fixing CLI hangs after responses; verify command exit and a real Docker first-turn path in CI.

### Runtime changes since 0.33.0

- Add Gecko semantic scenes and the TUI `s` scene view with observed control
  selection/clicks (#34297, #34298). Scene replies remain bound to their browser,
  tab and document. Live use requires the updated native host and extension 0.3.0;
  the installer does not upgrade an existing browser extension.

- **The embedded tree is the managed asset set; the hand-written manifest is
  gone.** `config/{tools,prompts,mcp}/managed-assets.json` listed the files
  beside it a second time, and five releases running shipped with a file on
  one side and not the other -- v0.33.0 warned `half-built binary` on every
  boot over `keeper_lane_status.toml`, which was embedded but unlisted. The
  sync now computes the managed set from what the binary embeds, refuses an
  empty set instead of projecting it, and still writes the runtime
  directory's `managed-assets.json` as the record of what it owns there.
  Adding a tool, prompt, or MCP file is one file again. (#31283)
- **The shim names the release it came from, and the server says when they
  differ.** `masc-exec-shim --probe` now answers with a `release` field taken
  from `dune-project` through a generated module, so no build step has to
  remember to stamp it. On every probe the server compares that with its own
  version and logs `remote_shim_outdated` when they differ, or when the shim is
  old enough not to name itself; the lane keeps running, because the two sides
  negotiate the protocol major and tolerate one release apart on purpose. The
  `keeper_lane_status` tool reports `shim_release` beside `server_release`, so a
  keeper can read it for its own lane. The repair is the existing
  `masc-exec-ssh-bootstrap --shim`, which the warning names (RFC-0427 B-3).

- **The observation stage actually runs in the box now.** The gate's
  pre-judge observation (RFC-0422) dispatched the keeper's effect-built
  shell IR unchanged: execution reads the dispatch target from the IR, so
  the "observed" run was the real call with live network, and its exit
  became the gate's evidence — an `observed_in_box` auto-allow granted a
  real `gh pr create` (PR #33609) and a review comment before any operator
  decision on 2026-09-06. `Shell_ir.with_sandbox` rewrites every stage of
  the IR onto the box's target (a delegated masc-tool stage keeps its own),
  and the observation stage dispatches the rewritten IR (#33638,
  task-1375).
- **The exec shim traces every request and names its build.** On 2026-09-06
  an `observed_in_box` auto-allow ran with live network (a keeper opened PR
  #33609 through the observation path), while the same shim binary framed by
  hand boxed correctly — and no record said what the server had actually
  framed. The shim now appends one line per request to the guest's
  `/tmp/masc-shim-requests.log` (framed mode, the plan it got, argv0, build
  id; best-effort, capped at 4 MiB), and the static build stamps its commit
  sha into the probe version (`3.0.0+a1b2c3d4`), so two artifacts of one
  protocol stop looking identical. RFC-0422 diagnosis, task-1375.

## [0.33.0] - 2026-09-06

- **The release ships the exec shim.** Every tagged release now carries
  `masc-exec-shim-linux-arm64` and `masc-exec-shim-linux-amd64`, built
  statically on a runner of the same architecture and probed before upload.
  Operators download the asset beside the server binary instead of building
  it; the runbook says so (RFC-0427 B-1).
- **The installer places the guest exec shim, and the boot verifies it.**
  `scripts/install.sh` downloads `masc-exec-shim-linux-<guest arch>` from the
  release beside the other companions, places it at
  `<base>/.masc/microvm/shim/masc-exec-shim`, and writes the release's sha256
  next to it as `masc-exec-shim.sha256`; `--no-guest-shim` skips it. A microvm
  boot compares the binary with that sidecar and refuses a mismatch as
  `microvm_shim_hash_mismatch`; a shim without a sidecar (hand-built) runs
  unverified and the boot log says so. The release job's installer smoke
  covers both paths (RFC-0427 B-2).

- **TUI: Notion-grade 2-column web bookmarks, visual banners, and remote image viewer.**
  - 2-column Notion-style bookmark cards with domain favicon/header, title, description summary, URL, and action pills (`[o:Browser]`, `[y:Copy]`, `[v:Visual]`), with mathematically grapheme-safe cell width alignment across all lines and responsive fallback to 1-column on narrow terminals (< 55 cols) (#33541).
  - 24-bit TrueColor visual OG thumbnail banners with platform-specific branding: GitHub (slate/purple with Octocat), YouTube (crimson with play mark), arXiv (academic navy with preprint ID), Hacker News (warm orange), Direct Image (cyan), and Web (charcoal) (#33541).
  - Remote image viewer: one-click inspection (`[v]`) downloads HTTP(S) images to `/tmp/masc_img_cache/` and renders inline via Kitty graphics or falls back to browser opening (#33541).
  - Multi-protocol terminal graphics: added iTerm2 `OSC 1337` (`\x1b]1337;File=inline=1;...`) protocol alongside Kitty APC graphics, auto-detected via `TERM_PROGRAM = "iTerm.app"` (#33544).
  - Universal fast image format conversion: added `convert_to_png` leveraging macOS built-in `/usr/bin/sips` (with ImageMagick `convert` and `ffmpeg` fallback) to convert JPEG, WebP, GIF, and TIFF images to PNG in milliseconds (#33544).
- **TUI: line memos from lexed comments, Mermaid text rendering, and categorical themes.**
  - Line memos are comments in the file (`masc(AUTHOR): TEXT`, `masc(AUTHOR) KIND: TEXT`), read directly off lexer rows without network round-trips or server drift (#33543).
  - `keeper_ide_annotate` writes its memo into the file as a comment — the write side of the same design: language-specific comment markers, a line-anchored insert instead of text substitution, Markdown included (#33592).
  - Mermaid diagram rendering: draws `mermaid` graph and flowchart code blocks as clean Unicode/ASCII box-and-arrow diagrams within the TUI viewport (#33508).
  - Categorical 6-slot theming extended across all remaining axes in `render.ml` with raw hues removed (#33485).
  - Palette matchers fold case internally (#33536, #33522); `K`/`D`/`R` shortcuts open the palette as a choice among the line's names (#33514); multiline preview uses return marks instead of raw `\n` (#33482); stopped keepers display as `paused` instead of `offline` (#33510).
  - Loop gaps, slow requests, and mailbox waits logged with dual monotonic and wall clocks (#33486).
- **LSP: 23 languages recognized with root detection and Python support.**
  - Language table expanded to 23 languages, each paired with project root discovery rules (#33509).
  - Python language server configured with `pyright-langserver` (#33535).
- **Runtime, process execution, and storage performance.**
  - Subprocess spawn migrated from `fork` to `posix_spawn` for safer and faster process management (#33483).
  - Incremental dated JSONL folding: `fold_range_appended` reads only bytes appended since the last read cursor, avoiding redundant rescans of multi-megabyte log ranges (#33542).
  - Workspace backlog decoding and task ID parsing offloaded to domain pool workers (#33487).
  - Typed `run_outcome` prevents execution errors from masquerading as empty tool results (#33467).
  - Seed catalog bindings declare explicit `max-request-body-bytes` (#33484).
  - Tool schema payload size structurally reduced below the 80 KB ceiling (#33528).
  - GitHub config directory preauth clarification prevents redundant HOME copies in keeper containers (#33545).
- **Architecture & Specifications.**
  - RFC-0427: Autonomous execution lanes and self-deploying shims (#33450).
  - RFC-0429: Terminal UI as an IDE surface: real-world defect analysis, universal language servers, and Mermaid text rendering (#33480).

## [0.32.0] - 2026-09-05

- **A context overflow walks the history down to its floor.** The same-run
  shrink retry no longer stops after three halvings; it goes on while the
  runtime can name a strictly smaller view and ends where none exists, so
  `bootstrap_floor_exceeded` is committed only once no smaller view remains.
  Measured 2026-09-05: a 4.1 MB history on a 128k-token model was
  cut to 498 KB in three halvings and left on an operator recovery with 79
  messages still attached.
- **A voice listen with no timeout waits 15 s, the number its schema says.**
  `keeper_voice_listen` defaulted `timeout_seconds` to 60 s in the tool while
  its schema advertised 15 and the TUI capture used 15; the tool passes
  nothing now and the bridge's one default applies. The 60 came in with
  #20370, which released the turn semaphore for the length of a listen;
  #20379 removed that release the same day and kept the number, and nothing
  releases a turn during a listen today. Whether 15 is the right window is
  the owner's call with those two in view. A `keeper_voice_speak`
  under a voice config that does not load is refused with the loader's
  sentence instead of being sent to the Gate; capture config errors name
  `capture.<key>`; a capture result with no `status` reads back as its own
  case; the TUI's input-device probe reports why it found nothing.
- **A cancel claim is the operator's to close; the system LLM reviews
  completion claims.** The lane records a cancel claim as `operator_routed`
  and has no review prompt for it. An operator-routed row is neither a verdict
  nor a lane failure on the Verifier lane.
- **A cancel says whose reason it is.** A cancel resolves its reason from its
  own `reason` or `handoff_context` only, never from the previous owner's
  release note the Task still carries. A cancel of a claimed, started or
  awaiting Task is refused when neither is given; a cancel of an unclaimed
  Task commits without one. The Board post the operator judges, the
  committed Task, the message log, the transition log row, the activity
  event and the duration metric carry one sentence. The verification record
  carries no `cancel_reason` field: nothing read it.
- **The nightly test lane runs what it says.** It builds the root `@runtest`
  alias, so the 41 suites in `packages/agent_core/test`, the ten in
  `lib/exec/test` and the `tools/` suites run with the rest; the scheduled run
  on main has its own concurrency lane, so a branch dispatch no longer cancels
  it; a failure in any `dune` file is attributed to its suite, keyed as
  `<dir>/<name>` in `test/ci-known-failures.txt` because two directories now
  declare the same names, and a run in which a failure header names no suite
  fails; and a deadline expiry lists the executables still running under dune,
  found through parent links since dune starts each one in its own process
  group, instead of only a log tail.
- **A keeper's `sandbox_image` reaches the docker preflight.** The keeper
  TOML `sandbox_image` is passed through to the docker preflight (#33434,
  #33455): a custom tag is trimmed before it is used, and the rejection
  wording when a stated image cannot be used matches what actually happens.
- **A cross-domain lane start or restart delegates to the owning domain.**
  (#33368, #33447) The three wildcard catches the delegation needs are
  justified with cancel-guard marker comments (#33494).
- **The microsandbox shim probe fires without `--stream`.** (#33431, #33464)
- **TUI: web link previews and a six-slot categorical theme.** Web link
  preview, OpenGraph extraction, rich embed cards and a 3D preview modal
  (#33478); a categorical six-slot theme applied to the file listing
  (#33471); smart declutter approvals, a refine HUD, an interactive diff
  review modal and tool-row readability (#33448); a theme test that could
  not reach the lane decoder is fixed (#33469).
- **`keeper_lane_status`, the lane's account of itself.** (#33472)
- **Dashboard: a per-keeper fusion review list.** (#33452)
- **.mli exposure cleanup.** Unused .mli exposures are closed and what the
  compiler already reported dead is removed (#33474); the research record
  tree grows the index it lacked (#33336).

## [0.31.0] - 2026-09-04

- **Voice input, end to end.** A Keeper chat can be dictated: the capture decides
  where speech starts and ends and the meter watches it (#33062), thresholds and
  noise reduction move into `runtime.toml` (#33036, #33020), a Config pane shows
  what voice resolved to and on which microphone (#33032), Esc abandons a
  recording (#33088), and a stop keeps the sentence it interrupted (#33079). The
  capture meter reaches the chat surface and keeps reading (#33035, #33045).
- **The composer completes and holds.** Tab autocompletes slash commands and
  their arguments (#33068), arrow keys and Shift-Tab walk the completions
  (#33071), and a line typed while a Keeper is still being composed for is held
  rather than sent past the one in progress (#33047). A lone continuation bullet
  is now a quiet vertical rail (#33060).
- **An image a text-only Keeper cannot read is read for it.** A deferred runtime
  lane degrades an image turn to text instead of crashing on a text-only model
  (#33037, RFC-0414 #33054), and the cloud vision runtime gemma4-31b is wired as the
  `media_failover` read fleet so `analyze_image`'s eager read lands on a fast one,
  with an image-sized request-body ceiling in its binding (#33074).
- **Chat is one canonical event log.** A per-turn chat event journal records the
  stream once and projects it (RFC-0412 stage 1, #33053, #33002), with a
  retention sweep and a repeating-SSE decode fix (#33056).
- **A stop is judged on its reason.** Verification reads why a turn stopped
  rather than what it did not build (#33059), the cancellation lookup describes
  tools instead of ordering a rejection (#33080, #33066), five vacuous checks now
  fail on the value they check (#33050), and a stop waits on a record the
  authority can read (#33046).
- **Interrupts do what the screen says.** Esc during a turn stops the turn
  (#33025) and leaves the chat once the interrupt is stale, declined, or errored
  (#33049); a spawned process no longer freezes the UI (#33023); Gate steps fold
  into the one approval they describe and draw from their typed phase (#33024,
  #33001).
- **Keeper hygiene.** `masc keeper-create` lands a Keeper on the network mode it
  was given (#33084); a moving-result loop is still caught as a loop (#33033);
  the carried tool set is bounded at its growth boundary (#32988); paste delivery
  is verified by read-back before it is logged delivered (#33042); a microVM
  guest whose work volume is not mounted is refused (#33026); the official-client
  codex profile id is corrected and an unset system prompt omitted (#33072,
  #33009).
- **Tool schema and streams.** Canonicalizing a schema derives its description
  without rendering the prose it discards (#33003, #33013), the cancel tool joins
  the embedded-tools manifest (#33081), and a consumer that stops reading stops
  the socket (#33048, #33055). Nightly CI now runs the full test suite (#33070).
- **Surfaces with no producer are removed rather than drawn empty.** The metrics
  alias surface (#33019), the handoff rail whose producer died in August
  (#33014), and the submission-clock field nothing read (#33067). The chat store
  records an approval instead of wording one (#33028), the duplicate attachment
  ids and folded image rows the two-writer shape produced are gone (#33063), and
  `gh` read verbs take the observation-only path instead of the judge (#32999).
- **Checks that could not fail now fail.** The composable-output gate reaches the
  paged shape and every probe runs (#33006), goal and run probes carry an item
  and the collector keeps every failure (#33011), and the output schema rejects
  the metrics alias fields that were removed (#33030).

- **Also folded into this tag.** A Keeper answering a Discord mention no longer
  sends the surface name as a channel id: `keeper_surface_post`'s `channel_id`
  says omit it to reply where the message came from (#33093). The STATUS badge
  stops drawing two lanes as one (#33094), and the TUI renderer gains an
  interface it did not have (#33091).

## [0.30.0] - 2026-09-04

- **The install wizard detects what is ready before it asks.** The setup
  catalog no longer dies on a provider it cannot resolve (#32852) and now offers
  subscription CLIs — Claude Code, Codex, Antigravity — beside HTTP providers
  (#32857). It reports which local model servers are actually running (#32868)
  and which execution sandboxes the host can offer — docker, microvm via Apple's
  `container` CLI, remote_ssh (#32884). When there is no terminal it uses the one
  source that is ready rather than error or skip (#32914), and the menu default
  lands on a ready source instead of a dead one (#32903).
- **A subscription is shown as signed in, not just installed.** `masc
  runtime-probe <runtime_id>` reports whether a Claude Code or Codex CLI is
  actually signed in, reusing the server's own login probe rather than parsing
  credential files, and the wizard uses it to distinguish "installed" from
  "signed in" (#32897).
- **Connecting an MCP client is one command.** `masc mcp-config
  [--client env|codex|claude-desktop]` mints a bearer and prints a ready client
  config block, so a client connects without hand-wiring the URL, token, and
  header (#32907).
- **The README and RFC-0408 match what shipped.** The README documents the
  first-run detection and the one-command MCP setup (#32901, #32907); RFC-0408
  is marked implemented and its sandbox premise corrected to what the code does
  (#32919).

## [0.29.1] - 2026-09-03

- **The release gate runs again.** Four scenarios in the release evidence
  bundle were red, and every one of them was a test that had never passed:
  owner fixtures and prompt prose pinned what the product had deliberately
  changed (#32695), the verification surface tests stood their producer on
  Docker while the release job builds no daemon or image (#32710), the owner
  suite gated on that same daemon (#32719), and the speak-gate test ran in a
  runtime that could not speak, so it measured the text fallback instead of
  the Gate (#32723). Two main breakages were repaired alongside them: an
  unclosed paren in the replay body and a field label two records had come to
  share (#32676, #32694), and a cancelled-fiber pattern that needed
  parentheses (#32684).
- **A verifier reads the producer it is judging.** The verification lookup
  reached no producer at all: a microvm keeper's tree was refused as
  unreachable, and a workspace producer — which declares no sandbox profile by
  design — could not get a surface once the profile became mandatory (#32710).
- **A Keeper carries the tools its profile names.** Nineteen rarely-needed
  tools move behind the listing (#32711), the ask family is deferred and the
  prefix vocabulary closes (#32718), a Keeper takes the attached tools its
  profile names rather than every tool its services offer (#32679), and the
  tool surface takes public names instead of reaching into the Keeper domain
  (#32677, #32699).
- **The Gate reviews what it can replay.** An approved speak is replayed by
  the host and listen never queues a request, because an approval cycle
  outlives the microphone window (#32668); the deferred wording promises only
  what the replay engine supports (#32674); the observation fast path reads
  the typed sandbox profile instead of wire strings (#32672); an observation
  script runs a read-only argv table (#32705, RFC-0404).
- **The chat and the TUI.** A line typed while another waits joins it instead
  of queueing behind (#32682); a skill row is always full rather than behind
  the tool toggle (#32685); an attempt boundary drops the unfinished stretch,
  not the whole turn's speech (#32693); an Execute row's subject can be a
  shell line as well as argv (#32692); the chrome becomes a library so a
  surface can leave the god file (#32728).
- **Providers and runtime.** The DashScope provider kind is removed and the
  Qwen id it had overwritten is restored (#32709), and the top-level
  `enable_thinking` wire form goes with it (#32713). A host stop carries the
  assistant usage sum and logs the stop as designed (#32687); the segment
  accumulator keeps a fingerprint it was given (#32688); a turn that routed
  something still says what it dropped (#32717); three wildcard catches stop
  answering for a cancelled fiber (#32680); a refused tool call says which
  name it refused (#32706); the health probe reports the transition rather
  than the steady state (#32707).
- **The campaign runner survives a rate limit.** HTTP 429 is treated as
  "later", every rejection is recorded, and the call retries within a budget —
  r8 run1 had died on its first 429 (#32673).

## [0.29.0] - 2026-09-02

- **Tool calls read as trees.** A call's JSON arrives as structure and the
  labels of one tree share a column (#32606), each part of the payload draws in
  its own colour (#32625), a result's string documents unfold into the tree and
  multi-line strings draw as blocks (#32616), typed execution details are
  exposed (#32571), the folded Tools line names the tool behind a failure
  (#32370), and lane tool outcomes are badges (#32348).
- **The chat says what went into a turn and what came back.** The context
  stack answers what goes in each turn and the request tab says where each
  item stands (#32540); the request tab shows the answer to that request
  (#32563) and `/` searches it the way the roster is searched (#32564); the
  context detail column keeps its own window (#32531) and says which turn it
  describes (#32286); lane input and output compare side by side (#32270);
  civil-hour rails mark the chat (#32363); exact Keeper Skill evidence shows
  in chat (#32294).
- **The Tab ring is shorter and the children sit under their parents.** Acting
  became Activity and owns the server log (#32251); Resources and Tools hang
  off Config as `s` and `t` (#32245); Code is a Workspace child and the Repos
  stop was renamed Workspace (#32230); Connectors left the ring (#32213) and
  channel bindings are operated from the selected Keeper's Channels tab,
  beside Automation and Runs (#32242, #32526); the seven surfaces that answer
  the row search say so in their footer (#32613).
- **Keeper detail shows the sandbox.** Sandbox status, the actual container
  logs, and where a microvm keeper's build output lands (#32535, #32542,
  #32557, #32324); durable Keeper edits appear in file history (#32192); `b`
  puts `git blame` in the Code margin, one author per run of lines (#32619).
- **Memory has a fact browser.** Memory grows a fact browser over the health
  counts (#32236) with a three-state journal detail (#32367); the server
  exposes fact-level reads at `/keepers/:name/memory-facts` (#32217) and exact
  fact retraction (#32250); support is derived and budget authority is removed
  (#32239); source-bound health shows in Dashboard and TUI (#32169); an
  undecodable Memory OS snapshot no longer wedges a keeper (#32390), a
  rejected one says which row and field (#32371), and a corrupt store is a
  stamped failure rather than an exception (#32480).
- **A microvm guest owns its working tree (RFC-0399, RFC-0400).** Build output
  moves off virtiofs (#32281, #32285, #32291); the guest boots with a work
  volume and the exec shim and is a remote endpoint (#32516); Write and Edit
  reach the tree the endpoint owns (#32523) and every command takes the remote
  lane (#32574); microvm Execute routes through Apple Container (#32399); the
  lane runs no OpenSSH preflight (#32586); a guest proves it can write its
  keeper root before it is handed out (#32601); a created keeper reports the
  isolation it landed on (#32607). A keeper runs under docker, microvm, or ssh,
  or not at all: the host profile is gone (#32078, #32103).
- **A turn explains itself to the next one.** The next turn is told why the
  previous one stopped (#32492), a stimulus's turn records how it ended
  (#32287), the exact provider input is exposed by turn (#32292), checkout
  freshness is projected as a context layer (#32237), a completed turn
  consumes its batch so a stimulus no longer re-promotes in a loop (#32282), a
  Gate-deferred call no longer re-spends a turn per wake (#32602), and
  max-token degeneration is recovered or handed to the next lane (#32577,
  #32605).
- **Tools arrive by name, with a typed failure class.** The tool listing
  carries names only and a query finds the rest (#32475, #32484), the typed
  failure class reaches the model with its next move (#32476),
  `keeper_tasks_list` pages through a keyset cursor (#32488), `masc` inside a
  shell line reaches a tool (#32427), and Execute and its siblings read their
  descriptions from the catalog instead of OCaml literals (#32555, #32528,
  #32525).
- **Planning, verification, and schedules explain themselves.** Verifier lane
  runs and their evidence are exposed (#32189), Planning names its flow and
  actors (#32186) and the Board and Planning order (#32180), Fusion tool
  execution evidence is inspectable (#32147), scheduled wakes trace to durable
  reactions (#32204), the dashboard schedule page names the Keeper a wake
  reaches and what became of it (#32466), a decision without continuation
  evidence is not marked Ignored (#32114), and a method-not-found reconciles
  with the live catalog (#32116).
- **The E0 campaign has a scoreboard.** Three pinned runner bundles become one
  round scored k-of-3 with typed residual causes (#32567); the runner takes its
  keeper lane as `--sandbox-profile` at both keeper-up sites (#32593, #32615),
  and an RW23 wait that runs out is the mission's failure, not the round's
  (#32599).
- **Colour comes from the theme.** The renderer stops picking colour codes and
  the theme grows the words it was missing (#32627); native-pass themes list
  first (#32202); system logs are inspectable and verbose logging toggles
  directly (#32138, #32203).
- **CI builds the whole tree.** The build job builds everything, not just what
  installs (#32518), in one manual job (#32511); the main source ratchets,
  boundary registries, and shell tool contracts are restored (#32378, #32168,
  #32442); connectors expose a managed channel directory (#32547).

## [0.28.0] - 2026-08-30

- **A bare Linux install runs in one shot.** The Linux release binaries link
  SQLite statically, so `masc` and `masc-tui` start without `libsqlite3.so.0`
  installed first (#31784), and the release build asserts neither shipped
  binary keeps a dynamic SQLite dependency. When a system library is genuinely
  missing, the installer now prints the loader error and the missing library
  name instead of a blank `--version` failure (#31781). An offline install
  smoke stages the packaged binaries as a `file://` release and boots the
  installed server end to end, so the installer's asset-name and checksum
  contract is exercised on every release (#31731, #31795).
- **The TUI can start its own server.** `masc-tui` discovers the sibling server
  binary and, on the Keepers surface, starts it on `s` when disconnected and
  stops it on exit — an opt-in path toward the TUI as the default entry point
  (RFC `tui-server-lifecycle`, #31745, #31752, #31761).
- **Approvals answer the first keypress.** The Gate and held-tool decisions now
  take the same single-action slot the operator-confirm path takes, so the
  Approvals header shows `[submitting]` the instant a decision key lands and a
  repeat press during the server round trip is refused instead of dispatching a
  duplicate resolve (#31803). The surface also lists the standing always-allow
  rules (#31819) and carries the reviewer's stated reason on an approval
  (#31821).
- **New Runtime and Config surfaces in the TUI.** The Runtime surface lists
  every runtime rather than only the assigned ones (#31790), adds lane failover
  candidates and repairs its scroll (#31806), and a self-hosted server declares
  what it can actually do (#31823). A Config pane puts each model's two runtime
  knobs in one table (#31817), and a turn can widen its own tool set (#31818).
- **Keeper identity, sandbox, and GitHub App.** A GitHub App
  installation-token broker issues scoped tokens (RFC `keeper-github-apps`,
  #31766), `masc_keeper_up` advertises the microvm sandbox profile (#31764), an
  omitted `sandbox_profile` resolves from the TOML declaration rather than
  defaulting to the playground (#31786, #31789), identity scalar redaction
  becomes a runtime toggle (#31787), and a keeper either exists or it does not —
  the retirement fact is dropped (#31717).
- **Verification does not stall on bad input.** An unreadable artifact reaches
  the judge instead of leaving the Task waiting forever (#31802), and a
  checkpoint whose payload cannot be encoded is recovered rather than lost
  (#31779).
- **Dashboard slimming and dependency floors.** Caller-less dashboard exports,
  never-mounted config blocks, and seven weeks of unloaded `ds-*-kit` CSS are
  removed (#31737, #31741, #31748, #31754), and a light refresh no longer rides
  on a full-refresh waiter (#31804). `tls` moves to 2.1.2 so a client checks the
  server certificate's usage (#31827), and esbuild, @babel/core, and three
  vulnerable transitives are lifted past their patched floors (#31799, #31792).

## [0.27.0] - 2026-08-29

- **A page's own tools reach a Keeper — WebMCP.** The dashboard registers a
  closed read-only set on `document.modelContext`, so a browser agent reads
  masc status, tasks, keepers, goals, and board through the page instead of
  scraping it (#31601). A Keeper consumes the other direction: `keeper_webmcp_list`
  and `keeper_webmcp_call` drive an operator-run Chrome over CDP through an
  embedded bridge, so a Keeper calls the tools a page registered, with every
  missing prerequisite a typed refusal (#31626). Three further lanes are designed
  with explicit gates — an ecosystem sensor that watches for external sites
  turning WebMCP on, a userscript framework for credential-delegated reads, and
  a human-armed mutating surface (#31673). `docs/rfc/RFC-webmcp-*.md`.
- **The coding-outcome eval is wired end to end.** A corpus, runner, and report
  CLI score a Keeper's coding outcome (#31592), the judge reads its calibration
  examples before ruling (#31598), an operator labels a verdict from the TUI to
  close the judge's loop (#31619), and the first virtual-project mission
  reproduces a paper's claim (#31591).
- **Validated plans and async recipes persist durably.** Composition encodes
  validated plans (#31604) and a durable async-recipe codec (#31624), and
  accepted descriptor drift is typed rather than guessed (#31656, #31662).
- **Tool definitions move out of OCaml into TOML.** The last three OCaml tool
  schemas become TOML (#31674), continuing the migration so a tool's name,
  description, and schema live in one editable file.
- **TUI.** Each goal row shows its open work (#31659), Acting folds a turn's
  lifecycle into one row (#31559), and task review nests under planning (#31578).
- **The manual compaction subsystem is removed.** The compaction executor and
  its observation residue are gone (#31582, #31623, #31666) — compaction is
  reactive survival, not an operator entry point.

## [0.26.0] - 2026-08-29

- **A Keeper can carry its own outside identity.** Attaching Jira, Slack,
  GitHub, or any of the other work services to a Keeper started this train at
  zero (#30780) and reached 34 services within days (#30867, #30893), with
  Google's eight apps (Gmail, Drive, Docs, Sheets, Slides, Calendar, Chat,
  Contacts) sharing one OAuth client (#30932) and a slot for masc's own
  registered apps where Slack, GitHub, and Figma needed one (#30917). Both the
  TUI and the dashboard drive the same attach flow (#30822, #30830), and the
  attached service's own tools reach the Keeper once it is connected (#30822).
  `docs/KEEPER-IDENTITY-MANUAL.md` (and its Korean twin) is the current count
  and the setup path for each of the two cases — the ones that just work and
  the ones that need an app first.
- **RFC-0393 removes name-encoded Keeper identity as a hard cut** (#31198):
  the encoding was a parallel identity representation with its own decode
  failures; nothing reads it after this PR, and nothing converts it either.
- **External service calls now route through a durable Gate** (#31124): lanes,
  replay, and grants persist the same way task and goal state already did, so
  an approval survives a restart instead of living in memory. A Keeper can be
  pinned to a stricter judge than the workspace default (#31128), and which
  judge asks first is a per-Keeper order rather than one global list (#31134).
- **Skills gained an evidence trail.** What used to be a declared capability
  with no record of use now has an activation ledger (#30752) frozen at each
  Keeper turn boundary (#30732), a composition ledger that joins the natural
  turn to what it actually invoked (#31258), and a visual flow studio in both
  TUI and dashboard for editing one (#31115, #31389 with CAS preview). Editable
  revisions can be deleted outright once superseded (#31402), and the proof
  the TUI and dashboard render now scopes to the exact runtime tuple that
  produced it rather than the catalog in general (#31549, #31552).
- **Keeper sandboxing gained two lanes beyond Docker.** A `microvm` profile
  runs turns in Apple container guests and refuses rather than silently
  falling back when a guest cannot be sized (#31253, #31334); an SSH remote
  exec lane reached its endpoint-provisioning phase (#31409 through #31459).
  Underneath both, RFC-0394 Phase 0 makes the `local` sandbox profile
  fail-closed by default — a Keeper that would have quietly run on the host
  now refuses unless `MASC_EXEC_ALLOW_LOCAL_PLAYGROUND` says otherwise
  (#31202).
- **An assembler can propose a plan durably.** Proposals are typed, bound to
  an execution request, stored, and run asynchronously with their provenance
  preserved end to end (#31450 through #31491) — a Keeper's plan no longer has
  to be re-derived from scratch if the process that proposed it is gone by the
  time it runs.
- **The terminal UI kept growing past the 20 surfaces 0.25.0 shipped.**
  Surfaces converged on one shared chrome contract instead of each drawing its
  own header and hint row (#31287, #31265), Skill activation and cross-Keeper
  use became a first-class timeline (#31269), and Goal and Task detail panes
  gained their own history views (#31394) alongside the judge's actual
  evidence on Verification (#31447). `docs/TUI-GUIDE.md` names all 20 in Tab
  order.
- **The dashboard picked up the same operational signals.** The Keeper roster
  glows while a turn is in flight and clears when it lands (#31280), shows
  which Keepers are mid-answer without opening each one (#31222), and warns
  on screen when the served bundle is older than the server that built it
  (#31210).

This train is `687` commits over `v0.25.0..v0.26.0` — roughly a fifth each in
`tui` and `keeper`/`skills` combined, with `identity`, `dashboard`, `gate`,
`runtime`, and `harness` making up most of the rest. The bulk of it is not
listed above one PR at a time; this entry names the shape of the train, not
every stop.

## [0.25.0] - 2026-08-25

- **The terminal UI is where you drive Keepers now.** 104 of the 188 features
  in this release are `feat(tui)`, and they arrive in two arcs. The first made
  it an operator surface: approvals you can answer (#29466), a Keeper chat that
  survives a restart (#29317, #29619), Board posts and votes written from the
  terminal (#29747, #29787), goal phases changed from Planning (#29765),
  scheduled automation listed and cancelled (#29814), and a subscription to the
  runtime event feed in place of polling (#29857). The second made it a code
  surface: a Code browser that lexes the file it opens (#30414), `H` for the
  commits that touched it (#30489), `d` for its working-tree diff (#30527), `m`
  for the notes anchored to it (#30530), `c` for the edits a Keeper recorded
  (#30548), `/` to search its lines (#30574), and `K`/`D` to ask the language
  server where a name comes from with `B` to walk back out (#30565, #30578).
  Twenty surfaces rotate on `Tab`; `docs/TUI-GUIDE.md` is the key-by-key
  reference.
- **`masc-tui` ships with a release** (#30566): the terminal UI was reachable
  only from a source checkout, which no issue or roadmap line had ever decided
  — the release workflow simply never caught up with it. It is built, smoked,
  and packaged as `masc-tui-<arch>`, and `install.sh` puts it beside `masc` and
  prints the command that starts it. The runner cannot boot a program that
  requires a TTY, so the smoke calls `--help`, which returns before that check
  and still proves the shipped file resolves its dynamic libraries.
- **A language server both a Keeper and an operator can ask** (#30494, #30539,
  #30560, #30571): one server per workspace answering three questions, exposed
  over REST on the workspace axes, reachable from a Keeper's tools and from the
  TUI's Code pane. References answer across files once the server can.
- **A Keeper's tool surface is declared per Keeper** (RFC-0389 #29986,
  RFC-0390 #30119): `keeper.tools` in the TOML selects the bundle, and a Keeper
  with no declaration keeps exactly the surface it had before the feature —
  pinned by a golden that counts tools and schema bytes.
- **A Claude Code Keeper sees the image** (#30567) rather than a reading of it:
  the stream-json user message always carries a content-block array now.
- **The `classic` preset starts** (#30580): its four prompts lived in
  `keepers/<name>/AGENT.md`, and nothing has read that filename since the
  prompt moved into `keeper.instructions`. Every Keeper the preset seeded was
  rejected at load. The prompts are in the TOMLs, and a test reads every preset
  so the next one cannot rot the same way.
- **The front-door docs describe what is there.** Both READMEs are rewritten
  around the three ways in — MCP, dashboard, terminal UI — with the dashboard
  screen inventory recaptured against this release and terminal surfaces added
  (#30558). `docs/KEEPER-USER-MANUAL.md` and its Korean twin are rewritten from
  a running fleet: which TOML fields Keepers actually set, what the Gate's
  three layers are, and why a runtime lane wants more than one candidate
  (#30585). Twenty documents whose subject no longer exists are deleted.

- **iMessage runs inside the server** (#24497): the Python sidecar under
  `sidecars/imessage-bot/` is deleted. The server now reads Messages.app's
  SQLite store and replies through `osascript` on its own poll fiber, the
  third connector to move in-process after Discord (RFC-0203) and Slack
  (RFC-0317). Liveness is a value the poll fiber publishes rather than a file
  a second process wrote, which is the class the connector's four defects on
  2026-08-16 all belonged to (#28848, #28855, #28869, #28882). Replies from a
  resumed keeper now return to the conversation that asked: iMessage has a
  continuation-channel variant, so it no longer resolves to `Unrouted` and
  drops the answer. An unbound conversation is no longer forwarded to a
  default keeper — Messages.app holds personal correspondence, so binding is
  what decides delivery. The env vars are `MASC_IMESSAGE_REPLY_MODE`,
  `MASC_IMESSAGE_SELF_CHAT_GUID`, `MASC_IMESSAGE_POLL_INTERVAL_SEC`,
  `MASC_IMESSAGE_CURSOR_PATH` and `MASC_IMESSAGE_CHAT_DB_PATH`; the sidecar's
  `IMESSAGE_*` spellings and its `status.json` are gone, and
  `/api/v1/sidecar/*?name=imessage` now 404s.

## [0.24.0] - 2026-08-22

- **Goal completion passes through verification** (RFC-0387, #29152 → #29258):
  a Goal must declare a success condition, `request_complete` moves
  `executing -> verifying` instead of completing, and the verifier agent reads
  the durable verification ledger, inspects the linked task artifacts before a
  verdict, and records each run as an observation the dashboard API projects.
  The dashboard renders the `verifying` phase and the Work goal detail is built
  around the completion criteria; attainment is no longer derived from the
  lifecycle phase.
- **Tools compose and run in parallel**: tool kind is a closed sum type
  (RFC-0386, #29148); audited read-only descriptors declare composable output
  schemas and run as `Concurrent` batches (#29012, #29017, #29146); and
  `keeper_plan_execute` (#29021) lets the model define a typed DAG of tool
  nodes in its turn with the same vocabulary as `tool-compositions.toml`.
  Rejections carry the composable tool list so the model can correct itself.
- **No duplicated streaming text** (constitution B5, #29149): OpenAI-compatible
  servers that resend the accumulated text on every chunk are deduplicated at
  the stream bridge; the Anthropic and Responses paths were already
  incremental.
- **A dashboard purge that died mid-way has an exit** (#29295): three Keepers
  sat half-removed for three days while reconcile retried about 238 times an
  hour. The blocked purge is now a typed operation with a release path; the
  dashboard refuses a purge while the Keeper is still executing and shows an
  asynchronous purge as in progress.
- **Channel-aware autonomous instructions**: `autonomous_instructions` flow
  through turn-up and the `Update_profile` reducer and select the prompt
  channel for `Scheduled_autonomous` turns.
- **Keeper runtime projections**: the shutdown operation phase and admission
  fence are visible on `keeper_status`; runtime serving receipts are verified;
  the compaction saving reaches the owner projection; autonomous turns are not
  replayed as conversation (RFC-0385 §5.1).
- **Legacy readers are gone**: the first purge sweep removed readers, default
  values and converters kept for earlier on-disk shapes across 61 files
  (#29379), `active_goal_ids` and its surfaces are removed (#29374), and the
  `Dead` phase, tombstone latch and `Keeper_measurement` are deleted. Stores
  written by earlier versions are not migrated; the decoders reject them.
- **Issue triage is declarative** (#29309): the issue body's `masc-triage`
  block is the single source of labels, the vocabulary is four closed axes
  (`kind`, `area`, `impact`, `root`) plus `must-do`, and the `impact` order is
  the priority order.
- **The quickstart and release path run as documented** (#29302): the source
  quickstart starts the workspace server without Keepers or a provider key and
  reaches an authenticated MCP initialize; the stale Homebrew formula and the
  duplicate quick-start document are removed.
- **Dashboard**: global autonomous-turn expand toggle, runtime observables in
  the Monitor lane, recorded tool-call evidence decoded with the composition
  tree, a Keeper can be removed from the screen with its chat store swept, and
  `pnpm lint` runs in CI.
- **Build**: warning 69 (unused record field) is a build error alongside 32;
  the dead-export ratchet and the changed-files `ocamlformat` check run on every
  PR.

## [0.23.0] - 2026-08-16

- **Keeper broadcasts reach the other Keepers' prompts**: projecting a fleet
  broadcast into every other Keeper's transcript got the row to the dashboard
  and no further. The prompt's `Pending Messages` section renders only rows that
  mention this Keeper or that the Owner authored, and nothing else read the
  transcript into context. A `Fleet Messages` layer now carries the newest
  `keeper.fleet.messages.max` projected rows (default 10, `0` disables) as
  standing context. Selection reads the typed `Surface_ref.Agent` surface, and
  the lane predicate is shared with the reactive lanes so no row can render in
  both sections. No acknowledgement cursor: lane ack advances only on
  autonomous turn success, so a Keeper with `proactive_enabled = false` would
  otherwise accumulate rows forever. Measured on an isolated instance: the
  probe string appeared once in the transcript and not at all in the rendered
  prompt before, and once in both after, with the mention rendered once under
  `Pending Messages` and the two broadcasts once under `Fleet Messages`.
- **The direct-keeper-message path reads no transcript**: an earlier cut of the
  fleet layer called the uncapped `Keeper_chat_store.load_all` there, on a path
  that performs no transcript I/O otherwise, costing a full read and parse of
  the whole store per direct message — the largest in production was about
  1.8 MB over roughly 2,900 rows, and it is append-only. That path
  empties the reactive lanes because the triggering message is the point; the
  Keeper sees fleet context on its next observation turn, where the load
  already happens.
- **Approved Gate resolutions are delivered past queue-ordered stimuli**: a
  turn suspended at an approval gate resumed on a redelivered workspace message
  rather than the approval, so `hitl_resolution` was absent and the host replay
  never fired.
- **The agent surface badge no longer claims a row is the viewer's own**: it
  read `Agent (Self)`, which held while that surface carried only the viewed
  Keeper's traffic. Projected broadcasts share the surface, so the badge named
  the wrong Keeper; the speaker chip beside it already identifies the author.
- **`LspCall` rpc and the inline LSP dispatcher are removed** from the gRPC
  surface.
- **Build**: the commit-stamp rule moved to a `lib/build_commit` leaf, dead
  dune descriptions were removed, and the health snapshot no longer archives
  the purged `examples/` root — that pathspec made `git archive` exit 128 and
  failed the required `CI Gate` on every PR. The same change restored
  `dune build @check`, which a test applying a `private` variant directly had
  broken; both landed inside this window, so no release carried either.

- **Workspace messages reach the linear event queue**: a workspace message
  that names a Keeper is committed as a typed
  `Keeper_event_queue.Workspace_message` entry in that Keeper's per-Keeper
  drain, ordered against every other stimulus and deduplicated by the
  workspace request id. The same path now emits the `keeper_chat_appended`
  SSE it was missing, so the conversation window updates without a reload.
  Measured on an isolated instance: one addressed message produced zero queue
  entries before and one `workspace-message:<request_id>` entry at urgency
  `immediate` after.
- **Keeper speech reaches every Keeper's conversation window**: a committed
  `Fleet_conversation` message is projected into each registered Keeper's
  transcript (author excluded), with no queue entry and no wake, so one
  announcement cannot open a turn on every Keeper. Before this, 17 of the 18
  retained workspace messages were unmentioned Keeper broadcasts that reached
  nobody — the dispatcher answered `Passive` without calling the delivery
  handler at all. The projected row's mentions are still derived from the
  message text, so a second `@name` in one message reaches that Keeper as a
  transcript mention without a queue entry (masc#28795).
- `Workspace_broadcast.audience` is a **required** argument, so the compiler
  makes all 14 library producers state their answer. Five are speech —
  `masc_broadcast`, `keeper_broadcast`, the gRPC `Broadcast` RPC, the operator
  dashboard route, the operator control action — and nine are records: task
  claim, task create (2), task transition, session lifecycle (3) and workspace
  init (2). Records reach no conversation window. It was optional at first,
  and that silently classified `keeper_broadcast` — the only broadcast tool
  live Keepers use, 55 of 55 calls in the reference traces — as a record, so
  the projection was dead on the only path production exercises.
- Measured cost of projecting one message across the reference fleet: 4.53 MB
  of locked transcript across 39 registered Keepers, 22-95 ms per append
  against a broadcast that otherwise takes 33 ms.

## [0.22.0] - 2026-08-14

- **Breaking (keeper output contract, RFC-0376)**: an autonomous turn's final
  text no longer auto-delivers to the channel that woke it. The
  continuation-delivery outbox/publisher/recovery subsystem and the schedule
  result-delivery dashboard view are removed; keeper speech reaches connectors
  only through speech tools (`keeper_surface_post` / connector posts), and the
  connector-attention ledger consumes the typed continuation-route disposition
  carried by `Turn_completed`. Live measurement before/after: obligation
  growth +11/hour under the old path, zero after, with real replies unaffected.
- **Keeper turn batching (RFC-0377)**: one turn consumes the pending backlog
  of a single conversation together (one-scan batch read, pure batch
  disposition) instead of one stimulus per wake.

- **Breaking (agent execution ownership)**: MASC now owns its execution engine
  as the embedded `masc.agent_core` library. Runtime modules, configuration,
  environment keys, telemetry, dashboard events, persistence fields, and
  public OCaml types use the Agent Core contract directly. No alternate module,
  wire name, environment key, storage decoder, or compatibility facade remains.
- **Breaking (startup/task storage contract)**: startup health and readiness
  now expose only lifecycle, lazy-task, readiness, error, and path/config
  diagnostics. Task operations bind directly to the supplied Workspace
  configuration, and the server-state product models only lifecycle,
  lazy-task, and readiness dimensions.
- **Breaking (cost ledger storage/schema)**: the Keeper producer, `masc-cost`,
  and inference metrics now share one current row codec and the date-split
  `.masc/costs/YYYY-MM/DD.jsonl` store. Automatic rows carry the runtime-owned
  `(trace_id, keeper_turn_id, agent_core_turn_ordinal)` identity, so decision/cost
  observations merge only on exact identity; nearby timestamps and equal token
  counts no longer act as a deduplication rule. Windowed readers open only the
  requested day range, and malformed rows, schema violations, or duplicate
  identities remain explicit diagnostics. The `masc-cost --json` envelope now
  uses `state` instead of `status`, and `by_agent[]` no longer emits one
  misleading `model` value for aggregates that can span multiple models. No
  alternate store, field-name decoder, migration, or repair path is present.
- **Breaking (approval snapshot wire)**: `summary_status.failed.retryable`
  is no longer accepted and discarded while loading pending approvals. Current
  snapshots contain only `status` and `reason`; snapshots carrying the retired
  field fail closed through the existing unavailable-store path. No migration
  or repair path was added.
- **Keeper tool admission**: identity-translated `Execute`, `WebSearch`, and
  `WebFetch` payloads now use the public descriptor validation as their single
  schema Gate. Translation shape and validation ownership now share one typed
  descriptor field, so shape-changing translators such as `Grep` retain
  post-translation validation without an independent boolean.
- **Breaking (recall injection ledger)**: schema v3 adds a required typed
  `reset` marker. The first row for each keeper process now resets replay state
  before applying its exact current baseline, so keys deleted across a process
  restart cannot survive durable materialization. Schema v2 rows are rejected;
  no compatibility reader or migration path was added.

### Removed
- **Breaking (host FD-pressure path)**: removed the retired
  `MASC_SYSMON_PRESSURE_STATE` environment fallback from both the sysmon
  producer and server poller. The live pressure path now has one override,
  `MASC_HOST_FD_PRESSURE_STATE_FILE`, plus the explicit runtime base path from
  `--base-path` or `MASC_BASE_PATH`; repo/cwd fallbacks are rejected.
  Split-brain conflict detection and the public legacy env helpers were removed;
  no migration or compatibility path was added.
- **Breaking (workspace root state)**: removed the pre-rename
  `.masc/state.json` fallback from the cluster-root initialization check and
  removed its public path helper. Workspace, dashboard, keeper-directive, and
  gRPC root gates now recognize only the current `.masc/root-state.json`
  marker already written by init/bootstrap. No migration or repair path was
  added.
- **Breaking (Memory OS retention)**: removed the periodic full-store LLM
  consolidation fiber, its runtime route, env toggle, prompt/schema, dashboard
  projection, and tests. The bounded Librarian still upserts producer-declared
  facts; GC deletes only rows past an explicit `valid_until`. There is currently
  no semantic supersession/tombstone path, so an unexpired row is retained and
  no score, clock, or model sweep may silently retire it.
  - Deployment precondition: before deploying this build, remove
    `memory_os_consolidation = ...` from the live
    `<base-path>/.masc/config/runtime.toml`. Confirm the key is absent with
    `rg -n '^[[:space:]]*memory_os_consolidation[[:space:]]*=' <runtime.toml>`;
    any match blocks deployment.
  - After deploying, restart normally and require
  `curl -fsS 'http://127.0.0.1:8935/health?full=1'` to succeed. The new parser
  rejects the retired key as unknown; no compatibility parser or automatic
  migration is retained.
- **Breaking (keeper chat wire)**: removed read-time message-id synthesis for
  rows without a persisted `id` and removed the duplicate persisted `source`
  lane label. Current chat rows require a nonblank producer-assigned `id` and
  persist only typed `surface` identity; history/timeline/lane consumers derive
  the compact source label from that typed field. The unused
  `Gate_surface.of_source` compatibility facade was also removed. No migration,
  repair, or string-to-surface fallback was added.
- **Breaking (viewer TRPG transport)**: removed the compiled but unreachable
  legacy TRPG EventSource transport, event vocabulary, reconnect state, and
  teardown branch. The TRPG viewer now has one transport: the existing MASC
  `/api/v1/trpg/stream` JSON polling loop. Monitor, Social, and Experiment SSE
  remain owned by the separate MASC SSE client.
- **Breaking (telemetry wire/storage)**: removed the retired
  `Agent_joined`/`Agent_left` decoder aliases, the `.masc/telemetry.jsonl`
  fallback reader, and the producer-less `Handoff_triggered` event plus its
  derived `handoff_rate`. Telemetry now reads only the current date-split
  `.masc/telemetry/YYYY-MM/DD.jsonl` store and rejects retired event variants.
- **Breaking (Fusion board metadata)**: removed duplicate `source` and `run_id`
  keys from Fusion `meta_json`. Board `origin.source` and
  `origin.fusion_run_id` are now the sole typed identity consumed by the Board
  evidence and Fusion dashboard features; posts without that current origin
  are not admitted to those surfaces.
- **Breaking (recall injection ledger wire)**: removed the retired
  `schema_version=1`/missing-version full-snapshot decoder, its public
  serializer, the unused option compatibility decoder, and the unused
  read-error labeling facade. Recall injection rows now require exact
  `schema_version=3` reset/Delta fields. The current writer,
  full-history outcome-evaluation replay, invalid-row accounting, and
  retention behavior are unchanged; no migration or repair path was added.
- **Breaking (keeper failure wire)**: removed the bare
  `fiber_unresolved` failure-reason projection retained for historical log and
  dashboard matching. Unexpected unresolved fibers now serialize as
  `fiber_unresolved(unexpected)`, alongside the existing
  `graceful_shutdown` and `cancelled_by_parent` causes. The current
  `fiber_unresolved` blocker/cohort class is unchanged.
- **Breaking (keeper sandbox cleanup wire)**: removed the three-field
  `docker inspect` cleanup payload decoder used only by containers created
  before the `masc.mcp.ttl_sec` label existed. Current four-field payloads
  remain exact, including an empty fourth field when no TTL is configured;
  malformed owner PID, start time, running state, or TTL values now fail
  closed. No migration or repair path was added.
- **Breaking (inference metrics wire)**: removed the
  `provider_tokens_per_second` compatibility field and decoder fallback.
  Provider-native decode throughput now has one wire key,
  `hw_decode_tokens_per_second`; wall-clock throughput remains separately
  represented by `tokens_per_second`.
- **Breaking (keeper config schema)**: removed the keeper TOML `base = "..."` inheritance mechanism. `keeper.base` is no longer a recognised key, `config/keepers/base.toml` and `presets/classic/keepers/base.toml` are deleted, and every keeper TOML now states its own values. Effective per-keeper profiles are unchanged: each formerly inherited value was written out explicitly (`config/keepers/{taskmaster,issue_king,verifier,adversary}.toml`, `presets/classic/keepers/{backend,frontend,qa,tech_lead}.toml`).
  - Migration order matters. A keeper TOML that still carries `base = "..."` after this build is deployed does **not** fail to boot: `keeper.base` becomes an unrecognised key, so the keeper loads while silently losing every value it used to inherit, with one `Log.Keeper.warn`, a `masc_config_unknown_keys_ignored_total` increment, and a row on the dashboard drift surface. `/health` additionally reports `keeper_config_schema: config_unknown_keys` with status `blocked` and `operator_action_required: true` for the whole server (`server_routes_http_runtime.ml:479-488`). Flatten the deployed TOMLs first, then deploy this build.
  - Keeper prompts now have one authoring source: `<keeper>/AGENT.md`. Keeper TOML stores the Keeper handle and operational settings without copying the prompt.

### Changed
- Agent Core compaction projects exact credential-free request-body bytes
  through the provider serializer and output requirement used by admission,
  without duplicating serializer or provider/model limit logic in MASC.
- The Agent Core GLM streaming backend consumes the catalog-resolved typed
  reasoning dialect instead of hardcoding `reasoning_content`; MASC's
  deployment overlay declares the exact `delta:reasoning_content` capability
  for both GLM-5-Turbo provider bindings.
- Provider materialization and registry/model-string resolution now share
  `Runtime_provider_binding.default_headers_for_kind` as the sole owner of
  non-credential provider header defaults. The duplicate Runtime adapter
  table and unused `headers_with_auth` public surface were removed; auth
  tokens remain carried only through Agent Core `api_key`.
- Workspace broadcast delivery now returns the canonical content, mention, and
  message type produced by its single terminal-task invariant check. MCP
  session/SSE/notification/audit consumers reuse that exact result instead of
  pre-running the invariant through a bypass flag.
- Agent Core accepts provider-specific stop-reason dialects such as
  `context_length_exceeded` and `max_context_length`, and preserves empty GLM
  completion stop reasons so context overflow cannot become an orphan retry.
- Agent Core accepts empty initial SSE delta `id` and `name` strings as
  `Ok None`, preventing stream failures on GLM-5-Turbo and compatible backends.
- Malformed artifact markers that end before all required fields now return the
  typed `Invalid_marker` result instead of escaping as `End_of_file` during
  tool-blob maintenance.


## [0.21.2] - 2026-07-20

### Changed
- Bumped the agent_core Agent SDK pin from `v0.217.1` to `v0.217.3` (`cbc5168e`). Absorbs 0.217.2 (`reasoning_replay_dropped` logs at Info) and 0.217.3: the Ollama native tool-loop replay/correlation now flows through an immutable occurrence-scoped projection that rejects legacy User-role ToolResult and uncorrelated tool messages typed on Gemini/Ollama-native instead of silently repairing them (, supersedes ), and durable `Error_occurred` error_domain is classified from the error rather than hardcoded `"Api"`. Public Agent SDK surface fingerprint unchanged (only the pin sha/version move). Live checkpoint audit 2026-07-20: 24/24 primary checkpoints carry zero legacy shapes, so the hard-cut is inert on the current fleet.

## [0.21.1] - 2026-07-20

### Changed
- Re-cut of the 0.21.0 release line: the `v0.21.0` tag points at a commit whose generated `masc.opam` still carried version 0.20.1, so its own version-truth gate (and the tag-triggered release workflow) fail on it. 0.21.1 is the first version-truth-clean release commit; `v0.21.0` remains an unpublished historical tag. Also aligns the previously ungated `masc.opam.locked` version field (was 0.19.54) and the ROADMAP/PRODUCT-OPERATING-PLAN/SPEC-INDEX version headers.

## [0.21.0] - 2026-07-20

### Changed
- Bumped the agent_core Agent SDK pin from `v0.216.5` to `v0.217.1` (`8147cfc7` chain). Absorbs the 0.217.0 breaking change — streaming rejects malformed tool-call batches whole-batch — plus resume totality over crash-reachable journal states (/), overflow wire finish_reason decoding, finite retry_after parsing, admission-warning URL sanitisation, Kimi native token-count admission, admission-SSOT projected input, exact provider turn identity, and typed rejection of unencodable explicit thinking.
- Runtime prep for : the deployment `agent-core-models-overlay.toml` now declares `thinking_control_format = "none"` + `supports_reasoning = true` for the OpenAI-compatible `ollama_cloud` rows (`kimi-k2.6`, `minimax-m3`, `deepseek-v4-pro`), so `enable_thinking=true` keeper turns admit as declared-inherent reasoning instead of failing with `Enable_not_encodable` on the /v1 wire (2026-07-20 flip-risk audit).

### Fixed
- Keeper streaming responses now resolve a fail-safe inter-line idle timeout floor of 600 s (10 min) when neither `MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC` nor `runtime.toml`'s `turn.stream_idle_timeout_sec` is set. Previously the resolved value was `None` and agent_core applied no inter-line idle bound, so a hung provider stream (bytes stop arriving mid-response) froze the keeper chat lane until an external restart (#25128, measured 30+ min). An explicit env/toml value still overrides the floor verbatim; the boot log now states the effective idle timeout and its source (env/toml vs floor). Implements RFC-0345 Option A.
- CI now rejects mangled-module access to the three wrapped agent_core libraries linked by MASC and treats scanner errors as failures; the unused advisory `Llm_provider` text scans, retired/test source trees, comment/allow-marker bypasses, and nonblocking `|| true` invocation were removed from the guard.
- The Ops surface now preserves and displays the operator snapshot's typed context-metrics storage and malformed-row failures per Keeper instead of presenting unavailable context as an unexplained blank value. Invalid diagnostic wire payloads remain explicitly visible as contract failures.
- The process supervisor now records the real server exit code: `|| true` before `exit_code=$?` reported every exit — including SIGSEGV (139) and SIGTERM (143) — as `code=0`; exits above 128 additionally decode the signal name. Takeover kills now leave a JSON breadcrumb next to the pid lock, the victim's SIGTERM path logs the attribution (or its absence: external sender), and the next boot reports a breadcrumb after a SIGKILL escalation.
- Keeper context projection no longer reads persisted metrics rows. Current
  snapshots expose typed `not_observed` occupancy and keep provider-reported
  last-turn usage separate; no legacy decoder or metadata fallback remains.

### Removed
- **Breaking (Keeper metrics/context wire)**: current turn and heartbeat rows
  now require `schema="keeper.metrics.v1"` plus typed `record_kind`; versionless
  rows are not decoded and no migration path was added. Provider usage presence
  and its timestamp are tracked as one process-local typed observation,
  independently from the latest turn attempt; restart returns it to unobserved
  instead of inferring it from persisted token counters. Removed fabricated
  context occupancy, producer-less metrics fields/compaction history,
  tool-name aliases and decision-log guessing, duplicate handoff generation
  keys, the dormant context-bearing agent_core keeper snapshot publisher/decoder, and
  the `keeper_context_status.last_model_used = null` placeholder. Both current
  context-status descriptors now state that occupancy is not observed.
- Removed the zero-consumer Keeper compaction policy authoring record: profile aliases, hardcoded threshold tables, ratio/message/token Runtime params and env knobs, keeper-up/schema/meta fields, status/config projections, and dashboard controls. Retired inputs and persisted fields now fail explicitly; the typed compaction runtime, owner-lane execution, provider-overflow recovery, and durable observations remain unchanged.
- Removed dead compaction ratio/message/token gates from Keeper status, metrics, TUI, dashboard config, and PATCH surfaces, including the unused `context_within_budget` FSM condition and inferred dashboard threshold marker. Observable compaction transitions now name the typed `Compaction_started` event; no UI fallback manufactures a gate.
- Removed the superseded `Runtime_agent.media_reroute_candidates` helper (the live reroute path builds candidates inline) and narrowed `Keeper_runtime`'s interface to its live supervisor operations. No replacement: zero external consumers.
- Removed the public MASC JSON Schema classifiers `Tool_bridge.param_type_of_string` and `Sdk_tool_contract.param_type_of_schema_opt`, plus the zero-consumer `Sdk_tool_contract.tool_params_of_input_schema`. Consumers must use the agent_core-owned `Agent_sdk.Mcp.json_schema_to_params`; missing, unsupported, or ambiguous property types now fail at that boundary instead of defaulting to `String`. No compatibility alias remains.
- Removed the unreferenced synchronous `Dashboard_snapshot.current_or_bootstrap` full-bootstrap path. Dashboard requests continue to use the live immutable snapshot or their existing projection-specific cold fallback; no compatibility path remains.
- Removed the dead board-backend env chain (`MASC_BOARD_BACKEND`, `Board.backend`, test-only `Board_dispatch.jsonl_forced`), the reader-less `Discovery_history` store and its `masc_discovery_history_failures` metric, the caller-less bench-canary reader (`MASC_KEEPER_BENCH_CANARY_*`), and `Local_runtime_pool.select_runtime_from`. No replacement: none of these had a production consumer.
- Removed the never-read `Exec_cache` plumbing from `masc.masc_exec`, the `masc.worker_runtime_config` library, and the three `MASC_WORKER_RUNTIME_*` env knobs (backend/docker-image/host-MCP-URL) whose only reader was that library — the knobs no longer appear in the operator snapshot or the tunables catalog. No replacement: nothing dispatched on them.
- Removed the dead external-MCP voice session/conference cluster (~380 lines: session/conference lifecycle, health cache, `call_session_tool`, unraised `Timeout`) from `voice_bridge`; superseded by the local `Voice_session_manager`. The live local voice API is unchanged.
- Removed the retired `Autonomous_bridge`/`Autonomous_state` modules (~540 lines) whose keeper wire-in was already deleted by #24765, plus a foreign `session_tracker` QA test targeting a PostgreSQL module that never existed in this repo. `Autonomous_phase` stays live via the autonomous routes. No replacement: the surfaces had no production consumers.
- Removed 12 dead root modules with zero production consumers (`evidence_ref`, `exec_shell_adapter`, `retrieval_projection`, `masc_error_recovery`, `state_product`, `prompt_composer`, `team_context`, `tool_name_alias_axis`, `attribution_tagged`, `timeout_policy`, `runtime_deadline`, `runtime_provider_credentials`) — a 2,527-line public typed API cut across `masc`/`masc.runtime`/`masc.masc_core`. No replacement: every surface was self-consuming (tests only).
- Removed automatic config-root, cwd-parent, executable-parent, and `MASC_MODEL_CATALOG` full-catalog discovery. agent_core's embedded catalog is now the only base; `agent-core-models-overlay.toml` carries deployment-local rows, while `OAS_MODEL_CATALOG` remains an explicit operator override.
- Removed the per-turn prefix/string heuristic that rewrote unknown-looking
  prompt tokens. Keeper prompt prose now describes behaviour, while the active
  typed tool schema is the sole authority for tool names and availability.
- Removed the generic Governance pipeline, risk taxonomy, unconditional deny/operator floors, command/tool-name authorization heuristics, global resource admission blockers, and failure-derived Keeper pauses. External effects now converge on exact Always Allowed, configured LLM Auto Judge, or nonblocking HITL; objective typed input/path/sandbox invariants remain at execution boundaries.
- Removed product-specific credential/JWT wiring and direct continuation-delivery bypasses from the Keeper runtime. Connectors and credentials remain outside the product-neutral Gate boundary.
- Removed the no-op Keeper cost guard and arbitrary per-Keeper waiting cap. Cost, token, turn, FD, disk, provider health, and queue depth remain observable without becoming authorization or fleet-wide stop conditions.
- Removed the unused permissive `Activity_feed` JSON decoder surface; the live activity API remains encode-only and its filesystem aggregation, ordering, limit, and agent-filter contracts now have dedicated regression coverage (#23960).

### Fixed
- Keeper lifecycle reservations now use cooperative cross-context locking, so
  TOML reconciliation can suspend during durable persistence without a second
  Eio fiber re-locking the same OS-thread mutex.
- Long-lived Keeper turn event-bus polling now uses a real tail-recursive loop;
  polling no longer retains one exception-handler frame per cycle until CPU and
  memory are consumed by stack scanning and GC.
- Auto Judge requests now persist the exact outer-turn causal context without interpreting it, and durable retryable judgments resume on an accepted provider attempt rather than waiting for a server restart.
- Keeper Gate state now has a BasePath-derived `.masc/gate/` owner. A corrupt optional Always Allowed rule store degrades only exact-rule lookup, while Chat persistence/read failures remain local to Chat and no longer close unrelated Keeper lanes.
- Prompt overrides now persist in a schema-versioned envelope bound to the SHA256 revision of each prompt body and template-variable contract. Legacy or malformed files and contract-drifted entries fail closed with observable fallback, writes use atomic replacement, and dashboard set/clear mutations commit to memory only after persistence succeeds.

## [0.20.1] - 2026-07-10

### Changed
- Bump agent_core pin to v0.209.0 (tag v0.209.0): catalog-driven provider capability + Anthropic thinking policy, typed empty-completion boundary convergence, Hooks.Block + 0.209 breaking release floor (/#2497). Exact pin SHA in `the pin script`.

## [0.20.0] - 2026-07-08

### Added
- RFC-0320 connector-aware HITL continuation delivery (W3a/W3b/W3c) — a `Hitl_resolved` wake resumes the keeper on its originating chat connector instead of stalling until an unrelated stimulus (#23628, #23639, #23663).
- RFC-0323 verification-required Done guard + goal matrix: state-keyed done (G-1), RFC-0199 probe through a verification lane (G-2), state-keyed completion side effects (G-3), and `predecessor_task_id` linked re-run (G-8) (#23665, #23668, #23680, #23687).
- RFC-0321 hard-block refusals switch to typed `Hooks.Block` (PreToolUse `is_error=true` policy rejection), PR-2 (#23654).
- RFC-0271 `Retry_no_thinking` recovery arm for thinking-only turns (§4.1) and typed `stop_reason` threading into `Accept_rejected` (§4.5) (#23648, #23720).
- RFC-0319 operator approval-mode backend (`Manual` | `Auto_low_risk` + segregation-of-duty invariant) (#23625).
- `gh pr merge` moved to `Ask` (Requires_approval); the deny floor is removed at the operator's discretion (#23618).

### Changed
- New RFC drafts: RFC-0325 (compaction LLM provider-agnostic structured output) and RFC-0326 (typed keeper failure classification). Renumbered the filesystem-truth RFC 0323 → 0324 to resolve a number collision (#23673, #23675, #23696, #23717).
- agent_core `agent_sdk` pin bumped to v0.208.22 (, masc #23697); consumer `.mli` surface unchanged.

### Fixed
- Keeper self-wake approval deadlock: `masc.keeper_wake` is now reminder-only (intrinsic risk class), ending the self-approval stall that produced empty placeholder replies (#23716).
- Repo-id clone denials routed to HITL with a typed clone-probe ADT (fail-closed on unknown repo-id) (#23638).
- `keeper_crud` `.mli` added and module-name reference fixed, recovering main from a fleet-wide Structure Ratchet / build red (#23683, #23688, #23692, #23702).
- `anti_rationalization` gate-0: a disabled gate now falls through to gate-1, and `evidence_refs` is threaded through all `review_request` construction sites (#23691, #23694, #23724).
- Workspace gate-0 rejection blocking resolved and task evidence enforced (#23719).
- Dashboard: top-bar ops chip ellipsis, fleet roster action-column width, Fusion surface copy tidy, generic title clamp (#23684, #23701, #23707, #23711).

## [0.19.56] - 2026-07-06

### Added
- Interactive install wizard in `scripts/install.sh` with TTY detection,
  typed provider catalog selection, secure API key prompting, and writing
  `.env.local` / updating `runtime.toml` defaults.
- `masc runtime-wizard-catalog` command that derives the install wizard
  provider catalog from the typed `runtime.toml` config, including provider
  healthcheck metadata.
- Provider connectivity ping during interactive install, using healthcheck
  paths declared in `runtime.toml`.
- `masc runtime-default-set` typed writer used by the installer to update the
  runtime default.

### Changed
- Runtime schema and TOML parser additions to support provider display names,
  credentials, endpoints, healthcheck paths, and concrete runtime bindings for
  the install wizard, with provider wizard defaults selected through explicit
  `wizard-default` binding metadata instead of declaration order or dashboard
  runtime default markers.
- Installer one-touch startup now seeds the agent_core model catalog, runs binary
  smoke checks with the installed base path/catalog environment, and prints a
  copy-paste start command with `MASC_BASE_PATH`, `OAS_MODEL_CATALOG`, and
  `MASC_RUNTIME_EVENTS=0` wired for clean Linux/macOS installs.

### Fixed
- Stop keeper infinite rotation on `capacity_backpressure` (#23383, Phase A of
  #23373). `degraded_reason_allows_candidate_cycle` now caps rotation for
  `Capacity_backpressure`; the keeper pauses once when candidates are
  exhausted instead of looping forever between two cooldown runtimes
  (incidents 2026-05-21, 2026-07-06).
- Expand rotation candidates to the full runtime catalog for transient
  infrastructure errors (#23392, Phase B-1) so failover reaches healthy
  runtimes outside the narrow `[base; default; phase_recovery]` set.
- Unbreak main build after #23353 red-merge: add missing type annotation and
  `(modules)` entry for `test_keeper_board_attention_candidate` (#23356).
## [0.19.55] - 2026-07-03

### Changed
- Bump agent_core agent_sdk pin to v0.208.14 (#23054) and bump masc version to
  0.19.55, following the v0.208.13 pin (#22950) that carried the 0.208.13
  release line.
- Align version truth across `dune-project`, `ROADMAP.md`,
  `docs/PRODUCT-OPERATING-PLAN.md`, and `docs/spec/SPEC-INDEX.md`.
- Bump agent_core agent_sdk pin to v0.208.12 (`2f3d6846`), carrying the
  default-unbounded agent turn budget release so MASC keeper/agent_core runs no longer
  inherit the older finite default turn cap.
- Bump agent_core agent_sdk pin to the 0.207.22 main follow-up (`c741324`),
  carrying #2254 typed GLM forced-tool-choice rejection, #2248
  provider-qualified capability lookup, #2244 assistant tool-content,
  fail-closed unknown-stream-block handling, and the post-merge agent_core format
  readiness repair after the earlier 0.207.21/0.207.22 CI failures and the
  stale inline-test fix from agent_core #2265.

### Fixed
- Resolve runtime capability validation and default preserve-thinking decisions
  through agent_core provider-qualified provider/model capabilities instead of bare
  model ids, so overlapping ids such as Ollama Cloud Kimi do not need
  bare-id manifest workarounds.
- Prune synthetic empty keeper replay suffixes from agent_core checkpoints and record a
  typed prune reason, preventing no-visible-output state snapshots from being
  replayed as durable assistant context.
- Stabilize keeper quick-suite tests under Dune sandboxing by resolving
  source-file assertions through `DUNE_SOURCEROOT`.
- Stabilize `keeper_msg_async` async persistence coverage by waiting for
  disk persistence before recovery/GC assertions.
- Default keeper preserve-thinking from agent_core typed request-side preserve
  capabilities instead of treating every thinking-capable runtime as
  preserve-capable.

## [0.19.54] - 2026-06-29

### Changed
- Bump agent_core agent_sdk pin to 0.207.16 and bump masc version to 0.19.54.

## [0.19.52] - 2026-06-29

### Changed
- Bump agent_core agent_sdk pin to 0.207.14 release and bump masc version to 0.19.52.
- Refresh the agent_core API surface fingerprint for `main@25a59927ea61d1c2b77e35c66aabb512e839eaff`, including the legacy provider compatibility shim purge.

## [0.19.51] - 2026-06-28

### Changed
- Bump agent_core agent_sdk pin to 0.207.12 release and bump masc version to 0.19.51.
- `dashboard`: Memory OS fact decoding now emits a development-console warning
  when a legacy wire payload still carries `external_ref`. The field remains
  intentionally absent from dashboard fact types/rendering; PR/issue text is
  context for the model, not a machine-readable external-state status tag.

### Fixed
- `gate`: Discord inbound messages now resolve `<@snowflake>` / `<@!snowflake>`
  user mentions to `@DisplayName` using the structured `mentions` array. This
  makes Discord-originated chat in the dashboard show human-readable names
  instead of raw ids. The existing platform surface badge already identifies the
  message as coming from Discord.

### Removed
- `dashboard`: documented the Memory OS `external_ref` dashboard API removal.
  Legacy payloads are ignored rather than re-rendered as status tags; producers
  must use future structured origin fields instead of relying on the retired
  dashboard `external_ref` surface.
- `runtime`: removed the legacy runtime storage selector. Storage is now
  filesystem-only by construction; operator/test environments must remove old
  backend overrides instead of expecting an in-memory backend.

## [0.19.50] - 2026-06-26

### Changed
- Bump agent_core agent_sdk pin to latest main and bump masc version to 0.19.50.

### Fixed
- `keeper`: playground repo policy visibility now reuses the keeper-repository
  mapping decision and reports `policy_source` consistently as
  `keeper_repo_mappings.toml` (#22329).

### Deprecated
- TBD

## [0.19.49] - 2026-06-26

### Changed
- `agent_sdk`: bumped the agent_core runtime pin from `v0.207.7` (`b84af27e`) to
  `v0.207.8` (`ecd509f4`, agent_core `main` HEAD) and raised the dependency floor to
  `>= 0.207.8` in `dune-project` / `masc.opam`. Pin metadata in
  `the pin script`, locked opam metadata, and the keeper user
  manual pin block were refreshed by #22359.

## [0.19.48] - 2026-06-22

### Changed
- `agent_sdk`: bumped the agent_core runtime pin from `v0.207.6` (`fdc35ccc`) to
  `v0.207.7` (`b84af27e`, agent_core `main` HEAD, release 0.207.7 #2166) and raised
  the dependency floor to `>= 0.207.7` in `dune-project` / `masc.opam`. This
  release pulls in the Ollama native `/api/chat` multimodal serialization fix.

## [0.19.47] - 2026-06-20

### Changed
- `agent_sdk`: bumped the agent_core runtime pin from `v0.207.3` (`57ed7272`) to
  `v0.207.6` (`57371405`, agent_core `main` HEAD, release 0.207.6 #2149) and raised
  the dependency floor to `>= 0.207.6` in `dune-project` / `masc.opam`. The
  pinned SHA is now the `v0.207.6` release-tag commit; the prior pin carried a
  `v0.207.5` label but pointed at a post-tag `main` commit (`8a30a9a2`) rather
  than the `v0.207.5` tag commit (`6fe842bf`), so this release restores the
  tag-SHA invariant. Pin metadata, lock metadata, generated docs, and the API
  surface fingerprint were refreshed for the new agent_core release.

### Fixed
- `runtime`: corrected a stale `runtime_toml.mli` doc comment that claimed the
  TOML parser still "accepts" the deprecated provider-letter protocol aliases
  (`provider_d-http` / `provider-d-cli`). The parser has no such branch — these
  labels are rejected with an "unknown protocol" error, so a checked-in config
  still using them fails to load. Added `test_legacy_protocol_alias_rejected`
  to lock the rejection and the canonical-label allow-list.


## [0.19.46] - 2026-06-18

### Changed
- `agent_sdk`: bumped the agent_core runtime pin from `v0.207.2` (`3efb5f00`) to
  `v0.207.3` (`57ed7272`, agent_core `main` HEAD, release 0.207.3 #2118) and raised
  the dependency floor to `>= 0.207.3` in `dune-project` / `masc.opam`. Pin
  metadata in `the pin script` and the generated doc blocks were
  regenerated; `the pin check` verifies the floor, the upstream
  ref-reachability of the pinned SHA, and the installed opam switch version.


## [0.19.45] - 2026-06-17

### Changed
## [0.19.44] - 2026-06-14

### Changed
- Bumped agent_core `agent_sdk` pin to `v0.206.9` at
  `8a619adbe2cb10025ceaac5338bef93791c9be9c` and raised the `agent_sdk`
  dependency floor to `0.206.9`.

### Removed
- `runtime`: legacy cleanup — dead code, Boundary_redaction SSOT,
  provider-letter purge (#21122).


## [0.19.43] - 2026-06-12

### Added
- `runtime`: added the GLM Coding Plan seed as `glm-coding.glm-4-7-coding`
  with the dedicated Z.AI Coding endpoint, `ZAI_CODING_API_KEY`, preserved
  thinking, and strict runtime/provider materialization coverage (#20971).

### Changed
- `runtime`: renamed checked-in OpenAI-compatible runtime protocol labels from
  `provider_d-http`/`provider-d-cli` to `openai-compatible-http` and
  `openai-compatible-cli`; the TOML parser still accepts legacy provider-letter
  aliases but canonicalizes parsed provider records before exposing runtime
  metadata.
- Bumped the agent_core agent SDK pin to `v0.206.1` at
  `a5006c5444c04e4a8af9c650015a91a098cd1d9f` and raised the
  `agent_sdk` dependency floor to `0.206.1`, picking up duplicate
  streaming request-field deduplication from agent_core #2022 and the Z.AI
  preserved-thinking request mapping from agent_core #2023.

### Fixed
- `keeper`: classified provider timeout catch-all records such as
  `provider_error_timeout:http_operation` as retryable provider timeouts
  instead of terminal `provider_runtime_error` blockers.
- `release`: allowed README subcommand drift smoke to pass when README has no
  `masc <subcommand>` snippets, instead of treating grep's no-match status as a
  failed release.

## [0.19.42] - 2026-06-12

### Fixed
- `release`: disabled OTLP export in release binary smoke so GitHub release jobs
  validate boot/listening without blocking on a collector that is intentionally
  absent in CI.

## [0.19.41] - 2026-06-12

### Added
- `keeper`: added local secret env/file projection for local keeper runs,
  including `secrets/<keeper>/env` overlays and `secrets/<keeper>/files`
  materialization (#20922).
- `keeper`: advanced the Memory OS rollout with persistence, recall rendering,
  librarian runtime wiring, prompt integration, and default-on behavior
  (#20876, #20881, #20883, #20897, #20915, #20926).
- `runtime`: added the Gemma4 Ollama runtime seed and constrained it to the
  intended `nick0cave` runtime lane (#20927, #20928).

### Changed
- Bumped the agent_core agent SDK pin to `v0.206.0` at
  `a5038de0c43d70b091418041ba1afde5486d30c7` and raised the
  `agent_sdk` dependency floor to `0.206.0`.
- `keeper`: continued RFC-0232 typed lane identity work with closed role
  modeling, producer-typed turn outcomes, and structural keeper identity
  (#20896, #20914, #20932).

### Fixed
- `keeper`: scrubbed ambient host GitHub/SSH credentials when a local keeper
  secret root is absent, while preserving noninteractive git/gh defaults for
  local subprocesses (#20922).
- `keeper-chat`: re-landed live text-delta streaming behind a typed guard, and
  `keeper-memory` now uses token-AND matching for search (#20912, #20913).
- `workspace`: tightened stale task-cache cleanup after backlog writeback and
  stale-release paths (#20822, #20847, #20878).

## [0.19.40] - 2026-06-09

### Changed
- Bumped the agent_core agent SDK pin to `v0.204.3` and raised the package
  metadata to `0.19.40`.

### Fixed
- `workspace`: capped `cycle_count` at 100 to prevent unbounded growth
  from claim-release hot-potato patterns (#18853).
- `workspace`: removed implicit auto-release on `task_claim_next`
  when an agent already holds a Claimed task (#18839).
- `keeper`: resolved `Git_unknown_revision` over-classification from
  bare branch names in `exec_semantic.ml` (#19977).
- `keeper`: corrected Shell IR risk classification for `find`/`sed`
  action flags (#19802).
- `keeper`: fixed task-state probe gate to allow git/mv/cp/rm/sed
  file-manipulation even when token matches forbidden task-state path
  (#19210).
- `dashboard`: restored WebSearch/WebFetch to keeper allow-list after
  descriptor-backed filter mismatch (#20060).
- `dashboard`: fixed stale build issue where vite failures were
  silently swallowed (#19551).
- `ci`: reinstated missing `ripgrep` in lint environment (#3404).

### Removed
- RFC-0151 withdrawn: the code-smell monotone ratchet is removed
  (`scripts/code-smell/measure.sh`, `scripts/lint/godfile-size-regression.sh`,
  `ci/code-smell-baseline.json`, and the `Godfile size` CI job in
  `fundamental-check.yml`). The `godfile_loc_1000plus` metric grew on natural
  code/test expansion and each increase required a paired baseline regenerate
  PR (#19231, #19433); the recurring baseline-drift false-fails blocked every
  open PR, so maintenance cost exceeded signal value. Trade-off:
  `catch_all_arms`/`contains_substring_defs` lose automated tracking and are
  now handled at PR review per the CLAUDE.md workaround-rejection bar.
- RFC-0203 Phase 3: `sidecars/discord-bot/` (Python connector, ~5000
  LoC) deleted. The external sidecar diagnostics surface no longer lists
  "discord"; only remaining external sidecars
  (slack/telegram/imessage/cli) stay routeable. The Channel Gate HTTP
  routes (`/api/v1/gate/message` etc.) remain unchanged and continue
  to serve the other external connectors.
- Portal and A2A dead surfaces removed from masc-mcp (27 files,
  #20016): `tool_catalog` registrations, `CanOpenPortal`/`CanSendPortal`
  capabilities, `Masc_domain.Portal` error variants, and related
  dashboard components.

### Added
- RFC-0203 Phase 3: in-process Discord gateway
  (`Server_discord_in_process_gateway`) replaces the deleted Python
  sidecar at `sidecars/discord-bot/`. `DISCORD_BOT_TOKEN` env var now
  activates the in-process WSS gateway at server boot; inbound
  messages are routed to keepers via the existing
  `Channel_gate.handle_inbound` entry point and replies are pushed
  back through the new `Channel_gate_discord_state.send_message`.
  `MASC_DISCORD_TRIGGER_POLICY` controls the inbound filter
  (`mention_only` default, `user_only:<id>`, `all`). The `board.posted`
  /`board.commented` activity-polling auto-push (previously done by
  the sidecar) is dropped — re-add as a follow-up if needed.
- `keeper`: Shell IR effect proof foundation (`exec_effect.ml`) with
  typed `effect_kind` and `project_risk` classification.
- `telemetry`: OpenTelemetry exporter integration (S1+S2, #20082).

## [0.19.37] - 2026-06-05

### Changed
- Bumped the agent_core agent SDK pin to `v0.202.0` at
  `c1ca73b9e0653350c57b7a74f3de64e2c0d303b0` and raised the masc
  package metadata to `0.19.37`.

### Removed
- Dropped stale keeper SDK error handling for agent_core error constructors that
  no longer exist in the `0.202.0` agent SDK surface.

## [0.19.36] - 2026-06-04

### Changed
- Bumped the agent_core pin to `v0.200.10` and the package metadata to
  `0.19.36`, keeping `dune-project` and the generated opam metadata on
  the same release train.

### Fixed
- Restored release truth alignment across the roadmap, product operating
  plan, and specification index so CI version/doc guards use the current
  package baseline.

## [0.19.35] - 2026-05-27

### Added
- RFC-0109 Phase D: introduced `Cdal_evidence_gate` layered decision
  module that consults `Cdal_verdict_gate.lookup_latest_verdict` before
  falling back to the legacy substring shim in
  `Tool_task_completion_review`. Analysis-only tasks (no contract)
  bypass the evidence gate — the operator-visible
  `keeper_task_done` open-loop block no longer fires when the keeper
  has nothing to attest beyond completion. Violated/Inconclusive
  verdicts now reject with typed `findings[]` and
  `completeness_gaps[]` in the workflow_rejection payload instead of
  the opaque "include pr_url..." hint string.
- RFC-0109 Phase A: introduced `Masc_mcp_cdal_runtime.Criteria` typed
  sum (Keeper_turn_capture_v1, Contract_catalog_invariants,
  Verification_request, Keeper_probe, Free) and migrated
  `Risk_contract.eval_criteria` away from opaque `Yojson.Safe.t`. Wire
  format preserved via legacy `kind` field + new `criteria_kind` tag.
  Amends §4.1 of the RFC to match the live producer inventory and adds
  Phase D (Task evidence gate ↔ CDAL verdict) targeting the
  `keeper_task_done` open-loop block pain.

### Changed
- `Keeper_tools_oas_workflow.workflow_rejection_payload_json` and
  `Tool_task_payloads.workflow_rejection_payload_json` accept a new
  optional `~extra_fields:(string * Yojson.Safe.t) list` so the typed
  CDAL verdict payload can be embedded in the rejection envelope
  without a schema break (RFC-0109 Phase D).

## [0.19.35] - 2026-05-28

### Added
- RFC-0201 Steps 2+3+5: wait-free snapshot for activity graph and
  swimlane views, retired PR #19150 cache wrapper for activity events.

### Changed
- Optimized HTTP dispatch, encoding, prefix route lookup, response
  header, and body chunk accumulation hot paths.
- Bumped agent SDK pin to 0.200.6.
- Dashboard refactors: extracted `errorMessageOr`, `UNKNOWN_STATUS_LABEL`,
  `MISSING_DATA_DASH`, `isRecord`, `isNonEmptyString`, `isAbortError` to
  shared `lib/format-string` and `lib/type-guards`; removed inspector pin
  wrapper, session trace trigger aliases, and agent identity tuple wrapper.
- Removed retired PR tool family wording and helper guard labels.
- Removed code smell ratchet wrapper and MCP server Eio transport mode
  reexport.
- Fixed `Execute` tool `rg` context path args.

### Fixed
- Resolved pre-existing CI gate failures (version truth, code-smell
  baseline drift, RFC numbering).

## [0.19.31] - 2026-05-26

### Changed
- Retired legacy keeper tool surfaces, including the active PR review helper
  wrappers and stale keeper interface aliases, so PR
  workflows route through the configured keeper/sandbox/provider binding.
- Continued legacy alias purging across board sort-order, MCP join-state, and
  keeper identity facade surfaces.
- Tightened task claim readiness/recovery handling with typed decisions and
  tolerated degraded retry runtime receipts without relying on legacy aliases.
- Improved runtime operator visibility by exposing MCP tool call IO previews
  and defaulting agent_core event retention for dashboard/runtime inspection.

## [0.19.30] - 2026-05-24

### Changed
- Bumped the downstream agent_core `agent_sdk` pin from `v0.198.0` to
  `v0.198.1` and raised the dependency floor to `agent_sdk >= 0.198.1`.
- Bumped the downstream agent_core `agent_sdk` pin from `v0.196.17` to
  `v0.198.0` and raised the dependency floor to `agent_sdk >= 0.198.0`.
- Continued Keeper Tool/Backend boundary cleanup by retiring the
  `Keeper_docker_read` module surface in favor of
  `Keeper_sandbox_read_backend`, keeping tool callers behind
  `Keeper_sandbox_read_runner`, and adding source guards for the old module
  name.
## [0.19.29] - 2026-05-24

### Changed
- Bumped `agent_sdk` (agent_core) minimum from `0.196.10` to `0.196.16`.
- Continued Keeper Tool/Backend boundary cleanup by routing file read tools
  through `Keeper_sandbox_read_runner` and moving file-tool route labels to
  sandbox runner facades.

## [0.19.28] - 2026-05-21

### Changed
- Bumped `agent_sdk` (agent_core) pin from `v0.196.7` to `v0.196.8` and SHA from
  `609600d8` to `8ea10c7b` (origin/main HEAD). Picks up `feat(error): carry
  completion contract violation detail` (#1660), `test(runtime): cover capacity
  admission fast-fail` (#1659), and CLI/capabilities refactors (#1662, #1663).

## [0.19.27] - 2026-05-20

### Changed
- Reduced local build friction by adding no-write/custom-output dependency
  graph inspection and narrowing two structural tests away from the broad
  `masc_test_deps` bundle.
- Continued shell path/name cleanup by purging forbidden-character legacy
  naming, reusing the path token scan for directory materialization, and
  renaming the path argument token selector.
- Trimmed dashboard dead surface area by removing unused components and common
  UI modules.

### Fixed
- Repaired the tier-admission metric label export that broke the main build
  after the runtime saturation wire-in.
- Corrected dashboard runtime truth around paused Keeper counts, crashed-phase
  SSOT handling, and tool-quality trend rendering.
- Rolled up status-only board automation posts so board history stays readable.

## [0.19.26] - 2026-05-20

### Added
- RFC-0153 Phase A/B for runtime saturation: added the typed `Runtime_saturation_signal`, wired tier admission into keeper attempts, and emitted the new saturation metric.
- RFC-0148 closed-sum `tool_error` module (7 variants) with codemod adoption at six LLM-facing sites.
- RFC-0142 `Json_field` typed extraction helper for boundary parsing.
- RFC-0141 `Field_resolution` typed TOML extractor in `repo_manager`.
- RFC-0143 typed `catalog_metadata_query` bridge for `keeper_runtime_profile`.
- RFC-0139 dashboard agent-status typed SSOT module.
- RFC-0135 keeper-operational-state typed SSOT promotion across vocab outliers.
- Typed `drain_outcome` sum for background tasks and a typed `validator_stage` enum in `exec_core` (RFC-0092 Cluster C).

### Changed
- Bumped the downstream agent_core `agent_sdk` pin to `v0.196.7` and raised the dependency floor accordingly.
- Promoted multiple permissive `_ ->` and string-keyed fallbacks to typed closed-sum splits (RFC-0070, RFC-0092, RFC-0093, RFC-0126 discipline).
- Replaced raw try/with handlers with `int_of_string_opt`-style total parsers and named the JSON shape in `of_json` errors across several boundary sites.

### Fixed
- RFC-0106 cancel-safe discipline: propagate `Eio.Cancel.Cancelled` instead of swallowing it in `fd_accountant` and several N-of-M boundary sites.
- `cdal_loader` boundary parsing: split `Yojson.Json_error` from the catch-all in `read_json_file` and preserve `Sys_error` reason in `File_not_found`.
- `worker_helper` / `worker_runtime_helper_protocol`: labelled bare `Failure` handlers and split `run_result_of_yojson` failure modes.
- `ide_annotation_types`: kind-aware parse errors with total integer parsers; exposed JSON shape in two `of_json` errors.
- `runtime_http_probe`: log HTTP transport failures instead of returning silent `None`.
- `mode_enforcer` / `anti_rationalization` / `eval_harness`: kind-aware boundary parse errors and bounded entry dumps.
- Build break in `test_runtime_saturation_signal_phase_a2` from an `Unix.unsetenv` reference (no such stdlib function) and a wrong `Masc_mcp.Env_config_keeper` qualifier.

## [0.19.25] - 2026-05-17

### Added
- Added the RFC-0109 `Bounded_proc` helper and tests for time-bounded subprocess execution.
- Added the RFC-0107 `Masc_http_client.Pool` interface skeleton for the next connection-pool implementation lane.
- Exposed FD accountant metrics through retired scrape backend, including coverage for the new metric names.
- Documented RFC-0108's PR/worktree operation safety gates and in-process atomic JSONL append direction.

### Changed
- Migrated additional cancel-safe shell, sandbox, response, and host-FD probe paths onto `Cancel_safe` helpers.
- Bumped the downstream agent_core `agent_sdk` pin to `main@308152ee` (`v0.196.1`) and raised the dependency floor to `agent_sdk >= 0.196.1`, covering the provider-timeout evidence release wave.

### Fixed
- Blocked Docker keeper shell runs during host FD hotspot pressure and added Darwin maxfilesperproc visibility plus best-effort Docker one-shot cleanup.
- Serialized `system_log` JSONL writes and trajectory appends with per-path mutex/fresh-fd handling, then removed the unsafe append-fd cache path.
- Removed remaining inline atomic helpers from `dated_jsonl` and `trajectory` so those paths use the shared `Fs_compat` surface.
- Restored the `home_dir` test reference left behind by the config-surface rename.
- Counted `tool_keeper` `cache_ttl_seconds` environment parse fallbacks through retired scrape backend.
- Replaced the CDAL runtime health inline error envelope with the shared `Tool_args` helper.
- Routed CDAL proof-store health path checks through the `Proof_store` owner API.
- Removed the backend mutex metrics log suffix that tripped the OCaml comment terminator lint.
- Split keeper shell-op resource classification parsing from the explicit shell fallback, and added the `Types_core` interface required by the OCaml structure ratchet.
- Replaced raw `error_kind:string` signatures in keeper memory validation and WebSocket parse metrics with closed typed variants.
- Kept keeper compaction observe sequencing in the correct branch and closed the snapshot-eviction match-arm regression that broke the main binary build.
- Parallelized safe lazy startup tasks and added tool/cache flusher outcome counters for clearer startup and dispatch diagnostics.
- Added the auto-upgrade dispatch and `Mcp-Session-Id` 404 handling path for the RFC-0100 server session lane.

## [0.19.24] - 2026-05-17

### Added
- Documented RFC-0105's OpenAI-compatible boundary typed error mapping for tool validation and provider/runtime failure surfaces.
- Added RFC-0106's cancel-safe `try`/`with` discipline draft for callback and cleanup paths.
- Added Docker playground FD-hotspot operator tooling:
  `scripts/docker-playground-fd-status.sh` surfaces worktree fanout and
  `lsof` holders under `.masc/playground/docker`, while
  `scripts/cleanup-docker-playground-worktrees.sh` dry-runs/applies
  conservative stale clean worktree cleanup for #15931, with explicit
  `--include-broken` handling for old non-git orphan directories.

### Fixed
- Wired the `Sandbox_exec` slot at non-Docker spawn callsites and gated keeper admission on system FD pressure, so fleet startup respects host-level descriptor pressure.
- Closed setup file descriptors on process spawn failure.
- Preserved typed PR evidence through task handling and prevented long-run workload stampedes.
- Deduplicated keeper goal repair and added janitor auto-stagnate threshold handling.
- Split background-task drain failures into typed handling for `drain_fd_to_buf` instead of silently swallowing read-side errors.
- Failed closed on tool validation failures, tagged fabricated pair-repair messages, and re-raised `Eio.Cancel.Cancelled` from the keeper compaction-start callback.
- Swept cursor-covered reaction stimuli so already-advanced keeper cursors do not leave stale pending work.

## [0.19.23] - 2026-05-17

### Changed
- Promoted the RFC-0099 / RFC-0101 closeout docs to Active after the session-close and FD-accountant runtime lanes merged.
- Bumped the downstream agent_core `agent_sdk` pin to `main@79262f37` (`v0.195.0`) and raised the dependency floor to `agent_sdk >= 0.195.0`, covering the agent_core body-timeout release wave.
- Updated the unified keeper metrics fixture for the latest tool-candidate and health fields.
- Removed the policy tool known-name adapter now that unified tool resolution owns the current path.

### Fixed
- Streamed large JSONL restore reads and removed the keeper-health legacy alias now that callers use the current health fields.
- Split binary build identity from repository checkout identity in `/health`, so stale executables no longer masquerade as the current checkout.

## [0.19.22] - 2026-05-17

### Changed
- Bumped the downstream agent_core `agent_sdk` pin to `main@5f8e07b7` (`v0.194.1`) and raised the dependency floor to `agent_sdk >= 0.194.1`.
- Moved the agent_core pin note out of the older 0.19.20 changelog section so release history matches merge chronology.

## [0.19.21] - 2026-05-17

### Added
- `lib/server/`: SSE close frames and `Session_lifecycle` publisher hook for the RFC-0099 session close path.
- `lib/keeper/`: required-tool candidate surfacing, Docker sandbox workspace-state exposure, and disk-pressure circuit breaker support for the keeper resource-gate lane.
- `lib/admission/`: Tool-resource-gate snapshots are exposed through the admission queue for the PR-6 resource-gate lane.
- `scripts/`: lint coverage for OCaml block-comment terminator traps so `_*)`-style failures are caught before PR merge.

### Changed
- Runtime configuration now continues purging legacy path/default fallback surfaces, including repo-config fallback removal and legacy path default cleanup.
- Log retention defaults are opt-in disabled as part of the RFC-0103 closeout path.
- Runtime legacy-runner worker tuning constants are lifted to SSOT, and the obsolete swarm harness entrypoint is removed.

### Fixed
- Keeper/tool gates: lane semaphores, generic required-tool gate behavior, typed handoff-context vocabulary, and tool-input validation exception qualification.
- Process/tool task reliability: background task reserve/release wiring into spawn, stale `pr_url` blob cleanup, and the OCaml comment terminator regression in `tool_task`.
- Transport/runtime visibility: runtime HTTP probe silent JSON parse drops now warn/count, and board-post validation stays at the correct boundary.

## [0.19.20] - 2026-05-17

### Added
- `lib/keeper/keeper_reaction_ledger.ml`: keeper-local Reaction Ledger summaries are exposed through runtime health and dashboard runtime-resolution payloads, so pending stimuli show as degraded/operator-action-required instead of disappearing into post-turn internals.
- `lib/server/fd_accountant.ml`: 4-kind FD accounting pool with Docker spawn throttle delegation for the RFC-0101 fleet pressure path.
- `lib/sse_event/`: typed SSE event migration for tool/turn and handoff/context/replacement/slot arms, with byte-level tests covering the new RFC-0004 PR-3/PR-4 event emitters.
- `docs/rfc/0101-fd-accountant-generic-pool.md` and RFC-0089 inventory partition updates document the next FD-accountant and close-prep lanes.

### Changed
- `lib/dashboard/` and dashboard runtime trust views label system-blocked states as `Blocked` rather than human `Pause`, separating operator pauses from runtime blockers.
- MCP server internals remove the legacy `respond_mcp_*` / `mcp_internal_error_json` factories from the active response path.
- Runtime max-token handling clamps model/provider output ceilings explicitly.
- Runtime qwen configuration declares chat-template thinking support explicitly and removes the legacy `cap_auto_resolved_max_tokens` alias from active runtime code and historical DD-020 notes.

### Fixed
- `lib/keeper/keeper_agent_run.ml`: captured CDAL proof files are persisted into keeper run outputs.
- `lib/server/server_mcp_transport_ws.ml`: silent websocket JSON parse drops now increment metrics and emit warnings.
- Runtime base-path handling no longer falls back to `ME_ROOT`.
- Release notes now cover the completed world-reactivity closeout wave, including Runtime Lens proof surfacing, required-tool route failure splitting, Reaction Ledger health, and CDAL proof persistence.

## [0.19.19] - 2026-05-17

### Added
- `lib/sse_event_poc/`: byte-equal PoC sublib (atdgen + atdgen-runtime, `(optional)`) demonstrating 3-way byte-equal output (`` `Assoc `` + `Yojson.Safe.to_string` vs hand-coded module vs atdgen `-j -j-std`) for `agent_started` payload. Gated behind `with-test` to avoid leaking atdgen into production opam install.
- `test/sse_event_poc/test_sse_event_poc.ml`: 3-way byte-equal Alcotest fixture (PASS, single run, byte-identical across all three emit paths).

### Changed
- `dashboard/src/components/ide/ide-context-lens.ts`: defensive `?? ''` null coalescing on `link.label.trim()` and `anchor.surface.trim()` to stop runtime crash from SSE schema drift (`TypeError: Cannot read properties of null (reading 'trim')`, observed 2026-05-17). Marked WORKAROUND; root removal once RFC-0004 Phase A0.4 (Zod-from-JSON-Schema payload nested validation) lands.

### Notes
- No production runtime change; PoC sublib is test-only via `(optional)` + opam `:with-test`.

## [0.19.18] - 2026-05-17

### Added
- `specs/keeper-state-machine/KeeperCompactionCooldown.tla`: TLA+ model for keeper continuity cooldown behavior, with clean and buggy TLC configs wired into `scripts/tla-check.sh`.
- `masc_keeper_continuity_no_state_total` and `masc_keeper_tool_pair_repair_total`: counters for no-STATE continuity cooldown advancement and keeper-local tool-pair repair.

### Changed
- `lib/keeper/keeper_compact_policy.{ml,mli}`: exposes pure `decide_compaction`, keeps tool-heavy emergency compaction eligible during cooldown, and isolates pre-compact dashboard health telemetry failures.
- `scripts/harness/workload/keeper_continuity_validation.sh`: reads the current `masc_keeper_status.meta.*` schema and validates checkpoint truth from trace checkpoint paths.

### Fixed
- `lib/keeper/keeper_post_turn.ml`: no-STATE continuity passes now advance `last_continuity_update_ts`, preventing repeated cooldown misses.
- `lib/keeper/keeper_run_tools.ml`: removes agent_core synthetic dangling-tool repair from the keeper reducer path and records local tool-pair repair instead.

## [0.19.17] - 2026-05-11

### Fixed
- `lib/keeper/keeper_telemetry_consumer.ml`: drain loop now yields between iterations (`Eio.Time.sleep clock 0.1`). The fiber introduced by #14491 saturated a single Eio domain at ~100% CPU because `Agent_sdk_metrics_bridge.drain` is non-blocking and the loop recursed without sleeping. Co-located fibers (HTTP handlers, lazy startup tasks) starved — server boot stalled at `lazy_task: starting restore_sessions`, `/health` timed out, and HTTP handlers never responded despite ports being LISTEN. Mirrors the sibling drain loops in `keeper_compact_audit`, `runtime_event_bridge`, and `server_bootstrap_loops` keeper-lifecycle, all of which already sleep between drains. PR #14499.

## [0.19.16] - 2026-05-07

### Added
- `lib/alignment_score.{ml,mli}`: backend OCaml implementation of Master Report section 3.3 Alignment Score (AS) formula - Dim03 P2 first slice. 10 raw metrics (TRC/COV/CMP/CRN/DBT/TMP/DIR/COH/BND/CNF), default weights summing to 1.0, normalization with 5 distinct patterns (linear, distance-from-1, complement, midpoint, complement-with-clamp), 5-step grade A/B/C/D/F, 5 warning flags. JSON codec with stable keys for the dashboard score panel. Pure OCaml, no Eio, no I/O. RFC-0035 PR-6.
- `test/test_alignment_score.ml`: 16 alcotest cases covering weights-sum invariant, overweight custom-weight clamping, ideal-metrics -> 100/A/no-warnings, worst-metrics -> low/F, rounded displayed-score grade consistency, normalization on each axis, out-of-range clamping, grade boundaries (90/75/60/40), floating precision at grade boundaries, all 5 warnings, no false warnings on ideal, and JSON-shape contract.

### Fixed (vs Master Report TS reference)
- `normalized.TMP > 150 -> Behind_schedule` was structurally impossible (normalized cap is 100); replaced with raw `tmp > 1.5`.
- `normalized.DBT > 50 -> High_debt` had inverted semantics (normalized.DBT large = low debt); replaced with raw `dbt > 0.5`.

## [0.19.15] - 2026-05-07

### Added
- `lib/chronicle_librarian.{ml,mli}`: in-memory chronicle-event store with keyword-search retrieval — Master Report Dim02 P1 §2.4 Librarian Agent first slice. Reuses `Cognitive_gravity.rank` for ordering, no new ranking primitive. Exposes `empty / add / of_list / to_list / len`, three filter helpers (`filter_by_event_type / filter_by_session / filter_by_time_range`), and a deterministic tokeniser. Pure OCaml, no Eio, no I/O. Vector embedder + Responder + Proactive Summary deferred to PR-6+. RFC-0035 PR-5.
- `test/test_chronicle_librarian.ml`: 11 alcotest cases (tokenise basic, search empty/single/relevance/limit/recency-default/recency-explicit, filter event_type/session/time_range, add insertion order).

### Changed
- `docs/rfc/RFC-0035-cognitive-ide-roadmap.md`: PR-stack table marks PR-5 in-flight (this PR). PR-4 still in-flight pending merge.

## [0.19.14] - 2026-05-07

### Added
- `lib/chronicle_event.{ml,mli}`: backend OCaml schema for the chronicle event stream — Master Report Dim02 P1 ChronicleEvent. JSON-shape compatible with the dashboard read model `dashboard/src/components/chronicle/chronicle-types.ts` (camelCase: eventType, displayName, sessionId, parentEventId, relatedEventIds, projectState, filesChanged, statedGoal, inferredIntent). 21 event types, 4 actor kinds, 7 target kinds. Custom yojson codec (not [@@deriving]) so the wire format stays string-level stable across pin bumps. RFC-0035 PR-4.
- `test/test_chronicle_event.ml`: 10 alcotest cases covering the full round-trip of every variant in all three taxonomies, full event JSON round-trip, dashboard camelCase key contract, optional-intent absent semantics, decode-rejects on unknown eventType / missing required field, and well-formedness invariant.

### Changed
- `docs/rfc/RFC-0035-cognitive-ide-roadmap.md`: mapping table Dim02 row updated — `chronicle_event` is now in-flight (PR-4) on the lib side. PR-stack table extended to mark PR-4 as in-flight and PR-5 (Librarian retriever) as the next P1 item.

## [0.19.13] - 2026-05-06

### Changed
- `docs/rfc/RFC-0035-cognitive-ide-roadmap.md`: refreshed mapping table after Master Report Dim01 dashboard PRs landed. P0 #1~#4 (#13768, #13773, #13781, #13779) now marked merged; P0 #5 backend (cognitive_gravity, #13797) marked merged with #13800 added as the dashboard renderer counterpart for both #5 and #6; P0 #6 backend (intentional_projection, #13821) marked in-flight. PR-stack section renumbered: PR-3 is the bump+refresh chore, PR-4 onward are the deferred items. RFC-0035 PR-3.

## [0.19.12] - 2026-05-06

### Added
- `lib/cognitive_gravity.ml(.mli)`: pure OCaml Semantic Gravity ranker covering Master Report Dim01 P0 #5. Combines keyword overlap (Jaccard, case-insensitive), exponential recency decay (τ = 1 day), and a clamped frequency weight into a deterministic ranking. No I/O, no Eio, no dashboard or agent_core surface change. RFC-0035 PR-1.
- `docs/rfc/RFC-0035-cognitive-ide-roadmap.md`: integration manifest mapping the 11 cognitive-IDE dimensions in the Master Report to existing modules and in-flight PRs (#13768, #13773, #13779, #13781). Future PRs in those modules must cite this RFC.
- `test/test_cognitive_gravity.ml`: 7 unit tests covering empty input, single-item, ordering by overlap, zero-weight component pruning, recency decay (including negative-recency clamp), frequency clamp at 1.0, and case-insensitive keyword matching.

## [0.19.11] - 2026-05-06

### Added
- `scripts/verify_audit_claim.sh`: deterministic verifier for audit count claims (`<expected> <pattern> <path...>`). Forces measurement against the working tree before count claims are acted on. Origin: 2026-05-06 hallucinated audit runtime where a "16 silent-empty antipatterns" claim cross-cited by 4 keepers measured as 2 against actual code (8x overstated). Exit 0 on match, 1 on mismatch with overstatement ratio.

## [0.19.10] - 2026-05-05

### Added
- `feat(runtime)`: RFC-0027 PR-9c per-secondary metric label `dual_track_swap` (#13158).
- `feat(dashboard)`: board comment thread controls (#13142).
- `feat(goal)`: goal attainment projection surfaced in dashboard (#13131).
- `feat`: observed keeper PR work metrics (#13177).

### Changed
- Bumped `agent_sdk` pin to `0.190.7` (#13151).
- `refactor(dashboard)`: extracted board surface modules (#13147).
- `chore(build)`: `dune-local.sh` guards missing opam deps + OCaml < 5.1 early (#13117).
- `chore`: goal loop checklist added to PR template (#13145).
- `fix(keeper)`: tightened action signals; removed zombie field (#13168).

### Fixed — Keeper recovery & freeze
- `fix(keeper)`: wake alive-stuck keepers (#13123).
- `fix(keeper)`: recover alive-but-stuck keepers (#13106).
- `fix(keeper)`: surface semaphore timeout phase (#13126).
- `fix(keeper)`: degraded retry slot guard (#13120).
- `fix`: bound keeper autoboot warmup jitter (#13119).
- `fix`: `Int32` arithmetic for platform-stable warmup hash (#13156).

### Fixed — Runtime & provider routing
- `fix`: runtime on model access denial (#13146).
- `fix(runtime)`: unblock `validate_path_result` on warning 16 (#13159).
- `fix`: probe local providers in runtime catalog (#13124).

### Fixed — agent_core / tooling
- `fix(agent_core)`: enable codex CLI keeper MCP approval (#13169).
- `fix(agent_core)`: log codex CLI skip decisions (#13149).

### Fixed — Goal loop / verification
- `fix(dashboard)`: tokenize acronym prefixes; de-shadow non-finite test (#13176).
- `review(#13166)`: camelCase tokenizer + state test update + 2 regressions (#13170).
- `fix(dashboard)`: goal attainment projection follow-up (post-#13131) (#13166).
- `fix`: aggregate goal loop phase status (#13160).
- `fix`: link goal loop decisions to act artifacts (#13153).
- `fix`: verify goal loop raw log contracts (#13150).
- `fix`: surface governance fallback counters (#13143).

### Fixed — Dashboard / IDE
- `fix(dashboard)`: address hearth stack review feedback (#13175).
- `fix(ide)`: register discovered repositories (#13173).
- `fix(dashboard)`: bound judge bridge budgets (#13115).
- `fix(dashboard)`: log keeper sub-op timings after row build (#13114).
- `fix(dashboard)`: bound safe-autonomy sandbox probes (#13113).
- `[codex]` Fix Code IDE read-only editor hydration (#13136).

### Fixed — Misc
- `fix(metrics)`: wire agent_core LLM bridge callbacks (#13125).
- `fix(metrics)`: persist heuristic events after late init (#13122).
- `fix(keeper)`: preserve board signal wake stimuli (#13139).
- `fix(keeper)`: scope claimable backlog signals (#13154).
- `fix(keeper)`: surface unloaded tool policy accessors (#13129).
- `fix(keeper)`: surface keeper toml unknown keys in health (#13138).
- `fix`: surface credential starvation monitoring (#13148).
- `fix(types)`: stabilize keeper facade cmi (#13130).
- `fix(start)`: wait for transient port release (#13144).

### Tests
- `fix(test)`: exhaustive match on `Keeper_event_queue.classify` variants (#13174).
- `test`: add goal loop fixture bundle (#13172).
- `test(bootstrap)`: pin Int32 djb2 hash outputs cross-platform — tracker §L (#13167).
- `test`: lock keeper PR capability invariants (#13137).


## [0.19.9] - 2026-05-05

### Changed
- Bumped `agent_sdk` pin to `0.190.6` (released version from agent_core main).
- Dashboard dependency refresh: minor/patch bumps for tailwindcss, typescript, vitest, eslint-plugin-react-hooks, lucide-preact, cytoscape, dompurify, marked, zod, solid-js.
- Removed deprecated `@types/cytoscape` (built-in types now available).

## [0.19.8] - 2026-05-05

### Added
- RFC-0026 keeper admission router + WFQ overflow + keeper policy types (shadow-mode).
- Per-provider token bucket primitive and runtime confidence ring buffer.
- Stale-binary warning at startup via `commit_age_seconds` build identity.
- Dashboard provider color tokens and keeper-aware `/api/v1/git/blame` + `/api/v1/git/diff`.

### Fixed
- Cap runtime rotation to per-attempt timeout budget.
- Stamp `Fiber_unresolved` blocker_class and clean up #12910 revert leftovers.
- Dedup `fallback_runtime` cycle WARN per (config_path, cycle_set).
- `oas_compat` includes truncated body in all `error_message` fallback paths.
- Restore missing `metric_keeper_slot_yield_total` and `run_unified_turn` wrapper.

### Changed
- Unexport ~80 internal helpers across dashboard modules (-3.2k lines).
- Remove all IDE mock data; connect dashboard to real APIs (Phase 1-3).

## [0.19.7] - 2026-05-05

### Added
- Keeper-aware workspace tree + file routes in Dashboard.
- Dashboard token system: sp-1h half-step + 5 polish tokens.
- IDE activity and conversation rail connected to real APIs.

### Fixed
- Release current_task_id on supervisor auto-pause (Task-138).
- Annotate intentional non-color CSS literals with inline justification.

### Changed
- Unexport 27 internal-only helpers across common/ (+ unit test cleanup).

## [0.19.6] - 2026-05-04

### Added
- Semaphore holder tracking so timeouts can name the blocker.
- Cycle detection for fallback_runtime at load_catalog time.
- Per-candidate runtime attempt emitted to system_log.
- Real workspace/git API endpoints replacing IDE mock data.

### Fixed
- Reset queue-head wait clock after fairness yield + enqueue.
- Remove duplicate write_meta_failures counters and normalize phase label.
- Scope WorldVisualizer to Cockpit/IDE surfaces.

### Changed
- Drop 14 orphan hooks/utilities (-2001 lines).

## [0.19.5] - 2026-05-03

### Added
- Alive-but-stuck detector — retired scrape backend signal only.
- Keeper cadence gauges (consecutive_idle, last_productive_ts).
- Unit tests for keeper_alerting_path pure helpers.

### Fixed
- Replace 4 "unknown" stand-ins with "aggregate" placeholder.
- Instrument decision record JSONL append failure in unified_metrics.

### Changed
- Drop 9 orphan components (-2315 lines).
- Drop deprecated theme-hash exports.

## [0.19.4] - 2026-05-02

### Added
- Passive loop action injection — nudge keeper to act when stuck in read-only loop.
- retired scrape backend counters for tool setup and task load failures.
- Issue dependency graph: liveness recovery, runtime rotation, lifecycle timeline.

### Fixed
- Inject stream_idle_timeout default when caller omits option.
- Data accuracy sweep for Provider Capability Matrix in Dashboard.
- Unblock main build (printf format + Env_config_keeper rename).
- Sync stale test defaults with Env_config_exec_timeout.
- Silent dispatch + timeout_sec SSOT migration.

## [0.19.3] - 2026-05-02

### Added
- Health-Aware Provider Circuit Breaker to prevent runtime stagnation with a 30-second cooldown.
- Adaptive Pheromone Evaporation with Max-Min Conductivity Bounds.
- 3-Layer Context Auto-Compaction (Working, Episodic, Semantic).
- TLA+ Runtime Invariant verification (`ZombiePhaseInvariant`).
- 4-Tier Operator Nudge System (`HINT` -> `SUGGEST` -> `APPROVE/REJECT` -> `REDIRECT`) and dashboard lifecycle inspector.

### Fixed
- SafeAuto source path recovery to prevent backtrace loss in Effect Handler.
- Fiber Yield Starvation with `Eio_context.fair_yield ()`.
- Flaky `test_runtime_retry` test using deterministic structured concurrency.

## [0.19.2] - 2026-05-01

Release-build recovery patch after the `v0.19.1` tag landed before the latest main build-break repair PRs. No breaking API changes.

### Added

- Provider cooldown observability now includes `masc_keeper_provider_block_duration_sec`, recording cooldown durations for rejected, rate-limited, hard-quota, and terminal-failure paths (#12429).

### Changed

- Dashboard navigation is consolidated around the operator loop, keeping daily surfaces focused while retaining diagnostic routes behind canonical drill-downs and redirects (#12442).
- agent_core agent SDK pin helper now targets `0.187.6` for the downstream pin lane after the upstream generated opam metadata repair (#12460).
- Package and release metadata advanced from `0.19.1` to `0.19.2`.
- Roadmap, product operating plan, opam metadata, and spec baseline version references synced to `0.19.2`.

### Fixed

- Monitoring keeper detail routes now render safely from direct URLs when live keeper data exists but `selectedKeeper` starts empty, covering the `insertBefore` dashboard crash class (#12431).
- Main branch release builds now compile after the `Tool_workspace.tool_result` record conversion and `Task_sandbox.create ?repo_name` signature drift (#12453).
- Gemini CLI admin policy now explicitly denies `ask_user`, preventing headless keepers from hanging on an interactive-only tool surface (#12455).

## [0.19.1] - 2026-05-01

Post-v0.19.0 release-truth follow-up for the keeper Event Layer consumer path, dashboard design-system baseline, and `lib/dune` module-discovery cleanup. No breaking API changes.

### Added

- `Keeper_registry.dequeue_event` now provides the consumer-side registry API for FIFO stimulus consumption, snapshot depth updates, empty/missing-keeper `None`, and base-path isolation (#12413).
- Turn entry now consumes one queued stimulus per tick, completing the producer-to-consumer Event Layer path after the `wakeup_keeper` and heartbeat-gate changes (#12420).
- RFC-0020 Rule 2 now has a retired scrape backend override counter and decision-table regression coverage for the queue-non-empty heartbeat override (#12417, #12419).
- Dashboard design-system primitives now cover focus, interaction, portal/z-index, IDE-grade components, agent-experience patterns, ARIA widgets, a11y helpers, token validation, and paired component tests (#12406, #12421).

### Changed

- Keeper run runtime context now uses a typed boundary for runtime runtime names (#12418).
- `lib/dune` now relies on Dune `:standard` module auto-discovery while preserving the checked-in `private_modules` surface, reducing merge conflicts for new modules (#12422).
- Package and release metadata advanced from `0.19.0` to `0.19.1`.
- Roadmap, product operating plan, opam metadata, and spec baseline version references synced to `0.19.1`.

## [0.19.0] - 2026-05-01

Multi-repository architecture Phase 1. Introduces explicit repository registry and keeper-scoped access control, resolving the basepath mixing problem where all Git branches from nested projects were conflated.

### Added

- `Repo_store` module for repository CRUD, TOML persistence, and git discovery (#12401).
- `Keeper_repo_mapping` module for keeper-to-repository access control with wildcard support and credential isolation (#12401).
- `Credential_store` module for credential CRUD and type-safe storage (#12401).
- `Repo_git` and `Repo_sync` modules for branch listing and sync scheduling (#12401).
- HTTP API endpoints under `/api/v1/repositories` for listing, adding, removing, updating, discovering, and syncing repositories (#12401).
- `Keeper_repo_mapping.validate_path_access` integration in `keeper_shell_ops` for path-level access enforcement (#12401).
- `wakeup_keeper` now accepts optional `?stimulus` payloads and enqueues them into the keeper Event Layer before flipping the existing wakeup hint (#12411).
- Smart heartbeat gating now honors RFC-0020 Rule 2 by forcing emit when the keeper Event Layer queue is non-empty, preventing queued stimuli from being starved by skip decisions (#12412).
- Keeper turn-entry telemetry now records Event Layer queue depth for operator-visible runtime diagnosis (#12415).

### Changed

- Quadrant 1 quick wins externalize dashboard context thresholds and keeper watchdog/retry constants, add provider/cooldown/queue metrics, and replace the `auto` model-selector magic string with a typed boundary (#12416).
- Package version advanced from `0.18.25` to `0.19.0`.
- Spec baseline and snapshot metadata synced to `0.19.0`.

## [0.18.25] - 2026-05-01

Post-v0.18.24 merge train for keeper event-queue registry wiring, silent-failure visibility, runtime typing/FSM message cleanup, runtime memory config, prompt XML escaping, and release-truth sync. No breaking API changes.

### Added

- Keeper registry entries now carry the `Keeper_event_queue` field, wiring the Event Layer queue into keeper registry construction and snapshots (#12403).
- RFC-0020 now documents the keeper Event Layer / Policy Layer split, including the one-way Event-to-Policy data path and TLA+ correspondence for the queued heartbeat work (#12409).
- Agent terminal reason reporting now has per-variant `agent_core.Error.Agent` reason codes so dashboard chips and operator broadcast payloads can distinguish terminal agent failure classes (#12402).

### Changed

- Runtime runtime lookups now use typed `Keeper_runtime_profile.runtime_name` boundaries internally while preserving existing public/agent_core string entry points (#12404).
- Package and release metadata advanced from `0.18.24` to `0.18.25`.
- Roadmap, product operating plan, opam metadata, and spec baseline version references synced to `0.18.25`.

### Fixed

- Remaining dev-only diagnostics in agent, runtime, provider, repo-manager, sidecar, tool, and verification paths now surface through structured operator-visible logging instead of disappearing silently (#12400).
- Keeper memory compaction knobs now route through `keeper_runtime.toml` / env precedence so boot-time runtime overrides are visible to memory-bank readers (#12384).
- Runtime exhaustion user messages now render through the runtime FSM boundary instead of duplicated worker-side string formatting (#12383).
- Keeper and goal prompt blocks now escape XML predefined entities before injection into pseudo-XML prompt tags (#12408).

## [0.18.24] - 2026-05-01

Post-v0.18.23 release-truth follow-up for the silent-failure cleanup, keeper event queue implementation, and ratchet baseline updates that landed immediately after the `v0.18.23` tag. No breaking API changes.

### Added

- Keeper runtime now has the `Keeper_event_queue` Event Layer module for typed queue snapshots, enqueue decisions, draining, compaction, and admission/retention accounting (#12396).

### Changed

- Package and release metadata advanced from `0.18.23` to `0.18.24`.
- Roadmap, product operating plan, opam metadata, and spec baseline version references synced to `0.18.24`.
- The OCaml structure ratchet baseline for `lib_dune_lines` now allows the current checked-in library layout up to 1000 lines (#12398).

### Fixed

- Server, workspace collaboration, governance anomaly, mention inbox, runtime route, dashboard delete-action, and task-tool paths now avoid silent failure patterns by surfacing ignored exceptions or error details through structured logging and explicit handling (#12395).
- The 0.18.24 release bump also repairs the #12395 logging follow-up type errors by stringifying board/auth/schema errors at the correct boundaries (#12397).

## [0.18.23] - 2026-05-01

Post-v0.18.22 merge train for keeper silent-failure visibility, sandbox dispatch regression coverage, TLA/FSM naming cleanup, runtime-name typing, RFC-0019 keeper repo access control, and release-truth baseline cleanup. No breaking API changes.

### Added

- Keeper event queue TLA+ coverage now includes a buggy bug-model for layer-separation checks (#12386).
- Receipt outcome JSON boundaries now use the TLA+ spec names consistently across the FSM-01 path (#12385).
- SND-05 regression coverage verifies `dispatch_simple` preserves Docker sandbox runner metadata instead of falling back to host execution (#12376).
- Keeper turn queue depth is now exposed as an operator metric (#12379).
- RFC-0019 keeper GitHub shell context now enforces repo access against the repo store mapping (#12387).

### Changed

- Runtime record names now use typed runtime-name boundaries instead of raw string propagation (#12374).
- Turn execution runtime routing now carries typed runtime names through keeper turn budget and unified-turn boundaries (#12394).
- Package and release metadata advanced from `0.18.22` to `0.18.23`.
- Roadmap, product operating plan, opam metadata, and spec baseline version references synced to `0.18.23`.

### Fixed

- Keeper compact-audit dispatch paths now use structured keeper logging instead of raw `Printf.eprintf` output (#12389).
- SSE keepalive and runtime health paths now use structured server logging instead of raw `Printf.eprintf` output (#12390).
- Non-relative read errors redact resolved host paths so sandbox/path leaks do not reach operator-visible failures (#12388).
- Keepalive dispatch rejections now surface instead of disappearing behind silent control-flow paths (#12375).
- Profile-defaults validation keeps the intermediate result `unit`-typed until tool-access defaults are bound, preserving the #12378 compile fix after the latest FSM merge train.
- Spec index release baseline now matches the current package version after the `0.18.22` bump left it at `0.18.21`.

## [0.18.22] - 2026-05-01

Post-v0.18.21 merge train for routine release boundary advancement. No breaking API changes.

### Changed

- Package and release metadata advanced from `0.18.21` to `0.18.22`.
- Roadmap, product operating plan, opam metadata, and spec baseline version references synced to `0.18.22`.

## [0.18.21] - 2026-04-30

Release-truth follow-up after the `0.18.20` version bump landed before the rest of the merge train, and the `v0.18.20` tag was later cut with additional PRs but without matching changelog text. No breaking API changes.

### Added

- RFC-0019 credential materialization landed with `with_token` provisioning support for repo-manager flows (#12336).
- RFC-0019 credential hardening added SHA-256 token-prefix audit support and `hosts.yml` relabeling for keeper-scoped identities (#12345).
- IDE dashboard work continued with the editor toolbar, view tabs, and design-system tooltip/ARIA sweep (#12337, #12340, #12341).
- The IDE dashboard gained the EXPLORER file-tree store plus Popover, AlertDialog, and ResizablePanel primitives with a11y coverage (#12347, #12352).

### Fixed

- Dashboard render errors in runtime inspector and agent surfaces were repaired, including the keeper metadata type reference that blocked the `v0.18.20` Linux release build (#12338).
- Draft auto-merge guard races were closed so merged PR current-state checks fail closed instead of racing stale draft state (#12339, #12342, #12343).
- `do-not-merge` is now a hard-stop label that overrides human-approved and non-agent bypass paths in PR automation (#12346).
- Model inference metrics and provider routes were brought back into sync with the `latency_buckets` aggregate field and keeper type-source split (#12349, #12351, #12354).

### Changed

- Routine keeper runtime log noise was reduced after the 0.18.20 boundary (#12344).
- Runtime strategy signal contexts now carry typed runtime runtime names through the string boundary (#12350).
- Dead keeper SOUL.md / "SYSTEM: SOUL INFUSION" path handling was removed from the checked-in runtime surface (#12353).
- Package and release metadata advanced from `0.18.20` to `0.18.21` so the published release boundary includes the post-tag fixes.
- Roadmap, product operating plan, opam metadata, and spec baseline version references synced to `0.18.21`.

### Deprecated

- None.

## [0.18.20] - 2026-04-30

Post-v0.18.19 merge train for the agent_core `0.187.4` downstream pin and the first IDE-plane/RFC-0019 keeper credential slices. No breaking API changes.

### Added

- IDE-plane dashboard shell routing and design-system RFCs for the next code-management surface landed behind the existing dashboard boundaries (#12325, #12330).
- RFC-0019 keeper credential unification began with credential-store host config bridging and GitHub identity setup documentation (#12328, #12329, #12323).

### Changed

- agent_core agent SDK pin metadata advanced to `0.187.4`, including the regenerated public API surface fingerprint and downstream pin documentation (#12327, #12331).
- Multi-repo management, dashboard connector status, runtime inventory naming, and goal-FSM freshness surfaces were hardened or consolidated after the `0.18.19` release boundary (#12321, #12322, #12324, #12326).
- Package and release metadata advanced from `0.18.19` to `0.18.20`.
- Roadmap, product operating plan, opam metadata, and spec baseline version references synced to `0.18.20`.

### Deprecated

- None.

## [0.18.19] - 2026-04-30

Release-truth catch-up after the `v0.18.18` tag was cut before the final changelog sync and design-system mapping audit landed. No runtime behavior changes beyond the commits already on `main`.

### Changed

- Release metadata advanced from `0.18.18` to `0.18.19` so the tagged boundary includes the 0.18.18 changelog correction and IDE mockup/v0.4 mapping audit (#12316, #12317).
- Roadmap, product operating plan, opam metadata, and spec baseline version references synced to `0.18.19`.

### Deprecated

- None.

## [0.18.18] - 2026-04-30

Post-v0.18.17 merge train through the release boundary. No breaking API changes.

### Added

- Multi-repository architecture landed with repository, credential, sync, and keeper-mapping stores, server routes, tests, and dashboard management surfaces (#12304).
- Keeper observability gained lifecycle restart metrics and a per-keeper tool-emission push counter (#12306, #12302).
- Dashboard multimodal navigation and payload rendering improvements shipped through DAG node navigation, sidebar entry, server-side list filtering, and kind-specific renderers (#12296, #12300, #12301, #12303).

### Fixed

- Local MCP client bearer lifetime, clone-policy fail-closed behavior, keeper stream idle timeout defaults, fs-read containment matching regressions, and dashboard IO contention/world-memory prompt handling were fixed (#12295, #12305, #12307, #12310, #12311, #12313, #12314).

### Changed

- Runtime/agent_core labels are now typed at metric and FSM boundaries, and routine keeper logs are demoted to reduce operator noise (#12298, #12308, #12299).
- agent_core agent SDK pin metadata advanced to `0.187.3` after the downstream pin lane landed (#12312).
- Package and release metadata advanced from `0.18.17` to `0.18.18` after the post-v0.18.17 merge train.
- Roadmap, product operating plan, opam metadata, and spec baseline version references synced to `0.18.18`.

### Deprecated

- None.

## [0.18.17] - 2026-04-30

### Fixed

- Closed the `Skip_idle + Woken` half of the `MissedWakeup` gap modeled in `KeeperHeartbeat.tla` (#12271). `interruptible_sleep` now returns the discriminator `Stopped | Woken | Timeout` and `run_smart_heartbeat_gate` promotes a wakeup-cut idle backoff to a continuing cycle, so external `wakeup_keeper` / board signals on a Live keeper no longer get absorbed by the smart-heartbeat gate. Sibling fix to #10078, which closed the same shape for `Skip_busy`.
- Dashboard agent directory no longer crashes with `insertBefore: parameter 1 is not of type 'Node'` when a filter targets a keeper the live registry has dropped (#12290 closes #12283). `KeeperDetailPage` now refuses the cached `selectedKeeper` fallback whenever the live registry is non-empty, falling through to a redesigned missing-state that names the likely cause (watchdog kill / operator stop) and points at `masc_keeper_stale_termination_total{keeper=...}`.

### Added

- New positive-signal retired scrape backend counter `masc_keeper_skip_idle_wake_resumed_total{keeper}` increments every time `cycle_continues_after_wake` promotes a `Skip_idle` to a turn dispatch (#12282). Pairs with the existing `masc_keeper_stale_termination_by_class_total{class=idle_turn}` so operators can read the fix as a positive/negative balance: a healthy fleet shows non-zero rate of resumes proportional to inbound signals while idle-class kills trend toward zero.
- New pure helper `resolveKeeperForDetail` in `dashboard/src/lib/keeper-detail-resolution.ts` (#12290), unit-tested without a React render or signal harness so the dashboard regression guard stays cheap.

### Changed

- Package and release metadata advanced from `0.18.16` to `0.18.17` to mark the keeper idle-wake regression boundary on `main`.
- Roadmap, product operating plan, opam metadata, and spec baseline version references synced to `0.18.17`.

### Deprecated

- None.

## [0.18.16] - 2026-04-30

### Changed

- Package and release metadata advanced from `0.18.15` to `0.18.16` after the downstream agent_core `v0.187.2` pin landed on `main`.
- Roadmap, product operating plan, opam metadata, and spec baseline version references synced to `0.18.16`.
- Release boundary verified against the current `agent_sdk >= 0.187.2` floor and regenerated agent_core API surface fingerprint.

### Deprecated

- None.

## [0.18.15] - 2026-04-30

### Changed

- Package and release metadata advanced from `0.18.14` to `0.18.15` so post-v0.18.14 keeper, audit, dashboard, and dependency follow-ups land on a new patch line.
- Roadmap, product operating plan, opam metadata, and spec baseline version references synced to `0.18.15`.
- agent_core agent SDK pin advanced to `v0.185.0` / `a04ce1f373c8f9458b7e6059558c8a6867856743`, including the regenerated public API surface fingerprint and keeper manual pin block.

### Deprecated

- None.

## [0.18.14] - 2026-04-30

Release train metadata bump immediately after publishing the v0.18.13 catch-up boundary. No runtime behavior changes.

### Changed

- Package and release metadata advanced from `0.18.13` to `0.18.14` so new post-release work lands on the next patch line.
- Roadmap, product operating plan, opam metadata, and spec baseline version references synced to `0.18.14`.

### Deprecated

- None.

## [0.18.13] - 2026-04-30

Aggregate of 389 commits since v0.18.9 (147 feat / 74 chore / 54 fix / 26 docs / 25 test / 20 refactor / 8 spec / 3 ci, plus filename-scoped surface pins). No breaking API changes.

This is a release-truth catch-up for the 0.18.10-0.18.13 stabilization train. The headline thread is keeper/agent_core boundary hardening after budget-loop and local Ollama timeout failures, plus dashboard/runtime visibility cleanup and CI/release hygiene.

### Added

- agent_core provider error variant contract, metric export, and dashboard telemetry samples for provider/runtime diagnosis.
- Resolved-goal verification evidence and expanded dashboard/runtime surfaces for operator truth.
- Performance and reliability instrumentation, including dashboard WS load harness, cache hit/miss counters, GC quick-stat sampling, and cold/warm tool-call labels.

### Fixed

- Keeper agent_core timeout behavior: fallback budget reservation, repeated `oas_timeout_budget` auto-pause, hard-quota fail-fast handling, and local Ollama token-cap tuning.
- Docker-backed keeper execution: `HOME=/tmp` coverage for run/exec/shell paths and runtime contract visibility fixes.
- Dashboard CI/typecheck stability, provider runtime clarity, fleet idle recovery false positives, and stale TLA/spec-line references.

### Changed

- agent_core pin metadata refreshed through the reachable `0.184.0` SDK line and downstream version truth synced to `0.18.13`.
- Keeper tool preset UI compatibility removed after the runtime-facing preset model moved to typed gate decisions.
- TLA deadlock checking narrowed for `AutonomousLoop` terminal-state behavior so CI tracks the intended invariant surface.

### Deprecated

- None.

## [0.18.9] - 2026-04-28 — patch: spec ↔ code bidirectional identity infrastructure (Cycle 24-44 autonomous series) + 234 operational commits

Aggregate of 254 commits since v0.18.8 (109 feat / 33 fix / 37 docs+spec / 36 chore / 34 refactor / 3 test / 1 quality / 1 ci). No breaking API changes. Patch bump (per #11388 narrow-scope precedent); a minor bump (`0.19.0`) is also defensible given the 109 `feat` commits and is a release-manager call.

The headline thread for this release is the autonomous **Cycle 24-44 spec ↔ code identity series** (20 PRs, all spec/docs only, behavior-change 0). The series closes the discoverability gap users observed as "lifecycle 30-40% black-box": OCaml subsystems whose specs already cited them but had no reverse anchor. Two patterns:

1. **Anchor addition** (Cycle 24-39, 16 PRs) — adds a `(* Spec navigation (OCaml -> TLA+) ... *)` block plus inline anchors to OCaml modules so code search lands on the authoritative spec module.
2. **Citation refresh** (Cycle 40-43, 4 PRs) — verifies and corrects stale OCaml line citations in 5 specs and adds a forward-stability disclaimer ("function names are stable identifiers; lines drift across edits") that converts future drift into metadata-only refreshes.

### Added (spec ↔ code navigation infrastructure — autonomous Cycle 24-44)

- `#11565` derive_phase navigation block (`keeper_state_machine.ml`) — Tier C1 Phase 0 anchor with 4-way Drift/Refinement classification per priority branch.
- `#11583` `specs/keeper-state-machine/KeeperLaunchPending.tla` — new 3-phase pre-launch spec (Offline/Running/Dead) with `FiberStartedWithoutClearing` bug action; resolves the previous "Note A drift candidate" entry in derive_phase navigation block (#11584).
- `#11596` `keeper_keepalive.ml` — Heartbeat anchor (B1, 3 transitions: WakeupSignal/HeartbeatTick/MissedWakeup).
- `#11597` `keeper_unified_turn.ml` — TaskAcquisition anchor (B2, AssignTask/EmptyQueueSleep/TaskRejected).
- `#11599` `keeper_approval_queue.ml` — ApprovalQueue anchor (B3, Submit/Resolve/ExpireAndForceResolve + BoundedSuspension invariant).
- `#11608` `keeper_failure_circuit_breaker.ml` — CircuitBreaker anchor with Refinement classification (5 OCaml classes vs 3 spec abstract classes, by-design).
- `#11612` `keeper_rollover.ml`, `#11614` `keeper_post_turn.ml`, `#11615` `keeper_types.mli` — KeeperGenerationLineage 3/3 closure.
- `#11617` `keeper_memory_policy.ml`, `#11622` `keeper_memory_bank.ml` — KeeperMemoryLifecycle 2/2.
- `#11618` `keeper_execution_receipt.ml` — multi-spec anchor first (ReceiptOutcomeSet + OperatorPauseBroadcast).
- `#11625` `keeper_stale_watchdog.ml` — OperatorPauseBroadcast 2/2 with module-relocation drift correction.
- `#11634` `keeper_guards.ml` — KeeperTurnCycle anchor (single-action `GateRejected` ownership).

### Changed (spec citation refresh — autonomous Cycle 40-43)

- `#11641` `KeeperTurnCycle.tla` — 22 stale line citations across 4 OCaml files refreshed to current main; forward-stability disclaimer added.
- `#11645` `KeeperRuntimeLifecycle.tla` + `KeeperDecisionPipeline.tla` — sibling refresh of the same `keeper_registry.ml` setter family (`mark_turn_started` 386→493, `mark_turn_finished` 472→614, etc.; 8 setters total).
- `#11647` `KeeperHeartbeat.tla` — 3 stale `keeper_keepalive.ml` citations refreshed (uniform +13 drift; matches Cycle 27 anchor's inline drift note).
- `#11649` `KeeperSocialModelMagenticLedger.tla` — narrow citation refresh.

### Other operational changes (234 commits)

This release also rolls up substantial operational and infrastructure work merged since v0.18.8 — see `git log bff6a28b..HEAD` for the full set. Notable themes (without exhaustive PR-by-PR enumeration):

- **PPX `tla_derive`** (`#11377`, `#11384`, `#11430`, `#11450`) — PPX deriver scaffold + `keeper_turn_fsm.mli` first application + `module type TLA_STATE_MACHINE` + `[@fsm_guard]` runtime injection (Tier I1/I2/I3 of the Kimi keeper FSM review plan).
- **Receipt outcome quad-state** (`#11360`, `#11491`, `#11499`, `#11500`) — `outcome_kind = [`Ok | `Error | `Cancelled | `Skipped]` polymorphic variant + outer Cancel handler producer + spec parity (Tier S1 + Cycle 1b A/i/ii/iv).
- **`AuthIdentityFSM.tla` integration** (`#11391`) — `specs/auth/` directory + clean+buggy cfg (Tier S2).
- **Receipt append failure escalation** (`#11398`) — silent `Log.warn` → `Result.Error \`Receipt_lost` (Tier A2).
- **Path leak removal** (`#11403`) — relative paths or hashes in `keeper_alerting_path.ml` error strings (Tier A3).
- **Heartbeat / TaskAcquisition / ApprovalQueue specs** (`#11408`, `#11412`, `#11417`) — 3 new spec modules with bug-action contracts (Tier B1/B2/B3).
- **`tools/tlc_test_gen/`** (`#11525`, `#11539`, `#11553`, `#11563`) — TLC counterexample → OCaml regression test scaffold + nested record fixture + PPX-free test runner + multi-spec self-validation (Tier C2).
- **234 other operational commits** across feat/fix/refactor/chore — feature work in runtime routing, dashboard, MCP transport, design-system token migration, PPX adoption, type SSOT extractions, agent_core pin bumps, etc.

### Notes

- The autonomous Cycle 24-44 series is documented in `~/me/planning/claude-plans/30m-users-dancer-downloads-kimi-agent-ke-wobbly-shell.md` §19.
- All 20 spec/docs PRs in the Cycle 24-44 series are behavior-change 0; they affect only TLA+ and OCaml comments. The release boundary is largely a marker for the broader 254-commit corpus.

## [0.18.8] - 2026-04-28 — patch: keeper fleet reliability (goal repair + auto-task-start + preset workspace collaboration)

Aggregate of 8 commits since v0.18.7 (3 feat / 2 fix / 2 test / 1 chore). No breaking API changes.

Keeper fleet reliability release: empty `active_goal_ids` now auto-repairs via keeper audit (PR1 #11351), claimed tasks auto-start immediately (PR2 #11364), and social/dispatch presets gained workspace collaboration tool access (PR3 #11345).

### Added (keeper reliability)

- **keeper_goal_repair**: detect and repair keepers with empty `active_goal_ids` by creating goals from keeper purpose statements. New module `Keeper_goal_repair` with dry-run and execute modes.
- **auto-task-start**: `keeper_task_claim` now automatically calls `masc_transition(action=start)` after successful claim, eliminating the claim-without-start pattern that caused task abandonment.
- **preset workspace collaboration tools**: social and dispatch tool presets now include `masc.workspace collaboration` group, granting access to `masc_transition`, `masc_claim_next` and related workspace collaboration tools.

### Fixed

- Keeper audit now reports `empty_active_goal_ids` as an actionable issue with repair guidance.
- Keeper meta reconciliation detects goal-less keepers and surfaces them in audit output.

### Changed

- `scripts/ocaml-structure-baseline.json` updated: `keeper_mli_missing: 21`, `lib_dune_lines: 954`.


## [0.18.7] - 2026-04-27 — patch: keeper contract fix (require_tool_use stay_silent) + dashboard KpiStrip canonical sweep + observability + auth fail-closed

Aggregate of 17 commits since v0.18.6 (11 feat / 4 fix / 1 test / 1 chore). No breaking API changes.

Operational keeper-contract correctness release: `require_tool_use` contract accepted the retired keeper no-op sentinel as a satisfied turn, eliminating a contract-vs-prompt mismatch that rejected ~40% of post-runtime-fix turns. Plus dashboard StatCard retirement (3-sweep migration into KpiStrip) and observability surface emissions for substrate visibility.

### Added (observability + structural)
- `#11125` observability — emit `[substrate:tool_surface]` log + SSE on TurnReady (per-turn tool surface visibility)
- `#11133` observability — emit `[substrate:system_prompt]` per keeper turn (operator visibility into per-turn prompt content)
- `#11121` keeper — high-priority `.mli` files for keeper modules (interface contract surfacing)
- `#11120` test — cross-FSM joint behavior tests mirroring TLA+ SafetyInvariant
- `#11126` specs — AuthIdentityFSM bug-model for silent identity fallback

### Changed (dashboard KpiStrip canonical sweep)
- `#11135` retire StatCard, migrate 27 callsites to KpiStrip+KpiCell (sweep #3)
- `#11130` migrate feature-health overview into KpiStrip (sweep #2)
- `#11128` migrate overview funnel into KpiStrip (sweep #1)
- `#11122` add KpiStrip composite (cb-group-a SPEC alignment)
- `#11118` adopt KpiCell in feature-health overview (apply cycle 2)
- `#11116` adopt KpiCell in overview funnel (apply cycle 1)
- `#11131` design-system — add 4 raw tokens + migrate bonsai flame_*

### Fixed (keeper contract correctness)
- `#11124` keeper — classify the retired keeper no-op sentinel as `Completion` to satisfy `require_tool_use` contract (decisive no-op recognition; abuse defence retained via no-progress loop detection)
- `#11132` server-auth — fail-closed on `Ok None` instead of silent dashboard rewrite (security hardening)
- `#11117` scripts — resolve log path via lsof on running server, eliminate $HOME drift
- `#11123` keeper — raise compact_ratio default 0.5 → 0.85 (#11111 follow-up, fewer premature compactions)

### Removed
- `#11119` mcp — drop deprecated prompt stubs (`execution_session_proof`, `command_truth`)

## [0.18.6] - 2026-04-27 — patch: keeper resilience (retry guard + watchdog auto-pause) + design-system token wave continuation + i18n rounds 95-101

Aggregate of 37 commits since v0.18.5 (15 fix / 13 feat / 7 i18n / 1 perf / 1 chore). No breaking API changes.

Operational hardening release: keeper recovery surfaces (oas_timeout retry guard relax, watchdog auto-pause on stale termination storm, zombie detection seed, runtime-filter dedup) plus continuation of canonical SPEC token wave (status/border/bg-hover/bg-surface/accent-soft/CSS-files) and 7 localization rounds.

### Added
- `#11070` dashboard — Heartbeat + LifelineBar primitives (cb-group-a)
- `#11066` dashboard — KpiCell primitive (cb-group-a, Stage A)
- `#11088` dashboard — TickerItem + TickerStrip primitives (cb-group-a)
- `#11075` transport — P1 failure-path counters for SSE broadcast
- `#11068` workspace — extract local git op timeout to env (SSOT, #10426)

### Changed (design-system canonical SPEC tokens)
- `#11095` adopt canonical SPEC tokens in handwritten CSS files
- `#11087` canonical SPEC §3.5 status tokens (10-file sweep)
- `#11085` canonical accent-soft token in 5 remaining files (CS105)
- `#11076` canonical accent-soft token in 5 files
- `#11073` canonical SPEC border tokens (`--border-slate-N` sweep)
- `#11067` canonical bg-hover token (`--bg-panel-hover` sweep)
- `#11065` SPEC fs scale for arbitrary `text-[10px]/text-[11px]`
- `#11064` canonical SPEC bg-surface in 5 files (`--card → --color-bg-surface`)

### Fixed (keeper resilience)
- `#11057` keeper — relax `oas_timeout` retry guard 30→15 (cycle6 band-aid)
- `#11055` keeper-watchdog — Phase 2 auto-pause on stale termination storm (closes #10765)
- `#11062` keeper — seed `last_turn_ts` to bootstrap time so watchdog can detect zombies
- `#11084` runtime-filter — dedupe `all-providers-rejected` WARN, promote first to ERROR (#11060)
- `#11080` keeper — stop leaking host playground paths to LLM tool responses
- `#11099` keeper — surface 5 P2 silent failures (telemetry gaps)
- `#11074` keeper — surface 2 P1 silent failures in registry

### Fixed (build / types / dashboard)
- `#11092` main — restore green build broken by #11077 + #11078
- `#11093` workspace — Eio 1.0+ types in `workspace_utils_backend_setup.mli`
- `#11078` workspace — add missing `.mli` files for workspace_utils and worktree
- `#11094` dashboard — surface 6 P2 silent failures (telemetry gaps)
- `#11072` auth — add token hash prefix to dashboard fallback warn
- `#11041` server-auth — decompose dashboard fallback `err_kind` beyond `[other]`
- `#11061` a11y — add ARIA attributes to connector-config-form

### i18n
- `#11098` localize 4 fallback error literals (round-101)
- `#11091` localize 10 api/ thrown Error payloads (round-100)
- `#11086` localize 3 keeper API thrown errors (round-99)
- `#11082` finish fsm-hub-lane-analysis (round-98)
- `#11071` localize turn/decision/runtime/compaction lane meanings (round-97)
- `#11069` localize 9 'phase' lane meaning fields (round-96)
- `#11063` localize 'vs env' delta suffix (round-95)

### Performance
- `#11090` hoist per-call `Re.compile` to module-level bindings

### CI / chore
- `#11089` naturalize L1a baseline 27→28 to match main

## [0.18.5] - 2026-04-27 — patch: design-system canonical SPEC token wave + i18n round 90-92 + env SSOT extractions

Aggregate of 19 commits since v0.18.4 (10 feat-design-system / 4 fix / 3 i18n / 1 feat-typography / 1 feat-sidecar). No breaking API changes.

Continuation of the design-system unification wave — converts 10 dashboard surfaces to canonical SPEC color/accent/fg tokens (CS89 onward) and finalizes localization rounds 90-92. New env-driven SSOT extraction surface for sidecar subprocess timeouts.

### Added
- `#11039` dashboard — SPEC §3 typography & spacing scale (Phase G Step 2)
- `#11049` sidecar — extract subprocess timeouts to env (SSOT)

### Changed (design-system canonical SPEC tokens)
- `#11050` server-config fg token
- `#11053` accent token sweep across 6 files
- `#11048` accent token in 3 remaining files
- `#11042` color tokens in feature-health & transport-beacon
- `#11035` color tokens in retired-scrape-backend-metrics
- `#11033` color tokens in keeper-detail-shell
- `#11031` color tokens in autoresearch
- `#11028` color tokens in keeper-config-panel
- `#11027` color tokens in telemetry-unified
- `#11023` runtime-config-panel tokens (CS89)

### Fixed
- `#11056` dashboard — update test assertions for i18n localized strings
- `#11038` dashboard — surface 3 P1 silent failures
- `#11037` agent-core-worker-exec-transport — remove unreachable catch-all in transport_for_provider
- `#11032` mcp/join-guard — resolve rotation alias to canonical join entry (#10699 Family A)

### i18n
- `#11034` localize 4 operator-actions extractApiError fallbacks (round-92)
- `#11030` localize 4 user-facing strings outside components/ (round-91)
- `#11026` localize transport-beacon + keeper-detail-shell tooltips (round-90)


## [0.18.4] - 2026-04-27 — patch: a11y completion + worktree cleanup extension + log severity ratchet

Aggregate of 29 commits since v0.18.3 (12 fix / 7 i18n / 4 feat / 3 refactor / 2 a11y / 1 perf / 1 ci, includes 10 commits landed during release CI window). No breaking API changes.

Follow-up patch that closes the dashboard a11y round (#10930 focus trap + aria-expanded landed), extends worktree auto-cleanup to Cancel/Release transitions building on the v0.18.3 leak root fix, and introduces the log severity anti-pattern detector ratchet baseline.

### Fixed
- `#10930` dashboard a11y — focus trap, aria-expanded, readability (final round-6 landing after rebase cycle)
- `#11001` workspace/task — extend worktree auto-cleanup to Cancel and Release transitions (continuation of v0.18.3 #10956 root fix)
- `#10999` keeper-watchdog — emit fleet batch-termination ERROR when ≥3 keepers stop in 30s (#10765 follow-up)
- `#11008` build — drop 5 redundant catch-all arms after provider_kind exhaustive sweep
- `#11019` provider — exhaust provider_kind matches for lint (broader sweep)
- `#11022` session — bound registry + mcp-store mailboxes (was max_int)
- `#11025` keeper — warn once when sandbox GH_TOKEN unavailable
- `#11012` keeper-supervisor — surface keeper drift at registration (#10993)
- `#11004` admission — inline fd-growth rate in admission rejection log (#10745)
- `#10995` approval-queue — skip Critical risk in expire_stale to break re-enqueue cycle
- `#10992` contract — harden public tool sweep and runtime guard edges

### Added
- `#11013` dashboard — extend SPEC §3 color alias bridge in variables.css (CS87)
- `#11011` keeper — capture unknown TOML keys on profile_defaults
- `#10997` dashboard — adopt KeeperBadge in ConnectorKeeperMatrix row label

### a11y
- `#11017` dashboard — agent-detail role=log/region/progressbar
- `#11021` dashboard — auth-status aria-expanded/haspopup

### Performance
- `#11002` dashboard — isolate fsm-hub render scope from 5 s tick

### Changed
- `#11016` server-bootstrap — demote 5 recoverable cleanup Errors → Warn (§ 3.3)
- `#10994` design-system — swap connector restart button to ActionButton ok (PR-CS83)
- `#10981` design-system — swap activity-stream FilterBar to ActionButton ghost (PR-CS81)

### CI
- `#11000` log severity anti-pattern detector — Phase 1 ratchet baselines

### i18n
- `#10990` `#10996` `#10998` localize nextExpectedStep return strings (rounds 83–85)
- `#11003` localize 7 detail field strings (round-86)
- `#11005` finish fsm-hub-invariant-analysis (round-87)
- `#11006` localize "Tool telemetry unavailable" fallback (round-88)
- `#11014` localize 2 short matrix tooltip titles (round-89)


## [0.18.3] - 2026-04-27 — patch: leak root fixes + keeper observability + design-system progress

Aggregate of 30 commits since v0.18.2 (9 feat / 6 refactor / 6 fix / 4 i18n / 3 docs / 2 perf). No breaking API changes.

Follow-up to v0.18.2 stability hardening. This release closes two long-standing leak issues at the source (autoresearch + keeper-playground worktree cleanup) and continues design-system swap wave + KeeperBadge primitive adoption. All `feat` entries are additive.

### Fixed (leak root cause)
- `autoresearch`: auto-cleanup managed worktree on terminal transition (#10892, #10968) — `Switch.on_release` pattern, prevents per-job dir accumulation (~91 MB / job pre-fix).
- `workspace/task`: auto-cleanup playground worktree on task done (#10899, #10956) — `Workspace_hooks` task_done pattern, closes contract gap when keeper crashes mid-task / watchdog stale-termination / SP-suppression / LLM forgets to call `masc_worktree_remove`.

### Fixed (keeper / fleet hot path)
- `server`: wire `approval_janitor` fork to break HITL death-spiral (#10973).
- `mcp/call_tool`: demote policy/workflow rejections from ERROR to WARN (#10975, #10978).
- `keeper/sp`: probe escape valve every 10 same-cohort suppressions (#10887, #10948).

### Added (keeper observability)
- `keeper`: surface deliberate-skip reasons on stale watchdog kill (#10962).
- `workspace/task`: retired scrape backend counter + warn log for `task_claim_next` implicit auto-release (#10421, #10977).
- `masc_oas_bridge`: cancel reason bucket + inner exception (#10954) — surfaces agent_core cancellation provenance.

### Added (dev tooling / SSOT)
- `keeper-bootstrap`: extract autoboot polling/settle intervals to env (SSOT) (#10957).
- `dashboard`: `ErrorRecoverable` + `ErrorFatal` 2-tier error states (#10965).
- `dashboard`: `KeeperBadge` primitive + adoption in safe-autonomy `FindingsList`/`KeeperCard`/`TimelineList` (#10955, #10970, #10983).
- `docs/spec`: log severity taxonomy SSOT — anti-pattern catalog + lint rule scaffold (#10963).

### Refactor
- `dashboard`: extract `createSharedTicker` factory + dedup boilerplate (#10971) — shared ticker helper for periodic re-render across panels.
- `design-system swap wave`: PR-CS75 ~ PR-CS82 (#10966, #10974, #10979, #10980, #10987 + others) — ActionButton variants (warn / ghost), TextArea swaps.

### Perf
- `dashboard`: migrate fsm-hub timeline + pipeline children to `nowSecondsSignal` (#10961, #10969).

### i18n
- `dashboard`: localize Idle snapshot headline (round-71), substring-safe headlines (round-73), keeper directory error panel (round-78), composite-fsm-flowchart, sectionLabel for fleet-health/safe-autonomy (#10939 / #10943 / #10964 / #10984 / #10976).

### Docs
- `docs/workspace`: add `workspace_gc.mli` + `workspace_git.mli` (#10751 batch — #10958 / #10960).
- `scripts`: add `cleanup-autoresearch.sh` interim TTL quarantine + help-text polish (#10913 / #10967).

### Bumps
- dune-project version 0.18.2 → 0.18.3
- masc.opam version 0.18.2 → 0.18.3
- CHANGELOG.md: v0.18.3 entry added (0.18.2 history preserved)
- ROADMAP.md / docs/PRODUCT-OPERATING-PLAN.md / docs/spec/SPEC-INDEX.md: version refs synced

### Out of scope (deferred)
- 4 stale `sangsu-task-*` orphan worktrees from before #10956 land (Apr 22, dirty 1-line `network_mode` config) — operator manual sweep recommended in #10899 follow-up comment.
- #10930 / #10871 user a11y stack PRs (`a11y-006` / `a11y-007`) — most patches already upstream via #10874; recommended cherry-pick novel only or close + restart.


## [0.18.2] - 2026-04-27 — patch: keeper stability hardening + observability + dev tooling

Aggregate of 66 commits since v0.18.1 (18 fix / 8 feat / 14 refactor / 6 perf / 9 i18n / 8 squash / 2 chore / 1 test). No breaking API changes.

Follow-up to v0.18.1 ProviderTerminal rescue. This release collects a wave of keeper-watchdog / runtime rotation / autoboot / sandbox-docker fixes that landed after a focused diagnostic cycle, plus dashboard-side observability and dev-tooling SSOT cleanup. All `feat` entries are additive (env knobs, lint detector, telemetry semantic refinement, dev scripts, design-system sync) — no behavioural defaults changed for runtime keepers.

### Fixed (keeper / fleet hot path)
- `keeper-watchdog`: suppress idle-stale events during an active turn; add a separate turn-timeout (default 600s) so watchdog stops misclassifying mid-turn LLM waits as stalls (#10940).
- `keeper`: cap runtime rotation at 1 for `required_tool_contract_violation` so a single proactive contract miss can't cycle through every provider (#10851).
- `workspace/task`: emit warn when a task crosses the 5-cycle oscillation threshold so operators see escalation candidates (#10719, #10920).
- `server/autoboot`: per-task boot guard so a single hung lazy task can't block keeper boot — restore_sessions now degrades gracefully instead of hanging the boot pipeline (#10857).
- `boot`: start `Runtime_legacy_runner` actor consumer fiber that was dropped in a refactor and left the runtime actor without a reader (#10895).
- `runtime-filter`: per-provider rejection diagnostics for #10681 so runtime-skip reasons are visible per provider, not aggregate (#10852).
- `keeper-shell-docker`: detect `gh --repo X api Y` LLM-hallucinated form and self-correct (108 events / day pre-fix, #10855, #10900).
- `keeper-shell-docker`: replace `List.hd` with pattern match (Health ratchet, #10905).
- `auth`: stop classifying `keeper-<id>-agent` as a transient alias so per-keeper credentials don't churn (#10867).
- `auth`: surface `error_kind` + `actor_hint` in `dashboard_actor_fallback` warn payload for easier triage (#10933).
- `post_verifier`: add Korean filler phrases (filler detector previously English-only, #10882, #10938).
- `workspace/config`: memoize `default_config` to drop 1745 redundant inits / 2 days (#10919, #10937).

### Fixed (dashboard / health / hygiene)
- `health`: replace `List.hd` with pattern match in `keepers_directory` (#10926).
- `dashboard`: a11y restore `role=status`/`role=alert` on loading/error indicators (#10874).
- `dashboard`: update test expectations for i18n-localized flag tooltips (#10929).
- `workspace/backend`: demote per-call backend init logs to DEBUG (1745 events / 2d, #10919, #10928).
- `keeper/watchdog`: demote all-default tick log to DEBUG (1638 events / 2d, 92% all-healthy, #10908, #10910).
- `ws-transport`: downgrade per-session lifecycle log to DEBUG (4029 events / 31min, #10875, #10881).

### Added (feat — additive, env-gated where applicable)
- `dashboard`: extract mission/shell/render timeouts to env (SSOT, #10880).
- `dashboard`: extract execution-surface timeouts to env (SSOT, #10886).
- `process`: consolidate 11 hardcoded subprocess timeout defaults to env (SSOT, #10889).
- `lint`: detect Eio actor consumer fibers that are never wired up (covers the #10895 class of bugs at the lint layer, #10904).
- `scripts`: add `cleanup-autoresearch.sh` — TTL-based quarantine for stale autoresearch dirs (#10913).
- `telemetry`: mark `Goal_event` as `optional_when_missing` — show `not_yet` instead of `missing` for keepers that haven't emitted yet (#10921).
- `design-system`: sync v0.4.3 — extract `semantic.css` + 6 preview pages (#10898).
- `dashboard`: localize Runtime profile tooltip + reveal aria (round-52, #10811).

### Changed (perf — dashboard re-render reduction)
- `dashboard/fsm-hub`: drop 1 Hz tick to 5 s for re-render reduction (#10894).
- `dashboard/fsm-hub`: drop self-triggering `pollTick` from interval deps (#10914).
- `dashboard`: hoist 5 s wall-clock tick to a shared module signal (#10918).
- `dashboard`: hide `sourceMappingURL` to stop browser map auto-fetch (#10907).
- `dashboard`: add opt-in bundle visualizer (`BUNDLE_REPORT=1`, #10897).
- `transport`: label `sse_broadcast_events_total` by `target` for per-target broadcast attribution (#10916).

### Changed (refactor / i18n / squash)
- 14 refactor PRs (design-system migration across multiple panels, dashboard utility consolidation).
- 9 i18n rounds (rounds 52, 68, 69, 70, 72, 74) covering ~25 chips/labels/empty-state strings.
- 8 squash merges (autocoder dedup + small-PR rollups).

### Notes
- Diagnostic chain that drove this batch: `#10474` runtime dead → `#10745` fd leak (separate fix wave, partially captured) → `#10765` keeper stale watchdog terminating fleet → `#10872`/`#10940` keeper-watchdog suppress + turn timeout. Diagnostic comments → autocoder fix loop closed end-to-end within 6 hours.
- Out of scope (deferred to follow-up release): `#10828` no process-level supervisor (awaiting operator policy decision; conflicts with `<launchd>` guidance), `#10887` keeper self_preservation `ratio=1.00` permanent lock (FSM circuit-breaker design review needed), `#10719` task-049 cycle=20 hard-stop escalation (this release adds the warn signal at threshold 5; threshold ≥15 hard-stop is a separate proposal).

## [0.18.1] - 2026-04-26 — patch: rescue v0.18.0 release (ProviderTerminal partial-match fix-forward)

Aggregate of 37 commits since v0.18.0 (14 feat / 10 fix / 9 refactor / 2 chore / 2 diag). No breaking API changes.

The v0.18.0 tag exists but its GitHub release workflow failed: the agent_core pin bump to SHA `162940fd` (#10667) added a `ProviderTerminal` variant that broke 6 partial-match sites. This patch ships the fix-forward (#10713 + #10721) plus a batch of dashboard localisation, design-system migration, and keeper hardening work that accumulated on `main`.

### Fixed (rescue path)
- agent_core boundary: close `ProviderTerminal` partial-match in `Oas_compat` + add `error_message` helper (#10721).
- agent_core bridge: add `ProviderTerminal` arm at 3 partial-match sites (#10713).

### Fixed
- Watchdog: extract to standalone module, cover autoboot path (#10698).
- Workspace: resolve `git_clone` policy at canonical `.masc/config/` path (#10693).
- Keeper: auto-pause on `runtime_exhausted` to break supervisor restart loop (task-074, #10691).
- Keeper: use container path for `default_cwd` / `private_workspace_root` in `masc_keeper_status` (#10650, #10686).
- Deploy: build dashboard SPA in Dockerfile multi-stage build (#10684).
- Dune: exclude misplaced `worktrees/` (no-dot) from dune scan (#10688).
- TLA+: add `Recycle` action to clear `OperatorPauseBroadcast` deadlock (#10678).
- Fleet: use sandbox arguments in `keeper_context_status` instead of host paths (#10677).

### Added (feat)
- Dashboard localisation rounds 31–41: 70+ chips/labels/headings/aria-labels across many components (#10685, #10689, #10690, #10695, #10697, #10700, #10703, #10708, #10712, #10714, #10723).
- Audit: keeper credential UUID layout integrity detector (#10718) and dual-identity drift detector (#10706).
- Design system: `ActionButton` `pressed` prop + tool-picker tier filter swap (PR-CS4, #10679).

### Changed (refactor)
- Design system PR-CS5 → PR-CS12: ActionButton/Select migration across runtime-monitor (#10722), connector-quick-bind (#10717), governance-monitor (#10715), agent-profile (#10705), memory-post-detail (#10702), tool-picker (#10694), error-panel (#10687), autoresearch (#10683).
- Rename `Oas_sse_bridge` → `Runtime_event_bridge` (transport-agnostic, #10711).

### Chore
- agent_core pin: bump SHA to `97b8a603` (agent_core #1201 TurnReady event, #10704, #10709).

### Diagnostics
- retired scrape backend: capture EDEADLK backtrace on `metrics_mutex` (#10682, #10707).
- Keeper-tools-agent-core: capture backtrace on EDEADLK to identify mutex site (#10682, #10696).

## [0.18.0] - 2026-04-26

Aggregate of 50 commits since v0.17.0 (18 feat / 11 fix / 9 refactor / 5 perf / 3 docs / 3 chore / 1 diag). No breaking API changes. Headline: dashboard localisation continues (rounds 24–28, 50+ chips/labels), keeper stability gains noop-cycle classifier fix unblocking 8x cooldown trap (#10672) and `/workspace` LLM hallucination negative anchor (#10647), RFC-0008 PR-1 introduces `Credential_provider` property + `Host_config_provider` (#10660).

### Added (feat)
- Dashboard localisation rounds 24–28: 50+ chips/labels/headings across multiple components (#10644 round-24, #10651 round-25, #10653 round-26, #10655 round-27, #10666 round-28); WS-only cutover dev default + transport beacon (#10657).
- Keeper architecture: RFC-0008 PR-1 — `Credential_provider` property + `Host_config_provider` (#10660).
- Config SSOT: `Pr_review_post` caller (30s) + migrate `gh pr review` write site (#10626); `Git_meta` + `Shell_probe` callers added to `exec_timeout` SSOT (#10603).

### Changed (refactor)
- Common: `auth_dir` / `agents_dir` helpers hoisted to break P2 cycle (#10658); orphaned `Error` module + its coverage test dropped (#10659).
- Dashboard: `bg-0` / `bg-1` / `bg-2` migrated to semantic aliases (#10638); inline buttons replaced with `ActionButton` in transport-health (PR-CS1, #10646) and autoresearch (PR-CS2, #10656).
- Alerting: default 15→20s + `gh-issue-create` site migration (#10622).

### Fixed
- Keeper proactive scheduler: `Claim_context` excluded from noop cycle (#10672) — unblocks 8x cooldown trap that was pinning `ollama-local` and `qa-king` keepers.
- Keeper sandbox prompt: `/workspace` negative anchor + `workspace` word replaced (#10647) — addresses LLM training-time prior hallucination.
- Keeper concurrency: `Stdlib.Mutex` migrated to `Eio.Mutex` in single-domain hot paths (#10649).
- Runtime: judge profiles ordered gemini-first to skip codex 30s timeout cycle (#10642).
- Observability: `[max_turns]` / `[hard_quota]` class label prepended to runtime-fallback log (#10641, addresses #10629).
- Dashboard tests: `successClass` / `statusChipClass` aligned with semantic aliases (#10662); telemetry / overview tests aligned with current source (#10654).

### Performance
- 5 perf commits (text-similarity, gate-diff, auth, cdal-judge SSOT delegations).

### Diagnostics
- Observer: `last_turn_ts` exposed in composite snapshot for watchdog diagnosis (#10663).

### Documentation
- CHANGELOG 0.16.0 + 0.17.0 release notes filled (#10639).

## [0.17.0] - 2026-04-26

Aggregate of 103 commits since v0.16.0 (42 feat / 24 fix / 15 perf / 15 refactor / 4 chore / 2 docs). No breaking API changes. Headline: design-system semantic alias migration completes its bulk of CSS/JSX surface; runtime unblock series resolves repeated `agent_sdk` cap drift; keeper stability gains stale watchdog fiber restart and stream-idle gap-detection.

### Added (feat)
- Design-system semantic alias migration (35 PRs, batches PR-M14 through PR-M26 + S3e–S3h). SPEC §3 alias introduced to both products at Stage 1 (#10611), then sweeps over `layout.css` (#10586), `sidebar.css` (#10587), `drawer.css` (#10588), `swimlanes.css` (#10589), `primitives.css` (#10590), `deck.css` (#10591), `code.css` (#10595), `cockpit.css` (#10597), `preview/*.html` (#10600), `preview/*.jsx` (#10601), `ui_kits/cockpit/*.jsx` (#10602), `_preview.css` (#10621). Bonsai shadow-ring rename + SPEC §6.2 escape hatch (#10620). Bonsai paper colors + scrollbar absorbed (#10556).
- Topbar variant API unified (Phase 3 consistency, #10505); SectionHeading primitive extracted (#10476).

### Changed (refactor)
- SSOT consolidation: cohort_key moved to source-of-truth module (#10618); 12 deprecated re-exports dropped from `Keeper_context_runtime` (#10616); KeeperSandbox/DockerPlayground aliased to `Env_config_sandbox` (#10536); 5 Alerting/Pr_review timeout literals migrated to SSOT (#10502); 4 Sandbox/Turn_sandbox timeout literals migrated (#10486); 3 sandbox hardcoded constants migrated (#10551). Alerting default 15→20s (#10615).
- Yojson hygiene: drop unused decoder for `agent_identity.t` + `post_eval_result` (#10526); lint exempts encoder-only deriving from option-default rule (#10537).
- Bumped `agent_sdk` floor to 0.177.0 (#10608) after raising cap to <0.178.0 to align with pinned SHA v0.177.0 (#10592).

### Fixed
- Runtime unblock series: accept `weight=0` in toml materializer (#10571 / #10610) after the codex_cli weight=0 sweep (#10554) was reverted (#10613). Pin agent_sdk upper bound to <0.177.0 (#10497 / #10529), then raised to <0.178.0 (#10592). `check-agent-core-pin` regex accepts capped-floor pattern (#10596). Keeper supervisor handles `Stale_turn_timeout` in cohort_key (#10572 / #10574).
- Keeper stability: stale watchdog triggers fiber restart instead of cosmetic broadcast (#10540); `stream_idle_timeout` set to gap-detection value 120s (#10604); `Stdlib.Lazy` replaced with Atomic+Mutex memo in keeper memory bank (#10399 / #10407); turn_timeout_sec_live aligned with SSOT (#10456 / #10469); pause directive persist + duplicate cohort key drop (#10593).
- Sandbox: accept legacy 3-field `docker inspect` without `ttl_sec` (#10488 / #10513 / #10514); preserve trailing tab; scrub `roots=` leak from path-rejection errors (#10349 / #10383); `gh-validation` inlines allowed command list in blocked error (#10561 / #10566).
- Auth: write short-form alias for every keeper at bootstrap (#10440 / #10525). Auth bridge SSOT routing (#10400 follow-through).
- Observability: inline rejection context in `runtime-no-callable-models` ERROR (#10528 / #10541); align `system_log` filename to UTC (#10392 / #10401); duplicate `InferenceTelemetry` emit dropped (#10489 / #10490 / #10511).
- TLA+: `OperatorPauseBroadcast` spec wired into `tla-check.sh` (#10516 / #10521).
- Dashboard: cb-group-a.jsx de-duplication after squash union (#10437 + #10451 → #10467).

### Performance
- String hot paths: `String.sub` equality replaced with `String.starts_with` across 8 hot paths (#10532), sweep 2 across 7 files (#10543), gh-validation 5 hunks (#10548); WS SSE data payload single `String.sub` (#10560); `String_util.equals_ci` SSOT applied to HTTP header lookup (#10612).
- List hot paths: `List.length` emptiness check replaced with `[] =` (13 hunks, O(N)→O(1), #10568); `List_util.count_if` SSOT introduced + sweep 16 sites across 14 files (#10609); single-pass `count_if` for 7 `List.length(List.filter)` sites in model_inference_metrics (#10607); file-private `take` helper for top-N truncation (#10619).
- Lookup: `try Hashtbl.find/Unix.getenv` replaced with `_opt` variants in 2 hot paths (#10575).
- Server auth: 2 allocations dropped from Bearer header check (#10483).
- MCP accept-header: redundant lowercase removed from callbacks (#10539, parked).

### Documentation
- See PR notes; 2 commits.

## [0.16.0] - 2026-04-26

Aggregate of 206 commits since v0.15.0 (95 fix / 38 perf / 21 feat / 13 chore / 10 refactor / 9 diag / 5 test / 3 obs / 2 docs). No breaking API changes. Headline: stability-heavy release — 95-fix sweep across keeper/sandbox/runtime/auth + 38 hot-path performance reductions + Trust system Phase 0a–1.

### Added (feat)
- Runtime trust system: fingerprint counter for trust observability (Phase 0a, #10292), JSONL snapshot of trust state every minute (Phase 0b, #10331), `trust_score` auto-rotation on persistent failures (Phase 1, #10365).
- Keeper identity: `normalize_all_names` SSOT (P1, #10417); silent identity-fallback paths surfaced (PR-I scope 1, #10351).
- Governance: destructive vs evasion-only payload severity split (#10355); routine matcher preflight + `keeper_shell git_clone` allowlist (PR-E, #10396).
- Transport: identity headers preserved on Codex CLI runtime MCP (#10359).
- Keeper runtime: sandbox cleanup error messages emitted in janitor loop (#10433); `keeper_composite` exposes `fiber_stop` / `fiber_wakeup` / `noop_count` / `idle_seconds` (#10312).
- Dashboard: low-trust operator recommendations (Phase 2a, #10416); a11y baseline for Code IDE v2 (#10394) and dashboard Phase 1 cb-group-a (#10451); semantic color tokens + theme infra (#10427).
- Config: `Env_config_exec_timeout` SSOT scaffold for #10426 P1 (#10452).

### Changed (refactor / chore)
- 10 refactor + 13 chore commits — see PR refs.

### Fixed
- Build / runtime unblock: main build unblocked after Phase-1 trust revert orphans (#10441 / #10445); `discover_keepers_toml` per-cycle WARN spam dedup (#10259 / #10380); `runtime_id` with `keeper_assignable=false` rejected (#10388 / #10406); degraded TOML-section fallback for keeper-name validator (#10259 / #10274); attribute and cool down Kimi resumable failures (#10285 / #10300); scheduler-safe RNG mutex (#10413).
- Keeper / sandbox: keepers taught to chdir before git in sandbox (#10424 / #10435); fall back to gh CLI keychain for sandbox `GH_TOKEN` (#10378); price cache usage in turn cost (#10379); register sandbox cleanup in server background loop (#10366); raise `git status` timeout default (#10360); consensus regex cache guard (#10377).
- Auth / dispatcher: ctx identity enforced on board author/voter (#10297 / #10305); keeper bearer tokens split at bootstrap (#10304 / #10313).
- Telemetry: tolerate nullable `Tool_assigned` preset (#10450); recover tool and task lifecycle diagnostics (#10358 / #10369); time-based flush makes sub-cap heuristic-metrics emit visible (#10348 / #10363); per-failure learning tags emitted instead of boilerplate (#10325 / #10330).
- Goal / FSM: `Awaiting_verification` exit transitions added (#10411 / #10420); periodic sweep fiber added in goal-janitor bootstrap loops (#10405 / #10439); lifecycle states blocked on goal upsert (#10247 / #10261).
- Transport: tunnel host detection in `legacy_messages_endpoint_url` corrected (#10454).
- Anti-rationalization: Korean rationalization patterns added (#10385 / #10391).
- Discovery history: all loaded models per probe preserved (#10404 / #10414).
- File I/O: `dated_jsonl` file-scope mutex registry shares lock across instances (#10372 / #10376); double-dropping tail prefix avoided (#10328).
- Bonsai: keeper SSOT bug eliminated by removing 3-source merge (#10343).
- agent_core bridge: route Governance/Operator judges through agent_core bridge SSOT (#9629 / #10400).

### Performance
- String hot paths: per-request `String.sub` allocations dropped on h2-gateway route prefix match (#10455), keeper-api-route per-suffix (#10444), ws-transport SSE/route (#10434), transport-read-model `trim_trailing_slashes` single-pass (#10438); 13 forked `starts_with`/`has_prefix`/`has_suffix` helpers routed through `Stdlib` (#10393); 7 forked `contains_substring` helpers routed through `String_util` SSOT (#10386); gh-cmd-validation routed through SSOT (#10384); `Json_util` SSOT applied to `json-string-field` 2 forks (#10410) + 2 more delegates (#10422); `Dashboard_http_helpers` `normalize_text` SSOT (#10402).
- PCRE caching: `Re.compile` hoisted in 4 hot paths + `String_util.find_substring` added (#10371); 2 more per-call `Re.compile` hoisted in drift-guard / board-votes (#10375); output-parse / memory-bank / consensus paths (#10367); tool-board / notify / inline-dispatch (#10361); link-preview compiled PCREs cached in `first_match` (#10381).

### Diagnostics
- Structured `Timeout` / `Parse_degraded` from agent-stress failure path (#10341 / #10346); structured signals replace boilerplate institution-episode failure learnings (#10325 / #10339); `agent_stress` emits `Turn_failure` from `keeper_unified_turn` (#10341 / #10362); 9 diag commits total.

## [0.15.0] - 2026-04-25

Aggregate of 185 commits since v0.14.0 (26 feat / 93 fix / 30 perf-refactor-obs-docs / 10 chore / 26 misc). No breaking API changes.

### Added (feat)
- Keeper observability counters: per-keeper turn-latency buckets (#10124), livelock observer (#10123), context_max drift (#10122), require_tool_use violations (#10099), proactive skip-reason (#10060), compaction outcome (#10011), usage-trust retired scrape backend (#10021), Hebbian per-outcome edge (#10048), metric-emit drops (#10053).
- Keeper runtime: affordance-tool intersection at `Require_tool_use` gate (#10141), Ollama `keep_alive`/`num_ctx` forwarding from keeper_runtime.toml (#9985), wire `Gh_exit_class` into docker sandbox (#9974), keeper authoring wizard (#9940).
- Workspace/FSM: per-agent FSM drift counter (#10152), retired scrape backend task FSM drift (#10082).
- Dashboard: gRPC `events_dropped` strip (#10114), WS delivery counters (#10106, #10107), WS-only cutover flag (#10102), websocket route slice expansion (#9963), a11y high-contrast + forced-colors support (#10080).
- agent_core/runtime: per-kind `masc_oas_error` counter (#10039), resolved_model_id metric label (#9962), context_overflow_imminent action signal (#9954).
- Keeper CLI: auto-construct Claude Code / Kimi CLI MCP config behind flag (#10059).

### Fixed
- Keeper: backlog gating on claimable tasks (#10159), supervisor sweep startup (#10161), max_restart loud alert (#10147), Ollama saturation skip (#10150), runtime MCP trajectory record (#10154), failed-turn episode persist (#10144), Hebbian first consolidation on fork (#10137), per-model telemetry empty-response defense (#10090), `keeper_msg` merged-CAS retry (#10135), Anthropic cache silent-disable flag (#10128), smart-heartbeat starvation (#10078), per_turn multiplier removed in favor of wall-clock cap (#10074), unified turn write_meta CAS retry (#10145).
- agent_core: API fingerprint metadata drift detection (#10156), agent-core bridge timeout SSOT (#10108), agent-core bridge typed contract (#10153), `codex_cli` MCP omission WARN dedup (#10100), suppress repeated omission warnings (#10109).
- Runtime: declarative `fallback_runtime` for single-provider profiles (life-support escalation) (#10157).
- Telemetry: dedupe websocket delivery schema (#10151), legacy degenerate row scrub at init (#10095), heuristic-theatre retired scrape backend migration follow-up (#10044).
- Governance: auto-approve `masc_transition` + `masc_board_post` for autonomous flow (#10148), default judge timeout raised to 180s (#10132), anti-rationalization gate-2 demoted to LLM advisory (#10116).
- Filesystem: `save_file_atomic` orphan boot sweep (#10131), test-executable HOME guard (#10085).
- Board/workspace: keeper actor identity unified (#10133), original vote timestamp persisted across flush (#10093), fixture-vote quarantine (#10079).
- A11y: ARIA on vis-timeline/vis-network/filter chips (#10138), keeper-phase ARIA (#10142), GraphQL Playground viewport zoom (#10134).
- Auth/usage: bearer-token cross-agent mismatch counter (#10129), Anthropic cache provider-kind evidence requirement (#10163).
- Tool registry: shard tool registration completeness (#10105).
- Dashboard SSOT: keeper display source unified (#10084).
- PR automation: draft guard skip for owner-authored PRs (#10143).
- CDAL gate: dormancy diagnostics + ledger health surface (#10118).
- WS perf: dashboard delta gating on client `bufferedAmount` (#10104).

### Performance
- Slice-aware fanout: Phase 1 slice index bookkeeping (#10155), Phase 2 fanout gate (#10160). Keeper supervisor sweep liveness counter + age gauge (#10126), dashboard delta gating on client `bufferedAmount` (#10104).

### Refactor
- Keeper meta types facade refactor (`refactor-keeper-meta-types-facade`).
- Dedup of redundant code paths in agent-core bridge, keeper-runtime, and telemetry-flow.

### Chore
- agent_core-pin refresh to `main@bbe5e6b0` (`v0.174.0`) for agent_core usage accounting (#1186); dependency floor remains `agent_sdk >= 0.174.0`.
- agent_core-pin bump to agent_sdk v0.173.0 (#10149) with version-floor synchronisation.
- RFC documentation: WS slice-indexed fanout design (#10119).

## [0.14.0] - 2026-04-24

### Added
- `Env_git_noninteractive` module (`lib/env_git_noninteractive.{ml,mli}`) centralises `GIT_ASKPASS=''` and `GIT_TERMINAL_PROMPT=0` for keeper docker subprocesses. Previously these constants were absent everywhere in the codebase (verified zero hits on commit `0e408ffc`), so a keeper `git push` inside the sandbox could, in principle, block indefinitely on a credential prompt if the RO-mounted `hosts.yml` auth path failed before git fell through.

### Changed
- `keeper_shell_docker.run_docker_shell_command_with_status` now appends `Env_git_noninteractive.docker_env_args` to the docker `-e` env list at the single credential-composition callsite (`lib/keeper/keeper_shell_docker.ml:234-245`). No change to identity/auth semantics; the container now fails fast on a git credential prompt rather than hanging.

### RFC
- RFC-0007 rev.3 and RFC-0008 landed as design documents (`docs/rfc/`). This release implements RFC-0007 PR-1 only; PR-2 (`gh_result.t` structured result), PR-3 (typed `Api_get` / `Api_graphql_query`), and RFC-0008 `CredentialProvider` property are tracked for follow-up releases.

## [0.13.0] - 2026-04-24

### Added
- Keeper `always_approve` flag bypasses rule-based approval gates for non-destructive, non-critical tools. Destructive operations (shell, git, critical risk) remain blocked regardless of the flag.
- `goal_id` is now a required parameter in `masc_add_task` and `masc_batch_add_tasks`. Tasks without a goal_id can no longer be created, closing the goal-task orphanage gap.

### Changed
- Approval gate audit events now log `auto_approved_always` disposition when `always_approve` is enabled, with full keeper/task/goal context.

## [0.12.3] - 2026-04-21

### Added
- `config/keeper_runtime.toml` is now the supported human-authored runtime catalog
  source. When present, the runtime materializes sibling `config/runtime.json`
  on load and continues serving the existing JSON-backed runtime path without a
  consumer-facing schema change.

### Changed
- Keeper Phase C blocker classification now uses structured
  `masc_internal_error` variants for admission queue timeout, turn timeout,
  and ambiguous post-commit cases instead of relying on formatted-string
  matching across the worker and supervisor surfaces.
- `Otel_spans` now ships an explicit `.mli` interface that hides mutable
  internal refs and publishes the supported tracing API surface
  (`init`, exporter setup, `shutdown`, span helpers, and trace state accessors).
- TOML-backed runtime catalogs now fail closed: invalid `keeper_runtime.toml` blocks
  runtime resolution instead of silently falling back to stale generated JSON.
- Dashboard runtime surfaces now make the authoring/runtime split explicit.
  The runtime panel shows the active authoring source, raw `runtime.json`
  editing becomes read-only when TOML-backed, and keeper config surfaces now
  show both the selected `runtime_id` and the paths that control selection
  versus generated runtime catalog state.
- Regression coverage now locks the TOML materialization contract, resolver
  behavior for TOML-only config roots, dashboard raw-config read-only behavior,
  and keeper-config source/runtime provenance.

### Deprecated
- None.
## [0.12.2] - 2026-04-21

### Changed
- Keeper `gh` execution no longer falls back to a hardcoded repository or
  stderr text matching when the working directory is not itself a Git
  checkout. It now resolves repo context structurally from the current task's
  worktree git root and fails with a typed error when that context is missing.
- `require_tool_use` completion enforcement now latches across the full keeper
  run and only treats actual keeper-surface tool calls as satisfying the
  contract. A final optional turn can no longer mask an earlier tool-required
  turn that never used tools.
- Keeper sandbox option validation and docs now expose `docker_with_git`
  consistently, and the new regression tests cover task-derived GitHub repo
  context plus run-level tool contract enforcement.

## [0.12.1] - 2026-04-21

### Changed
- TBD

### Deprecated
- TBD

## Unreleased

### Changed

- **Running turns now yield to waiting connector conversations, and the
  dashboard no longer misreads a queued send as a dead stream (#25898).** A
  nonempty-wake turn's post-tool boundary probe chain gains a third probe:
  a pending ambient `Connector_attention` stimulus (a new Slack/Discord
  conversation message) now preempts the in-flight source turn at its next
  tool boundary, closing the same class of priority inversion #20849
  measured for owner messages. Pure decision exposed as
  `Keeper_unified_turn.connector_attention_preemption_request` and covered in
  `test_keeper_hitl_replay_delivery`. RFC-0441 states the policy.
- **Live chat sends poll the queued operation for liveness while waiting.**
  `sendKeeperThreadMessage` now marks the stream-liveness signal from the
  chat operation's `queued`/`running` state during the silent gap between
  `ACCEPTED` and the first reply event — the same evidence the hydrate path
  already used — so the composer's 15s stall hint no longer reads a
  healthily-working keeper as "스트림 지연" while the operator's message waits
  behind a running turn.
- **Strict required-tool contracts now use typed tool effects.** MASC passes
  an input-aware required-tool satisfaction predicate into agent_core, so passive
  observation tools such as `masc_status` and `keeper_tasks_list` no longer
  satisfy required productive action. The agent_core dependency floor is raised to
  `agent_sdk >= 0.171.0` for the new contract hook.
- **agent_core pin bump → `main@031c7e6b` (`v0.170.5`).**
  `the pin script` now tracks the merged agent_core truth-layer evidence
  primitives, and the dependency floor in `dune-project` / `masc.opam` is
  raised to `agent_sdk >= 0.170.5`. Keeper metrics now separate
  `raw_evidence_ref_count` from `violation_count`, so agent_core
  `evidence/effects.json` rows are treated as advisory effect-decision evidence
  instead of mode violations.
- **Keeper TOML key drift assertion restored.** The TOML unknown-key allowlist no
  longer whitelists retired nested tool-access fields unless the TOML profile
  parser actually consumes them, unblocking keeper test executable startup after
  the canonical/parsed key lists diverged.
- **agent_core pin bump → `main@8b5bf30a` (`v0.170.4`).**
  `the pin script` now tracks the merged agent_core Kimi CLI session
  reuse fix on upstream `main`, and the dependency floor in `dune-project` /
  `masc.opam` is raised to `agent_sdk >= 0.170.4`. Generated keeper agent_core
  pin docs are re-synced from the shared pin script so the declared base
  version, runtime SHA, and floor stay aligned.
- **agent_core pin refresh → `main@09a19698` (`v0.170.3`).**
  `the pin script` no longer tracks the deleted
  `fix/pipeline-message-constructor` branch. It now pins upstream agent_core `main`
  at the current reachable head while keeping the dependency floor at
  `agent_sdk >= 0.170.3`, because upstream `main` still advertises version
  `0.170.3`. The generated keeper agent_core pin docs are re-synced from the shared
  pin script so the declared track ref, SHA, and floor stay aligned.
- **Keeper sandbox profile collapsed to `Local | Docker` 2-mode.** The three
  external variants (`Legacy_local`, `Docker_hardened`, `Docker_with_git`) are
  replaced by two: `local` runs on the host with filesystem scoped to the
  keeper playground; `docker` runs in the hardened container. Git credential
  mounting is no longer a separate profile. Old
  profile strings are rejected instead of compat-mapped. See
  RFC-0006 §8 Addendum.
- **agent_core pin bump → `main@3dabe7a8` (`v0.164.0`).** `the pin script` now follows upstream `main` instead of the older retired runtime branch, and the dependency floor in `dune-project` / `masc.opam` is raised to `agent_sdk >= 0.164.0`. This matches the upstream version-boundary fix where current agent_core `main` advertises `0.164.0` after post-`0.163.0` public API growth, so downstream pin metadata no longer conflates branch head with the older `0.163.0` line.

### Added

- **CLI auto-model rotation for runtime specs.** `gemini_cli:auto` now
  expands into a quota-aware concrete Gemini CLI candidate list
  (Flash/Lite first, Pro last), and `codex_cli:auto` expands through a
  light-to-heavy supported Codex order from `gpt-5.2` up to `gpt-5.4`,
  including `gpt-5.4-mini` and `gpt-5.3-codex-spark`. The ChatGPT-backed
  Codex rotation now excludes `gpt-5.1-codex-mini`, `gpt-5.1-codex-max`, and
  `gpt-5.2-codex` after direct runtime probes returned 400
  unsupported-model errors; operators can still re-add them explicitly
  through `MASC_CODEX_CLI_AUTO_MODELS`.
  `claude_code:auto` remains single-entry by default but can be expanded via
  `MASC_CLAUDE_CODE_AUTO_MODELS`. This lets existing runtime
  failover/round-robin/cooldown machinery rotate CLI models without
  relying on interactive `/model` state.

- **Legendary Bash shadow-counter per-reason `too_complex_*`
  histogram.**  `Legendary_counters.snapshot` now includes fifteen
  new fields — one per `Parsed.reason_too_complex` variant plus
  dedicated `too_complex_parse_error`, `too_complex_parse_aborted`,
  and `too_complex_other` buckets.  The shadow-observer in
  `agent_tool_shell_runtime.ml` feeds the `parse_tag` string (e.g.
  `"too_complex:redirect"`) through the new
  `Legendary_counters.incr_too_complex_by_tag` routing table
  whenever `diff=Shadow_cannot_parse`; unknown tags collapse into
  `too_complex_other` so the histogram sum always equals
  `gate_diff_shadow_cannot_parse`.  Same zero-cost posture as the
  other counters — nothing increments until
  `MASC_BASH_AST_SHADOW_LOG` is on.  Exposed through the existing
  `/api/v1/legendary_bash/shadow_counters` endpoint (additive
  fields only, pre-existing consumers unaffected).  Six new unit
  tests (prefixed / bare / parse_error / parse_aborted / unknown /
  JSON shape).  `LEGENDARY-BASH-RUNBOOK.md` documents the new
  buckets and the A1-PR-N prioritisation recipe ("top-N buckets
  over observation window = next grammar expansion targets").

### Changed

- **TLA+ specs 이관 완결 (`tla/` → `specs/`).** 기존 top-level
  `tla/` 디렉토리에 남아 있던 3개 스펙을 `specs/` 서브디렉토리
  구조로 이동: `specs/task-lifecycle/TaskLifecycle.{tla,cfg,-buggy.cfg}`
  (#8960), `specs/checkpoint-trim/CheckpointTrim.{tla,cfg,-buggy.cfg}`
  (#9001), `specs/social-state-cap/SocialStateCap.{tla,cfg,-buggy.cfg}`
  (#9020). 이관 이유: (1) `specs/Makefile` 의 `find . -name '*.cfg'`
  auto-discovery 가 `specs/**` 하위만 탐색해 `tla/` 스펙은
  `make -C specs check-all` 에서 제외되었고, (2) `ci.yml` 의
  `tla-specs` job path filter (`^(specs/|lib/keeper/|lib/oas_.*\\.ml$
  |Makefile$)`) 도 `tla/` 변경을 무시해 TaskLifecycle 이 PR #8437
  merge 이후 로컬 only 로 남아 있었다. 이관 후 `scripts/tla-check.sh`
  의 legacy `tla/` 루프 제거 및 `.gitignore` 의 `tla/` 전용 패턴
  정리. `CheckpointTrim.cfg` / `-buggy.cfg` 에는 terminating spec
  (`pc: "trim" → "done"`) 의 default deadlock 오탐을 막기 위해
  `CHECK_DEADLOCK FALSE` 를 추가 — safety invariant 로만 검증.
  CI `TLA+ Model Checking` job 은 SocialStateCap 11,665 distinct
  states 포함 17 분 런타임에 pass.

### Added

- **Bash parser post-hoc `Too_complex` classifier (P5 parse-gap
  narrowing).**  `Masc_exec_bash_parser.Bash.parse_string` now
  post-processes lexer/grammar rejections through
  `classify_too_complex`, a substring scanner that upgrades the
  response from opaque `Parse_error` to a typed
  `Parsed.Too_complex reason` variant whenever the rejection is
  attributable to a subset-excluded bash feature.  Ordered
  multi-char markers first (`<<<`, `<<`, `>>`, `&&`, `||`, `$(`,
  `$((`, `<(`, `>(`), then single-char (`<`, `>`, `&`, `(`, `{`,
  etc.), first match wins.  New variant `Redirect` added to
  `Parsed.reason_too_complex` for `<`/`>`/`>>`; mapping added to
  `Worker_dev_tools.too_complex_reason_tag` → `"redirect"`.  Eleven
  new parser tests cover `Logic_op` (`&&`/`||`), `Redirect`,
  `Heredoc` (`<<`), `Here_string` (`<<<`), `Cmd_subst` (`` ` ``
  and `$(`), `Arith_expansion` (`$((`), `Background` (`&`),
  `Subshell` (`(…)`).  The existing
  `test_double_quote_with_backtick_rejected` now expects
  `Too_complex `Cmd_subst` — the substring scan is not
  quote-aware, and since anything reaching this arm has already
  been grammar-rejected the more specific tag is strictly better
  for the corpus-tap telemetry that drives future A1-PR-N grammar
  expansion priority decisions.

- **Legendary Bash `bg_tasks/<keeper>` HTTP endpoint.**  New
  `GET /api/v1/legendary_bash/bg_tasks/<keeper>` returns the
  per-keeper background task roster as
  `{"keeper": "<name>", "count": N, "tasks": ["<id>", …]}`.
  Wraps `Bg_task.list ~keeper` under the same public-read posture
  as `shadow_counters` (no auth on keeper identity, zero-cost when
  quiet).  Unknown / quiet keepers return `{"count": 0, "tasks":
  []}` — the endpoint mirrors the filesystem/PG lookup instead
  of gating on keeper existence, so a dashboard can poll liberally.
  Trailing-slash requests (`.../bg_tasks/`) return 400 with
  `"keeper name is required"`.  Three new route tests cover empty
  keeper, unusual-name echo (`my-keeper_01`), and stable
  `keeper → count → tasks` field ordering.
  `LEGENDARY-BASH-RUNBOOK.md` now documents the endpoint alongside
  the existing `shadow_counters` snapshot endpoint so dashboards
  and operator tooling have a single reference.

- **`Cdal_judge` jest / vitest classifier.**  `of_exec_outcome`
  now emits typed `Test_pass {count}` / `Test_fail {count}`
  markers for jest and vitest runner output in addition to dune,
  cargo, alcotest, pytest, and go test.  Detection anchors on the
  runner-specific summary banners — `Test Suites:` for jest,
  `Test Files ` for vitest — so bare prose or user-visible text
  mentioning "Tests" or "passed" cannot false-positive.  Count is
  extracted from the `Tests:` / `Tests` summary line by scanning
  for " passed" / " failed" and reading the int immediately
  before the tag.  This correctly handles vitest's pipe-delimited
  failure lines (`Tests  2 failed | 3 passed (5)` →
  `Test_fail {count=2}`).  Banner-required behaviour is covered
  by a dedicated negative test (`test_jest_vitest_banner_
  required`).  Verifier runtime now covers dune + cargo + pytest
  + go test + jest + vitest, bringing JavaScript-ecosystem
  runner output (ExampleOrg FE repos, most npm projects) into the
  same typed-marker surface the rest of the runtime consumes.

## [0.12.0] - 2026-04-20

### Added

- **Bash parser single-quote string support (P5 parse-gap step).**
  `lib/exec/parser/bash_lexer.mll` now recognises `'...'` literal
  strings and emits them as a single `WORD` token with the surrounding
  quotes stripped.  Lets the AST gate classify commands like
  `git commit -m 'my message'` or `echo 'foo | bar'` without falling
  back to `Shadow_cannot_parse`, narrowing the
  `gate_diff_legacy_allow_shadow_deny` / `..._shadow_allow` signal
  on the `MASC_BASH_AST_SHADOW_LOG` observer (feeds the
  `MASC_BASH_AST_ONLY` flip decision per RUNBOOK §P5).  Five new
  parser tests cover: basic quoted arg, empty `''`, multiple quoted
  args in one command, pipe-metachar-as-literal-payload, and the
  unterminated-quote negative.  No grammar change; no behaviour
  change on commands without single quotes.

- **Bash parser double-quote string support (P5 parse-gap step).**
  `lib/exec/parser/bash_lexer.mll` now recognises `"..."` double-
  quoted literals alongside unquoted `WORD` tokens.  The double-
  quote body is matched by `dq_body = [^ '"' '\n' '\\' '$' '`']*`
  and emitted as a single `WORD` with the surrounding quotes
  stripped, so shapes like `rg "error pattern"` /
  `git commit -m "some message"` / `echo "hello world"` round-trip
  as one `Shell_ir.Lit` element — spaces preserved, pipe metachar
  inside the body left literal.  Bash features that `"..."` would
  otherwise interpret (backslash escapes `\"`/`\\`, variable
  expansion `$FOO`, command substitution `` ` ``/`$(…)`, embedded
  newlines) are subset-excluded at the A1 layer: their presence in
  the body breaks the lex and surfaces as `Parse_error`, which is
  fail-closed for the subset gate.  The grammar is unchanged
  (`WORD` production already accepts the token in any argument
  position).  Follow-up PRs will add an unescape sub-rule for `\"`
  / `\\` / `\n` / `\$` to widen coverage.  Eight new parser tests
  cover the happy paths (basic literal, empty string, pipe
  metachar as literal, `rg "error pattern" src/`) and the four
  fail-closed negatives (`$FOO`, `\"` escapes, backtick subst,
  unterminated `"`).  19/19 parser tests green locally.  Narrows
  the `Shadow_cannot_parse` bucket emitted by the AST gate shadow
  observer, bringing the `MASC_BASH_AST_ONLY` flip criterion one
  step closer.

- **`Cdal_judge` go test classifier.**  `of_exec_outcome` now emits
  typed `Test_pass {count}` / `Test_fail {count}` markers for `go
  test` output in addition to dune, cargo, alcotest, and pytest.
  Detection anchors on the runner-specific `--- PASS:` / `--- FAIL:`
  / `=== RUN` prefaces so that bare `PASS` / `FAIL` tokens elsewhere
  in stdout (e.g. docstrings or user-visible prose) cannot
  false-positive. Count is obtained by counting `--- PASS:` /
  `--- FAIL:` occurrences — one per completed subtest. Banner-
  required behavior is covered by a dedicated negative test
  (`test_go_test_banner_required`). Verifier runtime now covers
  dune + cargo + pytest + go test.

- **Legendary Bash shadow-counters HTTP endpoint.**  New
  `GET /api/v1/legendary_bash/shadow_counters` returns the
  `Legendary_counters.snapshot` as JSON.  Public-read (same auth
  posture as `/api/v1/activity/*`), zero-cost when observers are
  off (all counters stay at zero).  Wired behind
  `Server_routes_http_routes_artifacts` in the route pipeline.
  `LEGENDARY-BASH-RUNBOOK.md` now documents the endpoint and the
  suggested `disagree_ratio` formula so operators can drive the
  `MASC_BASH_AST_ONLY` flip decision from a dashboard instead of a
  log grep pipeline.

- **Legendary Bash in-process shadow counters.**  New
  `lib/legendary_counters.{ml,mli}` exposes `Atomic.t`-backed totals
  for the P5 gate-diff observer (`total` + 4 buckets mirroring
  `Worker_dev_tools.gate_diff` 1:1) and the P4 auto-background
  observer (`observed` + `would_have_promoted`).  The counters are
  incremented from the same sites that already emit
  `gate_diff_shadow` / `auto_bg_would_have_promoted` log lines, so
  the cost remains zero whenever the matching observer env flag is
  off.  `snapshot_to_json` returns a stable field layout intended
  for a later dashboard / HTTP endpoint.  5 unit tests
  (`test_legendary_counters`).  No behavior change on the request
  path.

- **`Cdal_judge` pytest classifier.**  `of_exec_outcome` now emits
  typed `Test_pass` / `Test_fail` markers for pytest output in
  addition to dune, cargo, and alcotest.  Detection is anchored on
  the canonical `===== N passed in Ts =====` / `===== N failed`
  summary banner so that bare "N passed" prose elsewhere in stdout
  cannot false-positive.  Banner-required behavior is covered by a
  dedicated negative test
  (`test_pytest_banner_required`).  Lifts the verifier runtime out
  of OCaml-only coverage so Python-test keepers get the same typed
  marker stream as dune keepers.

- **KEEPER-USER-MANUAL §3.1.2 Legendary Bash 도구 표면.**  New
  subsection documents the three-tool surface (`keeper_bash`,
  `keeper_bash_output`, `keeper_bash_kill`) at the level a keeper
  operator reads: call-schema contract, single-command / no-chaining
  rule, the three flag-gated optional response fields
  (`return_code_interpretation`, `verifiable_markers`, promoted
  triple), and the background polling / tree-kill lifecycle.  Points
  operators at the existing `LEGENDARY-BASH-RUNBOOK.md` /
  `ENV-CONTRACT.md §4` as SSOT for flag matrices.  Adds both files
  to the manual's 관련 문서 appendix so new keeper operators land on
  the procedure docs.  No code change.

- **Legendary Bash operator runbook.**  New
  `docs/LEGENDARY-BASH-RUNBOOK.md` consolidates the P1–P6 rollout
  surface: current flag state table, authoritative opt-out tokens,
  dark-launch observer grep recipes for `gate_diff_shadow` and
  `auto_bg_would_have_promoted`, flip criteria for the remaining
  `AUTO_BG` / `AST_ONLY` defaults, and a restart-free rollback
  checklist.  `ENV-CONTRACT.md §4` now cross-links to it.  No code
  change.

- **`MASC_BASH_AUTO_BG_OBSERVE` dark-launch observer.**  Companion
  to `AST_SHADOW_LOG` (#8902) covering the AUTO_BG rollout axis.
  When the flag is set every foreground-only `keeper_bash` run is
  timed, and if the elapsed duration would have tripped
  `MASC_BLOCKING_BUDGET_MS` (default 15 000 ms) the keeper emits
  `auto_bg_would_have_promoted keeper=… cmd_hash=… duration_ms=N
  budget_ms=M`.  Inert when `AUTO_BG` itself is already enabled.
  Evidence for the later `AUTO_BG` default-flip decision without
  any behavior change.

- **`MASC_BASH_AST_SHADOW_LOG` dark-launch observer.**  With the
  flag set to a truthy value every `keeper_bash` call runs
  `Worker_dev_tools.diff_command` side-by-side with the live regex
  gate and emits a structured log line
  (`gate_diff_shadow keeper=… cmd_hash=… diff=… legacy=… shadow=…`)
  for every non-`Agree` outcome.  Command strings are hashed to a
  12-hex MD5 prefix before logging so no raw shell fragments leak
  to the log stream.  Default off; behavior is unchanged when
  disabled.  This is the evidence-collection step before the
  `MASC_BASH_AST_ONLY` default flip, which still waits on an
  N=1000 zero-diff window per the plan.

### Changed

- **`MASC_BASH_VERIFIABLE_MARKERS` flipped to on by default.**
  Post-Legendary-Bash-P6 (#8721) rollout step paralleling the
  `SEMANTIC_EXIT` flip: every `keeper_bash` response now carries
  the `verifiable_markers` array (typed `Test_pass {count}`,
  `Build_ok`, `Lint_clean`, `Git_clean`, each with
  `Exact | Heuristic` confidence) when the heuristic matches.
  Empty-result callers are omitted, so consumers that don't parse
  the key remain byte-compatible.  Explicit opt-out: set the env
  to `0` / `false` / `no` / `off`.  The flag itself survives one
  more minor bump before removal.

- **`MASC_BASH_SEMANTIC_EXIT` flipped to on by default.** Post-
  Legendary-Bash-P1 (#8721) rollout step: every `keeper_bash`
  response now carries the typed `semantic_exit` variant and the
  `return_code_interpretation` hint without requiring an operator
  opt-in.  Fields are purely additive — no existing key is removed
  or renamed, so consumers that parse `status` directly are
  unaffected.  Explicit opt-out: set the env to `0` / `false` /
  `no` / `off`.  The flag itself survives one more minor bump to
  let downstream consumers confirm compatibility before removal.

### Added

- **`Docker_with_git` sandbox profile + git/gh per-command dispatch.** New `sandbox_profile = "docker_with_git"` keeps every `Docker_hardened` guard (cap-drop, no-new-privs, read-only rootfs, tmpfs, pids/memory limits, no nested runtimes) but adds `--network bridge` and read-only mounts for `~/.config/gh`, `~/.gitconfig`, optionally `~/.ssh` (opt-in via `MASC_KEEPER_SANDBOX_SSH_DIR`). Optional `GH_TOKEN` env forward via `MASC_KEEPER_SANDBOX_GH_TOKEN`. A `Docker_hardened` keeper still gets git/gh access for free: `keeper_bash` automatically routes commands whose first token is `git` or `gh` through the new profile (toggle `MASC_KEEPER_SANDBOX_GIT_DISPATCH=false` to disable). Closes the gap that left coding keepers with `repo clone 차단: allowed org mismatch` board posts and 16 days of zero `keeper_bash` git activity.

- **Legendary Bash P1–P6 (`feature/legendary-bash-p1`, PR #8721).**
  Reworks `keeper_bash` along six aligned axes.  Every surface
  is additive and opt-in; the default JSON shape is unchanged.
  - **P1 — typed semantic exit.**  New `Exec_semantic` variant
    (`Ok / Fail / Timeout / Signaled / Git_not_a_repo / Oom_killed /
    Policy_denied / Tool_missing / Permission_denied`) with
    heuristic interpretation of exit codes 126/127/128 and dmesg
    OOM hints.  Gated by `MASC_BASH_SEMANTIC_EXIT`.
  - **P2 — background task lifecycle.**  `Bg_task.spawn/read/kill`
    plus `keeper_bash_output` / `keeper_bash_kill` mirror
    claude-code's `BashOutput` / `KillShell`.  pgid-owned children
    enable tree-kill; PID-file persistence
    (`<base>/.masc/keeper/<name>/bg/*.pid`) plus a startup
    `reap_orphans` hook recover stranded groups after restart.
  - **P3 — head+tail output cap.**  `Exec_buffer` keeps the first
    and last 500 KB of each stream in memory with an overlap-aware
    `bytes_dropped` counter.  Controlled by `MASC_BASH_OUTPUT_CAP`
    / `MASC_BASH_CAP_HEAD` / `MASC_BASH_CAP_TAIL`.
  - **P4 — auto-background race.**  `Exec_run.run_with_auto_bg`
    spawns a `Bg_task` and races its exit against
    `MASC_BLOCKING_BUDGET_MS` (default 15 000 ms) via
    `Eio.Fiber.first`.  Budget expiry returns `{promoted: true,
    background_task_id, partial_output, bytes_dropped, budget_ms,
    hint}`.  Gated by `MASC_BASH_AUTO_BG`; falls back to the
    blocking path when no Eio clock is available.
  - **P5 — AST-shadow safety layer.**  `Worker_dev_tools`
    classifies every `Eval_gate.destructive_patterns` entry into an
    8-arm `destructive_class` and runs the existing regex allowlist
    in parallel with the `Masc_exec_bash_parser` AST gate.  The
    legacy↔shadow diff harness (`test/test_gate_diff.ml`) pins the
    flip covenant: no `Eval_gate` pattern may slip into
    `Legacy_deny_shadow_allow`.
  - **P6 — verifiable markers.**  `Cdal_judge.of_exec_outcome`
    translates `(semantic, stdout, stderr)` into a typed marker
    list (`Test_pass {count}`, `Build_ok`, `Lint_clean`,
    `Git_clean`, …) with `Exact | Heuristic` confidence, so the
    verifier runtime can consume structured proofs instead of regex
    scraping.  Emitted when `MASC_BASH_VERIFIABLE_MARKERS` is set.

  All six phases land behind flags so operators can soak each axis
  independently before default flip.  See
  `docs/ENV-CONTRACT.md §4` for the flag matrix.

### Changed

- **agent_core pin bump → `main@36490371` (v0.163.0).** Single-commit upstream bump for `pipeline: handle Nudge decision in before_turn`. Without this, `before_turn` hooks returning `Hooks.Nudge` were silently dropped by `pipeline.ml stage_input` (`_ -> ()` fall-through). Effect on masc: the work-discovery nudge wired in PR #8805 (1089-char Samchon schema text) now actually reaches the LLM. 3 SSOT axes bumped per `feedback_oas-pin-must-bump-version-floor`: `the pin script`, `dune-project`, `masc.opam`. Generated docs re-synced via `scripts/sync-agent-core-pin-docs.sh`. Live verification: post-deploy, `keeper:<name> before_turn: injecting work_discovery nudge` log lines should be followed by `tool_call` events from the same keeper (currently 10 fires + 0 follow-up actions over the live server's 2 hour uptime).

- **agent_core pin bump → `main@2798831c` (v0.162.0 + 7 follow-ups).** Carries
  upstream agent_core commits since the last `54f4aeab` pin:
  - `2798831c` #1035 — `fix(hooks): emit OnError on tool-not-found
    dispatch failure (#1032)`. Surfaces a previously-silent dispatch
    failure mode through the existing `Hooks.OnError` channel; useful
    for keeper observability when LLMs hallucinate tool names.
  - `2a9a8756` #1061 — batch register 15 orphan test executables (agent_core
    internal coverage; no surface change).
  - `e1578747` #1045 — refactor: split runtime control and memory
    backend helpers (internal split, public modules unchanged).
  - `4d7b8489` #1043 — refactor: split context reducer helpers
    (internal split, `Context` API unchanged).
  - `98a13ab5` #1041 — refactor(checkpoint): split codec and delta
    helpers (internal split, `Checkpoint` API unchanged).
  - `8a5abf2e` #1060 — register orphan `test_memory_advanced` (agent_core
    internal coverage).
  - `d2b81773` #1059 — `build(dune): bump lang 3.11 → 3.22 to match
    toolchain` (agent_core-side dune version, opaque to consumers).

  Dependency floor and declared base version remain `0.162.0`.

## [0.11.0] - 2026-04-20

### Added

- **Tool-failure root-cause sweep (#8688, RFC #8760).** Server-authored
  hints now have Good/Bad examples for the top rejection classes and
  the Keeper prompt documents how to consume them. Observability
  script `scripts/sweep-tool-error-signatures.sh` (#8767) buckets daily
  `tool_calls/*.jsonl` failures by normalized signature so the impact
  of prompt changes is measurable. Shipped:
  - `agent_tool_shell_runtime` — raise gh op timeout floor 5s → 15s (#8712),
    hint on gh `Could not resolve to a Repository` from playground cwd
    (#8734), Good:/Bad: examples for 5 readonly-shell categories
    (#8704).
  - `keeper.capabilities` — tool error grammar (envelope / hint field /
    same-turn retry / judgment escalation) replaces the weak
    "do not retry" one-liner (#8775 / RFC R1).
  - `worker_dev_tools` — Chain_or_redirect and Injection hints name
    the `cwd=` argument explicitly so `cd X && Y` stops being the
    default suggestion (#8783).
  - `keeper_alerting_path` — `path_not_in_allowed_paths` suggests the
    concrete playground prefix when the raw path starts with `repos/`
    or `mind/` (#8789).
  - `tool_task` — completion-rejection message embeds a concrete
    accepted-notes example (#8708).
  - `anti_rationalization` — empty evaluator response routes to
    liveness approval instead of hard rejection (#8722).
- **Runtime event listener (pilot).** `feat(runtime_events)` (#8792)
  installs an OCaml `Runtime_events` listener and reserves event handles
  for MASC turn / tool-call observability (Wave 2A pilot).
- **Streamable HTTP atomic race fix (pilot).** `session.last_seen`
  marked `[@atomic]` to remove an unlocked race in the streamable HTTP
  transport (#8790, Wave 2 pilot).
- **CDAL attribution on verification legs.** Approve/reject verification
  transitions now record attribution so the post-hoc CDAL timeline
  includes who verified (#8731).
- **Verifier role gating for `task_verify`.** Affordance is now gated
  to verifier-role keepers (#8715). Default keeper set excludes the
  verification approvers from ordinary work claim queues.
- **Multi-assignment current binding semantics.** Task assignments can
  now express the current active binding vs historical ones; surfaced
  in `masc_check` and downstream accountability paths (#8776).
- **Keeper msg observability.** Usage / cost / cache-token counters and
  the raw model id are surfaced on `keeper_msg` MCP responses so clients
  and dashboards can attribute cost per keeper turn (#8717).

### Changed

- **FD leak SSOT (#8538 Tier 2).** PR #8543 이 3 hot-path call site 에 inline
  try/with 으로 pipe fd leak 을 막았지만, 같은 패턴을 여러 곳에서 재유도하면
  drift 가 발생한다. 공통 combinator `With_process.with_process_in` /
  `with_process_args_in` 을 `lib/process/with_process.ml` 에 추출하고
  `diagnostic_dispatch.ml`, `server_routes_http_routes_dashboard.ml`,
  `worktree_live_context.ml` 세 site 를 SSOT 에 귀속시켜 drift vector 제거.
  `test/test_with_process_coverage.ml` 이 error path 별 fd 회수와 100-iter
  stress 를 검증한다. `Fun.protect` 대신 수동 try/with 을 선택한 근거:
  finally 에서 던져진 예외가 `Fun.Finally_raised` 로 랩핑돼 `Eio.Cancel.Cancelled`
  의 구조적 취소 정보를 가릴 수 있음 (OCaml stdlib `Fun.protect` spec).
  후속: `Eio.Process.parse_out` 기반 Tier 3 이관 (follow-up Issue).

## [0.10.1] - 2026-04-19

### Changed

- **agent_core pin bump → `v0.160.1`.** `agent_sdk` floor raised from `0.160.0`
  to `0.160.1` (dune-project + masc.opam + pin script SHA
  `f70fd95e79bbe5f53ddd6687d3438e39f7b2c59f`). Picks up agent_core #1001's
  `completion_contract` fix: `validate_response` now accepts no-ToolUse
  responses when `stop_reason` is `MaxTokens` or `Unknown "pause_turn"`
  (resumable), unblocking Haiku 4.5 vendor_mix_balanced runtimes that
  exhaust the 8192-token output budget during extended thinking before a
  ToolUse block emits. `EndTurn` / `StopToolUse` / `StopSequence` /
  other `Unknown` reasons continue to reject no-ToolUse responses.

### Context

Observed empirically via `~/me/.masc/logs/system_log_2026-04-18.jsonl`:
104 `Completion contract [require_tool_use] violated` entries in a single
day, with +12 new violations accumulating in the 25 minutes between
observation and fix — silent cost of the pre-fix contract shape.

## [0.10.0] - 2026-04-18

### Changed

- **Verification surface — advisory CDAL attribution + verifier keeper
  signal + Kanban visibility + TLA+ bug-model.** Responds to the
  "검증 흔적이 UI에서 안 보인다" feedback by making every hop of the
  verification pipeline observable.
  - CDAL gate records an attribution entry for advisory (strict=false)
    contracts instead of silently skipping the lookup (#8402).
  - `Keeper_unified_turn.is_verifier_role_keeper` predicate plus
    `observation.verifier_role_keeper` field on every decision record
    let the dashboard pick verification-authority keepers out of the
    fleet (#8422).
  - Kanban adds a "검증 대기" column (store bucket +
    `TaskBacklog` wiring + card pill) so `awaiting_verification`
    tasks stop disappearing into the Done column (#8424).
  - `tla/TaskLifecycle.tla` bug-model: `DoneRequiresApproval`
    invariant is verified on the clean cfg (5 states, exit 0) and
    violated on the buggy cfg (exit 12), confirming the contract
    that Done is reachable only after Approve_verification (#8437,
    draft).

- **Dashboard design-system migration.** Multi-wave sweep of raw Tailwind
  color utilities to semantic CSS var tokens (`var(--ok)`, `var(--warn)`,
  `var(--bad-light)`, `var(--accent)`) across ~50 files.
  - Severity hues (emerald/rose/amber/red) collapsed to `--ok`/`--bad-light`/`--warn`
    (#8271, #8273, #8278, #8279, #8283, #8286).
  - Working hues (sky/blue/violet/...) folded into `--accent` (#8284).
  - Orange/lime sweep (#8285). Neutral-gray (zinc/gray/neutral/stone)
    collapsed to `--text-muted`/`--white-*` (#8281).
  - Final high-shade/extreme variants cleanup (#8288).
  - Paper-theme bridges `--accent`/`--ok`/`--warn`/`--bad` (#8290).
  - Text size hygiene sweep `text-[9px]` → `text-[10px]` (97 instances /
    29 files, #8260).
  - Radius tokens absorb `rounded-[3px]`/`rounded-[18px]` drift (#8291).
  - Sharp corners sweep `rounded-{xl,2xl,3xl}` → `rounded` (#8292).
  - Flat shadows (`shadow-{md,lg,xl,2xl}` → `shadow-sm`) (#8299).

- **Keeper — critical-path + lifecycle fixes.**
  - Surface unified turn critical path failures (#8265).
  - Consume overflow event-bus signal (#8251).
  - Honour declared `max_checkpoint_messages` default on create (#8256).
  - Synchronous `is_registered` check after `start_keepalive` (#8247).
  - Tool-policy validator recognises admin-dispatched keeper tools (#8241).
  - `workspace_gc` quarantines broken agent files instead of deleting (#8253).
  - `keeper_tool_affinity.configured_max_k`/`lookback_days` treat empty
    or whitespace-only env values as unset; optional `?getenv` injection
    seam for tests (#8190).

- **Runtime + verification.**
  - Hard-quota-aware immediate cooldown in runtime (#8249).
  - `/api/v1/runtime/health` exposes `hard_quota_cooldown_sec` (#8277).
  - Verification-protocol warns on missing-contract submit (#8276).
  - Verification-panel exposes `task_title` + pending-0 hint (#8259).
  - Dashboard surfaces live `pending_ruling` count instead of hardcoded 0 (#8268).

- **Dashboard runtime + auth.**
  - Auto-provision shared loopback dev token for `/mcp` (#8258).
  - Runtime-panel uses `CollapsibleSection` instead of raw `<details>` (#8275).
  - Ring buffer replaces `spread+slice` for hot-path signals (#8269).
  - Buffer sizes Vite-env overridable (#8270).

- **Sidecar + bridges.**
  - Sidecar honours configured runtime paths (#8267).
  - `oas_sse_bridge` surfaces `keeper_name` on envelope `agent_name` (#8261).

- **agent_core pin bump → `v0.160.1`.** `agent_sdk` floor raised from `0.159.0`
  to `0.160.1` (dune-project + masc.opam + pin script SHA
  `43527e8095f2f0c35aa84853d941025a0031aea0`). Keeps the event-bus
  backpressure-policy API (`Block` / `Drop_oldest` / `Drop_newest`),
  per-subscription + per-bus stats, and `subscribe ?purpose` labels from
  agent_core #998, and now tracks agent_core PR #1004 where the deprecated

- **Keeper `[keeper.oas_env]` TOML table.** Per-keeper agent_core transport env
  vars are now declarative. `config/keepers/<name>.toml` accepts a new
  `[keeper.oas_env]` table whose entries are applied via `Unix.putenv`
  at turn start, right before any agent_core call. Keys must match
  current agent_core env naming — anything else is silently dropped
  to block ambient env injection (e.g. a `PATH=/evil/bin` entry in a
  TOML cannot reach the process). Bool / int TOML values coerce to
  strings (`true` → `"1"`, `false` → `"0"`) so the agent_core transport
  build_args side reads them uniformly.
  - Built-in keepers no longer inject transport-specific agent_core env defaults.
    MCP / approval policy now lives at the agent_core transport/config boundary,
    keeping keeper behavior deterministic without stale provider aliases.
  - `merge_keeper_profile_defaults` merges `oas_env` key-by-key: a
    keeper-level base survives where the keeper TOML overlay doesn't
    override.
  - 5 new inline tests in `test_keeper_toml.ml` cover allowed / dropped
    / absent / bool-coerced / unknown-keys-whitelist paths.

- **Tool-task schema.**
  - `handoff_context.summary` declared required; runtime error surfaces
    example payload (#8293).
  - Ignore underscore-prefixed internal markers in transition schema (#8289).

### Deprecated
- None.

## [0.9.13] - 2026-04-17

### Changed

- **Dashboard — form control whitelists + new semantic components.**
  - `Select` prop whitelist expanded (id/name/aria/required/blur/testId) + tests 0 → 14 (#8007).
  - `TimeAgo` renders as semantic `<time>` with `aria-label` + `mode` prop + tests 0 → 19 (#8011).
- **Dashboard — highlight-on-match helper wired into 2 panels** (#8012).
- **Keeper — team memory scope enforcement** [codex] (#8016). Keeper team-memory writes now fail closed when the keeper does not own the scope.
- **CI — lib_option_get baseline naturalized 0 → 3** after the lockfree cache refactor in #7953 exposed 3 legitimate call sites (#8022).
- **Docs/design — CDAL PHASE1A rename.** `cdal_eval` references renamed to `cdal_eval_v1`; successor modules clarified (#8020).

### Deprecated
- **Spec sync — board + testing dead refs retired (#8008).**
  - `docs/spec/11-board.md` Maps-to row: dropped `lib/tool_vote.ml` and
    `lib/tool_social.ml` (both folded into `lib/tool_board.ml` per that
    file's own `Replaces tool_social.ml for new installations` header);
    corrected sub-library path `lib/board/` → `lib/board_types/`.
  - `docs/spec/15-testing.md`: §5.3 Anti-Fake and §5.6 Keeper Contract
    collapsed into RETIRED paragraphs (`lib/anti_fake.ml`,
    `lib/keeper/keeper_contract.ml` purged — 0 grep hits each).
  - §5.5 Keeper Verifier rewritten to describe the 3-way successor
    split: `lib/verifier_core.ml` + `lib/verifier_oas.ml` +
    `lib/keeper/keeper_guards.ml` (`lib/keeper/keeper_verifier.ml`
    removed in #2589). Maps-to row adjusted accordingly.
  - Net: 47 lines of stale catalogs removed, 17 lines of retirement
    records + successor pointers added.

## [0.9.12] - 2026-04-17

### Changed

Dashboard prop-whitelist expansion batch + structural cleanup. Autocoder-
driven increments on top of the 0.9.11 release.

- **Dashboard — form control prop whitelists.**
  - `Checkbox` prop whitelist expanded (id/name/aria/value/testId) + tests 0 → 13 (#8000).
  - `NumberInput` prop whitelist expanded (id/name/aria/autocomplete/keyboard/blur/testId) + tests 0 → 15 (#8005).

- **Dashboard — copy affordance.**
  - `CopyIdButton` placed next to truncated `trace_id` displays (#8001).

- **Dashboard — connector/keeper views.**
  - K×M `ConnectorKeeperMatrix` added under all-connectors view (#8002).

- **Dashboard — cleanup / clarity.**
  - Retired `runtime-params` / `param-audit` state cluster purged (#8003).
  - `'runtime'` label overload disambiguated; card titles made KO-only (#8004).

### Deprecated

- None.

## [0.9.11] - 2026-04-17

### Changed

Post-0.9.10 bulk merge cycle (admin override). Corrects the four entries
(#7981, #7982, #7985, #7986) that landed *after* the v0.9.10 tag commit
(`9820decae`) and were incorrectly attributed to 0.9.10 in #7994 — they
belong to this release.

- **Dashboard UX.**
  - Runtime Profiles + Keeper Mapping merged into one Runtime Routing card (#7986).
  - Visible toast cap at 5 + test coverage 0 → 9 (#7985).
  - Text filter on harness-health compaction/handoff lists (#7981).
  - Text filter on agent-detail owned-tasks + histories (#7982).
  - `CopyIdButton` wired into keeper-detail prompt fingerprint displays (#7989).
  - `ActionButton` prop whitelist expanded (aria-busy/id/title/testId) + tests 0 → 16 (#7995).
  - `TextInput` / `TextArea` now forward `id` — fixes orphan `<label for>` a11y regression (#7987).

- **Keeper / runtime / server.**
  - Raw `runtime_id` preserved on keeper side; canonicalization pushed to point-of-use (#7978).
  - `Accept_rejected` split from success in runtime evaluator; added `evict_idle` + `rejected_in_window` metrics (#7996).

- **Performance.**
  - Autoresearch pagination: in-memory mtime cache removes O(N) file I/O bottleneck (#7988).

- **Dead code / cleanup.**
  - Dead `mission-cards` barrel removed (no importers, `SummaryStat` unreferenced) (#7991).

- **Spec / docs / tooling.**
  - RFC-0004: OCaml ↔ TS shared contract (SSE + gRPC-web) (#7999).
  - Spec §7/§8/§10 type sections retired (checkpoint / context_budget / message_schema purged) (#7997).
  - Capsule Execution Plan Slices A–C marked historical (team_session retired) (#7984).
  - agent_core pin bumped to `0.155.1` + compat fixes (#7993).
  - CHANGELOG `[0.9.10]` TBD placeholders filled (#7994).
  - `.tmp/` scratch directory added to `.gitignore` (#7998).

### Deprecated

- **Capsule Execution Plan slices marked historical (#7984).**
  `docs/design/masc-capsule-execution-plan.md` Slices A–C targeted the retired
  `team_session` subsystem (9 dead `lib/team_session/*` and
  `lib/tool_team_session_*` module refs). Slices preserved as migration context
  for future `board_posts` + keeper-FSM workspace collaboration work. Product Thesis,
  Boundary Rules, Execution Order, Social Runtime Invariants, and Review Gate
  sections remain the current design stance.

## [0.9.10] - 2026-04-17

### Changed

Bulk merge cycle (2 `/loop` batches, admin override) covering dashboard UX, keeper observability, lock-free refactors, and spec/docs cleanup.

- **Dashboard UX.**
  - Connector overview strip gains an incident banner for sidecars dropped in the last 5 min (#7925) and an aggregate summary line (#7944).
  - Auto-restart toggle chains Save → stop → start on connector config (#7933).
  - Quick-bind form supports Enter-to-submit with per-connector channel ID hint (#7970).
  - Setup guide gains per-step completion checklist (#7974) and Vercel-style Start button on onboarding cards (#7963).
  - Copy affordance: new `CopyIdButton` on transport-health hot session ids (#7973) with inline "Copied" confirmation (#7980).
  - Live-ticking counter on startup-warning banner (#7967).
  - Text filters added to mission worker-runs evidence list (#7975) and runtime-monitor model-id/tool-name search (#7957).
  - Keyboard shortcuts for connector navigation (1–4, ?) (#7958).
  - Keeper modal KPIs regrouped into 4 question-led sections (#7946).
  - Live Judge promoted to page title; empty toolbar card purged (#7969).
  - AA accessibility pass on connector readiness rail (#7960).
  - Zod parse boundary for SSE events (#7955).
  - Outcomes rollup added to keeper JSON response (#7941).
  - Autoresearch loops API + list UI gain pagination (#7861).

- **Keeper / server / lib.**
  - Keeper behavioral regime deriver MVP (7th FSM axis: Crashing/Thrashing/Healthy) (#7968).
  - HTTP transport session/conn registries: global mutexes eliminated via lock-free atomic maps (#7979).
  - Dashboard cache global mutex eliminated via lock-free atomic map (#7953).
  - New `Lockfree_atomic` helper module extracted for reuse (#7952).
  - `bash exec` substrate semantics hardened (#7891).
  - Board flusher actor started with jsonl backend (#7915).
  - Autoresearch: exception-throwing serde helpers removed (#7942).
  - Dashboard: unexport internal-only helpers across 2 component files (#7977).
  - Dead cluster removal: `governance-panels/detail/strips` (follow-up #7927) (#7962), 3 orphan components (mission, connector-binding-summary, execution/shared) (#7938), orphan `keeper_handoff_delta` module (#7948).

- **Spec / docs / tooling.**
  - TLA+: `KeeperConditionsGovernPhase` liveness spec + clean/buggy cfg pair (#7965).
  - Spec §2 module table + §17 references synced with `lib/workspace/` (workspace → workspace rename) (#7954).
  - Comprehensive glossary sync: Chain/CP/agent_ecosystem/context_budget retired (#7964).
  - Keeper spec §05 synced with current keeper module layout (#7972).
  - Dead `code_refs` dropped (`sdk_version.ml`, `agent_ecosystem`, `message_schema`); §6 retired (#7945).
  - Retired CP/MDAL dropped from `DASHBOARD-INTEGRATION`; self-contradicting `BENCHMARK-RUNBOOK` note fixed (#7943).
  - Runtime gate for frontmatter `code_refs` existence (#7966).
  - agent_core pin bumped to `cb4beb52` (PR-O2 pipeline → `Complete.complete`) (#7956).
  - `agent-core-pin` orphan SHA `6c79cf3f` replaced with ref-reachable `f2387e2a` (#7898).

### Deprecated

- None.

## [0.9.9] - 2026-04-17

### Changed

- **README facts aligned with code (PR #7730).**
  - agent_core pin floor in badge + Tech Stack: `0.118.2` → `0.153.0` (matches `masc.opam` and `dune-project`).
  - Keeper lifecycle diagram corrected from "11-state" to the actual **12 states** in `lib/keeper/keeper_state_machine.mli` (`Overflowed` was missing).
  - WebRTC signaling endpoints made precise: `POST /webrtc/offer`, `POST /webrtc/answer`, gated by `Server_webrtc_transport.is_enabled`.
  - Keeperl-project disclaimer added (Korean + English) at the top.
  - "Production surface" framing replaced with surface-map vocabulary that doesn't imply external SLA.
- **Root scratch removed (PR #7744).**
  - `git rm` on 9 tracked one-off files: `pr-payload.json`, `pr6975.json`, `pr_body_tmp.txt`, `test-integration-{retry,verify}.txt`, `test_portal_lock_stress.ml` (no rg refs in `lib/bin/test/scripts`), `EIO_REFACTOR_ISSUES.md`, `AGENTS.md` (CLAUDE.md is the live SSOT), `session_tracker_qa_tests.md`.
  - `.gitignore` extended with `pr-*.json`, `pr_body_*.txt`, `test-integration-*.txt` so future drops are ignored automatically.
- **Audit tracker added (PR #7749).** `docs/_audit/2026-04-17-doc-classification.md` classifies all 145 markdown files in `docs/` into A·Live (81) / B·Historical (46) / C·Hype (7) / D·Duplicate (11), with grep evidence and disposition per file. Tracker only — actual delete / archive / merge / frontmatter PRs are sequenced separately.

No code changes. Bump captures the documentation/hygiene cycle as a tagged release boundary.

## [0.9.8] - 2026-04-17

### Changed
- **agent_core pin bump to `v0.153.0`** — picks up agent_core PR #975
  (`Budget_strategy.default_summarizer` exported in the `.mli`).
- **`keeper_summarizer.ml` simplified** — deletes the local
  `default_extractive_summary` re-implementation and delegates to
  `Agent_sdk.Budget_strategy.default_summarizer` directly. This was
  the follow-up promised in PR #7668 (Gen4 compaction-layer structured-state
  scrub). Net diff: −36 lines; behavior unchanged (4 existing tests
  in `test_keeper_summarizer.ml` still pass).
- `the pin script` BASE/SHA/MIN → `v0.153.0` /
  `485ac29af8c14942e29c99381a9946c7000a55c9` / `0.153.0`.

## [0.9.7] - 2026-04-17

### Changed
- **agent_core pin bump to `v0.152.0`** — raises the `agent_sdk` floor in
  `dune-project` and updates the helper constants in
  `the pin script` (BASE_VERSION, SHA, MIN_VERSION) to
  `d5d92f38f6490b924238b5a176a9feb6e79d17e3`.
  - Picks up agent_core PR #973 (`Agent.options.summarizer` +
    `Builder.with_summarizer`): downstream consumers can now inject a
    custom summarizer callback into `Budget_strategy.reduce_for_budget`
    via the options record instead of falling through to
    `default_summarizer`.
  - Also picks up agent_core PR #962 (Anthropic `cache_extended_ttl`), included
    transitively via the 0.151.0 release.
  - No runtime behavior change in masc itself: this is a pin-only
  bump. Registering a structured-state-aware summarizer is the follow-up step
    and ships separately.

## [0.9.6] - 2026-04-16

### Fixed
- **Keeper continuity resonance loop** (PR #7612, #7615, #7618) — closes the
  save/read asymmetry that caused keepers to echo their own prior structured
  narrative every turn.
  - `keeper_world_observation.ml:read_continuity_summary` now prefers the
    structured snapshot stored in `Checkpoint.working_context` over
    re-parsing model-authored state blocks from message bodies (PR #7612). Completes
    the RFC-MASC-001 Phase 1 read side; the save side already wrote
    structured JSON when enabled.
  - `scripts/retro-clean-keeper-continuity.sh` one-shot: dry-run default,
    `--apply` backs up and zeroes stale `continuity_summary` fields across
    `.masc/keepers/*.json`. Preserves all other fields (PR #7615).

### Changed
- **`MASC_STRUCTURED_STATE` default flipped to `true`** (PR #7618) —
  completes RFC-MASC-001 Phase 1 rollout. The structured
  `Checkpoint.working_context` save path is now active by default;
  combined with PR #7612 every keeper turn writes a typed snapshot and
  reads it back on the next turn instead of re-parsing model-authored state text.
  Accepted opt-out values: `false`, `0`, `no`. Legacy text-state
  fallback is preserved for checkpoints without `working_context`.

## [0.9.5] - 2026-04-16

### Added
- **CDAL Verdict Gate** (PR #7531, env `MASC_CDAL_GATE_ENABLED`, default off) —
  `cdal_verdict_gate.ml` blocks task completion when CDAL verdict is Violated
  or Inconclusive with blocking gaps. Reads persisted verdicts with task_id
  filtering via typed `persisted_verdict` envelope.
- **Task verification FSM** (PR #7531, env `MASC_VERIFICATION_FSM_ENABLED`,
  default off) — new `AwaitingVerification` task_status + 3 actions
  (`submit_for_verification`, `approve`, `reject`). Cross-agent enforcement
  (worker ≠ verifier). Contract-driven deadline and required role.
- **Verification protocol** (`verification_protocol.ml`) — board post + SSE
  event emission on submit/approve/reject/timeout. Updates
  `Verification.ml` state machine on cross-agent verdicts.
- **Keeper-as-verifier** — `pending_verification_count` in
  `world_observation`; keepers can observe and act on verification requests
  via `masc_transition(action=approve|reject)`.
- **Typed evidence criterion** — `Types_core.evidence_criterion` ADT
  (Schema_match/Contains/Not_contains/Custom) replaces string list for
  `task_contract.verify_gate_evidence`. Backward compat reader.
- **Env-configurable knobs** —
  `MASC_CDAL_VERDICT_LOOKUP_LIMIT` (default 500),
  `MASC_VERIFICATION_TIMEOUT_CHECK_INTERVAL_SEC` (default 60.0).

### Changed
- verification_id now cryptographically random (128-bit CSPRNG via
  mirage-crypto). Previously used `Hashtbl.hash` + timestamp (weak).
- Dashboard shows `검증 대기` badge for `awaiting_verification` status
  (accent color, event icons).

### Deprecated
- Legacy `_task_id` string-prefix JSONL envelope still read but no longer
  written. Reader handles both formats.

## [Unreleased]

### Changed (specs)

- **`KeeperContextLifecycle.tla` completeness pass** — closes 3 of the
  gaps flagged by the 2026-04-16 compaction FSM/TLA+ audit
  (#7568 §1.4):
  - `CompactionFailed(k)` action added (documentation-only in the
    clean `Next` to avoid infinite retry without a bounded retry
    variable; exercised by `NextBuggy`). Models the
    `Compaction_failed` event at `keeper_state_machine.ml:383-389`
    that routes `compacting → overflow_retry` without clearing
    `context_overflow`.
  - `CompactionCompletesBuggy(k)` + `NextBuggy` + `SpecBuggy` —
    new Bug Model variant that reallocates `context_id` during
    compaction (models a broken Context.t identity path).
  - `CheckpointConsistency` strengthened: previously a duplicate of
    `TurnMonotonicity` (`ckpt_turn <= turn + 1`); now verifies that
    `ckpt_ctx_id` references an allocated context_id
    (`0 < ckpt_ctx_id < next_ctx_id`). Strengthens formally-verified
    surface without weakening the turn-monotonicity check.

### Added (specs)

- `KeeperContextLifecycle-buggy.cfg` — Bug Model cfg that runs the
  deliberate `CompactionCompletesBuggy` variant. TLC finds
  `Invariant ResumeIdentity is violated` at 377 states / depth 6 /
  1s. Completes the Bug Model pattern coverage that was missing.
- `KeeperContextLifecycle-ci.cfg` — smaller-constant cfg for quick
  invariant validation in every CI build. Reserves the default cfg
  (5.6M+ states) for nightly/release runs. Liveness
  (`PROPERTIES`) intentionally omitted — see file header comment.

### Follow-ups (out of scope)

- Add a bounded retry-budget variable to model the
  `compact_retry_exhausted` latch → `Paused` routing, then include
  `CompactionFailed(k)` in the clean `Next` and re-add liveness to
  `KeeperContextLifecycle-ci.cfg`.
- Upgrade `TurnSucceeds` fairness from WF to SF so small-model
  liveness holds without growing the state space (exposed by
  `KeeperContextLifecycle-ci.cfg` during this work).

## [0.9.5] - 2026-04-16

### Added

- **Keeper compaction audit** (`lib/keeper/keeper_compact_audit.{ml,mli}`).
  New Event_bus subscriber that observes `ContextCompactStarted` and
  `ContextCompacted` payloads emitted by agent_core, synthesises a per-keeper
  `compaction_id` to correlate Start/Complete pairs, and appends
  structured JSONL rows to `.masc/data/harness-compact/YYYY-MM/DD.jsonl`.
  Rolling retention (default 14 days, override via
  `MASC_COMPACTION_AUDIT_RETENTION_DAYS`) prunes old day-files on every
  write — self-healing, no cron. No agent_core changes required; subscriber
  runs alongside existing `oas_sse_bridge` each on its own bounded
  stream.
- **Audit CLI** (`bin/masc_compaction_audit.ml`, installed as
  `masc-compaction-audit`). Options: `--since`, `--until`,
  `--keeper NAME`, `--orphans-only`, `--prune`, `--retention-days`.
  Pairs Start/Complete by `compaction_id`, emits human-readable summary,
  flags orphan rows (compaction that never completed, or server crash).
- **Compaction FSM/TLA+ audit** (`docs/audits/compaction-fsm-tla-audit-2026-04-16.md`,
  #7568). Traceability matrix for `KeeperContextLifecycle.tla` and
  `MemoryCompaction.tla` against 12-phase OCaml FSM. Confirms
  `Compaction_completed`/`Compaction_failed` handlers align with spec
  intent; reclassifies the `manual_reconcile_required` drift from prior
  audit as abstraction mismatch (live behaviour correct via PR #6834's
  separate event dispatch). Flags gaps: missing
  `KeeperContextLifecycle-buggy.cfg`, no `CompactionFailed` action in
  context spec, 3-of-5 gate abstractions.

## [0.9.4] - 2026-04-16

### Added

- **Runtime TOML config** for all 4 Python sidecars (#7509, #7518). Each
  sidecar reads an optional `$MASC_BASE_PATH/.gate/runtime/<kind>/config.toml`.
  File absent = field defaults only (zero-config works). Secrets stay in
  env vars. Priority: env > TOML > field default.
- **Shared bindings-store helpers** (`gate_shared/bindings_store.py`,
  #7501). `load_bindings` + `save_bindings` free functions replace 3x38
  duplicated lines across Slack/iMessage/Telegram sidecars.
- **Env-var aliases** for Slack + Telegram timeout/path config fields
  (#7506).
- **Runtime `weighted_entry.supports_tool_choice`** (#7493). Per-entry
  capability override parsed from runtime.json; `sangsu` profile's
  Ollama entry declares `"supports_tool_choice": true`.

### Changed

- **agent_core pin bumped to v0.150.0** (#7493). Removes
  `OAS_OLLAMA_SUPPORTS_TOOL_CHOICE` env var in favor of per-config
  `Provider_config.supports_tool_choice_override`.
- **Code quality pass** (#7516): trimmed 56 LOC of excessive comments +
  fixed 3 TOCTOU `Sys.file_exists` pre-checks in `read_json_file_opt`.

### Fixed

- Keeper: redirect `gh` to shell execution (#7474), demote
  semaphore_wait logs to INFO (#7472), add admin tools to Keeper_denied
  surface (#7455), hand off after overflow retry (#7435), accept both
  `pr_number` and `number` in the retired PR review helper (#7476).
- CI: pin `ocaml/setup-ocaml` to avoid upstream opam-binary regression
  (#7499).
- Dashboard: activity_graph events_shown vs events_store_total (#7502).
- Workspace: before-state snapshots in error path logging (#7512), unified
  transition log_event JSON (#7504), correlation_id/run_id on task
  activity (#7511).

## [0.9.3] - 2026-04-16

### Changed

- **Gate wire vocabulary migrated** from `keeper_name` to `destination_id`
  across a 4-phase rolling deprecation. The Gate library is en route to a
  standalone `gate-mcp` repo (Track B4); `keeper_name` carried
  MASC-specific language that didn't belong in a generic gate contract.
  Phases:
  - Phase 1 (#7482): `inbound_of_json` accepts either key (prefers
    `destination_id`).
  - Phase 2 (#7484): `outbound_to_json` emits both keys.
  - Phase 2b (#7485): sidecar `GateResponse.from_json` parses either
    key on the consumer side (single shared helper covers all four
    Python sidecars).
  - Phase 3 (#7487): `outbound_to_json` drops `keeper_name`; only
    `destination_id` emitted now.
  - Phase 4 (future major release): rename internal OCaml record field
    and inbound-only `keeper_name` parse as well.

### Migration note

Out-of-tree consumers that still read only the `keeper_name` key from
gate reply JSON now see `null`. Upgrade to read `destination_id`. The
transition window was Phase 2 → Phase 3 (both keys emitted); consumers
had the full Phase 2 release to migrate.

## [0.9.2] - 2026-04-16

### Changed

- **B3c Python sidecar migration complete**. All four Python sidecars
  (`discord-bot`, `imessage-bot`, `slack-bot`, `telegram-bot`) now
  default to `.gate/runtime/<kind>/*` and share the same 1-tier legacy
  read-fallback pattern. Pre-v0.9.0 `bindings.json` auto-discovered on
  first startup; next save writes to the new default (#7477 iMessage,
  #7478 Slack, #7479 Telegram). Discord already migrated in v0.9.1.

### Fixed

- **OCaml bootstrap no longer depends on upstream latest-opam auto-pick**.
  On 2026-04-16 the latest stable `opam 2.5.1` release was published
  before Linux x86_64 binaries were attached, so `ocaml/setup-ocaml`
  failed early with `Failed to find opam binary for 'linux' and 'x86_64'`.
  The shared toolchain bootstrap now downloads the published `opam 2.5.0`
  Linux binary directly and `release.yml`, `webrtc-live-interop.yml`, and
  `deploy-railway.yml` reuse the same local bootstrap.
  Closes #7475.

## [0.9.1] - 2026-04-16

### Changed

- **Gate runtime path migration**: default storage paths move from
  `.masc/connectors/<kind>/*` to `.gate/runtime/<kind>/*` for Discord
  (OCaml + Python sidecar) and iMessage (OCaml). The pre-v0.9.0 layout is
  demoted to `legacy_*_path` so existing deployments see a transparent
  read-fallback — next write lands at the new default (#7467, #7468, #7470).
- iMessage's OCaml `configured_read_path` gained a required `~legacy`
  parameter, matching the Discord resolver in
  `Channel_gate_discord_names`. Read priority: env var > new default (if
  file exists) > legacy (if file exists) > new default (stable for later
  creation) (#7468).
- Discord sidecar cleanup: the `LEGACY_BASE_ROOT = Path("sidecars/discord-bot")`
  constant and `_resolve_legacy_storage_path` helper were removed. They
  served a 2026-Q1 cwd-relative layout (`sidecars/discord-bot/.gate/discord_*`)
  that is no longer auto-discovered; deployments still on it must set
  `DISCORD_*_PATH` env vars explicitly (#7470).

### Deferred to v0.9.2

- iMessage, Slack, Telegram sidecar migrations (Python). These sidecars
  currently have **no read-fallback loop** in their `bot.py` entry, unlike
  Discord. Each needs a 1-tier fallback wired in before the `DEFAULT_*` →
  `LEGACY_*` rotation can safely ship.

## [0.9.0] - 2026-04-16

### Added

- **Dashboard UX**: density toggle (comfortable/compact) (#7377); Compound Graph
  toggle bound to `g` (#7398); tab anomaly indicator on selected keeper (#7383);
  manual refresh button + `r` shortcut (#7378); Watson-pattern inferred reason
  on transition trail (#7397); time-windowed observatory telemetry (#7390).
- **Keeper features**: social transition reasons exposed + cross-turn state
  (#7399, #7395); magentic ledger social model + TLA+ spec (#7426, #7430);
  campaign FSM harness (#7385); `sangsu` runtime profile — local-first Ollama +
  GLM fallback (#7404); pipe support in command execution (#7393).

### Changed

- **Discord connector dashboard is now keeper-first** (#7388). Each configured
  keeper has its own section with inline channel-binding management; bindings
  that reference a keeper not in the directory are surfaced under `⚠` instead
  of being silently dropped. Replaces the prior binding-first grouping that
  users reported as opaque across 5 distinct confusion points.
- **Gate library extraction**: pure Gate modules (`gate_protocol`,
  `channel_gate_connector`, `channel_gate_discord_*`, `channel_gate_imessage_*`,
  `channel_gate_metrics`, `gate_time_util`) moved to `lib/gate/` as the
  `masc_gate` sub-library (#7407 B1a). `channel_gate` facade joined the same
  sub-library after Pulse extraction (#7457 B1c). Call sites unchanged thanks
  to `wrapped false`. Prerequisite for the planned standalone `gate-mcp` repo.
- **Pulse library extraction** (#7452 B1b): the beat engine moved to
  `lib/pulse/` as the `masc_pulse` sub-library. Unblocks Gate's dependency on
  Pulse without routing the arrow back through `masc`.
- **agent_core pin → v0.148.0** (from v0.141.0) (#7394 + prior pins). Legacy runtime
  API removed from agent_core across v0.142.0–v0.148.0 — `Judge.judge` and
  `Tool_selector.default_rerank_fn` now take a single `Provider_config.t`, and
  `Runtime_executor` was deleted (839 LOC). Runtime orchestration is now
  entirely a MASC concern; `keeper_agent_run` resolves the runtime locally,
  picks the first healthy provider, and passes a single provider to the
  single-provider SDK. Falls back to `core+prefilter+discovered` on
  no-healthy-provider (same as before).
- **`Workspace` module retired** (#7355): split into `workspace_state.ml` + renamed
  remainder to `Workspace`.
- **Hashtbl → immutable StringMap/StringSet** across 14+ modules: `exec_memory`
  (#7414 #7416), `memory_bank` (#7429), `memory_recall` (#7421), `hooks_oas`
  (#7428), `tool_diversity` (#7425), `types_profile` (#7423), `rate_limit`
  (#7420), `cancellation` (#7419), `supervisor` (#7409 #7410), `context_core`
  (#7418), `exec_shared` (#7417), `tool_policy` (#7359), `agent_identity`
  (#7422), `streamable_http session storage` (#7427).
- Stringly-typed internal variants replaced with typed sums (#7347).
- `fail_fast_enabled` → `startup_abort_eligible` rename (#7415).

### Fixed

- Dashboard: 50-task hard cap removed (#7432); legacy composite payload
  normalized (#7412); duplicate cache timeout WARN in bg-revalidate (#7446);
  repeat shell cache timeout on workspaces with many board posts (#7402).
- Keeper: deduplicated tool_use_failure + cycle-failure WARN/ERROR
  (#7454, #7451); `gh` timeout floor + org allowlist in `validate_gh_command`
  (#7433); status tails sorted + continuity fallback marker (#7363); real-cause
  pointer when `rg` exits 2 (#7408).
- Log: normal keeper/JSON flows no longer WARN (#7444).
- Board: `masc_board_post` accepts `body` alias + auto-fills author (#7445);
  duplicate 100-post pagination cap removed (#7396).
- Checkpoint: malformed checkpoint detection logging in `load_latest` (#7413).

### Removed

- Retired PR submit helper + hardened `gh`/dashboard flows (#7389).
- 18 dead permission entries (#7434); dead tool references
- Dead `Blocked` variant from `turn_outcome` (#7346).
- Dead functions from `keeper_status_bridge` (#7403, #7406).

## [0.8.0] - 2026-04-15

### Changed
- **Tool registry pruning** (#7184): removed 65 dead tools with zero
  usage in April 2026 tool_usage logs. Deleted 5 entire subsystems
  (verify_*, auth_*, repair_loop_*, handover_*, heartbeat internals)
  as 19 source files + ~7,700 lines. Also pruned individual dead
  handlers, schemas, permission entries, and dispatch arms for 25+
  system-internal tools (agent eval, error tracking, lock/unlock,
  cancellation, subscription, progress, feature_flags, init,
  governance_set, set_workspace, etc.). keeper_denied surface was reduced to
  the remaining lifecycle controls. masc_heartbeat dispatch relocated
  from deleted tool_heartbeat.ml to tool_workspace.ml.

### Added
- Operator-facing context overflow recovery tools (#7115). Two new MCP
  tools paired with the `Overflowed` phase introduced in #7083:
  - `masc_keeper_compact`: dispatches `Operator_compact_requested` to the
    keeper FSM and runs checkpoint compaction via agent_core
    `recover_latest_checkpoint_for_overflow_retry`. Phase precondition is
    `Overflowed`/`Paused`/`Compacting`; `force=true` bypasses for
    `Running`/`Failing`.
  - `masc_keeper_clear`: last-resort context wipe. Loads the checkpoint,
    clears non-system messages (system prompt preserved by default), saves
    a new checkpoint, dispatches `Operator_clear_requested`. Requires an
    operator-provided `reason` for audit trail.
- retired scrape backend counters for the new operator tools:
  `masc_keeper_operator_compact_total{keeper,result}` (result ∈
  `ok|no_checkpoint|precondition`) and
  `masc_keeper_operator_clear_total{keeper,preserve_system}`.
- `checkpoint_found` field in the `masc_keeper_clear` response so
  operators can distinguish "no messages to clear" from "no checkpoint
  on disk".

### Fixed
- `masc_keeper_compact`/`masc_keeper_clear` now read/write checkpoints
  from `session_base_dir(config)` (`<masc_root>/.masc/traces`) instead
  of the incorrect `<base_path>/<keeper_name>`. Previous path would have
  made the tools always report missing checkpoints.
- When no valid checkpoint exists, `masc_keeper_compact` now dispatches
  `Compaction_failed` rather than `Compaction_completed { 0, 0 }`. The
  latter was a false-success signal that would clear `context_overflow`
  even though no compaction happened.

## [0.7.0] - 2026-04-14

### Added
- retired scrape backend metrics dashboard surface under monitoring tab (#6974). Fetches
  `/metrics`, parses retired scrape backend text format, renders 8 categorized tables
  (Server, Agent, Keeper, Transport, Inference, Tool, Delta, Provider).
- Clickable links from retired scrape backend labels: `keeper=` labels navigate to
  keeper detail, `tool_name=` labels navigate to tool-quality with
  highlight-and-scroll of the matching row (#7017).
- Agent + Transport metric categories — recategorize `masc_agent_*`,
  `masc_grpc_*`, `masc_ws_*` that previously fell into Other (#7017).
- RFC-0003 Keeper Composite Lifecycle docs + TLA+ spec with buggy variants
  (runtime, compaction, recovery) for regression-style verification (#7020).

### Fixed
- UTF-8 sanitization on outbound telemetry writers. `keeper_tool_call_log`
  and `oas_sse_bridge` now scrub invalid UTF-8 before persisting or
  broadcasting, eliminating ~12% JSONL row drop when tool output contains
  truncated multi-byte sequences (#6929).
- retired scrape backend histogram export format. `to_retired-scrape-backend_text()` now emits
  histograms as `summary` type with `_sum`/`_count` pair rather than the
  invalid `histogram` bare type, so retired scrape backend servers parse the metrics
  correctly (#6936).
- `tool_usage_log` syntax error at line 105 (`let counts = fold_left ...`
  missing `in`) that broke Build/Test, Health, and Lint CI (#6975).
  Complexity comment updated from O(1) to O(log n) to match StringSet.mem.

### Changed
- Concurrency hardening: serialize `keeper_recurring` tasks Hashtbl +
  atomic id counter (#7022), `sse event_buffer` Queue with Eio.Mutex
  (#7016), `tool_shard` agent_shards read-modify-write (#6985).
- Pin `agent_sdk` to 0.134.0 (#7012).
- CI `ci_core=true` no longer forces TLA+, saving ~14 min per run (#7024).
- Dashboard: remove unused config binding in `ordered_workspace_ids` (#7021).

## [0.6.0] - 2026-04-14

### Added
- Dashboard agent_core telemetry surface (#6978).
- `oas_sse_bridge` usage relay wiring (#6938).

### Changed
- Concurrency and observability fixes carried over from the 0.5.x line.

### Notes
- Version bumped in `dune-project` and `masc.opam` by #7009. This
  entry finalizes the release docs that were omitted in that bump, so
  `scripts/check-version-truth.sh` stops failing on every main-base PR.

## [0.5.11] - 2026-04-13

### Changed
- Replace all `Eio.traceln` in `lib/` with structured `Log` module
  calls (runtime_inference, autoresearch_codegen, dashboard judges,
  opentelemetry_client). Zero ad-hoc traceln calls remain.
- Add relay calibration drift metric: warn on correction_factor
  outside [0.5, 1.5], debug on shift > 0.1.

## [0.5.10] - 2026-04-13

### Added
- MASC-driven runtime FSM Phase 2: direct provider failover from MASC (#6776)
- Event_bus envelope API adoption: correlation_id + run_id metadata (#6777)
- Groq runtime fallback restored (#6566)
- agent_core log bridge to masc structured logging (#6618)
- Keeper runtime provider allowlist env knob (#6478)
- Cross-model enforcement rate on dashboard (#6565)
- Keeper FSM dashboard exposure + TLA+ bug model (#6556)
- retired scrape backend llm_provider_http_status metrics (#6514)

### Fixed
- agent_core pin v0.124.2: GLM auth passthrough (static_token) + intra-turn truncation (#6781, #6790)
- Runtime: add default_api_key_env for GLM providers (#6784)
- Admission queue: size to actual decode parallelism (#6768), passthrough mode (#6788)
- Keeper: context compaction in reducer (#6731), unified prompt CI alignment (#6700, #6783)
- Test: prevent integration tests from leaking real PRs to GitHub (#6756)
- Test: align admission queue default (#6785)
- Remove dead blocker_class_of_failure_reason (#6778)

### Refactored
- Spawn: add mcp_flag/prompt_flag types, replace match tables (#6767)
- Keeper: immutable string list for keeper_internal_set (#6761)

### Docs
- RFC-MASC-001 (checkpoint boundary migration), MASC-004 (memory bridge), MASC-005 (dashboard eval consumer) (#6787)

## [0.5.9] - 2026-04-12

### Added
- Harden agent_core telemetry visibility and proactive monitoring (#6679)

### Fixed
- Keeper: add keeper_board_delete + cleanup to boundary-exempt list (#6698)
- Lazy: replace Stdlib.Lazy with Eio.Lazy in keeper modules (#6696)
- Dashboard: externalize agent status thresholds (#6683)
- Prompt: restore world prompt contract and sanitize unified prompt (#6675)
- Prompt: reinforce playground containment in keeper capabilities (#6678)
- Re-raise Eio.Cancel.Cancelled in 5 catch-all handlers (#6697)
- CI: unblock Build and Test (#6699)

### Hardened
- Store cache: mutex-protect Dated_jsonl store caches (#6690)
- Agent registry: serialise session cache mutations (#6682)

### Performance
- Memory agent_core bridge: move episode JSONL load outside cache mutex (#6671)
- Prompt registry: move markdown disk reads outside registry mutex (#6663)

## [0.5.8] - 2026-04-12

### Fixed
- SSE: stop double-incrementing event_counter when ~id is passed (#6660)
- RNG: guard module-level Random.State with Eio.Mutex in 3 modules (#6652)
- Repair loop: gate working_dir on caller playground (#6651)
- Local runtime pool: drop dead select_runtime, re-check fingerprint after env load (#6650)
- Runtime: remove coding_first profile, cap max_tokens to 32768 (#6687)
- Runtime: clamp keeper_unified + coding_first max_tokens to 32768 (Groq limit) (#6686)
- Build identity: probe exe_dir before cwd for git commit (#6688)
- Keeper: masc_* boundary-exempt gap + runtime.json prune (#6681)
- Worker agent_core: stop sending min_p=0.0 to cloud providers (#6672)
- Keeper checkpoint store: classify Eio.Io Fs Not_found as Not_found (#6655)

### Changed
- Bump agent_core pin for GLM max_tokens clamp (#6689)
- Improve keeper timeout visibility (#6552)

### Performance
- Board: move Agent_economy.earn outside store.mutex (#6649)

## [0.5.7] - 2026-04-12

### Fixed
- CP unit: bound descendant_units_of_kind recursion (#6647)
- Prompt registry: merge validate+write into single mutex transaction (#6646)
- Workspace task schedule: reuse Workspace_task.update_local_agent_state on agent writes (#6642)

### Changed
- Bump agent_core pin for min_p capability gate fix (#6653)
- Keeper: remove redundant UTF-8 sanitize calls on LLM input path (#6645)
- Docs: fix prompt-layer drift teaching server-root .worktrees/ (#6648)

## [0.5.6] - 2026-04-12

### Added
- Restore Groq runtime fallback, confirmed by agent_core 0.121.0 (#6566)
- Bridge Agent_sdk.Log to masc structured log (#6618)

### Fixed
- CP unit: bound descendant_ids recursion with max_tree_depth guard (#6635)
- Workspace task: hold with_file_lock on agent state writes (#6634)
- Workspace/CP: hold with_file_lock around archive read-modify-write (#6632)
- Session: hold registry.lock on all hashtable reads, drop dead unregister_sync (#6628)
- Auth: gate cross-agent create_token and revoke on initial_admin (#6627)
- Channel gate: wire dedup_cleanup into orchestrator pulse (#6612)
- Keeper: fix retry timeout budget and local-only context (#6593)
- Config: prefer base-path config over repo-local env (#6626)

### Changed
- Bump agent_core pin to v0.122.0 (#6631)

## [0.5.5] - 2026-04-12

### Added
- Harness: expose cross-model enforcement rate on dashboard (#6565)
- Dashboard: expose keeper FSM + root-fix hardcoded constants + TLA+ bug model (#6556)

### Fixed
- Keeper: cap Eio.Semaphore.acquire wait in with_keeper_turn_slot (#6608)
- Keeper: delete manual_reconcile file on clear to unblock legacy binaries (#6576)
- Tool worktree: reject cross-agent agent_name in masc_worktree_create (#6617)
- Tool code_write: scope writable paths and clone cwd per-agent (#6610)
- CI: narrow Keeper_tool_policy_config shortcut, revert signature tightening (#6607)
- CI: require tool_policy.toml in config_signature_exists (#6595)

### Changed
- Bump agent_core pin to v0.121.0 for keep_alive=-1 fix (#6601)
- CI: wire specs/bug-models/ into tla-check.sh (#6582)

### Specifications
- TLA+ KeeperTaskInterlock: no Dead keeper holds a claimed task (#6574)

### Documentation
- Document post-turn-lifecycle implicit invariant (#6604)

## [0.5.4] - 2026-04-11

### Added
- `MASC_KEEPER_RUNTIME_PROVIDER_ALLOWLIST` env knob for runtime runtime narrowing (#6478)
- `Config_dir_resolver.log_resolution` startup log with shadow hint (#6478)
- `test_runtime_config_validity` alcotest suite for runtime.json profiles (#6478)
- `scripts/sync-version-truth.sh` dry-run version sync helper (#6478)
- `scripts/opam-pin-external-deps.sh --install` flag (#6478)

### Changed
- Keeper: remove scope_kind gating (#6544)
- Runtime: drop unsupported groq labels (#6558)
- Dashboard: remove dead SSE route entries (#6557)

### Fixed
- Keeper: block write ops outside playground in keeper_bash (#6579)
- Keeper: address cross-model review follow-ups for #6543 (#6563)
- Keeper: log when open_pending overwrites a Cleared reconcile record (#6562)
- Keeper: use Eio.Lazy for decision_audit env caches (#6549)
- Keeper: tolerate text_response when provider ignores tool_choice (#6532)
- Keeper: distinguish Cancel from Timeout in LLM bridge (#6543)
- Keeper: enforce base path SSOT for playgrounds (#6548)
- Keeper: fix startup base path and cwd defaults (#6546)
- Keeper: fix channel gate ack leak (#6545)
- gRPC: guarantee cleanup on heartbeat fiber exit paths (#6524)
- gRPC: guarantee typed_stream close on subscribe fiber exit paths (#6529)
- Worktree: remove server-root fallback from worktree_create_r (#6542)
- Config: align config truth with runtime paths (#6503)
- CI: clean log noise and TLA workflow (#6505)
- Dashboard: type supervisor_diagnostics + ErrorState wave 3 (#6550)
- Test: clone into playground before masc_worktree_* (#6577)
- Docs: require keeper worktree under own playground clone (#6533)

## [0.5.3] - 2026-04-11

### Added
- Expose llm_provider_http_status via retired scrape backend counter (#6514)

### Changed
- Extract shared tool permission map from auth (#6501)
- Rename type result to tool_result across all tool modules (#6482)
- Bump agent_core pin to v0.120.0 (#6510)
- Replace tautological assertions with observable post-conditions in keeper-registry tests (#6506)
- Prune retired front doors (#6520)
- Remove unused delete_posts_by_predicate (#6509)
- Remove 13 dead dashboard exports (#6493)

### Fixed
- Keeper: gate auto-clear of manual reconcile behind age threshold (#6497)
- Keeper: should_run_turn now consults manual_reconcile_pending (#6518)
- Keeper: SSOT playground paths, drop hardcoded masc and container root (#6468)
- Keeper: convert parse_keeper_identity from failwith to Result (#6479)
- Keeper FSM runtime integration (#6451)
- Goal-janitor: surface write_meta Error instead of ignoring (#6513)
- Board: log vote/vote_comment errors instead of silent drop (#6463)
- Backend: detect partial writes in atomic_increment and atomic_update (#6480)
- Transport: surface WS and WebRTC send failures in server bootstrap (#6517)
- Eio: wrap oas_sse_bridge + rate_limit cleanup fibers with exception loggers (#6519)
- Dashboard: restore control surface routing (#6490, #6523)
- Dashboard: standardize error display to CSS variable color scheme (#6494)
- Dashboard: standardize time display to relativeTime/TimeAgo (#6491)
- Dashboard: improve accessibility for buttons and form labels (#6496)
- Dashboard: preserve board scroll position on refresh (#6461)
- Dashboard: rename harness rail labels to match actual state (#6521)
- Dashboard: align navigation descriptions with actual UI (#6526)
- Worktree: use config base_path for worktree root (#6449)
- Playground: docker_playground_cwd double-slash escape (#6522)

### Security
- Remove tracked localhost TLS key from repository (#6487)

### Performance
- Memoize expensive derived state in fleet and agent-roster dashboard (#6492)

## [0.5.2] - 2026-04-11

### Changed
- Eliminate vendor hardcoding outside provider_adapter boundary (#6495)
- Root cause fixes for JSONL parsing, retired GitHub repo helper, preset validation (#6457)

### Fixed
- Restore loopback cross-port relaxation in auth (#6504)
- Delegate context budget to agent_core pipeline (#6488)

## [0.5.1] - 2026-04-11

### Changed
- FSM apply_event returns `Applied | Ignored` transition type — detect invalid events (#6481)
- Replace stringly-typed gate field with variant type (#6454)

### Fixed
- Restore keeper reset surface and typed tool expectations (#6477)
- Use glm-coding (Coding Plan) before glm (pay-per-use) in runtime (#6475)
- Align 4 tests with post-#6433 main state (#6460)

## [0.5.0] - 2026-04-11

### Added
- Typed_tool_masc + State_product + TLA+ orthogonal FSM verification (#6321)
- Trust Observatory dashboard — raw signals (Phase C0) (#6359)
- B-SIM Monte Carlo verification — 4 gates pass (#6352)
- Per-decision trifecta evaluation (Phase B3) (#6346)
- Guard → Thompson bridge (Phase B1) (#6307)
- TLA+ KeeperDecisionPipeline — Phase B0 gate (#6277)
- Shared gate client + Telegram/CLI connectors (#6367)
- iMessage channel connector (#6329)
- Docker playground for keeper_bash (#6338)
- Decision Pipeline FSM diagram in keeper detail dashboard (#6405)
- masc_keeper_reset command for stale runtime state (#6428)
- rate_limit.mli — hide bucket internals behind abstract type (#6431)
- coding_first runtime profile — glm-5.1 first for PR-capable keepers (#6430)
- Voice tools for sangsu (ElevenLabs Roger) (#6247)
- Keeper Failing → recovery minimum shards + .masc/ whitelist (Phase B2) (#6325)

### Changed
- Restructure keeper.world.md and keeper.capabilities.md (#6298)
- Substitute keeper_name into world/capabilities prompts (#6316)
- Expand decision log error_category: 5 → 7 categories (#6316)
- Wire agent_core Tool_retry_policy + post_tool_use_failure hook (#6324)
- Per-keeper error prevention hints in TOML instructions (#6298)
- Broadcast PoC uses Tool_schema_gen combinators (#6427)
- Remove params_to_input_schema duplicate — use agent_core shared utility (#6418)
- Draining invariant doc fix to match TLA+ (#6403)
- Rename team_session → execution_session (#6364)
- Remove remaining team session surfaces (#6363)
- agent_core pin bumped to v0.119.1 (#6446)
- Allow localhost cross-port browser mutations for dev dashboard (#6459)

### Fixed
- Keeper turn timeout 300s → 1200s default (env var override removed) (#6371)
- Auto-recover reconcile-safe tools on server parse errors (#6370)
- Feature flag registry: MASC_KEEPER_DOCKER_PLAYGROUND (#6365)
- Voice config empty session endpoints (#6357)
- Keeper sidecar suffix check for dotted names (#6408)
- Worktree basepath config resolution (#6449)
- Keeper autonomous stall — raise turn budget, classify shell read-only (#6371)
- 50 additional bug fixes across keeper, dashboard, and infrastructure

## [0.3.0] - 2026-04-09

### Added
- Startup TOML cross-validation for tool registration (#6093)
- Keeper runtime config API + dashboard selector + TOML hot-reload (#6100)
- MASC store diagnosis cards in telemetry view (#6105)
- agent_core runtime diagnosis surfaces (#6061)
- Prompt fingerprint telemetry (#6075)
- Keeper PR history tracking + active worktree listing in dashboard (#6083)
- Keeper playground state cache + dashboard panel (#6060)
- Dashboard agent_core worker observability enrichment (#6071)
- Fleet telemetry panel improvements (#6104)
- Governance HITL approvals dashboard (#6098)
- Keeper TOML→JSON config SSOT resync — 20 fields (#6110)

### Changed
- **Breaking**: Renamed `keeper_shell_readonly` to `keeper_shell` across all configs, prompts, and registry (#6095)
- Centralized keeper entrypoint alias resolution (#6096)
- Simplified dashboard command surface (#6058)
- Simplified monitoring agents runtime view (#6103)
- Simplified playground status with stdlib `List.take` (#6097)
- Tool spec handler_binding required variant for type-safe dispatch (#6073)
- agent_core pin bump to 120710a with Uncertain.t (#6114)
- Hardened agent_core ownership boundaries (#6101)
- agent_core pin SSOT and diagnostics checks relaxation (#6113)

### Fixed
- Discord keeper session isolation per workspace (#6094)
- Keeper post-commit timeout classification (#6102)
- Worker model_id hardcoded "turn-exhausted" in MaxTurnsExceeded response (#6087)
- Dashboard error prefix stripping before JSON categorization (#6057)
- Removed fake no-op Dashboard_cache.set_clock/set_sw (#6081, #6074)
- Dead agent_core proof bridge panels removed from telemetry view (#6106)
- Sangsu keeper switched to local_only runtime (#6088)
- CI semantic version comparison in agent_core pin check (#6111)

## [0.2.0] - 2026-04-09

### Changed
- Release SemVer restarts at `0.y.z` to reflect that `masc` is still pre-1.0.
- Release-train automation now compares tags within the active major series, so frozen legacy `v2.*` tags do not block the new `0.x` line.
- Front-door docs, release policy, and issue templates now point at `v0.2.0` as the active package version.
- The reset starts at `0.2.0` because historical `v0.1.0` and `v0.1.1` tags already exist in the repo.

### Deprecated
- New `v2.*` release tags. Historical `v2.87.0` through `v2.263.0` remain immutable legacy references.

## [2.263.0] - 2026-04-09

### Added
- agent_core exit_condition plumbing — boring gate exits Agent.run early after 8+ idle turns (#5988)
- Configurable boring exit threshold via Runtime_params (#5997)
- Tool schemas for the historical autonomy pipeline (#5996)
- Keeper read-only tool classification with Tool_dispatch mirroring (#5983)
- Retry-safe tool metadata — board tools registered with Mod_inline + idempotent flags (#5973)
- Self-repo --base-path guard — rejects runtime state in source repo (#5992)

### Changed
- Adaptive agent_core timeout — context-based (180s + 1.5s/1K tokens), max_turns 200→5 (#5987)
- GLM runtime simplified — removed redundant glm:glm-5-turbo, agent_core glm:auto handles expansion (#5985)
- Time constants extracted to Masc_time_constants SSOT module (#5993)
- Network defaults centralized — SearXNG, OTel, allowed_origins (#5994)
- Output cap and min context constants deduplicated (#5995)

### Fixed
- Dashboard null-status crash — assoc_member wrapper tolerates null nested JSON (#5985)
- Keeper ambiguous-partial-commit reclassification for read-only tools (#5983, #5973)
- agent_core runtime model timeout derived from keeper agent_core budget (#5985)
- Cheolsu keeper set to ollama-only for slot queuing test (#5986)
- TLA+ spec: separated timeout from fairness, use Filename.concat (#5979)
- Version truth sync across ROADMAP, SPEC-INDEX, PRODUCT-OPERATING-PLAN (#5982)
- agent_core pin updated to 0.117.0 (#5981)

## [2.262.0] - 2026-04-09

### Added
- Genuine HITL approval pipeline — Eio.Promise fiber suspension, MCP approval tools (#5907 Phase 1, #5955)
- Graduated boring-turn guard — 5-level tool_choice escalation to cut idle token waste (#5968)
- agent_core pin drift diagnostics — local switch validation in Makefile build/test targets (#5958)
- Spawn stderr capture + cloexec pipes — child process observability and hang prevention (#5960)
- Approval audit log — persistent JSONL records for pending/resolved/expired events (#5969)
- Git clone sandboxing in keeper_shell (#5930)

### Fixed
- Ollama thinking mode disabled for keepers — unblocked all keeper timeouts (#5948)
- ToolResult.json field drift — aligned with agent_core 0.116.1 (#5948)
- Hardcoded port 8085 removal — env-driven LLM endpoint discovery (#5962)
- Keeper name and MCP prefix boundary resolution (#5967)
- Dashboard null-agent patch guard (#5971)
- GLM-5-turbo runtime fallback for outage resilience (#5956)
- Read path validation with bounded suffix resolution and symlink escape prevention (#5930)
- Approval queue fiber cancellation cleanup — no orphan entries (#5955)

### Changed
- Named constants for model context thresholds (64k/200k) replacing magic numbers (#5969)
- Governance risk patterns documented in-code for mandatory review (#5969)

## [2.261.0] - 2026-04-08

### Added
- Per-keeper provider filter via `allowed_providers` config (#5831)
- Preset-aware task routing — keepers only claim tasks matching their preset (#5820)
- 11-state keeper phase diagram in dashboard (#5829)
- Excuse patterns editor UI with server-side validation (#5818)
- Output validation stats in tool-quality dashboard (#5832)
- Dashboard SSE `keeper_tool_skipped` event + centralized thresholds (#5824)
- Deterministic tool output validation (Samchon-style schema constraints) (#5821)
- Analyst keeper (verification-driven) (#5850)

### Fixed
- Comprehensive Eio.Cancel.Cancelled guard sweep — 72 files, 129 patterns (#5842)
- Cancelled guard rollback for 3 cleanup sites (fd close before re-raise) (#5848)
- AllowList pruning WARN + agent JSON race condition (atomic write) (#5840)
- Defensive lowercase + warn log in filter_by_providers (#5846)
- Policy preset name validation at load time (#5787)
- Cluster-aware telemetry read path (#5828)
- Chevron discoverability (opacity-40 default) (#5837)

### Changed
- Board_listener removed — filesystem-first, PG relay redundant (#5809)
- Heuristic metadata matching replaced with deterministic Tool_dispatch sets (#5830)
- DRY `lower_string_list_opt` helper for allowed_providers parsing (#5844)
- Transport status reports canonical HTTP protocol (#5833)

### Docs
- Gate-Connector Protocol RFC: fail-closed, shorter URL TTL, replay protection (#5805)

## [2.260.0] - 2026-04-08

### Fixed
- Eio.Cancel.Cancelled re-raised instead of swallowed in bridge, dashboard, and metrics modules (#5810)
- truncate_tool_output now enforces hard cap on total output length (#5814)
- autonomous_turn_limit default set to 1 for single-slot servers (#5806)
- Yojson.Json_error catch narrowed in dashboard tool-quality (#5812)
- Branch-switch guard hardened with tab tokenization, global git options, and precise mutation detection (#5813)
- useEffect void prefix for floating promise lint (#5816)

### Changed
- Board votes now use stable post content hash instead of monotonic counter (#5817)
- K2K preset routing refined with forbidden_tools and improved score penalty (#5819)
- Deterministic read-only boundary enforcement for shell/gh tools (#5822)
 
