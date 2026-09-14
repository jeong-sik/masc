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
    Some (Digestif.SHA256.(digest_string (Yojson.Safe.to_string (`Assoc
      ["trace", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id); "progress", progress])) |> to_hex))
  | None, _ | Some _, (Owner_absent | Owner_projection {meta = None; _}
      | Owner_projection {stopping = true; _}) -> None

let capture ~base_path ~keepers_dir ~keeper_name =
  let before = execution_basis ~base_path ~keeper_name in
  let failures = ref [] in
  let events = match Keeper_registry_event_queue.pending_selections_result ~base_path keeper_name with
    | Ok selections -> List.map Context.source_of_event selections
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
    | Ok snapshot -> snapshot
    | Error detail -> failures := ("previous context: " ^ detail) :: !failures; None in
  let _, reversed_sources = List.fold_left (fun (seen, acc) (source : Context.source) ->
    if References.mem source.reference seen then seen, acc
    else References.add source.reference seen, source :: acc)
    (References.empty, []) (events @ chats) in
  let after = execution_basis ~base_path ~keeper_name in
  {Context.sources = List.rev reversed_sources; previous; unavailable = List.rev !failures;
   execution_basis = (if before = after then after else None)}

let render ~base_path ~keepers_dir ~keeper_name =
  try
    let input = capture ~base_path ~keepers_dir ~keeper_name in
    List.iter (fun detail -> Log.Keeper.warn ~keeper_name
      "working context source unavailable; original intake continues: %s" detail) input.unavailable;
    Context.render input
  with
  | Eio.Cancel.Cancelled _ as error -> raise error
  | exn ->
    Log.Keeper.warn ~keeper_name "working context unavailable; original intake continues: %s"
      (Printexc.to_string exn);
    None
