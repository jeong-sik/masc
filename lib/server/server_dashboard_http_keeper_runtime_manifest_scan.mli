(** Runtime manifest scan state and reader for keeper runtime-trace responses.

    Split from {!Server_dashboard_http_keeper_api}; included back there so
    existing local call sites keep using the same names. *)

type manifest_scan_diagnostic =
  | Retired_event_row of Keeper_runtime_manifest.retired_event_kind
  | Unsupported_event_row of string
  | Invalid_manifest_row of string
  | Invalid_json_row of string

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
  ; mutable latest_provider_lane_decision : Yojson.Safe.t option
  ; mutable latest_provider_lane_row : Keeper_runtime_manifest.t option
  ; mutable latest_pre_dispatch_blocked_row : Keeper_runtime_manifest.t option
  ; mutable payload_role_counts : (string, int) Hashtbl.t
  ; mutable source_clock_counts : (string, int) Hashtbl.t
  ; mutable context_injected_count : int
  ; mutable context_compacted_event_count : int
  ; mutable provider_started_count : int
  ; mutable provider_finished_count : int
  ; mutable provider_terminal_row : Keeper_runtime_manifest.t option
  ; mutable latest_context_injected_row : Keeper_runtime_manifest.t option
  ; mutable latest_context_compacted_row : Keeper_runtime_manifest.t option
  ; mutable dag_edges : (string * string) list
  ; mutable scanned_lines : int
  ; scan_line_limit : int
  ; scan_scope : string
  ; retired_event_counts : (Keeper_runtime_manifest.retired_event_kind, int) Hashtbl.t
  ; unsupported_event_counts : (string, int) Hashtbl.t
  ; mutable unsupported_event_count : int
  ; mutable unsupported_event_unattributed_count : int
  ; mutable invalid_manifest_row_count : int
  ; mutable invalid_json_row_count : int
  ; diagnostic_samples : manifest_scan_diagnostic Queue.t
  }

val make_runtime_manifest_scan :
  path:string ->
  limit:int ->
  scan_line_limit:int ->
  scan_scope:string ->
  runtime_manifest_scan

val push_bounded : 'a Queue.t -> int -> 'a -> unit
val queue_to_list : 'a Queue.t -> 'a list
val runtime_manifest_scan_diagnostics_json : runtime_manifest_scan -> Yojson.Safe.t
val increment_event_count : runtime_manifest_scan -> Keeper_runtime_manifest.event_kind -> unit

val runtime_manifest_scan_event_count :
  runtime_manifest_scan -> Keeper_runtime_manifest.event_kind -> int

val max_int_opt : int option -> int -> int option
val update_runtime_manifest_scan : runtime_manifest_scan -> Keeper_runtime_manifest.t -> unit

val read_runtime_manifest_scan :
  config:Workspace.config ->
  keeper_name:string ->
  trace_id:string ->
  ?turn_id:int ->
  limit:int ->
  unit ->
  runtime_manifest_scan
