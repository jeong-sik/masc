(* See server_dashboard_http_keeper_memory_reads.mli. *)

module Http = Http_server_eio

(* Surface only the current fact structure. [current] is derived solely from
   membership in this snapshot and is never persisted as another authority. *)
let memory_os_fact_json ~current (fact : Keeper_memory_os_types.fact) =
  `Assoc
    [ "memory_id", `String (Keeper_memory_os_types.memory_id fact)
    ; "claim", `String fact.claim
    ; "category", `String (Keeper_memory_os_types.category_to_string fact.category)
    ; "first_seen", `Float fact.first_seen
    ; "current", `Bool current
    ; "basis", Keeper_memory_os_types.basis_to_json fact.basis
     ]
;;

let memory_os_support_invalidation_json
    (invalidation : Keeper_memory_os_current.support_invalidation)
  =
  `Assoc
    [ "fact", memory_os_fact_json ~current:false invalidation.fact
    ; ( "missing_premise_ids"
      , `List
          (List.map
             (fun premise_id -> `String premise_id)
             invalidation.missing_premise_ids) )
    ]
;;

let memory_os_change_json (change : Keeper_memory_os_current.change) =
  `Assoc
    [ "added", `List (List.map (memory_os_fact_json ~current:true) change.added)
    ; "removed", `List (List.map (memory_os_fact_json ~current:false) change.removed)
    ; "retained", `Int change.retained
    ; ( "invalidated"
      , `List
          (List.map memory_os_support_invalidation_json change.invalidated) )
    ]
;;

let memory_os_keepers_dir (config : Workspace.config) =
  Config_dir_resolver.keepers_dir_for_base_path
    ~base_path:config.Workspace.base_path
;;

let memory_os_dashboard_json ~(config : Workspace.config) ~keeper_id =
  let keepers_dir = memory_os_keepers_dir config in
  let snapshot, read_error =
    match
      Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id
    with
    | Ok snapshot -> snapshot, None
    | Error message -> None, Some message
  in
  let facts, change, revision, updated_at, source =
    match snapshot with
    | None ->
      ( []
      , `Assoc
          [ "added", `List []
          ; "removed", `List []
          ; "retained", `Int 0
          ; "invalidated", `List []
          ]
      , 0
      , None
      , `Null )
    | Some snapshot ->
      let source = snapshot.Keeper_memory_os_current.source in
      ( snapshot.facts
      , memory_os_change_json snapshot.change
      , snapshot.revision
      , Some snapshot.updated_at
      , `Assoc
          [ ( "kind"
            , `String
                (match source.kind with
                 | Keeper_memory_os_current.Librarian -> "librarian"
                 | Keeper_memory_os_current.Explicit_write -> "explicit_write"
                 | Keeper_memory_os_current.Explicit_retract ->
                   "explicit_retract") )
          ; "trace_id", `String source.trace_id
          ] )
  in
  let current_facts = List.length facts in
  `Assoc
    [ "keeper", `String keeper_id
    ; ( "snapshot_store"
      , `String
          (Keeper_memory_os_current.path_for_keepers_dir
             ~keepers_dir
             ~keeper_id) )
    ; "recall_enabled", `Bool (Keeper_memory_os_recall.enabled ())
    ; "revision", `Int revision
    ; "updated_at", (match updated_at with Some value -> `Float value | None -> `Null)
    ; "update_source", source
    ; ( "read_errors"
      , match read_error with
        | None -> `List []
        | Some error ->
          `List [ `Assoc [ "scope", `String "snapshot"; "error", `String error ] ] )
    ; ( "facts"
      , `Assoc
          [ "shown", `Int (List.length facts)
          ; "current", `Int current_facts
          ; ( "items"
            , `List (List.map (memory_os_fact_json ~current:true) facts) )
          ] )
    ; "change", change
    ]
;;

let handle_working_context_get state req reqd name =
  if not (Keeper_config.validate_name name)
  then
    Http.Response.json_value ~status:`Bad_request
      (`Assoc
         [ "error", `String (Printf.sprintf "invalid keeper name: %s" name) ])
      reqd
  else
    let config = Mcp_server.workspace_config state in
    let keepers_dir = memory_os_keepers_dir config in
    let status, json =
      match
        Keeper_librarian_context.read_with_snapshot_sha256
          ~keepers_dir
          ~keeper_id:name
      with
      | Error detail ->
        `Internal_server_error,
        `Assoc
          [ "keeper", `String name
          ; "read_error", `String detail
          ]
      | Ok None ->
        `OK,
        `Assoc
          [ "keeper", `String name
          ; "present", `Bool false
          ]
      | Ok (Some (snapshot, snapshot_sha256)) ->
        `OK,
        `Assoc
          [ "keeper", `String name
          ; "present", `Bool true
          ; "snapshot_sha256", `String snapshot_sha256
          ; "snapshot", Keeper_librarian_context.snapshot_json snapshot
          ]
    in
    Http.Response.json_value ~status ~compress:true ~request:req json reqd
;;

let handle_facts_get state req reqd name =
  (* What this keeper remembers, fact by fact. The store keeps a closed
     taxonomy and provenance on every row, and the health
     projection reports only counts. Ordinary and source-bound stores are
     two readings and stay two fields, each with its own read error, so
     one failing store never blanks the other. The ordinary reading exposes
     the exact stored-byte SHA-256 beside its revision for admin cleanup CAS. *)
  if not (Keeper_config.validate_name name)
  then
    Http.Response.json_value ~status:`Bad_request
      (`Assoc
         [ "error", `String (Printf.sprintf "invalid keeper name: %s" name) ])
      reqd
  else (
    let config = Mcp_server.workspace_config state in
    let keepers_dir = memory_os_keepers_dir config in
    (* What happened to each fact (RFC-0418): retrievals, retractions
       and revisions, projected from the events sidecar at read time and
       stored nowhere. A line the reader could not decode is counted, not
       dropped. *)
    let event_rows, events_read_error =
      match Keeper_memory_os_events.read ~keepers_dir ~keeper_id:name with
      | Ok rows -> rows, None
      | Error error ->
        [], Some (Keeper_memory_os_events.file_read_error_to_string error)
    in
    let events =
      List.filter_map
        (fun (_, row) ->
           match row with
           | Ok event -> Some event
           | Error _ -> None)
        event_rows
    in
    let events_unreadable_lines =
      List.length
        (List.filter
           (fun (_, row) ->
              match row with
              | Ok _ -> false
              | Error _ -> true)
           event_rows)
    in
    let fact_json (fact : Keeper_memory_os_types.fact) =
      `Assoc
        [ "claim", `String fact.claim
        ; ( "category"
          , `String (Keeper_memory_os_types.category_to_string fact.category)
          )
        ; ( "origin"
          , `String
              (Keeper_memory_os_types.origin_kind_to_string fact.origin.kind)
          )
        ; "first_seen", `Float fact.first_seen
        ; "last_seen", `Float fact.last_seen
        ; "memory_id", `String (Keeper_memory_os_types.memory_id fact)
        ; "basis", Keeper_memory_os_types.basis_to_json fact.basis
        ; ( "events"
          , Keeper_memory_os_events.summary_to_json
              (Keeper_memory_os_events.summary_for
                 ~memory_id:(Keeper_memory_os_types.memory_id fact)
                 events) )
        ]
    in
    let support_invalidation_json
        (invalidation : Keeper_memory_os_current.support_invalidation)
      =
      `Assoc
        [ "memory_id", `String (Keeper_memory_os_types.memory_id invalidation.fact)
        ; "claim", `String invalidation.fact.claim
        ; "basis", Keeper_memory_os_types.basis_to_json invalidation.fact.basis
        ; ( "missing_premise_ids"
          , `List
              (List.map
                 (fun premise_id -> `String premise_id)
                 invalidation.missing_premise_ids) )
        ]
    in
    let ordinary =
      match
        Keeper_memory_os_current.read_with_snapshot_sha256
          ~keepers_dir
          ~keeper_id:name
      with
      | Error detail -> `Assoc [ "read_error", `String detail ]
      | Ok None -> `Assoc [ "present", `Bool false ]
      | Ok (Some (snapshot, snapshot_sha256)) ->
        `Assoc
          [ "present", `Bool true
          ; "revision", `Int snapshot.Keeper_memory_os_current.revision
          ; "snapshot_sha256", `String snapshot_sha256
          ; "updated_at", `Float snapshot.Keeper_memory_os_current.updated_at
          ; "facts", `List (List.map fact_json snapshot.facts)
          ; ( "support_invalidations"
            , `List
                (List.map
                   support_invalidation_json
                   snapshot.change.invalidated) )
          ]
    in
    let source_fact_json (fact : Keeper_memory_source_current.fact) =
      `Assoc
        [ "claim", `String fact.claim
        ; "first_seen", `Float fact.first_seen
        ; "path", `String fact.source.path
        ; "sha256", `String fact.source.sha256
        ]
    in
    let invalidation_json (row : Keeper_memory_source_current.invalidation) =
      `Assoc
        [ "source_path", `String row.source_path
        ; "invalidated_at", `Float row.invalidated_at
        ; ( "reason"
          , `String
              (match row.reason with
               | Keeper_memory_source_current.Source_changed ->
                 "source_changed"
               | Keeper_memory_source_current.Source_unavailable ->
                 "source_unavailable") )
        ]
    in
    let source_bound =
      match
        Keeper_memory_source_current.read_for_keepers_dir
          ~keepers_dir
          ~keeper_id:name
      with
      | Error detail -> `Assoc [ "read_error", `String detail ]
      | Ok None -> `Assoc [ "present", `Bool false ]
      | Ok (Some snapshot) ->
        `Assoc
          [ "present", `Bool true
          ; "revision", `Int snapshot.Keeper_memory_source_current.revision
          ; ( "updated_at"
            , `Float snapshot.Keeper_memory_source_current.updated_at )
          ; "facts", `List (List.map source_fact_json snapshot.facts)
          ; ( "invalidations"
            , `List (List.map invalidation_json snapshot.invalidations) )
          ]
    in
    Http.Response.json_value ~compress:true ~request:req
      (`Assoc
         [ "keeper", `String name
         ; "dashboard_surface", `String "/api/v1/keepers/:name/memory-facts"
         ; "ordinary", ordinary
         ; "source_bound", source_bound
         ; "events_unreadable_lines", `Int events_unreadable_lines
         ; ( "events_read_error"
           , match events_read_error with
             | None -> `Null
             | Some detail -> `String detail )
         ])
      reqd)
;;

let handle_journal_get state req reqd name =
  (* Why this keeper's memory looks the way it does. The librarian's passes
     reach disk here — committed and failed alike since RFC-0361 Part 5 — and
     the internal-agents monitor could show that a pass ran but not what it
     decided. A failed pass is the case an operator actually opens. *)
  if not (Keeper_config.validate_name name)
  then
    Http.Response.json_value ~status:`Bad_request
      (`Assoc
         [ "error", `String (Printf.sprintf "invalid keeper name: %s" name) ])
      reqd
  else (
    let limit =
      Server_utils.int_query_param req "limit" ~default:50 |> max 1 |> min 500
    in
    let config = Mcp_server.workspace_config state in
    let keepers_dir = memory_os_keepers_dir config in
    match
      Keeper_memory_os_current.read_journal_tail_projection
        ~keepers_dir
        ~keeper_id:name
        ~limit
    with
    | Error detail ->
      (* A journal that exists and cannot be read is not an empty one. *)
      Http.Response.json_value ~status:`Internal_server_error
        (`Assoc
           [ "keeper", `String name
           ; "read_error", `String detail
           ])
        reqd
    | Ok entries ->
    let undecodable =
      List.length
        (List.filter
           (function
             | `Assoc fields -> List.assoc_opt "ok" fields = Some (`Bool false)
             | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null
             | `String _ -> false)
           entries)
    in
    let activity =
      if Server_utils.query_param req "activity" = Some "1" then
        [ "activity", Keeper_memory_activity.to_json
            (Keeper_memory_activity.read ~keepers_dir ~keeper_id:name ~limit) ]
      else []
    in
    Http.Response.json_value ~compress:true ~request:req
      (`Assoc
         ([ "keeper", `String name
         ; "dashboard_surface", `String "/api/v1/keepers/:name/memory-journal"
         ; "returned", `Int (List.length entries)
         ; (* Reported rather than hidden: a journal this build cannot fully
              read is a different observation from a shorter one. *)
           "undecodable_lines", `Int undecodable
         ; "entries", `List entries
         ] @ activity))
      reqd)
;;
