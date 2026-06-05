(** Source metadata and discovery helpers for unified telemetry stores. *)

val observe_source_read_failure :
  Telemetry_unified_source.source -> site:string -> error:string -> unit

val observe_source_read_failure_exn :
  Telemetry_unified_source.source -> site:string -> exn -> unit

val protect_source_read :
  Telemetry_unified_source.source ->
  site:string ->
  default:'a ->
  (unit -> 'a) ->
  'a

type read_result = {
  entries : Yojson.Safe.t list;
  total_matching_entries : int;
  truncated : bool;
}

val fixed_store_dir :
  masc_root:string ->
  base_path:string ->
  Telemetry_unified_source.source ->
  string option

val source_freshness_slo_s : Telemetry_unified_source.source -> float
val source_producer : Telemetry_unified_source.source -> string
val source_dashboard_surface : Telemetry_unified_source.source -> string

val source_durable_store :
  masc_root:string -> base_path:string -> Telemetry_unified_source.source -> string

val source_metadata_fields :
  base_path:string ->
  masc_root:string ->
  Telemetry_unified_source.source ->
  (string * Yojson.Safe.t) list

val replay_retention_json :
  base_path:string ->
  masc_root:string ->
  sources:Telemetry_unified_source.source list ->
  Yojson.Safe.t

type store_dir_state =
  | Store_missing
  | Store_directory
  | Store_invalid

val classify_store_dir :
  Telemetry_unified_source.source -> site:string -> string -> store_dir_state

val discover_keeper_metric_dirs : string -> (string * string) list
val is_directory : Telemetry_unified_source.source -> site:string -> string -> bool
val is_jsonl_file : Telemetry_unified_source.source -> site:string -> string -> bool
val discover_trajectory_keeper_dirs_in_root : string -> (string * string) list
val discover_trajectory_keeper_dirs : string -> (string * string) list
val discover_execution_receipt_dirs : string -> (string * string) list
