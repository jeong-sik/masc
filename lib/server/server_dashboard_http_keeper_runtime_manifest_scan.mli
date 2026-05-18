(** Runtime manifest scan state and reader for keeper runtime-trace responses.

    Split from {!Server_dashboard_http_keeper_api}; included back there so
    existing local call sites keep using the same names. *)

type runtime_manifest_scan =
  { path : string
  ; limit : int
  ; returned_rows : Keeper_runtime_manifest.t Queue.t
  ; provider_attempt_rows : Keeper_runtime_manifest.t Queue.t
  ; event_counts : (string, int) Hashtbl.t
  ; mutable total_rows : int
  ; mutable has_terminal : bool
  ; mutable terminal_keeper_turn_ids : int list
  ; mutable max_oas_turn_count : int option
  ; mutable keeper_turn_ids : int list
  ; mutable event_bus_count : int
  ; mutable event_bus_correlation_ids : string list
  ; mutable event_bus_run_ids : string list
  ; mutable context_compact_started_count : int
  ; mutable context_compacted_count : int
  ; mutable last_compaction : Yojson.Safe.t option
  ; mutable memory_injected_count : int
  ; mutable memory_injected_present_count : int
  ; mutable memory_flushed_count : int
  ; mutable memory_flush_success_count : int
  ; mutable memory_flush_error_count : int
  ; mutable episodes_flushed : int
  ; mutable procedures_flushed : int
  ; mutable latest_tool_surface_decision : Yojson.Safe.t option
  ; mutable latest_provider_lane_decision : Yojson.Safe.t option
  ; mutable latest_provider_lane_row : Keeper_runtime_manifest.t option
  ; mutable latest_pre_dispatch_blocked_row : Keeper_runtime_manifest.t option
  ; mutable context_injected_count : int
  ; mutable context_compacted_event_count : int
  ; mutable provider_started_count : int
  ; mutable provider_finished_count : int
  ; mutable provider_terminal_row : Keeper_runtime_manifest.t option
  }

val make_runtime_manifest_scan :
  path:string -> limit:int -> runtime_manifest_scan

val push_bounded : 'a Queue.t -> int -> 'a -> unit
val queue_to_list : 'a Queue.t -> 'a list
val increment_event_count : runtime_manifest_scan -> Keeper_runtime_manifest.event_kind -> unit

val runtime_manifest_scan_event_count :
  runtime_manifest_scan -> Keeper_runtime_manifest.event_kind -> int

val max_int_opt : int option -> int -> int option
val update_runtime_manifest_scan : runtime_manifest_scan -> Keeper_runtime_manifest.t -> unit

val read_runtime_manifest_scan :
  config:Coord.config ->
  keeper_name:string ->
  trace_id:string ->
  ?turn_id:int ->
  limit:int ->
  unit ->
  runtime_manifest_scan
