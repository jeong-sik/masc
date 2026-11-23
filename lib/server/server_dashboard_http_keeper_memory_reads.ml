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

let source_of_commit_cause (cause : Librarian_log.cause) : Keeper_memory_os_current.source =
  let non_empty text fallback =
    let trimmed = String.trim text in
    if String.equal trimmed "" then fallback else trimmed
  in
  match cause with
  | Librarian_log.Direct { write = Librarian_direct.Retract _; trace; _ } ->
    { kind = Explicit_retract; trace_id = non_empty trace "explicit_retract" }
  | Librarian_log.Direct
      { write = Librarian_direct.(Remember _ | Supersede _); trace; _ } ->
    { kind = Explicit_write; trace_id = non_empty trace "explicit_write" }
  | Librarian_log.Read { trace; _ } ->
    { kind = Librarian; trace_id = non_empty trace "librarian_read" }
  | Librarian_log.Make_room { trace; _ } ->
    { kind = Librarian; trace_id = non_empty trace "librarian_make_room" }
  | Librarian_log.Molt_and_synthesize { trace; _ } ->
    { kind = Librarian; trace_id = non_empty trace "librarian_molt" }
  | Librarian_log.Adopt { by; _ } ->
    { kind = Librarian; trace_id = non_empty by "adopt" }
  | Librarian_log.Skip _ ->
    { kind = Librarian; trace_id = "skip" }
  | Librarian_log.Checkpoint _ ->
    { kind = Librarian; trace_id = "checkpoint" }
;;

let undecodable_log_line_to_string = function
  | Librarian_log_store.Not_json -> "commit log line is not valid JSON"
  | Librarian_log_store.Malformed err ->
    Keeper_memory_os_types.wire_error_to_string err
;;

let read_commit_lineage_from_log ~keepers_dir ~keeper_id =
  let log_path = Librarian_log_store.path_for_keepers_dir ~keepers_dir ~keeper_id in
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    Librarian_log_store.fold log_path ~init:([], [])
      ~f:(fun (revisions_rev, retractions_rev) ({ line; _ } : Librarian_log_store.scanned) ->
        match line with
        | Ok (Librarian_log.Committed commit) ->
          List.fold_left
            (fun (revs, rets) ((fact : Keeper_memory_os_types.fact), removal) ->
               let id = Keeper_memory_os_types.memory_id fact in
               match removal with
               | Librarian_effects.Revised_into into_id
               | Librarian_effects.Superseded_by into_id ->
                 ( { Keeper_memory_os_types.superseded = id
                   ; superseded_by = into_id
                   }
                   :: revs
                 , rets )
               | Librarian_effects.Retracted _ -> revs, id :: rets
               | Dropped _ | Merged_into _ | Support_lost _ | Molted _ -> revs, rets)
            (revisions_rev, retractions_rev)
            commit.effects.removed
        | Ok (Librarian_log.Started _) | Error _ -> revisions_rev, retractions_rev)
    |> Result.map (fun (revs, rets) -> List.rev revs, List.rev rets)
    |> Result.map_error Private_jsonl_scan.error_to_string)
;;

let journal_projection_identity ~keeper_id line_offset =
  Printf.sprintf "memory:journal:%d:%s:%d" (String.length keeper_id) keeper_id line_offset
;;

let read_memory_log_tail_projection ~keepers_dir ~keeper_id ~limit =
  if limit <= 0
  then Ok []
  else
    let log_path = Librarian_log_store.path_for_keepers_dir ~keepers_dir ~keeper_id in
    Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      match
        Librarian_log_store.fold log_path ~init:[]
          ~f:(fun acc ({ at; line } : Librarian_log_store.scanned) ->
            match line with
            | Ok (Librarian_log.Started _) -> acc
            | Ok (Librarian_log.Committed commit) -> (at, Ok commit) :: acc
            | Error err -> (at, Error err) :: acc)
      with
      | Error err -> Error (Private_jsonl_scan.error_to_string err)
      | Ok rows_rev ->
        let tail_rows = List.rev (List.take limit rows_rev) in
        let anchored =
          match Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id with
          | Ok (Some snap) ->
            let rec walk_back running acc = function
              | [] -> acc
              | (at, Error err) :: older -> walk_back running ((at, Error err) :: acc) older
              | (at, Ok (commit : Librarian_log.commit)) :: older ->
                let added_n = List.length commit.effects.added in
                let removed_n = List.length commit.effects.removed in
                let retained = max 0 (running - added_n) in
                let before = max 0 (running - added_n + removed_n) in
                walk_back before ((at, Ok (commit, retained)) :: acc) older
            in
            walk_back (List.length snap.facts) [] (List.rev tail_rows)
          | Ok None | Error _ ->
            let rec walk_forward running acc = function
              | [] -> List.rev acc
              | (at, Error err) :: newer -> walk_forward running ((at, Error err) :: acc) newer
              | (at, Ok (commit : Librarian_log.commit)) :: newer ->
                let added_n = List.length commit.effects.added in
                let removed_n = List.length commit.effects.removed in
                let retained = max 0 (running - removed_n) in
                let after = max 0 (retained + added_n) in
                walk_forward after ((at, Ok (commit, retained)) :: acc) newer
            in
            walk_forward 0 [] tail_rows
        in
        Ok
          (List.map
             (fun (line_offset, row) ->
                let structural_id =
                  "structural_id", `String (journal_projection_identity ~keeper_id line_offset)
                in
                match row with
                | Error err ->
                  `Assoc
                    [ structural_id
                    ; "ok", `Bool false
                    ; "error", `String (undecodable_log_line_to_string err)
                    ]
                | Ok ((commit : Librarian_log.commit), retained) ->
                  let source = source_of_commit_cause commit.cause in
                  let invalidated =
                    List.filter_map
                      (fun ((fact : Keeper_memory_os_types.fact), removal) ->
                         match removal, fact.basis with
                         | Librarian_effects.Support_lost { missing },
                           Keeper_memory_os_types.Derived _ ->
                           let ids =
                             List.filter Keeper_memory_os_types.is_memory_id missing
                             |> List.sort_uniq String.compare
                           in
                           if ids = []
                           then None
                           else
                             Some
                               { Keeper_memory_os_current.fact
                               ; missing_premise_ids = ids
                               }
                         | Librarian_effects.Support_lost _,
                           Keeper_memory_os_types.Observed _
                         | ( Librarian_effects.Dropped _
                           | Librarian_effects.Merged_into _
                           | Librarian_effects.Revised_into _
                           | Librarian_effects.Superseded_by _
                           | Librarian_effects.Retracted _
                           | Librarian_effects.Molted _ ),
                           Keeper_memory_os_types.(Observed _ | Derived _) -> None)
                      commit.effects.removed
                  in
                  let dropped =
                    List.filter_map
                      (fun ((fact : Keeper_memory_os_types.fact), removal) ->
                         match removal with
                         | Librarian_effects.Dropped { reason }
                         | Librarian_effects.Retracted { reason; _ }
                         | Librarian_effects.Molted { reason } ->
                           if String.trim reason = ""
                           then None
                           else
                             Some
                               (`Assoc
                                 [ "memory_id", `String (Keeper_memory_os_types.memory_id fact)
                                 ; "reason", `String reason
                                 ])
                         | Merged_into _ | Revised_into _ | Superseded_by _ | Support_lost _ ->
                           None)
                      commit.effects.removed
                  in
                  let change : Keeper_memory_os_current.change =
                    { added = commit.effects.added
                    ; removed = List.map fst commit.effects.removed
                    ; retained
                    ; invalidated
                    }
                  in
                  `Assoc
                    ([ structural_id
                     ; "ok", `Bool true
                     ; "outcome", `String "committed"
                     ; "recorded_at", `Float commit.at
                     ; "revision", `Int commit.revision
                     ; "source", Keeper_memory_os_snapshot_codec.source_to_json source
                     ; "change", Keeper_memory_os_snapshot_codec.change_to_json change
                     ]
                     @ if dropped = [] then [] else [ "dropped", `List dropped ]))
             anchored))
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
    (* What happened to each fact: retrievals from the events
       sidecar, retractions and revisions from the memory journal the commits
       wrote, projected at read time and stored nowhere. A sidecar line the
       reader could not decode is counted, not dropped. A history that could
       not be read is named in [events_read_error], so its zeros are not taken
       for an empty history. *)
    let event_rows, sidecar_read_error =
      match Keeper_memory_os_events.read ~keepers_dir ~keeper_id:name with
      | Ok rows -> rows, None
      | Error error ->
        [], Some (Keeper_memory_os_events.file_read_error_to_string error)
    in
    let revisions, retractions, lineage_read_error =
      match read_commit_lineage_from_log ~keepers_dir ~keeper_id:name with
      | Ok (revisions, retractions) -> revisions, retractions, None
      | Error detail ->
        [], [], Some ("memory commit log lineage read failed: " ^ detail)
    in
    let events_read_error =
      match sidecar_read_error, lineage_read_error with
      | None, None -> None
      | Some detail, None | None, Some detail -> Some detail
      | Some sidecar, Some journal -> Some (sidecar ^ "; " ^ journal)
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
    let fact_json (memory_id, (fact : Keeper_memory_os_types.fact)) event_summary =
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
        ; "memory_id", `String memory_id
        ; "basis", Keeper_memory_os_types.basis_to_json fact.basis
        ; ( "events"
          , Keeper_memory_os_events.summary_to_json event_summary )
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
        let facts =
          match snapshot.Keeper_memory_os_current.facts with
          | [] -> []
          | facts ->
            let facts = List.map (fun fact -> Keeper_memory_os_types.memory_id fact, fact) facts in
            let summaries = Keeper_memory_os_events.summaries_for
                ~memory_ids:(List.map fst facts)
                ~revisions
                ~retractions
                events in
            List.map2 fact_json facts summaries
        in
        `Assoc
          [ "present", `Bool true
          ; "revision", `Int snapshot.Keeper_memory_os_current.revision
          ; "snapshot_sha256", `String snapshot_sha256
          ; "updated_at", `Float snapshot.Keeper_memory_os_current.updated_at
          ; "facts", `List facts
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
     reach disk here — committed and failed alike — and
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
      read_memory_log_tail_projection
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

let memory_os_internals_json ~(config : Workspace.config) ~keeper_id =
  let keepers_dir = memory_os_keepers_dir config in
  let compaction_json =
    match Keeper_compaction.inspect_stats ~keepers_dir ~keeper_id with
    | Error err ->
      `Assoc
        [ "present", `Bool false
        ; "epoch_count", `Int 0
        ; "archived_turns_count", `Int 0
        ; "anchor_bytes", `Int 0
        ; "latest_epoch_id", `Null
        ; "covers_through_turn", `Null
        ; "archived_epochs_through", `Null
        ; "verified_facts_count", `Int 0
        ; "decisions_count", `Int 0
        ; "open_threads_count", `Int 0
        ; "read_error", `String (Keeper_compaction.store_error_to_string err)
        ]
    | Ok s ->
      let ( latest_epoch_id
          , covers_through_turn
          , archived_epochs_through
          , verified_facts_count
          , decisions_count
          , open_threads_count ) =
        match s.latest_anchor with
        | None -> `Null, `Null, `Null, 0, 0, 0
        | Some a ->
          ( `Int a.epoch_id
          , `String (Ids.Turn_id.to_string a.covers_through_turn)
          , Json_util.int_opt_to_json a.archived_epochs_through
          , List.length a.verified_facts_and_files
          , List.length a.decisions_made
          , List.length a.open_threads )
      in
      `Assoc
        [ "present", `Bool s.present
        ; "epoch_count", `Int s.epoch_count
        ; "archived_turns_count", `Int s.archived_turns_count
        ; "anchor_bytes", `Int s.anchor_bytes
        ; "latest_epoch_id", latest_epoch_id
        ; "covers_through_turn", covers_through_turn
        ; "archived_epochs_through", archived_epochs_through
        ; "verified_facts_count", `Int verified_facts_count
        ; "decisions_count", `Int decisions_count
        ; "open_threads_count", `Int open_threads_count
        ; "read_error", `Null
        ]
  in
  let canonical_turns_json =
    match Keeper_canonical_turn_store.inspect_stats ~keepers_dir ~keeper_id with
    | Error err ->
      `Assoc
        [ "present", `Bool false
        ; "turn_count", `Int 0
        ; "latest_turn_id", `Null
        ; "latest_runtime_kind", `Null
        ; "latest_runtime_id", `Null
        ; "latest_created_at", `Null
        ; "compaction_watermark_seq", `Null
        ; "compaction_watermark_epoch", `Null
        ; "history_resets_count", `Int 0
        ; "latest_reset_at", `Null
        ; "read_error", `String (Keeper_canonical_turn_store.store_error_to_string err)
        ]
    | Ok s ->
      `Assoc
        [ "present", `Bool s.present
        ; "turn_count", `Int s.turn_count
        ; ( "latest_turn_id"
          , Json_util.string_opt_to_json (Option.map Ids.Turn_id.to_string s.latest_turn_id) )
        ; ( "latest_runtime_kind"
          , Json_util.string_opt_to_json
              (Option.map Keeper_canonical_turn_store.runtime_kind_to_string s.latest_runtime_kind) )
        ; "latest_runtime_id", Json_util.string_opt_to_json s.latest_runtime_id
        ; "latest_created_at", Json_util.float_opt_to_json s.latest_created_at
        ; ( "compaction_watermark_seq"
          , match s.compaction_watermark_seq with
            | None -> `Null
            | Some seq -> `Int (Int64.to_int seq) )
        ; "compaction_watermark_epoch", Json_util.int_opt_to_json s.compaction_watermark_epoch
        ; "history_resets_count", `Int s.history_resets_count
        ; "latest_reset_at", Json_util.float_opt_to_json s.latest_reset_at
        ; "read_error", `Null
        ]
  in
  let digest_meta = Keeper_memory_digest.read_cached_meta ~keepers_dir ~keeper_id in
  let memory_digest_json =
    `Assoc
      [ "present", `Bool digest_meta.present
      ; "revision", Json_util.int_opt_to_json digest_meta.revision
      ; "digest_sha256", Json_util.string_opt_to_json digest_meta.digest_sha256
      ; "bytes", `Int digest_meta.bytes
      ; "fact_count", `Int digest_meta.fact_count
      ; "derived_count", `Int digest_meta.derived_count
      ]
  in
  let writer_row =
    Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
      Keeper_memory_writer_health.keeper_rows ~config keeper_id)
  in
  let librarian_molt_json =
    match writer_row with
    | `Assoc fields ->
      (match List.assoc_opt "kind" fields, List.assoc_opt "row" fields with
       | Some (`String "writer"), Some (`Assoc row_fields) ->
         `Assoc
           [ "writer_kind", `String "writer"
           ; "writer_state", Option.value ~default:`Null (List.assoc_opt "state" row_fields)
           ; "pending_molt", Option.value ~default:`Null (List.assoc_opt "pending_molt" row_fields)
           ; ( "pending_molt_categories"
             , Option.value ~default:(`List []) (List.assoc_opt "pending_molt_categories" row_fields) )
           ; ( "available_acts"
             , Option.value ~default:(`List []) (List.assoc_opt "available_acts" row_fields) )
           ]
       | Some (`String kind), _ ->
         `Assoc
           [ "writer_kind", `String kind
           ; "writer_state", `Null
           ; "pending_molt", `Null
           ; "pending_molt_categories", `List []
           ; "available_acts", `List []
           ]
       | _ ->
         `Assoc
           [ "writer_kind", `String "unknown"
           ; "writer_state", `Null
           ; "pending_molt", `Null
           ; "pending_molt_categories", `List []
           ; "available_acts", `List []
           ])
    | _ ->
      `Assoc
        [ "writer_kind", `String "unknown"
        ; "writer_state", `Null
        ; "pending_molt", `Null
        ; "pending_molt_categories", `List []
        ; "available_acts", `List []
        ]
  in
  `Assoc
    [ "keeper", `String keeper_id
    ; "dashboard_surface", `String "/api/v1/keepers/:name/memory-os-internals"
    ; "compaction", compaction_json
    ; "canonical_turns", canonical_turns_json
    ; "memory_digest", memory_digest_json
    ; "librarian_molt", librarian_molt_json
    ]
;;

let handle_memory_os_internals_get state req reqd name =
  if not (Keeper_config.validate_name name)
  then
    Http.Response.json_value ~status:`Bad_request
      (`Assoc
         [ "error", `String (Printf.sprintf "invalid keeper name: %s" name) ])
      reqd
  else (
    let config = Mcp_server.workspace_config state in
    let json = memory_os_internals_json ~config ~keeper_id:name in
    Http.Response.json_value ~compress:true ~request:req json reqd)
;;
