---- MODULE OperatorApprovalMode ----
\* RFC-0319 operator approval mode safety model.
\*
\* Clean Spec:
\*   Manual queues all requests.
\*   Auto_low_risk may auto-resolve only LowRequests.
\*   High, Critical, and Unclassified requests are never auto-resolved.
\*
\* Buggy Spec:
\*   NextBuggy adds AutoApprovesDestructive, which auto-resolves a
\*   high/critical/unclassified request and must violate
\*   NoDestructiveAutoApproval.

EXTENDS FiniteSets

CONSTANTS
    LowRequests,
    MediumRequests,
    HighRequests,
    CriticalRequests,
    UnclassifiedRequests

Requests ==
    LowRequests \cup MediumRequests \cup HighRequests
      \cup CriticalRequests \cup UnclassifiedRequests

Modes == {"manual", "auto_low_risk"}
AutoEligibleRequests == LowRequests
DestructiveRequests == HighRequests \cup CriticalRequests \cup UnclassifiedRequests

VARIABLES
    mode,
    pending,
    resolved,
    auto_resolved

vars == << mode, pending, resolved, auto_resolved >>

TypeOK ==
    /\ mode \in Modes
    /\ pending \subseteq Requests
    /\ resolved \subseteq Requests
    /\ auto_resolved \subseteq resolved

Init ==
    /\ mode = "manual"
    /\ pending = {}
    /\ resolved = {}
    /\ auto_resolved = {}

SetMode ==
    /\ mode' \in Modes
    /\ UNCHANGED << pending, resolved, auto_resolved >>

QueueRequest(r) ==
    /\ r \in Requests
    /\ r \notin pending
    /\ r \notin resolved
    /\ pending' = pending \cup {r}
    /\ UNCHANGED << mode, resolved, auto_resolved >>

ResolveManual(r) ==
    /\ r \in pending
    /\ pending' = pending \ {r}
    /\ resolved' = resolved \cup {r}
    /\ UNCHANGED << mode, auto_resolved >>

AutoApproveLow(r) ==
    /\ mode = "auto_low_risk"
    /\ r \in AutoEligibleRequests
    /\ r \notin pending
    /\ r \notin resolved
    /\ resolved' = resolved \cup {r}
    /\ auto_resolved' = auto_resolved \cup {r}
    /\ UNCHANGED << mode, pending >>

Next ==
    SetMode
    \/ \E r \in Requests : QueueRequest(r) \/ ResolveManual(r) \/ AutoApproveLow(r)

AutoApprovesDestructive ==
    /\ mode = "auto_low_risk"
    /\ \E r \in DestructiveRequests :
        /\ r \notin pending
        /\ r \notin resolved
        /\ resolved' = resolved \cup {r}
        /\ auto_resolved' = auto_resolved \cup {r}
        /\ UNCHANGED << mode, pending >>

NextBuggy == Next \/ AutoApprovesDestructive

Spec == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

NoDestructiveAutoApproval ==
    auto_resolved \cap DestructiveRequests = {}

SafetyInvariant ==
    /\ TypeOK
    /\ NoDestructiveAutoApproval

====
