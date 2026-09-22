---- MODULE LibrarianRead ----
\* Which atoms a Librarian round reads, against the writers of the turn-boundary
\* log (RFC librarian-lifecycle 4.4 and 4.6).
\*
\* Mirrors: lib/keeper/keeper_librarian_range.ml (the rules this spec varies)
\*          lib/keeper/keeper_turn_boundaries.ml (the lines it reads)
\*          lib/keeper/keeper_librarian_progress.ml (the position it writes)
\*
\* A finished Keeper turn appends a line saying where the saved history ended.
\* A round of the Librarian reads the lines, loads the checkpoint, picks the
\* atoms it has not read, and writes back where it got to. The rules must leave
\* no atom behind: a read position may not pass an atom no round delivered.
\*
\* Every atom digest is taken to collide, which is the worst case for the rules
\* that compare a line against the loaded checkpoint (4.4 rows 2a and 5): with
\* one digest, "this line describes the history I loaded" is just
\* end_atom <= atom count, so a line of an older history can pass.
\*
\* An append that fails needs no action of its own: a turn that finished its
\* saves and left no line is the same state as a turn that died after them,
\* which TurnDie already reaches.
\*
\* The clean model is explored to the end, so its state count is the same on
\* every run. A buggy model stops at the first violation, and what a parallel
\* search had explored by then is not: run those with -workers 1 for a state
\* count that repeats. Each -buggy cfg switches one rule off and has to violate
\* the invariant, and scripts/tla-check.sh runs all of them, so what each one
\* costs is in that run and not in this comment, which cannot be kept true.
\*
\* Not modelled: how much of what is unread one round takes (row 3a) and which
\* trace the caller reads (row 1b). Neither decides whether an atom is lost --
\* they decide how many rounds it takes and how many rounds stop for nothing.

EXTENDS TLC, Integers, Sequences, FiniteSets

CONSTANTS
    MaxTurns,       \* turns that may start
    MaxSaves,       \* checkpoint saves within one turn
    MaxClears,      \* masc_keeper_clear runs
    MaxBad          \* appends that land as bytes the decoder refuses

ASSUME Bounds ==
    /\ MaxTurns \in Nat /\ MaxTurns >= 1
    /\ MaxSaves \in Nat /\ MaxSaves >= 1
    /\ MaxClears \in Nat
    /\ MaxBad \in Nat

NoTurn == [none |-> TRUE]
NoProgress == [none |-> TRUE]

RestartLine == [kind |-> "HR", fresh |-> FALSE, end |-> 0]
RefusedLine == [kind |-> "BAD", fresh |-> FALSE, end |-> 0]

VARIABLES
    hist,       \* the saved checkpoint: the atom ids it holds, in order
    ckTurns,    \* the turn count the store has, which decides a stale save
    log,        \* the turn-boundary lines, in the order they reached the file
    turn,       \* the running turn, or NoTurn (turns of one keeper are serial)
    progress,   \* the read position [end, seen], or NoProgress
    readIds,    \* atom ids some round delivered to the Librarian
    nextId,
    budget,     \* [turns, clears, bad]
    clearHalf,  \* a clear emptied the history and owes its line
    snap        \* the line count the running round took, or -1 when none runs

vars == << hist, ckTurns, log, turn, progress, readIds, nextId,
           budget, clearHalf, snap >>

Max(S) == CHOOSE x \in S : \A y \in S : y <= x
Min(S) == CHOOSE x \in S : \A y \in S : x <= y

\* ---------------------------------------------------------------- the rules

\* Row 3d. Two kinds of line say the atoms are numbered from zero again.
IsRestart(l) == l.kind = "HR" \/ (l.kind \in {"TE", "TN"} /\ l.fresh)

\* Row 2a. A line is a place to cut only when it describes the history that was
\* loaded. Every digest collides here, so that is end_atom <= atom count.
IsCut(l, ck) == l.kind = "TE" /\ l.end <= Len(ck)

CutsOf(lines, ck) ==
    { lines[i].end : i \in { j \in 1..Len(lines) : IsCut(lines[j], ck) } }

\* Keeper_turn_boundaries.witness_line: a line among the first [seen] that
\* ends a turn at [end]. A position is read only with such a line, and a
\* recovery moves one only to an end that has one. Every digest collides
\* here, so that is the end alone.
StatesPosition(lines, seen, end) ==
    \E i \in 1..Min({seen, Len(lines)}) : lines[i].kind = "TE" /\ lines[i].end = end

\* Row 2c. The first line the decoder refuses, or 0.
FirstRefused(lines) ==
    LET refused == { i \in 1..Len(lines) : lines[i].kind = "BAD" }
    IN IF refused = {} THEN 0 ELSE Min(refused)

\* Row 2c'. A restart line after the refused one settles what the refused line
\* could have said: the round starts at atom zero and no start is smaller.
RefusedIsDead(lines, at) ==
    \E i \in (at + 1)..Len(lines) : IsRestart(lines[i])

\* A restart settles the refused lines before it and no others, so the question
\* is asked of each of them, not of the first alone.
FirstBlockingRefused(lines) ==
    LET blocking == { i \in 1..Len(lines) :
                        lines[i].kind = "BAD" /\ ~RefusedIsDead(lines, i) }
    IN IF blocking = {} THEN 0 ELSE Min(blocking)

\* keeper_librarian_range.select. [kind, start, end]; start is exclusive of what
\* is read and end is inclusive, so a round reads atoms start+1 .. end.
\* refusedMode: "block" asks of every refused line, "first" asks only of the
\* first one and lets a later live one through, "drop" ignores them all.
Choose(lines, ck, prog, refusedMode, restartFirst) ==
    LET first == FirstRefused(lines)
        bad == CASE refusedMode = "block" -> FirstBlockingRefused(lines)
                 [] refusedMode = "first" ->
                      IF first # 0 /\ ~RefusedIsDead(lines, first) THEN first ELSE 0
                 [] OTHER -> 0
    IN IF bad # 0
       THEN [kind |-> "stop", start |-> 0, end |-> 0]
       ELSE LET seen  == IF prog = NoProgress THEN 0 ELSE prog.seen
                cuts  == CutsOf(lines, ck)
                back  == \E i \in (seen + 1)..Len(lines) : IsRestart(lines[i])
                \* Row 3c puts the restart line ahead of a position that seems
                \* to match: a digest carries neither an index nor a time, so
                \* the same message at the same place reads as the same history.
                again == back /\ (restartFirst \/ prog = NoProgress
                                  \/ prog.end > Len(ck))
            IN IF again                                              \* row 3c
               THEN IF cuts = {} THEN [kind |-> "nothing", start |-> 0, end |-> 0]
                    ELSE [kind |-> "read", start |-> 0, end |-> Max(cuts)]
               ELSE IF prog = NoProgress                             \* row 3
               THEN IF cuts = {} THEN [kind |-> "nothing", start |-> 0, end |-> 0]
                    ELSE [kind |-> "baseline", start |-> Min(cuts), end |-> Min(cuts)]
               ELSE IF prog.end > Len(ck)                            \* row 5
               THEN [kind |-> "stop", start |-> 0, end |-> 0]
               ELSE LET beyond == { c \in cuts : c > prog.end }       \* row 2
                    IN IF beyond = {}
                       THEN [kind |-> "nothing", start |-> prog.end, end |-> prog.end]
                       ELSE [kind |-> "read", start |-> prog.end, end |-> Max(beyond)]

\* ---------------------------------------------------------------- invariants

TypeOK ==
    /\ ckTurns \in Nat
    /\ nextId \in Nat
    /\ clearHalf \in BOOLEAN
    /\ snap \in -1..MaxTurns * MaxSaves + MaxTurns + MaxClears + MaxBad + 1
    /\ progress = NoProgress \/ (progress.end \in Nat /\ progress.seen \in Nat)

\* The one thing the rules owe: no atom of the saved history is out of reach.
\*
\* A position that sits past an unread atom is not yet a loss. A restart line
\* the position has not counted takes the next round back to atom zero, which
\* reaches it again -- the rules trade a second reading for never losing one
\* (4.4 row 3c). The atom is lost only when the position is past it, no round
\* read it, and no such line is there to go back for.
\*
\* Atoms a clear or a version cut erased before they were read are not counted:
\* their text is gone (4.6), and they are no longer in the history. A history
\* that restarts later erases these atoms rather than delivering them, so a
\* line that has not been written yet cannot save them.
\* It judges only states where the reader is level with the log. A line no
\* round has counted yet means the round has not had its say: it may be about
\* to stop on a refused line, or to go back to atom zero on a restart. A stop
\* writes no progress, so `seen` stays behind and the state stays excused for
\* as long as the stop lasts -- which is what 4.10 describes, an operator-
\* visible halt rather than a loss. What this invariant forbids is a round
\* that had every line in front of it and moved past an atom anyway.
NoAtomPassedUnread ==
    \/ progress = NoProgress
    \/ Len(log) > progress.seen
    \/ \E j \in (progress.seen + 1)..Len(log) : IsRestart(log[j])
    \/ \A i \in 1..Min({progress.end, Len(hist)}) : hist[i] \in readIds

\* ---------------------------------------------------------------- writers

StartTurn(loaded, fresh, tc, blind, line) ==
    /\ budget.turns > 0
    /\ turn = NoTurn
    /\ ~clearHalf
    /\ snap = -1 \/ snap >= 0   \* a round may be mid-flight; turns do not wait
    /\ turn' = [loaded |-> loaded, fresh |-> fresh, tc |-> tc, mine |-> << >>,
                accepted |-> FALSE, saves |-> 0, blind |-> blind]
    /\ log' = IF line = "none" THEN log
              ELSE IF line = "restart" THEN Append(log, RestartLine)
              ELSE Append(log, RefusedLine)
    /\ budget' = [budget EXCEPT !.turns = @ - 1,
                                !.bad = IF line = "refused" THEN @ - 1 ELSE @]
    /\ UNCHANGED << hist, ckTurns, progress, readIds, nextId, clearHalf, snap >>

\* A turn that starts from no atom and knows the saved history holds none says
\* so before it runs; nothing of its own can be saved ahead of the line.
TurnStart ==
    /\ Len(hist) = 0
    /\ StartTurn(hist, TRUE, ckTurns, FALSE, "restart")

TurnStartRefused ==
    /\ budget.bad > 0
    /\ Len(hist) = 0
    /\ StartTurn(hist, TRUE, ckTurns, FALSE, "refused")

TurnStartContinued ==
    /\ Len(hist) > 0
    /\ StartTurn(hist, FALSE, ckTurns, FALSE, "none")

\* A turn whose checkpoint could not be loaded starts from no atom while the
\* saved history still holds some. It has not seen them, so it says nothing yet.
TurnStartBlind ==
    /\ Len(hist) > 0
    /\ StartTurn(<< >>, TRUE, 0, TRUE, "none")

TurnSave ==
    /\ turn # NoTurn
    /\ turn.saves < MaxSaves
    /\ LET mine  == Append(turn.mine, nextId)
           tc    == turn.tc + 1
           takes == tc >= ckTurns
           first == turn.blind /\ takes /\ ~turn.accepted
       IN /\ hist' = IF takes THEN turn.loaded \o mine ELSE hist
          /\ ckTurns' = IF takes THEN tc ELSE ckTurns
          /\ turn' = [turn EXCEPT !.mine = mine, !.tc = tc,
                                  !.accepted = takes, !.saves = @ + 1]
          \* The save that replaced what was on disk is where an unread turn
          \* says the history restarted: it may die before its own end line.
          /\ log' = IF first THEN Append(log, RestartLine) ELSE log
    /\ nextId' = nextId + 1
    /\ UNCHANGED << progress, readIds, budget, clearHalf, snap >>

\* The same save with its restart line landing as bytes the decoder refuses.
\* This is the append that matters most: it is the only line saying the history
\* on disk was replaced, so a round that does not stop on it reads the new
\* history from an old position.
TurnSaveRefusedRestart ==
    /\ turn # NoTurn
    /\ turn.saves < MaxSaves
    /\ turn.blind
    /\ ~turn.accepted
    /\ budget.bad > 0
    /\ LET mine == Append(turn.mine, nextId)
           tc   == turn.tc + 1
       IN /\ tc >= ckTurns
          /\ hist' = turn.loaded \o mine
          /\ ckTurns' = tc
          /\ turn' = [turn EXCEPT !.mine = mine, !.tc = tc,
                                  !.accepted = TRUE, !.saves = @ + 1]
          /\ log' = Append(log, RefusedLine)
    /\ budget' = [budget EXCEPT !.bad = @ - 1]
    /\ nextId' = nextId + 1
    /\ UNCHANGED << progress, readIds, clearHalf, snap >>

EndLine(t) ==
    LET taken == t.loaded \o t.mine
    IN IF t.accepted /\ Len(taken) > 0
       THEN [kind |-> "TE", fresh |-> t.fresh, end |-> Len(taken)]
       ELSE [kind |-> "TN", fresh |-> t.fresh, end |-> 0]

TurnEnd ==
    /\ turn # NoTurn
    /\ turn.saves > 0
    /\ log' = Append(log, EndLine(turn))
    /\ turn' = NoTurn
    /\ UNCHANGED << hist, ckTurns, progress, readIds, nextId, budget,
                    clearHalf, snap >>

TurnEndRefused ==
    /\ turn # NoTurn
    /\ turn.saves > 0
    /\ budget.bad > 0
    /\ log' = Append(log, RefusedLine)
    /\ turn' = NoTurn
    /\ budget' = [budget EXCEPT !.bad = @ - 1]
    /\ UNCHANGED << hist, ckTurns, progress, readIds, nextId,
                    clearHalf, snap >>

TurnDie ==
    /\ turn # NoTurn
    /\ turn' = NoTurn
    /\ UNCHANGED << hist, ckTurns, log, progress, readIds, nextId,
                    budget, clearHalf, snap >>

\* A clear empties the history and then says so, in two steps, so that a round
\* or a turn can land between them.
ClearSave ==
    /\ budget.clears > 0
    /\ ~clearHalf
    /\ hist' = << >>
    /\ clearHalf' = TRUE
    /\ budget' = [budget EXCEPT !.clears = @ - 1]
    /\ UNCHANGED << ckTurns, log, turn, progress, readIds, nextId, snap >>

ClearLine ==
    /\ clearHalf
    /\ log' = Append(log, RestartLine)
    /\ clearHalf' = FALSE
    /\ UNCHANGED << hist, ckTurns, turn, progress, readIds, nextId,
                    budget, snap >>

\* ---------------------------------------------------------------- the round
\* Two steps, so that a writer can land between the lines a round took and the
\* checkpoint it loads. Which way round matters: the lines must be read first.

RoundSnap ==
    /\ snap = -1
    /\ snap' = Len(log)
    /\ UNCHANGED << hist, ckTurns, log, turn, progress, readIds,
                    nextId, budget, clearHalf >>

Apply(refusedMode, restartFirst) ==
    /\ snap >= 0
    /\ LET lines == SubSeq(log, 1, Min({snap, Len(log)}))
           sel == Choose(lines, hist, progress, refusedMode, restartFirst)
           \* keeper_librarian_durable_consumer reads from a position only
           \* with the line that states it, among the lines the position
           \* counted, whatever the round starts from. Without one the pass
           \* stops (Progress_boundary_missing) and moves nothing.
           stalled == /\ sel.kind = "read"
                      /\ progress # NoProgress
                      /\ ~StatesPosition(lines, progress.seen, progress.end)
           read == IF sel.kind = "read" /\ ~stalled
                   THEN { hist[i] : i \in (sel.start + 1)..sel.end }
                   ELSE {}
           moves == sel.kind \in {"read", "baseline"} /\ ~stalled
       IN /\ readIds' = readIds \cup read
          /\ progress' = IF moves THEN [end |-> sel.end, seen |-> snap] ELSE progress
    /\ snap' = -1
    /\ UNCHANGED << hist, ckTurns, log, turn, nextId, budget, clearHalf >>

RoundApply == Apply("block", TRUE)

\* A round that failed: it delivered nothing, so it moves nothing.
RoundFailed ==
    /\ snap >= 0
    /\ snap' = -1
    /\ UNCHANGED << hist, ckTurns, log, turn, progress, readIds,
                    nextId, budget, clearHalf >>

\* ---------------------------------------------------------------- spec

Init ==
    /\ hist = << >>
    /\ ckTurns = 0
    /\ log = << >>
    /\ turn = NoTurn
    /\ progress = NoProgress
    /\ readIds = {}
    /\ nextId = 1
    /\ budget = [turns |-> MaxTurns, clears |-> MaxClears, bad |-> MaxBad]
    /\ clearHalf = FALSE
    /\ snap = -1

Next ==
    \/ TurnStart \/ TurnStartRefused \/ TurnStartContinued \/ TurnStartBlind
    \/ TurnSave \/ TurnSaveRefusedRestart \/ TurnEnd \/ TurnEndRefused \/ TurnDie
    \/ ClearSave \/ ClearLine
    \/ RoundSnap \/ RoundApply \/ RoundFailed

Spec == Init /\ [][Next]_vars

\* Bug witness 1: a round drops the line the decoder refused instead of standing
\* on it. The refused line may have been the one saying the history restarted,
\* and then the round takes an older line as its baseline and never goes back.
RoundApplyDroppingRefused == Apply("drop", TRUE)

NextBuggy ==
    \/ Next
    \/ RoundApplyDroppingRefused

SpecBuggy == Init /\ [][NextBuggy]_vars

\* A purge keeps every atom and the digest of every message a line or the
\* position names (Keeper_checkpoint_purge), so to this model, whose history is
\* atom ids and whose rounds compare only those digests, it changes nothing.
\* What moves a position is recovery from a broken transcript: it drops the
\* history from the break on. The break may be anywhere, so the model cuts
\* after any atom.
TrimTo(k) == hist' = SubSeq(hist, 1, k)

PurgeTrimGuard ==
    /\ turn = NoTurn
    /\ ~clearHalf
    /\ snap = -1
    /\ Len(hist) > 1

\* Bug witness 4: the recovery drops the tail and leaves the read position
\* where it was, past the new end. The next turn saves atoms at numbers the
\* position has already passed, and the round after it reads from beyond them.
PurgeTrimKeepingProgress ==
    /\ PurgeTrimGuard
    /\ \E k \in 1..(Len(hist) - 1) : TrimTo(k)
    /\ UNCHANGED << ckTurns, log, turn, progress, readIds, nextId, budget,
                    clearHalf, snap >>

NextPurgeTrim ==
    \/ Next
    \/ PurgeTrimKeepingProgress

SpecPurgeTrim == Init /\ [][NextPurgeTrim]_vars

\* Bug witness 5: the recovery under the guard RFC librarian-lifecycle 10
\* first recommended -- refuse while a turn is unread, and otherwise make the
\* new end the position. It loses atoms because the guard asks about turns
\* while atoms are at risk: a turn that saved and then died leaves atoms that
\* no line names, so "no turn is unread" is true while an atom is not, and the
\* position is moved over it.
PurgeTrimGuardedByTurns ==
    /\ PurgeTrimGuard
    /\ progress # NoProgress
    /\ \A c \in CutsOf(log, hist) : c <= progress.end
    /\ \E k \in 1..(Len(hist) - 1) :
         /\ TrimTo(k)
         /\ progress' = [end |-> k, seen |-> Len(log)]
    /\ UNCHANGED << ckTurns, log, turn, readIds, nextId, budget, clearHalf, snap >>

NextPurgeTrimGuardedByTurns ==
    \/ Next
    \/ PurgeTrimGuardedByTurns

SpecPurgeTrimGuardedByTurns == Init /\ [][NextPurgeTrimGuardedByTurns]_vars

\* Bug witness 6: the recovery the code runs, except that it counts every line
\* the log now holds instead of leaving the count alone. The count is what
\* makes a restart line beyond it new; raising it swallows a restart no round
\* has taken in, and that line was what would have sent the next round back
\* to atom zero. A recovery may move where a round reads; it may not decide
\* what a round has already seen.
PurgeTrimAtEndCountingLines ==
    /\ PurgeTrimGuard
    /\ progress # NoProgress
    /\ progress.end = Len(hist)
    /\ \E k \in 1..(Len(hist) - 1) :
         /\ StatesPosition(log, progress.seen, k)
         /\ TrimTo(k)
         /\ progress' = [end |-> k, seen |-> Len(log)]
    /\ UNCHANGED << ckTurns, log, turn, readIds, nextId, budget, clearHalf, snap >>

NextPurgeTrimAtEndCountingLines ==
    \/ Next
    \/ PurgeTrimAtEndCountingLines

SpecPurgeTrimAtEndCountingLines ==
    Init /\ [][NextPurgeTrimAtEndCountingLines]_vars

\* The recovery the code runs (Keeper_checkpoint_purge.purge_messages and
\* librarian_rebase). With a position, it is refused unless the position is
\* the history's end, and it ends the history at an end a counted line states
\* ahead of the break; the position moves there and the counted lines stay as
\* they are. Without a position it ends at the break.
\* SpecPurgeTrimAtEnd and SpecPurgeTrimAtEndLive must NOT violate.
PurgeTrimAtEnd ==
    /\ PurgeTrimGuard
    /\ progress # NoProgress
    /\ progress.end = Len(hist)
    /\ \E k \in 1..(Len(hist) - 1) :
         /\ StatesPosition(log, progress.seen, k)
         /\ TrimTo(k)
         /\ progress' = [end |-> k, seen |-> progress.seen]
    /\ UNCHANGED << ckTurns, log, turn, readIds, nextId, budget, clearHalf, snap >>

PurgeTrimWithoutProgress ==
    /\ PurgeTrimGuard
    /\ progress = NoProgress
    /\ \E k \in 1..(Len(hist) - 1) : TrimTo(k)
    /\ UNCHANGED << ckTurns, log, turn, progress, readIds, nextId, budget,
                    clearHalf, snap >>

NextPurgeTrimAtEnd ==
    \/ Next
    \/ PurgeTrimAtEnd
    \/ PurgeTrimWithoutProgress

SpecPurgeTrimAtEnd == Init /\ [][NextPurgeTrimAtEnd]_vars

\* Bug witness 8: the same recovery with the position moved to wherever the
\* break left the end (masc #37772). It passes nothing over unread, so
\* NoAtomPassedUnread holds, but the end may be one no line states. A round
\* reads from a position only with its line, and the count of lines moves
\* only with the position, so once the next turn ends every round stops
\* there. LibrarianRead-purge-trim-anywhere-live-buggy.cfg shows it.
PurgeTrimAtEndAnywhere ==
    /\ PurgeTrimGuard
    /\ progress # NoProgress
    /\ progress.end = Len(hist)
    /\ \E k \in 1..(Len(hist) - 1) :
         /\ TrimTo(k)
         /\ progress' = [end |-> k, seen |-> progress.seen]
    /\ UNCHANGED << ckTurns, log, turn, readIds, nextId, budget, clearHalf, snap >>

NextPurgeTrimAtEndAnywhere ==
    \/ Next
    \/ PurgeTrimAtEndAnywhere
    \/ PurgeTrimWithoutProgress

\* Bug witness 3: the turn-boundary file is deleted while the read position that
\* counted its lines is kept. Line numbers start at one again, so a restart line
\* appended after the deletion sits at a number the position has already passed
\* and row 3c never sees it. The purge plan removes the progress file with the
\* boundary file for exactly this reason; this action takes the two apart.
PurgeBoundariesKeepingProgress ==
    /\ turn = NoTurn
    /\ ~clearHalf
    /\ snap = -1
    /\ log # << >>
    /\ log' = << >>
    /\ UNCHANGED << hist, ckTurns, turn, progress, readIds, nextId, budget,
                    clearHalf, snap >>

NextPurgeSplit ==
    \/ Next
    \/ PurgeBoundariesKeepingProgress

SpecPurgeSplit == Init /\ [][NextPurgeSplit]_vars

\* Bug witness 7: the round asks whether the FIRST refused line still matters
\* and, when a restart settles that one, goes on without looking at the rest.
\* A later refused line with no restart after it is then never seen, and it
\* may have been the restart line for the history now on disk. Found in review
\* of the shipped code, which had exactly this shape; the model could not have
\* found it while only one line was ever refused.
RoundApplyFirstRefusedOnly == Apply("first", TRUE)

NextFirstRefusedOnly ==
    \/ Next
    \/ RoundApplyFirstRefusedOnly

SpecFirstRefusedOnly == Init /\ [][NextFirstRefusedOnly]_vars

\* Bug witness 2: a round takes a read position that matches the checkpoint over
\* a restart line it has not counted. The position matches because the digest of
\* the atom at that place is the same, which a replaced history can reproduce.
RoundApplyPositionFirst == Apply("block", FALSE)

NextPositionFirst ==
    \/ Next
    \/ RoundApplyPositionFirst

SpecPositionFirst == Init /\ [][NextPositionFirst]_vars

\* ------------------------------------------------- a round that never returns

\* NoAtomPassedUnread cannot see a round that stops for good. A round standing
\* on a refused line passes nothing over, because it delivers nothing, so that
\* invariant holds while the Keeper's memory stops being written. What the
\* design promises is the other half: a round comes back to what it could not
\* read.
\*
\* It promises that up to the last cut point only. An atom a turn saved before
\* it died has no line that ends it, so no round can name it, and reading it is
\* not owed. The property therefore asks about the atoms a cut point covers.
AtomsUpToLastCutRead ==
    LET cuts == CutsOf(log, hist)
    IN cuts = {} \/ \A i \in 1..Min({Max(cuts), Len(hist)}) : hist[i] \in readIds

EveryReachableAtomEventuallyRead == <>[]AtomsUpToLastCutRead

\* Strong fairness on the apply: a round that failed puts the snapshot back, so
\* the apply is enabled again and again rather than continuously, and weak
\* fairness would let the failures take every turn.
SpecLive ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(RoundSnap)
    /\ SF_vars(RoundApply)

\* The same question asked of a recovery that moves the position. With
\* MaxBad = 0 no line is ever unreadable, so the stop above cannot happen and
\* a violation here belongs to the recovery alone.
SpecPurgeTrimAtEndLive ==
    /\ Init
    /\ [][NextPurgeTrimAtEnd]_vars
    /\ WF_vars(RoundSnap)
    /\ SF_vars(RoundApply)

SpecPurgeTrimAtEndAnywhereLive ==
    /\ Init
    /\ [][NextPurgeTrimAtEndAnywhere]_vars
    /\ WF_vars(RoundSnap)
    /\ SF_vars(RoundApply)

\* There is no bug to plant here. SpecLive is the reader as it stands and it
\* already violates the property, so the cfg that runs it is named for what it
\* shows. When the stall is closed the cfg stops violating and the harness says
\* so, which is when it becomes a clean cfg.

====
