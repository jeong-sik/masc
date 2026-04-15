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

val string_list_to_json : string list -> Yojson.Safe.t

val drift_surface_json : unit -> Yojson.Safe.t

val auto_execution_session_surface_json : unit -> Yojson.Safe.t

val coordination_surface_json : keeper_meta -> Yojson.Safe.t

val live_override_fields :
  keeper_meta -> keeper_profile_defaults -> string list

val runtime_keepalive_running :
  Room_utils.config -> keeper_meta -> bool

val runtime_keepalive_started_at :
  Room_utils.config -> keeper_meta -> float option

val runtime_blocker_fields_json :
  Room_utils.config -> keeper_meta -> (string * Yojson.Safe.t) list

val runtime_surface_json :
  Room_utils.config -> keeper_meta -> Yojson.Safe.t

val source_provenance_json :
  Room_utils.config -> keeper_meta -> Yojson.Safe.t
