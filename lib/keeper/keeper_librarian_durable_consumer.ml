module B = Keeper_turn_boundaries
module P = Keeper_librarian_progress
module R = Keeper_librarian_range
module Window = Runtime_model_input_tail_window
module Canonical_tool = Agent_core.Canonical_tool
module String_map = Map.Make (String)
module Line_map = Map.Make (Int)
module Historical = Keeper_librarian_task_context

module O = Keeper_librarian_official_progress

type commit_result =
  | Memory_committed
  | Memory_refused of Keeper_librarian_runtime.not_committed list

type outcome =
  | Nothing_to_read
  | Baseline_advanced of P.t
  | Memory_not_committed of Keeper_librarian_runtime.not_committed list
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
  | B.Turn_ended
      { turn_ref = _
      ; history_at_start = B.Continued_history | B.Continued_history_from _; position = _
      } -> None
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

let range_id_for_selection
      ~receipt_scope
      ~trace_id
      ~(range : R.range)
      ~end_boundary_line
      ~boundary_lines_seen
  : Keeper_memory_os_current.durable_range_id
  =
  { receipt_scope
  ; unread_messages = []
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

(* The checkpoint and a turn-end line of [trace_id] both place [end_atom]
   with this digest, the line being [end_boundary_line]. *)
let endpoint_witnessed ~trace_id ~end_atom ~last_atom_digest ~end_boundary_line ~messages lines =
  let checkpoint_matches =
    match Window.atom_opening_digest messages (end_atom - 1) with
    | Some digest -> String.equal digest last_atom_digest
    | None -> false
  in
  checkpoint_matches
  && List.exists
       (fun (line, decoded) ->
          Int.equal line end_boundary_line
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
            String.equal (Ids.Turn_ref.trace_id turn_ref) trace_id
            && Int.equal boundary.end_atom end_atom
            && String.equal boundary.last_atom_digest last_atom_digest
          | Ok
              { B.event =
                  B.Turn_ended
                    { position =
                        (B.Empty_atom_history | B.No_atom_history | B.Stale_noop)
                    ; _
                    }
              ; _
              }
          | Ok { B.event = B.History_restarted _; _ }
          | Error _ -> false)
       lines
;;

let endpoint_is_present
      (range_id : Keeper_memory_os_current.durable_range_id)
      ~messages
      lines
  =
  endpoint_witnessed
    ~trace_id:range_id.trace_id
    ~end_atom:range_id.end_atom
    ~last_atom_digest:range_id.last_atom_digest
    ~end_boundary_line:range_id.end_boundary_line
    ~messages
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
  && Result.is_ok (Keeper_librarian_unread.validate_atom_history
       ~trace_id ~history_start_boundary_line:committed.history_start_boundary_line
       ~end_atom:committed.end_atom ~messages committed.unread_messages)
;;

(* Atoms the continuity round saved to Memory: a range of one trace's
   history, and the turn-end line that witnesses its end. *)
type continuity_saved =
  { saved_trace_id : string
  ; saved_history_start_boundary_line : int
  ; saved_start_atom : int
  ; saved_end_atom : int
  ; saved_last_atom_digest : string
  ; saved_end_boundary_line : int
  ; saved_unread_messages : Keeper_librarian_unread.t list
  }

(* Whether saved atoms reach past where this round starts. Unlike
   [is_committed_prefix], they may begin before the start: the continuity
   round reads in its own units, and its snapshot stands for the whole prefix
   it covers. *)
let continuity_saved_reaches_past
      saved
      ~trace_id
      ~(selected : R.range)
      ~selected_end_boundary_line
      ~messages
      lines
  =
  String.equal saved.saved_trace_id trace_id
  && Int.equal saved.saved_history_start_boundary_line selected.history_start_boundary_line
  && saved.saved_start_atom <= selected.start_atom
  && selected.start_atom < saved.saved_end_atom
  && saved.saved_end_atom <= selected.end_atom
  && saved.saved_end_boundary_line <= selected_end_boundary_line
  && Result.is_ok (Keeper_librarian_unread.validate_atom_history
       ~trace_id:saved.saved_trace_id
       ~history_start_boundary_line:saved.saved_history_start_boundary_line
       ~end_atom:saved.saved_end_atom ~messages saved.saved_unread_messages)
  && endpoint_witnessed
       ~trace_id:saved.saved_trace_id
       ~end_atom:saved.saved_end_atom
       ~last_atom_digest:saved.saved_last_atom_digest
       ~end_boundary_line:saved.saved_end_boundary_line
       ~messages
       lines
;;

(* The atoms the continuity round has saved to Memory. It saves Memory itself
   for a completed range this round has not committed yet, under the receipt
   scope [Keeper_librarian_continuity.path] names, in the same Memory WAL this
   round reads its own receipt from, and gives that Memory pass the same
   tool and counterpart observations this round would. It publishes its
   snapshot only after the Memory of every unit it covers is saved
   ([Keeper_librarian_continuity.commit]), so a published snapshot stands for
   saved Memory from atom 0 through its end. The WAL keeps one receipt per
   scope, so after several units only the snapshot still says what the
   earlier ones saved; the receipt alone covers a stop between the Memory
   save and the snapshot write. A snapshot that ends inside a turn is not
   offered: no turn-end line witnesses its end, so this round cannot stand
   there.

   The two are read apart, and whichever is readable is used. What cannot be
   read proves nothing, so without either the range is read as before, and
   the cause is logged. *)
let continuity_saved_ranges ~config ~keeper_name ~memory_keepers_dir =
  let unreadable what detail =
    Log.Keeper.warn
      ~keeper_name
      "durable Librarian cannot read the continuity round's %s; not counting it as saved: %s"
      what
      detail;
    []
  in
  let receipt =
    match
      Keeper_memory_os_current.committed_durable_coverage
        ~keepers_dir:memory_keepers_dir
        ~keeper_id:keeper_name
        ~receipt_scope:(Keeper_librarian_continuity.path ~config ~keeper_name)
    with
    | Error detail -> unreadable "Memory receipt" detail
    | Ok None -> []
    | Ok (Some (range : Keeper_memory_os_current.durable_range_id)) ->
      [ { saved_trace_id = range.trace_id
        ; saved_history_start_boundary_line = range.history_start_boundary_line
        ; saved_start_atom = range.start_atom
        ; saved_end_atom = range.end_atom
        ; saved_last_atom_digest = range.last_atom_digest
        ; saved_end_boundary_line = range.end_boundary_line
        ; saved_unread_messages = range.unread_messages
        }
      ]
  in
  let published =
    match Keeper_librarian_continuity.read ~config ~keeper_name with
    | Error detail -> unreadable "snapshot" detail
    | Ok None -> []
    | Ok (Some (snapshot : Librarian_continuity_snapshot.t))
      when Int.equal snapshot.end_atom snapshot.covering_end_atom ->
      [ { saved_trace_id = snapshot.trace_id
        ; saved_history_start_boundary_line = snapshot.history_start_boundary_line
        ; saved_start_atom = 0
        ; saved_end_atom = snapshot.end_atom
        ; saved_last_atom_digest = snapshot.last_atom_digest
        ; saved_end_boundary_line = snapshot.end_boundary_line
        ; saved_unread_messages = snapshot.unread_messages
        }
      ]
    | Ok (Some (_ : Librarian_continuity_snapshot.t)) -> []
  in
  (* A historical snapshot may outlive this scope's last receipt. Never pass
     its holes unless their exact originals/causes survived in the cumulative
     Memory ledger; the caller reconciles that ledger before cursor recovery. *)
  match Keeper_memory_os_current.read_unread_messages ~keepers_dir:memory_keepers_dir
      ~keeper_id:keeper_name with
  | Error detail -> unreadable "unread ledger" detail
  | Ok archived ->
    List.filter (fun candidate -> List.for_all (fun (hole : Keeper_librarian_unread.t) ->
      List.exists (fun (stored : Keeper_librarian_unread.t) ->
        stored.source=hole.source && List.for_all (fun reason -> List.mem reason stored.reasons)
          hole.reasons) archived) candidate.saved_unread_messages) (receipt @ published)
;;

(* The furthest end the continuity round's saved Memory proves for this
   range, as the position this round would write had it read that far. On
   2026-09-25 three keepers' receipts show the same atoms saved twice, the
   continuity round's first: jazz-developer [6416,6455) at revisions 1444
   then 1447, code-reviewer [387,397) then [257,397) at 292 then 293,
   masc-pro-builder [1862,1866) then [1847,1866) at 947 then 948. *)
let continuity_saved_position
      ~config
      ~keeper_name
      ~memory_keepers_dir
      ~trace_id
      ~(selected : R.range)
      ~selected_end_boundary_line
      ~selected_boundary_lines_seen
      ~messages
      lines
  =
  continuity_saved_ranges ~config ~keeper_name ~memory_keepers_dir
  |> List.fold_left
       (fun furthest candidate ->
          if not
               (continuity_saved_reaches_past
                  candidate
                  ~trace_id
                  ~selected
                  ~selected_end_boundary_line
                  ~messages
                  lines)
          then furthest
          else (
            match furthest with
            | Some kept when kept.saved_end_atom >= candidate.saved_end_atom -> furthest
            | Some _ | None -> Some candidate))
       None
  |> Option.map (fun furthest ->
    { P.position =
        { P.trace_id
        ; end_atom = furthest.saved_end_atom
        ; last_atom_digest = furthest.saved_last_atom_digest
        }
    ; boundary_lines_seen = selected_boundary_lines_seen
    })
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
      Keeper_memory_os_current.read_classified ~keepers_dir ~keeper_id:keeper_name)
  with
  | Io_unreadable { detail } -> Error (Memory_snapshot_unreadable detail)
  | No_snapshot -> Ok (None, None)
  | Readable snapshot ->
    Ok (Some { Keeper_librarian.facts = snapshot.facts }, Some snapshot.revision)
  | Undecodable { rejection } ->
    (* A decode rejection is the one failure the write path can recover: the
       commit below re-reads under the store lock and the quarantine branch in
       [update_locked_with_error] moves the undecodable bytes aside, then the
       replacement writes a fresh revision-1 snapshot. Feeding the empty
       current in with no expected revision is what routes the pass through
       that branch instead of skipping the write and leaving the keeper
       wedged (#32461). An I/O failure above stays a hard stop: replacing a
       store the build could not even read would destroy state blindly. *)
    Log.Keeper.warn
      ~keeper_name
      "librarian routing undecodable current snapshot into write-path quarantine: %s"
      rejection;
    Ok (None, None)
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

type message_floor =
  | No_message_floor
  | Runtime_message_floor of Keeper_lane_cli_oneshot.runner option

let floor_refusal detail : Keeper_librarian_runtime.not_committed =
  {input_capacity_evidence=No_input_capacity_refusal;provider_input_refusals=[];
   message_descent=No_descent_evidence;
   detail;walk_shows_size=false;smaller_range_meets_same_failure=false}

let checkpoint_message_floor ?cli_runner ~config ~keeper_name ~lines ~progress ~official_cursor
    ~selection_progress ~messages ~(selected_range : R.range)
    ~(range : Keeper_memory_os_current.durable_range_id)
    ~external_cursor ~external_through reports (input : Keeper_librarian.input) =
  let module Current = Keeper_memory_os_current in
  let module Unread = Keeper_librarian_unread in
  let module Floor = Keeper_librarian_message_floor in
  let module C = Keeper_checkpoint_store in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path in
  let runtime_keepers_dir = Workspace.keepers_runtime_dir config in
  let failure detail extra = Memory_refused (reports @ extra @ [floor_refusal detail]) in
  let inferred =
    let ( let* ) = Result.bind in
    let* sources = Unread.sources_for_atom_range ~trace_id:range.trace_id
      ~history_start_boundary_line:range.history_start_boundary_line
      ~start_atom:range.start_atom ~end_atom:range.end_atom ~messages
      |> Result.map_error (fun detail -> detail,[]) in
    let unread_message source ~reasons = match source with
      | Unread.Atom {trace_id;history_start_boundary_line;atom;message_in_atom;_}
          when trace_id=range.trace_id && history_start_boundary_line=range.history_start_boundary_line
               && range.start_atom <= atom && atom < range.end_atom ->
        Unread.for_atom ~trace_id ~history_start_boundary_line ~atom ~message_in_atom ~messages ~reasons
      | Unread.Atom _ | Unread.Official_turn _ -> Error "message is outside the selected checkpoint range" in
    let* unread_messages = Domain_pool_ref.submit_io_or_inline (fun () ->
      Current.read_unread_messages ~keepers_dir ~keeper_id:keeper_name)
      |> Result.map_error (fun detail -> detail,[]) in
    Floor.infer ?cli_runner ~base_path:config.Workspace.base_path ~keepers_dir ~keeper_name
      ~sources ~unread_message ~previous_state:None ~unread_messages input
      |> Result.map_error (fun (error : Floor.error) -> error.detail,error.reports) in
  match inferred with
  | Error (detail,extra) -> failure detail extra
  | Ok inferred ->
    let range = {range with Current.unread_messages=inferred.program.unread} in
    let source = Current.Atom_program_source {range;checkpoint=messages} in
    let committed = ref false in
    let publication = Eio.Cancel.protect (fun () ->
      Domain_pool_ref.submit_io_or_inline (fun () ->
        (* The selected trace may already be retired. Lock its actual source,
           not the current Keeper metadata trace, and do not reenter its loader. *)
        let session_dir = Filename.concat (Keeper_fs.session_store_path config) range.trace_id in
        C.with_agent_core_exact_snapshot ~session_dir ~session_id:range.trace_id (fun snapshot ->
          let ( let* ) = Result.bind in
          let current_messages = C.exact_snapshot_messages snapshot in
          let* current_lines = B.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name in
          let prefix = List.filter (fun (line,_) -> line <= range.end_boundary_line) in
          let* () = if prefix current_lines=prefix lines then Ok ()
            else Error "checkpoint boundary prefix changed during message inference" in
          let* current_progress = P.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
            |> Result.map_error P.read_error_to_string in
          let* current_official = O.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
            |> Result.map_error O.read_error_to_string in
          let* () = if current_progress=progress && current_official=official_cursor then Ok ()
            else Error "Librarian cursor changed during checkpoint message inference" in
          (* Opening digests do not cover a later tool response. Compare every
             original prefix message using its canonical full encoding. *)
          let prefix_messages messages = Window.annotate messages |> fst
            |> List.filter_map (fun (message,label) -> match label with
              | Window.Pinned -> Some (Agent_core.Checkpoint.message_to_json message)
              | Window.Atom atom -> if atom < range.end_atom
                then Some (Agent_core.Checkpoint.message_to_json message) else None) in
          let* () = if prefix_messages current_messages=prefix_messages messages then Ok ()
            else Error "checkpoint message prefix changed during message inference" in
          (* A restart appended beyond the selected prefix changes the history
             generation even when all old bytes and opening digests survive.
             A normal later cut leaves this first selected cut unchanged. *)
          let* () = match R.select ~trace_id:range.trace_id ~lines:current_lines
              ~progress:selection_progress ~messages:current_messages R.To_first_cut_point with
            | R.Read {range=current;_} when current=selected_range -> Ok ()
            | R.Read _ | R.Baseline _ | R.Nothing_to_read | R.Position_in_other_trace _ | R.Stop _ ->
              Error "checkpoint selection or history generation changed during message inference" in
          let* () = Keeper_external_read_cursor.prepare ~memory_keepers_dir:keepers_dir
            ~runtime_keepers_dir ~keeper_name external_cursor ~through:external_through
            ~atom:(Some range) ~official:None in
          let* _ = Current.apply_program ~keepers_dir ~keeper_id:keeper_name ~now:(Time_compat.now ())
            ~anchor:inferred.anchor ~source ~validate_source:(fun () -> Ok ())
            ~on_committed:(fun _ -> committed := true) inferred.program in
          Ok ()))) in
    let settled_failure detail =
      if !committed then (
        Log.Keeper.warn ~keeper_name
          "checkpoint Memory program is durable; later settlement failed and WAL recovery is required: %s" detail;
        Memory_committed)
      else failure detail [] in
    (match publication with
     | Ok (Ok ()) -> Memory_committed
     | Ok (Error detail) -> settled_failure detail
     | Error error -> settled_failure (C.checkpoint_ref_load_error_to_string error))
;;

let official_message_floor ?cli_runner ~config ~keeper_name ~lines ~progress ~official_cursor
    ~fragments ~(selected : R.official_line) ~(range : Keeper_memory_os_current.official_range_id)
    ~external_cursor ~external_through reports
    (input : Keeper_librarian.input) =
  let module Current = Keeper_memory_os_current in
  let module Unread = Keeper_librarian_unread in
  let module Floor = Keeper_librarian_message_floor in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path in
  let runtime_keepers_dir = Workspace.keepers_runtime_dir config in
  let trace_id = Ids.Turn_ref.trace_id selected.turn_ref in
  let selected_turns = [selected.line,selected.turn_ref,input.messages] in
  let sources = List.mapi (fun message_in_turn message ->
    Unread.Official_turn {turn_ref=selected.turn_ref;boundary_line=selected.line;
      message_in_turn;message_sha256=Unread.message_digest message}) input.messages in
  let unread_message source ~reasons = match source with
    | Unread.Official_turn {turn_ref;boundary_line;message_in_turn;_}
        when Ids.Turn_ref.equal turn_ref selected.turn_ref && boundary_line=selected.line ->
      Unread.for_official_turn ~turn_ref ~boundary_line ~message_in_turn ~messages:input.messages ~reasons
    | Unread.Atom _ | Unread.Official_turn _ -> Error "message is outside the selected official turn" in
  let failure detail extra = Memory_refused (reports @ extra @ [floor_refusal detail]) in
  let inferred =
    let ( let* ) = Result.bind in
    let* unread_messages = Domain_pool_ref.submit_io_or_inline (fun () ->
      Current.read_unread_messages ~keepers_dir ~keeper_id:keeper_name)
      |> Result.map_error (fun detail -> detail,[]) in
    Floor.infer ?cli_runner ~base_path:config.Workspace.base_path ~keepers_dir ~keeper_name
      ~sources ~unread_message ~previous_state:None ~unread_messages input
      |> Result.map_error (fun (error : Floor.error) -> error.detail,error.reports) in
  match inferred with
  | Error (detail,extra) -> failure detail extra
  | Ok inferred ->
    let range = {range with Current.unread_messages=inferred.program.unread} in
    let source = Current.Official_program_source {range;selected_turns} in
    let committed = ref false in
    let publication = Eio.Cancel.protect (fun () ->
      Domain_pool_ref.submit_io_or_inline (fun () ->
        let session_dir = Filename.concat (Keeper_fs.session_store_path config) trace_id in
        Keeper_checkpoint_store.with_session_lock ~session_dir (fun _ ->
          (* The same session lock excludes both real history writers. Keep
             it through Memory durability; no inference runs under this lock. *)
          let ( let* ) = Result.bind in
          let* current_lines = B.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name in
          let prefix = List.filter (fun (line,_) -> line <= selected.line) in
          let* () = if prefix current_lines=prefix lines then Ok ()
            else Error "official boundary prefix changed during message inference" in
          let* current_progress = P.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
            |> Result.map_error P.read_error_to_string in
          let* current_official = O.read ~keepers_dir:runtime_keepers_dir ~keeper_id:keeper_name
            |> Result.map_error O.read_error_to_string in
          let* () = if current_progress=progress && current_official=official_cursor then Ok ()
            else Error "Librarian cursor changed during official message inference" in
          let* current_fragments = read_fragments ~config [selected] |> Result.map_error error_to_string in
          let* () = match String_map.find_opt trace_id fragments,
              String_map.find_opt trace_id current_fragments with
            | Some original, Some current ->
              if Keeper_turn_fragments.of_turn selected.turn_ref current
                 = Keeper_turn_fragments.of_turn selected.turn_ref original then Ok ()
              else Error "official messages or host observations changed during message inference"
            | None, (None | Some _) | Some _, None -> Error "official source capture is unavailable" in
          let* () = Keeper_external_read_cursor.prepare ~memory_keepers_dir:keepers_dir
            ~runtime_keepers_dir ~keeper_name external_cursor ~through:external_through
            ~atom:None ~official:(Some range) in
          let* _ = Current.apply_program ~keepers_dir ~keeper_id:keeper_name ~now:(Time_compat.now ())
            ~anchor:inferred.anchor ~source ~validate_source:(fun () -> Ok ())
            ~on_committed:(fun _ -> committed := true) inferred.program in
          Ok ()))) in
    (match publication with
     | Ok (Ok ()) -> Memory_committed
     | Error detail | Ok (Error detail) ->
       if !committed then (
         Log.Keeper.warn ~keeper_name
           "official Memory program is durable; later settlement failed and WAL recovery is required: %s" detail;
         Memory_committed)
       else failure detail [])
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
           | Ok
               { B.event =
                   B.Turn_ended
                     { position =
                         (B.Atom_history _ | B.Empty_atom_history | B.Stale_noop)
                     ; _
                     }
               ; _
               }
           | Ok { B.event = B.History_restarted _; _ }
           | Error _ -> None)
      lines
  with
  | Some recorded_at -> Ok recorded_at
  | None -> Error (Official_progress_boundary_missing cursor)
;;

(* The Memory WAL, not a successful return from the model, proves which
   official turns were saved. Repair this cursor before retry narrowing or
   checkpoint selection; a mixed pass can have saved only its atom cursor. *)
let recover_official_progress
      ~config ~write ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name ~lines ~cursor
  =
  let ( let* ) = Result.bind in
  if not (R.may_have_unread_official ~lines ~cursor)
  then Ok None
  else
  let* receipt =
    Keeper_memory_os_current.committed_official_coverage
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
      let* source_matches = match receipt.unread_messages with
        | [] -> Ok true
        | holes ->
          (match selected with
           | R.Nothing_official | R.Official_stop _ -> Ok false
           | R.Official_read selected ->
             let* fragments = read_fragments ~config selected in
             Ok (List.for_all (fun (hole : Keeper_librarian_unread.t) ->
               match hole.source with
               | Atom _ -> false
               | Official_turn {turn_ref;boundary_line;message_in_turn;_} ->
                 let lines = match String_map.find_opt (Ids.Turn_ref.trace_id turn_ref) fragments with
                   | Some lines -> lines | None -> [] in
                 let messages = Keeper_turn_fragments.of_turn turn_ref lines
                   |> List.filter_map (function
                     | Keeper_turn_fragments.Message {message;_} -> Some message
                     | Keeper_turn_fragments.Tool_observation _ -> None) in
                 Keeper_librarian_unread.for_official_turn ~turn_ref ~boundary_line
                   ~message_in_turn ~messages ~reasons:hole.reasons = Ok hole) holes))
      in
      if current < start || not matches || not source_matches
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

(* A checkpoint of a version this build supersedes holds no history this
   build reads, on the current trace as on a retired one
   ({!Keeper_checkpoint_store.saved_history}): its atoms are nothing to read,
   and the official lines of the same trace are still read. Every other error
   stops the pass. A later version's file reads once that version is
   deployed, a parse error can be damage an operator repairs, and a store or
   IO failure can be a disk that comes back, so the pass keeps saying what it
   cannot read instead of walking past turns it could have read. *)
let load_current_checkpoint ~config ~trace_id =
  let session_dir = Filename.concat (Keeper_fs.session_store_path config) trace_id in
  Domain_pool_ref.submit_io_or_inline (fun () ->
    Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:trace_id
    |> Keeper_checkpoint_store.saved_history)
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
      | Ok (Keeper_checkpoint_store.History_superseded _) -> Ok (Some 0)
      | Error
          (( Keeper_checkpoint_store.Not_found | Keeper_checkpoint_store.Store_error _ | Keeper_checkpoint_store.Parse_error _
            | Keeper_checkpoint_store.Superseded_version _ | Keeper_checkpoint_store.Newer_version _ | Keeper_checkpoint_store.Io_error _
            | Keeper_checkpoint_store.Read_failed _ | Keeper_checkpoint_store.Agent_core_error _ ) as error) ->
        Error (Checkpoint_unreadable { trace_id = current_trace_id; error })
      | Ok (Keeper_checkpoint_store.History_read checkpoint) ->
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
      ~message_floor
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
  let cursor_error detail = Counterpart_observations_unreadable
    (Keeper_librarian_input_sources.External_cursor_failed detail) in
  let* _ = Domain_pool_ref.submit_io_or_inline (fun () ->
    Keeper_memory_os_current.committed_unread_messages ~keepers_dir:memory_keepers_dir
      ~keeper_id:keeper_name)
    |> Result.map_error (fun detail -> Memory_snapshot_unreadable detail) in
  let* external_cursor = Domain_pool_ref.submit_io_or_inline (fun () ->
    Keeper_external_read_cursor.read ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name)
    |> Result.map_error cursor_error in
  let* recovered =
    recover_official_progress ~config ~write:write_official_progress_store
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
    | Ok (Keeper_checkpoint_store.History_superseded _), progress ->
      Ok (trace_id, progress, [], R.Nothing_to_read)
    | Error
        (( Keeper_checkpoint_store.Not_found | Keeper_checkpoint_store.Store_error _ | Keeper_checkpoint_store.Parse_error _
          | Keeper_checkpoint_store.Superseded_version _ | Keeper_checkpoint_store.Newer_version _ | Keeper_checkpoint_store.Io_error _
          | Keeper_checkpoint_store.Read_failed _ | Keeper_checkpoint_store.Agent_core_error _ ) as error), _ ->
      Error (Checkpoint_unreadable { trace_id; error })
    | Ok (Keeper_checkpoint_store.History_read checkpoint), progress ->
      let messages = checkpoint.Agent_core.Checkpoint.messages in
      Ok (trace_id, progress, messages, R.select ~trace_id ~lines ~progress ~messages extent)
  in
  (* [previous]'s trace has nothing left, or its checkpoint is gone. Each trace
     that started after it is read from its own start, in the order the log
     saw them start (#37362): a trace with nothing to read is passed, and the
     current trace ends the walk. With no started trace to move to, the old
     position stays authoritative. *)
  let after_prior (previous : P.t) =
    let rec walk = function
      | [] -> Error (Position_in_other_trace previous.P.position)
      | trace_id :: later ->
        (match trace_selection trace_id with
         | Error
             (( Keeper_meta_absent | Keeper_meta_unreadable _
              | Boundary_log_unreadable _ | Progress_unreadable _
              | Checkpoint_unreadable _ | Position_in_other_trace _
              | Position_not_in_history _ | Range_stopped _
              | Range_end_boundary_missing _ | Progress_boundary_missing _
              | Memory_snapshot_unreadable _ | Counterpart_interval_non_monotone _
              | Counterpart_observations_unreadable _ | Progress_write_failed _
              | Official_progress_unreadable _ | Official_progress_write_failed _
              | Official_progress_boundary_missing _
              | Committed_official_range_mismatch | Official_range_stopped _
              | Fragment_store_unreadable _ | Fragment_line_unreadable _ ) as error) ->
           Error error
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
       | Ok (Keeper_checkpoint_store.History_read checkpoint) ->
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
       | Error Keeper_checkpoint_store.Not_found
       | Ok (Keeper_checkpoint_store.History_superseded _) ->
         (* A removed owner/session cannot finish its old trace, and nothing
            of a superseded one is read. *)
         Result.map (with_counterpart (Some previous)) (after_prior previous)
       | Error
           (( Keeper_checkpoint_store.Store_error _ | Keeper_checkpoint_store.Parse_error _
             | Keeper_checkpoint_store.Superseded_version _ | Keeper_checkpoint_store.Newer_version _ | Keeper_checkpoint_store.Io_error _
             | Keeper_checkpoint_store.Read_failed _ | Keeper_checkpoint_store.Agent_core_error _ ) as error) ->
         Error (Checkpoint_unreadable { trace_id = position.trace_id; error }))
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
  (* The two positions are independent (RFC §4.10). An official stop holds
     the official lines only: no later line lifts it, so letting it hold the
     atoms too would stand every round of the keeper at a line the atom path
     has already settled (masc#37061). The stop is this pass's answer once the
     atom part has nothing to do, so a drain that reads atoms ends on it. *)
  match selection, official with
  | R.Stop stop, (R.Nothing_official | R.Official_read _ | R.Official_stop _) ->
    Error (Range_stopped stop)
  | R.Position_in_other_trace position, (R.Nothing_official | R.Official_read _ | R.Official_stop _)
    -> Error (Position_in_other_trace position)
  | R.Baseline _, (R.Nothing_official | R.Official_read _ | R.Official_stop _) ->
    (* The atom position is set first; the official lines wait for the next
       call, which the caller makes while a call advances. *)
    (match R.progress_after ~trace_id selection with
     | None -> Ok Nothing_to_read
     | Some next -> write_atom next (fun progress -> Baseline_advanced progress))
  | R.Nothing_to_read, R.Official_stop { line; error } ->
    Error (Official_range_stopped { line; error })
  | R.Nothing_to_read, R.Nothing_official -> Ok Nothing_to_read
  | R.Read _, (R.Nothing_official | R.Official_read _ | R.Official_stop _)
  | R.Nothing_to_read, R.Official_read _ ->
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
          Keeper_memory_os_current.committed_durable_coverage
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
         | Some _ | None ->
           Ok
             (continuity_saved_position
                ~config
                ~keeper_name
                ~memory_keepers_dir
                ~trace_id
                ~selected:recovery_range
                ~selected_end_boundary_line:recovery_boundary_line
                ~selected_boundary_lines_seen:recovery_boundary_lines_seen
                ~messages
                lines))
    in
    (match committed_prefix_advance with
     | Some next ->
       (* Memory for this prefix is already saved: by this round's commit
          whose progress write did not land, or by the continuity round.
          Move the position without a model call; the official lines wait
          for the next call. *)
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
    (* Join selected line identities against the same frozen boundary read.
       Earlier text covered by an end line is not automatically that turn's. *)
    let boundaries = List.fold_left (fun acc (line, decoded) ->
      match decoded with Ok record -> Line_map.add line record acc | Error _ -> acc)
      Line_map.empty lines in
    let digest_at = Window.atom_opening_digest messages in
    let _, _, _, selected_messages_rev, observations_rev, historical_rev =
      List.fold_left
        (fun (prev_end, message_count, tool_count, messages_rev, observations_rev, historical_rev) step ->
           match step with
           | Atoms { line; end_atom; _ } ->
             (match atom with
              | None -> prev_end, message_count, tool_count, messages_rev, observations_rev, historical_rev
              | Some (range, _, _, _, _) ->
                let scopes = Historical.atom_spans ~trace_id ~digest_at
                    ~start_atom:prev_end ~end_atom ~boundary:(Line_map.find_opt line boundaries) in
                let message_count, tool_count, messages_rev, observations_rev, historical_rev =
                  List.fold_left (fun (count, tool_count, messages_rev, observations_rev, contexts) scope ->
                    let slice = match scope.Historical.source with
                      | Historical.Atom_span {start_atom;end_atom;_} ->
                        R.slice messages {range with R.start_atom;end_atom}
                      | Historical.Boundary_only | Historical.Official_turn -> [] in
                    let after_message = count + List.length slice in
                    let observations = tool_observations slice in
                    let after_tool_observation = tool_count + List.length observations in
                    let context : Historical.t = {scope;first_message=count;after_message;
                      first_tool_observation=tool_count;after_tool_observation} in
                    after_message, after_tool_observation, List.rev_append slice messages_rev,
                    List.rev_append observations observations_rev, context :: contexts)
                    (message_count, tool_count, messages_rev, observations_rev, historical_rev) scopes in
                end_atom, message_count, tool_count, messages_rev, observations_rev, historical_rev)
           | Official { R.line; turn_ref; _ } ->
             let official_trace = Ids.Turn_ref.trace_id turn_ref in
             let of_trace =
               match String_map.find_opt official_trace fragments with
               | Some lines -> lines
               | None -> [] in
             let count, after_tools, messages_rev, observations_rev =
               List.fold_left
                 (fun (count, tools, messages_rev, observations_rev) fragment ->
                    match fragment with
                    | Keeper_turn_fragments.Message { message; _ } ->
                      count + 1, tools, message :: messages_rev, observations_rev
                    | Keeper_turn_fragments.Tool_observation { observation; _ } ->
                      count, tools + 1, messages_rev, observation :: observations_rev)
                 (message_count, tool_count, messages_rev, observations_rev)
                 (Keeper_turn_fragments.of_turn turn_ref of_trace) in
             let attribution = match Line_map.find_opt line boundaries with
               | Some {B.event=B.Turn_ended {turn_ref;task_context;_};_} ->
                 Historical.Observed {turn_ref;task_context}
               | Some { B.event = B.History_restarted _; _ } | None ->
                 Historical.Unattributed in
             let context : Historical.t =
               {scope={source=Historical.Official_turn;attribution};
                first_message=message_count;after_message=count;
                first_tool_observation=tool_count;after_tool_observation=after_tools} in
             prev_end, count, after_tools, messages_rev, observations_rev, context :: historical_rev)
        (start_atom, 0, 0, [], [], []) steps
    in
    let historical_task_contexts = List.rev historical_rev in
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
          ; unread_messages = []
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
         refusal stands: the pass stops without advancing and the operator
         sees [Counterpart_interval_non_monotone]. An official line read
         later moves the official cursor and lifts it; while an official stop
         holds those lines (RFC §4.10) none is read, so only a range that ends
         after that stamp, or a purge of the keeper, lifts it. Within one trace
         the inversion says the position and its boundary disagree. Without
         new external admissions it stops as before. Newly appended external
         evidence is independently ordered and can be consumed even when this
         chat-time interval is empty. *)
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
      let* counterpart_observations, external_through =
        Domain_pool_ref.submit_io_or_inline (fun () ->
          Keeper_librarian_input_sources.counterpart_observations_from
            ~external_after:(Keeper_external_read_cursor.offset external_cursor)
            ~base_dir:config.Workspace.base_path ~keeper_name ~after ~before:ended_at)
        |> Result.map_error (fun error -> Counterpart_observations_unreadable error) in
      let* () =
        match after with
        | Some after when after > ended_at && not inverted_by_the_carried_bound_alone
            && external_through = Keeper_external_read_cursor.offset external_cursor ->
          Error (Counterpart_interval_non_monotone { after; before = ended_at })
        | None | Some _ -> Ok ()
      in
      let* () = Domain_pool_ref.submit_io_or_inline (fun () ->
        Keeper_external_read_cursor.prepare ~memory_keepers_dir ~runtime_keepers_dir ~keeper_name external_cursor
          ~through:external_through ~atom:atom_next ~official:official_range_id)
        |> Result.map_error cursor_error in
      let input : Keeper_librarian.input =
        { turn_ref
        ; keeper_id
        (* Current queue context is separate from the selected turns' admission
           evidence; neither uses the batch's final turn to label earlier text. *)
        ; historical_task_contexts
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
      let result = commit ~expected_revision ~range_id:atom_next ~official_range_id input in
      let result = match result, message_floor with
        | Memory_refused reports, Runtime_message_floor cli_runner
            when input.messages <> [] && Keeper_librarian_runtime.may_descend_messages reports ->
          (match atom, atom_next, official_lines, official_range_id, steps with
           | None, None, [selected], Some range, _ ->
             official_message_floor ?cli_runner ~config ~keeper_name ~lines ~progress ~official_cursor
               ~fragments ~selected ~range ~external_cursor ~external_through reports input
           | Some (selected_range,_,_,_,_), Some range, [], None, [_] ->
             checkpoint_message_floor ?cli_runner ~config ~keeper_name ~lines ~progress ~official_cursor
               ~selection_progress ~messages ~selected_range ~range ~external_cursor ~external_through reports input
           | (None | Some _), (None | Some _), ([] | _::_), (None | Some _), ([] | _::_) -> result)
        | (Memory_committed | Memory_refused _), (No_message_floor | Runtime_message_floor _) -> result in
      match result with
      | Memory_refused reports -> Ok (Memory_not_committed reports)
      | Memory_committed ->
        let* _ = Domain_pool_ref.submit_io_or_inline (fun () ->
          Keeper_memory_os_current.committed_unread_messages
            ~keepers_dir:memory_keepers_dir ~keeper_id:keeper_name)
          |> Result.map_error (fun detail -> Memory_snapshot_unreadable detail) in
        let* () = Domain_pool_ref.submit_io_or_inline (fun () ->
          Keeper_external_read_cursor.acknowledge ~runtime_keepers_dir ~keeper_name)
          |> Result.map_error cursor_error in
        advance ())
;;

let consume_one_with_progress_writer_and_floor
      ~write_progress_store
      ~write_official_progress_store
      ~config
      ~keeper_name
      ~commit
      ~message_floor
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
      ~message_floor
      ~config
      ~keeper_name
      ~commit
  in
  (match result, extent with
   | Ok (Nothing_to_read | Baseline_advanced _), _
   | Ok (Progress_advanced _ | Official_advanced _), R.All_unread -> clear_failed key
   (* Returned only when the atom side has nothing to read: the atom backlog
      is empty, and the official stop is no wide range that failed. Keeping
      the marker would narrow every later pass to one turn for good. *)
   | Error (Official_range_stopped _), _ -> clear_failed key
   | (Ok (Progress_advanced _ | Official_advanced _), R.To_first_cut_point)
   | (Ok (Memory_not_committed _), _) | (Error (Keeper_meta_absent), _)
   | (Error (Keeper_meta_unreadable _), _) | (Error (Boundary_log_unreadable _), _)
   | (Error (Progress_unreadable _), _) | (Error (Checkpoint_unreadable _), _)
   | (Error (Position_in_other_trace _), _) | (Error (Position_not_in_history _), _)
   | (Error (Range_stopped _), _) | (Error (Range_end_boundary_missing _), _)
   | (Error (Progress_boundary_missing _), _) | (Error (Memory_snapshot_unreadable _), _)
   | (Error (Counterpart_interval_non_monotone _), _)
   | (Error (Counterpart_observations_unreadable _), _) | (Error (Progress_write_failed _), _)
   | (Error (Official_progress_unreadable _), _) | (Error (Official_progress_write_failed _), _)
   | (Error (Official_progress_boundary_missing _), _)
   | (Error (Committed_official_range_mismatch), _) | (Error (Fragment_store_unreadable _), _)
   | (Error (Fragment_line_unreadable _), _) -> ());
  result
;;

let consume_one ~config ~keeper_name ~commit =
  consume_one_with_progress_writer_and_floor
    ~write_progress_store:P.write
    ~write_official_progress_store:O.write
    ~config
    ~keeper_name
    ~commit
    ~message_floor:No_message_floor
;;

let consume_one_with_progress_writer ~write_progress_store ~write_official_progress_store
    ~config ~keeper_name ~commit =
  consume_one_with_progress_writer_and_floor ~write_progress_store ~write_official_progress_store
    ~config ~keeper_name ~commit ~message_floor:No_message_floor
;;

let commit_with_runtime_runner
      ?cli_runner
      ~base_path
      ~keepers_dir
      ~keeper_id
      ~expected_revision
      ~range_id
      ~official_range_id
      input
  =
  let committed = ref false and reports = ref [] in
  Keeper_librarian_runtime.run_best_effort
    ?cli_runner
    ~on_memory_committed:(fun () -> committed := true)
    ~on_not_committed:(fun report -> reports := report :: !reports)
    ?durable_range_id:range_id
    ?official_range_id
    ~base_path
    ~keepers_dir
    ~keeper_id
    ~expected_revision
    input;
  if !committed then Memory_committed else Memory_refused (List.rev !reports)
;;

let commit_with_runtime ~base_path ~keepers_dir ~keeper_id ~expected_revision ~range_id
    ~official_range_id input =
  commit_with_runtime_runner ~base_path ~keepers_dir ~keeper_id ~expected_revision ~range_id
    ~official_range_id input
;;

let consume_one_with_runtime_and_progress_writers ?cli_runner ~write_progress_store
    ~write_official_progress_store ~config ~keeper_name () =
  let base_path = config.Workspace.base_path in
  let keepers_dir = Config_dir_resolver.keepers_dir_for_base_path ~base_path in
  let commit ~expected_revision ~range_id ~official_range_id input =
    commit_with_runtime_runner ?cli_runner ~base_path ~keepers_dir ~keeper_id:keeper_name
      ~expected_revision ~range_id ~official_range_id input in
  consume_one_with_progress_writer_and_floor ~write_progress_store ~write_official_progress_store
    ~config ~keeper_name ~commit ~message_floor:(Runtime_message_floor cli_runner)
;;

let consume_one_with_runtime ?cli_runner ~config ~keeper_name () =
  consume_one_with_runtime_and_progress_writers ?cli_runner ~write_progress_store:P.write
    ~write_official_progress_store:O.write ~config ~keeper_name ()
;;

module For_testing = struct
  let consume_one_with_progress_writer = consume_one_with_progress_writer
  let consume_one_with_runtime_and_progress_writers = consume_one_with_runtime_and_progress_writers

  let reset_process_state () =
    Stdlib.Mutex.protect failed_ranges_mu (fun () -> Hashtbl.clear failed_ranges)
  ;;
end
