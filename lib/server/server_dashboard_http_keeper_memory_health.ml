(** Read-only fleet health for the current Memory OS snapshot. *)

type keeper_health =
  { keeper_id : string
  ; revision : int
  ; facts : int
  ; observed_facts : int
  ; derived_facts : int
  ; support_invalidations : int
  ; snapshot_bytes : int
  ; added : int
  ; removed : int
  ; snapshot_present : bool
  ; librarian_lane_busy : int
  ; librarian_failures : int
  ; vision_ingest_errors : int
  ; vision_ingest_error_reasons : (string * int) list
  ; read_error : string option
  ; source_revision : int
  ; source_facts : int
  ; source_invalidations : int
  ; source_snapshot_bytes : int
  ; source_snapshot_present : bool
  ; source_read_error : string option
  }

type source_health =
  { revision : int
  ; facts : int
  ; invalidations : int
  ; snapshot_bytes : int
  ; snapshot_present : bool
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

(* Labels mirror the counter increments in [Keeper_librarian_runtime] and the
   pre-librarian snapshot read in [Keeper_agent_run_post_turn_memory]: a keeper
   whose current-snapshot read keeps failing aborts before the librarian ever
   runs, so counting only the librarian site would report it as failure-free. *)
let librarian_failure_sites = [ "memory_os_librarian"; "memory_os_current_read" ]

let librarian_failures_for_keeper keeper_id =
  List.fold_left
    (fun total site ->
       total
       + (Otel_metric_store.metric_value_or_zero
            librarian_failures_metric
            ~labels:[ "keeper", keeper_id; "site", site ]
            ()
          |> int_of_float))
    0
    librarian_failure_sites
;;

(* A keeper with a config but no current snapshot is the starvation case this
   endpoint exists to expose; enumerating snapshot files alone gives it no
   row at all. Health rows therefore come from the union of configured
   keepers and existing snapshots. Discovery goes through
   [Keeper_types_profile.discover_keepers_toml] rather than toml basenames
   because a toml may set its canonical [name]: metrics and snapshots are
   keyed by that name, and a basename row would both miss the real keeper
   and show a ghost. Invalid tomls keep their basename row so a keeper with
   a broken config stays visible. *)
let configured_keeper_ids ~keepers_dir =
  Keeper_types_profile.discover_keepers_toml keepers_dir
  |> List.map Keeper_types_profile.keeper_toml_discovery_name
;;

let health_keeper_ids ~keepers_dir =
  configured_keeper_ids ~keepers_dir
  @ Keeper_memory_os_current.list_keeper_ids_for_keepers_dir ~keepers_dir
  @ Keeper_memory_source_current.list_keeper_ids_for_keepers_dir ~keepers_dir
  |> List.sort_uniq String.compare
;;

let vision_ingest_error_metric =
  Keeper_metrics.(to_string VisionIngestErrors)
;;

(* #32126: per-keeper image-ingest failures, by the closed reason set the
   ingest module owns. Only nonzero reasons ride along, so the row says why,
   not just how many. *)
let vision_errors_for_keeper keeper_id =
  List.filter_map
    (fun reason ->
       let count =
         Otel_metric_store.metric_value_or_zero
           vision_ingest_error_metric
           ~labels:[ "keeper", keeper_id; "reason", reason ]
           ()
         |> int_of_float
       in
       if count > 0 then Some (reason, count) else None)
    Keeper_vision_ingest.error_reasons
;;

let vision_ingest_error_count_for_keeper keeper_id =
  List.fold_left (fun total (_, count) -> total + count) 0
    (vision_errors_for_keeper keeper_id)
;;

let source_health ~keepers_dir keeper_id =
  let snapshot_path =
    Keeper_memory_source_current.path_for_keepers_dir ~keepers_dir ~keeper_id
  in
  match
    Keeper_memory_source_current.read_for_keepers_dir ~keepers_dir ~keeper_id
  with
  | Ok None ->
    { revision = 0
    ; facts = 0
    ; invalidations = 0
    ; snapshot_bytes = 0
    ; snapshot_present = false
    ; read_error = None
    }
  | Ok (Some snapshot) ->
    { revision = snapshot.revision
    ; facts = List.length snapshot.facts
    ; invalidations = List.length snapshot.invalidations
    ; snapshot_bytes = file_size_bytes snapshot_path
    ; snapshot_present = true
    ; read_error = None
    }
  | Error message ->
    { revision = 0
    ; facts = 0
    ; invalidations = 0
    ; snapshot_bytes = file_size_bytes snapshot_path
    ; snapshot_present = false
    ; read_error = Some message
    }
;;
let keeper_health ~keepers_dir keeper_id =
  let source_health = source_health ~keepers_dir keeper_id in
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
    ; observed_facts = 0
    ; derived_facts = 0
    ; support_invalidations = 0
    ; snapshot_bytes = 0
    ; added = 0
    ; removed = 0
    ; snapshot_present = false
    ; librarian_lane_busy = librarian_lane_busy_for_keeper keeper_id
    ; librarian_failures = librarian_failures_for_keeper keeper_id
    ; vision_ingest_errors =
        vision_ingest_error_count_for_keeper keeper_id
    ; vision_ingest_error_reasons = vision_errors_for_keeper keeper_id
    ; read_error = None
    ; source_revision = source_health.revision
    ; source_facts = source_health.facts
    ; source_invalidations = source_health.invalidations
    ; source_snapshot_bytes = source_health.snapshot_bytes
    ; source_snapshot_present = source_health.snapshot_present
    ; source_read_error = source_health.read_error
    }
  | Ok (Some snapshot) ->
    let observed_facts, derived_facts =
      List.fold_left
        (fun (observed, derived) fact ->
           match fact.Keeper_memory_os_types.basis with
           | Keeper_memory_os_types.Observed _ -> observed + 1, derived
           | Keeper_memory_os_types.Derived _ -> observed, derived + 1)
        (0, 0)
        snapshot.facts
    in
    { keeper_id
    ; revision = snapshot.revision
    ; facts = List.length snapshot.facts
    ; observed_facts
    ; derived_facts
    ; support_invalidations = List.length snapshot.change.invalidated
    ; snapshot_bytes = file_size_bytes snapshot_path
    ; added = List.length snapshot.change.added
    ; removed = List.length snapshot.change.removed
    ; snapshot_present = true
    ; librarian_lane_busy = librarian_lane_busy_for_keeper keeper_id
    ; librarian_failures = librarian_failures_for_keeper keeper_id
    ; vision_ingest_errors =
        vision_ingest_error_count_for_keeper keeper_id
    ; vision_ingest_error_reasons = vision_errors_for_keeper keeper_id
    ; read_error = None
    ; source_revision = source_health.revision
    ; source_facts = source_health.facts
    ; source_invalidations = source_health.invalidations
    ; source_snapshot_bytes = source_health.snapshot_bytes
    ; source_snapshot_present = source_health.snapshot_present
    ; source_read_error = source_health.read_error
    }
  | Error message ->
    { keeper_id
    ; revision = 0
    ; facts = 0
    ; observed_facts = 0
    ; derived_facts = 0
    ; support_invalidations = 0
    ; snapshot_bytes = file_size_bytes snapshot_path
    ; added = 0
    ; removed = 0
    ; snapshot_present = false
    ; librarian_lane_busy = librarian_lane_busy_for_keeper keeper_id
    ; librarian_failures = librarian_failures_for_keeper keeper_id
    ; vision_ingest_errors =
        vision_ingest_error_count_for_keeper keeper_id
    ; vision_ingest_error_reasons = vision_errors_for_keeper keeper_id
    ; read_error = Some message
    ; source_revision = source_health.revision
    ; source_facts = source_health.facts
    ; source_invalidations = source_health.invalidations
    ; source_snapshot_bytes = source_health.snapshot_bytes
    ; source_snapshot_present = source_health.snapshot_present
    ; source_read_error = source_health.read_error
    }
;;

let alert_json ~code ~severity ~target ~label ~message =
  `Assoc
    [ "code", `String code
    ; "severity", `String severity
    ; "target", `String target
    ; "label", `String label
    ; "message", `String message
    ]
;;

let alerts (h : keeper_health) =
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
      ]
  in
  let source_read_error_alert =
    match h.source_read_error with
    | None -> []
    | Some message ->
      [ alert_json
          ~code:"source_snapshot_read_error"
          ~severity:"warn"
          ~target:"source_snapshot_read_error"
          ~label:"소스 읽기"
          ~message
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
      ]
    else
      [ alert_json
          ~code:"librarian_starvation"
          ~severity:"error"
          ~target:"librarian_starvation"
          ~label:"Librarian"
          ~message:
            (if h.source_snapshot_present
             then
               "Librarian runs failed and no ordinary current-memory snapshot exists. A source-bound snapshot remains available, but it does not demonstrate or repair Librarian selection."
             else
               "Librarian runs failed and no ordinary or source-bound current-memory snapshot exists; the keeper is running memoryless and cannot leave that state on its own.")
      ]
  in
  let vision_ingest_alert =
    if h.vision_ingest_errors <= 0
    then []
    else
      [ alert_json
          ~code:"vision_ingest_errors"
          ~severity:"warn"
          ~target:"vision_ingest_errors"
          ~label:"Vision"
          ~message:
            (Printf.sprintf
               "Image ingestion failed %d times; those images reached the                 keeper as text placeholders. Reasons: %s."
               h.vision_ingest_errors
               (String.concat ", "
                  (List.map
                     (fun (reason, count) ->
                        Printf.sprintf "%s x%d" reason count)
                     h.vision_ingest_error_reasons)))
      ]
  in
  read_error_alert @ source_read_error_alert @ lane_busy_alert @ failure_alert
  @ vision_ingest_alert
;;

let alert_severity = function
  | `Assoc fields ->
    (match List.assoc_opt "severity" fields with
     | Some (`String severity) -> severity
     | _ -> "warn")
  | _ -> "warn"
;;

let keeper_health_entry_to_json (h : keeper_health) =
  `Assoc
    [ "keeper_id", `String h.keeper_id
    ; "revision", `Int h.revision
    ; "facts", `Int h.facts
    ; "observed_facts", `Int h.observed_facts
    ; "derived_facts", `Int h.derived_facts
    ; "support_invalidations", `Int h.support_invalidations
    ; "snapshot_bytes", `Int h.snapshot_bytes
    ; "added", `Int h.added
    ; "removed", `Int h.removed
    ; "snapshot_present", `Bool h.snapshot_present
    ; "librarian_lane_busy", `Int h.librarian_lane_busy
    ; "librarian_failures", `Int h.librarian_failures
    ; "vision_ingest_errors", `Int h.vision_ingest_errors
    ; ( "vision_ingest_error_reasons"
      , `List
          (List.map
             (fun (reason, count) ->
                `Assoc [ ("reason", `String reason); ("count", `Int count) ])
             h.vision_ingest_error_reasons) )
    ; ( "read_error"
      , match h.read_error with
        | Some message -> `String message
        | None -> `Null )
    ; "source_revision", `Int h.source_revision
    ; "source_facts", `Int h.source_facts
    ; "source_invalidations", `Int h.source_invalidations
    ; "source_snapshot_bytes", `Int h.source_snapshot_bytes
    ; "source_snapshot_present", `Bool h.source_snapshot_present
    ; ( "source_read_error"
      , match h.source_read_error with
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
    |> List.sort (fun (left : keeper_health) (right : keeper_health) ->
      compare
        (right.snapshot_bytes + right.source_snapshot_bytes)
        (left.snapshot_bytes + left.source_snapshot_bytes))
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
    [ "schema", `String "keeper.memory_os.current_health.v3"
    ; "generated_at", `Float generated_at
    ; ( "cadence_counter_entries"
      , `Int (Keeper_librarian_runtime.cadence_counter_entries ()) )
    ; "keepers", `List (List.map keeper_health_entry_to_json entries)
    ; ( "totals"
      , `Assoc
          [ "facts", `Int (sum (fun entry -> entry.facts))
          ; "observed_facts", `Int (sum (fun entry -> entry.observed_facts))
          ; "derived_facts", `Int (sum (fun entry -> entry.derived_facts))
          ; ( "support_invalidations"
            , `Int (sum (fun entry -> entry.support_invalidations)) )
          ; "snapshot_bytes", `Int (sum (fun entry -> entry.snapshot_bytes))
          ; "added", `Int (sum (fun entry -> entry.added))
          ; "removed", `Int (sum (fun entry -> entry.removed))
          ; "source_facts", `Int (sum (fun entry -> entry.source_facts))
          ; ( "source_invalidations"
            , `Int (sum (fun entry -> entry.source_invalidations)) )
          ; ( "source_snapshot_bytes"
            , `Int (sum (fun entry -> entry.source_snapshot_bytes)) )
          ; ( "librarian_lane_busy"
            , `Int (sum (fun entry -> entry.librarian_lane_busy)) )
          ; ( "librarian_failures"
            , `Int (sum (fun entry -> entry.librarian_failures)) )
          ; ( "vision_ingest_errors"
            , `Int (sum (fun entry -> entry.vision_ingest_errors)) )
          ; ( "read_errors"
            , `Int
                (sum (fun entry ->
                   match entry.read_error with
                   | Some _ -> 1
                   | None -> 0)) )
          ; ( "source_read_errors"
            , `Int
                (sum (fun entry ->
                   match entry.source_read_error with
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
          ; ( "source_snapshot_read_error_keepers"
            , `Int
                (sum (fun entry ->
                   match entry.source_read_error with
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
