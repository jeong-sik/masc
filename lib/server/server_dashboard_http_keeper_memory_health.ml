(** Read-only fleet health for the current Memory OS snapshot. *)

type keeper_health =
  { keeper_id : string
  ; revision : int
  ; facts : int
  ; snapshot_bytes : int
  ; added : int
  ; removed : int
  ; snapshot_present : bool
  ; librarian_lane_busy : int
  ; librarian_failures : int
  ; read_error : string option
  }

let librarian_lane_busy_metric =
  Keeper_metrics.(to_string MemoryLaneCoalesced)
;;

let librarian_failures_metric =
  Keeper_metrics.(to_string MemoryOsLibrarianFailures)
;;

let file_size_bytes path =
  if Sys.file_exists path then (Unix.stat path).Unix.st_size else 0
;;

let librarian_lane_busy_for_keeper keeper_id =
  Otel_metric_store.metric_value_or_zero
    librarian_lane_busy_metric
    ~labels:[ "keeper", keeper_id; "lane", "librarian" ]
    ()
  |> int_of_float
;;

(* Labels mirror the counter increments in [Keeper_librarian_runtime]. *)
let librarian_failures_for_keeper keeper_id =
  Otel_metric_store.metric_value_or_zero
    librarian_failures_metric
    ~labels:[ "keeper", keeper_id; "site", "memory_os_librarian" ]
    ()
  |> int_of_float
;;

(* A keeper with a config but no current snapshot is the starvation case this
   endpoint exists to expose; enumerating snapshot files alone gives it no
   row at all. Health rows therefore come from the union of configured
   keepers (<keeper>.toml) and existing snapshots. *)
let keeper_config_suffix = ".toml"

let configured_keeper_ids ~keepers_dir =
  if not (Sys.file_exists keepers_dir && Sys.is_directory keepers_dir)
  then []
  else
    Sys.readdir keepers_dir
    |> Array.to_list
    |> List.filter_map (Filename.chop_suffix_opt ~suffix:keeper_config_suffix)
;;

let health_keeper_ids ~keepers_dir =
  configured_keeper_ids ~keepers_dir
  @ Keeper_memory_os_current.list_keeper_ids_for_keepers_dir ~keepers_dir
  |> List.sort_uniq String.compare
;;

let keeper_health ~keepers_dir keeper_id =
  let snapshot_path =
    Keeper_memory_os_current.path_for_keepers_dir ~keepers_dir ~keeper_id
  in
  match
    Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id
  with
  | Ok None ->
    { keeper_id
    ; revision = 0
    ; facts = 0
    ; snapshot_bytes = 0
    ; added = 0
    ; removed = 0
    ; snapshot_present = false
    ; librarian_lane_busy = librarian_lane_busy_for_keeper keeper_id
    ; librarian_failures = librarian_failures_for_keeper keeper_id
    ; read_error = None
    }
  | Ok (Some snapshot) ->
    { keeper_id
    ; revision = snapshot.revision
    ; facts = List.length snapshot.facts
    ; snapshot_bytes = file_size_bytes snapshot_path
    ; added = List.length snapshot.change.added
    ; removed = List.length snapshot.change.removed
    ; snapshot_present = true
    ; librarian_lane_busy = librarian_lane_busy_for_keeper keeper_id
    ; librarian_failures = librarian_failures_for_keeper keeper_id
    ; read_error = None
    }
  | Error message ->
    { keeper_id
    ; revision = 0
    ; facts = 0
    ; snapshot_bytes = file_size_bytes snapshot_path
    ; added = 0
    ; removed = 0
    ; snapshot_present = false
    ; librarian_lane_busy = librarian_lane_busy_for_keeper keeper_id
    ; librarian_failures = librarian_failures_for_keeper keeper_id
    ; read_error = Some message
    }
;;

let alert_json ~code ~severity ~target ~label ~message ~value =
  `Assoc
    [ "code", `String code
    ; "severity", `String severity
    ; "target", `String target
    ; "label", `String label
    ; "message", `String message
    ; "value", `Float value
    ; "threshold", `Float 0.0
    ]
;;

let alerts h =
  let read_error_alert =
    match h.read_error with
    | None -> []
    | Some message ->
      [ alert_json
          ~code:"snapshot_read_error"
          ~severity:"warn"
          ~target:"snapshot_read_error"
          ~label:"읽기"
          ~message
          ~value:1.0
      ]
  in
  let lane_busy_alert =
    if h.librarian_lane_busy <= 0
    then []
    else
      [ alert_json
          ~code:"librarian_lane_busy"
          ~severity:"warn"
          ~target:"librarian_lane_busy"
          ~label:"Librarian"
          ~message:
            "The Librarian memory lane was busy; current-memory selection was deferred."
          ~value:(float_of_int h.librarian_lane_busy)
      ]
  in
  let failure_alert =
    if h.librarian_failures <= 0
    then []
    else if h.snapshot_present
    then
      [ alert_json
          ~code:"librarian_failures"
          ~severity:"warn"
          ~target:"librarian_failures"
          ~label:"Librarian"
          ~message:
            "Librarian runs failed since boot; the existing current-memory snapshot keeps serving recall but is no longer being updated."
          ~value:(float_of_int h.librarian_failures)
      ]
    else
      [ alert_json
          ~code:"librarian_starvation"
          ~severity:"error"
          ~target:"librarian_starvation"
          ~label:"Librarian"
          ~message:
            "Librarian runs failed and no current-memory snapshot exists; the keeper is running memoryless and cannot leave that state on its own."
          ~value:(float_of_int h.librarian_failures)
      ]
  in
  read_error_alert @ lane_busy_alert @ failure_alert
;;

let alert_severity = function
  | `Assoc fields ->
    (match List.assoc_opt "severity" fields with
     | Some (`String severity) -> severity
     | _ -> "warn")
  | _ -> "warn"
;;

let keeper_health_entry_to_json h =
  `Assoc
    [ "keeper_id", `String h.keeper_id
    ; "revision", `Int h.revision
    ; "facts", `Int h.facts
    ; "snapshot_bytes", `Int h.snapshot_bytes
    ; "added", `Int h.added
    ; "removed", `Int h.removed
    ; "snapshot_present", `Bool h.snapshot_present
    ; "librarian_lane_busy", `Int h.librarian_lane_busy
    ; "librarian_failures", `Int h.librarian_failures
    ; ( "read_error"
      , match h.read_error with
        | Some message -> `String message
        | None -> `Null )
    ; "alerts", `List (alerts h)
    ]
;;

let keeper_memory_health_http_json ~base_path =
  let generated_at = Time_compat.now () in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path
  in
  let entries =
    health_keeper_ids ~keepers_dir
    |> List.map (keeper_health ~keepers_dir)
    |> List.sort (fun left right ->
      compare right.snapshot_bytes left.snapshot_bytes)
  in
  let sum field =
    List.fold_left (fun total entry -> total + field entry) 0 entries
  in
  let all_alerts = List.concat_map alerts entries in
  let count_severity severity =
    List.length
      (List.filter
         (fun alert -> String.equal (alert_severity alert) severity)
         all_alerts)
  in
  `Assoc
    [ "schema", `String "keeper.memory_os.current_health.v1"
    ; "generated_at", `Float generated_at
    ; ( "cadence_counter_entries"
      , `Int (Keeper_librarian_runtime.cadence_counter_entries ()) )
    ; "keepers", `List (List.map keeper_health_entry_to_json entries)
    ; ( "totals"
      , `Assoc
          [ "facts", `Int (sum (fun entry -> entry.facts))
          ; "snapshot_bytes", `Int (sum (fun entry -> entry.snapshot_bytes))
          ; "added", `Int (sum (fun entry -> entry.added))
          ; "removed", `Int (sum (fun entry -> entry.removed))
          ; ( "librarian_lane_busy"
            , `Int (sum (fun entry -> entry.librarian_lane_busy)) )
          ; ( "librarian_failures"
            , `Int (sum (fun entry -> entry.librarian_failures)) )
          ; ( "read_errors"
            , `Int
                (sum (fun entry ->
                   match entry.read_error with
                   | Some _ -> 1
                   | None -> 0)) )
          ] )
    ; ( "alert_summary"
      , `Assoc
          [ "total_alerts", `Int (List.length all_alerts)
          ; "warn_alerts", `Int (count_severity "warn")
          ; "error_alerts", `Int (count_severity "error")
          ; ( "keepers_with_alerts"
            , `Int
                (sum (fun entry ->
                   if alerts entry = [] then 0 else 1)) )
          ; ( "snapshot_read_error_keepers"
            , `Int
                (sum (fun entry ->
                   match entry.read_error with
                   | Some _ -> 1
                   | None -> 0)) )
          ; ( "librarian_lane_busy_keepers"
            , `Int
                (sum (fun entry ->
                   if entry.librarian_lane_busy > 0 then 1 else 0)) )
          ; ( "librarian_starving_keepers"
            , `Int
                (sum (fun entry ->
                   if entry.librarian_failures > 0 && not entry.snapshot_present
                   then 1
                   else 0)) )
          ] )
    ]
;;
