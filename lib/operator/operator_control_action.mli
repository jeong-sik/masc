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
    helpers ([normalize_judgment_*], [default_fresh_ttl_sec]) stay
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
    - [confidence]: a number in 0.0-1.0.

    The judgment's [keeper_name] is the caller's authenticated name.

    Optional: [target_id], [fresh_ttl_sec] (default 60s for
    command.namespace, 300s for intervene; a value below 1 is an error),
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
  action : Operator_action_catalog.t;
  target_id : string option;
  payload : Yojson.Safe.t;
}
(** Parsed operator action — output of {!action_request_of_args}. The action
    is a catalog member; its target type is
    {!Operator_action_catalog.target_type} and is not carried here. *)

val require_payload_field :
  Yojson.Safe.t -> string -> string -> (string, string) result
(** [require_payload_field payload key error] reads a string [key] from
    [payload], or returns [Error error] when it is absent or not a string.
    Exported so the action handlers in {!Operator_control} state the
    requirement once instead of repeating the match at each site. *)

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

val resolved_actor : ?actor_hint:string -> 'a context -> string
(** [resolved_actor ?actor_hint ctx] is the authenticated actor:
    [actor_hint] (trimmed) when non-empty, else {!normalized_actor}'s
    fallback to [ctx.agent_name]. The request body is never read. *)

val action_request_of_args :
  ?actor_hint:string ->
  'a context ->
  Yojson.Safe.t ->
  (action_request, string) result
(** [action_request_of_args ?actor_hint ctx args] parses an
    [action_request] from raw JSON.  [action_type] is trimmed, lowercased
    and looked up in {!Operator_action_catalog}: an empty value is
    [Error "action_type is required"], any other unknown value
    [Error "unsupported action_type: <value>"].  [target_type] may be absent
    or name the action's own target type; a value outside the operator
    target-type set is the canonical target validation error, and a valid
    one the action does not address is
    [Error "invalid target_type for <action_type> (expected <expected>)"]. *)

val action_request_of_pending_confirm :
  pending_confirm -> (action_request, string) result
(** The request a stored pending confirm stands for.  The store only holds
    entries whose [action_type] is in the catalog, so [Error] reports a store
    that broke that contract. *)

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

val require_target_id : action_request -> (string, string) result
(** [require_target_id r] returns [Ok id] iff
    [r.target_id = Some id]; otherwise
    [Error "target_id is required"]. *)
