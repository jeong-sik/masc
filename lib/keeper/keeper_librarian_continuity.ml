module S = Librarian_continuity_snapshot
module R = Keeper_librarian_range
module B = Keeper_turn_boundaries
module C = Keeper_checkpoint_store
module W = Runtime_model_input_tail_window
let ( let* ) = Result.bind

type prepared =
  { trace_id : string
  ; lines : (int * (B.record, B.read_error) result) list
  ; messages : Agent_core.Types.message list
  ; previous : S.t option
  ; previous_state : string option
  ; unread : Agent_core.Types.message list
  }
let path ~config ~keeper_name =
  Filename.concat (Filename.concat (Workspace.keepers_runtime_dir config) keeper_name)
    "librarian-continuity.json"
let read ~config ~keeper_name =
  let file = path ~config ~keeper_name in
  match Fs_compat.exact_path_kind ~follow:false file with
  | Fs_compat.Exact_missing -> Ok None
  | Fs_compat.Exact_kind _ -> S.load ~path:file |> Result.map Option.some |> Result.map_error S.error_to_string
  | Fs_compat.Exact_unknown -> Error "continuity snapshot path cannot be inspected"
let prepare ~config ~keeper_name ~trace_id =
  let* lines = B.read ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name in
  let* previous = read ~config ~keeper_name in
  let progress = Option.map (fun (snapshot : S.t) ->
    {Keeper_librarian_progress.position =
      {trace_id=snapshot.trace_id;end_atom=snapshot.end_atom;last_atom_digest=snapshot.last_atom_digest};
     boundary_lines_seen=snapshot.end_boundary_line}) previous in
  if not (R.may_have_unread ~trace_id ~lines ~progress) then Ok None else
  let session_dir = Filename.concat (Keeper_fs.session_store_path config) trace_id in
  match C.load_agent_core_exact_snapshot ~session_dir ~session_id:trace_id with
  | Error C.Ref_not_found -> Ok None
  | Error error -> Error (match error with
      | C.Ref_not_found -> "continuity checkpoint absent"
      | C.Ref_read_failed error -> C.checkpoint_load_error_to_string error
      | C.Ref_identity_invalid _ -> "continuity checkpoint identity invalid"
      | C.Ref_session_mismatch _ -> "continuity checkpoint trace mismatch"
      | C.Ref_lock_failed detail -> detail)
  | Ok checkpoint ->
    let messages = C.exact_snapshot_messages checkpoint in
    match R.select ~trace_id ~lines ~progress:None ~messages R.All_unread with
    | R.Read {range;_} when range.start_atom=0 ->
      let labelled,_ = W.annotate messages in
      let messages = List.filter_map (fun (message,label) -> match label with
        | W.Pinned -> Some message
        | W.Atom atom -> if atom < range.end_atom then Some message else None) labelled in
      let previous_state, unread = match previous with
        | Some snapshot -> (match S.restore ~trace_id ~lines ~messages snapshot with
            | Ok restored -> Some restored.working_state, restored.messages
            | Error _ -> None, messages)
        | None -> None, messages in
      let has_atoms = List.exists (fun (_,label) -> match label with W.Atom _ -> true | W.Pinned -> false)
        (fst (W.annotate unread)) in
      if not has_atoms && Option.is_some previous_state then Ok None
      else Ok (Some {trace_id;lines;messages;previous;previous_state;unread})
    | R.Stop _ -> Error "continuity source boundary cannot be read safely"
    | R.Read _ | R.Baseline _ | R.Nothing_to_read | R.Position_in_other_trace _ -> Ok None
let memory_covers ~config ~keeper_name prepared =
  let* receipt = Keeper_memory_os_current.committed_durable_range
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path)
    ~keeper_id:keeper_name ~receipt_scope:(Workspace.keepers_runtime_dir config) in
  match receipt, R.select ~trace_id:prepared.trace_id ~lines:prepared.lines ~progress:None
    ~messages:prepared.messages R.All_unread with
  | Some receipt, R.Read {range;_} ->
    let ending = List.find_map (function
      | line, Ok {B.event=B.Turn_ended {turn_ref;
          position=B.Atom_history {end_atom;last_atom_digest};_};_}
        when line >= range.history_start_boundary_line
          && String.equal (Ids.Turn_ref.trace_id turn_ref) prepared.trace_id
          && end_atom=range.end_atom && String.equal last_atom_digest range.last_atom_digest -> Some line
      | _ -> None) prepared.lines in
    Ok (String.equal receipt.trace_id prepared.trace_id
      && receipt.history_start_boundary_line=range.history_start_boundary_line
      && receipt.end_atom=range.end_atom
      && String.equal receipt.last_atom_digest range.last_atom_digest
      && ending=Some receipt.end_boundary_line)
  | _ -> Ok false
let prepare_committed ~config ~keeper_name ~trace_id =
  let* prepared = prepare ~config ~keeper_name ~trace_id in
  match prepared with
  | None -> Ok None
  | Some prepared ->
    let* covered = memory_covers ~config ~keeper_name prepared in
    Ok (if covered then Some prepared else None)
let prompt_json prepared =
  `Assoc ["previous_working_state", (match prepared.previous_state with None -> `Null | Some text -> `String text);
    "completed_conversation", `List (List.map Agent_core.Checkpoint.message_to_json prepared.unread)]
let commit ~config ~keeper_name ~prepared ~working_state =
  let* snapshot = S.capture ~trace_id:prepared.trace_id ~lines:prepared.lines
    ~messages:prepared.messages ~working_state |> Result.map_error S.error_to_string in
  let* covered = memory_covers ~config ~keeper_name prepared in
  let* () = if covered then Ok () else Error "Memory has not committed this exact continuity frontier" in
  let file = path ~config ~keeper_name in
  Fs_compat.mkdir_p (Filename.dirname file);
  File_lock_eio.with_lock file (fun () ->
    let* current = read ~config ~keeper_name in
    if current <> prepared.previous then Error "continuity snapshot changed during generation"
    else let* () = S.save ~path:file snapshot |> Result.map_error S.error_to_string in Ok snapshot)
