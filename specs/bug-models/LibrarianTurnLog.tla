---- MODULE LibrarianTurnLog ----
(***************************************************************************)
(* The turn log of one Keeper: who appends which line, what a line names,  *)
(* and what the reader, the purge and the object sweep may do with it.     *)
(* It stands for RFC section 5, "Input: the turn log" (5.2 who appends     *)
(* what and when, 5.3 units, 5.4 unread and unreadable, 5.6 the purge does *)
(* not wait for the Librarian).                                            *)
(*                                                                         *)
(* One Keeper, one trace head, one turn log file, one reader. A message is *)
(* << id, version >>; a rewrite by a purge raises the version. A bundle is *)
(* the sequence of its messages and stands for its digest. A head holds    *)
(* closed turns (bundles) and open messages; a mark counts closed          *)
(* messages only. A Closed line and a Reset line are units: the content of *)
(* a unit is what closed between the last unit line's mark and its own.    *)
(*                                                                         *)
(* Rules the model holds, each with a planted old rule (constant Bug):     *)
(*   - After an announced Reset the next unit starts at its after, always. *)
(*     No line withdraws a Reset. When the announced head change was not   *)
(*     made, the messages from after to before are named a second time.    *)
(*   - A line writer outside a turn (admission, the process-start step     *)
(*     when it has a Closed to write, the reset function) closes the       *)
(*     head's open messages with one save before it reads the mark. When   *)
(*     the save fails, admission and the process-start step go on; the     *)
(*     reset function refuses (no line, no head change: not a step here).  *)
(*   - A stop that removes the session appends an Unannounced Reset first  *)
(*     and removes only when the append went in.                           *)
(*   - A rewrite-only purge rewrites only messages below the last unit     *)
(*     line's mark; its save closes the open messages byte-exact.          *)
(*   - The sweep at process start roots the bundles of every line from the *)
(*     reader's offset on, and of every line when that offset is not a     *)
(*     place in the file on disk. An undecodable root line stops the pass. *)
(*                                                                         *)
(* Properties:                                                             *)
(*   NoSilentSkip          every message ever closed is named by a line,   *)
(*                         lies in a recorded unknown span, went with a    *)
(*                         lost file, or is owed to the next unit line.    *)
(*   NoSkipOfHeadMessage   the same for the messages the head holds now.   *)
(*   NoOpenLost            no message leaves a head while still open,      *)
(*                         except by a stop whose line recorded the span.  *)
(*   EveryClosedInOneUnit  a closed message is named by exactly one unit;  *)
(*                         twice only for the two stated causes (a message *)
(*                         a clear keeps; a head change that was not       *)
(*                         made).                                          *)
(*   LeftoverNotBorrowed   a message left open by a dead turn or a failed  *)
(*                         closing save is never in the own slice of a     *)
(*                         turn admitted later, unless that admission's    *)
(*                         closing save failed (closeFailedAt).            *)
(*   UnreadReadable        what no commit passed is in the store as the    *)
(*                         line named it, and the first line that names a  *)
(*                         message names it as first written.              *)
(*   UndeliveredReadable   the same for content no commit accounted for,   *)
(*                         when the file was cut or replaced.              *)
(*   PurgeOnlyRewritesNamed  a purge rewrote only what a line had named.   *)
(*   OnlyWrittenOrder      Log_started ( Reset | Opened Reset* Closed )*.  *)
(*   ShrinkOnlyByNamedPaths  the closed count goes down only by a head     *)
(*                         change after its line, a stop that removes the  *)
(*                         session, or an edit from outside the product.   *)
(*   MarksOnlyShrinkAtReset  no Opened or Closed carries a mark below the  *)
(*                         line before it.                                 *)
(*   reader side           NoDoubleRead, PassedAccounted, UnknownRecorded, *)
(*                         SkipRecorded, CutOrReplacedFound,               *)
(*                         QuietMeansRead, NeverStuckWithFile,             *)
(*                         SkipLineOnlyUndecodable.                        *)
(*                                                                         *)
(* Not modelled: the official-client byte marks, chat bytes and external   *)
(* rows (a mark is trace + closed_messages), items inside a unit, the task *)
(* evidence on Opened (attribution is the own slice only), the commit log  *)
(* itself (a commit is one atomic step and its tail line is readable), a   *)
(* save as a read and a write (every save is one step), turn segments,     *)
(* locks other than "nothing of this Keeper runs between a Reset line and  *)
(* its head change" (LockShared), today's order of the clear, liveness.    *)
(***************************************************************************)
EXTENDS TLC, Integers, Sequences, FiniteSets

CONSTANTS
    MaxMsgs,        \* messages that may ever be written to a head
    MaxLines,       \* lines one turn log file may hold
    MaxOpen,        \* open messages a turn may leave in the head by in-turn saves
    MaxPurges,      \* rewrite-only purges
    MaxResets,      \* announced resets (clear, recovering purge)
    MaxFails,       \* failed appends and process exits of the turn path
    MaxCloseFails,  \* failed closing saves of a line writer outside a turn
    MaxLate,        \* closes outside the exit path with no process start (a late save)
    MaxChgFails,    \* head changes that return an error after the Reset line
    MaxCrashes,     \* process exits between a Reset line and its head change
    MaxStops,       \* process stops with no turn running
    MaxRemoves,     \* Keeper stops that remove the session
    MaxReplaces,    \* the turn log file is deleted
    MaxCuts,        \* the file is cut or restored shorter under the same id
    MaxBad,         \* lines that stop decoding
    MaxRecreates,   \* the Keeper is made again on a new trace beside the old turn log
    MaxBreaks,      \* the head stops decoding
    MaxHand,        \* the head is shrunk by hand, outside the product
    LockShared,     \* BOOLEAN: no close and no line writer of the Keeper lies between a Reset line and its head change
    ClearKeeps,     \* BOOLEAN: a clear keeps one message, as it keeps System messages
    Unseen,         \* BOOLEAN: a by-hand shrink may regrow to the last mark before a line writer looks (stated limit)
    RegrowAligned,  \* BOOLEAN: a cut file that regrows past the saved offset has a line start there (stated limit)
    OwnAfterReset,  \* a Closed whose Opened is followed by a Reset: "unattributed" (its range has no task) | "own" (the whole range is own)
    Bug             \* "none" | "no_close_before_reset" | "no_close_at_admission" | "remove_session_no_line"
                    \* | "stop_line_deduped" | "sweep_offset_unchecked" | "sweep_head_only" | "purge_above_mark"
                    \* | "purge_open" | "withdrawn_by_count"

VARIABLES
    head,        \* [trace, bundles, open, ok]: closed turns, open messages; ok = it decodes
    objects,     \* bundles the object store holds
    log,         \* the turn log file; << >> = absent or no complete line
    logId,       \* the id in the file's Log_started (the last one written)
    bad,         \* line indexes that do not decode
    up,          \* the server process runs
    turn,        \* "none" | "line" (its Opened is written) | "noline" | "deadline" | "deadnoline"
    turnLine,    \* the line of the running turn's Opened, 0 for none
    saved,       \* the running turn made its closing save
    pend,        \* a reset between its line and its head change
    offset,      \* the reader's first unread line (the commit log's turn_log_offset)
    covered,     \* the reader's covered mark
    readerLogId, \* the turn log id of the last commit line
    misaligned,  \* the saved offset is not at a line start of this file
    passedTo,    \* ghost: the highest line of this file a commit ever passed
    staleCov,    \* the last commit was a Skip_line
    delivered,   \* message ids some commit delivered
    missingRec,  \* message ids some commit recorded as missing
    unknownRec,  \* Unannounced lines some commit recorded as Unknown_span
    lineSkipRec, \* lines some Skip (Line_unreadable) commit recorded
    skipped,     \* ghost: ids a Skip (Turn_log_replaced | Position_lost) commit stands for
    acct,        \* ghost: ids an Unknown_span or Line_unreadable record stands for
    excused,     \* ghost: ids a Restart_reading on the same file may deliver again (accepted)
    dupIds,      \* ghost: ids delivered twice with no excuse
    nextMsg,
    closedIds,   \* ghost: ids ever closed in a head
    openLost,    \* ghost: ids that were open in a head and left it without ever closing and without a stop's line
    seenShrink,  \* ghost: Unannounced lines
    unseen,      \* ghost: a by-hand shrink no line writer has looked at yet
    badPurge,    \* ghost: a purge rewrote a message that no line named and no recorded hole covered
    badSkip,     \* ghost: a Skip_line commit passed something that was not one undecodable line of the reader's file
    droppedUnread, \* ghost: a head change dropped a message no commit had delivered
    lostIds,     \* ghost: ids closed before the current file's Log_started
    happened,    \* ghost: announced Reset lines whose head change was made
    notHap,      \* ghost: announced Reset lines whose head change was not made
    rereadKept,  \* ghost: ids a clear kept (installed open, closed again): second-reading cause 1
    rereadNotMade, \* ghost: ids at positions after+1 .. before of an announced change that was not made: cause 2
    leftover,    \* ghost: ids a turn left open when it ended or died
    closeFailedAt, \* Opened lines whose admission could not close the head's open messages first (the excuse of LeftoverNotBorrowed)
    stopLines,   \* ghost: Unannounced lines a stop that removes the session wrote
    wit,         \* ghost: witness flags (reachability)
    budget

hv == << head, objects, nextMsg, closedIds, openLost >>
lv == << log, logId, lostIds, seenShrink, unseen >>
tv == << turn, turnLine, saved >>
gv == << happened, notHap, rereadKept, rereadNotMade >>
av == << leftover, closeFailedAt, stopLines >>
rvars == << offset, covered, readerLogId, misaligned, passedTo, staleCov, delivered, missingRec,
            unknownRec, lineSkipRec, skipped, acct, excused, dupIds, badSkip >>
vars == << hv, lv, tv, gv, av, rvars, bad, up, pend, badPurge, droppedUnread, wit, budget >>

Max2(a, b) == IF a > b THEN a ELSE b
Min2(a, b) == IF a < b THEN a ELSE b
MaxOf(S) == CHOOSE x \in S : \A y \in S : y <= x
MinOf(S) == CHOOSE x \in S : \A y \in S : x <= y

RECURSIVE Flat(_)
Flat(bs) == IF bs = << >> THEN << >> ELSE Head(bs) \o Flat(Tail(bs))

RECURSIVE LenUpTo(_, _)
LenUpTo(bs, j) == IF j = 0 THEN 0 ELSE LenUpTo(bs, j - 1) + Len(bs[j])
Start(bs, j) == LenUpTo(bs, j - 1)      \* messages before bundle j
End(bs, j) == LenUpTo(bs, j)
CM(bs) == LenUpTo(bs, Len(bs))

N(h) == CM(h.bundles)                   \* closed_messages: open messages are not counted
Mk(h) == [trace |-> h.trace, n |-> N(h)]
Msgs(h) == Flat(h.bundles) \o h.open    \* the message list
BundleSet(bs) == { bs[x] : x \in 1..Len(bs) }
IdsOfSeq(s) == { s[x][1] : x \in 1..Len(s) }
\* ids of the head's closed messages at positions above n
IdsFrom(h, n) == LET f == Flat(h.bundles) IN { f[x][1] : x \in (n + 1)..Len(f) }
\* One closing save: the open messages become one bundle, byte-exact.
CloseOpen(h) == [h EXCEPT !.bundles = Append(@, h.open), !.open = << >>]

\* ------------------------------------------------- what a line names
\* A piece is a bundle and the messages lo+1 .. hi of it (a slice).

Piece(bs, j, lo, hi) ==
    [b |-> bs[j],
     lo |-> Max2(lo, Start(bs, j)) - Start(bs, j),
     hi |-> Min2(hi, End(bs, j)) - Start(bs, j)]

RECURSIVE MsgPieces(_, _, _, _)
MsgPieces(bs, j, lo, hi) ==
    IF j > Len(bs) THEN << >>
    ELSE (IF Start(bs, j) < hi /\ End(bs, j) > lo THEN << Piece(bs, j, lo, hi) >> ELSE << >>)
         \o MsgPieces(bs, j + 1, lo, hi)

\* The closed content at trace positions [lo, hi).
RangeP(bs, lo, hi) == IF lo >= hi THEN << >> ELSE MsgPieces(bs, 1, lo, hi)

OccOf(lines, idxs) ==
    UNION { UNION { { << i, k, x >> : x \in (lines[i].pieces[k].lo + 1)..lines[i].pieces[k].hi }
                    : k \in 1..Len(lines[i].pieces) } : i \in idxs }
Occ(lines, idxs) == OccOf(lines, idxs)
MsgOf(t) == log[t[1]].pieces[t[2]].b[t[3]]
IdOf(t) == MsgOf(t)[1]
LineIds(i) == { IdOf(t) : t \in Occ(log, {i}) }
AllIdx == 1..Len(log)
LineIdsAll == UNION { LineIds(i) : i \in AllIdx }
NamedIn(lg) == { lg[t[1]].pieces[t[2]].b[t[3]][1] : t \in OccOf(lg, 1..Len(lg)) }
SpansIn(lg) == UNION { lg[i].span : i \in 1..Len(lg) }
NamedBundles(idxs) ==
    UNION { { log[y].pieces[z].b : z \in 1..Len(log[y].pieces) } : y \in idxs \cap AllIdx }

\* ------------------------------------------------- lines
\* k: LS Log_started, O Opened, C Closed, R Reset.
\* cause (Reset): cleared | recovered | unann | withdrawn (planted bug only).
\* mark: Opened.baseline, Closed.after, Reset.after. before: Reset.before.
\* turn: a Closed's Opened. own: the ids of a Closed's own slice.
\* left (ghost, Opened): the ids that were leftovers when the turn was admitted.

Line(k, cause, t, outcome, before, mark, pieces, span, own, left) ==
    [k |-> k, cause |-> cause, turn |-> t, outcome |-> outcome,
     before |-> before, mark |-> mark, pieces |-> pieces, span |-> span, own |-> own, left |-> left]

Good(lg) == { i \in 1..Len(lg) : i \notin bad }           \* line 1 is never bad
UnitIdx(lg) == { i \in Good(lg) : lg[i].k \in {"LS", "C", "R"} }
TailIdx(lg) == MaxOf(UnitIdx(lg))
Q(lg) == lg[TailIdx(lg)].mark                             \* where the next unit starts
LastMark(lg) == lg[MaxOf(Good(lg))].mark
LastLine(lg) == lg[MaxOf(Good(lg))]
BadSince(lg) == \E i \in (TailIdx(lg) + 1)..Len(lg) : i \in bad
Shrunk(lg, h) == ~h.ok \/ h.trace # LastMark(lg).trace \/ N(h) < LastMark(lg).n
NeedUnann(lg, h) == Shrunk(lg, h) \/ BadSince(lg)
MkW(lg, h) == IF h.ok THEN Mk(h) ELSE LastMark(lg)        \* an undecodable head has no count: the writer keeps the last mark
GoodNonR(lg) == { i \in Good(lg) : lg[i].k # "R" }
Dangling(lg) == lg[MaxOf(GoodNonR(lg))].k = "O"
DTurn(lg) == MaxOf(GoodNonR(lg))

\* A line writer whose head already matches the after of a last line that is
\* an Unannounced reset appends no second one.
SameUnann(lg, h) ==
    LET l == LastLine(lg) IN l.k = "R" /\ l.cause = "unann" /\ l.mark = MkW(lg, h)
WillUnann(lg, h) == NeedUnann(lg, h) /\ ~SameUnann(lg, h)

\* Planted bug "withdrawn_by_count": the last line is an announced Reset with
\* before above after, and the head on that trace is at or above before. A
\* count cannot tell a head that was never changed from one that was changed
\* and grew back.
CountNow(lg, h) ==
    /\ Bug = "withdrawn_by_count"
    /\ h.ok
    /\ LET l == LastLine(lg)
       IN /\ l.k = "R" /\ l.cause \in {"cleared", "recovered"} /\ l.before.n > l.mark.n
          /\ h.trace = l.before.trace /\ N(h) >= l.before.n

\* What every line writer appends ahead of its own line. cl: the ids closed so
\* far (the Unannounced line stands for every one of them that no line names
\* and no hole covers: "what closed in between is not known").
Pre(lg, h, cl) ==
    IF WillUnann(lg, h)
    THEN << Line("R", "unann", 0, "none", LastMark(lg), MkW(lg, h), << >>,
                 cl \ (NamedIn(lg) \cup SpansIn(lg) \cup lostIds), {}, {}) >>
    ELSE IF ~NeedUnann(lg, h) /\ CountNow(lg, h)
    THEN << Line("R", "withdrawn", MaxOf(Good(lg)), "none", LastLine(lg).mark, LastLine(lg).before,
                 << >>, {}, {}, {}) >>
    ELSE << >>

OLine(lg, h, left) == Line("O", "none", 0, "none", MkW(lg, h), MkW(lg, h), << >>, {}, {}, left)

\* A Closed is a unit: its content is what closed between the last unit line's
\* mark and now. Its own slice starts at its Opened's baseline. When a Reset
\* lies after its Opened the baseline is a count of another head.
CLine(lg, h, t, outcome) ==
    LET q == Q(lg)
        inRange == h.ok /\ q.trace = h.trace
        resetAfter == \E r \in (t + 1)..Len(lg) : lg[r].k = "R"
        ownFrom == IF resetAfter THEN (IF OwnAfterReset = "own" THEN q.n ELSE N(h))
                   ELSE Max2(q.n, lg[t].mark.n)
    IN Line("C", "none", t, outcome, MkW(lg, h), MkW(lg, h),
            IF inRange THEN RangeP(h.bundles, q.n, N(h)) ELSE << >>, {},
            IF inRange THEN IdsFrom(h, ownFrom) ELSE {}, {})

\* Log_started is written when the file is absent or holds no complete line,
\* before an append.
LSLine(h) == Line("LS", "none", 0, "none", Mk(h), Mk(h), << >>, {}, {}, {})
Base0(h) == IF log = << >> THEN << LSLine(h) >> ELSE log

\* h: the head the lines were written from; cl: the ids closed by then.
AppendCore(lines, h, cl) ==
    LET lg0 == Base0(h)
    IN /\ Len(lg0) + Len(lines) <= MaxLines
       /\ log' = lg0 \o lines
       /\ logId' = IF log = << >> THEN logId + 1 ELSE logId
       /\ lostIds' = IF log = << >> THEN cl ELSE lostIds
       /\ seenShrink' = IF lines # << >> /\ lines[1].k = "R" /\ lines[1].cause = "unann"
                        THEN seenShrink \cup {Len(lg0) + 1} ELSE seenShrink
       /\ unseen' = IF lines = << >> THEN unseen ELSE FALSE

NoBase == [trace |-> 0, bundles |-> << >>, open |-> << >>, ok |-> TRUE]
NoPend == [kind |-> "none", j |-> 0, base |-> NoBase, line |-> 0]
Pending == pend.kind # "none"
\* Under the shared lock nothing of this Keeper runs while a reset is between its line and its head change.
Free == LockShared => ~Pending
Flag(f) == IF wit = {} THEN wit ELSE wit \cup f

\* ------------------------------------------------- where the reader stands

Synced == log # << >> /\ readerLogId = logId
PosLost == Synced /\ (misaligned \/ offset > Len(log) + 1)
ReaderOK == Synced /\ ~PosLost
IsUnann(i) == log[i].k = "R" /\ log[i].cause = "unann"
Stops == { i \in offset..Len(log) : i \in bad \/ IsUnann(i) }
StopAt == IF Stops = {} THEN Len(log) + 1 ELSE MinOf(Stops)
HasItem(i) == i \notin bad /\ log[i].k \in {"C", "R"} /\ log[i].pieces # << >>
ItemBefore == \E i \in offset..(StopAt - 1) : HasItem(i)

\* The sweep runs at process start, before any writer exists. It reads
\* turn_log_offset from the tail line of the commit log on disk. It uses the
\* offset only when that line names the turn-log file on disk and the offset
\* is a line start in it; otherwise every line is a root. A root line that
\* does not decode stops the pass with nothing removed.
RootIdx ==
    CASE Bug = "sweep_head_only" -> {}
      [] Bug = "sweep_offset_unchecked" -> offset..Len(log)
      [] OTHER -> IF ReaderOK THEN offset..Len(log) ELSE 1..Len(log)
SweepStops == \E i \in RootIdx \cap AllIdx : i \in bad
SweepKeep == IF SweepStops THEN objects ELSE BundleSet(head.bundles) \cup NamedBundles(RootIdx)

\* ------------------------------------------------- the turn path

\* Admission closes the head's open messages first (one save), then reads the
\* mark. When the save fails it goes on and the Opened is remembered in
\* closeFailedAt. The save is made before the append, so it stands also when
\* the append fails and the turn runs with no line.
Admit ==
    /\ up
    /\ turn = "none"
    /\ head.ok
    /\ Free
    /\ \E cs \in {"none", "saved", "failed"} :
         /\ (cs = "none") = (head.open = << >> \/ Bug = "no_close_at_admission")
         /\ cs = "failed" => budget.closefails > 0
         /\ LET h1 == IF cs = "saved" THEN CloseOpen(head) ELSE head
                cl1 == IF cs = "saved" THEN closedIds \cup IdsOfSeq(head.open) ELSE closedIds
                b1 == IF cs = "failed" THEN [budget EXCEPT !.closefails = @ - 1] ELSE budget
            IN /\ (cs = "saved" /\ unseen /\ ~Unseen /\ log # << >>) => Shrunk(log, h1)
               /\ head' = h1
               /\ objects' = IF cs = "saved" THEN objects \cup {head.open} ELSE objects
               /\ closedIds' = cl1
               /\ \/ LET lg0 == Base0(h1)
                         pre == Pre(lg0, h1, cl1)
                         lg1 == lg0 \o pre
                         cl == IF Dangling(lg1)
                               THEN << CLine(lg1, h1, DTurn(lg1), "close_missing") >>
                               ELSE << >>
                         at == Len(lg1) + Len(cl) + 1
                     IN /\ AppendCore(pre \o cl \o << OLine(lg1, h1, leftover) >>, h1, cl1)
                        /\ turn' = "line"
                        /\ turnLine' = at
                        /\ closeFailedAt' = IF cs = "failed" THEN closeFailedAt \cup {at} ELSE closeFailedAt
                        /\ budget' = b1
                  \/ /\ b1.fails > 0
                     /\ budget' = [b1 EXCEPT !.fails = @ - 1]
                     /\ turn' = "noline"
                     /\ turnLine' = 0
                     /\ UNCHANGED << lv, closeFailedAt >>
    /\ saved' = FALSE
    /\ UNCHANGED << nextMsg, openLost, gv, leftover, stopLines, bad, up, pend, droppedUnread, rvars,
                    badPurge, wit >>

\* An in-turn save: one more message is durable and open.
InTurnSave ==
    /\ up
    /\ turn \in {"line", "noline"}
    /\ ~saved
    /\ Free
    /\ head.ok
    /\ nextMsg <= MaxMsgs
    /\ Len(head.open) < MaxOpen
    /\ head' = [head EXCEPT !.open = Append(@, << nextMsg, 0 >>)]
    /\ nextMsg' = nextMsg + 1
    /\ UNCHANGED << objects, closedIds, openLost, lv, tv, gv, av, rvars, bad, up, pend, badPurge,
                    droppedUnread, wit, budget >>

\* One closing save of a turn: the open messages, and a new one when newmsg,
\* become one bundle.
CloseBundle(newmsg) ==
    /\ head.ok
    /\ newmsg => nextMsg <= MaxMsgs
    /\ LET b == head.open \o (IF newmsg THEN << << nextMsg, 0 >> >> ELSE << >>)
           h2 == [head EXCEPT !.bundles = Append(@, b), !.open = << >>]
       IN /\ b # << >>
          /\ (IF Unseen \/ ~unseen \/ log = << >> THEN TRUE ELSE Shrunk(log, h2))
          /\ head' = h2
          /\ objects' = objects \cup {b}
          /\ closedIds' = closedIds \cup IdsOfSeq(b)
    /\ nextMsg' = IF newmsg THEN nextMsg + 1 ELSE nextMsg
    /\ UNCHANGED openLost

Save ==
    /\ up
    /\ turn \in {"line", "noline"}
    /\ ~saved
    /\ Free
    /\ \E nm \in BOOLEAN : CloseBundle(nm)
    /\ saved' = TRUE
    /\ UNCHANGED << lv, turn, turnLine, gv, av, rvars, bad, up, pend, badPurge, droppedUnread, wit,
                    budget >>

\* A close outside the exit path while the process runs: a save that landed late.
LateSave ==
    /\ up
    /\ turn = "none"
    /\ budget.late > 0
    /\ Free
    /\ CloseBundle(TRUE)
    /\ budget' = [budget EXCEPT !.late = @ - 1]
    /\ UNCHANGED << lv, tv, gv, av, rvars, bad, up, pend, badPurge, droppedUnread, wit >>

\* What a turn leaves open when it ends or dies is a leftover.
LeftNow == leftover \cup IdsOfSeq(head.open)

\* The turn ends and its Closed is appended. With no closing save before it
\* (the save failed) the open messages stay open.
ExitOk ==
    /\ up
    /\ turn = "line"
    /\ Free
    /\ LET lg0 == Base0(head)
           pre == Pre(lg0, head, closedIds)
           lg1 == lg0 \o pre
       IN AppendCore(pre \o << CLine(lg1, head, turnLine, "completed") >>, head, closedIds)
    /\ turn' = "none"
    /\ turnLine' = 0
    /\ leftover' = LeftNow
    /\ UNCHANGED << hv, saved, bad, up, pend, gv, closeFailedAt, stopLines, droppedUnread, rvars,
                    badPurge, wit, budget >>

\* The exit append fails, or the turn had no Opened: nothing is written.
ExitSilent ==
    /\ up
    /\ \/ turn = "noline" /\ UNCHANGED budget
       \/ turn = "line" /\ budget.fails > 0 /\ budget' = [budget EXCEPT !.fails = @ - 1]
    /\ Free
    /\ turn' = "none"
    /\ turnLine' = 0
    /\ leftover' = LeftNow
    /\ UNCHANGED << hv, lv, saved, gv, closeFailedAt, stopLines, bad, up, pend, droppedUnread, rvars,
                    badPurge, wit >>

\* The process exits while a turn runs. What the turn saved in-turn stays open.
Die ==
    /\ up
    /\ turn \in {"line", "noline"}
    /\ ~Pending
    /\ budget.fails > 0
    /\ budget' = [budget EXCEPT !.fails = @ - 1]
    /\ turn' = IF turn = "line" THEN "deadline" ELSE "deadnoline"
    /\ up' = FALSE
    /\ leftover' = LeftNow
    /\ UNCHANGED << hv, lv, turnLine, saved, gv, closeFailedAt, stopLines, bad, pend, droppedUnread,
                    rvars, badPurge, wit >>

\* The process stops with no turn running.
Stop ==
    /\ up
    /\ turn = "none"
    /\ ~Pending
    /\ budget.stops > 0
    /\ budget' = [budget EXCEPT !.stops = @ - 1]
    /\ up' = FALSE
    /\ UNCHANGED << hv, lv, tv, gv, av, bad, pend, droppedUnread, rvars, badPurge, wit >>

\* Process start, in the code's order: the object sweep, checkpoint tail
\* recovery (tc: it closes the open tail or leaves it open), then the turn
\* log's process-start step: Log_started when the file is absent, and a
\* dangling Opened is closed. Only when it has that Closed to write does the
\* step close the head's open messages first; when that save fails it goes on.
Boot ==
    /\ ~up
    /\ ~Pending
    /\ \E tc \in BOOLEAN, cs \in {"none", "saved", "failed"} :
         /\ tc => (head.ok /\ head.open # << >>)
         /\ LET h1 == IF tc THEN CloseOpen(head) ELSE head
                cl1 == IF tc THEN closedIds \cup IdsOfSeq(head.open) ELSE closedIds
                swept == objects \cap SweepKeep
                lg0 == Base0(h1)
                dang == Dangling(lg0)
            IN /\ (cs = "none") = ~(dang /\ h1.ok /\ h1.open # << >>)
               /\ cs = "failed" => budget.closefails > 0
               /\ LET h2 == IF cs = "saved" THEN CloseOpen(h1) ELSE h1
                      cl2 == IF cs = "saved" THEN cl1 \cup IdsOfSeq(h1.open) ELSE cl1
                      pre == Pre(lg0, h2, cl2)
                      lg1 == lg0 \o pre
                      lines == IF dang
                               THEN pre \o << CLine(lg1, h2, DTurn(lg0), "process_exited") >>
                               ELSE << >>
                  IN /\ head' = h2
                     /\ objects' = swept \cup (IF tc THEN {head.open} ELSE {})
                                         \cup (IF cs = "saved" THEN {h1.open} ELSE {})
                     /\ closedIds' = cl2
                     /\ AppendCore(lines, h2, cl2)
                     /\ budget' = IF cs = "failed" THEN [budget EXCEPT !.closefails = @ - 1] ELSE budget
                     /\ wit' = Flag((IF cs = "saved" THEN {"start_step_closed_open"} ELSE {})
                                    \cup (IF swept # objects THEN {"sweep_removed_an_object"} ELSE {})
                                    \cup (IF log # << >> /\ ~ReaderOK /\ Bug = "none" /\ ~SweepStops
                                          THEN {"sweep_rooted_every_line"} ELSE {})
                                    \cup (IF SweepStops THEN {"sweep_stopped"} ELSE {}))
    /\ up' = TRUE
    /\ turn' = "none"
    /\ turnLine' = 0
    /\ UNCHANGED << nextMsg, openLost, saved, bad, pend, gv, av, droppedUnread, rvars, badPurge >>

\* Log_started at Keeper creation, with no turn running.
StartLog ==
    /\ up
    /\ log = << >>
    /\ turn = "none"
    /\ AppendCore(<< >>, head, closedIds)
    /\ UNCHANGED << hv, tv, gv, av, bad, up, pend, droppedUnread, rvars, badPurge, wit, budget >>

\* ------------------------------------------------- resets: one function, line first

NewHead(kind, j, h) ==
    CASE kind = "clear" ->
           \* the kept messages are saved open
           [h EXCEPT !.bundles = << >>,
                     !.open = IF ClearKeeps /\ h.bundles # << >> THEN << Flat(h.bundles)[1] >> ELSE << >>]
      [] kind = "recover" -> [h EXCEPT !.bundles = SubSeq(@, 1, j), !.open = << >>]
      [] kind = "clear_undec" -> [trace |-> h.trace, bundles |-> << >>, open |-> << >>, ok |-> TRUE]

\* The clear runs as the owner's exclusive maintenance child; the dashboard
\* purge only on a Keeper that is not registered; the CLI purge with no server.
ResetWhen(kind) ==
    \/ up /\ (IF LockShared THEN turn = "none" ELSE turn \in {"none", "line", "noline"})
    \/ ~up /\ kind = "recover"

ResetShape(kind, j, h) ==
    \/ kind = "clear" /\ h.ok /\ (h.bundles # << >> \/ h.open # << >>) /\ j = 0
    \/ kind = "recover" /\ h.ok /\ j \in 1..(Len(h.bundles) - 1)
    \/ kind = "clear_undec" /\ ~h.ok /\ j = 0

\* The reset function closes the head's open messages first (one save), then
\* writes its line from that head. When the save fails it refuses: no line and
\* no head change, so a refusal is no step here.
ResetAnnounce(kind, j) ==
    /\ ~Pending
    /\ budget.resets > 0
    /\ ResetWhen(kind)
    /\ LET closes == head.ok /\ head.open # << >> /\ Bug # "no_close_before_reset"
           h1 == IF closes THEN CloseOpen(head) ELSE head
           cl1 == IF closes THEN closedIds \cup IdsOfSeq(head.open) ELSE closedIds
           lg0 == Base0(h1)
           pre == IF kind = "clear_undec" THEN << >> ELSE Pre(lg0, h1, cl1)
           lg1 == lg0 \o pre
           new == NewHead(kind, j, h1)
           ll == LastLine(lg1)
           rl == IF kind = "clear_undec"
                 \* the clear of an undecodable head appends Unannounced itself; not a second one with the same after
                 THEN (IF ll.k = "R" /\ ll.cause = "unann" /\ ll.mark = Mk(new) THEN << >>
                       ELSE << Line("R", "unann", 0, "none", LastMark(lg1), Mk(new), << >>,
                                    cl1 \ (NamedIn(lg1) \cup SpansIn(lg1) \cup lostIds), {}, {}) >>)
                 ELSE << Line("R", IF kind = "clear" THEN "cleared" ELSE "recovered", 0, "none",
                              Mk(h1), Mk(new),
                              IF Q(lg1).trace = h1.trace
                              THEN RangeP(h1.bundles, Q(lg1).n, N(h1)) ELSE << >>, {}, {}, {}) >>
       IN /\ ResetShape(kind, j, h1)
          /\ AppendCore(pre \o rl, h1, cl1)
          /\ head' = h1
          /\ objects' = IF closes THEN objects \cup {head.open} ELSE objects
          /\ closedIds' = cl1
          /\ pend' = [kind |-> kind, j |-> j, base |-> h1,
                      line |-> IF kind = "clear_undec" THEN 0 ELSE Len(lg1) + 1]
          /\ wit' = Flag(IF closes THEN {"reset_closed_open"} ELSE {})
    /\ budget' = [budget EXCEPT !.resets = @ - 1]
    /\ UNCHANGED << nextMsg, openLost, tv, bad, up, gv, av, droppedUnread, rvars, badPurge >>

\* The head change: a compare-and-swap on the head the line was written from.
\* No object is deleted here: the sweep runs at process start.
ResetApply ==
    /\ Pending
    /\ head = pend.base
    /\ LET new == NewHead(pend.kind, pend.j, head)
       IN /\ head' = new
          /\ droppedUnread' = (droppedUnread
                               \/ (head.ok /\ ((IdsFrom(head, 0) \ IdsFrom(new, 0)) \ delivered) # {}))
          /\ openLost' = openLost \cup (IdsOfSeq(head.open) \ IdsOfSeq(new.open))
          \* second-reading cause 1: a message a clear keeps is closed again by the next save
          /\ rereadKept' = rereadKept \cup (IF pend.kind = "clear" THEN IdsOfSeq(new.open) ELSE {})
    /\ happened' = IF pend.line > 0 THEN happened \cup {pend.line} ELSE happened
    /\ pend' = NoPend
    /\ UNCHANGED << objects, nextMsg, closedIds, lv, tv, notHap, rereadNotMade, av, bad, up, rvars,
                    badPurge, wit, budget >>

\* second-reading cause 2: the head change was not made. The next unit starts
\* at the line's after, so positions after+1 .. before are named again.
NotMade ==
    /\ notHap' = IF pend.line > 0 THEN notHap \cup {pend.line} ELSE notHap
    /\ rereadNotMade' =
         IF pend.line > 0
         THEN rereadNotMade \cup { Flat(pend.base.bundles)[x][1]
                                   : x \in (log[pend.line].mark.n + 1)..log[pend.line].before.n }
         ELSE rereadNotMade

\* The head change returns an error: the compare-and-swap found another head,
\* or a write failed. The reset function has no error branch.
ResetFail ==
    /\ Pending
    /\ \/ head # pend.base /\ UNCHANGED budget
       \/ head = pend.base /\ budget.chgfails > 0 /\ budget' = [budget EXCEPT !.chgfails = @ - 1]
    /\ NotMade
    /\ pend' = NoPend
    /\ UNCHANGED << hv, lv, tv, happened, rereadKept, av, bad, up, droppedUnread, rvars, badPurge, wit >>

\* The process exits between the line and the head change.
CrashBetween ==
    /\ Pending
    /\ budget.crashes > 0
    /\ budget' = [budget EXCEPT !.crashes = @ - 1]
    /\ NotMade
    /\ pend' = NoPend
    /\ up' = FALSE
    /\ turn' = CASE turn = "line" -> "deadline" [] turn = "noline" -> "deadnoline" [] OTHER -> turn
    /\ leftover' = IF turn \in {"line", "noline"} THEN LeftNow ELSE leftover
    /\ UNCHANGED << hv, lv, turnLine, saved, happened, rereadKept, closeFailedAt, stopLines, bad,
                    droppedUnread, rvars, badPurge, wit >>

\* ------------------------------------------------- outside the product, and Keeper creation

\* A head shrunk by hand with no line (a stated limit).
HandShrink(kind, j) ==
    /\ budget.hand > 0
    /\ ~Pending
    /\ log # << >>
    /\ turn \in {"none", "line", "noline"}
    /\ kind \in {"clear", "recover"}
    /\ ResetShape(kind, j, head)
    /\ LET new == [NewHead(kind, j, head) EXCEPT !.open = << >>]
       IN /\ (Unseen \/ Shrunk(log, new))
          /\ head' = new
          /\ openLost' = openLost \cup IdsOfSeq(head.open)
    /\ unseen' = TRUE
    /\ budget' = [budget EXCEPT !.hand = @ - 1]
    /\ UNCHANGED << objects, nextMsg, closedIds, log, logId, lostIds, seenShrink, tv, gv, av, bad, up,
                    pend, droppedUnread, rvars, badPurge, wit >>

\* The Keeper is made again: a new trace beside the old turn log. No producer
\* line. Keeper creation writes Log_started when the file is absent.
Recreate ==
    /\ budget.recreates > 0
    /\ ~Pending
    /\ turn = "none"
    /\ LET new == [trace |-> head.trace + 1, bundles |-> << >>, open |-> << >>, ok |-> TRUE]
       IN /\ head' = new
          /\ openLost' = openLost \cup IdsOfSeq(head.open)
          /\ IF log = << >>
             THEN /\ log' = << LSLine(new) >>
                  /\ logId' = logId + 1
                  /\ lostIds' = closedIds
             ELSE UNCHANGED << log, logId, lostIds >>
    /\ budget' = [budget EXCEPT !.recreates = @ - 1]
    /\ UNCHANGED << objects, nextMsg, closedIds, seenShrink, unseen, tv, gv, av, bad, up, pend,
                    droppedUnread, rvars, badPurge, wit >>

\* A Keeper stop that removes the session, the Keeper's meta kept: the head
\* and every bundle of the trace are gone, the turn log stays. The stop
\* appends Reset { Unannounced; before = the last mark; after = the empty
\* mark of that trace } first and removes only when the append went in (when
\* it does not fit, the step is not taken). The line is written also when the
\* last line already is an Unannounced reset with that after: a turn with no
\* Opened may have closed messages since (planted bug "stop_line_deduped").
RemoveSession ==
    /\ budget.removes > 0
    /\ up
    /\ turn = "none"
    /\ ~Pending
    /\ LET lg0 == Base0(head)
           empty == [trace |-> head.trace, n |-> 0]
           ll == LastLine(lg0)
           same == Bug = "stop_line_deduped" /\ ll.k = "R" /\ ll.cause = "unann" /\ ll.mark = empty
           line == Line("R", "unann", 0, "none", LastMark(lg0), empty, << >>,
                        closedIds \ (NamedIn(lg0) \cup SpansIn(lg0) \cup lostIds), {}, {})
       IN IF Bug = "remove_session_no_line"
          THEN /\ openLost' = openLost \cup IdsOfSeq(head.open)
               /\ UNCHANGED << lv, stopLines >>
          ELSE /\ AppendCore(IF same THEN << >> ELSE << line >>, head, closedIds)
               /\ stopLines' = stopLines \cup {IF same THEN Len(lg0) ELSE Len(lg0) + 1}
               /\ UNCHANGED openLost
    /\ head' = [trace |-> head.trace, bundles |-> << >>, open |-> << >>, ok |-> TRUE]
    /\ objects' = {}
    /\ budget' = [budget EXCEPT !.removes = @ - 1]
    /\ UNCHANGED << nextMsg, closedIds, tv, gv, leftover, closeFailedAt, bad, up, pend, droppedUnread,
                    rvars, badPurge, wit >>

BreakHead ==
    /\ budget.breaks > 0
    /\ ~Pending
    /\ head.ok
    /\ log # << >>
    /\ head' = [head EXCEPT !.ok = FALSE]
    /\ budget' = [budget EXCEPT !.breaks = @ - 1]
    /\ UNCHANGED << objects, nextMsg, closedIds, openLost, lv, tv, gv, av, bad, up, pend, droppedUnread,
                    rvars, badPurge, wit >>

\* The undecodable head is put back by hand.
HandRestore ==
    /\ ~head.ok
    /\ ~Pending
    /\ head' = [head EXCEPT !.ok = TRUE]
    /\ UNCHANGED << objects, nextMsg, closedIds, openLost, lv, tv, gv, av, bad, up, pend, droppedUnread,
                    rvars, badPurge, wit, budget >>

\* The turn log file is deleted (fresh state of this file alone).
DeleteLog ==
    /\ budget.replaces > 0
    /\ log # << >>
    /\ ~Pending
    /\ head.ok
    /\ log' = << >>
    /\ bad' = {}
    /\ turn' = CASE turn = "line" -> "noline" [] turn = "deadline" -> "deadnoline" [] OTHER -> turn
    /\ turnLine' = 0
    /\ lostIds' = closedIds
    /\ seenShrink' = {}
    /\ unseen' = FALSE
    /\ passedTo' = 0
    /\ unknownRec' = {}
    /\ lineSkipRec' = {}
    /\ happened' = {}
    /\ notHap' = {}
    /\ closeFailedAt' = {}
    /\ stopLines' = {}
    /\ budget' = [budget EXCEPT !.replaces = @ - 1]
    /\ UNCHANGED << hv, logId, saved, rereadKept, rereadNotMade, leftover, up, pend, droppedUnread,
                    offset, covered, readerLogId, misaligned, staleCov, delivered, missingRec, skipped,
                    acct, excused, dupIds, badSkip, badPurge, wit >>

\* The file is cut, or an older copy is restored, under the same id. Lines c+1.. are gone.
CutLog(c) ==
    /\ budget.cuts > 0
    /\ log # << >>
    /\ ~Pending
    /\ c \in 1..(Len(log) - 1)
    /\ log' = SubSeq(log, 1, c)
    /\ bad' = bad \cap 1..c
    /\ seenShrink' = seenShrink \cap 1..c
    /\ happened' = happened \cap 1..c
    /\ notHap' = notHap \cap 1..c
    /\ closeFailedAt' = closeFailedAt \cap 1..c
    /\ stopLines' = stopLines \cap 1..c
    /\ IF turnLine > c
       THEN /\ turn' = CASE turn = "line" -> "noline" [] turn = "deadline" -> "deadnoline" [] OTHER -> turn
            /\ turnLine' = 0
       ELSE UNCHANGED << turn, turnLine >>
    /\ misaligned' = (misaligned \/ (readerLogId = logId /\ c < offset - 1 /\ ~RegrowAligned))
    /\ passedTo' = Min2(passedTo, c)
    /\ unknownRec' = unknownRec \cap 1..c
    /\ lineSkipRec' = lineSkipRec \cap 1..c
    /\ budget' = [budget EXCEPT !.cuts = @ - 1]
    /\ UNCHANGED << hv, logId, lostIds, unseen, saved, rereadKept, rereadNotMade, leftover, up, pend,
                    droppedUnread, offset, covered, readerLogId, staleCov, delivered, missingRec,
                    skipped, acct, excused, dupIds, badSkip, badPurge, wit >>

\* A line stops decoding (a shape change of the build, or damage).
CorruptLine(i) ==
    /\ budget.bads > 0
    /\ log # << >>
    /\ i \in 2..Len(log)
    /\ i \notin bad
    /\ bad' = bad \cup {i}
    /\ budget' = [budget EXCEPT !.bads = @ - 1]
    /\ UNCHANGED << hv, lv, tv, gv, av, up, pend, droppedUnread, rvars, badPurge, wit >>

\* ------------------------------------------------- the reader's acts

\* The reader orders its faults: id, then position, then decode.
Fault ==
    IF log = << >> THEN "no_file"
    ELSE IF readerLogId # logId THEN "replaced"
    ELSE IF PosLost THEN "position"
    ELSE IF StopAt <= Len(log) /\ StopAt \in bad /\ ~ItemBefore THEN "line"
    ELSE "none"

Unread ==
    \/ /\ log # << >>
       /\ \E i \in offset..Len(log) :
            \/ i \in bad
            \/ HasItem(i)
            \/ IsUnann(i)
            \/ (i = offset /\ (readerLogId # logId \/ misaligned))
    \/ log = << >>
    \/ readerLogId # logId
    \/ misaligned
    \/ offset > Len(log) + 1

Passed == IF ReaderOK THEN 2..Min2(offset - 1, Len(log)) ELSE {}
Reread == rereadKept \cup rereadNotMade

\* One read commit covers every unit from the offset through line u.
Commit(u) ==
    /\ up
    /\ ReaderOK
    /\ Unread
    /\ u \in offset..(StopAt - 1)
    /\ HasItem(u)
    /\ LET units == { i \in offset..u : HasItem(i) }
           T == Occ(log, units)
           readable(t) == log[t[1]].pieces[t[2]].b \in objects
           got == { IdOf(t) : t \in { t \in T : readable(t) } }
           miss == { IdOf(t) : t \in { t \in T : ~readable(t) } }
           twice == { IdOf(t1) : t1 \in { t1 \in T : \E t2 \in T : t1 # t2 /\ IdOf(t1) = IdOf(t2) } }
       IN /\ delivered' = delivered \cup got
          /\ missingRec' = missingRec \cup miss
          /\ dupIds' = dupIds \cup ((got \cap delivered) \ (excused \cup Reread)) \cup (twice \ Reread)
    /\ offset' = u + 1
    /\ covered' = log[u].mark
    /\ passedTo' = Max2(passedTo, u)
    /\ staleCov' = FALSE
    /\ UNCHANGED << hv, lv, tv, gv, av, bad, up, pend, droppedUnread, wit, readerLogId, misaligned,
                    unknownRec, lineSkipRec, skipped, acct, excused, badSkip, badPurge, budget >>

\* An Unannounced line with no unit with an item before it is passed by its own commit, Skip (Unknown_span).
CommitUnknown ==
    /\ up
    /\ ReaderOK
    /\ Unread
    /\ StopAt <= Len(log)
    /\ StopAt \notin bad
    /\ ~ItemBefore
    /\ unknownRec' = unknownRec \cup {StopAt}
    /\ acct' = acct \cup log[StopAt].span
    /\ offset' = StopAt + 1
    /\ covered' = log[StopAt].mark
    /\ passedTo' = Max2(passedTo, StopAt)
    /\ staleCov' = FALSE
    /\ UNCHANGED << hv, lv, tv, gv, av, bad, up, pend, droppedUnread, wit, readerLogId, misaligned,
                    delivered, missingRec, lineSkipRec, skipped, excused, dupIds, badSkip, badPurge,
                    budget >>

\* The operator's Skip_line.
SkipLineOk == Fault = "line"

SkipLine ==
    /\ up
    /\ SkipLineOk
    /\ LET at == StopAt
           units == { i \in offset..(at - 1) : i \notin bad /\ log[i].k \in {"C", "R"} }
       IN /\ lineSkipRec' = lineSkipRec \cup {at}
          /\ acct' = acct \cup LineIds(at) \cup log[at].span
          /\ offset' = at + 1
          /\ covered' = IF units = {} \/ ~ReaderOK THEN covered ELSE log[MaxOf(units)].mark
          /\ passedTo' = Max2(passedTo, at)
          /\ badSkip' = (badSkip \/ ~(ReaderOK /\ at \in bad))
    /\ readerLogId' = logId
    /\ misaligned' = FALSE
    /\ staleCov' = TRUE
    /\ UNCHANGED << hv, lv, tv, gv, av, bad, up, pend, droppedUnread, wit, delivered, missingRec,
                    unknownRec, skipped, excused, dupIds, badPurge, budget >>

\* The operator's Restart_reading.
RestartOk == log # << >> /\ (readerLogId # logId \/ misaligned \/ offset > Len(log) + 1)

RestartReading ==
    /\ up
    /\ RestartOk
    /\ excused' = IF readerLogId = logId THEN excused \cup delivered ELSE excused
    /\ skipped' = skipped \cup (lostIds \ delivered)
    /\ readerLogId' = logId
    /\ offset' = 2
    /\ covered' = log[1].mark
    /\ misaligned' = FALSE
    /\ staleCov' = FALSE
    /\ unknownRec' = {}
    /\ lineSkipRec' = {}
    /\ UNCHANGED << hv, lv, tv, gv, av, bad, up, pend, droppedUnread, wit, passedTo, delivered,
                    missingRec, acct, dupIds, badSkip, badPurge, budget >>

\* ------------------------------------------------- the rewrite-only purge

Accounted == delivered \cup missingRec \cup skipped \cup acct

\* The dashboard purge runs only on a Keeper that is not registered; the CLI purge with no server.
PurgeWhen == (up /\ turn = "none") \/ ~up

\* The purge does not read the Librarian. It is a line writer for a head on
\* another trace or below the mark (Unannounced first), and then rewrites
\* message i of the message list, i at or below the mark of the last unit
\* line. Its save keeps the turns before the first changed message and makes
\* one bundle of everything after them, open messages included, byte-exact.
\* No object is deleted. When the turn log cannot be appended the purge
\* rewrites nothing (the step is not taken).
Purge(i) ==
    /\ budget.purges > 0
    /\ ~Pending
    /\ head.ok
    /\ log # << >>
    /\ PurgeWhen
    /\ LET bs == head.bundles
           flat == Msgs(head)
           pre == Pre(log, head, closedIds)
           lgL == log \o pre
           m == Q(lgL)
           bound == IF m.trace = head.trace THEN Min2(m.n, Len(flat)) ELSE 0
           top == CASE Bug = "purge_above_mark" -> N(head)
                    [] Bug = "purge_open" -> Len(flat)
                    [] OTHER -> bound
           tOf == IF i <= N(head)
                  THEN CHOOSE x \in 1..Len(bs) : Start(bs, x) < i /\ i <= End(bs, x)
                  ELSE Len(bs) + 1
       IN /\ i \in 1..top
          /\ flat[i][2] = 0
          /\ \E s \in {1, tOf} :
               LET from == Start(bs, s)
                   merged == SubSeq(flat, from + 1, i - 1) \o << << flat[i][1], 1 >> >>
                             \o SubSeq(flat, i + 1, Len(flat))
                   h2 == [head EXCEPT !.bundles = SubSeq(bs, 1, s - 1) \o << merged >>, !.open = << >>]
               IN /\ head' = h2
                  /\ objects' = objects \cup {merged}
                  /\ closedIds' = closedIds \cup IdsOfSeq(head.open)
                  /\ AppendCore(pre, head, closedIds)
                  /\ wit' = Flag(IF head.open # << >> THEN {"purge_closed_open"} ELSE {})
          /\ badPurge' = (badPurge
                          \/ flat[i][1] \notin (NamedIn(lgL) \cup SpansIn(lgL) \cup lostIds))
    /\ budget' = [budget EXCEPT !.purges = @ - 1]
    /\ UNCHANGED << nextMsg, openLost, tv, gv, av, bad, up, pend, droppedUnread, rvars >>

\* ------------------------------------------------- spec

Mark0 == [trace |-> 1, n |-> 0]

Init ==
    /\ head = [trace |-> 1, bundles |-> << >>, open |-> << >>, ok |-> TRUE]
    /\ objects = {}
    /\ log = << Line("LS", "none", 0, "none", Mark0, Mark0, << >>, {}, {}, {}) >>
    /\ logId = 1
    /\ bad = {}
    /\ up = TRUE
    /\ turn = "none"
    /\ turnLine = 0
    /\ saved = FALSE
    /\ pend = NoPend
    /\ offset = 2
    /\ covered = Mark0
    /\ readerLogId = 1
    /\ misaligned = FALSE
    /\ passedTo = 1
    /\ staleCov = FALSE
    /\ delivered = {}
    /\ missingRec = {}
    /\ unknownRec = {}
    /\ lineSkipRec = {}
    /\ skipped = {}
    /\ acct = {}
    /\ excused = {}
    /\ dupIds = {}
    /\ nextMsg = 1
    /\ closedIds = {}
    /\ openLost = {}
    /\ seenShrink = {}
    /\ unseen = FALSE
    /\ badPurge = FALSE
    /\ badSkip = FALSE
    /\ droppedUnread = FALSE
    /\ lostIds = {}
    /\ happened = {}
    /\ notHap = {}
    /\ rereadKept = {}
    /\ rereadNotMade = {}
    /\ leftover = {}
    /\ closeFailedAt = {}
    /\ stopLines = {}
    /\ budget = [purges |-> MaxPurges, resets |-> MaxResets, fails |-> MaxFails,
                 closefails |-> MaxCloseFails, late |-> MaxLate,
                 chgfails |-> MaxChgFails, crashes |-> MaxCrashes, stops |-> MaxStops,
                 removes |-> MaxRemoves, replaces |-> MaxReplaces, cuts |-> MaxCuts, bads |-> MaxBad,
                 recreates |-> MaxRecreates, breaks |-> MaxBreaks, hand |-> MaxHand]

\* Witness flags are recorded only in runs that start with them on (SpecWit).
InitWit == Init /\ wit = {"on"}
InitPlain == Init /\ wit = {}

Kinds == {"clear", "recover", "clear_undec"}

Next ==
    \/ Admit \/ InTurnSave \/ Save \/ LateSave \/ ExitOk \/ ExitSilent \/ Die \/ Stop \/ Boot \/ StartLog
    \/ \E kind \in Kinds, j \in 0..MaxMsgs : ResetAnnounce(kind, j)
    \/ ResetApply \/ ResetFail \/ CrashBetween
    \/ \E kind \in Kinds, j \in 0..MaxMsgs : HandShrink(kind, j)
    \/ Recreate \/ RemoveSession \/ BreakHead \/ HandRestore
    \/ DeleteLog
    \/ \E c \in 1..MaxLines : CutLog(c)
    \/ \E i \in 2..MaxLines : CorruptLine(i)
    \/ \E i \in 1..MaxMsgs : Purge(i)
    \/ \E u \in 2..MaxLines : Commit(u)
    \/ CommitUnknown \/ SkipLine \/ RestartReading

Spec == InitPlain /\ [][Next]_vars
SpecWit == InitWit /\ [][Next]_vars

\* ------------------------------------------------- properties

TypeOK ==
    /\ turn \in {"none", "line", "noline", "deadline", "deadnoline"}
    /\ Len(log) \in 0..MaxLines
    /\ nextMsg \in 1..(MaxMsgs + 1)
    /\ \A i \in AllIdx : log[i].k \in {"LS", "O", "C", "R"}
    /\ log # << >> => log[1].k = "LS" /\ 1 \notin bad
    /\ ReaderOK => offset \in 2..(Len(log) + 1)
    /\ pend.kind \in {"none", "clear", "recover", "clear_undec"}
    /\ Len(head.open) <= MaxOpen + 1
    /\ ~up => turn \in {"none", "deadline", "deadnoline"}

Spans == SpansIn(log)

\* What the next unit line will name, by the rule the next line writer runs.
OwedNow ==
    IF log = << >> THEN closedIds
    ELSE IF NeedUnann(log, head) THEN (IF SameUnann(log, head) THEN {} ELSE closedIds)
    ELSE IF CountNow(log, head) THEN IdsFrom(head, LastLine(log).before.n)
    ELSE IF Q(log).trace = head.trace THEN IdsFrom(head, Q(log).n)
    ELSE {}

\* No line writer starts a unit above a closed message that no unit and no
\* recorded hole covers.
NoSilentSkip == closedIds \subseteq (LineIdsAll \cup Spans \cup lostIds \cup OwedNow)

\* The same for the messages the head holds now.
NoSkipOfHeadMessage ==
    (head.ok /\ log # << >>) => IdsFrom(head, 0) \subseteq (LineIdsAll \cup Spans \cup lostIds \cup OwedNow)

\* No message leaves a head while still open, except by a stop whose line recorded the span.
NoOpenLost == openLost = {}

NamedCount(id) == Cardinality({ t \in Occ(log, AllIdx) : IdOf(t) = id })
\* Every message ever closed in a head is named by exactly one unit, or lies
\* in a span a line records as unknown, or went with a lost file, or is owed
\* to the next unit. Named twice only for one of the two stated causes.
EveryClosedInOneUnit ==
    \A id \in closedIds :
        LET n == NamedCount(id)
        IN \/ n = 1
           \/ n = 0 /\ id \in (Spans \cup lostIds \cup OwedNow)
           \/ n >= 2 /\ id \in Reread
\* No message is named twice (no excuse): holds when neither cause can occur.
NoDoubleName ==
    \A t1, t2 \in Occ(log, AllIdx) : t1 # t2 => IdOf(t1) # IdOf(t2)

\* A message that was a leftover when a turn was admitted is not in that
\* turn's own slice, unless the admission could not close it first.
LeftoverNotBorrowed ==
    \A i \in AllIdx :
        log[i].k = "C" =>
            \/ log[i].own \cap log[log[i].turn].left = {}
            \/ log[i].turn \in closeFailedAt

\* Log_started ( Reset | Opened Reset* Closed )* [ Opened Reset* ]
RECURSIVE Gram(_, _, _)
Gram(lg, i, st) ==
    IF i > Len(lg) THEN TRUE
    ELSE CASE lg[i].k = "LS" -> FALSE
           [] lg[i].k = "R" -> Gram(lg, i + 1, st)
           [] lg[i].k = "O" -> st = 0 /\ Gram(lg, i + 1, i)
           [] lg[i].k = "C" -> st # 0 /\ lg[i].turn = st /\ Gram(lg, i + 1, 0)
OnlyWrittenOrder == log # << >> => (log[1].k = "LS" /\ Gram(log, 2, 0))

\* What no commit ever passed is on disk as the line named it. A stop that
\* removes the session takes the content of the lines before its own line.
UnreadIdx == (passedTo + 1)..Len(log)
UnreadOnDisk ==
    \A t \in Occ(log, UnreadIdx) :
        log[t[1]].pieces[t[2]].b \in objects \/ (\E s \in stopLines : s >= t[1])
\* The first line that names a message names it as it was first written: a
\* purge never makes a unit read rewritten bytes.
FirstNamedAsWritten ==
    \A t \in Occ(log, AllIdx) :
        MsgOf(t)[2] # 0 =>
            \E t2 \in Occ(log, AllIdx) : IdOf(t2) = IdOf(t) /\ MsgOf(t2)[2] = 0 /\ t2[1] < t[1]
UnreadReadable == UnreadOnDisk /\ FirstNamedAsWritten
\* A purge rewrote only what a line named or a recorded hole covered.
PurgeOnlyRewritesNamed == ~badPurge
\* For runs with a cut or a replaced file: content no commit accounted for is in the store.
UndeliveredReadable ==
    \A t \in Occ(log, UnreadIdx) :
        IdOf(t) \notin Accounted =>
            (log[t[1]].pieces[t[2]].b \in objects \/ (\E s \in stopLines : s >= t[1]))

\* The closed count of a head goes down only by a head change after its Reset
\* line, a stop that removes the session, or an edit from outside the product.
\* So no closing save of a line writer makes a mark shrink.
ShrinkOnlyByNamedPaths ==
    [][ (head'.trace = head.trace /\ N(head') < N(head)) =>
            \/ Pending
            \/ budget'.removes < budget.removes
            \/ budget'.hand < budget.hand ]_vars
\* No Opened and no Closed carries a mark below the line before it.
MarksOnlyShrinkAtReset ==
    \A i \in 2..Len(log) :
        (i \notin bad /\ (i - 1) \notin bad /\ log[i].k \in {"O", "C"}
         /\ log[i].mark.trace = log[i - 1].mark.trace) => log[i].mark.n >= log[i - 1].mark.n
\* The head holds no message twice: no two saves closed the same message.
HeadHoldsEachOnce ==
    \A x, y \in 1..Len(Msgs(head)) : x # y => Msgs(head)[x][1] # Msgs(head)[y][1]

NoDoubleRead == dupIds = {}
PassedAccounted ==
    \A i \in Passed : i \in lineSkipRec \/ LineIds(i) \subseteq (delivered \cup missingRec)
UnknownRecorded ==
    \A i \in seenShrink : i \in Passed => i \in (unknownRec \cup lineSkipRec)
SkipRecorded == ReaderOK => lostIds \subseteq (delivered \cup missingRec \cup skipped)
CutOrReplacedFound ==
    (log = << >> \/ readerLogId # logId \/ misaligned \/ offset > Len(log) + 1) => Unread
QuietMeansRead ==
    ~Unread => /\ \A i \in 2..Len(log) :
                    i \in lineSkipRec \/ LineIds(i) \subseteq (delivered \cup missingRec \cup acct)
               /\ lostIds \subseteq (delivered \cup missingRec \cup skipped)
CanGoOn ==
    \/ ReaderOK /\ ItemBefore
    \/ ReaderOK /\ StopAt <= Len(log) /\ StopAt \notin bad /\ ~ItemBefore
    \/ SkipLineOk
    \/ RestartOk
NeverStuckWithFile == (Unread /\ log # << >>) => CanGoOn
SkipLineOnlyUndecodable == ~badSkip

\* ------------------------------------------------- witnesses (each must be violated)

\* an announced head change that was not made, the messages named a second time, and both readings passed
W_NoSecondReading ==
    ~(ReaderOK /\ ~Unread /\ \E id \in rereadNotMade : NamedCount(id) >= 2 /\ id \in delivered)
\* a leftover named by the Closed of a later turn outside its own slice (no task), the admission's save having succeeded
W_NoLeftoverUnattributed ==
    ~(\E i \in AllIdx : /\ log[i].k = "C"
                        /\ log[i].turn \notin closeFailedAt
                        /\ ((LineIds(i) \ log[i].own) \cap log[log[i].turn].left) # {})
\* the excuse is used: the admission's save failed and the turn's own slice holds the leftover
W_NoBorrowExcused ==
    ~(\E i \in AllIdx : /\ log[i].k = "C"
                        /\ log[i].turn \in closeFailedAt
                        /\ (log[i].own \cap log[log[i].turn].left) # {})
\* a stop's line, and the reader's Skip of an unknown span for it
W_NoStopLineSkip == stopLines \cap unknownRec = {}
\* the covered mark rests at the after of a Reset whose head change was not made while a whole turn runs
W_NoCoveredRestsAtAfter ==
    ~(\E r \in notHap : /\ r \in AllIdx /\ ReaderOK /\ offset > r /\ ~Unread
                        /\ covered = log[r].mark /\ covered.n < log[r].before.n
                        /\ turn = "line" /\ saved /\ head.ok /\ N(head) > log[r].before.n)
\* and it leaves that place when the second reading is passed
W_NoRestEnds ==
    ~(\E r \in notHap : /\ r \in AllIdx /\ ReaderOK /\ offset > r + 1 /\ ~Unread
                        /\ covered.trace = log[r].before.trace /\ covered.n >= log[r].before.n
                        /\ \E id \in rereadNotMade : NamedCount(id) >= 2)
W_NoNotMade == notHap = {}
W_NoUnknownRecorded == unknownRec = {}
W_NoMissingRecorded == missingRec = {}
W_NoCloseMissing == \A i \in AllIdx : log[i].outcome # "close_missing"
W_NoBootClose == \A i \in AllIdx : log[i].outcome # "process_exited"
\* flags recorded by the actions (SpecWit only)
W_NoResetClosedOpen == "reset_closed_open" \notin wit
W_NoStartStepClosedOpen == "start_step_closed_open" \notin wit
W_NoPurgeClosedOpen == "purge_closed_open" \notin wit
W_NoSweepRemoved == "sweep_removed_an_object" \notin wit
W_NoSweepRootedEveryLine == "sweep_rooted_every_line" \notin wit
W_NoSweepStopped == "sweep_stopped" \notin wit

====
