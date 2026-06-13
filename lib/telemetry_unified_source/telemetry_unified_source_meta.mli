(** Metadata and store discovery helpers for unified telemetry sources. *)

open Telemetry_unified_source

val observe_source_read_failure : source -> site:string -> error:string -> unit
val observe_source_read_failure_exn : source -> site:string -> exn -> unit
val protect_source_read : source -> site:string -> default:'a -> (unit -> 'a) -> 'a

type read_result = {
  entries : Yojson.Safe.t list;
  total_matching_entries : int;
  truncated : bool;
}

val fixed_store_dir : masc_root:string -> base_path:string -> source -> string option
val source_freshness_slo_s : source -> float
val source_producer : source -> string
val source_dashboard_surface : source -> string
val source_durable_store : masc_root:string -> base_path:string -> source -> string
val source_metadata_fields : base_path:string -> masc_root:string -> source -> (string * Yojson.Safe.t) list
val replay_retention_json : base_path:string -> masc_root:string -> sources:source list -> Yojson.Safe.t

type store_dir_state =
  | Store_missing
  | Store_directory
  | Store_invalid

val classify_store_dir : source -> site:string -> string -> store_dir_state
val discover_keeper_metric_dirs : string -> (string * string) list
val is_directory : source -> site:string -> string -> bool
val is_jsonl_file : source -> site:string -> string -> bool
val discover_trajectory_keeper_dirs_in_root : string -> (string * string) list
val discover_trajectory_keeper_dirs : string -> (string * string) list
val discover_execution_receipt_dirs : string -> (string * string) list
