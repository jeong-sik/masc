(* Dashboard read model for autonomous keeper turns. Turn identity is
   producer-owned in Turn_record and is used only to address/dedupe this
   projection; durable semantic continuity comes from the Keeper checkpoint.
   The exact raw trace supplies the final response and a content-free activity
   projection for that recorded AGENT_CORE run. *)

type turn =
  { turn_id : string
  ; started_at : float
  ; final_text : string option
  ; trace : Keeper_chat_blocks.trace_step list
  }

let default_limit = Keeper_raw_trace_retention.history_limit

let agent_core_run_ref (run_ref : Turn_record.raw_trace_run_ref) : Agent_core.Raw_trace.run_ref =
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

type raw_trace_identity_mismatch =
  | Runtime_agent_name_mismatch
  | Session_id_mismatch

let check_raw_trace_identity
      (run_ref : Turn_record.raw_trace_run_ref)
      (records : Agent_core.Raw_trace.record list)
  =
  let rec loop = function
    | [] -> Ok ()
    | (record : Agent_core.Raw_trace.record) :: rest ->
      if not (String.equal record.agent_name run_ref.agent_name)
      then Error Runtime_agent_name_mismatch
      else (
        match record.session_id with
        | Some session_id when String.equal session_id run_ref.session_id -> loop rest
        | Some _ | None -> Error Session_id_mismatch)
  in
  loop records
;;

let trace_step_of_trajectory = function
  | Agent_core.Trajectory.Think { ts; _ } ->
    (* RFC-0358 §2 admits the step and its timestamp, not the reasoning. The
       flag carries that fact; the label a reader shows for it belongs to the
       reader, not to this projection. *)
    Some
      (Keeper_chat_blocks.Trace_think
         { text = ""
         ; content_withheld = true
         ; ts = Some (Masc_domain.iso8601_of_unix_seconds ts)
         ; agent_core_block_index = None
         })
  | Agent_core.Trajectory.Act { tool_call; _ } ->
    let status =
      match tool_call.finished_at, tool_call.is_error with
      | None, _ -> Some Keeper_chat_blocks.Trace_tool_pending
      | Some _, true -> Some Keeper_chat_blocks.Trace_tool_err
      | Some _, false -> Some Keeper_chat_blocks.Trace_tool_ok
    in
    let dur =
      Option.map
        (fun finished_at ->
          let elapsed_ms =
            max 0
              (int_of_float
                 (((finished_at -. tool_call.started_at) *. 1000.) +. 0.5))
          in
          Printf.sprintf "%dms" elapsed_ms)
        tool_call.finished_at
    in
    Some
      (Keeper_chat_blocks.Trace_tool
         { name = tool_call.tool_name
         ; tool_call_id = None
         ; execution_id = None
         ; status
         ; dur
         ; args = None
         ; result = None
         ; ts =
             Some
               (Masc_domain.iso8601_of_unix_seconds tool_call.started_at)
         ; agent_core_block_index = None
         })
  | Agent_core.Trajectory.Observe _ | Agent_core.Trajectory.Respond _ -> None
;;

(* Terminal-failure cache for exact run reads. Two read failures are
   permanent and cached per (path, run):

   - Version mismatch: the trace format is a hard cut, so files written
     with an earlier trace_version are never migrated or rewritten.
   - Missing file: a run reference is derived from the trace sink after
     the run finished, so the file existed before the record cited it.
     Deletion afterwards is one-way -- the v4 hard-cut cleanup and
     retention pruning both remove without restoring -- so a missing
     referenced file never comes back either.

   Without the cache, every dashboard poll re-reads the same rejected
   file and replays the same warning (16,128 WARN/day on 2026-08-27 for
   the version arm; 4,157/hour on 2026-08-28 for the missing arm after
   the hard-cut cleanup deleted pre-cut keeper traces whose turn records
   remained). Healable failures (I/O errors) stay uncached. *)
let version_rejected_runs : (string, unit) Hashtbl.t = Hashtbl.create 64
let missing_trace_runs : (string, unit) Hashtbl.t = Hashtbl.create 64

let turn_of_record ~config ~keeper_name (record : Turn_record.t) =
  match record.turn_kind, record.raw_trace_run_ref with
  | Turn_record.Direct, _ -> None
  | Turn_record.Autonomous, None -> None
  | Turn_record.Autonomous, Some run_ref ->
    let dir = Keeper_types_support.keeper_raw_trace_dir config keeper_name in
    let cache_key = run_ref.path ^ "\000" ^ run_ref.worker_run_id in
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
        if Hashtbl.mem missing_trace_runs cache_key then None
        else (
          Hashtbl.replace missing_trace_runs cache_key ();
          Log.Keeper.warn ~keeper_name
            "autonomous turn source: exact raw-trace file is missing or non-regular: %s"
            run_ref.path;
          None)
      | Current_regular_file ->
        if
          Hashtbl.mem version_rejected_runs cache_key
          || Hashtbl.mem missing_trace_runs cache_key
        then None
        else
          (match Agent_core.Raw_trace_query.read_run (agent_core_run_ref run_ref) with
           | Error (Agent_core.Error.Serialization
                      (Agent_core.Error.VersionMismatch _) as err) ->
             Hashtbl.replace version_rejected_runs cache_key ();
             Log.Keeper.warn ~keeper_name
               "autonomous turn source: cannot read exact run %s: %s"
               run_ref.worker_run_id
               (Agent_core.Error.to_string err);
             None
           | Error err ->
             Log.Keeper.warn ~keeper_name
               "autonomous turn source: cannot read exact run %s: %s"
               run_ref.worker_run_id
               (Agent_core.Error.to_string err);
             None
           | Ok [] ->
             Log.Keeper.warn ~keeper_name
               "autonomous turn source: exact run %s has no records"
               run_ref.worker_run_id;
             None
           | Ok ((first : Agent_core.Raw_trace.record) :: _ as records) ->
             (match check_raw_trace_identity run_ref records with
              | Error Runtime_agent_name_mismatch ->
                Log.Keeper.warn ~keeper_name
                  "autonomous turn source: exact run %s has a mismatched AGENT_CORE runtime identity"
                  run_ref.worker_run_id;
                None
              | Error Session_id_mismatch ->
                Log.Keeper.warn ~keeper_name
                  "autonomous turn source: exact run %s has a mismatched session identity"
                  run_ref.worker_run_id;
                None
              | Ok () ->
                let final_text =
                  records
                  |> List.rev
                  |> List.find_opt (fun (row : Agent_core.Raw_trace.record) ->
                    row.record_type = Agent_core.Raw_trace.Run_finished)
                  |> Option.map (fun (row : Agent_core.Raw_trace.record) ->
                    row.final_text)
                  |> Option.join
                in
                let trace =
                  Agent_core.Trajectory.of_raw_trace_records records
                  |> fun trajectory -> trajectory.steps
                  |> List.filter_map trace_step_of_trajectory
                in
                Some
                  { turn_id = Ids.Turn_ref.to_string record.turn_ref
                  ; started_at = first.ts
                  ; final_text
                  ; trace
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
