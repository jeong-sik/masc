(** Keeper status surface helpers — JSON projections for dashboard/operator.

    These functions project keeper runtime state (meta, defaults, config)
    into JSON structures consumed by the dashboard and operator control
    endpoints.

    Without this .mli, OCaml may generate an empty module interface when
    types from other modules (keeper_meta, keeper_profile_defaults) escape
    through return types. This caused phantom module issues in CI (#2894).

    @since 2.130.0
    @since 2.149.0 — .mli added to stabilize module interface *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

type runtime_blocker_surface = {
  blocker_class : string;
  summary : string;
}

val blocker_class_of_core_error :
  Agent_core.Error.t -> blocker_class option

val runtime_blocker_surface_of_failure_reason :
  Keeper_registry.failure_reason -> runtime_blocker_surface option

val auto_execution_session_surface_json : unit -> Yojson.Safe.t

val workspace_surface_json : keeper_meta -> Yojson.Safe.t

val live_override_fields :
  keeper_meta -> keeper_profile_defaults -> string list

val runtime_keepalive_running :
  Workspace_utils.config -> keeper_meta -> bool

val runtime_keepalive_started_at :
  Workspace_utils.config -> keeper_meta -> float option

val runtime_blocker_fields_json :
  Workspace_utils.config -> keeper_meta -> (string * Yojson.Safe.t) list

type approval_queue_attention =
  | Approval_queue_ready of int
  | Approval_queue_unavailable of Keeper_approval_queue.storage_error

val attention_fields_json_with_approval_queue :
  Workspace_utils.config ->
  keeper_meta ->
  approval_queue_attention ->
  (string * Yojson.Safe.t) list

val attention_fields_json :
  Workspace_utils.config -> keeper_meta -> (string * Yojson.Safe.t) list

val attention_fields_with_runtime_trust :
  (string * Yojson.Safe.t) list -> Yojson.Safe.t -> (string * Yojson.Safe.t) list

val runtime_surface_json :
  Workspace_utils.config -> keeper_meta -> Yojson.Safe.t

val source_provenance_json :
  Workspace_utils.config -> keeper_meta -> Yojson.Safe.t
