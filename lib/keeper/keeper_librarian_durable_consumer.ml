module B = Keeper_turn_boundaries
module P = Keeper_librarian_progress
module R = Keeper_librarian_range
module Window = Runtime_model_input_tail_window
module Canonical_tool = Agent_core.Canonical_tool
module String_map = Map.Make (String)

type outcome =
  | Nothing_to_read
  | Baseline_advanced of P.t
  | Memory_not_committed
  | Progress_advanced of P.t

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

let range_id_for_selection
      ~trace_id
      ~(range : R.range)
      ~end_boundary_line
      ~boundary_lines_seen
  : Keeper_memory_os_current.durable_range_id
  =
  { trace_id
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

let endpoint_is_present range_id ~messages lines =
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

let consume_one_with_extent ~write_progress_store ~extent ~config ~keeper_name ~commit =
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
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
  if not (R.may_have_unread ~trace_id ~lines ~progress)
  then Ok Nothing_to_read
  else
  let session_dir = Filename.concat (Keeper_fs.session_store_path config) trace_id in
  let* checkpoint =
    Domain_pool_ref.submit_io_or_inline (fun () ->
      Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:trace_id)
    |> Result.map_error (fun error -> Checkpoint_unreadable error)
  in
  let messages = checkpoint.Agent_core.Checkpoint.messages in
  let selection = R.select ~trace_id ~lines ~progress ~messages extent in
  match selection with
  | R.Nothing_to_read -> Ok Nothing_to_read
  | R.Position_in_other_trace position -> Error (Position_in_other_trace position)
  | R.Stop stop -> Error (Range_stopped stop)
  | R.Baseline _ ->
    (match R.progress_after ~trace_id selection with
     | None -> Ok Nothing_to_read
     | Some next ->
       write_progress
         ~write:write_progress_store
         ~keepers_dir:runtime_keepers_dir
         ~keeper_name
         next
         (fun progress -> Baseline_advanced progress))
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
    let selected_range_id =
      range_id_for_selection
        ~trace_id
        ~range
        ~end_boundary_line
        ~boundary_lines_seen
    in
    let* committed_range =
      Keeper_memory_os_current.committed_durable_range
        ~keepers_dir:memory_keepers_dir
        ~keeper_id:keeper_name
      |> Result.map_error (fun detail -> Memory_snapshot_unreadable detail)
    in
    (match committed_range with
     | Some committed
       when is_committed_prefix
              committed
              ~trace_id
              ~selected:range
              ~selected_end_boundary_line:end_boundary_line
              ~selected_boundary_lines_seen:boundary_lines_seen
              ~messages
              lines ->
      let next = progress_of_range_id committed in
      write_progress
        ~write:write_progress_store
        ~keepers_dir:runtime_keepers_dir
        ~keeper_name
        next
        (fun progress -> Progress_advanced progress)
     | Some _ | None ->
    let* after =
      match progress with
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
         | Some (_, recorded_at, _) -> Ok (Some recorded_at)
         | None -> Error (Progress_boundary_missing position))
    in
    let selected_messages = R.slice messages range in
    let* current, expected_revision = current_memory ~keepers_dir:memory_keepers_dir ~keeper_name in
    let* () =
      match after with
      | Some after when after >= ended_at ->
        Error (Counterpart_interval_non_monotone { after; before = ended_at })
      | None | Some _ -> Ok ()
    in
    let* counterpart_observations =
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
      ; tool_observations = tool_observations selected_messages
      ; counterpart_observations
      }
    in
    if not (commit ~expected_revision ~range_id:selected_range_id input)
    then Ok Memory_not_committed
    else
      write_progress
        ~write:write_progress_store
        ~keepers_dir:runtime_keepers_dir
        ~keeper_name
        (progress_of_range_id selected_range_id)
        (fun progress -> Progress_advanced progress))
;;

let consume_one_with_progress_writer ~write_progress_store ~config ~keeper_name ~commit =
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
      ~extent
      ~config
      ~keeper_name
      ~commit
  in
  (match result, extent with
   | Ok (Nothing_to_read | Baseline_advanced _), _
   | Ok (Progress_advanced _), R.All_unread -> clear_failed key
   | Ok (Progress_advanced _), R.To_first_cut_point
   | Ok Memory_not_committed, _
   | Error _, _ -> ());
  result
;;

let consume_one ~config ~keeper_name ~commit =
  consume_one_with_progress_writer
    ~write_progress_store:P.write
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
      input
  =
  let committed = ref false in
  Keeper_librarian_runtime.run_best_effort
    ~trigger:Keeper_librarian_runtime.Durable_range
    ~input_projection:Keeper_librarian_runtime.Already_selected_range
    ~on_memory_committed:(fun () -> committed := true)
    ~durable_range_id:range_id
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
