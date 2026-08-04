(* Public dashboard read model for autonomous keeper turns. Turn identity is
   producer-owned in Turn_record; raw traces supply only the final public
   response for that exact recorded OAS run. *)

type turn =
  { turn_id : string
  ; agent_name : string
  ; generation : int
  ; started_at : float
  ; finished_at : float option
  ; model : string option
  ; stop_reason : string option
  ; final_text : string option
  }

let default_limit = 200

let sdk_run_ref (run_ref : Turn_record.raw_trace_run_ref) : Agent_sdk.Raw_trace.run_ref =
  { worker_run_id = run_ref.worker_run_id
  ; path = run_ref.path
  ; start_seq = run_ref.start_seq
  ; end_seq = run_ref.end_seq
  ; agent_name = run_ref.agent_name
  ; session_id = Some run_ref.session_id
  }
;;

type trace_file_check =
  | Current_regular_file
  | Outside_keeper_store
  | Missing_or_non_regular

let check_trace_file ~dir path =
  if
    not
      (String.equal (Filename.dirname path) dir
       && Filename.check_suffix path Keeper_types_support.raw_trace_file_extension)
  then Outside_keeper_store
  else
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_REG; _ } -> Current_regular_file
    | _ -> Missing_or_non_regular
    | exception Unix.Unix_error _ -> Missing_or_non_regular
;;

let turn_of_record ~config ~keeper_name (record : Turn_record.t) =
  match record.turn_kind, record.raw_trace_run_ref with
  | Turn_record.Direct, _ -> None
  | Turn_record.Autonomous, None ->
    Log.Keeper.warn ~keeper_name
      "autonomous turn source: current turn record %s has no exact raw-trace run"
      (Ids.Turn_ref.to_string record.turn_ref);
    None
  | Turn_record.Autonomous, Some run_ref ->
    let dir = Keeper_types_support.keeper_raw_trace_dir config keeper_name in
    if not (String.equal record.keeper keeper_name)
    then (
      Log.Keeper.warn ~keeper_name
        "autonomous turn source: record %s belongs to keeper %s"
        (Ids.Turn_ref.to_string record.turn_ref)
        record.keeper;
      None)
    else
      match check_trace_file ~dir run_ref.path with
      | Outside_keeper_store ->
        Log.Keeper.warn ~keeper_name
          "autonomous turn source: rejected raw-trace path outside keeper store: %s"
          run_ref.path;
        None
      | Missing_or_non_regular ->
        Log.Keeper.warn ~keeper_name
          "autonomous turn source: exact raw-trace file is missing or non-regular: %s"
          run_ref.path;
        None
      | Current_regular_file ->
        (match Agent_sdk.Raw_trace_query.summarize_run (sdk_run_ref run_ref) with
         | Error err ->
           Log.Keeper.warn ~keeper_name
             "autonomous turn source: cannot summarize exact run %s: %s"
             run_ref.worker_run_id
             (Agent_sdk.Error.to_string err);
           None
         | Ok summary ->
           (match summary.started_at with
            | None ->
              Log.Keeper.warn ~keeper_name
                "autonomous turn source: exact run %s has no start timestamp"
                run_ref.worker_run_id;
              None
            | Some started_at ->
              Some
                { turn_id = Ids.Turn_ref.to_string record.turn_ref
                ; agent_name = record.agent_name
                ; generation = record.generation
                ; started_at
                ; finished_at = summary.finished_at
                ; model = record.model
                ; stop_reason = record.finish_reason
                ; final_text = summary.final_text
                }))
;;

let load_recent ~config ~keeper_name ?(limit = default_limit) ?since () =
  let store = Keeper_types_support.keeper_turn_record_store config keeper_name in
  match Dated_jsonl.read_recent_result store (max 1 limit) with
  | Error error ->
    Log.Keeper.warn ~keeper_name
      "autonomous turn source: cannot read current turn-record store: %s"
      (Dated_jsonl.read_error_to_string error);
    []
  | Ok entries ->
    entries
    |> List.filter_map (function
      | Dated_jsonl.Malformed_json { path; line_number; detail } ->
        Log.Keeper.warn ~keeper_name
          "autonomous turn source: malformed current turn record path=%s line=%s: %s"
          path
          (Option.fold ~none:"unknown" ~some:string_of_int line_number)
          detail;
        None
      | Dated_jsonl.Parsed json ->
        (match Turn_record.of_json json with
         | Ok record -> turn_of_record ~config ~keeper_name record
         | Error error ->
           Log.Keeper.warn ~keeper_name
             "autonomous turn source: incompatible current turn record skipped: %s"
             error;
           None))
    |> List.filter (fun turn ->
      match since with
      | Some cutoff -> Float.compare turn.started_at cutoff > 0
      | None -> true)
    |> List.stable_sort (fun left right -> Float.compare left.started_at right.started_at)
;;
