(* This is a decoded projection of one canonical checkpoint, not its raw head
   bytes. Metadata and the session have separate locks, so the trace is read
   again after the snapshot; this does not make the two stores atomic. *)
open Result.Syntax

let inspect ~base_path ~keeper_name =
  let module Store = Masc.Keeper_checkpoint_store in
  let* keeper = Keeper_id.Keeper_name.of_string keeper_name in
  let keeper_name = Keeper_id.Keeper_name.to_string keeper in
  let* workspace = Workspace_root.resolve_current ~flag:(Some base_path)
    |> Result.map_error Workspace_root.error_message in
  let base_path = workspace.Workspace_root.root in
  let runtime_root = Common.masc_dir_from_base_path ~base_path in
  let keepers_dir = Common.keepers_runtime_dir_of_base ~base_path in
  let meta_path = Filename.concat keepers_dir
      (Keeper_runtime_root_entry.keeper_basename ~keeper_name Keeper_runtime_root_entry.Metadata) in
  let read_trace () =
    match Masc.Keeper_meta_store.read_meta_file_path_read_only ~ownership_root:runtime_root meta_path with
    | Error (Masc.Keeper_meta_store.Unreadable detail | Invalid_json detail | Not_current detail) ->
      Error ("keeper metadata rejected: " ^ detail)
    | Ok None -> Error ("keeper metadata not found: " ^ keeper_name)
    | Ok (Some meta) ->
      if not (String.equal meta.Masc.Keeper_meta_contract.name keeper_name)
      then Error "keeper metadata names another keeper"
      else Ok (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
  in
  let* trace_id = read_trace () in
  let session_dir = Filename.concat
      (Masc.Keeper_fs.session_store_path_for_base_path base_path) trace_id in
  let* snapshot =
    match Store.load_agent_core_exact_snapshot ~session_dir ~session_id:trace_id with
    | Ok snapshot -> Ok (Some snapshot)
    | Error Store.Ref_not_found -> Ok None
    | Error error -> Error (Store.checkpoint_ref_load_error_to_string error)
  in
  let* after_trace = read_trace () in
  let* () =
    if String.equal trace_id after_trace then Ok ()
    else Error "keeper trace changed during checkpoint inspection"
  in
  let* state = match snapshot with
    | None -> Ok ["status", `String "not_found"]
    | Some snapshot ->
      let* checkpoint =
        Agent_core.Checkpoint.to_json_result (Store.exact_snapshot_checkpoint snapshot)
        |> Result.map_error Agent_core.Error.to_string
      in
      let reference = Store.exact_snapshot_reference snapshot in
      Ok ["status", `String "available";
          "reference", `Assoc ["trace_id", `String trace_id;
                               "turn_count", `Int reference.turn_count;
                               "content_sha256", `String reference.sha256];
          "checkpoint", checkpoint]
  in
  Ok (`Assoc (["schema", `String "masc.checkpoint-inspection.v1";
               "keeper", `String keeper_name; "trace_id", `String trace_id;
               "canonical_path", `String (Store.agent_core_checkpoint_path ~session_dir ~session_id:trace_id)] @ state))

let run ~base_path ~keeper_name =
  match inspect ~base_path ~keeper_name with
  | Error detail -> prerr_endline ("checkpoint inspection: " ^ detail); 1
  | Ok json ->
    Yojson.Safe.to_channel stdout json;
    output_char stdout '\n';
    flush stdout;
    0
