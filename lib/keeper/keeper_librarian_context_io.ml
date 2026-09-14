module Context = Keeper_librarian_context
module References = Set.Make (String)

let capture ~base_path ~keepers_dir ~keeper_name =
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
  let previous = match Context.read ~keepers_dir ~keeper_id:keeper_name with
    | Ok snapshot -> snapshot
    | Error detail -> failures := ("previous context: " ^ detail) :: !failures; None in
  let _, reversed_sources = List.fold_left (fun (seen, acc) (source : Context.source) ->
    if References.mem source.reference seen then seen, acc
    else References.add source.reference seen, source :: acc)
    (References.empty, []) (events @ chats) in
  {Context.sources = List.rev reversed_sources; previous; unavailable = List.rev !failures}

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
