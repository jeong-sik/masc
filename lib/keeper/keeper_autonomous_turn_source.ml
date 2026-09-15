(* Dashboard read model for autonomous keeper turns. Turn identity is
   producer-owned in Turn_record and is used only to address/dedupe this
   projection; durable semantic continuity comes from the Keeper checkpoint.
   The exact raw trace supplies the final response and activity for that recorded
   AGENT_CORE run. Canonical execution identities join retained tool evidence;
   raw reasoning, inputs and results are not copied into this projection. *)

type turn =
  { turn_id : string
  ; started_at : float
  ; final_text : string option
  ; trace : Keeper_chat_blocks.trace_step list
  }

module Execution_map = Map.Make (String)
module Sequence_map = Map.Make (Int)
module Invocation_map = Map.Make (struct
  type t = int * int
  let compare = Stdlib.compare
end)

type execution_occurrence = {
  execution_id : Ids.Execution_id.t;
  tool_use_id : string option;
  tool_name : string option;
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

(* Parse the declared ledger rows once per Keeper turn. Duplicate canonical
   ids and conflicting invocation coordinates stay ambiguous. *)
let executions_for_turn (record : Turn_record.t) execution_rows =
  List.fold_left (fun index id ->
    match Execution_map.find_opt (Ids.Execution_id.to_string id) execution_rows with
    | Some [ row ] ->
      let str key = Json_util.get_string row key in
      let int key = Json_util.get_int row key in
      (match int "turn", int "planned_index" with
       | Some turn, Some planned_index when turn >= 0 && planned_index >= 0
           && str "record_kind" = Some "tool_call"
           && str "keeper" = Some record.keeper
           && str "trace_id" = Some record.trace_id
           && str "session_id" = Some record.trace_id
           && str "turn_kind" = Some (Turn_record.turn_kind_to_string Turn_record.Autonomous)
           && int "keeper_turn_id" = Some record.absolute_turn ->
         let occurrence = { execution_id = id;
           tool_use_id = str "tool_use_id"; tool_name = str "tool" } in
         Invocation_map.update (turn, planned_index)
           (function None -> Some [ occurrence ] | Some rows -> Some (occurrence :: rows)) index
       | _ -> index)
    | Some _ | None -> index)
    Invocation_map.empty record.execution_ids
;;

(* What one exact run says before the execution ledger is joined. A tool step
   keeps only what the dashboard row shows, and the raw start row's
   invocation coordinates when that row is the only one at them. *)
type run_invocation =
  { invocation_turn : int
  ; invocation_planned_index : int
  ; raw_tool_use_id : string option
  ; raw_tool_name : string option
  }

type run_tool =
  { tool_name : string
  ; tool_started_at : float
  ; tool_finished_at : float option
  ; tool_is_error : bool
  ; invocation : run_invocation option
  }

type run_step =
  | Run_think of float
  | Run_tool of run_tool

type run_reading =
  | Run_projected of
      { run_started_at : float
      ; run_final_text : string option
      ; steps : run_step list
      }
  | Run_has_no_records
  | Run_identity_mismatch of raw_trace_identity_mismatch

(* The exact raw start sequence addresses the invocation; neither provider id
   reuse nor coincident names/timestamps can choose a different execution. *)
let invocation_of_call ~(records : Agent_core.Raw_trace.record list Sequence_map.t)
    ~raw_occurrences (call : Agent_core.Trajectory.tool_call) =
  match call.source_seq with
  | None -> None
  | Some seq ->
    (match Sequence_map.find_opt seq records with
     | Some [ raw ] when raw.record_type = Agent_core.Raw_trace.Tool_execution_started ->
       (match raw.tool_turn, raw.tool_planned_index with
        | Some turn, Some planned_index ->
          (match Invocation_map.find_opt (turn, planned_index) raw_occurrences with
           | Some 1 ->
             Some
               { invocation_turn = turn
               ; invocation_planned_index = planned_index
               ; raw_tool_use_id = raw.tool_use_id
               ; raw_tool_name = raw.tool_name
               }
           | Some _ | None -> None)
        | Some _, None | None, Some _ | None, None -> None)
     | Some _ | None -> None)
;;

let execution_of_invocation ~executions = function
  | None -> None
  | Some invocation ->
    (match
       Invocation_map.find_opt
         (invocation.invocation_turn, invocation.invocation_planned_index)
         executions
     with
     | Some [ occurrence ]
       when occurrence.tool_use_id = invocation.raw_tool_use_id
            && occurrence.tool_name = invocation.raw_tool_name ->
       Some occurrence.execution_id
     | Some _ | None -> None)
;;

let run_step_of_trajectory ~records ~raw_occurrences = function
  | Agent_core.Trajectory.Think { ts; _ } -> Some (Run_think ts)
  | Agent_core.Trajectory.Act { tool_call; _ } ->
    Some
      (Run_tool
         { tool_name = tool_call.tool_name
         ; tool_started_at = tool_call.started_at
         ; tool_finished_at = tool_call.finished_at
         ; tool_is_error = tool_call.is_error
         ; invocation = invocation_of_call ~records ~raw_occurrences tool_call
         })
  | Agent_core.Trajectory.Observe _ | Agent_core.Trajectory.Respond _ -> None
;;

let trace_step_of_run_step ~executions = function
  | Run_think ts ->
    (* RFC-0358 §2 admits the step and its timestamp, not the reasoning. The
       flag carries that fact; the label a reader shows for it belongs to the
       reader, not to this projection. *)
    Keeper_chat_blocks.Trace_think
      { text = ""
      ; content_withheld = true
      ; ts = Some (Masc_domain.iso8601_of_unix_seconds ts)
      ; agent_core_block_index = None
      }
  | Run_tool tool ->
    let status =
      match tool.tool_finished_at, tool.tool_is_error with
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
                 (((finished_at -. tool.tool_started_at) *. 1000.) +. 0.5))
          in
          Printf.sprintf "%dms" elapsed_ms)
        tool.tool_finished_at
    in
    Keeper_chat_blocks.Trace_tool
      { name = tool.tool_name
      ; tool_call_id = None
      ; execution_id = execution_of_invocation ~executions tool.invocation
      ; status
      ; dur
      ; args = None
      ; result = None
      ; ts = Some (Masc_domain.iso8601_of_unix_seconds tool.tool_started_at)
      ; agent_core_block_index = None
      }
;;

let reading_of_records ~keeper_name (run_ref : Turn_record.raw_trace_run_ref) = function
  | [] ->
    Log.Keeper.warn ~keeper_name
      "autonomous turn source: exact run %s has no records"
      run_ref.worker_run_id;
    Run_has_no_records
  | (first : Agent_core.Raw_trace.record) :: _ as records ->
    (match check_raw_trace_identity run_ref records with
     | Error (Runtime_agent_name_mismatch as mismatch) ->
       Log.Keeper.warn ~keeper_name
         "autonomous turn source: exact run %s has a mismatched AGENT_CORE runtime identity"
         run_ref.worker_run_id;
       Run_identity_mismatch mismatch
     | Error (Session_id_mismatch as mismatch) ->
       Log.Keeper.warn ~keeper_name
         "autonomous turn source: exact run %s has a mismatched session identity"
         run_ref.worker_run_id;
       Run_identity_mismatch mismatch
     | Ok () ->
       let run_final_text =
         records
         |> List.rev
         |> List.find_opt (fun (row : Agent_core.Raw_trace.record) ->
           row.record_type = Agent_core.Raw_trace.Run_finished)
         |> Option.map (fun (row : Agent_core.Raw_trace.record) -> row.final_text)
         |> Option.join
       in
       let records_by_seq = List.fold_left
         (fun index (row : Agent_core.Raw_trace.record) ->
           Sequence_map.update row.seq (function None -> Some [ row ] | Some rows -> Some (row :: rows)) index)
         Sequence_map.empty records
       in
       let raw_occurrences = List.fold_left
         (fun index (row : Agent_core.Raw_trace.record) ->
           match row.record_type, row.tool_turn, row.tool_planned_index with
           | Agent_core.Raw_trace.Tool_execution_started, Some turn, Some planned_index ->
             Invocation_map.update (turn, planned_index)
               (function None -> Some 1 | Some count -> Some (count + 1)) index
           | _ -> index)
         Invocation_map.empty records
       in
       let steps =
         (Agent_core.Trajectory.of_raw_trace_records records).steps
         |> List.filter_map
              (run_step_of_trajectory ~records:records_by_seq ~raw_occurrences)
       in
       Run_projected { run_started_at = first.ts; run_final_text; steps })
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
   remained). Healable failures (I/O errors) stay uncached.

   The history read that uses them runs on the domain pool, so every table
   here is read and written under [run_tables_mutex]. *)
let version_rejected_runs : (string, unit) Hashtbl.t = Hashtbl.create 64
let missing_trace_runs : (string, unit) Hashtbl.t = Hashtbl.create 64

(* What a run said, by its reference, for as long as its file keeps the
   identity it had when read. A retained keeper holds hundreds of runs, and
   each history recompute parsed all of them again: 13 GB of a live server's
   allocation in four hours (2026-09-16), while a finished run's file does not
   change. Each keeper's table holds the runs its last read used and is
   replaced whole, never changed after it is installed. *)
type file_identity =
  { device : int
  ; inode : int
  ; size : int
  ; mtime : float
  }

type remembered_run =
  { identity : file_identity
  ; reading : run_reading
  }

let run_readings : (string, (string, remembered_run) Hashtbl.t) Hashtbl.t =
  Hashtbl.create 16

let run_tables_mutex = Stdlib.Mutex.create ()

let with_run_tables f = Stdlib.Mutex.protect run_tables_mutex f

let file_identity path =
  match Unix.stat path with
  | stats ->
    Some
      { device = stats.Unix.st_dev
      ; inode = stats.Unix.st_ino
      ; size = stats.Unix.st_size
      ; mtime = stats.Unix.st_mtime
      }
  | exception Unix.Unix_error _ -> None
;;

let file_identity_equal left right =
  Int.equal left.device right.device
  && Int.equal left.inode right.inode
  && Int.equal left.size right.size
  && Float.equal left.mtime right.mtime
;;

let run_key (run_ref : Turn_record.raw_trace_run_ref) =
  String.concat
    "\000"
    [ run_ref.path
    ; run_ref.worker_run_id
    ; string_of_int run_ref.start_seq
    ; string_of_int run_ref.end_seq
    ; run_ref.agent_name
    ; run_ref.session_id
    ]
;;

let turn_of_record ~config ~keeper_name ~execution_rows ~previous ~used
    (record : Turn_record.t) =
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
        let first_miss =
          with_run_tables (fun () ->
            if Hashtbl.mem missing_trace_runs cache_key
            then false
            else (
              Hashtbl.replace missing_trace_runs cache_key ();
              true))
        in
        if first_miss
        then
          Log.Keeper.warn ~keeper_name
            "autonomous turn source: exact raw-trace file is missing or non-regular: %s"
            run_ref.path;
        None
      | Current_regular_file ->
        if
          with_run_tables (fun () ->
            Hashtbl.mem version_rejected_runs cache_key
            || Hashtbl.mem missing_trace_runs cache_key)
        then None
        else (
          let key = run_key run_ref in
          let before = file_identity run_ref.path in
          let remembered =
            match before, previous with
            | Some identity, Some table ->
              (match Hashtbl.find_opt table key with
               | Some remembered when file_identity_equal remembered.identity identity ->
                 Some remembered
               | Some _ | None -> None)
            | Some _, None | None, (Some _ | None) -> None
          in
          let reading =
            match remembered with
            | Some remembered ->
              Hashtbl.replace used key remembered;
              Some remembered.reading
            | None ->
              (match Agent_core.Raw_trace_query.read_run (agent_core_run_ref run_ref) with
               | Error (Agent_core.Error.Serialization
                          (Agent_core.Error.VersionMismatch _) as err) ->
                 with_run_tables (fun () ->
                   Hashtbl.replace version_rejected_runs cache_key ());
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
               | Ok records ->
                 let reading = reading_of_records ~keeper_name run_ref records in
                 (* Remembered only when the file statted before the read is
                    the one still there after it: a rewrite in between would
                    pair the new identity with the old records. *)
                 (match before, file_identity run_ref.path with
                  | Some identity, Some identity_after
                    when file_identity_equal identity identity_after ->
                    Hashtbl.replace used key { identity; reading }
                  | Some _, Some _ | Some _, None | None, (Some _ | None) -> ());
                 Some reading)
          in
          match reading with
          | Some (Run_projected { run_started_at; run_final_text; steps }) ->
            let executions = executions_for_turn record execution_rows in
            Some
              { turn_id = Ids.Turn_ref.to_string record.turn_ref
              ; started_at = run_started_at
              ; final_text = run_final_text
              ; trace = List.map (trace_step_of_run_step ~executions) steps
              }
          | Some (Run_has_no_records | Run_identity_mismatch _) | None -> None)
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
    let records = entries |> List.filter_map (function
      | Dated_jsonl.Malformed_json { path; line_number; detail } ->
        Log.Keeper.warn ~keeper_name
          "autonomous turn source: malformed current turn record path=%s line=%s: %s"
          path
          (Option.fold ~none:"unknown" ~some:string_of_int line_number)
          detail;
        None
      | Dated_jsonl.Parsed json ->
        (match Turn_record.of_json json with
         | Ok record -> Some record
         | Error error ->
           Log.Keeper.warn ~keeper_name
             "autonomous turn source: incompatible current turn record skipped: %s"
             error;
           None))
    in
    let execution_ids = records
      |> List.filter (fun (record : Turn_record.t) ->
        String.equal record.keeper keeper_name && record.turn_kind = Turn_record.Autonomous)
      |> List.concat_map (fun (record : Turn_record.t) -> record.execution_ids)
      |> List.map Ids.Execution_id.to_string
      |> List.sort_uniq String.compare
    in
    let execution_rows =
      match execution_ids with
      | [] -> []
      | _ ->
        let ledger = Dated_jsonl.create
          ~base_dir:(Filename.concat (Workspace.masc_root_dir config) "tool_calls") () in
        (match Keeper_tool_call_index.by_execution_ids
           ~store:ledger ~keeper_name ~execution_ids with
         | Ok rows -> rows
         | Error error ->
           Log.Keeper.warn ~keeper_name "autonomous execution evidence unavailable: %s" error;
           [])
    in
    let execution_rows = List.fold_left (fun index row ->
      match Json_util.get_string_nonempty row "execution_id" with
      | None -> index
      | Some id -> Execution_map.update id
          (function None -> Some [ row ] | Some rows -> Some (row :: rows)) index)
      Execution_map.empty execution_rows
    in
    let dir = Keeper_types_support.keeper_raw_trace_dir config keeper_name in
    let previous = with_run_tables (fun () -> Hashtbl.find_opt run_readings dir) in
    let used = Hashtbl.create (List.length records) in
    let turns =
      List.filter_map (turn_of_record ~config ~keeper_name ~execution_rows ~previous ~used)
        records
    in
    with_run_tables (fun () -> Hashtbl.replace run_readings dir used);
    turns
    |> List.filter (fun turn ->
      match since with
      | Some cutoff -> Float.compare turn.started_at cutoff > 0
      | None -> true)
    |> List.stable_sort (fun left right -> Float.compare left.started_at right.started_at)
;;
