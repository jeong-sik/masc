---- MODULE KeeperRowFacts ----
\* Bug model: a fact about a store kept in memory beside the store's files
\* (RFC "Keeper row facts are kept in memory by their writers", sections 2
\* and 5).
\*
\* Models lib/core/fact_cell.ml and the two sides of it in
\* lib/dated_jsonl/dated_jsonl.ml: an append (see_kept, the rotation, the
\* write, settle_kept or forget_kept), a reader that fills (read_fact), and
\* whoever removes files (removing_files, directories_removed).
\*
\* The store is a list of files, oldest first: the files rotated out and the
\* current one. A file is a list of lines. A line is a whole row, of kind
\* "turn" or "other", or a broken one. The current file can end in a fragment
\* without its newline; readers take the fragment for a broken line.
\*
\* Two facts are kept, each in a cell {gen, filled, val}:
\*   K  the last K lines, broken ones included
\*   T  the latest "turn" row
\* K changes with every row. T changes only with a turn row, so a write can
\* leave its value as it was; that case has rules of its own (g).
\*
\* The cells are made by the first reader. Writers and the remover go over
\* the cells that are there and make none. A writer that finds cells after
\* its row which were not there before it cannot have seen them, and forgets
\* them (m).
\*
\* Every step below is one the code can be preempted at:
\*   writer   takes the mutex (when the store has one), sees the cells,
\*            rotates the current file out or not, writes, then settles the
\*            cells or forgets them. A write lands whole at a line start, or
\*            fails and leaves nothing or a fragment. A writer cancelled after
\*            its row landed forgets.
\*   filler   sees the cells, lists the files, opens them one at a time by
\*            name, and compare-and-sets. A rotation after the listing makes
\*            it open the new current file under the old name. A read can
\*            fail; it then looks like an empty file and the filler knows.
\*   remover  removes files oldest first, as many as it gets to, then
\*            forgets the cells in a later step. A prune removes under the
\*            mutex and forgets after it; a purge takes no mutex.
\*
\* Invariant (Agree): while nobody is in the middle of changing the files, a
\* filled cell holds what a read of the files gives.
\*
\* Bug models. Each replaces one clean step; Agree must fail for each. The
\* letters are the RFC's (section 5) and the names are the cfg files'.
\*   a  fill-overwrites                   the filler puts its value without the compare-and-set
\*   b  writer-fills                      a writer puts its own row in an unfilled cell
\*   c  seen-after-the-row                a writer looks at the cells after its row is in the file
\*   d  remover-keeps                     the remover does not forget
\*   e  failed-remover-keeps              a remover that fails part-way does not forget
\*   f  failed-write-keeps                a write that failed or was cancelled does not forget
\*   g  unchanged-value-keeps-generation  a write that leaves a value as it was leaves an
\*                                        unfilled cell as it was
\*   h  no-newline-after-fragment         a writer writes straight after a fragment, without a
\*                                        newline first
\*   i  late-bytes                        bytes of a failed write reach the file later, with no
\*                                        writer
\*   j  list-drops-broken                 the list fact leaves broken lines out
\*   k  lost-settle-overwrites            a writer that lost the compare-and-set puts its value
\*                                        anyway
\*   l  failed-read-kept                  the filler puts the value of a read that failed
\*   m  cell-made-during-a-write-kept     a writer leaves cells made during its write as they
\*                                        were
\*
\* Out of model: which registry entry a spelling of a directory gets
\* (Store.directory_name), a clock that goes back (after_row's check of the
\* newest file, covered by test_dated_jsonl_kept_facts), and progress.

EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Writers,        \* e.g. {"w1", "w2"}
    Locked,         \* TRUE: writers take the store's mutex. FALSE: the decision record has none
    MaxLines,       \* rows the writers write in all
    MaxFragments,   \* failed writes that leave a fragment
    MaxRotations,   \* times the current file is rotated out
    K,              \* lines the list fact holds
    Bug             \* "none", or one of "a" .. "m"

ASSUME Bug \in {"none", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m"}

Remover == "remover"
Current == 0                        \* the file being written
Names == 0..MaxRotations            \* 1.. are the files rotated out

NoLine == [kind |-> "none", id |-> 0]
Broken(id) == [kind |-> "broken", id |-> id]

VARIABLES
    names,      \* the store's files, oldest first; the current file is last
    content,    \* name -> lines
    open,       \* the current file ends in a fragment without its newline
    nextId, fragments, rotations, late,
    cellK, cellT,
    made,       \* a reader has made the cells
    lock,       \* "free", a writer, or the remover
    wpc, wline, wseenK, wseenT, wmade, wchanged,
    fpc, fseenK, fseenT, flist, fgot, ffailed,
    rpc, rchanged, rfailed, rdone

files == <<names, content, open, fragments, rotations, late>>
cells == <<cellK, cellT, made>>
wvars == <<wpc, wline, wseenK, wseenT, wmade, wchanged>>
fvars == <<fpc, fseenK, fseenT, flist, fgot, ffailed>>
rvars == <<rpc, rchanged, rfailed, rdone>>
vars == <<files, cells, wvars, fvars, rvars, nextId, lock>>

\* ---- what the files say -------------------------------------------------

RECURSIVE Lines(_)
Lines(ns) == IF ns = <<>> THEN <<>> ELSE content[Head(ns)] \o Lines(Tail(ns))

Max(S) == CHOOSE x \in S : \A y \in S : y <= x
LastK(s) == IF Len(s) <= K THEN s ELSE SubSeq(s, Len(s) - K + 1, Len(s))
LatestTurn(s) ==
    LET turns == {i \in 1..Len(s) : s[i].kind = "turn"}
    IN IF turns = {} THEN NoLine ELSE s[Max(turns)]
Whole(s) == SelectSeq(s, LAMBDA line : line.kind # "broken")

\* ---- cells ----------------------------------------------------------------

Cell(gen, filled, val) == [gen |-> gen, filled |-> filled, val |-> val]
ForgottenK == Cell(cellK.gen + 1, FALSE, <<>>)
ForgottenT == Cell(cellT.gen + 1, FALSE, NoLine)

StepK(val, line) == LastK(Append(val, line))
StepT(val, line) == IF line.kind = "turn" THEN line ELSE val

\* ---- writers ----------------------------------------------------------------

Released(holder) == IF lock = holder THEN "free" ELSE lock

WBegin(w) ==
    /\ wpc[w] = "idle"
    /\ nextId <= MaxLines
    /\ Locked => lock = "free"
    /\ lock' = IF Locked THEN w ELSE lock
    /\ \E kind \in {"turn", "other"} :
         wline' = [wline EXCEPT ![w] = [kind |-> kind, id |-> nextId]]
    /\ nextId' = nextId + 1
    /\ wpc' = [wpc EXCEPT ![w] = IF Bug = "c" THEN "write" ELSE "see"]
    /\ UNCHANGED <<files, cells, wseenK, wseenT, wmade, wchanged, fvars, rvars>>

WSee(w) ==
    /\ wpc[w] = "see"
    /\ wseenK' = [wseenK EXCEPT ![w] = cellK]
    /\ wseenT' = [wseenT EXCEPT ![w] = cellT]
    /\ wmade' = [wmade EXCEPT ![w] = made]
    /\ wpc' = [wpc EXCEPT ![w] = "write"]
    /\ UNCHANGED <<files, cells, wline, wchanged, fvars, rvars, nextId, lock>>

\* The current file gets a name of its own and a new one is started. The
\* lines keep their order.
WRotate(w) ==
    /\ wpc[w] = "write"
    /\ rotations < MaxRotations
    /\ content[Current] # <<>>
    /\ content' = [content EXCEPT ![rotations + 1] = content[Current], ![Current] = <<>>]
    /\ names' = SubSeq(names, 1, Len(names) - 1) \o <<rotations + 1, Current>>
    /\ rotations' = rotations + 1
    /\ open' = FALSE
    /\ wchanged' = [wchanged EXCEPT ![w] = TRUE]
    /\ UNCHANGED <<fragments, late, cells, wpc, wline, wseenK, wseenT, wmade, fvars, rvars, nextId, lock>>

WithLine(line) == [content EXCEPT ![Current] = Append(@, line)]

\* The row is in the file, whole and at a line start: a fragment before it
\* is ended by a newline first. The writer goes on to settle, or is
\* cancelled before it gets there.
WWrite(w) ==
    /\ wpc[w] = "write"
    /\ content' = IF Bug = "h" /\ open THEN content ELSE WithLine(wline[w])
    /\ open' = FALSE
    /\ wchanged' = [wchanged EXCEPT ![w] = TRUE]
    /\ \E next \in {"settle", "forget"} : wpc' = [wpc EXCEPT ![w] = next]
    /\ UNCHANGED <<names, fragments, rotations, late, cells, wline, wseenK, wseenT, wmade, fvars, rvars, nextId, lock>>

\* The write fails. Nothing of it stays, or a fragment does.
WWriteFails(w) ==
    /\ wpc[w] = "write"
    /\ \/ UNCHANGED <<content, open, fragments, wchanged>>
       \/ /\ fragments < MaxFragments
          /\ content' = IF open THEN content ELSE WithLine(Broken(fragments + 1))
          /\ open' = TRUE
          /\ fragments' = fragments + 1
          /\ wchanged' = [wchanged EXCEPT ![w] = TRUE]
    /\ wpc' = [wpc EXCEPT ![w] = "forget"]
    /\ UNCHANGED <<names, rotations, late, cells, wline, wseenK, wseenT, wmade, fvars, rvars, nextId, lock>>

SettledK(w) ==
    LET seen == wseenK[w]
        line == wline[w]
        next == IF seen.filled THEN Cell(seen.gen + 1, TRUE, StepK(seen.val, line))
                ELSE IF Bug = "b" THEN Cell(seen.gen + 1, TRUE, <<line>>)
                ELSE Cell(seen.gen + 1, FALSE, <<>>)
    IN IF Bug = "c"
       THEN IF cellK.filled
            THEN Cell(cellK.gen + 1, TRUE, StepK(cellK.val, line))
            ELSE Cell(cellK.gen + 1, FALSE, <<>>)
       ELSE IF cellK = seen THEN next
       ELSE IF Bug = "k" THEN Cell(cellK.gen + 1, next.filled, next.val)
       ELSE ForgottenK

SettledT(w) ==
    LET seen == wseenT[w]
        line == wline[w]
        next == IF seen.filled THEN Cell(seen.gen + 1, TRUE, StepT(seen.val, line))
                ELSE IF Bug = "b" /\ line.kind = "turn" THEN Cell(seen.gen + 1, TRUE, line)
                ELSE Cell(seen.gen + 1, FALSE, NoLine)
    IN IF Bug = "c"
       THEN IF cellT.filled
            THEN Cell(cellT.gen + 1, TRUE, StepT(cellT.val, line))
            ELSE Cell(cellT.gen + 1, FALSE, NoLine)
       ELSE IF Bug = "g" /\ ~seen.filled /\ line.kind # "turn" THEN cellT
       ELSE IF cellT = seen THEN next
       ELSE IF Bug = "k" THEN Cell(cellT.gen + 1, next.filled, next.val)
       ELSE ForgottenT

WDone(w) ==
    /\ wpc' = [wpc EXCEPT ![w] = "idle"]
    /\ wchanged' = [wchanged EXCEPT ![w] = FALSE]
    /\ lock' = Released(w)
    /\ UNCHANGED <<files, made, wline, wseenK, wseenT, wmade, fvars, rvars, nextId>>

\* The cells were made after the writer looked for them. (The writer of bug
\* c does not look before its row at all, and takes the cells as it finds
\* them.)
MadeDuringTheWrite(w) == Bug # "c" /\ made /\ ~wmade[w]

WSettle(w) ==
    /\ wpc[w] = "settle"
    /\ IF ~made \/ (MadeDuringTheWrite(w) /\ Bug = "m")
       THEN UNCHANGED <<cellK, cellT>>
       ELSE IF MadeDuringTheWrite(w)
       THEN cellK' = ForgottenK /\ cellT' = ForgottenT
       ELSE cellK' = SettledK(w) /\ cellT' = SettledT(w)
    /\ WDone(w)

WForget(w) ==
    /\ wpc[w] = "forget"
    /\ IF Bug = "f" \/ ~made
       THEN UNCHANGED <<cellK, cellT>>
       ELSE cellK' = ForgottenK /\ cellT' = ForgottenT
    /\ WDone(w)

\* ---- the filler ---------------------------------------------------------------

FSee ==
    /\ fpc = "idle"
    /\ ~cellK.filled \/ ~cellT.filled
    /\ fseenK' = cellK
    /\ fseenT' = cellT
    /\ made' = TRUE
    /\ fpc' = "list"
    /\ UNCHANGED <<files, cellK, cellT, wvars, flist, fgot, ffailed, rvars, nextId, lock>>

FList ==
    /\ fpc = "list"
    /\ flist' = names
    /\ fgot' = <<>>
    /\ ffailed' = FALSE
    /\ fpc' = "read"
    /\ UNCHANGED <<files, cells, wvars, fseenK, fseenT, rvars, nextId, lock>>

\* One file is opened by the name the listing gave and read to its end.
FRead ==
    /\ fpc = "read"
    /\ flist # <<>>
    /\ \/ fgot' = fgot \o content[Head(flist)] /\ UNCHANGED ffailed
       \/ ffailed' = TRUE /\ UNCHANGED fgot
    /\ flist' = Tail(flist)
    /\ UNCHANGED <<files, cells, wvars, fpc, fseenK, fseenT, rvars, nextId, lock>>

Filled(cell, seen, val) ==
    IF seen.filled THEN cell
    ELSE IF cell = seen \/ Bug = "a" THEN Cell(cell.gen + 1, TRUE, val)
    ELSE cell

FKeep ==
    /\ fpc = "read"
    /\ flist = <<>>
    /\ IF ffailed /\ Bug # "l"
       THEN UNCHANGED <<cellK, cellT>>
       ELSE /\ cellK' = Filled(cellK, fseenK, IF Bug = "j" THEN LastK(Whole(fgot)) ELSE LastK(fgot))
            /\ cellT' = Filled(cellT, fseenT, LatestTurn(fgot))
    /\ fpc' = "idle"
    /\ UNCHANGED <<files, made, wvars, fseenK, fseenT, flist, fgot, ffailed, rvars, nextId, lock>>

\* ---- the remover -----------------------------------------------------------------

RBegin ==
    /\ rpc = "idle"
    /\ ~rdone
    /\ \/ lock = "free" /\ lock' = Remover        \* a prune
       \/ UNCHANGED lock                            \* a purge
    /\ rpc' = "remove"
    /\ UNCHANGED <<files, cells, wvars, fvars, rchanged, rfailed, rdone, nextId>>

RRemove ==
    /\ rpc = "remove"
    /\ LET oldest == Head(names)
       IN /\ oldest # Current \/ content[Current] # <<>>
          /\ content' = [content EXCEPT ![oldest] = <<>>]
          /\ names' = IF oldest = Current THEN names ELSE Tail(names)
          /\ open' = IF oldest = Current THEN FALSE ELSE open
    /\ rchanged' = TRUE
    /\ UNCHANGED <<fragments, rotations, late, cells, wvars, fvars, rpc, rfailed, rdone, nextId, lock>>

\* The removal is over: it got through, or it failed after the files it had
\* removed by then. The mutex goes before the cells are forgotten.
RStop ==
    /\ rpc = "remove"
    /\ \E failed \in BOOLEAN : rfailed' = failed
    /\ lock' = Released(Remover)
    /\ rpc' = "forget"
    /\ UNCHANGED <<files, cells, wvars, fvars, rchanged, rdone, nextId>>

RForget ==
    /\ rpc = "forget"
    /\ IF Bug = "d" \/ (Bug = "e" /\ rfailed) \/ ~made
       THEN UNCHANGED <<cellK, cellT>>
       ELSE cellK' = ForgottenK /\ cellT' = ForgottenT
    /\ rpc' = "idle"
    /\ rchanged' = FALSE
    /\ rdone' = TRUE
    /\ UNCHANGED <<files, made, wvars, fvars, rfailed, nextId, lock>>

\* ---- bytes with no writer (bug i) ------------------------------------------------

LateBytes ==
    /\ Bug = "i"
    /\ ~late
    /\ fragments > 0
    /\ content' = WithLine(Broken(MaxFragments + 1))
    /\ late' = TRUE
    /\ UNCHANGED <<names, open, fragments, rotations, cells, wvars, fvars, rvars, nextId, lock>>

\* ---- the specification -------------------------------------------------------------

Init ==
    /\ names = <<Current>>
    /\ content = [name \in Names |-> <<>>]
    /\ open = FALSE
    /\ nextId = 1
    /\ fragments = 0
    /\ rotations = 0
    /\ late = FALSE
    /\ cellK = Cell(0, FALSE, <<>>)
    /\ cellT = Cell(0, FALSE, NoLine)
    /\ made = FALSE
    /\ lock = "free"
    /\ wpc = [w \in Writers |-> "idle"]
    /\ wline = [w \in Writers |-> NoLine]
    /\ wseenK = [w \in Writers |-> Cell(0, FALSE, <<>>)]
    /\ wseenT = [w \in Writers |-> Cell(0, FALSE, NoLine)]
    /\ wmade = [w \in Writers |-> FALSE]
    /\ wchanged = [w \in Writers |-> FALSE]
    /\ fpc = "idle"
    /\ fseenK = Cell(0, FALSE, <<>>)
    /\ fseenT = Cell(0, FALSE, NoLine)
    /\ flist = <<>>
    /\ fgot = <<>>
    /\ ffailed = FALSE
    /\ rpc = "idle"
    /\ rchanged = FALSE
    /\ rfailed = FALSE
    /\ rdone = FALSE

Next ==
    \/ \E w \in Writers :
         WBegin(w) \/ WSee(w) \/ WRotate(w) \/ WWrite(w) \/ WWriteFails(w) \/ WSettle(w) \/ WForget(w)
    \/ FSee \/ FList \/ FRead \/ FKeep
    \/ RBegin \/ RRemove \/ RStop \/ RForget
    \/ LateBytes

Spec == Init /\ [][Next]_vars

\* ---- what must hold ------------------------------------------------------------------

Changing == rchanged \/ \E w \in Writers : wchanged[w]

Agree ==
    ~Changing =>
        /\ cellK.filled => cellK.val = LastK(Lines(names))
        /\ cellT.filled => cellT.val = LatestTurn(Lines(names))

\* A cell never comes back to a state it held: every change takes the next
\* generation. The compare-and-set in the code compares states by identity,
\* and this is what makes identity and equality the same here.
GenerationsOnlyGrow ==
    [][cellK'.gen >= cellK.gen /\ cellT'.gen >= cellT.gen
       /\ (cellK' # cellK => cellK'.gen > cellK.gen)
       /\ (cellT' # cellT => cellT'.gen > cellT.gen)]_vars

TypeOK ==
    /\ lock \in {"free", Remover} \cup Writers
    /\ cellK.filled \in BOOLEAN
    /\ cellT.filled \in BOOLEAN
    /\ Len(names) >= 1
    /\ names[Len(names)] = Current

====
