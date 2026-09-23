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
  ; recovery_receipt : Keeper_memory_os_current.durable_range_id option
  ; range : R.range
  ; covering_cut : R.atom_cut
  ; start_atom : int
  ; end_atom : int
  ; unread : Agent_core.Types.message list
  ; catch_up_target : int option
  }

type no_source =
  | Drained
  | Source_unreadable
  | Empty_range

type source =
  | Ready of prepared
  | No_source of no_source

let path_in ~keepers_dir ~keeper_name =
  Filename.concat (Filename.concat keepers_dir keeper_name) "librarian-continuity.json"
let path ~config ~keeper_name =
  path_in ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_name
let read_in ~keepers_dir ~keeper_name =
  let file = path_in ~keepers_dir ~keeper_name in
  match Fs_compat.exact_path_kind ~follow:false file with
  | Fs_compat.Exact_missing -> Ok None
  | Fs_compat.Exact_kind _ -> S.load ~path:file |> Result.map Option.some |> Result.map_error S.error_to_string
  | Fs_compat.Exact_unknown -> Error "continuity snapshot path cannot be inspected"
let read ~config ~keeper_name =
  read_in ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_name
let prepare_source ?end_atom ~config ~keeper_name ~trace_id () =
  let* lines = B.read ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name in
  let* previous = read ~config ~keeper_name in
  let progress = Option.map (fun (snapshot : S.t) ->
    {Keeper_librarian_progress.position =
      {trace_id=snapshot.trace_id;end_atom=snapshot.end_atom;last_atom_digest=snapshot.last_atom_digest};
     boundary_lines_seen=snapshot.end_boundary_line}) previous in
  if not (R.may_have_unread ~trace_id ~lines ~progress) then Ok (No_source Drained) else
  let session_dir = Filename.concat (Keeper_fs.session_store_path config) trace_id in
  match C.load_agent_core_exact_snapshot ~session_dir ~session_id:trace_id with
  | Error C.Ref_not_found -> Ok (No_source Source_unreadable)
  | Error error -> Error (match error with
      | C.Ref_not_found -> "continuity checkpoint absent"
      | C.Ref_read_failed error -> C.checkpoint_load_error_to_string error
      | C.Ref_identity_invalid _ -> "continuity checkpoint identity invalid"
      | C.Ref_session_mismatch _ -> "continuity checkpoint trace mismatch"
      | C.Ref_lock_failed detail -> detail)
  | Ok checkpoint ->
    let messages = C.exact_snapshot_messages checkpoint in
    match S.checkpoint_prefix_range ~trace_id ~lines ~messages with
    | Error S.Uncovered_history -> Ok (No_source Source_unreadable)
    | Error error -> Error (S.error_to_string error)
    | Ok range ->
      let fitting_previous = match previous with
        | Some snapshot -> (match S.restore ~trace_id ~lines ~messages snapshot with
            | Ok restored -> Some (snapshot, restored.working_state)
            | Error _ -> None)
        | None -> None in
      let previous_state, start_atom = match fitting_previous with
        | Some ((snapshot : S.t), working_state) -> Some working_state, snapshot.end_atom
        | None -> None, 0 in
      (* A rewrite from atom 0 must not move a request's start back
         (RFC keeper-context-window-in-tokens §13.4). While it catches up,
         the snapshot carries where a request starts without it -- the
         Librarian's durable position when it fits this history, else the
         end of the last completed turn, as the turn driver decides -- taken
         again every round, since both move on while the rewrite runs. The
         snapshot is not a request's working state until its end reaches
         that start; the capture drops the target then. An ordinary
         snapshot, one that fitted and was not catching up, carries none. *)
      let start_without_snapshot () =
        let position_fits (progress : Keeper_librarian_progress.t) =
          let position = progress.position in
          String.equal position.trace_id trace_id && position.end_atom >= 1
          && W.atom_opening_digest messages (position.end_atom - 1) = Some position.last_atom_digest in
        match
          Keeper_librarian_progress.read
            ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name
        with
        | Ok (Some progress) when position_fits progress -> progress.position.end_atom
        | Ok (Some _) | Ok None | Error _ -> range.end_atom in
      let catch_up_target = match fitting_previous with
        | Some ((snapshot : S.t), _) ->
          Option.map (fun _ -> start_without_snapshot ()) snapshot.catch_up_end_atom
        | None -> Some (start_without_snapshot ()) in
      let cuts = R.cut_lines ~trace_id ~lines ~messages range
        |> List.sort (fun (left : R.atom_cut) (right : R.atom_cut) ->
          compare (left.cut_end_atom, left.cut_line) (right.cut_end_atom, right.cut_line)) in
      let* receipt = Keeper_memory_os_current.committed_durable_range
        ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path)
        ~keeper_id:keeper_name ~receipt_scope:(path ~config ~keeper_name) in
      let recovery_receipt = match receipt with
        | Some receipt when String.equal receipt.trace_id trace_id
            && receipt.history_start_boundary_line = range.history_start_boundary_line
            && receipt.start_atom = start_atom && receipt.end_atom > start_atom
            && receipt.end_atom <= range.end_atom
            && W.atom_opening_digest messages (receipt.end_atom - 1) = Some receipt.last_atom_digest
            && List.exists (fun (cut : R.atom_cut) -> cut.cut_line = receipt.end_boundary_line
                 && cut.cut_end_atom >= receipt.end_atom) cuts -> Some receipt
        | _ -> None in
      let end_atom = match recovery_receipt with
        | Some receipt -> receipt.end_atom
        | None ->
          (match end_atom with
           | Some requested -> requested
           | None ->
             match List.find_opt (fun (cut : R.atom_cut) -> cut.cut_end_atom > start_atom) cuts with
             | Some cut -> cut.cut_end_atom
             | None -> range.end_atom) in
      if end_atom > range.end_atom || end_atom < 1 then
        Error "continuity cut is outside the completed checkpoint prefix"
      else if end_atom <= start_atom then Ok (No_source Empty_range)
      else
        let* covering_cut = match List.find_opt (fun (cut : R.atom_cut) ->
          match recovery_receipt with
          | Some receipt -> cut.cut_line = receipt.end_boundary_line
          | None -> cut.cut_end_atom >= end_atom) cuts with
          | Some cut -> Ok cut
          | None -> Error "continuity source has no covering completed boundary" in
        let unread = R.slice messages {range with R.start_atom; end_atom} in
        Ok (Ready {trace_id;lines;messages;previous;previous_state;recovery_receipt;range;covering_cut;start_atom;end_atom;unread;
                  catch_up_target})

(* The reason an empty source was empty is dropped here: a caller that only
   asks whether there is work does not distinguish them. *)
let prepare ?end_atom ~config ~keeper_name ~trace_id () =
  prepare_source ?end_atom ~config ~keeper_name ~trace_id ()
  |> Result.map (function Ready prepared -> Some prepared | No_source _ -> None)
let messages prepared = prepared.unread
let turn_ref prepared = prepared.covering_cut.cut_turn_ref
let start_atom prepared = prepared.start_atom
let completed_end_atom prepared = prepared.range.end_atom
let end_atom prepared = prepared.end_atom
let narrow prepared =
  let count = prepared.end_atom - prepared.start_atom in
  if count <= 1 || Option.is_some prepared.recovery_receipt then None
  else
    let end_atom = prepared.start_atom + count / 2 in
    let unread = R.slice prepared.messages {prepared.range with R.start_atom = prepared.start_atom; end_atom} in
    Some {prepared with end_atom; unread; recovery_receipt = None}
let rec fit ~fits prepared =
  let* accepted = fits prepared in
  if accepted then Ok (Some prepared)
  else match narrow prepared with
    | None -> Ok None
    | Some smaller -> fit ~fits smaller
let memory_range_id ~config ~keeper_name prepared =
  match prepared.recovery_receipt with Some receipt -> Ok receipt | None ->
  let cut = prepared.covering_cut in
  match W.atom_opening_digest prepared.messages (prepared.end_atom - 1) with
  | Some last_atom_digest -> Ok
    { Keeper_memory_os_current.receipt_scope = path ~config ~keeper_name;
      trace_id = prepared.trace_id;
      history_start_boundary_line = prepared.range.history_start_boundary_line;
      start_atom = prepared.start_atom; end_atom = prepared.end_atom; last_atom_digest;
      end_boundary_line = cut.cut_line;
      boundary_lines_seen = List.fold_left (fun count (_, read) ->
        match read with Error B.Incomplete_line -> count | _ -> count + 1) 0 prepared.lines }
  | None -> Error "continuity source has no covering completed boundary"
let memory_committed ~config ~keeper_name prepared =
  let* expected = memory_range_id ~config ~keeper_name prepared in
  let* actual = Keeper_memory_os_current.committed_durable_range
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path)
    ~keeper_id:keeper_name ~receipt_scope:expected.receipt_scope in
  if actual = Some expected then Ok true else
  let* ordinary = Keeper_memory_os_current.committed_durable_range
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path)
    ~keeper_id:keeper_name ~receipt_scope:(Workspace.keepers_runtime_dir config) in
  (* Only the serial consumer's genuinely read interval is known: a baseline
     is not evidence for the prefix preceding it. This receipt never changes
     the independent continuity recovery range. *)
  let floor = match R.select ~trace_id:prepared.trace_id ~lines:prepared.lines
      ~progress:None ~messages:prepared.messages R.All_unread with
    | R.Read {range;_} when range.start_atom = 0 -> Some 0
    | R.Baseline {position;_} -> Some position.end_atom
    | R.Read _ | R.Nothing_to_read | R.Position_in_other_trace _ | R.Stop _ -> None in
  Ok (match ordinary, floor with
    | Some receipt, Some floor ->
      String.equal receipt.trace_id prepared.trace_id
      && receipt.history_start_boundary_line = prepared.range.history_start_boundary_line
      && receipt.start_atom >= floor && prepared.start_atom >= floor
      && prepared.end_atom <= receipt.end_atom
      && W.atom_opening_digest prepared.messages (receipt.end_atom - 1) = Some receipt.last_atom_digest
      && List.exists (fun (cut : R.atom_cut) ->
           cut.cut_line = receipt.end_boundary_line && cut.cut_end_atom = receipt.end_atom)
           (R.cut_lines ~trace_id:prepared.trace_id ~lines:prepared.lines
              ~messages:prepared.messages prepared.range)
    | None, _ | Some _, None -> false)
let prompt_json prepared =
  `Assoc ["previous_working_state", (match prepared.previous_state with None -> `Null | Some text -> `String text);
    "completed_conversation", `List (List.map Agent_core.Checkpoint.message_to_json prepared.unread)]
let commit ~config ~keeper_name ~prepared ~working_state =
  let* covered = memory_committed ~config ~keeper_name prepared in
  let* () = if covered then Ok () else Error "Memory has not committed this continuity source" in
  (* Capture against this work unit's actual completed turn, not a later
     backlog boundary. Keep the full frozen checkpoint in [prepared] for
     Memory coverage checks; only this capture view ends at the chosen cut. *)
  let messages = W.annotate prepared.messages |> fst |> List.filter_map (fun (message, label) ->
    match label with
    | W.Pinned -> Some message
    | W.Atom atom -> if atom < prepared.covering_cut.cut_end_atom then Some message else None) in
  let* snapshot = S.capture_checkpoint_prefix ~end_atom:prepared.end_atom
    ~catch_up_end_atom:prepared.catch_up_target
    ~trace_id:prepared.trace_id ~lines:prepared.lines ~messages
    ~working_state () |> Result.map_error S.error_to_string in
  let file = path ~config ~keeper_name in
  Fs_compat.mkdir_p (Filename.dirname file);
  File_lock_eio.with_lock file (fun () ->
    let* current = read ~config ~keeper_name in
    if current <> prepared.previous then Error "continuity snapshot changed during generation"
    else let* () = S.save ~path:file snapshot |> Result.map_error S.error_to_string in Ok snapshot)
