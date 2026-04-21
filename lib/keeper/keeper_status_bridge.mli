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

type runtime_blocker_surface = {
  blocker_class : string;
  summary : string;
  continue_gate : bool;
}

val blocker_class_of_sdk_error :
  Oas.Error.sdk_error -> blocker_class option

val runtime_blocker_surface_of_typed_class :
  ?summary:string -> blocker_class -> runtime_blocker_surface

val runtime_blocker_surface_of_failure_reason :
  Keeper_registry.failure_reason -> runtime_blocker_surface option

val runtime_blocker_surface_of_reason :
  string -> runtime_blocker_surface option

val string_list_to_json : string list -> Yojson.Safe.t

val drift_surface_json : unit -> Yojson.Safe.t

val auto_execution_session_surface_json : unit -> Yojson.Safe.t

val coordination_surface_json : keeper_meta -> Yojson.Safe.t

val live_override_fields :
  keeper_meta -> keeper_profile_defaults -> string list

val runtime_keepalive_running :
  Coord_utils.config -> keeper_meta -> bool

val runtime_keepalive_started_at :
  Coord_utils.config -> keeper_meta -> float option

val runtime_blocker_fields_json :
  Coord_utils.config -> keeper_meta -> (string * Yojson.Safe.t) list

val social_model_resolution_fields_json :
  keeper_meta -> (string * Yojson.Safe.t) list

val social_runtime_fields_json :
  keeper_meta -> (string * Yojson.Safe.t) list

val runtime_surface_json :
  Coord_utils.config -> keeper_meta -> Yojson.Safe.t

val source_provenance_json :
  Coord_utils.config -> keeper_meta -> Yojson.Safe.t
