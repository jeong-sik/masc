(** Goal_verification — quorum-style verifier sign-off
    persisted alongside the goal store.

    Holds the data contract + persistence + workflow for "this
    goal needs N approvals from these principals before it
    can move to [Goal_phase.Completed]".  The state file
    lives at {!requests_path} under [Workspace_utils.masc_dir]; an
    append-only audit trail goes to {!events_path}.

    The yojson [_to_yojson] / [_of_yojson] pairs are written
    by hand because the records hold nested types
    ([Goal_phase.t], polymorphic variants like [`Null]) that
    don't slot cleanly into [@@deriving yojson].  Each
    [_of_yojson] returns a structured error string instead of
    raising — call sites can surface it to the user without
    wrapping a [Yojson.Json_error] handler.

    {b Pinning rationale}: every type is exposed concretely
    because external callers
    ([lib/goal/goal_store.ml], [lib/workspace_goals.ml],
    [lib/tool_goal_*]) pattern-match on the variants
    ([Approve] / [Reject] / [Open] / [Approved] / [Rejected]
    / [Cancelled] / [Extend] / [Replace] / [Pending] /
    [Passed] / [Failed]) and access record fields
    ([policy.principals], [request.goal_id], …) directly. *)

(** {1 Principals} *)

type goal_principal = {
  id : string;
  display_name : string option;
}
(** Identity of a principal eligible to vote on a request.
    [id] is the canonical reviewer name (operator login or agent
    name); [display_name] is the human-readable label
    surfaced in events and dashboards. *)

val goal_principal_to_yojson : goal_principal -> Yojson.Safe.t
val goal_principal_of_yojson :
  Yojson.Safe.t -> (goal_principal, string) result
(** Object round-trip with required [id] (non-empty)
    and optional [display_name]. *)

(** {1 Policy} *)

type inherit_mode =
  | Extend
  | Replace
  (** How a child goal's verifier policy combines with its
      parent's.  [Extend] = union of principals (deduped).
      [Replace] = the child's principals override the
      parent's. *)

type goal_verifier_policy = {
  inherit_mode : inherit_mode;
  principals : goal_principal list;
  required_verdicts : int option;
}
(** Per-goal-node verifier policy.  [principals] is the local
    contribution; [required_verdicts] is required to be
    [Some n] in the {b effective} (resolved-against-lineage)
    policy, but is allowed to be [None] on intermediate nodes
    that only contribute principals via [Extend]. *)

val inherit_mode_to_yojson : inherit_mode -> Yojson.Safe.t
val inherit_mode_of_yojson :
  Yojson.Safe.t -> (inherit_mode, string) result
val goal_verifier_policy_to_yojson :
  goal_verifier_policy -> Yojson.Safe.t
val goal_verifier_policy_of_yojson :
  Yojson.Safe.t -> (goal_verifier_policy, string) result

(** {1 Votes} *)

type vote_decision =
  | Approve
  | Reject
  (** A single principal's verdict.  No "abstain" — non-vote
      is implicit until quorum closes. *)

val vote_decision_to_string : vote_decision -> string
val vote_decision_of_string : string -> vote_decision option
val vote_decision_to_yojson : vote_decision -> Yojson.Safe.t
val vote_decision_of_yojson :
  Yojson.Safe.t -> (vote_decision, string) result

(** {1 Request status} *)

type request_status =
  | Open
  | Approved
  | Rejected
  | Cancelled
  (** [Open] is the only status under which votes are
      accepted.  [Approved] / [Rejected] are sealed by
      {!evaluate_quorum}.  [Cancelled] is set by
      {!cancel_request} and freezes the request without a
      verdict. *)

val request_status_to_yojson : request_status -> Yojson.Safe.t
val request_status_of_yojson :
  Yojson.Safe.t -> (request_status, string) result

(** {1 Resolved policy snapshot} *)

type policy_snapshot = {
  principals : goal_principal list;
  eligible_principals : goal_principal list;
  required_verdicts : int;
}
(** Captured at request creation time.  [principals] is the
    full effective policy lineage; [eligible_principals]
    starts as the same list and may be narrowed by
    {!exclude_requester} (a requester cannot vote on their
    own request).  [required_verdicts] is the quorum
    threshold (>= 1, <= [List.length principals]). *)

val policy_snapshot_to_yojson : policy_snapshot -> Yojson.Safe.t
val policy_snapshot_of_yojson :
  Yojson.Safe.t -> (policy_snapshot, string) result

(** {1 Vote record + request} *)

type goal_verification_vote = {
  principal : goal_principal;
  decision : vote_decision;
  note : string option;
  evidence_refs : string list;
  submitted_at : string;
}
(** Single submitted verdict.  [submitted_at] is the
    ISO-8601 timestamp from {!Masc_domain.now_iso} at submission
    time. *)

val goal_verification_vote_to_yojson :
  goal_verification_vote -> Yojson.Safe.t
val goal_verification_vote_of_yojson :
  Yojson.Safe.t -> (goal_verification_vote, string) result

type goal_verification_request = {
  id : string;
  goal_id : string;
  target_phase : Goal_phase.t;
  requested_by : goal_principal;
  policy_snapshot : policy_snapshot;
  votes : goal_verification_vote list;
  status : request_status;
  created_at : string;
  resolved_at : string option;
  expires_at : string option;
}
(** A single verifier review.  [target_phase] is the goal
    phase whose entry is gated by this request — currently
    always [Goal_phase.Completed] but the field is kept open
    for future phase gates.  [resolved_at] is set when
    [status] transitions out of [Open]. *)

type cancel_request_result =
  | Cancelled_request of goal_verification_request
  | Already_resolved_request of goal_verification_request

val goal_verification_request_to_yojson :
  goal_verification_request -> Yojson.Safe.t
val goal_verification_request_of_yojson :
  Yojson.Safe.t -> (goal_verification_request, string) result

(** {1 State + policy graph} *)

type state = {
  version : int;
  updated_at : string;
  requests : goal_verification_request list;
}
(** On-disk shape persisted to [goal_verifications.json].
    [version] increments on every write so concurrent readers
    can detect drift. *)

type goal_policy_node = {
  goal_id : string;
  parent_goal_id : string option;
  verifier_policy : goal_verifier_policy option;
}
(** One node in the goal-tree projection used by
    {!effective_policy_for_nodes}.  The node's policy may be
    [None] (no local override; inherit only from parents). *)

val state_to_yojson : state -> Yojson.Safe.t
val state_of_yojson : Yojson.Safe.t -> (state, string) result

(** {1 Quorum outcome} *)

type quorum_result =
  | Pending
  | Passed
  | Failed
  (** Outcome of {!evaluate_quorum}.  [Pending] means votes
      are still possible without sealing the request.
      [Passed] / [Failed] mean the request can be sealed
      ([status] flipped to [Approved] / [Rejected]). *)

(** {1 Persistence paths} *)

val requests_path : Workspace_utils.config -> string
(** [{!Workspace_utils.masc_dir} config / "goal_verifications.json"].
    The single state file the workspace backend persists. *)

val events_path : Workspace_utils.config -> string
(** [{!Workspace_utils.masc_dir} config / "goal_events.jsonl"].
    Append-only audit trail; each line is the JSON written by
    {!emit_event}. *)

(** {1 State I/O} *)

val read_state : Workspace_utils.config -> state
(** Reads {!requests_path}; returns the empty default state
    if the file does not exist or fails to parse.  Parse
    errors are silently absorbed — the JSONL events file is
    the durable history if recovery is needed. *)

(** {1 Effective policy resolution} *)

val effective_policy_for_nodes :
  goals:goal_policy_node list ->
  goal_id:string ->
  (policy_snapshot option, string) result
(** Walks the parent chain from [goal_id] up to its root,
    folding each node's {!goal_verifier_policy} according to
    its [inherit_mode] (Extend = dedup union, Replace = wipe
    & set), and projecting the result into a snapshot.
    Returns [Ok None] when no ancestor contributes any
    principal (verification not required).  Errors when the
    [goal_id] is missing from the node list, when the
    effective [required_verdicts] is unset, < 1, or exceeds
    the principal count. *)

val exclude_requester :
  policy_snapshot:policy_snapshot ->
  requested_by:goal_principal ->
  (policy_snapshot, string) result
(** Removes [requested_by] from [eligible_principals].
    Errors when the resulting eligible set is too small to
    satisfy [required_verdicts]. *)

(** {1 Audit trail} *)

val emit_event :
  Workspace_utils.config ->
  goal_id:string ->
  event_type:string ->
  payload:Yojson.Safe.t ->
  unit
(** Appends a JSON line to {!events_path} with [ts] /
    [goal_id] / [event_type] / [payload].  Used by the
    workflow functions below to record state transitions. *)

(** {1 Workflow} *)

val create_request :
  Workspace_utils.config ->
  goal_id:string ->
  requested_by:goal_principal ->
  policy_snapshot:policy_snapshot ->
  (goal_verification_request, string) result
(** Persists a new [Open] request.  [target_phase] is fixed
    to [Goal_phase.Completed].  Holds the file lock for the
    duration so concurrent creates serialize cleanly. *)

val find_request :
  Workspace_utils.config -> request_id:string -> goal_verification_request option
(** Lock-free lookup.  Caller is expected to treat the result
    as a snapshot; for mutation use {!submit_vote} or
    {!cancel_request}. *)

val count_votes :
  decision:vote_decision -> goal_verification_request -> int
(** Number of votes whose [decision] matches the argument. *)

val remaining_possible_votes : goal_verification_request -> int
(** [List.length policy_snapshot.eligible_principals - List.length votes].
    Used by {!evaluate_quorum} to decide whether more
    [Approve]s are reachable. *)

val cancel_request :
  Workspace_utils.config ->
  request_id:string ->
  (goal_verification_request, string) result
(** Flips [status] from [Open] to [Cancelled] and stamps
    [resolved_at].  Idempotent on already-non-[Open]
    requests (returns [Ok request] without mutation).
    Errors when [request_id] is unknown. *)

val cancel_request_if_open :
  Workspace_utils.config ->
  request_id:string ->
  (cancel_request_result, string) result
(** Like {!cancel_request}, but reports whether this call performed the
    [Open] -> [Cancelled] transition or found an already resolved
    request. *)

val submit_vote :
  Workspace_utils.config ->
  goal_id:string ->
  request_id:string ->
  principal:goal_principal ->
  decision:vote_decision ->
  ?note:string ->
  ?evidence_refs:string list ->
  unit ->
  (goal_verification_request * quorum_result, string) result
(** Appends a vote, runs {!evaluate_quorum}, and seals the
    request as needed (Passed → [Approved], Failed →
    [Rejected]).  Returns the updated request paired with the
    quorum verdict so the caller can branch on the outcome
    without re-deriving it.  Holds the file lock for the
    duration.

    Errors on any of:
    - [request_id] unknown,
    - [request_id] belongs to another goal,
    - request is not [Open],
    - [principal] is the original requester,
    - [principal] is not in
      [policy_snapshot.eligible_principals],
    - [principal] has already voted. *)
