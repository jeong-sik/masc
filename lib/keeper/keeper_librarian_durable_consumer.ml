module B = Keeper_turn_boundaries
module P = Keeper_librarian_progress
module R = Keeper_librarian_range
module Window = Runtime_model_input_tail_window
module Canonical_tool = Agent_core.Canonical_tool
module String_map = Map.Make (String)

module O = Keeper_librarian_official_progress

type outcome =
  | Nothing_to_read
  | Baseline_advanced of P.t
  | Memory_not_committed
  | Progress_advanced of P.t
  | Official_advanced of
      { atom : P.t option
      ; official : O.t
      }

type error =
  | Keeper_meta_absent
  | Keeper_meta_unreadable of string
  | Boundary_log_unreadable of string
  | Progress_unreadable of P.read_error
  | Checkpoint_unreadable of Keeper_checkpoint_store.checkpoint_load_error
  | Position_in_other_trace of P.position
  | Range_stopped of R.stop
  | Range_end_boundary_missing of R.range
  | Progress_boundary_missing of P.position
  | Memory_snapshot_unreadable of string
  | Counterpart_interval_non_monotone of
      { after : float
      ; before : float
      }
  | Counterpart_observations_unreadable of Keeper_librarian_input_sources.read_error
  | Progress_write_failed of P.write_error
  | Official_progress_unreadable of O.read_error
  | Official_progress_write_failed of O.write_error
  | Official_progress_boundary_missing of O.t
  | Committed_official_range_mismatch
  | Official_range_stopped of
      { line : int
      ; error : B.read_error
      }
  | Fragment_store_unreadable of
      { trace_id : string
      ; file : Keeper_turn_fragments.file
      ; detail : string
      }
  | Fragment_line_unreadable of
      { trace_id : string
      ; file : Keeper_turn_fragments.file
      ; line : int
      ; error : Keeper_turn_fragments.read_error
      }

let fragment_file_to_string = function
  | Keeper_turn_fragments.Main -> Keeper_types_support.history_file_name
  | Keeper_turn_fragments.Internal -> Keeper_types_support.internal_history_file_name
;;

let range_stop_to_string = function
  | R.Unreadable_line { line; error } ->
    Printf.sprintf
      "turn-boundary line %d is unreadable: %s"
      line
      (B.read_error_to_string error)
  | R.Position_mismatch { position; atom_count } ->
    Printf.sprintf
      "librarian position trace=%s end_atom=%d does not match checkpoint atoms=%d"
      position.P.trace_id
      position.end_atom
      atom_count
;;

let error_to_string = function
  | Keeper_meta_absent -> "keeper metadata is absent"
  | Keeper_meta_unreadable detail -> "keeper metadata is unreadable: " ^ detail
  | Boundary_log_unreadable detail -> "turn-boundary log is unreadable: " ^ detail
  | Progress_unreadable error -> P.read_error_to_string error
  | Checkpoint_unreadable error ->
    "checkpoint is unreadable: "
    ^ Keeper_checkpoint_store.checkpoint_load_error_to_string error
  | Position_in_other_trace position ->
    Printf.sprintf
      "librarian position belongs to trace=%s end_atom=%d"
      position.P.trace_id
      position.end_atom
  | Range_stopped stop -> range_stop_to_string stop
  | Range_end_boundary_missing range ->
    Printf.sprintf
      "selected range end has no matching boundary end_atom=%d digest=%s"
      range.R.end_atom
      range.last_atom_digest
  | Progress_boundary_missing position ->
    Printf.sprintf
      "read position has no matching turn boundary trace=%s end_atom=%d digest=%s"
      position.P.trace_id
      position.end_atom
      position.last_atom_digest
  | Memory_snapshot_unreadable detail ->
    "current Memory OS snapshot is unreadable: " ^ detail
  | Counterpart_interval_non_monotone { after; before } ->
    Printf.sprintf
      "counterpart interval is not monotone: after=%.06f before=%.06f"
      after
      before
  | Counterpart_observations_unreadable error ->
    Keeper_librarian_input_sources.read_error_to_string error
  | Progress_write_failed error -> P.write_error_to_string error
  | Official_progress_unreadable error -> O.read_error_to_string error
  | Official_progress_write_failed error -> O.write_error_to_string error
  | Committed_official_range_mismatch ->
    "committed official Librarian range no longer matches the turn-boundary log"
  | Official_progress_boundary_missing cursor ->
    Printf.sprintf
      "official read position names no official turn-boundary line line=%d"
      cursor.O.boundary_line
  | Official_range_stopped { line; error } ->
    Printf.sprintf
      "turn-boundary line %d beyond the official read position is unreadable: %s"
      line
      (B.read_error_to_string error)
  | Fragment_store_unreadable { trace_id; file; detail } ->
    Printf.sprintf
      "history store of trace=%s file=%s is unreadable: %s"
      trace_id
      (fragment_file_to_string file)
      detail
  | Fragment_line_unreadable { trace_id; file; line; error } ->
    Printf.sprintf
      "history line %d of trace=%s file=%s is unreadable: %s"
      line
      trace_id
      (fragment_file_to_string file)
      (Keeper_turn_fragments.read_error_to_string error)
;;

let turn_boundary_for_position ?through ~trace_id ~end_atom ~last_atom_digest lines =
  let latest =
    List.fold_left
      (fun latest (line, decoded) ->
       let admitted =
         match through with
         | None -> true
         | Some last_seen -> line <= last_seen
       in
       if not admitted
       then latest
       else
       match decoded with
       | Error _ -> latest
       | Ok ({ B.event = B.History_restarted _; _ } : B.record) -> latest
       | Ok
           ({ recorded_at
            ; event =
                B.Turn_ended
                  { turn_ref
                  ; history_at_start = _
                  ; position = B.Atom_history boundary
                  }
            } : B.record) ->
         if
           String.equal (Ids.Turn_ref.trace_id turn_ref) trace_id
           && boundary.end_atom = end_atom
           && String.equal boundary.last_atom_digest last_atom_digest
         then Some (line, recorded_at, turn_ref)
         else latest
       | Ok
           { B.event =
               B.Turn_ended
                 { turn_ref = _
                 ; history_at_start = _
                 ; position = B.Empty_atom_history | B.No_atom_history | B.Stale_noop
                 }
           ; _
           } -> latest)
      None
      lines
  in
  match latest with
  | None -> None
  | Some (line, recorded_at, turn_ref) -> Some (line, recorded_at, turn_ref)
;;

let has_history_start_witness ~trace_id lines =
  List.exists
    (fun (_, decoded) ->
       match decoded with
       | Ok { B.event = B.History_restarted { trace_id = restarted }; _ } ->
         String.equal restarted trace_id
       | Ok
           { B.event =
               B.Turn_ended
                 { turn_ref
                 ; history_at_start = B.Fresh_history
                 ; position = _
                 }
           ; _
           } ->
         String.equal (Ids.Turn_ref.trace_id turn_ref) trace_id
       | Ok _ | Error _ -> false)
    lines
;;

let range_id_for_selection
      ~receipt_scope
      ~trace_id
      ~(range : R.range)
      ~end_boundary_line
      ~boundary_lines_seen
  : Keeper_memory_os_current.durable_range_id
  =
  { receipt_scope
  ; trace_id
  ; history_start_boundary_line = range.history_start_boundary_line
  ; start_atom = range.start_atom
  ; end_atom = range.end_atom
  ; last_atom_digest = range.last_atom_digest
  ; end_boundary_line
  ; boundary_lines_seen
  }
;;

let progress_of_range_id (range_id : Keeper_memory_os_current.durable_range_id) : P.t =
  { position =
      { trace_id = range_id.trace_id
      ; end_atom = range_id.end_atom
      ; last_atom_digest = range_id.last_atom_digest
      }
  ; boundary_lines_seen = range_id.boundary_lines_seen
  }
;;

let endpoint_is_present
      (range_id : Keeper_memory_os_current.durable_range_id)
      ~messages
      lines
  =
  let checkpoint_matches =
    match Window.atom_opening_digest messages (range_id.end_atom - 1) with
    | Some digest -> String.equal digest range_id.last_atom_digest
    | None -> false
  in
  checkpoint_matches
  && List.exists
       (fun (line, decoded) ->
          Int.equal line range_id.end_boundary_line
          &&
          match decoded with
          | Ok
              ({ B.event =
                   B.Turn_ended
                     { turn_ref
                     ; history_at_start = _
                     ; position = B.Atom_history boundary
                     }
               ; _
               } : B.record) ->
            String.equal (Ids.Turn_ref.trace_id turn_ref) range_id.trace_id
            && Int.equal boundary.end_atom range_id.end_atom
            && String.equal boundary.last_atom_digest range_id.last_atom_digest
          | Ok _ | Error _ -> false)
       lines
;;

let is_committed_prefix
      committed
      ~trace_id
      ~(selected : R.range)
      ~selected_end_boundary_line
      ~selected_boundary_lines_seen
      ~messages
      lines
  =
  String.equal committed.Keeper_memory_os_current.trace_id trace_id
  && Int.equal
       committed.history_start_boundary_line
       selected.history_start_boundary_line
  && Int.equal committed.start_atom selected.start_atom
  && committed.end_atom <= selected.end_atom
  && committed.end_boundary_line <= selected_end_boundary_line
  && committed.boundary_lines_seen <= selected_boundary_lines_seen
  && endpoint_is_present committed ~messages lines
;;

let tool_observations messages =
  let calls_rev, results =
    List.fold_left
      (fun (calls_rev, results) (message : Agent_core.Types.message) ->
         List.fold_left
           (fun (calls_rev, results) block ->
              match Canonical_tool.tool_call_of_block block with
              | Some call -> (call :: calls_rev), results
              | None ->
                (match Canonical_tool.tool_result_of_block block with
                 | None -> calls_rev, results
                 | Some result ->
                   calls_rev, String_map.add result.call_id result.outcome results))
           (calls_rev, results)
           message.content)
      ([], String_map.empty)
      messages
  in
  List.rev_map
    (fun (call : Canonical_tool.provider_tool_call) ->
       let outcome =
         match String_map.find_opt call.call_id results with
         | None -> Keeper_librarian.Unknown
         | Some result ->
           if Agent_core.Types.tool_result_outcome_is_error result
           then Keeper_librarian.Failed
           else Keeper_librarian.Succeeded
       in
       ({ tool_name =
            Keeper_tool_descriptor_resolution.canonical_tool_name call.name
        ; outcome
        }
         : Keeper_librarian.tool_observation))
    calls_rev
;;

let current_memory ~keepers_dir ~keeper_name =
  match
    Domain_pool_ref.submit_io_or_inline (fun () ->
      Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id:keeper_name)
  with
  | Error detail -> Error (Memory_snapshot_unreadable detail)
  | Ok current ->
    let input, expected_revision =
      match current with
      | None -> None, None
      | Some snapshot ->
        Some { Keeper_librarian.facts = snapshot.facts }, Some snapshot.revision
    in
    Ok (input, expected_revision)
;;

let write_progress ~write ~keepers_dir ~keeper_name progress outcome =
  match
    Domain_pool_ref.submit_io_or_inline (fun () ->
      write ~keepers_dir ~keeper_id:keeper_name progress)
  with
  | Ok () -> Ok (outcome progress)
  | Error error -> Error (Progress_write_failed error)
;;

let failed_ranges : (string, unit) Hashtbl.t = Hashtbl.create 16
let failed_ranges_mu = Stdlib.Mutex.create ()

let range_key ~runtime_keepers_dir ~keeper_name =
  Filename.concat runtime_keepers_dir keeper_name
;;

let failed_before key =
  Stdlib.Mutex.protect failed_ranges_mu (fun () -> Hashtbl.mem failed_ranges key)
;;

let mark_failed key =
  Stdlib.Mutex.protect failed_ranges_mu (fun () -> Hashtbl.replace failed_ranges key ())
;;

let clear_failed key =
  Stdlib.Mutex.protect failed_ranges_mu (fun () -> Hashtbl.remove failed_ranges key)
;;

(* One step of a round's reading, placed by its line in the turn-boundary
   log. Atom cut points and official-client end lines are two kinds of line
   of one log, so their order is the log's order. *)
type step =
  | Atoms of
      { line : int
      ; end_atom : int
      ; recorded_at : float
      ; turn_ref : Ids.Turn_ref.t
      }
  | Official of R.official_line

let step_line = function
  | Atoms { line; _ } -> line
  | Official { R.line; _ } -> line
;;

let step_end = function
  | Atoms { recorded_at; turn_ref; _ } -> recorded_at, turn_ref
  | Official { R.recorded_at; turn_ref; _ } -> recorded_at, turn_ref
;;

(* The history files of every trace the official lines name, read once each.
   A refused line past the first named one stops the round (row 2c). *)
let read_fragments ~config (official : R.official_line list) =
  let ( let* ) = Result.bind in
  let session_dir trace_id = Filename.concat (Keeper_fs.session_store_path config) trace_id in
  let read_file ~trace_id file =
    let* lines =
      Domain_pool_ref.submit_io_or_inline (fun () ->
        Keeper_turn_fragments.read ~session_dir:(session_dir trace_id) file)
      |> Result.map_error (fun detail -> Fragment_store_unreadable { trace_id; file; detail })
    in
    match Keeper_turn_fragments.first_refused lines with
    | Some (line, error) -> Error (Fragment_line_unreadable { trace_id; file; line; error })
    | None -> Ok lines
  in
  List.fold_left
    (fun acc ({ R.turn_ref; _ } : R.official_line) ->
       let* by_trace = acc in
       let trace_id = Ids.Turn_ref.trace_id turn_ref in
       if String_map.mem trace_id by_trace
       then Ok by_trace
       else
         let* main = read_file ~trace_id Keeper_turn_fragments.Main in
         let* internal = read_file ~trace_id Keeper_turn_fragments.Internal in
         Ok (String_map.add trace_id (main @ internal) by_trace))
    (Ok String_map.empty)
    official
;;

let official_cursor_recorded_at ~lines (cursor : Keeper_librarian_official_progress.t) =
  match
    List.find_map
      (fun (line, decoded) ->
         if not (Int.equal line cursor.boundary_line)
         then None
         else
           match decoded with
           | Ok
               ({ recorded_at
                ; event = B.Turn_ended { position = B.No_atom_history; _ }
                } : B.record) -> Some recorded_at
           | Ok _ | Error _ -> None)
      lines
  with
  | Some recorded_at -> Ok recorded_at
  | None -> Error (Official_progress_boundary_missing cursor)
;;

(* The Memory WAL, not a successful return from the model, proves which
   official turns were saved. Repair this cursor before retry narrowing or
   checkpoint selection; a mixed pass can have saved only its atom cursor. *)
let recover_official_progress
      ~write ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name ~lines ~cursor
  =
  let ( let* ) = Result.bind in
  if not (R.may_have_unread_official ~lines ~cursor)
  then Ok None
  else
  let* receipt =
    Keeper_memory_os_current.committed_official_range
      ~keepers_dir:memory_keepers_dir ~keeper_id:keeper_name
      ~receipt_scope:runtime_keepers_dir
    |> Result.map_error (fun detail -> Memory_snapshot_unreadable detail)
  in
  match receipt with
  | None -> Ok None
  | Some receipt ->
    let current = match cursor with None -> 0 | Some cursor -> cursor.O.boundary_line in
    match List.rev receipt.Keeper_memory_os_current.turns with
    | [] -> Error Committed_official_range_mismatch
    | (end_line, _) :: _ when current >= end_line -> Ok None
    | (end_line, _) :: _ ->
      let start = receipt.Keeper_memory_os_current.after_boundary_line in
      let selected =
        R.select_official ~lines:(List.filter (fun (line, _) -> line <= end_line) lines)
          ~cursor:(if start = 0 then None else Some { O.boundary_line = start })
          R.All_unread
      in
      let matches =
        match selected with
        | R.Official_read selected ->
          let selected = List.filter (fun (turn : R.official_line) -> turn.line <= end_line) selected in
          List.equal
            (fun (line, turn_ref) (other_line, other_ref) ->
               Int.equal line other_line && Ids.Turn_ref.equal turn_ref other_ref)
            receipt.turns
            (List.map (fun (turn : R.official_line) -> turn.line, turn.turn_ref) selected)
        | R.Nothing_official | R.Official_stop _ -> false
      in
      if current < start || not matches
      then Error Committed_official_range_mismatch
      else
        let official = { O.boundary_line = end_line } in
        match Domain_pool_ref.submit_io_or_inline (fun () ->
          write ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name official)
        with
        | Error error -> Error (Official_progress_write_failed error)
        | Ok () -> Ok (Some (Official_advanced { atom = None; official }))
;;

let consume_one_with_extent
      ~write_progress_store
      ~write_official_progress_store
      ~extent
      ~config
      ~keeper_name
      ~commit
  =
  let ( let* ) = Result.bind in
  let runtime_keepers_dir = Workspace.keepers_runtime_dir config in
  let memory_keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path
  in
  let* lines =
    Domain_pool_ref.submit_io_or_inline (fun () ->
      Keeper_turn_boundaries.read
        ~keepers_dir:runtime_keepers_dir
        ~keeper_id:keeper_name)
    |> Result.map_error (fun detail -> Boundary_log_unreadable detail)
  in
  let* progress =
    Domain_pool_ref.submit_io_or_inline (fun () ->
      P.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name)
    |> Result.map_error (fun error -> Progress_unreadable error)
  in
  let* official_cursor =
    Domain_pool_ref.submit_io_or_inline (fun () ->
      Keeper_librarian_official_progress.read
        ~keepers_dir:runtime_keepers_dir
        ~keeper_id:keeper_name)
    |> Result.map_error (fun error -> Official_progress_unreadable error)
  in
  let* recovered =
    recover_official_progress ~write:write_official_progress_store
      ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name ~lines ~cursor:official_cursor
  in
  match recovered with
  | Some outcome -> Ok outcome
  | None ->
  let* meta =
    match
      Domain_pool_ref.submit_io_or_inline (fun () ->
        Keeper_meta_store.read_effective_meta_presence config keeper_name)
    with
    | Ok (Keeper_meta_store.Meta_present meta) -> Ok meta
    | Ok Keeper_meta_store.Meta_absent -> Error Keeper_meta_absent
    | Ok (Keeper_meta_store.Meta_not_current detail) ->
      Error (Keeper_meta_unreadable detail)
    | Error detail -> Error (Keeper_meta_unreadable detail)
  in
  let current_trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let progress_is_current =
    match progress with
    | None -> true
    | Some { P.position; _ } -> String.equal position.trace_id current_trace_id
  in
  if
    progress_is_current
    && (not (R.may_have_unread ~trace_id:current_trace_id ~lines ~progress))
    && not (R.may_have_unread_official ~lines ~cursor:official_cursor)
  then Ok Nothing_to_read
  else
  let load_checkpoint trace_id =
    let session_dir = Filename.concat (Keeper_fs.session_store_path config) trace_id in
    Domain_pool_ref.submit_io_or_inline (fun () ->
      Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:trace_id)
  in
  (* A keeper that has only ever run on official-client runtimes has no
     checkpoint and no atom position: its atoms are nothing to read, and its
     official lines are read below. A missing checkpoint with a position is
     still an error when unread atom work requires that checkpoint. *)
  let current_selection ?progress () =
    if not (R.may_have_unread ~trace_id:current_trace_id ~lines ~progress)
    then Ok (current_trace_id, progress, [], R.Nothing_to_read)
    else match load_checkpoint current_trace_id, progress with
    | Error Keeper_checkpoint_store.Not_found, None ->
      Ok (current_trace_id, None, [], R.Nothing_to_read)
    | Error error, _ -> Error (Checkpoint_unreadable error)
    | Ok checkpoint, progress ->
      let messages = checkpoint.Agent_core.Checkpoint.messages in
      Ok
        ( current_trace_id
        , progress
        , messages
        , R.select ~trace_id:current_trace_id ~lines ~progress ~messages extent )
  in
  let current_selection_after_prior position =
    if has_history_start_witness ~trace_id:current_trace_id lines
    then current_selection ()
    else Error (Position_in_other_trace position)
  in
  let* trace_id, selection_progress, messages, selection =
    match progress with
    | Some ({ P.position; _ } as previous)
      when not (String.equal position.trace_id current_trace_id) ->
      (match load_checkpoint position.trace_id with
       | Ok checkpoint ->
         let messages = checkpoint.Agent_core.Checkpoint.messages in
         let selection =
           R.select
             ~trace_id:position.trace_id
             ~lines
             ~progress:(Some previous)
             ~messages
             extent
         in
         (match selection with
          | R.Nothing_to_read -> current_selection_after_prior position
          | R.Read _
          | R.Baseline _
          | R.Position_in_other_trace _
          | R.Stop _ ->
            Ok (position.trace_id, Some previous, messages, selection))
       | Error Keeper_checkpoint_store.Not_found ->
         (* A removed owner/session cannot finish its old trace. The current
            trace's own fresh/restart boundary is the typed authority to read
            from atom zero; without one the old position remains authoritative. *)
         current_selection_after_prior position
       | Error error -> Error (Checkpoint_unreadable error))
    | None -> current_selection ()
    | Some current -> current_selection ~progress:current ()
  in
  let official = R.select_official ~lines ~cursor:official_cursor extent in
  let write_atom next outcome =
    write_progress
      ~write:write_progress_store
      ~keepers_dir:runtime_keepers_dir
      ~keeper_name
      next
      outcome
  in
  match selection, official with
  | R.Stop stop, _ -> Error (Range_stopped stop)
  | _, R.Official_stop { line; error } -> Error (Official_range_stopped { line; error })
  | R.Position_in_other_trace position, _ -> Error (Position_in_other_trace position)
  | R.Baseline _, _ ->
    (* The atom position is set first; the official lines wait for the next
       call, which the caller makes while a call advances. *)
    (match R.progress_after ~trace_id selection with
     | None -> Ok Nothing_to_read
     | Some next -> write_atom next (fun progress -> Baseline_advanced progress))
  | R.Nothing_to_read, R.Nothing_official -> Ok Nothing_to_read
  | (R.Nothing_to_read | R.Read _), (R.Nothing_official | R.Official_read _) ->
    (* The atom part, when there is one: its range, the line that ends it,
       and the receipt identity the Memory commit records. *)
    let* atom =
      match selection with
      | R.Read { range; boundary_lines_seen } ->
        let* end_boundary_line, ended_at, turn_ref =
          match
            turn_boundary_for_position
              ~trace_id
              ~end_atom:range.end_atom
              ~last_atom_digest:range.last_atom_digest
              lines
          with
          | Some boundary -> Ok boundary
          | None -> Error (Range_end_boundary_missing range)
        in
        Ok (Some (range, boundary_lines_seen, end_boundary_line, ended_at, turn_ref))
      | R.Nothing_to_read | R.Baseline _ | R.Position_in_other_trace _ | R.Stop _ -> Ok None
    in
    let official_lines =
      match official with
      | R.Official_read official_lines -> official_lines
      | R.Nothing_official | R.Official_stop _ -> []
    in
    (* A narrowed round reads the oldest turn only, whichever kind it is. *)
    let atom, official_lines =
      match extent, atom, official_lines with
      | R.To_first_cut_point, Some (_, _, end_boundary_line, _, _), first :: _ ->
        if first.R.line < end_boundary_line then None, [ first ] else atom, []
      | R.To_first_cut_point, _, _ | R.All_unread, _, _ -> atom, official_lines
    in
    let* committed_prefix_advance =
      match atom with
      | None -> Ok None
      | Some (range, boundary_lines_seen, end_boundary_line, _, _) ->
        let* committed_range =
          Keeper_memory_os_current.committed_durable_range
            ~keepers_dir:memory_keepers_dir
            ~keeper_id:keeper_name
            ~receipt_scope:runtime_keepers_dir
          |> Result.map_error (fun detail -> Memory_snapshot_unreadable detail)
        in
        let recovery_range, recovery_boundary_line, recovery_boundary_lines_seen =
          match
            R.select ~trace_id ~lines ~progress:selection_progress ~messages R.All_unread
          with
          | R.Read { range; boundary_lines_seen } ->
            (match
               turn_boundary_for_position
                 ~trace_id
                 ~end_atom:range.end_atom
                 ~last_atom_digest:range.last_atom_digest
                 lines
             with
             | Some (line, _, _) -> range, line, boundary_lines_seen
             | None -> range, end_boundary_line, boundary_lines_seen)
          | R.Nothing_to_read
          | R.Baseline _
          | R.Position_in_other_trace _
          | R.Stop _ -> range, end_boundary_line, boundary_lines_seen
        in
        (match committed_range with
         | Some committed
           when is_committed_prefix
                  committed
                  ~trace_id
                  ~selected:recovery_range
                  ~selected_end_boundary_line:recovery_boundary_line
                  ~selected_boundary_lines_seen:recovery_boundary_lines_seen
                  ~messages
                  lines -> Ok (Some (progress_of_range_id committed))
         | Some _ | None -> Ok None)
    in
    (match committed_prefix_advance with
     | Some next ->
       (* The Memory commit of this prefix landed and only its progress
          write did not. Recover the position without a model call; the
          official lines wait for the next call. *)
       write_atom next (fun progress -> Progress_advanced progress)
     | None ->
    let* after_atom =
      match selection_progress with
      | None -> Ok None
      | Some { P.position; boundary_lines_seen } ->
        (match
           turn_boundary_for_position
             ~through:boundary_lines_seen
             ~trace_id:position.trace_id
             ~end_atom:position.end_atom
             ~last_atom_digest:position.last_atom_digest
             lines
         with
         | Some (line, recorded_at, _) -> Ok (Some (line, recorded_at))
         | None -> Error (Progress_boundary_missing position))
    in
    let* after_official =
      match official_cursor with
      | None -> Ok None
      | Some cursor ->
        Result.map
          (fun recorded_at -> Some (cursor.Keeper_librarian_official_progress.boundary_line, recorded_at))
          (official_cursor_recorded_at ~lines cursor)
    in
    let* fragments = read_fragments ~config official_lines in
    (* The range's end is a cut point by construction; the fallback keeps the
       whole range as one step should the recomputation disagree, so a
       selected atom is never left out of what the model reads. *)
    let atom_steps =
      match atom with
      | None -> []
      | Some (range, _, end_boundary_line, ended_at, turn_ref) ->
        (match R.cut_lines ~trace_id ~lines ~messages range with
         | [] ->
           [ Atoms
               { line = end_boundary_line
               ; end_atom = range.R.end_atom
               ; recorded_at = ended_at
               ; turn_ref
               }
           ]
         | cuts ->
           List.map
             (fun { R.cut_line; cut_end_atom; cut_recorded_at; cut_turn_ref } ->
                Atoms
                  { line = cut_line
                  ; end_atom = cut_end_atom
                  ; recorded_at = cut_recorded_at
                  ; turn_ref = cut_turn_ref
                  })
             cuts)
    in
    let steps =
      List.sort
        (fun a b -> Int.compare (step_line a) (step_line b))
        (atom_steps @ List.map (fun official_line -> Official official_line) official_lines)
    in
    let start_atom =
      match atom with
      | Some (range, _, _, _, _) -> range.R.start_atom
      | None -> 0
    in
    let _, selected_messages_rev, observations_rev =
      List.fold_left
        (fun (prev_end, messages_rev, observations_rev) step ->
           match step with
           | Atoms { end_atom; _ } ->
             (match atom with
              | None -> prev_end, messages_rev, observations_rev
              | Some (range, _, _, _, _) ->
                let slice =
                  R.slice messages { range with R.start_atom = prev_end; end_atom }
                in
                ( end_atom
                , List.rev_append slice messages_rev
                , List.rev_append (tool_observations slice) observations_rev ))
           | Official { R.turn_ref; _ } ->
             let official_trace = Ids.Turn_ref.trace_id turn_ref in
             let of_trace =
               match String_map.find_opt official_trace fragments with
               | Some lines -> lines
               | None -> []
             in
             List.fold_left
               (fun (prev_end, messages_rev, observations_rev) fragment ->
                  match fragment with
                  | Keeper_turn_fragments.Message { message; _ } ->
                    prev_end, message :: messages_rev, observations_rev
                  | Keeper_turn_fragments.Tool_observation { observation; _ } ->
                    prev_end, messages_rev, observation :: observations_rev)
               (prev_end, messages_rev, observations_rev)
               (Keeper_turn_fragments.of_turn turn_ref of_trace))
        (start_atom, [], [])
        steps
    in
    let selected_messages = List.rev selected_messages_rev in
    let observations = List.rev observations_rev in
    let first_step, last_step =
      match steps, List.rev steps with
      | first :: _, last :: _ -> first, last
      | [], _ | _, [] ->
        (* Arm 6 is entered with a read atom range or a non-empty official
           list, and the narrowing keeps one of them. *)
        invalid_arg "librarian pass: a selection with nothing to read"
    in
    let ended_at, turn_ref = step_end last_step in
    (* The counterpart lower bound is the latest of the two positions that
       precede the first turn this pass reads. A position beyond it -- the
       atom baseline set while an older official line waited -- covers no
       counterpart the older turn should see, and must not turn the interval
       backwards. *)
    let after =
      List.filter_map
        (fun cursor ->
           match cursor with
           | Some (line, recorded_at) when line < step_line first_step -> Some recorded_at
           | Some _ | None -> None)
        [ after_atom; after_official ]
      |> List.fold_left (fun after recorded_at ->
        match after with
        | None -> Some recorded_at
        | Some earlier -> Some (Float.max earlier recorded_at)) None
    in
    let official_next =
      match List.rev official_lines with
      | last :: _ -> Some { Keeper_librarian_official_progress.boundary_line = last.R.line }
      | [] -> None
    in
    let atom_next =
      match atom with
      | None -> None
      | Some (range, boundary_lines_seen, end_boundary_line, _, _) ->
        Some
          (range_id_for_selection
             ~receipt_scope:runtime_keepers_dir
             ~trace_id
             ~range
             ~end_boundary_line
             ~boundary_lines_seen)
    in
    let official_range_id =
      match official_lines with
      | [] -> None
      | _ :: _ ->
        Some
          { Keeper_memory_os_current.receipt_scope = runtime_keepers_dir
          ; after_boundary_line =
              (match official_cursor with None -> 0 | Some cursor -> cursor.O.boundary_line)
          ; turns = List.map (fun (turn : R.official_line) -> turn.line, turn.turn_ref) official_lines
          }
    in
    (* Memory first, positions last (I2). Shield the cursor writes once
       reached; the Memory WAL also repairs an interruption before this
       function or a failed write of either cursor. *)
    let advance () =
      Eio.Cancel.protect (fun () ->
        let* atom_progress =
          match atom_next with
          | None -> Ok None
          | Some range_id ->
            Result.map Option.some
              (write_atom (progress_of_range_id range_id) (fun progress -> progress))
        in
        match official_next with
        | None ->
          (match atom_progress with
           | Some progress -> Ok (Progress_advanced progress)
           | None -> Ok Nothing_to_read)
        | Some official ->
          (match
             Domain_pool_ref.submit_io_or_inline (fun () ->
               write_official_progress_store
                 ~keepers_dir:runtime_keepers_dir
                 ~keeper_id:keeper_name
                 official)
           with
           | Ok () -> Ok (Official_advanced { atom = atom_progress; official })
           | Error error -> Error (Official_progress_write_failed error)))
    in
    if selected_messages = [] && observations = []
    then (
      (* Lines whose fragments are all gone or all untagged: nothing for the
         model, and the position moves past them. Said aloud, because the
         writer's own loss path ends here too. *)
      Log.Keeper.warn
        ~keeper_name
        "librarian pass found no fragments for %d official line(s) through line %d; passing them"
        (List.length official_lines)
        (step_line last_step);
      advance ())
    else
      let* current, expected_revision =
        current_memory ~keepers_dir:memory_keepers_dir ~keeper_name
      in
      let* () =
        match after with
        | Some after when after > ended_at ->
          Error (Counterpart_interval_non_monotone { after; before = ended_at })
        | None | Some _ -> Ok ()
      in
      let* counterpart_observations =
        match after with
        | Some after when Float.equal after ended_at -> Ok []
        | None | Some _ ->
          Keeper_librarian_input_sources.counterpart_observations_between_offloaded
            ~base_dir:config.Workspace.base_path
            ~keeper_name
            ~after
            ~before:ended_at
          |> Result.map_error (fun error -> Counterpart_observations_unreadable error)
      in
      let input : Keeper_librarian.input =
        { turn_ref
        (* Turn boundaries do not carry historical task identity. The current
           task can belong to a later turn, so borrowing it would attach an old
           range to an unrelated Goal. Exact historical identity must be added
           at the same durable boundary before this can become [Task_goals]. *)
        ; goal_context = Keeper_librarian.No_task
        ; keeper_instructions = meta.instructions
        ; current
        ; working_context =
            Domain_pool_ref.submit_io_or_inline (fun () ->
              Keeper_librarian_context_io.capture
                ~base_path:config.Workspace.base_path
                ~keepers_dir:memory_keepers_dir
                ~keeper_name)
        ; messages = selected_messages
        ; tool_observations = observations
        ; counterpart_observations
        }
      in
      if not (commit ~expected_revision ~range_id:atom_next ~official_range_id input)
      then Ok Memory_not_committed
      else advance ())
;;

let consume_one_with_progress_writer
      ~write_progress_store
      ~write_official_progress_store
      ~config
      ~keeper_name
      ~commit
  =
  let runtime_keepers_dir = Workspace.keepers_runtime_dir config in
  let key = range_key ~runtime_keepers_dir ~keeper_name in
  let extent = if failed_before key then R.To_first_cut_point else R.All_unread in
  (* Leave the marker set across exceptions and cancellation. After a failed
     wide range, keep taking one cut point until a later pass proves that the
     backlog is empty. Clearing after the first small success would alternate
     large failures with small successes while the backlog keeps growing. *)
  mark_failed key;
  let result =
    consume_one_with_extent
      ~write_progress_store
      ~write_official_progress_store
      ~extent
      ~config
      ~keeper_name
      ~commit
  in
  (match result, extent with
   | Ok (Nothing_to_read | Baseline_advanced _), _
   | Ok (Progress_advanced _ | Official_advanced _), R.All_unread -> clear_failed key
   | Ok (Progress_advanced _ | Official_advanced _), R.To_first_cut_point
   | Ok Memory_not_committed, _
   | Error _, _ -> ());
  result
;;

let consume_one ~config ~keeper_name ~commit =
  consume_one_with_progress_writer
    ~write_progress_store:P.write
    ~write_official_progress_store:O.write
    ~config
    ~keeper_name
    ~commit
;;

let commit_with_runtime
      ~base_path
      ~keepers_dir
      ~keeper_id
      ~expected_revision
      ~range_id
      ~official_range_id
      input
  =
  let committed = ref false in
  Keeper_librarian_runtime.run_best_effort
    ~trigger:Keeper_librarian_runtime.Durable_range
    ~input_projection:Keeper_librarian_runtime.Already_selected_range
    ~on_memory_committed:(fun () -> committed := true)
    ?durable_range_id:range_id
    ?official_range_id
    ~base_path
    ~keepers_dir
    ~keeper_id
    ~expected_revision
    input;
  !committed
;;

module For_testing = struct
  let consume_one_with_progress_writer = consume_one_with_progress_writer

  let reset_process_state () =
    Stdlib.Mutex.protect failed_ranges_mu (fun () -> Hashtbl.clear failed_ranges)
  ;;
end
