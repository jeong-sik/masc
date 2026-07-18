(** Runtime trace trajectory helpers for keeper dashboard API. *)

let trajectory_line_to_chat_trace_step = function
  | Trajectory.Thinking entry ->
    let text =
      match entry.block with
      | Agent_sdk.Types.Thinking { content; _ } -> content
      | Agent_sdk.Types.ReasoningDetails { reasoning_content; details } ->
          Agent_sdk.Types.reasoning_details_text ~reasoning_content ~details
      | Agent_sdk.Types.RedactedThinking _ -> "[redacted]"
      | _ ->
          invalid_arg
            "Trajectory.Thinking contained a non-reasoning OAS content block"
    in
    Some
      (Keeper_chat_blocks.Trace_think
         { text
         ; ts = Some entry.ts_iso
         ; oas_block_index = Some entry.block_index
         })
  | Trajectory.Tool_call entry ->
    let result, status =
      match entry.outcome with
      | Trajectory.Tool_succeeded text ->
          ( Some
              (try Yojson.Safe.from_string text with
               | Yojson.Json_error _ -> `String text)
          , Keeper_chat_blocks.Trace_tool_ok )
      | Trajectory.Tool_failed _ -> None, Keeper_chat_blocks.Trace_tool_err
    in
    Some
      (Keeper_chat_blocks.Trace_tool
         { name = entry.tool_name
         ; tool_call_id = Some entry.execution_id
         ; status = Some status
         ; dur = Some (Printf.sprintf "%dms" entry.duration_ms)
         ; args = Some (`Assoc entry.arguments)
         ; result
         ; ts = Some entry.ts_iso
         ; oas_block_index = None
         })
;;

let allowed_trace_id_set trace_ids =
  List.fold_left
    (fun acc trace_id -> Set_util.StringSet.add trace_id acc)
    Set_util.StringSet.empty
    trace_ids
;;

let log_trajectory_read_observation ~trace_id
    (read : Trajectory.trajectory_lines_read_result) =
  if read.line_decode.invalid_line_count > 0 then
    Log.Keeper.warn
      "trajectory trace %s: %d rows failed the closed trajectory codec (%s)"
      trace_id
      read.line_decode.invalid_line_count
      (Trajectory.invalid_entry_counts_to_json read.line_decode.invalid_reasons
       |> Yojson.Safe.to_string);
  List.iter
    (fun (error : Trajectory.trajectory_read_error) ->
       Log.Keeper.error "trajectory trace %s: read failed for %s: %s"
         trace_id error.path error.message)
    read.io_errors
;;

let chat_trace_block_by_turn_ref ~max_lines
    ~(config : Workspace.config)
    ~(keeper_name : string)
    ~(allowed_trace_ids : string list)
  =
  let allowed_trace_ids = Json_util.dedupe_keep_order allowed_trace_ids in
  let allowed = allowed_trace_id_set allowed_trace_ids in
  let cache = Hashtbl.create (max 1 (List.length allowed_trace_ids)) in
  let masc_root = Workspace.masc_root_dir config in
  let lines_for_trace_id trace_id =
    if not (Set_util.StringSet.mem trace_id allowed)
    then None
    else (
      match Hashtbl.find_opt cache trace_id with
      | Some lines -> Some lines
      | None ->
        let trajectory_read =
          Trajectory.read_recent_lines_result ~masc_root ~keeper_name ~trace_id
            ~max_lines
        in
        log_trajectory_read_observation ~trace_id trajectory_read;
        let lines = trajectory_read.lines in
        Hashtbl.replace cache trace_id lines;
        Some lines)
  in
  fun turn_ref ->
    let trace_id = Ids.Turn_ref.trace_id turn_ref in
    match lines_for_trace_id trace_id with
    | None -> None
    | Some all_lines ->
      let absolute_turn = Ids.Turn_ref.absolute_turn turn_ref in
      let trace =
        all_lines
        |> List.filter (function
             | Trajectory.Thinking entry -> entry.turn = absolute_turn
             | Trajectory.Tool_call entry -> entry.turn = absolute_turn)
        |> List.filter_map trajectory_line_to_chat_trace_step
      in
      (match trace with
       | [] -> None
       | trace -> Some (Keeper_chat_blocks.Trace { trace }))
;;
