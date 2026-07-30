(** Read-only fleet health for the current Memory OS snapshot. *)

type keeper_health =
  { keeper_id : string
  ; revision : int
  ; facts : int
  ; snapshot_bytes : int
  ; added : int
  ; removed : int
  ; librarian_lane_busy : int
  ; read_error : string option
  }

let librarian_lane_busy_metric =
  Keeper_metrics.(to_string MemoryLaneExecutionSlotBusy)
;;

let librarian_lane_busy_site = "memory_os_librarian_execution_slot"

let file_size_bytes path =
  if Sys.file_exists path then (Unix.stat path).Unix.st_size else 0
;;

let librarian_lane_busy_for_keeper keeper_id =
  Otel_metric_store.metric_value_or_zero
    librarian_lane_busy_metric
    ~labels:[ "keeper", keeper_id; "site", librarian_lane_busy_site ]
    ()
  |> int_of_float
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
    ; librarian_lane_busy = librarian_lane_busy_for_keeper keeper_id
    ; read_error = None
    }
  | Ok (Some snapshot) ->
    { keeper_id
    ; revision = snapshot.revision
    ; facts = List.length snapshot.facts
    ; snapshot_bytes = file_size_bytes snapshot_path
    ; added = List.length snapshot.change.added
    ; removed = List.length snapshot.change.removed
    ; librarian_lane_busy = librarian_lane_busy_for_keeper keeper_id
    ; read_error = None
    }
  | Error message ->
    { keeper_id
    ; revision = 0
    ; facts = 0
    ; snapshot_bytes = file_size_bytes snapshot_path
    ; added = 0
    ; removed = 0
    ; librarian_lane_busy = librarian_lane_busy_for_keeper keeper_id
    ; read_error = Some message
    }
;;

let alert_json ~code ~target ~label ~message ~value =
  `Assoc
    [ "code", `String code
    ; "severity", `String "warn"
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
          ~target:"snapshot_read_error"
          ~label:"읽기"
          ~message
          ~value:1.0
      ]
  in
  if h.librarian_lane_busy <= 0
  then read_error_alert
  else
    read_error_alert
    @ [ alert_json
          ~code:"librarian_lane_busy"
          ~target:"librarian_lane_busy"
          ~label:"Librarian"
          ~message:
            "The Librarian memory lane was busy; current-memory selection was deferred."
          ~value:(float_of_int h.librarian_lane_busy)
      ]
;;

let keeper_health_entry_to_json h =
  `Assoc
    [ "keeper_id", `String h.keeper_id
    ; "revision", `Int h.revision
    ; "facts", `Int h.facts
    ; "snapshot_bytes", `Int h.snapshot_bytes
    ; "added", `Int h.added
    ; "removed", `Int h.removed
    ; "librarian_lane_busy", `Int h.librarian_lane_busy
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
    Keeper_memory_os_current.list_keeper_ids_for_keepers_dir ~keepers_dir
    |> List.map (keeper_health ~keepers_dir)
    |> List.sort (fun left right ->
      compare right.snapshot_bytes left.snapshot_bytes)
  in
  let sum field =
    List.fold_left (fun total entry -> total + field entry) 0 entries
  in
  let total_alerts =
    List.fold_left
      (fun total entry -> total + List.length (alerts entry))
      0
      entries
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
          ; ( "read_errors"
            , `Int
                (sum (fun entry ->
                   match entry.read_error with
                   | Some _ -> 1
                   | None -> 0)) )
          ] )
    ; ( "alert_summary"
      , `Assoc
          [ "total_alerts", `Int total_alerts
          ; "warn_alerts", `Int total_alerts
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
          ] )
    ]
;;
