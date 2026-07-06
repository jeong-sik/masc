(** Operator_control_snapshot — operator dashboard snapshot
    + audit cache + runtime-status alignment helpers.

    The .ml is 1446 lines.  Runtime-includes
    {!Operator_pending_confirm} and {!Operator_digest} so
    callers can reach the pending-confirm + digest surface
    via [Operator_control_snapshot.X].  Type identity
    propagates end-to-end through
    [include module type of struct include M end]
    (cycle 187 rationale).

    External surface:
    - {!merge_json_objects}, {!invalidate_snapshot_cache}
      (production callers
      [server_bootstrap_loops] /
      [server_dashboard_http_keeper_api]).
    - {!valid_snapshot_view_strings},
      {!snapshot_view_of_string_opt}, {!snapshot_view}
      (consumed by [tool_operator] tool schema +
      [test/test_types]).
    - {!align_keeper_runtime_status}
      (test-only direct caller).
    - {!get_payload} (runtime-include
      consumer {!Operator_control_action} reaches it
      unqualified).

    Internal helpers stay private at this boundary
    (everything else — see body of the .ml.  Notably:
    the operator snapshot cache implementation in
    {!Operator_control_snapshot_cache}, the keeper-context
    snapshot helpers,
    [compute_context_ratio],
    [keeper_context_snapshot] type +
    [keeper_context_snapshot_is_empty] /
    [keeper_context_snapshot_from_metrics_json] /
    [latest_keeper_context_snapshot_from_files] /
    [fallback_keeper_context_snapshot] /
    [keeper_context_snapshot_of_meta] /
    [keeper_context_snapshot_fields],
    [action_result_status] / [confirmation_state] /
    [action_log_entry] types and their stringifiers,
    [action_log_path],
    [remote_confirm_ttl_seconds],
    [runtime_status_from_live_signal],
    [health_state_allows_runtime_status_override],
    [remote_client_type_of_context],
    [operator_server_profile_json],
    [action_log_entry_to_yojson],
    [cached_tool_audit_json], the snapshot dispatcher
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

(** {1 JSON object merge} *)

val merge_json_objects :
  Yojson.Safe.t -> Yojson.Safe.t -> Yojson.Safe.t
(** Concatenates the field lists of two [`Assoc] objects.
    Returns the right operand untouched when either side
    is not an [`Assoc].  Used by
    [server_bootstrap_loops] when extending the operator
    snapshot envelope with downstream-derived metadata. *)

(** {1 Snapshot cache} *)

val invalidate_snapshot_cache : unit -> unit
(** Drops every cached operator snapshot entry.  Called
    automatically by the keeper-mutation routes
    ([server_dashboard_http_keeper_api]) so the next
    snapshot read sees fresh state.  No-op when the
    {!Eio_guard} runtime is not yet ready (the cache is
    empty in that case). *)

(** {1 Snapshot view variant} *)

type snapshot_view =
  | Summary
  | Sessions
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
    Mirrored into the [tool_operator] tool schema's
    [view] enum field via this surface so adding a
    constructor automatically updates both the parser
    and the schema's user-visible catalogue. *)

val snapshot_view_of_string_opt : string -> snapshot_view option
(** Trim- and case-insensitive parser ({!Summary} ↔
    [summary], etc).  Returns [None] for inputs not in
    {!valid_snapshot_view_strings}. *)

(** {1 Runtime-status alignment} *)

val align_keeper_runtime_status :
  surface_status:string ->
  diagnostic:Yojson.Safe.t ->
  agent_status_json:Yojson.Safe.t ->
  keepalive_running:bool ->
  string
(** Aligns the keeper's surface status (stored on the
    runtime record) with the live signal extracted from
    [agent_status_json] when [keepalive_running = true]
    and the [diagnostic] health state allows the
    override.  Returns the input [surface_status]
    unchanged when keepalive is off or the live signal
    does not promote.  Specifically lifts [inactive] /
    [offline] surface labels to the live runtime status. *)

(** {1 Context ratio} *)

val compute_context_ratio :
  Keeper_meta_contract.keeper_meta -> float option
(** Returns [used_tokens / context_budget] when the
    keeper meta has a resolved context budget, [None]
    otherwise.  Pinned because
    [test/test_operator_control_snapshot.ml] exercises
    the ratio calculation across budget edge cases. *)

(** {1 Runtime-include consumer re-exports} *)

val remote_confirm_ttl_seconds : float
(** TTL applied to remote-confirmation pending entries
    (15 minutes).  Pinned because
    {!Operator_control} reads it via the runtime-include
    of this module to compute expiration timestamps. *)

type action_result_status = ActionOk | ActionError

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

val snapshot_json_result :
  ?actor:string ->
  ?view:string ->
  ?include_messages:bool ->
  ?include_keepers:bool ->
  ?include_summary_fields:bool ->
  ?lightweight_summary:bool ->
  'a context ->
  (Yojson.Safe.t, string) result
(** Result-returning variant of {!snapshot_json}. Read/decode failures in
    authoritative operator projection inputs are returned as [Error] instead of
    being represented as empty sections. *)

val recent_actions_json : Workspace.config -> Yojson.Safe.t
(** Returns the most recent operator-action log entries
    as a [`List].  Returns [`List []] when the log file
    is missing.  Pinned for the same runtime-include
    reason as {!snapshot_json}. *)

val cached_tool_audit_json :
  lightweight:bool ->
  Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  Yojson.Safe.t
(** Returns the cached tool-audit JSON for a keeper.
    [lightweight=true] uses the 120-second stale-fallback
    seed and a 30-second TTL; [lightweight=false] uses a
    2-second TTL for fresh dashboard reads.  Pinned for
    [test/test_operator_control_snapshot.ml]. *)

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
