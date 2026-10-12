# Renderer/search projection divergence

Baseline `5a9d7aeac2e609a5dab261204cf89825155860b6`.
Evidence: source control-flow trace. No full TUI or compiled test execution.

## P2: visible settled journal replies cannot be found with `/find`

A concrete state:

- Keeper `alpha`, operation `op-a`.
- Durable history has User(`question`) and Keeper(`UNIQUE_ANSWER_NEEDLE`).
- `msg_settled_logs` holds op-a's journal containing Run_started, Text with that
  answer, Reply_details(Visible_reply), and Run_finished.
- The journal is selected and `turn_log_holds_the_turn` is true.

Flow:

1. `compute_chat_rows_for` builds held turns and removes the Keeper row from
   loaded/session history with `rows_the_logs_do_not_draw` (`types.ml:9330-9337`).
   `log_draws_row` explicitly replaces Keeper, autonomous, tool and skill rows
   (`7357-7367`). This correctly avoids rendering the same answer twice.
2. `render_keeper_message` independently constructs held log blocks and merges
   their entries into the frame (`render_chat.ml:2962-3026,3038-3078`). The
   UNIQUE_ANSWER_NEEDLE text is visible once through its journal.
3. `keeper_message_find_scroll` gets `keeper_message_visible_messages`, whose
   default source is the already-filtered `chat_rows_for` (`1458-1464,1497-1500`).
   It constructs entries only from those committed rows (`2330-2337`).
4. Its actual predicate inspects only these entries (`2346-2351`), so the answer
   is absent. `/find UNIQUE_ANSWER_NEEDLE` returns None.
5. The user is told `nothing in this conversation` (`masc_tui.ml:8867-8872`),
   despite the answer being on the screen.

The same issue applies to visible settled tools/skills and to partial sources
whose final replies suppress a durable row. Pending inputs and hidden reasoning
have separate visibility policies; they are not needed to establish this bug.

A second symptom shares the same root: searching an older ordinary user row
counts only newer committed entries (`render_chat.ml:2359-2366`) while the actual
viewport also contains the newer journal blocks. Long held replies can therefore
leave a reported match outside the viewport. The recent receipt-annotation fix
only synchronized annotation height; it did not unify the source list.

## Regression scenario to execute after repair

1. Populate the normal TUI state with the above persisted history plus a held
   settled log, and draw the actual frame through `render_keeper_message`.
2. Assert the answer appears exactly once.
3. Invoke the public `keeper_message_find_scroll` with its unique text; require a
   match and render the returned scroll position to assert that match is visible.
4. Append several long settled journal replies, then search for the older input;
   assert the returned position still shows the requested row.
5. Exercise live-to-settled and history-refresh transitions without duplicating
   the searchable entries or changing the search anchor to a list index.

These are proposed regression steps, not claimed executed tests.
