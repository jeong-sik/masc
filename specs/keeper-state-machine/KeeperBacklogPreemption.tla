---- MODULE KeeperBacklogPreemption ----
\* Two Keeper turns share one Owner slot: a chat operation (a Direct turn) and
\* a scheduled turn (an autonomous turn admitted with one Schedule_due source).
\* The model asks when a running turn ends in a checkpoint and how many turns
\* the same two pieces of work then need.
\*
\* Runtime correspondence (read at 3e41385b549):
\*   - keeper_chat_yield_request.ml: a Direct turn yields to a pending
\*     Schedule_due and to a chat admitted after it; an autonomous turn yields
\*     to a claimable chat operation.
\*   - keeper_unified_turn.ml make_autonomous_yield_probe: an autonomous turn
\*     yields to a Schedule_due that arrived after its intake, and to a
\*     Tool_result_ready row that arrived after its intake.
\*   - keeper_client_tool_outbox_wake.ml: that row is published by a periodic
\*     pulse, so it can name a receipt the running turn already holds.
\*   - keeper_heartbeat_loop.ml checkpoint_source_policy: a checkpoint keeps
\*     Schedule_due and Tool_result_ready rows; only a completed turn removes
\*     them.
\*   - keeper_owner.ml observe_scheduled_turn: while a chat turn runs, the
\*     Owner reserves the next slot for the pending scheduled work.
\*   - A yielded chat operation is queued again as a continuation. This is read
\*     from the alternating decision rows and was not followed to the end in
\*     code.
\*
\* The clean model ends a turn in a checkpoint only for a chat admitted after
\* the Direct turn started, or, for the scheduled turn, a claimable chat. Each
\* buggy switch adds one of the three yields the code had at 3e41385b549. A turn that
\* yields without an outside cause starts the same work again, so the number of
\* turns grows with the number of tool calls instead of the number of
\* outside causes.

EXTENDS Naturals

CONSTANTS
    ChatCalls,               \* tool calls the chat operation needs
    SchedCalls,              \* tool calls the scheduled work needs
    MaxAddressed,            \* finite TLC environment: chats admitted later
    MaxOccurrences,          \* finite TLC environment: schedule occurrences
    MaxRows,                 \* finite TLC environment: published result rows
    DirectYieldsToSchedule,  \* BOOLEAN: a Direct turn yields to a pending schedule
    SuccessorYields,         \* BOOLEAN: the scheduled turn yields to a schedule that came due after its intake
    ReceiptRowYields         \* BOOLEAN: the scheduled turn yields to a result row it already holds

ASSUME CallsOK ==
    /\ ChatCalls  \in Nat /\ ChatCalls  >= 1
    /\ SchedCalls \in Nat /\ SchedCalls >= 1
ASSUME BoundsOK ==
    /\ MaxAddressed   \in Nat
    /\ MaxOccurrences \in Nat
    /\ MaxRows        \in Nat
ASSUME SwitchesOK ==
    /\ DirectYieldsToSchedule \in BOOLEAN
    /\ SuccessorYields        \in BOOLEAN
    /\ ReceiptRowYields       \in BOOLEAN

VARIABLES
    chat_left,         \* tool calls the chat operation still needs
    sched_left,        \* tool calls the scheduled work still needs
    sched_pending,     \* the Schedule_due row is in the queue; a checkpoint keeps it
    chat_queued,       \* a claimable chat operation waits for the slot
    reserved,          \* the Owner reserved the next slot for the scheduled work
    lane,              \* "none" | "direct" | "sched"
    at_boundary,       \* the running turn stands at a tool boundary
    later_chat,        \* a chat admitted after the running Direct turn started
    addressed_total,   \* chats admitted later, in total
    successor,         \* a schedule occurrence arrived after the scheduled turn's intake
    successor_total,
    receipt_row,       \* a Tool_result_ready row names a receipt the turn already holds
    rows_total,
    turns_started      \* turns started for the two pieces of work

vars ==
    << chat_left, sched_left, sched_pending, chat_queued, reserved, lane,
       at_boundary, later_chat, addressed_total, successor, successor_total,
       receipt_row, rows_total, turns_started >>

TypeOK ==
    /\ chat_left       \in 0..ChatCalls
    /\ sched_left      \in 0..SchedCalls
    /\ sched_pending   \in BOOLEAN
    /\ chat_queued     \in BOOLEAN
    /\ reserved        \in BOOLEAN
    /\ lane            \in {"none", "direct", "sched"}
    /\ at_boundary     \in BOOLEAN
    /\ later_chat      \in BOOLEAN
    /\ addressed_total \in 0..MaxAddressed
    /\ successor       \in BOOLEAN
    /\ successor_total \in 0..MaxOccurrences
    /\ receipt_row     \in BOOLEAN
    /\ rows_total      \in 0..MaxRows
    /\ turns_started   \in 0..(2 * (ChatCalls + SchedCalls + MaxAddressed
                                    + MaxOccurrences + MaxRows) + 4)

Init ==
    /\ chat_left       = ChatCalls
    /\ sched_left      = SchedCalls
    /\ sched_pending   = TRUE
    /\ chat_queued     = TRUE
    /\ reserved        = FALSE
    /\ lane            = "none"
    /\ at_boundary     = FALSE
    /\ later_chat      = FALSE
    /\ addressed_total = 0
    /\ successor       = FALSE
    /\ successor_total = 0
    /\ receipt_row     = FALSE
    /\ rows_total      = 0
    /\ turns_started   = 0

\* Someone else sends the Keeper a chat after the running turn started.
Address ==
    /\ addressed_total < MaxAddressed
    /\ addressed_total' = addressed_total + 1
    /\ later_chat'      = TRUE
    /\ chat_queued'     = TRUE
    /\ UNCHANGED << chat_left, sched_left, sched_pending, reserved, lane,
                    at_boundary, successor, successor_total, receipt_row,
                    rows_total, turns_started >>

\* A new schedule occurrence comes due while the scheduled turn runs.
NewOccurrence ==
    /\ lane = "sched"
    /\ successor_total < MaxOccurrences
    /\ successor'       = TRUE
    /\ successor_total' = successor_total + 1
    /\ UNCHANGED << chat_left, sched_left, sched_pending, chat_queued,
                    reserved, lane, at_boundary, later_chat, addressed_total,
                    receipt_row, rows_total, turns_started >>

\* The periodic pulse publishes a row for a receipt left by a tool call that
\* already happened, while a turn runs.
PulseRow ==
    /\ lane /= "none"
    /\ ~receipt_row
    /\ rows_total < MaxRows
    /\ rows_total < (ChatCalls - chat_left) + (SchedCalls - sched_left)
    /\ receipt_row' = TRUE
    /\ rows_total'  = rows_total + 1
    /\ UNCHANGED << chat_left, sched_left, sched_pending, chat_queued,
                    reserved, lane, at_boundary, later_chat, addressed_total,
                    successor, successor_total, turns_started >>

\* A chat turn starts. While it runs the Owner reserves the next slot for the
\* scheduled work.
StartDirect ==
    /\ lane = "none"
    /\ chat_queued
    /\ ~reserved
    /\ lane'          = "direct"
    /\ at_boundary'   = FALSE
    /\ chat_queued'   = FALSE
    /\ later_chat'    = FALSE
    /\ reserved'      = sched_pending
    /\ turns_started' = turns_started + 1
    /\ UNCHANGED << chat_left, sched_left, sched_pending, addressed_total,
                    successor, successor_total, receipt_row, rows_total >>

\* The scheduled turn starts when the slot is reserved for it or no chat waits.
\* The last turn of the work may need no tool call: the model only answers.
StartSched ==
    /\ lane = "none"
    /\ sched_pending
    /\ (reserved \/ ~chat_queued)
    /\ lane'          = "sched"
    /\ at_boundary'   = FALSE
    /\ reserved'      = FALSE
    /\ successor'     = FALSE
    /\ turns_started' = turns_started + 1
    /\ UNCHANGED << chat_left, sched_left, sched_pending, chat_queued,
                    later_chat, addressed_total, successor_total, receipt_row,
                    rows_total >>

DirectCall ==
    /\ lane = "direct"
    /\ ~at_boundary
    /\ chat_left > 0
    /\ chat_left'   = chat_left - 1
    /\ at_boundary' = TRUE
    /\ UNCHANGED << sched_left, sched_pending, chat_queued, reserved, lane,
                    later_chat, addressed_total, successor, successor_total,
                    receipt_row, rows_total, turns_started >>

\* Clean: the Direct turn goes on unless a chat was admitted after it started.
DirectContinue ==
    /\ lane = "direct"
    /\ at_boundary
    /\ ~later_chat
    /\ at_boundary' = FALSE
    /\ UNCHANGED << chat_left, sched_left, sched_pending, chat_queued,
                    reserved, lane, later_chat, addressed_total, successor,
                    successor_total, receipt_row, rows_total, turns_started >>

\* Clean: the Direct turn ends in a checkpoint for a chat admitted after it.
\* Its own continuation is queued again.
DirectYieldToLaterChat ==
    /\ lane = "direct"
    /\ at_boundary
    /\ later_chat
    /\ lane'        = "none"
    /\ at_boundary' = FALSE
    /\ later_chat'  = FALSE
    /\ chat_queued' = TRUE
    /\ UNCHANGED << chat_left, sched_left, sched_pending, reserved,
                    addressed_total, successor, successor_total, receipt_row,
                    rows_total, turns_started >>

DirectComplete ==
    /\ lane = "direct"
    /\ ~at_boundary
    /\ chat_left = 0
    /\ lane' = "none"
    /\ UNCHANGED << chat_left, sched_left, sched_pending, chat_queued,
                    reserved, at_boundary, later_chat, addressed_total,
                    successor, successor_total, receipt_row, rows_total,
                    turns_started >>

SchedCall ==
    /\ lane = "sched"
    /\ ~at_boundary
    /\ sched_left > 0
    /\ sched_left'  = sched_left - 1
    /\ at_boundary' = TRUE
    /\ UNCHANGED << chat_left, sched_pending, chat_queued, reserved, lane,
                    later_chat, addressed_total, successor, successor_total,
                    receipt_row, rows_total, turns_started >>

\* Clean: the scheduled turn goes on unless a chat operation is claimable.
SchedContinue ==
    /\ lane = "sched"
    /\ at_boundary
    /\ ~chat_queued
    /\ at_boundary' = FALSE
    /\ UNCHANGED << chat_left, sched_left, sched_pending, chat_queued,
                    reserved, lane, later_chat, addressed_total, successor,
                    successor_total, receipt_row, rows_total, turns_started >>

\* Clean: the scheduled turn ends in a checkpoint for a claimable chat. The
\* checkpoint keeps the Schedule_due row.
SchedYieldToChat ==
    /\ lane = "sched"
    /\ at_boundary
    /\ chat_queued
    /\ lane'        = "none"
    /\ at_boundary' = FALSE
    /\ UNCHANGED << chat_left, sched_left, sched_pending, chat_queued,
                    reserved, later_chat, addressed_total, successor,
                    successor_total, receipt_row, rows_total, turns_started >>

\* A completed scheduled turn removes the Schedule_due row and the result rows.
SchedComplete ==
    /\ lane = "sched"
    /\ ~at_boundary
    /\ sched_left = 0
    /\ lane'          = "none"
    /\ sched_pending' = FALSE
    /\ receipt_row'   = FALSE
    /\ UNCHANGED << chat_left, sched_left, chat_queued, reserved, at_boundary,
                    later_chat, addressed_total, successor, successor_total,
                    rows_total, turns_started >>

Done ==
    /\ chat_left = 0
    /\ ~sched_pending
    /\ ~chat_queued
    /\ lane = "none"
    /\ UNCHANGED vars

\* Bug: the Direct turn ends in a checkpoint while a schedule is pending. The
\* Owner reserves the next slot for it and the chat is queued again.
DirectYieldToSchedule ==
    /\ DirectYieldsToSchedule
    /\ lane = "direct"
    /\ at_boundary
    /\ sched_pending
    /\ lane'        = "none"
    /\ at_boundary' = FALSE
    /\ chat_queued' = TRUE
    /\ reserved'    = TRUE
    /\ UNCHANGED << chat_left, sched_left, sched_pending, later_chat,
                    addressed_total, successor, successor_total, receipt_row,
                    rows_total, turns_started >>

\* Bug: the scheduled turn ends in a checkpoint for an occurrence that came due
\* after its intake, and the Owner reserves the next slot for it.
SchedYieldToSuccessor ==
    /\ SuccessorYields
    /\ lane = "sched"
    /\ at_boundary
    /\ successor
    /\ lane'        = "none"
    /\ at_boundary' = FALSE
    /\ successor'   = FALSE
    /\ reserved'    = TRUE
    /\ UNCHANGED << chat_left, sched_left, sched_pending, chat_queued,
                    later_chat, addressed_total, successor_total, receipt_row,
                    rows_total, turns_started >>

\* Bug: the scheduled turn, which was admitted a source, ends in a checkpoint
\* for a result row that arrived after its intake, although the turn already
\* holds that receipt. The row stays. A Direct turn is not admitted a source, so
\* the code never yields it to this row.
YieldToReceiptRow ==
    /\ ReceiptRowYields
    /\ lane = "sched"
    /\ at_boundary
    /\ receipt_row
    /\ lane'        = "none"
    /\ at_boundary' = FALSE
    /\ UNCHANGED << chat_left, sched_left, sched_pending, chat_queued, reserved,
                    later_chat, addressed_total, successor, successor_total,
                    receipt_row, rows_total, turns_started >>

Next ==
    \/ Address
    \/ NewOccurrence
    \/ PulseRow
    \/ StartDirect
    \/ StartSched
    \/ DirectCall
    \/ DirectContinue
    \/ DirectYieldToLaterChat
    \/ DirectComplete
    \/ SchedCall
    \/ SchedContinue
    \/ SchedYieldToChat
    \/ SchedComplete
    \/ DirectYieldToSchedule
    \/ SchedYieldToSuccessor
    \/ YieldToReceiptRow
    \/ Done

Spec == Init /\ [][Next]_vars

\* A result row exists only for a tool call that was made.
RowsFromCalls ==
    rows_total <= (ChatCalls - chat_left) + (SchedCalls - sched_left)

\* The two pieces of work need two turns, plus at most two more for each chat
\* admitted later: the Direct turn stops for it and starts again, or the
\* scheduled turn stops for it and starts again after the chat's own turn.
\* Nothing else may start another turn.
TurnsFollowOutsideCauses ==
    turns_started <= 2 + 2 * addressed_total

====
