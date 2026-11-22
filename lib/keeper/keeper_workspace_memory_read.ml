let failure ~failure_class detail =
  Keeper_tool_execution.failure_data ~class_:failure_class ~message:detail
    (`Assoc ["ok", `Bool false; "error", `String detail])

let scrub_fact_for_workspace_reader (fact : World_memory_types.world_fact) =
  let provenance =
    match fact.provenance with
    | World_memory_types.Proposed_by { keeper_id; source_fact_ids = _ } ->
      World_memory_types.Proposed_by { keeper_id; source_fact_ids = [] }
    | World_memory_types.Cross_keeper_synthesized { keeper_ids; source_world_fact_ids } ->
      let filtered_ids =
        List.filter World_memory_types.is_world_fact_id source_world_fact_ids
      in
      World_memory_types.Cross_keeper_synthesized
        { keeper_ids; source_world_fact_ids = filtered_ids }
  in
  { fact with provenance }
;;

let is_shared_workspace_scope scope = not (World_memory_types.is_private_scope scope)

let handle_mvcc ~base_path ~args =
  let ok_data json =
    Keeper_tool_execution.success_data
      (`Assoc [ "ok", `Bool true; "backend", `String "sqlite_wal_mvcc"; "workspace_memory", json ])
  in
  let err_of e =
    failure ~failure_class:Tool_result.Dependency_unavailable (World_memory_store.error_to_string e)
  in
  match args with
  | `Assoc [] ->
    (match World_memory_store.read_snapshot ~include_inactive:false ~base_path () with
     | Ok { facts; entries; digest = digest_opt; _ } ->
       let shared_facts =
         List.filter
           (fun (f : World_memory_types.world_fact) ->
              not (World_memory_types.is_private_scope f.scope))
           facts
       in
       let canonical_count =
         List.length
           (List.filter
              (fun (f : World_memory_types.world_fact) -> f.lifecycle = Canonical)
              shared_facts)
       in
       ok_data
         (`Assoc
            [ "status", `String "available"
            ; "fact_count", `Int (List.length shared_facts)
            ; "canonical_count", `Int canonical_count
            ; "index_count", `Int (List.length entries)
            ; ( "digest"
              , Option.fold ~none:`Null ~some:World_memory_types.world_digest_to_json digest_opt )
            ])
     | Error e -> err_of e)
  | `Assoc [ "view", `String "index" ] ->
    (match World_memory_store.read_snapshot ~include_inactive:false ~base_path () with
     | Ok { facts; entries; _ } ->
       let shared_facts =
         facts
         |> List.filter (fun (f : World_memory_types.world_fact) ->
              is_shared_workspace_scope f.scope)
         |> List.map scrub_fact_for_workspace_reader
       in
       ok_data
         (`Assoc
            [ "status", `String "available"
            ; "claims", `List (List.map World_memory_types.world_fact_to_json shared_facts)
            ; "index", `List (List.map World_memory_types.index_entry_to_json entries)
            ])
     | Error e -> err_of e)
  | `Assoc [ "view", `String "briefing" ] ->
    (match World_memory_store.latest_digest ~base_path with
     | Ok None -> ok_data (`Assoc [ "status", `String "pending"; "briefing", `Null ])
     | Ok (Some digest) ->
       ok_data
         (`Assoc
            [ "status", `String "available"
            ; "briefing", World_memory_types.world_digest_to_json digest
            ])
     | Error e -> err_of e)
  | `Assoc [ "query", `String query ] when String.trim query <> "" ->
    (match World_memory_store.search_fts ~base_path ~query ~limit:10 with
     | Ok hits ->
       ok_data
         (`Assoc
            [ "status", `String "available"
            ; "query", `String query
            ; "total_matches", `Int (List.length hits)
            ; "matches", `List (List.map World_memory_types.search_hit_to_json hits)
            ])
     | Error e -> err_of e)
  | `Assoc [ "id", `String id ] when String.trim id <> "" ->
    (match
       World_memory_store.read_fact_with_edges ~include_inactive:false
         ~visible_scope:is_shared_workspace_scope ~base_path ~fact_id:id ()
     with
     | Ok None -> ok_data (`Assoc [ "found", `Bool false; "id", `String id ])
     | Ok (Some (fact, _edges)) when not (is_shared_workspace_scope fact.scope) ->
       ok_data (`Assoc [ "found", `Bool false; "id", `String id ])
     | Ok (Some (fact, edges)) ->
       let scrubbed = scrub_fact_for_workspace_reader fact in
       ok_data
         (`Assoc
            [ "found", `Bool true
            ; "fact", World_memory_types.world_fact_to_json scrubbed
            ; "edges", `List (List.map World_memory_types.world_edge_to_json edges)
            ])
     | Error e -> err_of e)
  | _ ->
    failure ~failure_class:Tool_result.Policy_rejection
      "Expected {}, a nonblank query, a nonblank id, or view=index|briefing; use one selector"

let handle ~base_path ~args =
  if World_memory_store.exists ~base_path
  then handle_mvcc ~base_path ~args
  else
    match args with
    | `Assoc [] ->
      (match Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
         Workspace_memory_ledger_view.inventory ~base_path ()) with
       | Ok json -> Keeper_tool_execution.success_data
           (`Assoc ["ok", `Bool true; "workspace_memory", json])
       | Error detail -> failure ~failure_class:Tool_result.Dependency_unavailable detail)
    | `Assoc ["view", `String "index"] ->
      (match Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
         Workspace_memory_ledger_view.summary ~base_path) with
       | Ok json -> Keeper_tool_execution.success_data
           (`Assoc ["ok", `Bool true; "workspace_memory", json])
       | Error detail -> failure ~failure_class:Tool_result.Dependency_unavailable detail)
    | `Assoc ["view", `String "briefing"] ->
      (match Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
         Workspace_memory_ledger_view.briefing ~base_path ()) with
       | Ok json -> Keeper_tool_execution.success_data
           (`Assoc ["ok", `Bool true; "workspace_memory", json])
       | Error detail -> failure ~failure_class:Tool_result.Dependency_unavailable detail)
    | `Assoc ["query", `String query] when String.trim query <> "" ->
      (match Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
         Workspace_memory_ledger_view.search ~base_path ~query ~limit:5) with
       | Ok json -> Keeper_tool_execution.success_data
           (`Assoc ["ok", `Bool true; "workspace_memory", json])
       | Error detail -> failure ~failure_class:Tool_result.Dependency_unavailable detail)
    | `Assoc ["id", `String id] when String.trim id <> "" ->
      (match Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
         Workspace_memory_ledger_view.detail ~base_path ~id) with
       | Ok json -> Keeper_tool_execution.success_data
           (`Assoc ["ok", `Bool true; "workspace_memory", json])
       | Error detail -> failure ~failure_class:Tool_result.Dependency_unavailable detail)
    | _ -> failure ~failure_class:Tool_result.Policy_rejection
        "Expected {}, a nonblank query, a nonblank id, or view=index|briefing; use one selector"
