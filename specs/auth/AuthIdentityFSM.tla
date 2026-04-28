---- MODULE AuthIdentityFSM ----
\* Models the masc-mcp request authentication FSM:
\*   transport bytes -> identify(token) -> policy(principal) -> decision
\*
\* Forensic root being modelled (PR #9657 / commit 277aa2698b, 2026-04-23):
\*   The OCaml refactor merged three changes in one PR --
\*     (1) shared internal_keeper.token.hash (one token, many keepers)
\*     (2) x-masc-keeper-name header asserts identity (token does not)
\*     (3) `Option.value ~default:"dashboard" agent_name_opt` silent rewrite
\*         in lib/server/server_auth.ml:183, 210, 233
\*   The pre-PR code was fail-closed; the post-PR code is fail-open with the
\*   substitute principal "dashboard". This spec encodes the silent rewrite
\*   as a BugAction so the SafetyInvariant fails under SpecBuggy and holds
\*   under Spec.
\*
\* Invariants verified:
\*   I1 IdentityBindsToken : resolved principal owns the request token
\*   I2 NoSilentRewrite    : resolved principal == deterministic Identify(token)
\*   I3 FailClosedDefault  : no token => decision in {Pending, Deny}
\*
\* Spec Bug-Model contract (CLAUDE.md software-development.md):
\*   Spec      under AuthIdentityFSM.cfg       => TLC: no error
\*   SpecBuggy under AuthIdentityFSM-buggy.cfg => TLC: invariant violated
\*   Both must hold. Clean-passes-only means the invariant is too weak.

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Agents,        \* set of agent names; must include "dashboard" for the bug
                   \* to be reachable, mirroring the OCaml default literal
    Tokens         \* set of token identifiers (abstract; SHA-256 in production)

NULL == "_NULL_"
ASSUME NullDistinct ==
    /\ NULL \notin Agents
    /\ NULL \notin Tokens

\* "dashboard" must be a real agent for SilentRewrite to substitute it.
ASSUME DashboardPresent == "dashboard" \in Agents

VARIABLES
    credentials,      \* [Agents -> SUBSET Tokens]  (an agent may rotate -> multiple tokens)
    request_token,    \* current request's bearer token: Tokens \cup {NULL}
    resolved_agent,   \* identify result: Agents \cup {NULL}
    decision          \* {"Allow", "Deny", "Pending"}

vars == <<credentials, request_token, resolved_agent, decision>>

\* ── Identify: pure AuthN ────────────────────────────────────
\* Returns NULL if zero or multiple agents match the token.
\* The multiple-match case models the 2026-04-25 incident where 14 keepers
\* shared one token (memory: feedback_shared-token-systemic-identity-violation.md).
\* A safe identifier MUST refuse to disambiguate -> NULL.

Matches(tok) == { a \in Agents : tok \in credentials[a] }

Identify(tok) ==
    IF tok = NULL THEN NULL
    ELSE IF Matches(tok) = {} THEN NULL
    ELSE IF Cardinality(Matches(tok)) > 1 THEN NULL
    ELSE CHOOSE a \in Matches(tok) : TRUE

\* ── Type invariant ──────────────────────────────────────────

TypeOK ==
    /\ credentials \in [Agents -> SUBSET Tokens]
    /\ request_token \in (Tokens \cup {NULL})
    /\ resolved_agent \in (Agents \cup {NULL})
    /\ decision \in {"Allow", "Deny", "Pending"}

\* ── Init ────────────────────────────────────────────────────
\* Deterministic credential assignment so the spec explores a single
\* initial state and "t_stale" is unambiguously the token NOT owned by
\* any agent (mirrors a rotated-out token still cached by the dashboard
\* browser; admin.json was rotated twice on 2026-04-27).

InitialCredentials == [a \in Agents |->
    IF a = "a1" THEN {"t1"}
    ELSE IF a = "a2" THEN {"t2"}
    ELSE IF a = "dashboard" THEN {"t3"}
    ELSE {}]

Init ==
    /\ credentials = InitialCredentials
    /\ request_token = NULL
    /\ resolved_agent = NULL
    /\ decision = "Pending"

\* ── Honest actions (clean spec) ─────────────────────────────

\* Receive a request: the network hands us a token (or none).
\* Identification happens immediately and deterministically.
ReceiveRequest ==
    /\ decision = "Pending"
    /\ resolved_agent = NULL
    /\ \E tok \in (Tokens \cup {NULL}) :
         /\ request_token' = tok
         /\ resolved_agent' = Identify(tok)
    /\ UNCHANGED <<credentials, decision>>

\* Decide policy. Fail-closed: any unresolved principal -> Deny.
DecidePolicy ==
    /\ decision = "Pending"
    /\ request_token /= NULL
    /\ IF resolved_agent = NULL
       THEN decision' = "Deny"
       ELSE decision' = "Allow"
    /\ UNCHANGED <<credentials, request_token, resolved_agent>>

\* Reset for the next request.
Reset ==
    /\ decision \in {"Allow", "Deny"}
    /\ request_token' = NULL
    /\ resolved_agent' = NULL
    /\ decision' = "Pending"
    /\ UNCHANGED credentials

\* Terminal stutter (prevents TLC deadlock false-positives at Allow/Deny).
Done ==
    /\ decision \in {"Allow", "Deny"}
    /\ UNCHANGED vars

\* ── Bug action (only in SpecBuggy) ──────────────────────────
\* Models the production code at lib/server/server_auth.ml:183, 210, 233:
\*   let agent_name = Option.value ~default:"dashboard" agent_name_opt
\* When Identify returned NULL but a token was present, the system
\* silently substitutes "dashboard" as the principal and continues.
\* This is exactly the silent identity rewrite that the user reported
\* on 2026-04-27 and which #10933 / #11041 / #11072 only added telemetry
\* for, without fixing.

SilentRewrite ==
    /\ decision = "Pending"
    /\ resolved_agent = NULL
    /\ request_token /= NULL          \* a token was sent but did not resolve
    /\ resolved_agent' = "dashboard"  \* OCaml: Option.value ~default:"dashboard"
    /\ UNCHANGED <<credentials, request_token, decision>>

\* ── Spec wirings ────────────────────────────────────────────

Next      == ReceiveRequest \/ DecidePolicy \/ Reset \/ Done
NextBuggy == Next \/ SilentRewrite

Spec      == Init /\ [][Next]_vars
SpecBuggy == Init /\ [][NextBuggy]_vars

\* ── Safety invariants ──────────────────────────────────────

\* I1: every resolved principal owns the token in its credential set.
IdentityBindsToken ==
    (resolved_agent /= NULL) =>
        /\ request_token /= NULL
        /\ request_token \in credentials[resolved_agent]

\* I2: the resolved principal must equal the deterministic Identify().
\* Catches silent rewrites that change the principal after identification.
NoSilentRewrite ==
    (resolved_agent /= NULL) => (Identify(request_token) = resolved_agent)

\* I3: no token => no Allow decision.
\* The pending decision is acceptable (transient); only Allow is forbidden.
FailClosedDefault ==
    (request_token = NULL) => (decision \in {"Pending", "Deny"})

SafetyInvariant ==
    /\ IdentityBindsToken
    /\ NoSilentRewrite
    /\ FailClosedDefault

====
