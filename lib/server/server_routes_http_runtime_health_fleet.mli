(** Server_routes_http_runtime_health_fleet — fleet-level health field helpers.

    Extracted from [server_routes_http_runtime.ml] during godfile decomposition.
    Contains keeper reaction ledger, FD accountant, fleet resolution,
    runtime truth, and contract-verification health JSON renderers. *)

val take : int -> 'a list -> 'a list

val keeper_reaction_ledger_health_json : unit -> Yojson.Safe.t

val keeper_turn_admission_health_json : unit -> Yojson.Safe.t

val keeper_board_event_collection_health_json : unit -> Yojson.Safe.t

val paused_keeper_count : Yojson.Safe.t -> int

val bool_field : string -> Yojson.Safe.t -> bool

val runtime_base_path_opt : unit -> string option

val keeper_fleet_runtime_resolution_base_fields :
  ?meta_scan:Server_routes_http_runtime_fleet_scan.keeper_fleet_meta_scan ->
  ?include_reaction_ledger:bool ->
  unit ->
  (string * Yojson.Safe.t) list

val fd_accountant_snapshot_json : unit -> Yojson.Safe.t

val runtime_truth_json :
  build:Build_identity.t ->
  path_diagnostics:Server_base_path_diagnostics.t ->
  keeper_fibers:int ->
  fd_accountant:Yojson.Safe.t ->
  Yojson.Safe.t

val keeper_fleet_runtime_resolution_fields :
  unit -> (string * Yojson.Safe.t) list

val keeper_fleet_runtime_resolution_light_fields :
  unit -> (string * Yojson.Safe.t) list
