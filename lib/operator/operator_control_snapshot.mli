(** Operator_control_snapshot — operator dashboard snapshot
    + audit cache.

    The .ml is 1446 lines.  Runtime-includes
    {!Operator_pending_confirm} and {!Operator_digest} so
    callers can reach the pending-confirm + digest surface
    via [Operator_control_snapshot.X].  Type identity
    propagates end-to-end through
    [include module type of struct include M end]
    (cycle 187 rationale).

    External surface:
    - {!invalidate_snapshot_cache}
      (production caller [server_dashboard_http_keeper_api]).
    - {!valid_snapshot_view_strings},
      {!snapshot_view_of_string_opt}, {!snapshot_view}
      (the [masc_operator_snapshot] tool schema's [view] enum is a
      literal in [config/tools/masc_operator_snapshot.toml]; the
      enum-mirror test pins it against this list).
    - {!get_payload} (runtime-include
      consumer {!Operator_control_action} reaches it
      unqualified).

    Internal helpers stay private at this boundary
    (everything else — see body of the .ml.  Notably:
    the operator snapshot cache implementation in
    {!Operator_control_snapshot_cache}, the Keeper context-observation
    projection,
    [action_result_status] / [confirmation_state] /
    [action_log_entry] types and their stringifiers,
    [action_log_path],
    [remote_confirm_ttl_seconds],
    [remote_client_type_of_context],
    [operator_server_profile_json],
    [action_log_entry_to_yojson], the snapshot dispatcher
    family).

    Runtime pattern: {!Operator_control_action} does
    [include Operator_control_snapshot] in its .ml + .mli;
    every entry exposed at this boundary therefore
    transitively re-exposed at the action layer. *)

module U = Yojson.Safe.Util
(** Yojson utilities re-exported because
    {!Operator_control_action} reaches them via the
    runtime-include of this module. *)

include module type of struct
  include Operator_pending_confirm
end

include module type of struct
  include Operator_digest
end


(** {1 Snapshot cache} *)

(** {1 Snapshot view variant} *)

type snapshot_view =
  | Summary
  | Keepers
  | Messages
  | Full
  (** Selectors for the operator dashboard's per-section
      snapshot.  [Summary] is the lightweight default;
      [Full] is reserved for diagnostic dumps. *)

val snapshot_view_to_string : snapshot_view -> string
(** Inverse of {!snapshot_view_of_string_opt}. *)

val valid_snapshot_view_strings : string list
(** Wire forms accepted by {!snapshot_view_of_string_opt}.
    The [masc_operator_snapshot] tool schema's [view] enum is a
    literal in [config/tools/masc_operator_snapshot.toml]; the
    enum-mirror test compares it against this list so adding a
    constructor fails the suite until the file follows. *)

val snapshot_view_of_string_opt : string -> snapshot_view option
(** Trim- and case-insensitive parser ({!Summary} ↔
    [summary], etc).  Returns [None] for inputs not in
    {!valid_snapshot_view_strings}. *)

(** {1 Runtime-include consumer re-exports} *)

val remote_confirm_ttl_seconds : float
(** TTL applied to remote-confirmation pending entries
    (15 minutes).  Pinned because
    {!Operator_control} reads it via the runtime-include
    of this module to compute expiration timestamps. *)

type action_result_status = ActionOk | ActionDeferred | ActionError

type confirmation_state =
  | Preview
  | Immediate
  | Expired
  | Denied
  | Confirmed

val action_result_status_to_string : action_result_status -> string
val confirmation_state_to_string : confirmation_state -> string

type action_log_entry = {
  trace_id : string;
  actor : string;
  remote_session_id : string option;
  remote_client_type : string;
  action_type : string;
  target_type : string;
  target_id : string option;
  delegated_tool : string;
  confirmation_state : confirmation_state;
  result_status : action_result_status;
  latency_ms : int;
  created_at : string;
}

val append_action_log :
  Workspace.config -> action_log_entry -> unit
(** Appends [entry] to the operator action log JSONL.
    Pinned because {!Operator_control} reaches it via the
    runtime-include of this module. *)

val remote_client_type_of_context : 'a context -> string
(** Classifies the [mcp_session_id] of an operator
    request context into a wire string (["dashboard"] /
    ["mcp"] / ["unknown"]).  Pinned because
    {!Operator_control} reaches it via the runtime-include
    of this module.  ['a context] comes from
    {!Operator_pending_confirm}. *)

(** {1 Snapshot cache access} *)

include module type of struct
  include Operator_control_snapshot_cache
end
(** Re-exports {!Operator_control_snapshot_cache.get_or_compute},
    {!Operator_control_snapshot_cache.peek},
    {!Operator_control_snapshot_cache.invalidate_snapshot_cache}, and
    {!Operator_control_snapshot_cache.stats} at the operator snapshot boundary. *)

(** {1 Snapshot + recent actions JSON} *)

val snapshot_json :
  ?actor:string ->
  ?view:string ->
  ?include_messages:bool ->
  ?include_keepers:bool ->
  ?include_summary_fields:bool ->
  ?lightweight_summary:bool ->
  'a context ->
  Yojson.Safe.t
(** Renders the full operator dashboard snapshot.
    Singleflight-cached under
    {!_snapshot_table} keyed by the context config +
    actor + view + include flags.  Pinned because
    {!Operator_control} re-exposes it via the
    runtime-include of this module. *)

val recent_actions_json : Workspace.config -> Yojson.Safe.t
(** Returns the most recent operator-action log entries
    as a [`List].  Returns [`List []] when the log file
    is missing.  Pinned for the same runtime-include
    reason as {!snapshot_json}. *)

val get_payload : Yojson.Safe.t -> Yojson.Safe.t
(** Extracts the [payload] field from a JSON args object,
    returning [`Null] when the field is missing or not an
    [`Assoc].  Pinned for the same runtime-include
    consumer reason as {!iso_of_unix}. *)

(** {1 Keeper slot helper (PR-C2)} *)

val with_keeper_slot :
  sem:Eio.Semaphore.t ->
  name:string ->
  (unit -> 'a) ->
  'a
(** Runs [f] after acquiring [sem], then releases [sem]
    via a [Fun.protect ~finally] scope so the slot is
    released on the normal-exit, exception, and
    [Eio.Cancel.Cancelled] paths (no double-release).
    Pinned for the white-box test suite
    [test/test_operator_control_snapshot_state.ml]
    which exercises the slot accounting invariant
    independent of [keepers_json].  Mirrors PR-B's
    typed-state pattern in spirit (no separate counter
    for the per-fiber slot) but expressed as a scope
    rather than a state transition. *)
