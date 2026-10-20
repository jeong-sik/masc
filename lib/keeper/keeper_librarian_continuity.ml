module S = Librarian_continuity_snapshot
module R = Keeper_librarian_range
module B = Keeper_turn_boundaries
module C = Keeper_checkpoint_store
module H = Keeper_checkpoint_store.Saved_history
module W = Runtime_model_input_tail_window
let ( let* ) = Result.bind

(* What the continuity file holds. The snapshot is derived from the
   checkpoint and the boundary log, so one that cannot be decoded -- in
   practice a format another binary wrote after a rollback or upgrade:
   unknown or missing fields, or values that fail validation -- is rebuilt
   from atom 0 like an absent one, and the rebuilt snapshot replaces it on
   commit. Its working state is dropped under the hard-cut policy; the
   rebuild costs one pass per completed turn. A file
   that cannot be read at all is an I/O failure, not a decode failure, and
   stays an error. *)
type stored =
  | Absent
  | Saved of S.t
  | Undecodable of { reason : string }

type prepared =
  { trace_id : string
  ; lines : (int * (B.record, B.read_error) result) list
  ; messages : Agent_core.Types.message list
  ; source : C.exact_source
      (* The checkpoint bytes [messages] were decoded from. *)
  ; covered_prefix : S.prefix_digest option
      (* The previous snapshot's verified prefix digest over [messages], when
         it fits; the capture extends it by this unit's atoms. *)
  ; previous : stored
  ; previous_state : string option
  ; previous_unread_messages : Keeper_librarian_unread.t list
  ; recovery_receipt : Keeper_memory_os_current.durable_range_id option
  ; range : R.range
  ; cuts : R.atom_cut list
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
let load_in ~keepers_dir ~keeper_name =
  let file = path_in ~keepers_dir ~keeper_name in
  match Fs_compat.exact_path_kind ~follow:false file with
  | Fs_compat.Exact_missing -> Ok Absent
  | Fs_compat.Exact_unknown -> Error "continuity snapshot path cannot be inspected"
  | Fs_compat.Exact_kind _ ->
    (match S.load ~path:file with
     | Ok snapshot -> Ok (Saved snapshot)
     | Error (S.Invalid_snapshot reason) -> Ok (Undecodable { reason })
     | Error
         ((S.Read_failed _ | S.Write_failed _ | S.Uncovered_history | S.Unmatched_history
          | S.Range_stopped _ | S.Trace_mismatch | S.History_changed | S.Prefix_changed) as error) ->
       Error (S.error_to_string error))
let load ~config ~keeper_name =
  load_in ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_name
let read_in ~keepers_dir ~keeper_name =
  let* stored = load_in ~keepers_dir ~keeper_name in
  match stored with
  | Absent -> Ok None
  | Saved snapshot -> Ok (Some snapshot)
  | Undecodable { reason } -> Error (S.error_to_string (S.Invalid_snapshot reason))
let read ~config ~keeper_name =
  read_in ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_name
let prepare_source ?previous ?end_atom ~config ~keeper_name ~trace_id () =
  let* lines = B.read ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name in
  let* stored = load ~config ~keeper_name in
  let previous_snapshot = match stored with
    | Saved snapshot -> Some snapshot
    | Absent -> None
    | Undecodable { reason } ->
      Log.Keeper.warn ~keeper_name
        "continuity snapshot %s cannot be decoded (%s); rebuilding it from atom 0, the commit replaces the file"
        (path ~config ~keeper_name) reason;
      None in
  let progress = Option.map (fun (snapshot : S.t) ->
    {Keeper_librarian_progress.position =
      {trace_id=snapshot.trace_id;end_atom=snapshot.end_atom;last_atom_digest=snapshot.last_atom_digest};
     boundary_lines_seen=snapshot.end_boundary_line}) previous_snapshot in
  if not (R.may_have_unread ~trace_id ~lines ~progress) then Ok (No_source Drained) else
  let session_dir = Filename.concat (Keeper_fs.session_store_path config) trace_id in
  (* The round before, in the same lane walk, holds an exact snapshot of this
     trace. While the file still holds those bytes its decoded messages are
     the ones that round read, so neither the decode nor the covered prefix's
     digest is repeated; changed bytes are decoded and digested in full.
     Nothing reads [previous] after the hash, so on changed bytes the round
     before's checkpoint can be collected before the new one is decoded. *)
  let decoded checkpoint =
    C.exact_snapshot_source checkpoint, C.exact_snapshot_messages checkpoint, None in
  let loaded = match previous with
    | Some (previous : prepared) when String.equal previous.trace_id trace_id ->
      (match C.read_agent_core_exact_bytes_since ~session_dir ~known:previous.source with
       | Ok C.Unchanged_bytes -> Ok (previous.source, previous.messages, previous.covered_prefix)
       | Ok (C.Changed_bytes changed) -> C.decode_changed_bytes changed |> Result.map decoded
       | Error _ as error -> error)
    | Some _ | None ->
      C.load_agent_core_exact_snapshot ~session_dir ~session_id:trace_id |> Result.map decoded in
  match C.saved_history_of_ref loaded with
  | Error H.Ref_not_found -> Ok (No_source Source_unreadable)
  (* Nothing in a superseded checkpoint is readable, so nothing is left to
     read, as the durable pass answers for the same file. *)
  | Ok (H.Superseded _) -> Ok (No_source Drained)
  | Error
      ((H.Ref_read_failed _ | H.Ref_identity_invalid _ | H.Ref_session_mismatch _
       | H.Ref_lock_failed _) as error) -> Error (match error with
      | H.Ref_not_found -> "continuity checkpoint absent"
      | H.Ref_read_failed error -> C.saved_history_error_to_string error
      | H.Ref_identity_invalid _ -> "continuity checkpoint identity invalid"
      | H.Ref_session_mismatch _ -> "continuity checkpoint trace mismatch"
      | H.Ref_lock_failed detail -> detail)
  | Ok (H.Read (source, messages, prefix)) ->
    match S.checkpoint_prefix_range ~trace_id ~lines ~messages with
    | Error (S.Uncovered_history | S.Unmatched_history) -> Ok (No_source Source_unreadable)
    | Error
        ((S.Range_stopped _ | S.Trace_mismatch | S.History_changed | S.Prefix_changed
         | S.Invalid_snapshot _ | S.Read_failed _ | S.Write_failed _) as error) ->
      Error (S.error_to_string error)
    | Ok range ->
      let fitting_previous = match previous_snapshot with
        | Some snapshot -> (match S.restore ?prefix ~trace_id ~lines ~messages snapshot with
            | Ok restored -> Some (snapshot, restored.working_state, restored.covered_prefix)
            | Error _ -> None)
        | None -> None in
      let previous_state, previous_unread_messages, start_atom, covered_prefix = match fitting_previous with
        | Some ((snapshot : S.t), working_state, covered_prefix) ->
          Some working_state, snapshot.unread_messages, snapshot.end_atom, Some covered_prefix
        | None -> None, [], 0, None in
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
        let keepers_dir = Workspace.keepers_runtime_dir config in
        match Keeper_librarian_progress.read ~keepers_dir ~keeper_id:keeper_name with
        | Ok (Some progress) when position_fits progress -> progress.position.end_atom
        | Ok (Some _) | Ok None -> range.end_atom
        | Error error ->
          Log.Keeper.warn ~keeper_name
            "continuity catch-up target falls back to this range's end: %s unreadable: %s"
            (Keeper_librarian_progress.path_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name)
            (Keeper_librarian_progress.read_error_to_string error);
          range.end_atom in
      let catch_up_target = match fitting_previous with
        | Some ((snapshot : S.t), _, _) ->
          Option.map (fun _ -> start_without_snapshot ()) snapshot.catch_up_end_atom
        | None -> Some (start_without_snapshot ()) in
      let cuts = R.cut_lines ~trace_id ~lines ~messages range
        |> List.sort (fun (left : R.atom_cut) (right : R.atom_cut) ->
          compare (left.cut_end_atom, left.cut_line) (right.cut_end_atom, right.cut_line)) in
      let* receipt = Keeper_memory_os_current.committed_durable_coverage
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
        let* previous_unread_messages = match recovery_receipt with
          | None -> Ok previous_unread_messages
          | Some receipt ->
            let* () = Keeper_librarian_unread.validate_atom_history
              ~trace_id ~history_start_boundary_line:range.history_start_boundary_line
              ~end_atom:receipt.end_atom ~messages receipt.unread_messages in
            Keeper_librarian_unread.merge previous_unread_messages receipt.unread_messages in
        let unread = R.slice messages {range with R.start_atom; end_atom} in
        Ok (Ready {trace_id;lines;messages;source;covered_prefix;previous=stored;previous_state;previous_unread_messages;recovery_receipt;range;cuts;covering_cut;start_atom;end_atom;unread;
                  catch_up_target})

(* The reason an empty source was empty is dropped here: a caller that only
   asks whether there is work does not distinguish them. *)
let prepare ?end_atom ~config ~keeper_name ~trace_id () =
  prepare_source ?end_atom ~config ~keeper_name ~trace_id ()
  |> Result.map (function Ready prepared -> Some prepared | No_source _ -> None)
let messages prepared = prepared.unread
let select_prefix ~end_atom prepared =
  match prepared.recovery_receipt with
  | Some _ -> Ok prepared
  | None ->
    if end_atom <= prepared.start_atom || end_atom > prepared.end_atom then
      Error "continuity prefix is outside the selected source"
    else if end_atom = prepared.end_atom then Ok prepared
    else
      match List.find_opt (fun (cut : R.atom_cut) -> cut.cut_end_atom >= end_atom) prepared.cuts with
      | None -> Error "continuity source has no covering completed boundary"
      | Some covering_cut ->
        let unread = R.slice prepared.messages
          {prepared.range with R.start_atom=prepared.start_atom;end_atom} in
        Ok {prepared with end_atom;covering_cut;unread}
let memory_sources prepared =
  Keeper_librarian_unread.sources_for_atom_range ~trace_id:prepared.trace_id
    ~history_start_boundary_line:prepared.range.history_start_boundary_line
    ~start_atom:prepared.start_atom ~end_atom:prepared.end_atom ~messages:prepared.messages
let unread_message prepared ~source ~reasons =
  let* sources = memory_sources prepared in
  if not (List.mem source sources) then Error "unread message is outside the selected original source"
  else match source with
    | Keeper_librarian_unread.Atom {trace_id;history_start_boundary_line;atom;message_in_atom;_} ->
      Keeper_librarian_unread.for_atom ~trace_id ~history_start_boundary_line ~atom
        ~message_in_atom ~messages:prepared.messages ~reasons
    | Keeper_librarian_unread.Official_turn _ -> Error "continuity source is not an official fragment"
(* Use all frozen cuts before clipping: a selected unit may end inside its
   covering turn, or an exact receipt may cover several turns. *)
let source_spans ?(include_unread=true) prepared =
  let module H = Keeper_librarian_task_context in
  let module Lines = Map.Make (Int) in
  (* Scopes partition this frozen history in atom order. Label it once and
     pass the remaining suffix on, rather than slicing the full checkpoint
     again for every historical turn and attribution gap. *)
  let labelled, _ = W.annotate prepared.messages in
  let digest_at = W.atom_opening_digest prepared.messages in
  let boundaries = List.fold_left (fun indexed (line, read) ->
    match read with
    | Ok boundary -> Lines.add line boundary indexed
    | Error _ -> indexed) Lines.empty prepared.lines in
  let omitted atom position message =
    List.exists (fun (hole : Keeper_librarian_unread.t) ->
      match hole.source with
      | Keeper_librarian_unread.Atom source ->
        source.trace_id=prepared.trace_id
        && source.history_start_boundary_line=prepared.range.history_start_boundary_line
        && source.atom=atom && source.message_in_atom=position
        && source.message_sha256=Keeper_librarian_unread.message_digest message
      | Keeper_librarian_unread.Official_turn _ -> false) prepared.previous_unread_messages in
  let rec take_span ~start_atom ~end_atom (remaining, last_atom, next_position) retained =
    match remaining with
    | [] -> List.rev retained, ([], last_atom, next_position)
    | (_, W.Pinned) :: rest ->
      take_span ~start_atom ~end_atom (rest, last_atom, next_position) retained
    | (_, W.Atom atom) :: _ when atom >= end_atom ->
      List.rev retained, (remaining, last_atom, next_position)
    | (message, W.Atom atom) :: rest ->
      let position = if last_atom=Some atom then next_position else 0 in
      let retained =
        if atom >= start_atom && (include_unread || not (omitted atom position message))
        then message :: retained else retained in
      take_span ~start_atom ~end_atom (rest, Some atom, position+1) retained in
  (* Keep every validated cut: a selected prefix may stop inside its
     covering turn, and an exact receipt may cover several turns. *)
  let _, _, reversed = List.fold_left (fun (start_atom, cursor, reversed) (cut : R.atom_cut) ->
    let end_atom = min prepared.end_atom cut.cut_end_atom in
    if end_atom <= start_atom then start_atom, cursor, reversed else
    let boundary = Lines.find_opt cut.cut_line boundaries in
    let scopes = H.atom_spans ~trace_id:prepared.trace_id ~digest_at
      ~start_atom ~end_atom ~boundary in
    let cursor, reversed = List.fold_left (fun (cursor, reversed) scope ->
      let messages, cursor = match scope.H.source with
        | H.Atom_span {start_atom;end_atom;_} ->
          take_span ~start_atom ~end_atom cursor []
        | H.Boundary_only | H.Official_turn -> [], cursor in
      cursor, (scope, messages) :: reversed) (cursor, reversed) scopes in
    end_atom, cursor, reversed)
    (prepared.start_atom, (labelled, None, 0), []) prepared.cuts in
  List.rev reversed

type turn_window = { after : float option; through : float }
(* A unit that stops inside its turn carries no window; the unit that
   finishes the turn carries the whole turn's, from the turn-end line at or
   before its start, so each turn's window is read once. Of several lines at
   one atom the latest is taken, as [Keeper_turn_boundaries.witness_line]
   takes it for the durable pass's bounds, so the two passes' windows meet. *)
let turn_window prepared =
  let cut = prepared.covering_cut in
  if prepared.end_atom <> cut.cut_end_atom then None
  else
    let cuts = prepared.cuts in
    let latest_at_or_before bound = List.fold_left (fun found (line : R.atom_cut) ->
      if line.cut_end_atom > bound then found
      else match found with
        | Some (kept : R.atom_cut) when kept.cut_end_atom > line.cut_end_atom -> found
        | Some _ | None -> Some line) None cuts in
    let recorded_at (line : R.atom_cut) = line.cut_recorded_at in
    Some { after = Option.map recorded_at (latest_at_or_before prepared.start_atom);
           through = Option.fold ~none:cut.cut_recorded_at ~some:recorded_at
               (latest_at_or_before cut.cut_end_atom) }
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
      unread_messages = [];
      start_atom = prepared.start_atom; end_atom = prepared.end_atom; last_atom_digest;
      end_boundary_line = cut.cut_line;
      boundary_lines_seen = List.fold_left (fun count (_, read) ->
        match read with
          | Error B.Incomplete_line -> count
          | Ok _ | Error (B.Not_json _ | B.Malformed _) -> count + 1) 0 prepared.lines }
  | None -> Error "continuity source has no covering completed boundary"
let memory_committed ~config ~keeper_name prepared =
  let* expected = memory_range_id ~config ~keeper_name prepared in
  let* actual = Keeper_memory_os_current.committed_durable_coverage
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
           prepared.cuts
    | None, _ | Some _, None -> false)
let previous_working_state prepared = prepared.previous_state
let previous_unread_messages prepared = prepared.previous_unread_messages
let prompt_json prepared =
  `Assoc ["previous_working_state", (match prepared.previous_state with None -> `Null | Some text -> `String text);
    "unread_messages", Keeper_librarian_unread.list_to_json prepared.previous_unread_messages]
(* The prefix a unit read, in the given messages: every pinned message and
   the atoms before its covering cut. *)
let read_prefix ~prepared messages =
  W.annotate messages |> fst |> List.filter_map (fun (message,label) ->
    match label with
    | W.Pinned -> Some message
    | W.Atom atom -> if atom < prepared.covering_cut.cut_end_atom then Some message else None)
let capture_snapshot ~prepared ~unread_messages ~working_state =
  (* Capture against this work unit's actual completed turn, not a later
     backlog boundary. Keep the full frozen checkpoint in [prepared] for
     Memory coverage checks; only this capture view ends at the chosen cut.
     The view holds the same message values, so the covered prefix digest
     extends over them. *)
  let messages = read_prefix ~prepared prepared.messages in
  S.capture_checkpoint_prefix ?prefix:prepared.covered_prefix ~unread_messages ~end_atom:prepared.end_atom
    ~catch_up_end_atom:prepared.catch_up_target
    ~trace_id:prepared.trace_id ~lines:prepared.lines ~messages
    ~working_state () |> Result.map_error S.error_to_string
let unchanged_snapshot ~config ~keeper_name ~prepared =
  let* current = load ~config ~keeper_name in
  if current = prepared.previous then Ok ()
  else Error "continuity snapshot changed during generation"
let save_snapshot ~config ~keeper_name snapshot =
  S.save ~path:(path ~config ~keeper_name) snapshot |> Result.map_error S.error_to_string
let with_original_source ~config ~keeper_name ~prepared publish =
  let session_dir = Filename.concat (Keeper_fs.session_store_path config) prepared.trace_id in
  let locked = C.with_agent_core_exact_snapshot_since ~session_dir ~known:prepared.source
    (fun since ->
      let current_messages = match since with
        | C.Unchanged_source -> prepared.messages
        | C.Changed_source current -> C.exact_snapshot_messages current in
      (* Completed boundary rows only append during the serial lane. Purge
         first cancels/awaits that lane. A suffix append cannot change this
         prefix; reread the real log rather than reconstructing its witnesses. *)
      let* lines = B.read ~keepers_dir:(Workspace.keepers_runtime_dir config) ~keeper_id:keeper_name in
      let prefix lines = List.filter (fun (line,_) -> line <= prepared.covering_cut.cut_line) lines in
      let* () = if prefix lines = prefix prepared.lines then Ok ()
        else Error "continuity boundary prefix changed during message inference" in
      let* range_now = S.checkpoint_prefix_range ~trace_id:prepared.trace_id ~lines ~messages:current_messages
        |> Result.map_error S.error_to_string in
      (* Unchanged bytes decode to the messages the unit read. Changed bytes
         are compared one message at a time with the whole-prefix check's
         equality: a pair passes when its checkpoint JSON trees are equal.
         Values equal under [=] give trees equal under [=], so the first test
         only spares building the trees and accepts nothing the tree compare
         refuses. Neither test is byte equality: [0.0] and [-0.0] pass both,
         though they encode one byte apart. *)
      let read_prefix_unchanged = match since with
        | C.Unchanged_source -> true
        | C.Changed_source _ ->
          List.equal (fun current original -> current = original
            || Agent_core.Checkpoint.message_to_json current
               = Agent_core.Checkpoint.message_to_json original)
            (read_prefix ~prepared current_messages) (read_prefix ~prepared prepared.messages) in
      let* () =
        if range_now.history_start_boundary_line=prepared.range.history_start_boundary_line
           && range_now.end_atom >= prepared.end_atom
           && read_prefix_unchanged then Ok ()
        else Error "continuity checkpoint prefix changed during message inference" in
      publish ()) in
  match locked with
  | Ok result -> result
  | Error C.Ref_not_found -> Error "continuity checkpoint disappeared before publication"
  | Error (C.Ref_read_failed error) -> Error (C.checkpoint_load_error_to_string error)
  | Error (C.Ref_identity_invalid _) -> Error "continuity checkpoint identity invalid at publication"
  | Error (C.Ref_session_mismatch _) -> Error "continuity checkpoint trace changed at publication"
  | Error (C.Ref_lock_failed detail) -> Error detail

let commit ~config ~keeper_name ~prepared ~new_unread_messages ~working_state =
  let* covered = memory_committed ~config ~keeper_name prepared in
  let* () = if covered then Ok () else Error "Memory has not committed this continuity source" in
  let* () = List.fold_left (fun result (hole : Keeper_librarian_unread.t) ->
    let* () = result in
    let* original = unread_message prepared ~source:hole.source ~reasons:hole.reasons in
    if original=hole then Ok () else Error "continuity unread record differs from its original message")
    (Ok ()) new_unread_messages in
  let* unread_messages = Keeper_librarian_unread.merge
    prepared.previous_unread_messages new_unread_messages in
  let* snapshot = capture_snapshot ~prepared ~unread_messages ~working_state in
  let file = path ~config ~keeper_name in
  Fs_compat.mkdir_p (Filename.dirname file);
  with_original_source ~config ~keeper_name ~prepared (fun () ->
    File_lock_eio.with_lock file (fun () ->
      let* () = unchanged_snapshot ~config ~keeper_name ~prepared in
      let* () = save_snapshot ~config ~keeper_name snapshot in Ok snapshot))

let apply_memory_program ?on_memory_committed ~config ~keeper_name ~prepared ~anchor
    ~(program : Keeper_memory_os_program.t) ~working_state () =
  let module Current = Keeper_memory_os_current in
  let* range = memory_range_id ~config ~keeper_name prepared in
  let range = {range with Current.unread_messages=program.unread} in
  let* unread_messages = Keeper_librarian_unread.merge
    prepared.previous_unread_messages program.unread in
  let* snapshot = capture_snapshot ~prepared ~unread_messages ~working_state in
  let source = Current.Atom_program_source {range;checkpoint=prepared.messages} in
  let file = path ~config ~keeper_name in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path in
  Fs_compat.mkdir_p (Filename.dirname file);
  with_original_source ~config ~keeper_name ~prepared (fun () ->
    File_lock_eio.with_lock file (fun () ->
      let* () = unchanged_snapshot ~config ~keeper_name ~prepared in
      let* _ = Current.apply_program ~keepers_dir ~keeper_id:keeper_name ~now:(Time_compat.now ())
        ~anchor ~source ~validate_source:(fun () -> Ok ())
        ?on_committed:(Option.map (fun observe (_ : Current.program_commit) -> observe ()) on_memory_committed)
        program in
      (* The original complete range proof is now recoverable. Archive its
         holes before exposing a continuation that omits those messages. *)
      let* _ = Current.committed_unread_messages ~keepers_dir ~keeper_id:keeper_name in
      let* () = save_snapshot ~config ~keeper_name snapshot in
      Ok snapshot))
