(** Read-only fleet health for the current Memory OS snapshot. *)

(* RFC librarian-lifecycle §4.9. What the keeper's durable Librarian drain
   measured when its last pass ended, plus the last thing its journal says.
   The counters this used to carry were totals since the server booted, which
   answered "has anything ever gone wrong" and never "is this keeper behind
   now". *)
type librarian_health =
  { state : Keeper_librarian_queue_refresh.pass_end option
      (** [None] until this process has observed the keeper's durable drain.
          This does not describe a later working-Context organization pass. *)
  ; measured_at : float option
  ; unread_atom_turns : int option
  ; unread_official_turns : int option
      (** [None] when the durable drain could not take the count; [state] says what
          the pass ran into. *)
  ; last_success_at : float option
      (** [updated_at] of the current snapshot when the Librarian is what
          wrote it. An explicit write is not a Librarian success. *)
  ; last_failure_kind : string option
      (** The kind on the journal's last line when that line is a failure. A
          failure older than the last success is not shown: the pass after it
          committed. *)
  }

type keeper_health =
  { keeper_id : string
  ; revision : int
  ; updated_at : float option
  ; facts : int
  ; observed_facts : int
  ; derived_facts : int
  ; support_invalidations : int
  ; snapshot_bytes : int
  ; added : int
  ; removed : int
  ; snapshot_present : bool
  ; librarian : librarian_health
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

let librarian_failures_metric =
  Keeper_metrics.(to_string MemoryOsLibrarianFailures)
;;

(* What the operator needs here is what this memory costs the model, so the
   figure is the recall block's own bytes -- the same strings
   [Keeper_memory_os_recall] injects -- not the snapshot file on disk. The
   file carries first_seen, origin, basis and JSON punctuation that never
   reach a request, so its size answered a question nobody asked. A snapshot
   that could not be read has no rendering and reports nothing. *)
let rendered_bytes facts =
  String.length (Keeper_memory_os_render.render_facts facts)
;;

let rendered_source_bytes ~facts ~invalidations =
  List.fold_left
    (fun total fact ->
       total + String.length (Keeper_memory_source_current.render_fact fact))
    0
    facts
  + List.fold_left
      (fun total invalidation ->
         total
         + String.length
             (Keeper_memory_source_current.render_invalidation invalidation))
      0
      invalidations
;;

(* The durable drain publishes in this process, so its measurement is read from memory: the
   health request counts nothing itself and moves no position. *)
let librarian_health ~config ~keepers_dir keeper_id ~snapshot =
  let measurement = Keeper_librarian_queue_refresh.last_measurement ~config ~keeper_name:keeper_id in
  let last_success_at =
    match (snapshot : Keeper_memory_os_current.t option) with
    | Some { updated_at; source = { kind = Keeper_memory_os_current.Librarian; _ }; _ } ->
      Some updated_at
    | Some { source = { kind = Explicit_write | Explicit_retract; _ }; _ } | None -> None
  in
  let last_failure_kind =
    match
      Keeper_memory_os_current.read_journal_tail ~keepers_dir ~keeper_id ~limit:1
    with
    | [ Ok (Keeper_memory_os_current.Journal_failed { recorded_at; kind; _ }) ]
      when Option.fold ~none:true ~some:(fun success -> recorded_at > success) last_success_at
      -> Some (Keeper_memory_os_current.librarian_failure_kind_to_string kind)
    | [] | [ Ok _ ] | [ Error _ ] | _ :: _ :: _ -> None
  in
  { state = Option.map (fun (m : Keeper_librarian_queue_refresh.measurement) -> m.last_pass) measurement
  ; measured_at =
      Option.map (fun (m : Keeper_librarian_queue_refresh.measurement) -> m.measured_at) measurement
  ; unread_atom_turns =
      Option.bind measurement (fun (m : Keeper_librarian_queue_refresh.measurement) ->
        Option.map (fun (u : Keeper_librarian_durable_consumer.unread) -> u.atoms) m.unread)
  ; unread_official_turns =
      Option.bind measurement (fun (m : Keeper_librarian_queue_refresh.measurement) ->
        Option.map (fun (u : Keeper_librarian_durable_consumer.unread) -> u.official) m.unread)
  ; last_success_at
  ; last_failure_kind
  }
;;

let librarian_state_to_string = function
  | Keeper_librarian_queue_refresh.Off -> "off"
  | Lane_unconfigured -> "lane_unconfigured"
  | Drained -> "drained"
  | Not_committed -> "not_committed"
  | Stopped _ -> "stopped"
  | Raised _ -> "raised"
;;

let librarian_state_detail = function
  | Keeper_librarian_queue_refresh.Stopped error ->
    Some (Keeper_librarian_durable_consumer.error_to_string error)
  | Raised detail -> Some detail
  | Off | Lane_unconfigured | Drained | Not_committed -> None
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
    ; snapshot_bytes =
        rendered_source_bytes
          ~facts:snapshot.facts
          ~invalidations:snapshot.invalidations
    ; snapshot_present = true
    ; read_error = None
    }
  | Error message ->
    { revision = 0
    ; facts = 0
    ; invalidations = 0
    ; snapshot_bytes = 0
    ; snapshot_present = false
    ; read_error = Some message
    }
;;
let keeper_health ~config ~keepers_dir keeper_id =
  let source_health = source_health ~keepers_dir keeper_id in
  let librarian ~snapshot = librarian_health ~config ~keepers_dir keeper_id ~snapshot in
  match
    Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id
  with
  | Ok None ->
    { keeper_id
    ; updated_at = None
    ; revision = 0
    ; facts = 0
    ; observed_facts = 0
    ; derived_facts = 0
    ; support_invalidations = 0
    ; snapshot_bytes = 0
    ; added = 0
    ; removed = 0
    ; snapshot_present = false
    ; librarian = librarian ~snapshot:None
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
    ; updated_at = Some snapshot.updated_at
    ; revision = snapshot.revision
    ; facts = List.length snapshot.facts
    ; observed_facts
    ; derived_facts
    ; support_invalidations = List.length snapshot.change.invalidated
    ; snapshot_bytes = rendered_bytes snapshot.facts
    ; added = List.length snapshot.change.added
    ; removed = List.length snapshot.change.removed
    ; snapshot_present = true
    ; librarian = librarian ~snapshot:(Some snapshot)
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
    ; updated_at = None
    ; revision = 0
    ; facts = 0
    ; observed_facts = 0
    ; derived_facts = 0
    ; support_invalidations = 0
    ; snapshot_bytes = 0
    ; added = 0
    ; removed = 0
    ; snapshot_present = false
    ; librarian = librarian ~snapshot:None
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
  (* RFC §4.9: a keeper standing behind is the thing to see, and the state
     says whether it is standing because something failed or because the
     Librarian is off. Off is not an alert. *)
  let stopped_alert =
    match h.librarian.state with
    | None | Some (Keeper_librarian_queue_refresh.Off | Drained) -> []
    | Some ((Lane_unconfigured | Not_committed | Stopped _ | Raised _) as state) ->
      let behind =
        match h.librarian.unread_atom_turns, h.librarian.unread_official_turns with
        | Some atoms, Some official ->
          Printf.sprintf " %d turns are unread." (atoms + official)
        | Some _, None | None, Some _ | None, None -> ""
      in
      [ alert_json
          ~code:"librarian_stopped"
          ~severity:"warn"
          ~target:"librarian_stopped"
          ~label:"Librarian"
          ~message:
            (Printf.sprintf
               "The keeper's Librarian pass ended as %s and waits for the next wake.%s%s"
               (librarian_state_to_string state)
               behind
               (match librarian_state_detail state with
                | Some detail -> " " ^ detail
                | None -> ""))
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
  read_error_alert @ source_read_error_alert @ stopped_alert @ failure_alert
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
    ; "updated_at", (match h.updated_at with None -> `Null | Some ts -> `Float ts)
    ; "facts", `Int h.facts
    ; "observed_facts", `Int h.observed_facts
    ; "derived_facts", `Int h.derived_facts
    ; "support_invalidations", `Int h.support_invalidations
    ; "snapshot_bytes", `Int h.snapshot_bytes
    ; "added", `Int h.added
    ; "removed", `Int h.removed
    ; "snapshot_present", `Bool h.snapshot_present
    ; ( "librarian"
      , `Assoc
          [ ( "state"
            , match h.librarian.state with
              | Some state -> `String (librarian_state_to_string state)
              | None -> `Null )
          ; ( "detail"
            , match Option.bind h.librarian.state librarian_state_detail with
              | Some detail -> `String detail
              | None -> `Null )
          ; ( "measured_at"
            , match h.librarian.measured_at with
              | Some ts -> `Float ts
              | None -> `Null )
          ; ( "unread_atom_turns"
            , match h.librarian.unread_atom_turns with
              | Some count -> `Int count
              | None -> `Null )
          ; ( "unread_official_turns"
            , match h.librarian.unread_official_turns with
              | Some count -> `Int count
              | None -> `Null )
          ; ( "last_success_at"
            , match h.librarian.last_success_at with
              | Some ts -> `Float ts
              | None -> `Null )
          ; ( "last_failure_kind"
            , match h.librarian.last_failure_kind with
              | Some kind -> `String kind
              | None -> `Null )
          ] )
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
  let config = Workspace.default_config base_path in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path
  in
  let entries =
    health_keeper_ids ~keepers_dir
    |> List.map (keeper_health ~config ~keepers_dir)
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
    [ "schema", `String "keeper.memory_os.current_health.v5"
    ; "generated_at", `Float generated_at
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
          ; ( "librarian_unread_turns"
            , (match List.fold_left (fun total entry ->
                 match total, entry.librarian.unread_atom_turns,
                       entry.librarian.unread_official_turns with
                 | Some total, Some atoms, Some official -> Some (total + atoms + official)
                 | _ -> None) (Some 0) entries with
               | Some total -> `Int total
               | None -> `Null) )
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
          ; ( "librarian_stopped_keepers"
            , `Int
                (sum (fun entry ->
                   match entry.librarian.state with
                   | Some (Lane_unconfigured | Not_committed | Stopped _ | Raised _) -> 1
                   | Some (Off | Drained) | None -> 0)) )
          ; ( "librarian_starving_keepers"
            , `Int
                (sum (fun entry ->
                   if entry.librarian_failures > 0 && not entry.snapshot_present
                   then 1
                   else 0)) )
          ] )
    ]
;;

(* Preserve each store's own revision and evidence rather than synthesizing a
   fleet-wide revision or treating collected claims as independently verified. *)
let workspace_memory_context_http_json = Workspace_memory_context.http_json
