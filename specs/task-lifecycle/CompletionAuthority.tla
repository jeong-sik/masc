----------------------------- MODULE CompletionAuthority -----------------------------
(* TLA+ bug-model for the RFC-0262 §9 completion-trust ownership invariant.

   Formal companion of the empirical dispatch oracle in
   test/test_completion_trust_harness.ml (Test A): a task reaches "Done"
   only if the actor that completed it was *authorized* to.

   Models the OCaml completion-authority gate:
     - completion_authority = Assignee | Operator | System
       (lib/types/types_core.ml:completion_authority)
     - owner_authorized ~authority ~same_agent assignee
       (lib/workspace/workspace_task_lifecycle.ml):
           Assignee          -> same_agent assignee   (only the owner)
           Operator | System -> true                  (privileged override)

   The safety invariant CompletionRequiresAuthority states that a "Done"
   task's completer was authorized under the recorded authority. The
   Authorized predicate below is the spec image of owner_authorized:
   under Assignee the completer must equal the assignee; under
   Operator/System any actor is permitted (cross-agent completion is a
   deliberate privileged path, not a violation).

   Bug Model pattern (mirrors specs/task-lifecycle/TaskLifecycle.tla):
     - Clean cfg: SpecClean + CompletionRequiresAuthority must pass —
       every reachable Done was reached through an authorized Complete.
     - Buggy cfg: SpecBuggy adds BugPeerCompletesAsAssignee (a non-owner
       completes the task while recording Assignee authority) which MUST
       violate CompletionRequiresAuthority. If it passes, the invariant
       is too weak to enforce RFC-0262 axis-2 ownership.

   OCaml <-> TLA+ mapping:
     assignee             <-> Claimed/InProgress { assignee }
     completer            <-> the agent_name that issued keeper_task_done
     completion_authority <-> the typed completion_authority on the transition
     Authorized(a,c,s)    <-> owner_authorized ~authority:a ~same_agent:(c=s) s
*)

EXTENDS Integers

CONSTANTS Agents          \* finite set of agent identities, e.g. {a1, a2}

Authorities == { "Assignee", "Operator", "System" }

\* Sentinel for "no agent / no authority recorded yet" (state = Todo).
NoAgent == "none"

VARIABLES state, assignee, completer, completion_authority

vars == << state, assignee, completer, completion_authority >>

States == { "Todo", "Claimed", "Done" }

\* Spec image of owner_authorized: under Assignee the completer must be the
\* owner; Operator/System are privileged and may complete any task.
Authorized(authority, c, owner) ==
    authority = "Assignee" => c = owner

TypeOK ==
    /\ state \in States
    /\ assignee \in (Agents \cup { NoAgent })
    /\ completer \in (Agents \cup { NoAgent })
    /\ completion_authority \in (Authorities \cup { NoAgent })

\* ── Init ────────────────────────────────────

Init ==
    /\ state = "Todo"
    /\ assignee = NoAgent
    /\ completer = NoAgent
    /\ completion_authority = NoAgent

\* ── Clean transitions ───────────────────────

\* Claim: Todo -> Claimed. Some agent reserves the task as its owner.
Claim(a) ==
    /\ state = "Todo"
    /\ a \in Agents
    /\ state' = "Claimed"
    /\ assignee' = a
    /\ UNCHANGED << completer, completion_authority >>

\* Complete: Claimed -> Done, but only via an AUTHORIZED completion. This is
\* the guard owner_authorized enforces at the FSM layer.
Complete(c, authority) ==
    /\ state = "Claimed"
    /\ c \in Agents
    /\ authority \in Authorities
    /\ Authorized(authority, c, assignee)
    /\ state' = "Done"
    /\ completer' = c
    /\ completion_authority' = authority
    /\ UNCHANGED assignee

\* Terminal state stutters so TLC can close the model.
Terminal ==
    /\ state = "Done"
    /\ UNCHANGED vars

NextClean ==
    \/ \E a \in Agents : Claim(a)
    \/ \E c \in Agents, authority \in Authorities : Complete(c, authority)
    \/ Terminal

\* ── Bug: peer completes a foreign task as Assignee ──
\* Models the wrong_approach where a non-owner marks another agent's task
\* done while the transition is recorded with Assignee authority (no
\* privileged override). owner_authorized rejects this at runtime; here it
\* is admitted on purpose so CompletionRequiresAuthority must catch it.

BugPeerCompletesAsAssignee(c) ==
    /\ state = "Claimed"
    /\ c \in Agents
    /\ c # assignee
    /\ state' = "Done"
    /\ completer' = c
    /\ completion_authority' = "Assignee"
    /\ UNCHANGED assignee

NextBuggy ==
    \/ NextClean
    \/ \E c \in Agents : BugPeerCompletesAsAssignee(c)

\* ── Specs ───────────────────────────────────

SpecClean == Init /\ [][NextClean]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Safety ──────────────────────────────────

\* A Done task's completer was authorized under the recorded authority.
\* Catches BugPeerCompletesAsAssignee: a non-owner completing under Assignee
\* authority makes Authorized("Assignee", completer, assignee) false.
CompletionRequiresAuthority ==
    state = "Done" => Authorized(completion_authority, completer, assignee)

================================================================================
