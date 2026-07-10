---- MODULE TypedGhCapabilityGating ----
EXTENDS TLC

CONSTANTS Mode

Commands ==
  { "gh_repo_create"
  , "gh_discussion_create"
  , "gh_repo_delete"
  , "gh_pr_merge"
  , "gh_unknown"
  , "gh_pr_view"
  }

Catastrophic == { "gh_repo_delete", "gh_pr_merge" }
RequiresApproval == { "gh_repo_create", "gh_discussion_create", "gh_unknown" }

VARIABLES cmd, verdict, pending, turnBlocked, phase
vars == <<cmd, verdict, pending, turnBlocked, phase>>

Init ==
  /\ cmd \in Commands
  /\ verdict = "none"
  /\ pending = FALSE
  /\ turnBlocked = FALSE
  /\ phase = "init"

CleanDecision(c) ==
  IF c \in Catastrophic THEN
    [rv |-> "deny", rp |-> FALSE, rb |-> FALSE]
  ELSE IF c \in RequiresApproval THEN
    [rv |-> "ask", rp |-> TRUE, rb |-> FALSE]
  ELSE
    [rv |-> "allow", rp |-> FALSE, rb |-> FALSE]

BuggyDecision(c) ==
  IF c = "gh_pr_merge" THEN
    [rv |-> "allow", rp |-> FALSE, rb |-> FALSE]
  ELSE IF c = "gh_unknown" THEN
    [rv |-> "allow", rp |-> FALSE, rb |-> FALSE]
  ELSE IF c \in RequiresApproval THEN
    [rv |-> "ask", rp |-> TRUE, rb |-> TRUE]
  ELSE IF c \in Catastrophic THEN
    [rv |-> "deny", rp |-> FALSE, rb |-> FALSE]
  ELSE
    [rv |-> "allow", rp |-> FALSE, rb |-> FALSE]

Decision(c) == IF Mode = "clean" THEN CleanDecision(c) ELSE BuggyDecision(c)

Decide ==
  /\ phase = "init"
  /\ LET d == Decision(cmd) IN
     /\ verdict' = d.rv
     /\ pending' = d.rp
     /\ turnBlocked' = d.rb
  /\ phase' = "decided"
  /\ UNCHANGED cmd

Next == Decide
Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ cmd \in Commands
  /\ verdict \in {"none", "allow", "ask", "deny"}
  /\ pending \in BOOLEAN
  /\ turnBlocked \in BOOLEAN
  /\ phase \in {"init", "decided"}

CatastrophicNeverAllowed ==
  (phase = "decided" /\ cmd \in Catastrophic) => verdict # "allow"

NonBlockingApproval ==
  (phase = "decided" /\ verdict = "ask") => (pending /\ turnBlocked = FALSE)

UnknownGhVerbNeverAutoRun ==
  (phase = "decided" /\ cmd = "gh_unknown") => verdict # "allow"

====
