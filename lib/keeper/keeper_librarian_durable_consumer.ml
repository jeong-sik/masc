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
  | Checkpoint_unreadable of
      { trace_id : string
      ; error : Keeper_checkpoint_store.checkpoint_load_error
      }
  | Position_in_other_trace of P.position
  | Position_not_in_history of P.position
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
  | Checkpoint_unreadable { trace_id; error } ->
    Printf.sprintf
      "checkpoint of trace=%s is unreadable: %s"
      trace_id
      (Keeper_checkpoint_store.checkpoint_load_error_to_string error)
  | Position_in_other_trace position ->
    Printf.sprintf
      "librarian position belongs to trace=%s end_atom=%d"
      position.P.trace_id
      position.end_atom
  | Position_not_in_history position ->
    Printf.sprintf
      "librarian position is not a place in this history trace=%s end_atom=%d digest=%s"
      position.P.trace_id
      position.end_atom
      position.last_atom_digest
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

(* The trace a line says starts a history from atom zero: a restart line, or
   a turn that began from an empty history. *)
let started_trace (written : B.record) =
  match written.event with
  | B.History_restarted { trace_id } -> Some trace_id
  | B.Turn_ended { turn_ref; history_at_start = B.Fresh_history; position = _ } ->
    Some (Ids.Turn_ref.trace_id turn_ref)
  | B.Turn_ended { turn_ref = _; history_at_start = B.Continued_history; position = _ } ->
    None
;;

(* Row 1b (#37362). The traces that started after [trace_id], in the order
   their first start line appears in the log. The list ends at
   [current_trace_id] when that trace states a start of its own; when it does
   not, every started trace after [trace_id] is listed and the walk ends by
   keeping the old position, which is the fail-closed answer for a
   continued-only log. Only a trace that states its own start can be read from
   atom zero, so a trace without a start line is not listed. A [trace_id] with
   no start line of its own is older than the log, so every trace that has one
   came after it.

   The walk reopens the checkpoint of every trace it passes on each round.
   Nothing here remembers what was passed, because the only cheap and
   stateless answer -- the boundary lines -- is what [R.may_have_unread]
   already reads before a checkpoint is opened. A keeper parked on a retired
   trace with several dead traces after it therefore pays one checkpoint read
   per dead trace per round, until a trace with something to read moves the
   position past them. *)
let traces_started_after ~trace_id ~current_trace_id lines =
  let started_in_order =
    List.fold_left
      (fun started (_, decoded) ->
         match decoded with
         | Ok written ->
           (match started_trace written with
            | Some trace when not (List.mem trace started) -> trace :: started
            | Some _ | None -> started)
         | Error (_ : B.read_error) -> started)
      []
      lines
    |> List.rev
  in
  let rec after_own = function
    | [] -> None
    | started :: rest ->
      if String.equal started trace_id then Some rest else after_own rest
  in
  let later =
    match after_own started_in_order with
    | Some rest -> rest
    | None -> started_in_order
  in
  let rec up_to_current = function
    | [] -> []
    | started :: rest ->
      if String.equal started current_trace_id
      then [ started ]
      else started :: up_to_current rest
  in
  up_to_current later
;;

(* Whether a checkpoint error on a trace the keeper has left is one that no
   later turn can clear. No turn runs on a retired trace, so nothing rewrites
   its checkpoint (keeper_checkpoint_store.ml says the same of the save path:
   reporting a superseded canonical as unreadable "made every save fail the
   same way forever, because nothing ever replaced the file"). An error that
   cannot clear would stop the pass on that trace for good, and with it every
   trace after it, so it is passed instead.

   Only the version this build supersedes is that error: the file holds turns
   this build will not read, and for a retired trace no newer file replaces
   it. The others are not passed. A parse error is an older binary reading a
   newer workspace as often as it is damage, a store or IO failure can be a
   disk that comes back, and an agent-core failure is neither classified here;
   a deploy or an operator makes those readable, so the pass keeps saying what
   it cannot read instead of walking past turns it could have read. *)
let retired_checkpoint_never_becomes_readable = function
  | Keeper_checkpoint_store.Superseded_version _ -> true
  | Keeper_checkpoint_store.Not_found
  | Keeper_checkpoint_store.Store_error _
  | Keeper_checkpoint_store.Parse_error _
  | Keeper_checkpoint_store.Io_error _
  | Keeper_checkpoint_store.Agent_core_error _ -> false
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

(* Durable inputs shared by the consumer and its read-only lag observation.
   Metadata is read separately so a committed receipt can repair progress
   even when the Keeper metadata is temporarily unavailable. *)
type positions =
  { runtime_keepers_dir : string
  ; memory_keepers_dir : string
  ; lines : (int * (B.record, B.read_error) result) list
  ; progress : P.t option
  ; official_cursor : Keeper_librarian_official_progress.t option
  }

let read_positions ~config ~keeper_name =
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
  Ok { runtime_keepers_dir; memory_keepers_dir; lines; progress; official_cursor }
;;

(* The Keeper identity comes from the same read that refuses a blank name,
   so a pass that has its metadata also has the id the Librarian is told. *)
let read_meta ~config ~keeper_name =
  match Domain_pool_ref.submit_io_or_inline (fun () ->
    Keeper_meta_store.read_effective_meta_presence_named config keeper_name) with
  | Ok (keeper_id, Keeper_meta_store.Meta_present meta) -> Ok (keeper_id, meta)
  | Ok (_, Keeper_meta_store.Meta_absent) -> Error Keeper_meta_absent
  | Ok (_, Keeper_meta_store.Meta_not_current detail) -> Error (Keeper_meta_unreadable detail)
  | Error detail -> Error (Keeper_meta_unreadable detail)
;;

let load_current_checkpoint ~config ~trace_id =
  let session_dir = Filename.concat (Keeper_fs.session_store_path config) trace_id in
  Domain_pool_ref.submit_io_or_inline (fun () ->
    Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:trace_id)
;;

type unread =
  { atoms : int
  ; official : int
  }

(* RFC §4.9, invariant I4. Read-only: the number the operator surfaces show,
   taken from the same files a pass reads. A keeper that never ran on
   AGENT_CORE has no checkpoint, so its atoms are nothing to count and its
   official lines are counted alone. *)
let unread_turns ~config ~keeper_name =
  let ( let* ) = Result.bind in
  let* positions = read_positions ~config ~keeper_name in
  let* _keeper_id, meta = read_meta ~config ~keeper_name in
  let current_trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  let official =
    R.unread_official_turns ~lines:positions.lines ~cursor:positions.official_cursor
  in
  match positions.progress with
  | Some { P.position; _ } when not (String.equal position.trace_id current_trace_id)
    ->
    (* A pass would drain that trace's own checkpoint first; which of its
       turns are behind is a question about a history this keeper has left. *)
    Error (Position_in_other_trace position)
  | Some _ | None ->
    let* atoms =
      if not (R.may_have_unread ~trace_id:current_trace_id
        ~lines:positions.lines ~progress:positions.progress)
      then Ok (Some 0)
      else match load_current_checkpoint ~config ~trace_id:current_trace_id with
      | Error Keeper_checkpoint_store.Not_found when Option.is_none positions.progress ->
        Ok (Some 0)
      | Error error ->
        Error (Checkpoint_unreadable { trace_id = current_trace_id; error })
      | Ok checkpoint ->
        Ok
          (R.unread_turns
             ~trace_id:current_trace_id
             ~lines:positions.lines
             ~progress:positions.progress
             ~messages:checkpoint.Agent_core.Checkpoint.messages)
    in
    (match atoms, positions.progress with
     | Some atoms, (Some _ | None) -> Ok { atoms; official }
     | None, Some { P.position; _ } -> Error (Position_not_in_history position)
     | None, None ->
       (* [R.unread_turns] answers [None] only for a position it could not
          place, and there is none here. *)
       invalid_arg "librarian unread turns: no position and no count")
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
  let* { runtime_keepers_dir
       ; memory_keepers_dir
       ; lines
       ; progress
       ; official_cursor
       }
    =
    read_positions ~config ~keeper_name
  in
  let* recovered =
    recover_official_progress ~write:write_official_progress_store
      ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name ~lines ~cursor:official_cursor
  in
  match recovered with
  | Some outcome -> Ok outcome
  | None ->
  let* keeper_id, meta = read_meta ~config ~keeper_name in
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
  let load_checkpoint trace_id = load_current_checkpoint ~config ~trace_id in
  (* A keeper that has only ever run on official-client runtimes has no
     checkpoint and no atom position: its atoms are nothing to read, and its
     official lines are read below. A missing checkpoint with a position is
     still an error when unread atom work requires that checkpoint. *)
  let trace_selection ?progress trace_id =
    if not (R.may_have_unread ~trace_id ~lines ~progress)
    then Ok (trace_id, progress, [], R.Nothing_to_read)
    else match load_checkpoint trace_id, progress with
    | Error Keeper_checkpoint_store.Not_found, None ->
      Ok (trace_id, None, [], R.Nothing_to_read)
    | Error error, _ -> Error (Checkpoint_unreadable { trace_id; error })
    | Ok checkpoint, progress ->
      let messages = checkpoint.Agent_core.Checkpoint.messages in
      Ok (trace_id, progress, messages, R.select ~trace_id ~lines ~progress ~messages extent)
  in
  (* [previous]'s trace has nothing left, or its checkpoint is gone. Each trace
     that started after it is read from its own start, in the order the log
     saw them start (#37362): a trace with nothing to read is passed, and the
     current trace ends the walk. With no started trace to move to, the old
     position stays authoritative. *)
  let say_passed_trace ~trace_id error =
    Log.Keeper.warn
      ~keeper_name
      "librarian hand-off passes trace=%s: %s; the keeper has left that trace, \
       so nothing rewrites its checkpoint and its turns stay unread"
      trace_id
      (Keeper_checkpoint_store.checkpoint_load_error_to_string error)
  in
  let after_prior (previous : P.t) =
    let rec walk = function
      | [] -> Error (Position_in_other_trace previous.P.position)
      | trace_id :: later ->
        (match trace_selection trace_id with
         | Error (Checkpoint_unreadable { trace_id = _; error })
           when (not (String.equal trace_id current_trace_id))
                && retired_checkpoint_never_becomes_readable error ->
           say_passed_trace ~trace_id error;
           walk later
         | Error error -> Error error
         | Ok ((_, _, _, selection) as chosen) ->
           (match selection with
            | R.Nothing_to_read when not (String.equal trace_id current_trace_id) ->
              walk later
            | R.Nothing_to_read
            | R.Read _
            | R.Baseline _
            | R.Position_in_other_trace _
            | R.Stop _ -> Ok chosen))
    in
    walk
      (traces_started_after
         ~trace_id:previous.P.position.P.trace_id
         ~current_trace_id
         lines)
  in
  (* The counterpart lower bound is its own cursor. A trace change restarts
     the atom position at zero, but the counterpart evidence up to
     [previous]'s boundary was read with the old trace, so that boundary stays
     the lower bound instead of the start of both stores. *)
  let with_counterpart counterpart_progress (trace_id, selection_progress, messages, selection) =
    trace_id, selection_progress, counterpart_progress, messages, selection
  in
  let* trace_id, selection_progress, counterpart_progress, messages, selection =
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
          | R.Nothing_to_read ->
            Result.map (with_counterpart (Some previous)) (after_prior previous)
          | R.Read _
          | R.Baseline _
          | R.Position_in_other_trace _
          | R.Stop _ ->
            Ok (position.trace_id, Some previous, Some previous, messages, selection))
       | Error Keeper_checkpoint_store.Not_found ->
         (* A removed owner/session cannot finish its old trace. *)
         Result.map (with_counterpart (Some previous)) (after_prior previous)
       | Error error ->
         (* The trace the position names is retired too, so it takes the same
            decision as a trace the walk opens. *)
         if retired_checkpoint_never_becomes_readable error
         then (
           say_passed_trace ~trace_id:position.trace_id error;
           Result.map (with_counterpart (Some previous)) (after_prior previous))
         else Error (Checkpoint_unreadable { trace_id = position.trace_id; error }))
    | None -> Result.map (with_counterpart None) (trace_selection current_trace_id)
    | Some current ->
      Result.map
        (with_counterpart (Some current))
        (trace_selection ~progress:current current_trace_id)
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
            B.witness_line
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
               B.witness_line
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
      match counterpart_progress with
      | None -> Ok None
      | Some { P.position; boundary_lines_seen } ->
        (match
           B.witness_line
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
    let cursor_bound cursor =
      match cursor with
      | Some (line, recorded_at) when line < step_line first_step -> Some recorded_at
      | Some _ | None -> None
    in
    let atom_bound = cursor_bound after_atom in
    let official_bound = cursor_bound after_official in
    let after =
      List.filter_map Fun.id [ atom_bound; official_bound ]
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
      (* A bound carried from the trace before this one can sit after this
         range's end when the wall clock went backwards between the two
         traces. This commit replaces the atom cursor with this range's end,
         so the rows above that end are read by the next range: the window
         here is empty by reading, not by repair.

         That holds only while the atom cursor is the one that inverted the
         interval. The official cursor is not replaced by this commit, so if
         it also sits after this range's end, the next range's bound is that
         same stamp and the rows between would be read by nobody. Then the
         refusal stands: the pass stops without advancing, and an official
         line or a clock that comes forward moves it again. Within one trace
         the inversion says the position and its boundary disagree, and stops
         the pass as before. *)
      let carried_from_another_trace =
        match counterpart_progress with
        | None -> false
        | Some { P.position; _ } -> not (String.equal position.P.trace_id trace_id)
      in
      let inverted_by_the_carried_bound_alone =
        carried_from_another_trace
        && (match official_bound with
            | None -> true
            | Some official_bound -> official_bound <= ended_at)
      in
      let* () =
        match after with
        | Some after when after > ended_at && not inverted_by_the_carried_bound_alone ->
          Error (Counterpart_interval_non_monotone { after; before = ended_at })
        | None | Some _ -> Ok ()
      in
      let* counterpart_observations =
        match after with
        | Some after when after >= ended_at -> Ok []
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
        ; keeper_id
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
