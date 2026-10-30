(** Runtime manifest scan state and reader for keeper runtime-trace responses.

    Split from {!Server_dashboard_http_keeper_api}; included back there so
    existing local call sites keep using the same names. *)

type manifest_scan_diagnostic =
  | Unsupported_event_row of string
  | Invalid_manifest_row of string
  | Invalid_json_row of string

type runtime_manifest_scan =
  { path : string
  ; limit : int
  ; returned_rows : Keeper_runtime_manifest.t Queue.t
  ; event_counts : (string, int) Hashtbl.t
  ; total_rows : int
  ; has_terminal : bool
  ; terminal_row : Keeper_runtime_manifest.t option
  ; terminal_keeper_turn_ids : int list
  ; max_agent_core_turn_count : int option
  ; keeper_turn_ids : int list
  ; event_bus_count : int
  ; event_bus_correlation_ids : string list
  ; event_bus_run_ids : string list
  ; latest_provider_lane_decision : Yojson.Safe.t option
  ; latest_provider_lane_row : Keeper_runtime_manifest.t option
  ; latest_pre_dispatch_blocked_row : Keeper_runtime_manifest.t option
  ; payload_role_counts : (string, int) Hashtbl.t
  ; source_clock_counts : (string, int) Hashtbl.t
  ; context_injected_count : int
  ; latest_context_injected_row : Keeper_runtime_manifest.t option
  ; dag_edges : (string * string) list
  ; scanned_lines : int
  ; scan_line_limit : int
  ; scan_scope : string
  ; unsupported_event_counts : (string, int) Hashtbl.t
  ; unsupported_event_count : int
  ; unsupported_event_unattributed_count : int
  ; invalid_manifest_row_count : int
  ; invalid_json_row_count : int
  ; diagnostic_samples : manifest_scan_diagnostic Queue.t
  }

val make_runtime_manifest_scan :
  path:string ->
  limit:int ->
  scan_line_limit:int ->
  scan_scope:string ->
  runtime_manifest_scan

val queue_to_list : 'a Queue.t -> 'a list
val runtime_manifest_scan_diagnostics_json : runtime_manifest_scan -> Yojson.Safe.t
val runtime_manifest_scan_event_count :
  runtime_manifest_scan -> Keeper_runtime_manifest.event_kind -> int

(** Fold one manifest row into the scan. Returns the updated scan; the
    [Queue.t] and [Hashtbl.t] fields are shared with the argument and are
    still mutated in place. *)
val update_runtime_manifest_scan :
  runtime_manifest_scan -> Keeper_runtime_manifest.t -> runtime_manifest_scan

val read_runtime_manifest_scan :
  config:Workspace.config ->
  keeper_name:string ->
  trace_id:string ->
  ?turn_id:int ->
  limit:int ->
  unit ->
  runtime_manifest_scan
