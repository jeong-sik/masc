module B = Keeper_turn_boundaries
module P = Keeper_librarian_progress
module R = Keeper_librarian_range
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
  | Memory_snapshot_unreadable of string
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
  | Memory_snapshot_unreadable detail ->
    "current Memory OS snapshot is unreadable: " ^ detail
  | Progress_write_failed error -> P.write_error_to_string error
;;

let turn_boundary_for_position ~trace_id ~end_atom ~last_atom_digest lines =
  List.filter_map
    (fun (_, decoded) ->
       match decoded with
       | Error _ -> None
       | Ok ({ B.event = B.History_restarted _; _ } : B.record) -> None
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
         then Some (recorded_at, turn_ref)
         else None
       | Ok
           { B.event =
               B.Turn_ended
                 { turn_ref = _
                 ; history_at_start = _
                 ; position = B.Empty_atom_history | B.No_atom_history | B.Stale_noop
                 }
           ; _
           } -> None)
    lines
  |> List.sort (fun (left, _) (right, _) -> Float.compare right left)
  |> List.hd_opt
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

let write_progress ~keepers_dir ~keeper_name progress outcome =
  match
    Domain_pool_ref.submit_io_or_inline (fun () ->
      P.write ~keepers_dir ~keeper_id:keeper_name progress)
  with
  | Ok () -> Ok (outcome progress)
  | Error error -> Error (Progress_write_failed error)
;;

let consume_one ~config ~keeper_name ~commit =
  let ( let* ) = Result.bind in
  let* meta =
    match
      Domain_pool_ref.submit_io_or_inline (fun () ->
        Keeper_meta_store.read_meta config keeper_name)
    with
    | Ok (Some meta) -> Ok meta
    | Ok None -> Error Keeper_meta_absent
    | Error detail -> Error (Keeper_meta_unreadable detail)
  in
  let trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id in
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
  let session_dir = Filename.concat (Keeper_fs.session_store_path config) trace_id in
  let* checkpoint =
    Domain_pool_ref.submit_io_or_inline (fun () ->
      Keeper_checkpoint_store.load_agent_core ~session_dir ~session_id:trace_id)
    |> Result.map_error (fun error -> Checkpoint_unreadable error)
  in
  let messages = checkpoint.Agent_core.Checkpoint.messages in
  let selection = R.select ~trace_id ~lines ~progress ~messages R.All_unread in
  match selection with
  | R.Nothing_to_read -> Ok Nothing_to_read
  | R.Position_in_other_trace position -> Error (Position_in_other_trace position)
  | R.Stop stop -> Error (Range_stopped stop)
  | R.Baseline _ ->
    (match R.progress_after ~trace_id selection with
     | None -> Ok Nothing_to_read
     | Some next ->
       write_progress
         ~keepers_dir:runtime_keepers_dir
         ~keeper_name
         next
         (fun progress -> Baseline_advanced progress))
  | R.Read { range; boundary_lines_seen = _ } ->
    let* ended_at, turn_ref =
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
    let after =
      match progress with
      | None -> None
      | Some { P.position; boundary_lines_seen = _ } ->
        turn_boundary_for_position
          ~trace_id:position.trace_id
          ~end_atom:position.end_atom
          ~last_atom_digest:position.last_atom_digest
          lines
        |> Option.map fst
    in
    let selected_messages = R.slice messages range in
    let* current, expected_revision = current_memory ~keepers_dir:memory_keepers_dir ~keeper_name in
    let input : Keeper_librarian.input =
      { turn_ref
      ; goal_context =
          Keeper_librarian_input_sources.goal_context_for_task
            ~config
            meta.current_task_id
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
      ; counterpart_observations =
          Keeper_librarian_input_sources.counterpart_observations_between_offloaded
            ~base_dir:config.Workspace.base_path
            ~keeper_name
            ~after
            ~before:ended_at
      }
    in
    if not (commit ~expected_revision input)
    then Ok Memory_not_committed
    else (
      match R.progress_after ~trace_id selection with
      | None -> Ok Memory_not_committed
      | Some next ->
        write_progress
          ~keepers_dir:runtime_keepers_dir
          ~keeper_name
          next
          (fun progress -> Progress_advanced progress))
;;

let commit_with_runtime ~base_path ~keepers_dir ~keeper_id ~expected_revision input =
  let committed = ref false in
  Keeper_librarian_runtime.run_best_effort
    ~trigger:Keeper_librarian_runtime.Queue_changed
    ~input_projection:Keeper_librarian_runtime.Already_selected_range
    ~on_memory_committed:(fun () -> committed := true)
    ~base_path
    ~keepers_dir
    ~keeper_id
    ~expected_revision
    input;
  !committed
;;
