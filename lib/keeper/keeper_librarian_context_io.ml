module Context = Keeper_librarian_context
module References = Set.Make (String)

let execution_basis ~base_path ~keeper_name =
  match Keeper_registry.get ~base_path keeper_name,
        Keeper_owner_projection.lookup ~base_path ~keeper_name with
  | Some entry, Owner_projection {meta = Some meta; stopping = false} ->
    let progress = match entry.Keeper_registry_types.current_turn_observation with
      | Some observation -> `Assoc
          ["turn", `Int observation.turn_id; "started_at", `Float observation.started_at;
           "progress_at", `Float observation.last_progress_at; "active_tools", `Int observation.active_tool_count]
      | None -> `Assoc ["completed_turns", `Int meta.runtime.usage.total_turns;
          "last_turn_at", `Float meta.runtime.usage.last_turn_ts] in
    Some (Agent_core_sha256.(digest_string (Yojson.Safe.to_string (`Assoc
      ["trace", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id); "progress", progress])) |> to_hex))
  | None, _ | Some _, (Owner_absent | Owner_projection {meta = None; _}
      | Owner_projection {stopping = true; _}) -> None

let capture ~base_path ~keepers_dir ~keeper_name =
  let before = execution_basis ~base_path ~keeper_name in
  let failures = ref [] in
  (* Queue observers do not run through the Owner's profile refresh. Resolve
     the effective TOML aliases here rather than using its cached projection. *)
  let meta = Keeper_meta_store.read_effective_meta
    (Workspace.default_config base_path) keeper_name in
  let can_project stimulus =
    let allowed = match meta with
      | Ok (Some meta) -> Keeper_board_audience.can_project_queued_stimulus ~meta stimulus
      | Ok None | Error _ ->
        (match stimulus.Keeper_event_queue.payload with
         | Keeper_event_queue.Board_routing_pending _ | Board_signal _ | Board_attention _ -> false
         | Keeper_event_queue.Bootstrap | Fusion_completed _ | Schedule_due _
         | Connector_attention _ | Hitl_resolved _ | Ask_answered _
         | Completion_authority_rejected _ | Task_outcome _ | Task_cancelled _
         | Workspace_message _ | Delegate_completed _ | Composition_completed _
         | Tool_result_ready _ | Owned_job_completed _ -> true) in
    if not allowed then failures := "Board queue source withheld pending authorized routing/readership" :: !failures;
    allowed in
  let events = match Keeper_registry_event_queue.pending_selections_result ~base_path keeper_name with
    | Ok selections -> selections
      |> List.filter (fun (selection : Keeper_event_queue_state.pending_selection) -> can_project selection.source)
      |> List.map Context.source_of_event
    | Error detail -> failures := ("events: " ^ detail) :: !failures; [] in
  let path = Keeper_chat_operation_store.path_for_keeper
      ~keepers_runtime_dir:(Common.keepers_runtime_dir_of_base ~base_path) ~keeper_name in
  (* A single read-only SQLite snapshot includes queued and running original
     inputs. It cannot chase a growing/reordered cursor, claim a row, or wait
     for the Owner mailbox. Running questions remain unresolved context. *)
  let chats = match Keeper_chat_operation_store.inspect_pending_inputs ~path with
    | Ok (Some chat_operations) -> List.map Context.source_of_chat chat_operations
    | Ok None -> failures := "chat store not yet available" :: !failures; []
    | Error error -> failures := Keeper_chat_operation_store.error_to_string error :: !failures; [] in
  let previous = match Context.read_for_update ~keepers_dir ~keeper_id:keeper_name with
    | Ok snapshot ->
      Option.map (fun (snapshot : Context.snapshot) ->
        let sources = List.filter (fun (source : Context.source) ->
          if not (String.starts_with ~prefix:"event:" source.reference) then true
          else match Keeper_event_queue.stimulus_of_yojson source.content with
            | Ok stimulus -> can_project stimulus
            | Error _ -> failures := "Retained event source unavailable" :: !failures; false)
          snapshot.sources in
        let allowed = List.fold_left (fun set (source : Context.source) -> References.add source.reference set)
          References.empty sources in
        (* A merged context may contain any of its sources. Withhold the whole
           pocket if one source is private/unresolved; keep stored data intact. *)
        let pockets = List.filter (fun (pocket : Context.pocket) ->
          List.for_all (fun reference -> References.mem reference allowed) pocket.sources)
          snapshot.pockets in
        { snapshot with sources; pockets }) snapshot
    | Error detail -> failures := ("previous context: " ^ detail) :: !failures; None in
  let _, reversed_sources = List.fold_left (fun (seen, acc) (source : Context.source) ->
    if References.mem source.reference seen then seen, acc
    else References.add source.reference seen, source :: acc)
    (References.empty, []) (events @ chats) in
  let after = execution_basis ~base_path ~keeper_name in
  {Context.sources = List.rev reversed_sources; previous; unavailable = List.rev !failures;
   execution_basis = (if before = after then after else None)}
