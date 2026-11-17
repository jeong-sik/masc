---- MODULE AuthIdentityFSM ----
\* Models the masc request authentication FSM:
\*   transport bytes -> identify(token) -> policy(principal) -> decision
\*   -> the layers below the door (dispatch, caller identity, execution)
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
\* RFC a-request-reads-its-bearer-once-at-the-door (§5.3) adds the layers
\* below the door. The door reads the bearer once; each layer takes the
\* door's principal. Credentials can be replaced or revoked at any time,
\* also while a request is in flight. A layer that read the token again
\* could then name a different caller than the door did: LayerRereadsToken
\* models that, and OneIdentityPerRequest fails under SpecReread.
\*
\* Invariants verified:
\*   I1 IdentityBindsToken    : resolved principal owned the request token
\*                              in the store the door read
\*   I2 NoSilentRewrite       : resolved principal == Identify(token) over
\*                              the store the door read
\*   I3 FailClosedDefault     : no token => decision in {Pending, Deny}
\*   I4 OneIdentityPerRequest : every layer below the door sees the door's
\*                              principal
\*
\* Spec Bug-Model contract (CLAUDE.md software-development.md):
\*   Spec       under AuthIdentityFSM.cfg              => TLC: no error
\*   SpecBuggy  under AuthIdentityFSM-buggy.cfg        => TLC: invariant violated
\*   SpecReread under AuthIdentityFSM-reread-buggy.cfg => TLC: I4 violated
\*   All must hold. Clean-passes-only means the invariant is too weak.

EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Agents,        \* set of agent names; must include "dashboard" for the bug
                   \* to be reachable, mirroring the OCaml default literal
    Tokens,        \* set of token identifiers (abstract; SHA-256 in production)
    Layers         \* the layers below the door that name the caller

NULL == "_NULL_"
UNREAD == "_UNREAD_"
ASSUME NullDistinct ==
    /\ NULL \notin Agents
    /\ NULL \notin Tokens
ASSUME UnreadDistinct == UNREAD \notin (Agents \cup {NULL})

\* "dashboard" must be a real agent for SilentRewrite to substitute it.
ASSUME DashboardPresent == "dashboard" \in Agents

VARIABLES
    credentials,      \* [Agents -> SUBSET Tokens]  (an agent may rotate -> multiple tokens)
    door_credentials, \* the store as the door read it for the current request
    request_token,    \* current request's bearer token: Tokens \cup {NULL}
    resolved_agent,   \* identify result: Agents \cup {NULL}
    decision,         \* {"Allow", "Deny", "Pending"}
    seen              \* [Layers -> Agents \cup {NULL, UNREAD}]: the caller each layer named

vars == <<credentials, door_credentials, request_token, resolved_agent, decision, seen>>

\* ── Identify: pure AuthN ────────────────────────────────────
\* Returns NULL if zero or multiple agents match the token.
\* The multiple-match case models the 2026-04-25 incident where 14 keepers
\* shared one token (memory: feedback_shared-token-systemic-identity-violation.md).
\* A safe identifier MUST refuse to disambiguate -> NULL.

MatchesIn(creds, tok) == { a \in Agents : tok \in creds[a] }

IdentifyIn(creds, tok) ==
    IF tok = NULL THEN NULL
    ELSE IF MatchesIn(creds, tok) = {} THEN NULL
    ELSE IF Cardinality(MatchesIn(creds, tok)) > 1 THEN NULL
    ELSE CHOOSE a \in MatchesIn(creds, tok) : TRUE

\* The store's answer now.
Identify(tok) == IdentifyIn(credentials, tok)

\* What one agent's credential can be replaced with: revoked, or one token.
CredentialValues == {{}} \cup { {t} : t \in Tokens }

Unread == [l \in Layers |-> UNREAD]

\* ── Type invariant ──────────────────────────────────────────

TypeOK ==
    /\ credentials \in [Agents -> SUBSET Tokens]
    /\ door_credentials \in [Agents -> SUBSET Tokens]
    /\ request_token \in (Tokens \cup {NULL})
    /\ resolved_agent \in (Agents \cup {NULL})
    /\ decision \in {"Allow", "Deny", "Pending"}
    /\ seen \in [Layers -> (Agents \cup {NULL, UNREAD})]

\* ── Init ────────────────────────────────────────────────────
\* Deterministic credential assignment so the spec explores a single
\* initial state and "t_stale" is, at first, the token NOT owned by any
\* agent (mirrors a rotated-out token still cached by the dashboard
\* browser; admin.json was rotated twice on 2026-04-27).

InitialCredentials == [a \in Agents |->
    IF a = "a1" THEN {"t1"}
    ELSE IF a = "a2" THEN {"t2"}
    ELSE IF a = "dashboard" THEN {"t3"}
    ELSE {}]

Init ==
    /\ credentials = InitialCredentials
    /\ door_credentials = InitialCredentials
    /\ request_token = NULL
    /\ resolved_agent = NULL
    /\ decision = "Pending"
    /\ seen = Unread

\* ── Honest actions (clean spec) ─────────────────────────────

\* Receive a request: the network hands us a token (or none).
\* The door reads the store once and identifies the caller from that read.
ReceiveRequest ==
    /\ decision = "Pending"
    /\ resolved_agent = NULL
    /\ \E tok \in (Tokens \cup {NULL}) :
         /\ request_token' = tok
         /\ resolved_agent' = Identify(tok)
    /\ door_credentials' = credentials
    /\ UNCHANGED <<credentials, decision, seen>>

\* Decide policy. Fail-closed: any unresolved principal -> Deny.
DecidePolicy ==
    /\ decision = "Pending"
    /\ request_token /= NULL
    /\ IF resolved_agent = NULL
       THEN decision' = "Deny"
       ELSE decision' = "Allow"
    /\ UNCHANGED <<credentials, door_credentials, request_token, resolved_agent, seen>>

\* A layer below the door names the caller from the door's principal
\* (Auth.request_principal, Mcp_server_eio_caller_identity.bearer).
LayerReadsDoor(l) ==
    /\ decision = "Allow"
    /\ seen[l] = UNREAD
    /\ seen' = [seen EXCEPT ![l] = resolved_agent]
    /\ UNCHANGED <<credentials, door_credentials, request_token, resolved_agent, decision>>

\* An operator replaces or revokes a credential. It can happen at any time,
\* also between the door and the layers below it (RFC §3.3).
ReplaceCredential(a, s) ==
    /\ credentials' = [credentials EXCEPT ![a] = s]
    /\ UNCHANGED <<door_credentials, request_token, resolved_agent, decision, seen>>

\* Reset for the next request.
Reset ==
    /\ decision \in {"Allow", "Deny"}
    /\ request_token' = NULL
    /\ resolved_agent' = NULL
    /\ decision' = "Pending"
    /\ seen' = Unread
    /\ door_credentials' = credentials
    /\ UNCHANGED credentials

\* Terminal stutter (prevents TLC deadlock false-positives at Allow/Deny).
Done ==
    /\ decision \in {"Allow", "Deny"}
    /\ UNCHANGED vars

\* ── Bug actions ─────────────────────────────────────────────
\* SilentRewrite (SpecBuggy) models the production code at
\* lib/server/server_auth.ml:183, 210, 233:
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
    /\ UNCHANGED <<credentials, door_credentials, request_token, decision, seen>>

\* LayerRereadsToken (SpecReread) models a layer that takes the raw token
\* and asks the store again, as tools/call did four to eight times before
\* the RFC: it names the caller from the store as it is now.
LayerRereadsToken(l) ==
    /\ decision = "Allow"
    /\ seen[l] = UNREAD
    /\ seen' = [seen EXCEPT ![l] = Identify(request_token)]
    /\ UNCHANGED <<credentials, door_credentials, request_token, resolved_agent, decision>>

\* ── Spec wirings ────────────────────────────────────────────

Next ==
    \/ ReceiveRequest
    \/ DecidePolicy
    \/ \E l \in Layers : LayerReadsDoor(l)
    \/ \E a \in Agents, s \in CredentialValues : ReplaceCredential(a, s)
    \/ Reset
    \/ Done
NextBuggy == Next \/ SilentRewrite
NextReread == Next \/ \E l \in Layers : LayerRereadsToken(l)

Spec       == Init /\ [][Next]_vars
SpecBuggy  == Init /\ [][NextBuggy]_vars
SpecReread == Init /\ [][NextReread]_vars

\* ── Safety invariants ──────────────────────────────────────
\* I1 and I2 hold over the store the door read. A credential replaced
\* after the door does not change the request's principal; the next
\* request reads the new store (RFC §3.3).

\* I1: every resolved principal owned the token when the door read it.
IdentityBindsToken ==
    (resolved_agent /= NULL) =>
        /\ request_token /= NULL
        /\ request_token \in door_credentials[resolved_agent]

\* I2: the resolved principal must equal the deterministic Identify()
\* over the door's read. Catches silent rewrites that change the principal
\* after identification.
NoSilentRewrite ==
    (resolved_agent /= NULL) =>
        (IdentifyIn(door_credentials, request_token) = resolved_agent)

\* I3: no token => no Allow decision.
\* The pending decision is acceptable (transient); only Allow is forbidden.
FailClosedDefault ==
    (request_token = NULL) => (decision \in {"Pending", "Deny"})

\* I4: a layer that named the caller named the door's principal.
OneIdentityPerRequest ==
    \A l \in Layers : (seen[l] /= UNREAD) => (seen[l] = resolved_agent)

SafetyInvariant ==
    /\ IdentityBindsToken
    /\ NoSilentRewrite
    /\ FailClosedDefault
    /\ OneIdentityPerRequest

====
