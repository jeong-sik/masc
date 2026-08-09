---- MODULE KeeperOwnerOperation ----
\* Per-Keeper single-owner operation scheduling.
\*
\* Queued edits remain legal until the actor-linearized Start. Therefore Start
\* must hand the child the input version read at that same transition; a child
\* that caches the body earlier can execute stale input.

EXTENDS FiniteSets, Integers, TLC

CONSTANTS O1, O2, O3, K1, K2, MaxSequence, MaxVersion

Operations == {O1, O2, O3}
Keepers == {K1, K2}
OwnerMap == [o \in Operations |-> IF o = O3 THEN K2 ELSE K1]

States == {"Absent", "Queued", "Running", "Succeeded", "Failed", "Cancelled"}
TerminalStates == {"Succeeded", "Failed", "Cancelled"}

VARIABLES
    status,
    sequence,
    nextSequence,
    inputVersion,
    preparedVersion,
    executionVersion,
    terminalSeen,
    terminalKind,
    interrupted

vars == << status, sequence, nextSequence, inputVersion, preparedVersion,
           executionVersion, terminalSeen, terminalKind, interrupted >>

TypeOK ==
    /\ status \in [Operations -> States]
    /\ sequence \in [Operations -> 0..MaxSequence]
    /\ nextSequence \in 0..MaxSequence
    /\ inputVersion \in [Operations -> 0..MaxVersion]
    /\ preparedVersion \in [Operations -> 0..MaxVersion]
    /\ executionVersion \in [Operations -> 0..MaxVersion]
    /\ terminalSeen \subseteq Operations
    /\ terminalKind \in [Operations -> States]
    /\ interrupted \subseteq Operations

Init ==
    /\ status = [o \in Operations |-> "Absent"]
    /\ sequence = [o \in Operations |-> 0]
    /\ nextSequence = 0
    /\ inputVersion = [o \in Operations |-> 0]
    /\ preparedVersion = [o \in Operations |-> 0]
    /\ executionVersion = [o \in Operations |-> 0]
    /\ terminalSeen = {}
    /\ terminalKind = [o \in Operations |-> "Absent"]
    /\ interrupted = {}

Submit(o) ==
    /\ status[o] = "Absent"
    /\ nextSequence < MaxSequence
    /\ status' = [status EXCEPT ![o] = "Queued"]
    /\ sequence' = [sequence EXCEPT ![o] = nextSequence]
    /\ nextSequence' = nextSequence + 1
    /\ inputVersion' = [inputVersion EXCEPT ![o] = 1]
    /\ UNCHANGED << preparedVersion, executionVersion, terminalSeen,
                     terminalKind, interrupted >>

Edit(o) ==
    /\ status[o] = "Queued"
    /\ inputVersion[o] < MaxVersion
    /\ inputVersion' = [inputVersion EXCEPT ![o] = @ + 1]
    /\ UNCHANGED << status, sequence, nextSequence, preparedVersion,
                     executionVersion, terminalSeen, terminalKind, interrupted >>

MoveToEnd(o) ==
    /\ status[o] = "Queued"
    /\ nextSequence < MaxSequence
    /\ sequence' = [sequence EXCEPT ![o] = nextSequence]
    /\ nextSequence' = nextSequence + 1
    /\ UNCHANGED << status, inputVersion, preparedVersion, executionVersion,
                     terminalSeen, terminalKind, interrupted >>

Cancel(o) ==
    /\ status[o] = "Queued"
    /\ status' = [status EXCEPT ![o] = "Cancelled"]
    /\ terminalSeen' = terminalSeen \cup {o}
    /\ terminalKind' = [terminalKind EXCEPT ![o] = "Cancelled"]
    /\ UNCHANGED << sequence, nextSequence, inputVersion, preparedVersion,
                     executionVersion, interrupted >>

NoRunning(k) ==
    \A o \in Operations : OwnerMap[o] = k => status[o] # "Running"

IsHead(o) ==
    /\ status[o] = "Queued"
    /\ \A other \in Operations :
         /\ OwnerMap[other] = OwnerMap[o]
         /\ status[other] = "Queued"
         => sequence[o] <= sequence[other]

\* A child may prepare to wait for admission, but this is not a durable claim.
Prepare(o) ==
    /\ IsHead(o)
    /\ NoRunning(OwnerMap[o])
    /\ preparedVersion' = [preparedVersion EXCEPT ![o] = inputVersion[o]]
    /\ UNCHANGED << status, sequence, nextSequence, inputVersion,
                     executionVersion, terminalSeen, terminalKind, interrupted >>

Start(o) ==
    /\ IsHead(o)
    /\ NoRunning(OwnerMap[o])
    /\ status' = [status EXCEPT ![o] = "Running"]
    /\ executionVersion' = [executionVersion EXCEPT ![o] = inputVersion[o]]
    /\ UNCHANGED << sequence, nextSequence, inputVersion, preparedVersion,
                     terminalSeen, terminalKind, interrupted >>

\* Bug witness: execute the body cached by Prepare instead of the body current
\* at the mailbox-linearized Start.
StartBuggy(o) ==
    /\ IsHead(o)
    /\ NoRunning(OwnerMap[o])
    /\ preparedVersion[o] > 0
    /\ status' = [status EXCEPT ![o] = "Running"]
    /\ executionVersion' = [executionVersion EXCEPT ![o] = preparedVersion[o]]
    /\ UNCHANGED << sequence, nextSequence, inputVersion, preparedVersion,
                     terminalSeen, terminalKind, interrupted >>

Finish(o, terminal) ==
    /\ status[o] = "Running"
    /\ terminal \in {"Succeeded", "Failed"}
    /\ status' = [status EXCEPT ![o] = terminal]
    /\ terminalSeen' = terminalSeen \cup {o}
    /\ terminalKind' = [terminalKind EXCEPT ![o] = terminal]
    /\ UNCHANGED << sequence, nextSequence, inputVersion, preparedVersion,
                     executionVersion, interrupted >>

Restart ==
    LET wasRunning == {o \in Operations : status[o] = "Running"}
    IN
      /\ wasRunning # {}
      /\ status' = [o \in Operations |->
           IF o \in wasRunning THEN "Failed" ELSE status[o]]
      /\ terminalSeen' = terminalSeen \cup wasRunning
      /\ terminalKind' = [o \in Operations |->
           IF o \in wasRunning THEN "Failed" ELSE terminalKind[o]]
      /\ interrupted' = interrupted \cup wasRunning
      /\ UNCHANGED << sequence, nextSequence, inputVersion, preparedVersion,
                       executionVersion >>

Next ==
    \/ \E o \in Operations : Submit(o)
    \/ \E o \in Operations : Edit(o)
    \/ \E o \in Operations : MoveToEnd(o)
    \/ \E o \in Operations : Cancel(o)
    \/ \E o \in Operations : Prepare(o)
    \/ \E o \in Operations : Start(o)
    \/ \E o \in Operations, terminal \in {"Succeeded", "Failed"} :
         Finish(o, terminal)
    \/ Restart

NextBuggy ==
    \/ \E o \in Operations : Submit(o)
    \/ \E o \in Operations : Edit(o)
    \/ \E o \in Operations : MoveToEnd(o)
    \/ \E o \in Operations : Cancel(o)
    \/ \E o \in Operations : Prepare(o)
    \/ \E o \in Operations : StartBuggy(o)
    \/ \E o \in Operations, terminal \in {"Succeeded", "Failed"} :
         Finish(o, terminal)
    \/ Restart

Spec == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

SingleRunning ==
    \A k \in Keepers :
      Cardinality({o \in Operations : OwnerMap[o] = k /\ status[o] = "Running"}) <= 1

TerminalImmutable ==
    \A o \in terminalSeen :
      /\ status[o] \in TerminalStates
      /\ status[o] = terminalKind[o]

RestartNoRequeue ==
    \A o \in interrupted : status[o] = "Failed"

FifoExceptMove ==
    \A running \in Operations :
      status[running] = "Running" =>
        \A queued \in Operations :
          /\ OwnerMap[queued] = OwnerMap[running]
          /\ status[queued] = "Queued"
          => sequence[running] < sequence[queued]

ExecutionUsesLatestInput ==
    \A o \in Operations :
      status[o] = "Running" => executionVersion[o] = inputVersion[o]

====
