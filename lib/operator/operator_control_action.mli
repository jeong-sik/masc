(** Operator_control_action — operator action / judgment helpers.

    Layered between {!Operator_control_snapshot} (state-readonly) and
    {!Operator_control} (exposed dispatcher).  Adds:

    - Judgment surface validation + write/latest JSON dispatchers.
    - {!action_request} record + parsers from raw JSON args.
    - {!generate_confirm_token} (collision-retry with exponential
      backoff).
    - {!preview_of_action} for UI confirmation panes.

    {b Include runtime:} starts with [include Operator_control_snapshot]
    so {!Operator_control}'s [include] propagates the snapshot
    surface (notably the [\\'a context] type) through.  Internal
    helpers ([judgment_surface_enums], [normalize_judgment_*],
    [default_fresh_ttl_sec], [normalize_action_target_type],
    [default_target_type_for], [require_payload_field]) stay
    private. *)

include module type of struct
  include Operator_control_snapshot
end

(** {1 Judgment dispatchers} *)

val judgment_write_json :
  'a context -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** [judgment_write_json ctx args] records an
    {!Operator_judgment} entry parsed from [args].  Required fields:

    - [surface]: ["command.namespace"] or ["intervene"].
    - [target_type]: ["workspace"].
    - [summary] (non-empty after trim).

    Optional: [target_id], [fresh_ttl_sec] (default 60s for
    command.namespace, 300s for intervene, 120s otherwise; floored
    at 1), [confidence] (default 0.5), [keeper_name],
    [evidence_refs] (string list), [recommended_action] (object),
    [model_name], [runtime_name], [fallback_used] (bool, default
    false), [disagreement_with_truth] (bool, default false).

    Returns [Ok \`Assoc \[("status", "ok"); ("judgment", ...)\]] on
    success, [Error msg] on validation failure. *)

val judgment_latest_json :
  'a context -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** [judgment_latest_json ctx args] reads the most-recent active
    judgment matching [(surface, target_type, target_id)].  Required
    fields: [surface], [target_type].  Optional: [target_id],
    [require_fresh] (default [true]).  When [require_fresh = true],
    judgments past their [fresh_until] window are filtered to [None]. *)

(** {1 Action request} *)

type action_request = {
  actor : string;
  action_type : string;
  target_type : string;
  target_id : string option;
  payload : Yojson.Safe.t;
}
(** Parsed operator action — output of {!action_request_of_args}. *)

val canonical_action_type : string -> string
(** [canonical_action_type t] is the remaining parser seam for
    action-type normalization. Historical aliases are intentionally no
    longer accepted here; callers must use canonical action types. *)

val generate_confirm_token :
  clock:_ Eio.Time.clock -> Workspace.config -> (string, string) result
(** [generate_confirm_token ~clock config] returns a 36-char token
    of the form ["opc_" ^ <32-char-token-suffix>].  Handles
    collisions:

    - 10 retry attempts.
    - Exponential backoff: 1ms -> 2ms -> 4ms -> ... -> ~512ms.
    - On exhaustion: [Error "failed to generate unique confirm token
      after 10 attempts (...)"] including the current pending-confirm
      count (operator-actionable diagnostic). *)

val resolved_actor_for_args :
  ?actor_hint:string ->
  'a context ->
  Yojson.Safe.t ->
  (string, string) result
(** [resolved_actor_for_args ?actor_hint ctx args] picks the actor
    string in priority order: [actor_hint] (trimmed) -> [args.actor]
    (trimmed) -> {!normalized_actor} fallback to [ctx.agent_name].
    Always returns [Ok _]; [string result] is for caller chaining
    via {!Result.Syntax}. *)

val action_request_of_args :
  ?actor_hint:string ->
  'a context ->
  Yojson.Safe.t ->
  (action_request, string) result
(** [action_request_of_args ?actor_hint ctx args] parses an
    [action_request] from raw JSON.  Applies trim/lowercase
    normalization to [action_type] and falls back to the type-specific
    default target_type (see internal [default_target_type_for]) when
    [args.target_type] is missing. *)

val normalize_request_target_type :
  action_request -> (action_request, string) result
(** [normalize_request_target_type r] returns [r] with [target_type]
    validated against the allowed set ([workspace] / [keeper] / [goal] / [""]).
    Empty [target_type] is replaced by the action-type default.
    Invalid inputs return the canonical operator-target validation error. *)

val delegated_tool_for : string -> string
(** [delegated_tool_for action_type] returns the tool name for an
    action_type by lookup into
    {!Operator_pending_confirm.available_actions}; returns
    ["unknown"] when no match exists.  Used for confirm-step routing
    so the JSON contract knows which tool will receive the call. *)

val confirm_required : string -> bool
(** Re-export of {!Operator_action_catalog.requires_confirmation}. Pinned here
    to keep the action contract surface in one place. *)

val preview_of_action : action_request -> Yojson.Safe.t
(** [preview_of_action r] renders a JSON preview for UI
    confirmation panes.  Schema:

    {[
      {
        "actor": <string>,
        "action_type": <string>,
        "target_type": <string>,
        "target_id": <string|null>,
        "payload": <object>  (* empty when payload is not [`Assoc] *)
      }
    ]} *)

val validate_target_type :
  Operator_action_constants.target_type -> action_request -> (unit, string) result
(** [validate_target_type expected r] returns [Ok ()] iff
    [r.target_type] decodes to [expected] through the operator target-type
    SSOT; otherwise
    [Error "invalid target_type for <action_type> (expected
    <expected>)"]. *)

val require_target_id : action_request -> (string, string) result
(** [require_target_id r] returns [Ok id] iff
    [r.target_id = Some id]; otherwise
    [Error "target_id is required"]. *)
