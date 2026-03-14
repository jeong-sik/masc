(** MCP tools for long-running team sessions (1h orchestration). *)

open Types
open Tool_args
module Oas = Agent_sdk

type 'a context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
}

type result = bool * string

let json_error message =
  Yojson.Safe.to_string
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])

let json_ok fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

let parse_execution_scope args =
  match String.lowercase_ascii (get_string args "execution_scope" "observe_only") with
  | "limited_code_change" -> Team_session_types.Limited_code_change
  | _ -> Team_session_types.Observe_only

let parse_orchestration_mode args =
  match String.lowercase_ascii (get_string args "orchestration_mode" "assist") with
  | "manual" -> Team_session_types.Manual
  | "auto" -> Team_session_types.Auto
  | _ -> Team_session_types.Assist

let parse_communication_mode args =
  match String.lowercase_ascii (get_string args "communication_mode" "broadcast") with
  | "off" -> Team_session_types.Comm_off
  | "portal" -> Team_session_types.Comm_portal
  | "hybrid" -> Team_session_types.Comm_hybrid
  | _ -> Team_session_types.Comm_broadcast

let parse_scale_profile args =
  match String.lowercase_ascii (get_string args "scale_profile" "standard") with
  | "local64" -> Team_session_types.Scale_local64
  | _ -> Team_session_types.Scale_standard

let parse_control_profile ~scale_profile args =
  match get_string_opt args "control_profile" with
  | Some raw -> (
      match
        Team_session_types.control_profile_of_string
          (String.lowercase_ascii (String.trim raw))
      with
      | profile -> profile)
  | None -> (
      match scale_profile with
      | Team_session_types.Scale_local64 ->
          Team_session_types.Control_hierarchical_quality_v1
      | Team_session_types.Scale_standard -> Team_session_types.Control_flat)

let parse_fallback_policy args =
  match String.lowercase_ascii (get_string args "fallback_policy" "cascade_then_task") with
  | "none" -> Team_session_types.Fallback_none
  | "strict_local_only" -> Team_session_types.Fallback_none
  | "task_only" -> Team_session_types.Fallback_task_only
  | "local_first_conditional" -> Team_session_types.Fallback_cascade_then_task
  | "cloud_first" -> Team_session_types.Fallback_cascade_then_task
  | _ -> Team_session_types.Fallback_cascade_then_task

let parse_instruction_profile args =
  match String.lowercase_ascii (get_string args "instruction_profile" "standard") with
  | "strict" -> Team_session_types.Profile_strict
  | _ -> Team_session_types.Profile_standard

let parse_alert_channel args =
  match String.lowercase_ascii (get_string args "alert_channel" "both") with
  | "broadcast" -> Team_session_types.Alert_broadcast
  | "board" -> Team_session_types.Alert_board
  | _ -> Team_session_types.Alert_both

let parse_report_formats args =
  let raw = get_string_list args "report_formats" in
  let parsed = Team_session_types.report_formats_of_strings raw in
  if parsed = [] then [ Team_session_types.Markdown; Team_session_types.Json ]
  else parsed

let get_agent_names args key =
  match Yojson.Safe.Util.member key args with
  | `List xs ->
      xs
      |> List.filter_map (function
             | `String s ->
                 let t = String.trim s in
                 if t = "" then None else Some t
             | `Assoc fields -> (
                 match List.assoc_opt "name" fields with
                 | Some (`String s) ->
                     let t = String.trim s in
                     if t = "" then None else Some t
                 | _ -> None)
             | _ -> None)
  | _ -> []

let parse_turn_kind args =
  let raw = get_string args "turn_kind" "note" |> String.trim |> String.lowercase_ascii in
  match Team_session_types.turn_kind_of_string raw with
  | Some k -> Ok k
  | None ->
      Error
        "invalid turn_kind (allowed: note|broadcast|portal|task|checkpoint)"

let parse_turn_kind_opt args =
  match get_string_opt args "turn_kind" with
  | None -> Ok None
  | Some raw -> (
      match Team_session_types.turn_kind_of_string (String.lowercase_ascii raw) with
      | Some k -> Ok (Some k)
      | None ->
          Error
            "invalid turn_kind (allowed: note|broadcast|portal|task|checkpoint)")

let parse_proof_level args =
  let raw =
    get_string args "proof_level" "standard"
    |> String.trim |> String.lowercase_ascii
  in
  Team_session_types.proof_level_of_string raw

let parse_wait_mode args =
  let raw =
    get_string args "wait_mode" "background"
    |> String.trim |> String.lowercase_ascii
  in
  Team_session_types.wait_mode_of_string raw

let worker_run_status_to_json = function
  | `Accepted -> `String "accepted"
  | `Ready -> `String "ready"
  | `Running -> `String "running"
  | `Completed -> `String "completed"
  | `Failed -> `String "failed"

let is_all_digits s =
  let len = String.length s in
  len > 0 && String.for_all (function '0' .. '9' -> true | _ -> false) s

let is_all_hex s =
  let len = String.length s in
  len > 0
  && String.for_all
       (function
         | '0' .. '9'
         | 'a' .. 'f'
         | 'A' .. 'F' ->
             true
         | _ -> false)
       s

let is_valid_session_id session_id =
  match String.split_on_char '-' session_id with
  | [ "ts"; epoch_ms; suffix ] -> is_all_digits epoch_ms && is_all_hex suffix
  | _ -> false

let make_worker_run_id () =
  let ms = Int64.of_float (Time_compat.now () *. 1000.0) in
  let high = Int64.of_int (Random.bits ()) in
  let low = Int64.of_int (Random.bits ()) in
  let rnd = Int64.logor (Int64.shift_left high 30) low in
  Printf.sprintf "wr-%Ld-%015Lx" ms rnd

let get_valid_session_id_key args key =
  match get_string_opt args key with
  | None -> Error (key ^ " is required")
  | Some session_id ->
      if is_valid_session_id session_id then
        Ok session_id
      else
        Error ("invalid " ^ key ^ " format")

let get_valid_session_id args = get_valid_session_id_key args "session_id"

let parse_status_filter args =
  match get_string_opt args "status" with
  | None -> Ok None
  | Some status ->
      let normalized = String.lowercase_ascii (String.trim status) in
      match normalized with
      | "running" | "paused" | "completed" | "interrupted" | "failed" ->
          Ok (Some (Team_session_types.status_of_string normalized))
      | _ -> Error "invalid status filter"

let can_access_session ~agent_name (session : Team_session_types.session) =
  String.equal agent_name session.created_by
  || List.exists (String.equal agent_name) session.agent_names

let ensure_session_access ctx session_id =
  match Team_session_store.load_session ctx.config session_id with
  | None -> Error (Printf.sprintf "team session not found: %s" session_id)
  | Some session ->
      if can_access_session ~agent_name:ctx.agent_name session then
        Ok ()
      else
        Error "not authorized for this team session"

let latest_worker_run_id config session_id =
  Team_session_store.list_worker_run_ids config session_id
  |> List.rev |> List.find_opt (fun _ -> true)

let load_worker_run_meta config session_id worker_run_id =
  let path =
    Team_session_store.worker_run_meta_path config session_id worker_run_id
  in
  if not (Room_utils.path_exists config path) then
    Error (Printf.sprintf "worker run not found: %s" worker_run_id)
  else
    Ok (Room_utils.read_json config path)

let oas_trace_session_root config =
  Filename.concat (Room_utils.masc_dir config) "oas-runtime"

type trace_run_locator = {
  worker_run_id : string;
  session_id : string option;
}

let trace_run_locator_of_json json =
  let open Yojson.Safe.Util in
  match member "trace_ref" json with
  | `Assoc _ as trace_json -> (
      try
        Some
          {
            worker_run_id = trace_json |> member "worker_run_id" |> to_string;
            session_id = trace_json |> member "session_id" |> to_string_option;
          }
      with _ -> None)
  | _ -> None

let evidence_session_id_of_json json =
  match Yojson.Safe.Util.member "evidence_session_id" json with
  | `String value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let raw_trace_run_ref_to_json (run_ref : Oas.Raw_trace.run_ref) =
  `Assoc
    [
      ("worker_run_id", `String run_ref.worker_run_id);
      ("start_seq", `Int run_ref.start_seq);
      ("end_seq", `Int run_ref.end_seq);
      ("agent_name", `String run_ref.agent_name);
      ( "session_id",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          run_ref.session_id );
    ]

let raw_trace_summary_to_json
    (summary : Oas.Sessions.raw_trace_summary) =
  `Assoc
    [
      ("run_ref", raw_trace_run_ref_to_json summary.run_ref);
      ("record_count", `Int summary.record_count);
      ("assistant_block_count", `Int summary.assistant_block_count);
      ( "tool_execution_started_count",
        `Int summary.tool_execution_started_count );
      ( "tool_execution_finished_count",
        `Int summary.tool_execution_finished_count );
      ( "tool_names",
        `List (List.map (fun name -> `String name) summary.tool_names) );
      ( "final_text",
        Option.fold ~none:`Null ~some:(fun s -> `String s) summary.final_text
      );
      ( "stop_reason",
        Option.fold ~none:`Null ~some:(fun s -> `String s) summary.stop_reason
      );
      ("error", Option.fold ~none:`Null ~some:(fun s -> `String s) summary.error);
      ("started_at", Option.fold ~none:`Null ~some:(fun ts -> `Float ts) summary.started_at);
      ("finished_at", Option.fold ~none:`Null ~some:(fun ts -> `Float ts) summary.finished_at);
    ]

let raw_trace_validation_to_json
    (validation : Oas.Sessions.raw_trace_validation) =
  `Assoc
    [
      ("run_ref", raw_trace_run_ref_to_json validation.run_ref);
      ("ok", `Bool validation.ok);
      ( "checks",
        `List
          (List.map
             (fun (check : Oas.Raw_trace.validation_check) ->
               `Assoc
                 [
                   ("name", `String check.name);
                   ("passed", `Bool check.passed);
                 ])
             validation.checks) );
      ( "evidence",
        `List (List.map (fun item -> `String item) validation.evidence) );
      ("paired_tool_result_count", `Int validation.paired_tool_result_count);
      ("has_file_write", `Bool validation.has_file_write);
      ( "verification_pass_after_file_write",
        `Bool validation.verification_pass_after_file_write );
      ( "final_text",
        Option.fold ~none:`Null ~some:(fun s -> `String s) validation.final_text );
      ("tool_names", `List (List.map (fun name -> `String name) validation.tool_names));
      ( "stop_reason",
        Option.fold ~none:`Null ~some:(fun s -> `String s) validation.stop_reason );
      ( "failure_reason",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          validation.failure_reason );
    ]

let oas_trace_capability_to_string = function
  | Oas.Sessions.Raw -> "raw"
  | Oas.Sessions.Summary_only -> "summary_only"
  | Oas.Sessions.No_trace -> "none"

let oas_worker_status_to_json = function
  | Oas.Sessions.Planned -> `String "planned"
  | Oas.Sessions.Accepted -> `String "accepted"
  | Oas.Sessions.Ready -> `String "ready"
  | Oas.Sessions.Running -> `String "running"
  | Oas.Sessions.Completed -> `String "completed"
  | Oas.Sessions.Failed -> `String "failed"

let oas_worker_run_to_json (worker : Oas.Sessions.worker_run) =
  `Assoc
    [
      ("worker_run_id", `String worker.worker_run_id);
      ("agent_name", `String worker.agent_name);
      ("role", Option.fold ~none:`Null ~some:(fun s -> `String s) worker.role);
      ("aliases", `List (List.map (fun alias -> `String alias) worker.aliases));
      ("provider", Option.fold ~none:`Null ~some:(fun s -> `String s) worker.provider);
      ("model", Option.fold ~none:`Null ~some:(fun s -> `String s) worker.model);
      ( "requested_provider",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          worker.requested_provider );
      ( "requested_model",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          worker.requested_model );
      ( "requested_policy",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          worker.requested_policy );
      ( "resolved_provider",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          worker.resolved_provider );
      ( "resolved_model",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          worker.resolved_model );
      ("status", oas_worker_status_to_json worker.status);
      ("trace_capability", `String (oas_trace_capability_to_string worker.trace_capability));
      ("validated", `Bool worker.validated);
      ("tool_names", `List (List.map (fun name -> `String name) worker.tool_names));
      ("final_text", Option.fold ~none:`Null ~some:(fun s -> `String s) worker.final_text);
      ("stop_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) worker.stop_reason);
      ("error", Option.fold ~none:`Null ~some:(fun s -> `String s) worker.error);
      ( "failure_reason",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          worker.failure_reason );
      ("started_at", Option.fold ~none:`Null ~some:(fun ts -> `Float ts) worker.started_at);
      ("finished_at", Option.fold ~none:`Null ~some:(fun ts -> `Float ts) worker.finished_at);
      ( "last_progress_at",
        Option.fold ~none:`Null ~some:(fun ts -> `Float ts)
          worker.last_progress_at );
      ( "policy_snapshot",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          worker.policy_snapshot );
      ("paired_tool_result_count", `Int worker.paired_tool_result_count);
      ("has_file_write", `Bool worker.has_file_write);
      ( "verification_pass_after_file_write",
        `Bool worker.verification_pass_after_file_write );
    ]

let conformance_report_to_json (report : Oas.Conformance.report) =
  `Assoc
    [
      ("ok", `Bool report.ok);
      ( "summary",
        `Assoc
          [
            ("session_id", `String report.summary.session_id);
            ("generated_at", `Float report.summary.generated_at);
            ("worker_run_count", `Int report.summary.worker_run_count);
            ("raw_trace_run_count", `Int report.summary.raw_trace_run_count);
            ( "validated_worker_run_count",
              `Int report.summary.validated_worker_run_count );
            ( "latest_accepted_worker_run_id",
              Option.fold ~none:`Null ~some:(fun s -> `String s)
                report.summary.latest_accepted_worker_run_id );
            ( "latest_ready_worker_run_id",
              Option.fold ~none:`Null ~some:(fun s -> `String s)
                report.summary.latest_ready_worker_run_id );
            ( "latest_running_worker_run_id",
              Option.fold ~none:`Null ~some:(fun s -> `String s)
                report.summary.latest_running_worker_run_id );
            ( "latest_worker_run_id",
              Option.fold ~none:`Null ~some:(fun s -> `String s)
                report.summary.latest_worker_run_id );
            ( "latest_completed_worker_run_id",
              Option.fold ~none:`Null ~some:(fun s -> `String s)
                report.summary.latest_completed_worker_run_id );
            ( "latest_worker_agent_name",
              Option.fold ~none:`Null ~some:(fun s -> `String s)
                report.summary.latest_worker_agent_name );
            ( "latest_worker_validated",
              Option.fold ~none:`Null ~some:(fun v -> `Bool v)
                report.summary.latest_worker_validated );
            ( "latest_failed_worker_run_id",
              Option.fold ~none:`Null ~some:(fun s -> `String s)
                report.summary.latest_failed_worker_run_id );
            ( "latest_failure_reason",
              Option.fold ~none:`Null ~some:(fun s -> `String s)
                report.summary.latest_failure_reason );
            ( "trace_capabilities",
              `List
                (List.map
                   (fun capability ->
                     `String (oas_trace_capability_to_string capability))
                   report.summary.trace_capabilities) );
          ] );
      ( "checks",
        `List
          (List.map
             (fun (check : Oas.Conformance.check) ->
               `Assoc
                 [
                   ("code", `String check.code);
                   ("name", `String check.name);
                   ("passed", `Bool check.passed);
                   ("detail", Option.fold ~none:`Null ~some:(fun s -> `String s) check.detail);
                 ])
             report.checks) );
    ]

type oas_worker_evidence = {
  trace_ref : Oas.Raw_trace.run_ref option;
  trace_summary_json : Yojson.Safe.t option;
  trace_validation_json : Yojson.Safe.t option;
  worker_json : Yojson.Safe.t option;
  conformance_json : Yojson.Safe.t option;
  worker : Oas.Sessions.worker_run option;
}

let oas_worker_evidence_payload ~config ~evidence_session_id =
  let session_root = oas_trace_session_root config in
  match
    Oas.Sessions.get_proof_bundle ~session_root ~session_id:evidence_session_id (),
    Oas.Conformance.run ~session_root ~session_id:evidence_session_id ()
  with
  | Ok bundle, Ok report ->
      let latest_trace_run = bundle.latest_raw_trace_run in
      let worker = bundle.latest_worker_run in
      let trace_summary_json =
        match latest_trace_run with
        | Some run_ref -> (
            match
              List.find_opt
                (fun (summary : Oas.Sessions.raw_trace_summary) ->
                  String.equal summary.run_ref.worker_run_id
                    run_ref.worker_run_id)
                bundle.raw_trace_summaries
            with
            | Some summary -> Some (raw_trace_summary_to_json summary)
            | None -> None)
        | None -> None
      in
      let trace_validation_json =
        match latest_trace_run with
        | Some run_ref -> (
            match
              List.find_opt
                (fun (validation : Oas.Sessions.raw_trace_validation) ->
                  String.equal validation.run_ref.worker_run_id
                    run_ref.worker_run_id)
                bundle.raw_trace_validations
            with
            | Some validation -> Some (raw_trace_validation_to_json validation)
            | None -> None)
        | None -> None
      in
      Some
        {
          trace_ref = latest_trace_run;
          trace_summary_json;
          trace_validation_json;
          worker_json = Option.map oas_worker_run_to_json worker;
          conformance_json = Some (conformance_report_to_json report);
          worker;
        }
  | _ -> None

let tool_trace_of_raw_records (records : Oas.Raw_trace.record list) =
  records
  |> List.filter_map (fun record ->
         match record.Oas.Raw_trace.record_type with
         | Oas.Raw_trace.Tool_execution_started ->
             Some
               (`Assoc
                 [
                   ("kind", `String "tool_use");
                   ( "tool_use_id",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       record.tool_use_id );
                   ( "tool_name",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       record.tool_name );
                   ( "input",
                     Option.fold ~none:`Null ~some:(fun json -> json)
                       record.tool_input );
                 ])
         | Oas.Raw_trace.Tool_execution_finished ->
             Some
               (`Assoc
                 [
                   ("kind", `String "tool_result");
                   ( "tool_use_id",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       record.tool_use_id );
                   ( "tool_name",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       record.tool_name );
                   ( "content",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       record.tool_result );
                   ( "is_error",
                     Option.fold ~none:`Null ~some:(fun v -> `Bool v)
                       record.tool_error );
                 ])
         | Oas.Raw_trace.Assistant_block ->
             Option.map
               (fun block ->
                 `Assoc
                   [
                     ("kind", `String "assistant_block");
                     ("block", block);
                   ])
               record.assistant_block
         | Oas.Raw_trace.Run_finished ->
             Some
               (`Assoc
                 [
                   ("kind", `String "run_finished");
                   ( "final_text",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       record.final_text );
                   ( "error",
                     Option.fold ~none:`Null ~some:(fun s -> `String s)
                       record.error );
                 ])
         | Oas.Raw_trace.Run_started -> None)

let verification_rollup_of_trace trace =
  let uses =
    trace
    |> List.filter (fun json ->
           Yojson.Safe.Util.member "kind" json = `String "tool_use")
  in
  let results =
    trace
    |> List.filter (fun json ->
           Yojson.Safe.Util.member "kind" json = `String "tool_result")
  in
  let pair_count =
    List.fold_left
      (fun acc use_json ->
        match Yojson.Safe.Util.member "tool_use_id" use_json with
        | `String id ->
            if
              List.exists
                (fun result_json ->
                  Yojson.Safe.Util.member "tool_use_id" result_json
                  = `String id)
                results
            then acc + 1
            else acc
        | _ -> acc)
      0 uses
  in
  let tool_names =
    uses
    |> List.filter_map (fun json ->
           match Yojson.Safe.Util.member "tool_name" json with
           | `String name -> Some name
           | _ -> None)
    |> Team_session_types.dedup_strings
  in
  let rec find_file_write idx = function
    | [] -> None
    | json :: rest -> (
        match
          Yojson.Safe.Util.member "kind" json,
          Yojson.Safe.Util.member "tool_name" json
        with
        | `String "tool_use", `String "file_write" -> Some idx
        | _ -> find_file_write (idx + 1) rest)
  in
  let file_write_index = find_file_write 0 trace in
  let verification_pass_after_file_write =
    match file_write_index with
    | None -> not (List.mem "file_write" tool_names)
    | Some idx ->
        trace
        |> List.mapi (fun i json -> (i, json))
        |> List.exists (fun (i, json) ->
               i > idx
               &&
               match
                 Yojson.Safe.Util.member "kind" json,
                 Yojson.Safe.Util.member "is_error" json,
                 Yojson.Safe.Util.member "content" json
               with
               | `String "tool_result", `Bool false, `String content ->
                   let trimmed = String.trim content in
                   trimmed = "PASS"
                   || String.starts_with ~prefix:"PASS" trimmed
               | _ -> false)
  in
  (pair_count, tool_names, verification_pass_after_file_write)

let verification_json ~records
    ~(summary : Oas.Sessions.raw_trace_summary)
    ~(validation : Oas.Sessions.raw_trace_validation) =
  let tool_trace = tool_trace_of_raw_records records in
  let pair_count, trace_tool_names, verification_pass_after_file_write =
    verification_rollup_of_trace tool_trace
  in
  let tool_names =
    if validation.tool_names <> [] then validation.tool_names else trace_tool_names
  in
  `Assoc
    [
      ("tool_trace", `List tool_trace);
      ("summary", raw_trace_summary_to_json summary);
      ("validation", raw_trace_validation_to_json validation);
      ("ok", `Bool validation.ok);
      ("tool_names", `List (List.map (fun name -> `String name) tool_names));
      ("tool_use_count", `Int summary.tool_execution_started_count);
      ("tool_result_count", `Int summary.tool_execution_finished_count);
      ("paired_tool_result_count", `Int validation.paired_tool_result_count);
      ("has_file_write", `Bool (List.mem "file_write" tool_names));
      ("has_shell_exec", `Bool (List.mem "shell_exec" tool_names));
      ( "verification_pass_after_file_write",
        `Bool validation.verification_pass_after_file_write );
      ( "final_text",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          validation.final_text );
      ( "stop_reason",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          validation.stop_reason );
      ( "failure_reason",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          validation.failure_reason );
      ("trace_pair_count", `Int pair_count);
      ( "trace_verification_pass_after_file_write",
        `Bool verification_pass_after_file_write );
    ]

let raw_trace_session_payloads ~config ~fallback_session_id
    (run_ref : Oas.Raw_trace.run_ref) =
  let trace_session_id =
    Option.value ~default:fallback_session_id run_ref.session_id
  in
  let session_root = oas_trace_session_root config in
  match
    Oas.Sessions.get_raw_trace_summary ~session_root ~session_id:trace_session_id
      ~worker_run_id:run_ref.worker_run_id (),
    Oas.Sessions.validate_raw_trace_run ~session_root
      ~session_id:trace_session_id ~worker_run_id:run_ref.worker_run_id ()
  with
  | Ok summary, Ok validation ->
      Some
        ( raw_trace_summary_to_json summary,
          raw_trace_validation_to_json validation )
  | _ -> (
      match Oas.Raw_trace.summarize_run run_ref, Oas.Raw_trace.validate_run run_ref with
      | Ok summary, Ok validation ->
          Some
            ( raw_trace_summary_to_json summary,
              raw_trace_validation_to_json validation )
      | _ -> None)

let record_session_turn_json ~(config : Room.config) ~session_id ~actor
    ~turn_kind ~message ~target_agent ~task_title ~task_description
    ~task_priority =
  Team_session_engine_eio.record_turn ~config ~session_id ~actor ~turn_kind
    ~message ~target_agent ~task_title ~task_description ~task_priority

let handle_start ctx args : result =
  let goal = get_string args "goal" "" in
  if String.trim goal = "" then
    (false, json_error "goal is required")
  else
    let duration_seconds =
      let raw_seconds = get_int args "duration_seconds" 0 in
      if raw_seconds > 0 then
        raw_seconds
      else
        let duration_minutes = get_int args "duration_minutes" 60 in
        max 1 duration_minutes * 60
    in
    let checkpoint_interval_sec = get_int args "checkpoint_interval_sec" 60 in
    let min_agents = get_int args "min_agents" 2 in
    let scale_profile = parse_scale_profile args in
    let control_profile = parse_control_profile ~scale_profile args in
    let auto_resume = get_bool args "auto_resume" true in
    let report_formats = parse_report_formats args in
    let execution_scope = parse_execution_scope args in
    let orchestration_mode = parse_orchestration_mode args in
    let communication_mode = parse_communication_mode args in
    let model_cascade = get_string_list args "model_cascade" in
    let fallback_policy = parse_fallback_policy args in
    let instruction_profile = parse_instruction_profile args in
    let alert_channel = parse_alert_channel args in
    let agents = get_agent_names args "agents" in
    let operation_id = get_string_opt args "operation_id" in
    match
      Team_session_engine_eio.start_session ~sw:ctx.sw ~clock:ctx.clock
        ~config:ctx.config ~created_by:ctx.agent_name ~goal ~duration_seconds
        ~execution_scope ~checkpoint_interval_sec ~min_agents
        ~scale_profile ~control_profile
        ~orchestration_mode ~communication_mode ~model_cascade ~fallback_policy
        ~instruction_profile ~alert_channel ~auto_resume ~report_formats
        ~agent_names:agents ~operation_id
    with
    | Ok json -> (true, json_ok [ ("result", json) ])
    | Error e -> (false, json_error e)

let handle_status ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () -> (
          match Team_session_engine_eio.status_session ~config:ctx.config ~session_id with
          | Ok json -> (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let handle_stop ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let reason = get_string args "reason" "manual_stop" in
          let generate_report = get_bool args "generate_report" true in
          (match
             Team_session_engine_eio.stop_session ~config:ctx.config ~session_id
               ~reason ~generate_report
           with
          | Ok json ->
              let linked_result =
                match
                  Autoresearch.load_swarm_link_by_session
                    ~base_path:ctx.config.base_path session_id
                with
                | None -> None
                | Some link ->
                    Autoresearch.stop_loop ~base_path:ctx.config.base_path
                      ~reason:(Printf.sprintf "team_session_stop:%s" reason)
                      link.loop_id
                    |> Option.map (fun (state : Autoresearch.loop_state) ->
                           `Assoc
                             [
                               ("loop_id", `String state.loop_id);
                               ( "status",
                                 `String
                                   (Autoresearch.status_to_string state.status) );
                               ("current_cycle", `Int state.current_cycle);
                               ("best_score", `Float state.best_score);
                             ])
              in
              let json =
                match json with
                | `Assoc fields -> (
                    match linked_result with
                    | Some linked ->
                        `Assoc
                          (List.remove_assoc "linked_autoresearch" fields
                          @ [ ("linked_autoresearch", linked) ])
                    | None -> json)
                | _ -> json
              in
              (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let handle_report ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let force_regenerate = get_bool args "force_regenerate" false in
          (match
             Team_session_engine_eio.generate_report ~config:ctx.config ~session_id
               ~force_regenerate
           with
          | Ok json -> (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let handle_list ctx args : result =
  let limit = get_int args "limit" 20 in
  match parse_status_filter args with
  | Error e -> (false, json_error e)
  | Ok status_filter -> (
      match
        Team_session_engine_eio.list_sessions ~config:ctx.config
          ~requester_agent:(Some ctx.agent_name) ~status_filter ~limit
      with
      | Ok json -> (true, json_ok [ ("result", json) ])
      | Error e -> (false, json_error e))

let handle_compare ctx args : result =
  match
    ( get_valid_session_id_key args "base_session_id",
      get_valid_session_id_key args "target_session_id" )
  with
  | Ok base_session_id, Ok target_session_id -> (
      match
        Team_session_engine_eio.compare_sessions ~config:ctx.config
          ~requester_agent:(Some ctx.agent_name) ~base_session_id
          ~target_session_id
      with
      | Ok json -> (true, json_ok [ ("result", json) ])
      | Error e -> (false, json_error e))
  | Error e, _ -> (false, json_error e)
  | _, Error e -> (false, json_error e)

let handle_turn ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () -> (
          match parse_turn_kind args with
          | Error e -> (false, json_error e)
          | Ok turn_kind ->
              let message = get_string_opt args "message" in
              let target_agent = get_string_opt args "target_agent" in
              let task_title = get_string_opt args "task_title" in
              let task_description = get_string_opt args "task_description" in
              let task_priority = get_int args "task_priority" 3 in
              (match
                 record_session_turn_json ~config:ctx.config ~session_id
                   ~actor:ctx.agent_name ~turn_kind ~message ~target_agent
                   ~task_title ~task_description ~task_priority
               with
              | Ok json -> (true, json_ok [ ("result", json) ])
              | Error e -> (false, json_error e))))

let int_opt_to_json = function Some n -> `Int n | None -> `Null
let float_opt_to_json = function Some v -> `Float v | None -> `Null

let truncate_for_event ?(max_len = 320) (s : string) =
  if String.length s <= max_len then
    s
  else
    String.sub s 0 max_len ^ "..."

let derived_llama_runtime_actor ~session_id ~prompt =
  let digest = Digest.string (session_id ^ "\n" ^ prompt) |> Digest.to_hex in
  Printf.sprintf "llama-local-%s" (String.sub digest 0 8)

let normalize_spawn_agent agent_name =
  let normalized = String.lowercase_ascii (String.trim agent_name) in
  if normalized = "" then "default" else normalized

let is_local_spawn_agent agent_name =
  match normalize_spawn_agent agent_name with
  | "default" | "llama" -> true
  | _ -> false

let legacy_spawn_fields = [ "spawn_agent"; "spawn_model"; "model_tier" ]

let find_present_json_key keys json =
  List.find_opt (fun key -> Yojson.Safe.Util.member key json <> `Null) keys

let legacy_spawn_field_error ?batch_index field =
  match batch_index with
  | Some index ->
      Printf.sprintf
        "spawn_batch[%d].%s is no longer supported in masc_team_session_step; \
         use spawn_prompt, spawn_role, worker_class, and worker_size"
        index field
  | None ->
      Printf.sprintf
        "%s is no longer supported in masc_team_session_step; use spawn_prompt, \
         spawn_role, worker_class, and worker_size"
        field

type routing_decision = {
  model_tier : Team_session_types.model_tier;
  task_profile : Team_session_types.task_profile;
  risk_level : Team_session_types.risk_level;
  confidence : float option;
  reason : string;
  judge_used : bool;
  escalate_if : string list;
  escalated : bool;
}

type spawn_spec = {
  spawn_agent : string;
  spawn_prompt : string;
  spawn_model : string option;
  spawn_model_explicit : bool;
  spawn_role : string option;
  execution_scope : Team_session_types.execution_scope option;
  thinking_enabled : bool option;
  max_turns : int option;
  worker_class : Team_session_types.worker_class option;
  worker_size : Team_session_types.worker_size option;
  parent_actor : string option;
  capsule_mode : Team_session_types.capsule_mode option;
  runtime_pool : string option;
  lane_id : string option;
  control_domain : Team_session_types.control_domain option;
  supervisor_actor : string option;
  model_tier : Team_session_types.model_tier option;
  model_tier_explicit : bool;
  task_profile : Team_session_types.task_profile option;
  risk_level : Team_session_types.risk_level option;
  routing_confidence : float option;
  routing_reason : string option;
  spawn_selection_note : string option;
  spawn_timeout_seconds : int;
}

type prepared_spawn = {
  worker_run_id : string;
  spec : spawn_spec;
  runtime_actor_name : string option;
  runtime_model : Llm_client.model_spec;
  runtime_lease : Local_runtime_pool.lease option;
  assigned_runtime : string option;
}

let trim_opt = function
  | None -> None
  | Some raw ->
      let trimmed = String.trim raw in
      if trimmed = "" then None else Some trimmed

let env_trim_opt name = Sys.getenv_opt name |> trim_opt

let bool_env_default name ~default =
  match env_trim_opt name with
  | Some ("1" | "true" | "yes" | "on") -> true
  | Some ("0" | "false" | "no" | "off") -> false
  | _ -> default

let float_env_default name ~default =
  match env_trim_opt name with
  | Some raw -> (
      try float_of_string raw with Failure _ -> default)
  | None -> default

let int_env_default name ~default =
  match env_trim_opt name with
  | Some raw -> (
      try int_of_string raw with Failure _ -> default)
  | None -> default

let default_worker_size_for_class = function
  | Some Team_session_types.Worker_manager ->
      Some Team_session_types.Worker_xlg
  | Some Team_session_types.Worker_executor ->
      Some Team_session_types.Worker_lg
  | Some Team_session_types.Worker_scout
  | Some Team_session_types.Worker_librarian ->
      Some Team_session_types.Worker_sm
  | Some Team_session_types.Worker_metacog ->
      Some Team_session_types.Worker_lg
  | None -> Some Team_session_types.Worker_lg

let default_execution_scope_for_worker_class = function
  | Some Team_session_types.Worker_executor ->
      Some Team_session_types.Limited_code_change
  | _ -> Some Team_session_types.Observe_only

let effective_execution_scope_of_spec spec =
  match spec.execution_scope with
  | Some scope -> Some scope
  | None -> default_execution_scope_for_worker_class spec.worker_class

let explicit_worker_size_of_spec (spec : spawn_spec) =
  match spec.worker_size with
  | Some _ as size -> size
  | None ->
      Option.bind spec.model_tier Team_session_types.worker_size_of_model_tier

let worker_size_of_spec (spec : spawn_spec) =
  match explicit_worker_size_of_spec spec with
  | Some _ as size -> size
  | None -> default_worker_size_for_class spec.worker_class

let contains_ci haystack needle =
  let haystack = String.lowercase_ascii haystack in
  let needle = String.lowercase_ascii needle in
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then
      true
    else if idx + needle_len > haystack_len then
      false
    else if String.sub haystack idx needle_len = needle then
      true
    else loop (idx + 1)
  in
  loop 0

let contains_any_ci haystack needles =
  List.exists (fun needle -> contains_ci haystack needle) needles

let runtime_inventory_models () =
  Local_runtime_pool.snapshots ()
  |> List.filter_map (fun (runtime : Local_runtime_pool.runtime_snapshot) ->
         trim_opt runtime.model)
  |> Team_session_types.dedup_strings

let explicit_lead_model () = env_trim_opt "MASC_TEAM_SESSION_MODEL_35B"
let explicit_middle_model () = env_trim_opt "MASC_TEAM_SESSION_MODEL_27B"
let explicit_worker_model () = env_trim_opt "MASC_TEAM_SESSION_MODEL_9B"

let inferred_lead_model () =
  match explicit_lead_model () with
  | Some _ as explicit -> explicit
  | None -> (
      match env_trim_opt "LLAMA_SWARM_MODEL" with
      | Some _ as env_model -> env_model
      | None ->
          runtime_inventory_models ()
          |> List.find_opt (fun model -> contains_ci model "35b"))

let inferred_middle_model () =
  match explicit_middle_model () with
  | Some _ as explicit -> explicit
  | None ->
      runtime_inventory_models ()
      |> List.find_opt (fun model -> contains_ci model "27b")

let inferred_worker_model () =
  match explicit_worker_model () with
  | Some _ as explicit -> explicit
  | None ->
      runtime_inventory_models ()
      |> List.find_opt (fun model -> contains_ci model "9b")

let infer_model_tier_from_model_name model_name =
  match trim_opt model_name with
  | None -> None
  | Some model_name -> (
      match
        (inferred_worker_model (), inferred_middle_model (), inferred_lead_model ())
      with
      | Some worker_model, _, _ when String.equal worker_model model_name ->
          Some Team_session_types.Tier_9b
      | _, Some middle_model, _ when String.equal middle_model model_name ->
          Some Team_session_types.Tier_27b
      | _, _, Some lead_model when String.equal lead_model model_name ->
          Some Team_session_types.Tier_35b
      | _ when contains_ci model_name "35b" -> Some Team_session_types.Tier_35b
      | _ when contains_ci model_name "27b" -> Some Team_session_types.Tier_27b
      | _ when contains_ci model_name "9b" -> Some Team_session_types.Tier_9b
      | _ -> None)

let default_risk_for_profile = function
  | Team_session_types.Profile_extract
  | Team_session_types.Profile_normalize
  | Team_session_types.Profile_summarize ->
      Team_session_types.Risk_low
  | Team_session_types.Profile_verify
  | Team_session_types.Profile_decide ->
      Team_session_types.Risk_high
  | Team_session_types.Profile_synthesize ->
      Team_session_types.Risk_medium

let min_risk left right =
  match (left, right) with
  | Team_session_types.Risk_high, _
  | _, Team_session_types.Risk_high ->
      Team_session_types.Risk_high
  | Team_session_types.Risk_medium, _
  | _, Team_session_types.Risk_medium ->
      Team_session_types.Risk_medium
  | _ -> Team_session_types.Risk_low

let default_tier_for_profile ~risk_level = function
  | (Team_session_types.Profile_extract
    | Team_session_types.Profile_normalize
    | Team_session_types.Profile_summarize)
    when risk_level <> Team_session_types.Risk_high ->
      Team_session_types.Tier_9b
  | (Team_session_types.Profile_verify | Team_session_types.Profile_synthesize)
    when risk_level <> Team_session_types.Risk_high ->
      Team_session_types.Tier_27b
  | _ -> Team_session_types.Tier_35b

let normalized_spawn_text ~spawn_prompt ~spawn_role =
  String.concat "\n"
    ([ spawn_prompt ]
    @
    match spawn_role with
    | Some role -> [ role ]
    | None -> [])
  |> String.lowercase_ascii

let keyword_matches text =
  let groups =
    [
      ( Team_session_types.Profile_extract,
        [ "fetch"; "collect"; "gather"; "search"; "find source"; "read docs"; "web"; "official docs"; "article"; "paper"; "source" ] );
      ( Team_session_types.Profile_normalize,
        [ "normalize"; "convert"; "transform"; "schema"; "format"; "json"; "label"; "tag"; "dedup" ] );
      ( Team_session_types.Profile_summarize,
        [ "summarize"; "summary"; "digest"; "brief"; "recap"; "short answer"; "bullet" ] );
      ( Team_session_types.Profile_verify,
        [ "verify"; "validate"; "check"; "review"; "audit"; "judge"; "prove"; "test"; "compare" ] );
      ( Team_session_types.Profile_decide,
        [ "decide"; "choose"; "route"; "triage"; "prioritize"; "assign"; "classify" ] );
      ( Team_session_types.Profile_synthesize,
        [ "synthesize"; "write"; "draft"; "compose"; "architecture"; "design"; "plan"; "proposal"; "explain" ] );
    ]
  in
  List.filter_map
    (fun (profile, keywords) ->
      if contains_any_ci text keywords then Some profile else None)
    groups

let high_risk_keywords =
  [ "security"; "policy"; "final"; "merge"; "customer"; "public"; "external"; "production"; "critical"; "architecture"; "decision" ]

let router_judge_enabled () =
  bool_env_default "MASC_TEAM_SESSION_ROUTER_JUDGE" ~default:true

let router_judge_timeout_sec () =
  max 5 (int_env_default "MASC_TEAM_SESSION_ROUTER_JUDGE_TIMEOUT_SEC" ~default:15)

let router_judge_confidence_threshold () =
  let value =
    float_env_default "MASC_TEAM_SESSION_ROUTER_CONFIDENCE_THRESHOLD"
      ~default:0.72
  in
  if value < 0.0 then 0.0 else if value > 1.0 then 1.0 else value

let router_judge_model () =
  match env_trim_opt "MASC_TEAM_SESSION_ROUTER_JUDGE_MODEL" with
  | Some _ as explicit -> explicit
  | None -> inferred_lead_model ()

let llama_router_model_spec model_id =
  {
    Llm_client.provider = Llm_client.Llama;
    model_id;
    max_context = 262_144;
    api_url = Env_config.Llama.server_url;
    api_key_env = None;
    cost_per_1k_input = 0.0;
    cost_per_1k_output = 0.0;
  }

let classify_risk ~task_profile ~spawn_prompt ~spawn_role =
  let text = normalized_spawn_text ~spawn_prompt ~spawn_role in
  let base = default_risk_for_profile task_profile in
  if contains_any_ci text high_risk_keywords then
    min_risk base Team_session_types.Risk_high
  else base

let heuristic_routing ~spawn_prompt ~spawn_role ~worker_class ~task_profile
    ~risk_level ~model_tier ~routing_confidence ~routing_reason =
  let resolved_profile =
    match task_profile with
    | Some profile -> Some (profile, "explicit_task_profile", 0.99)
    | None -> (
        match worker_class with
        | Some Team_session_types.Worker_manager ->
            Some (Team_session_types.Profile_decide, "rule:worker_class=manager", 0.97)
        | Some Team_session_types.Worker_metacog ->
            Some (Team_session_types.Profile_verify, "rule:worker_class=metacog", 0.97)
        | Some Team_session_types.Worker_scout ->
            Some (Team_session_types.Profile_extract, "rule:worker_class=scout", 0.95)
        | Some Team_session_types.Worker_librarian ->
            Some (Team_session_types.Profile_summarize, "rule:worker_class=librarian", 0.94)
        | _ ->
            let matches =
              keyword_matches
                (normalized_spawn_text ~spawn_prompt ~spawn_role)
            in
            match matches with
            | [ profile ] -> Some (profile, "rule:keyword_match", 0.78)
            | _ -> None)
  in
  match resolved_profile with
  | Some (profile, reason, confidence) ->
      let resolved_risk =
        match risk_level with
        | Some explicit -> explicit
        | None -> classify_risk ~task_profile:profile ~spawn_prompt ~spawn_role
      in
      let resolved_tier =
        match model_tier with
        | Some explicit -> explicit
        | None -> default_tier_for_profile ~risk_level:resolved_risk profile
      in
      let confidence =
        match routing_confidence with
        | Some value -> Some value
        | None -> Some confidence
      in
      let reason =
        match routing_reason with
        | Some explicit -> explicit
        | None -> reason
      in
      Some
        {
          model_tier = resolved_tier;
          task_profile = profile;
          risk_level = resolved_risk;
          confidence;
          reason;
          judge_used = false;
          escalate_if =
            [ "worker failure"; "schema mismatch"; "context pressure"; "evidence conflict" ];
          escalated = false;
        }
  | None -> None

let parse_routing_decision_json (json : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  let model_tier =
    match member "model_tier" json |> to_string_option with
    | Some raw ->
        Team_session_types.model_tier_of_string
          (String.lowercase_ascii (String.trim raw))
    | None -> None
  in
  let task_profile =
    match member "task_profile" json |> to_string_option with
    | Some raw ->
        Team_session_types.task_profile_of_string
          (String.lowercase_ascii (String.trim raw))
    | None -> None
  in
  let risk_level =
    match member "risk_level" json |> to_string_option with
    | Some raw ->
        Team_session_types.risk_level_of_string
          (String.lowercase_ascii (String.trim raw))
    | None -> None
  in
  match (model_tier, task_profile, risk_level) with
  | Some model_tier, Some task_profile, Some risk_level ->
      let confidence =
        match member "confidence" json with
        | `Float value -> Some value
        | `Int value -> Some (float_of_int value)
        | `Intlit raw -> (try Some (float_of_string raw) with Failure _ -> None)
        | _ -> None
      in
      let reason =
        member "reason" json |> to_string_option
        |> Option.value ~default:"llm_judge"
      in
      let escalate_if =
        match member "escalate_if" json with
        | `List xs ->
            xs
            |> List.filter_map (function
                   | `String value ->
                       let trimmed = String.trim value in
                       if trimmed = "" then None else Some trimmed
                   | _ -> None)
        | _ -> []
      in
      Some
        {
          model_tier;
          task_profile;
          risk_level;
          confidence;
          reason;
          judge_used = true;
          escalate_if;
          escalated = false;
        }
  | _ -> None

let llm_judge_routing ~spawn_prompt ~spawn_role ~worker_class =
  match router_judge_model () with
  | None -> None
  | Some judge_model ->
      let worker_class_text =
        match worker_class with
        | Some kind -> Team_session_types.worker_class_to_string kind
        | None -> "unspecified"
      in
      let role_text = Option.value ~default:"unspecified" spawn_role in
      let prompt =
        Printf.sprintf
          "Classify the worker task for a quality-first 2-tier swarm router.\n\
           Return strict JSON only with keys: model_tier, task_profile, risk_level, confidence, reason, escalate_if.\n\
           model_tier must be one of [\"35b\",\"27b\",\"9b\"].\n\
           task_profile must be one of [\"extract\",\"normalize\",\"summarize\",\"verify\",\"decide\",\"synthesize\"].\n\
           risk_level must be one of [\"low\",\"medium\",\"high\"].\n\
           Use 35b for root judgment, final arbitration, or high-risk outputs.\n\
           Use 27b for lane managers, quality review, knowledge review, and medium-risk synthesis.\n\
           Use 9b only for low-risk, machine-checkable, or strict-template subtasks.\n\
           worker_class=%s\n\
           spawn_role=%s\n\
           worker_prompt=%S\n"
          worker_class_text role_text spawn_prompt
      in
      let request : Llm_client.completion_request =
        {
          model = llama_router_model_spec judge_model;
          messages =
            [
              {
                Llm_client.role = Llm_client.System;
                content =
                  "You are a routing judge for a hybrid swarm. Output only JSON.";
                name = None;
                tool_call_id = None;
              };
              {
                Llm_client.role = Llm_client.User;
                content = prompt;
                name = None;
                tool_call_id = None;
              };
            ];
          temperature = 0.0;
          max_tokens = 220;
          tools = [];
          response_format = `Json;
        }
      in
      match
        Llm_client.complete ~timeout_sec:(router_judge_timeout_sec ()) request
      with
      | Ok response -> (
          try
            Yojson.Safe.from_string response.content
            |> parse_routing_decision_json
          with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None)
      | Error _ -> None

let routing_summary_line (decision : routing_decision) =
  Printf.sprintf
    "[routing] profile=%s tier=%s risk=%s confidence=%s reason=%s judge=%b escalated=%b"
    (Team_session_types.task_profile_to_string decision.task_profile)
    (Team_session_types.model_tier_to_string decision.model_tier)
    (Team_session_types.risk_level_to_string decision.risk_level)
    (match decision.confidence with
    | Some value -> Printf.sprintf "%.2f" value
    | None -> "n/a")
    decision.reason decision.judge_used decision.escalated

let merge_selection_note selection_note routing_note =
  match (trim_opt selection_note, trim_opt (Some routing_note)) with
  | None, None -> None
  | Some note, None | None, Some note -> Some note
  | Some note, Some routing when String.equal note routing -> Some note
  | Some note, Some routing -> Some (note ^ " | " ^ routing)

let finalize_routing_decision ~spawn_model ~(decision : routing_decision) =
  let resolved_model, escalated, reason =
    match decision.model_tier with
    | Team_session_types.Tier_35b -> (inferred_lead_model (), decision.escalated, decision.reason)
    | Team_session_types.Tier_27b -> (
        match inferred_middle_model () with
        | Some model -> (Some model, decision.escalated, decision.reason)
        | None ->
            ( inferred_lead_model (),
              true,
              decision.reason ^ "; fallback:27b_unavailable->35b" ))
    | Team_session_types.Tier_9b -> (
        match inferred_worker_model () with
        | Some model -> (Some model, decision.escalated, decision.reason)
        | None ->
            ( inferred_lead_model (),
              true,
              decision.reason ^ "; fallback:9b_unavailable->35b" ))
  in
  let resolved_model =
    match trim_opt spawn_model with
    | Some explicit -> Some explicit
    | None -> resolved_model
  in
  let resolved_tier =
    match trim_opt spawn_model with
    | Some explicit ->
        Option.value ~default:decision.model_tier
          (infer_model_tier_from_model_name (Some explicit))
    | None ->
        if escalated then Team_session_types.Tier_35b else decision.model_tier
  in
  (resolved_model, resolved_tier, escalated, reason)

let resolve_routing_for_spec (spec : spawn_spec) =
  if not (is_local_spawn_agent spec.spawn_agent) then
    spec
  else
    let explicit_tier =
      match spec.worker_size with
      | Some size -> Team_session_types.model_tier_of_worker_size size
      | None -> (
          match spec.model_tier with
          | Some tier -> Some tier
          | None -> infer_model_tier_from_model_name spec.spawn_model)
    in
    let heuristic =
      heuristic_routing ~spawn_prompt:spec.spawn_prompt ~spawn_role:spec.spawn_role
        ~worker_class:spec.worker_class ~task_profile:spec.task_profile
        ~risk_level:spec.risk_level ~model_tier:explicit_tier
        ~routing_confidence:spec.routing_confidence
        ~routing_reason:spec.routing_reason
    in
    let decision =
      match heuristic with
      | Some decision ->
          let confidence =
            Option.value ~default:1.0 decision.confidence
          in
          if confidence >= router_judge_confidence_threshold ()
             || Option.is_some spec.task_profile
             || Option.is_some spec.model_tier
             || Option.is_some spec.worker_size
          then
            decision
          else
            (match llm_judge_routing ~spawn_prompt:spec.spawn_prompt
                     ~spawn_role:spec.spawn_role ~worker_class:spec.worker_class with
            | Some llm -> llm
            | None ->
                {
                  decision with
                  model_tier = Team_session_types.Tier_35b;
                  risk_level = Team_session_types.Risk_high;
                  reason = decision.reason ^ "; fallback:uncertain->35b";
                  escalated = true;
                })
      | None -> (
          match llm_judge_routing ~spawn_prompt:spec.spawn_prompt
                   ~spawn_role:spec.spawn_role ~worker_class:spec.worker_class with
          | Some llm -> llm
          | None ->
              {
                model_tier = Option.value ~default:Team_session_types.Tier_35b explicit_tier;
                task_profile =
                  Option.value ~default:Team_session_types.Profile_synthesize
                    spec.task_profile;
                risk_level =
                  Option.value ~default:Team_session_types.Risk_high spec.risk_level;
                confidence = Some 0.0;
                reason = Option.value ~default:"fallback:ambiguous->35b" spec.routing_reason;
                judge_used = false;
                escalate_if =
                  [ "worker failure"; "schema mismatch"; "context pressure"; "evidence conflict" ];
                escalated = true;
              })
    in
    let spawn_model, model_tier, routing_escalated, routing_reason =
      finalize_routing_decision ~spawn_model:spec.spawn_model ~decision
    in
    let routing_confidence =
      match spec.routing_confidence with
      | Some _ as explicit -> explicit
      | None -> decision.confidence
    in
    let routing_note =
      routing_summary_line { decision with model_tier; reason = routing_reason; escalated = routing_escalated }
    in
    let worker_size =
      match spec.worker_size with
      | Some _ as explicit -> explicit
      | None -> Team_session_types.worker_size_of_model_tier model_tier
    in
    {
      spec with
      spawn_agent = normalize_spawn_agent spec.spawn_agent;
      spawn_model;
      model_tier = Some model_tier;
      worker_size;
      task_profile = Some decision.task_profile;
      risk_level = Some decision.risk_level;
      routing_confidence;
      routing_reason = Some routing_reason;
      spawn_selection_note =
        merge_selection_note spec.spawn_selection_note routing_note;
    }

let hierarchy_lane_ids = [| "lane-a"; "lane-b"; "lane-c"; "lane-d" |]

let hierarchy_lane_id_of_index index =
  hierarchy_lane_ids.(index mod Array.length hierarchy_lane_ids)

let inferred_control_domain_of_spec (spec : spawn_spec) =
  match spec.control_domain with
  | Some domain -> Some domain
  | None -> (
      match (spec.worker_class, spec.task_profile) with
      | Some Team_session_types.Worker_metacog, _ ->
          Some Team_session_types.Domain_meta
      | Some Team_session_types.Worker_scout, _
      | Some Team_session_types.Worker_librarian, _ ->
          Some Team_session_types.Domain_knowledge
      | _, Some Team_session_types.Profile_verify ->
          Some Team_session_types.Domain_quality
      | _, Some Team_session_types.Profile_extract
      | _, Some Team_session_types.Profile_summarize ->
          Some Team_session_types.Domain_knowledge
      | _ -> Some Team_session_types.Domain_execution)

let inferred_controller_level_of_spec (spec : spawn_spec) =
  match spec.worker_class with
  | Some Team_session_types.Worker_manager -> Some Team_session_types.Controller_lane
  | Some Team_session_types.Worker_metacog
  | Some Team_session_types.Worker_scout
  | Some Team_session_types.Worker_librarian ->
      Some Team_session_types.Controller_submanager
  | _ -> Some Team_session_types.Controller_worker

let inferred_lane_id_of_spec ~index (spec : spawn_spec) =
  match spec.lane_id with
  | Some lane -> Some lane
  | None -> (
      match spec.worker_class with
      | Some Team_session_types.Worker_metacog -> Some "global"
      | _ -> Some (hierarchy_lane_id_of_index index))

let inferred_supervisor_actor_of_spec ~lane_id ~control_domain (spec : spawn_spec)
    =
  match spec.supervisor_actor with
  | Some actor -> Some actor
  | None -> (
      match spec.worker_class with
      | Some Team_session_types.Worker_manager -> Some "ctrl-root"
      | _ -> (
          match (lane_id, control_domain) with
          | _, Some Team_session_types.Domain_meta -> Some "ctrl-global-metacog"
          | _, Some Team_session_types.Domain_runtime -> Some "ctrl-runtime-warden"
          | Some "global", _ -> Some "ctrl-root"
          | Some lane, Some Team_session_types.Domain_quality ->
              Some (Printf.sprintf "ctrl-%s-quality" lane)
          | Some lane, Some Team_session_types.Domain_knowledge ->
              Some (Printf.sprintf "ctrl-%s-knowledge" lane)
          | Some lane, _ -> Some (Printf.sprintf "ctrl-%s" lane)
          | None, _ -> Some "ctrl-root"))

let controller_target_tier_of_spec ~control_domain (spec : spawn_spec) =
  match control_domain with
  | Some Team_session_types.Domain_meta -> Team_session_types.Tier_35b
  | Some Team_session_types.Domain_quality
  | Some Team_session_types.Domain_knowledge -> Team_session_types.Tier_27b
  | _ -> (
      match spec.worker_class with
      | Some Team_session_types.Worker_manager -> Team_session_types.Tier_27b
      | _ ->
          Option.value
            ~default:(Option.value ~default:Team_session_types.Tier_9b spec.model_tier)
            spec.model_tier)

let annotate_control_hierarchy_for_session
    (session : Team_session_types.session) (specs : spawn_spec list) =
  if
    session.control_profile <> Team_session_types.Control_hierarchical_quality_v1
  then
    specs
  else
    List.mapi
      (fun index spec ->
        let lane_id = inferred_lane_id_of_spec ~index spec in
        let control_domain = inferred_control_domain_of_spec spec in
        let supervisor_actor =
          inferred_supervisor_actor_of_spec ~lane_id ~control_domain spec
        in
        let model_tier =
          match spec.worker_size with
          | Some worker_size ->
              Team_session_types.model_tier_of_worker_size worker_size
          | None -> (
              match (spec.model_tier_explicit, spec.model_tier) with
              | true, Some explicit -> Some explicit
              | _ -> Some (controller_target_tier_of_spec ~control_domain spec))
        in
        let spawn_model =
          match (spec.spawn_model_explicit, trim_opt spec.spawn_model) with
          | true, (Some _ as explicit) -> explicit
          | _ -> (
              match model_tier with
              | Some Team_session_types.Tier_35b -> inferred_lead_model ()
              | Some Team_session_types.Tier_27b -> inferred_middle_model ()
              | Some Team_session_types.Tier_9b -> inferred_worker_model ()
              | None -> spec.spawn_model)
        in
        {
          spec with
          spawn_model;
          lane_id;
          control_domain;
          supervisor_actor;
          model_tier;
        })
      specs

let parse_spawn_spec_from_object ?(default_timeout = 300)
    ?top_level_worker_policy batch_index json =
  match find_present_json_key legacy_spawn_fields json with
  | Some field -> Error (legacy_spawn_field_error ~batch_index field)
  | None ->
  let open Yojson.Safe.Util in
  let get_required_string key =
    match member key json with
    | `String s ->
        let trimmed = String.trim s in
        if trimmed = "" then
          Error
            (Printf.sprintf "spawn_batch[%d].%s is required" batch_index key)
        else
          Ok trimmed
    | _ ->
        Error
          (Printf.sprintf "spawn_batch[%d].%s is required" batch_index key)
  in
  let get_optional_string key =
    match member key json with
    | `String s ->
        let trimmed = String.trim s in
        if trimmed = "" then None else Some trimmed
    | _ -> None
  in
  let get_optional_worker_class key =
    Option.bind
      (get_optional_string key)
      (fun raw ->
        Team_session_types.worker_class_of_string
          (String.lowercase_ascii (String.trim raw)))
  in
  let get_optional_worker_size key =
    Option.bind
      (get_optional_string key)
      (fun raw ->
        Team_session_types.worker_size_of_string
          (String.lowercase_ascii (String.trim raw)))
  in
  let get_optional_execution_scope key =
    Option.map
      Team_session_types.execution_scope_of_string
      (get_optional_string key)
  in
  let get_optional_task_profile key =
    Option.bind
      (get_optional_string key)
      (fun raw ->
        Team_session_types.task_profile_of_string
          (String.lowercase_ascii (String.trim raw)))
  in
  let get_optional_risk_level key =
    Option.bind
      (get_optional_string key)
      (fun raw ->
        Team_session_types.risk_level_of_string
          (String.lowercase_ascii (String.trim raw)))
  in
  let get_optional_capsule_mode key =
    Option.bind
      (get_optional_string key)
      (fun raw ->
        Team_session_types.capsule_mode_of_string
          (String.lowercase_ascii (String.trim raw)))
  in
  let get_optional_control_domain key =
    Option.bind
      (get_optional_string key)
      (fun raw ->
        Team_session_types.control_domain_of_string
          (String.lowercase_ascii (String.trim raw)))
  in
  let get_optional_float key =
    match member key json with
    | `Float value -> Some value
    | `Int value -> Some (float_of_int value)
    | `Intlit raw -> (try Some (float_of_string raw) with Failure _ -> None)
    | _ -> None
  in
  let get_timeout key =
    match member key json with
    | `Int n -> max 1 n
    | `Intlit s -> (try max 1 (int_of_string s) with Failure _ -> default_timeout)
    | _ -> default_timeout
  in
  let worker_policy =
    match member "worker_policy" json with
    | `Assoc _ as obj -> Some obj
    | _ -> None
  in
  let policy_json key =
    let lookup = function
      | Some obj -> (
          match member key obj with
          | `Null -> None
          | value -> Some value)
      | None -> None
    in
    match lookup worker_policy with
    | Some value -> Some value
    | None -> lookup top_level_worker_policy
  in
  let policy_bool key =
    match policy_json key with
    | Some value -> (
        match value with
        | `Bool value -> Some value
        | _ -> None)
    | None -> None
  in
  let policy_int key =
    match policy_json key with
    | Some value -> (
        match value with
        | `Int value -> Some (max 1 value)
        | `Intlit raw -> (try Some (max 1 (int_of_string raw)) with Failure _ -> None)
        | _ -> None)
    | None -> None
  in
  match get_required_string "spawn_prompt" with
  | Ok spawn_prompt ->
      Ok
        {
          spawn_agent = "default";
          spawn_prompt;
          spawn_model = None;
          spawn_model_explicit = false;
          spawn_role = get_optional_string "spawn_role";
          execution_scope =
            (match get_optional_execution_scope "execution_scope" with
            | Some _ as explicit -> explicit
            | None ->
                default_execution_scope_for_worker_class
                  (get_optional_worker_class "worker_class"));
          thinking_enabled = policy_bool "thinking";
          max_turns = policy_int "max_turns";
          worker_class = get_optional_worker_class "worker_class";
          worker_size = get_optional_worker_size "worker_size";
          parent_actor = get_optional_string "parent_actor";
          capsule_mode = get_optional_capsule_mode "capsule_mode";
          runtime_pool = get_optional_string "runtime_pool";
          lane_id = get_optional_string "lane_id";
          control_domain = get_optional_control_domain "control_domain";
          supervisor_actor = get_optional_string "supervisor_actor";
          model_tier = None;
          model_tier_explicit = false;
          task_profile = get_optional_task_profile "task_profile";
          risk_level = get_optional_risk_level "risk_level";
          routing_confidence = get_optional_float "routing_confidence";
          routing_reason = get_optional_string "routing_reason";
          spawn_selection_note = get_optional_string "spawn_selection_note";
          spawn_timeout_seconds =
            Option.value ~default:(get_timeout "spawn_timeout_seconds")
              (policy_int "timeout_seconds");
        }
  | Error e -> Error e

let parse_step_spawn_specs args =
  match find_present_json_key legacy_spawn_fields args with
  | Some field -> Error (legacy_spawn_field_error field)
  | None ->
  let singular_prompt = get_string_opt args "spawn_prompt" in
  let singular_present = Option.is_some singular_prompt in
  let default_batch_timeout =
    match Yojson.Safe.Util.member "spawn_timeout_seconds" args with
    | `Int value -> max 1 value
    | `Intlit raw -> (try max 1 (int_of_string raw) with Failure _ -> 300)
    | _ -> max 1 (get_int args "spawn_timeout_seconds" 300)
  in
  let batch_specs_result =
    let top_level_worker_policy =
      match Yojson.Safe.Util.member "worker_policy" args with
      | `Assoc _ as obj -> Some obj
      | _ -> None
    in
    match Yojson.Safe.Util.member "spawn_batch" args with
    | `Null -> Ok []
    | `List xs ->
        let rec loop idx acc = function
          | [] -> Ok (List.rev acc)
          | json :: rest -> (
              match
                parse_spawn_spec_from_object ~default_timeout:default_batch_timeout
                  ?top_level_worker_policy
                  idx json
              with
              | Ok spec -> loop (idx + 1) (spec :: acc) rest
              | Error e -> Error e)
        in
        loop 0 [] xs
    | _ -> Error "spawn_batch must be an array"
  in
  match batch_specs_result with
  | Error e -> Error e
  | Ok batch_specs ->
      let route_specs specs = Ok (List.map resolve_routing_for_spec specs) in
      if singular_present && batch_specs <> [] then
        Error "spawn_batch cannot be combined with top-level spawn_prompt"
      else if batch_specs <> [] then
        route_specs batch_specs
      else
        match singular_prompt with
        | None -> Ok []
        | Some spawn_prompt ->
            let worker_policy =
              match Yojson.Safe.Util.member "worker_policy" args with
              | `Assoc _ as obj -> Some obj
              | _ -> None
            in
            let policy_bool key =
              match worker_policy with
              | Some obj -> (
                  match Yojson.Safe.Util.member key obj with
                  | `Bool value -> Some value
                  | _ -> None)
              | None -> None
            in
            let policy_int key =
              match worker_policy with
              | Some obj -> (
                  match Yojson.Safe.Util.member key obj with
                  | `Int value -> Some (max 1 value)
                  | `Intlit raw -> (try Some (max 1 (int_of_string raw)) with Failure _ -> None)
                  | _ -> None)
              | None -> None
            in
            route_specs
              [
                {
                  spawn_agent = "default";
                  spawn_prompt;
                  spawn_model = None;
                  spawn_model_explicit = false;
                  spawn_role = get_string_opt args "spawn_role";
                  execution_scope =
                    (match
                       Option.map
                         Team_session_types.execution_scope_of_string
                         (get_string_opt args "execution_scope")
                     with
                    | Some _ as explicit -> explicit
                    | None -> Some Team_session_types.Limited_code_change);
                  thinking_enabled = policy_bool "thinking";
                  max_turns = policy_int "max_turns";
                  worker_class =
                    Option.bind
                      (get_string_opt args "worker_class")
                      (fun raw ->
                        Team_session_types.worker_class_of_string
                          (String.lowercase_ascii (String.trim raw)));
                  worker_size =
                    Option.bind
                      (get_string_opt args "worker_size")
                      (fun raw ->
                        Team_session_types.worker_size_of_string
                          (String.lowercase_ascii (String.trim raw)));
                  parent_actor = get_string_opt args "parent_actor";
                  capsule_mode =
                    Option.bind
                      (get_string_opt args "capsule_mode")
                      (fun raw ->
                        Team_session_types.capsule_mode_of_string
                          (String.lowercase_ascii (String.trim raw)));
                  runtime_pool = get_string_opt args "runtime_pool";
                  lane_id = get_string_opt args "lane_id";
                  control_domain =
                    Option.bind
                      (get_string_opt args "control_domain")
                      (fun raw ->
                        Team_session_types.control_domain_of_string
                          (String.lowercase_ascii (String.trim raw)));
                  supervisor_actor = get_string_opt args "supervisor_actor";
                  model_tier = None;
                  model_tier_explicit = false;
                  task_profile =
                    Option.bind
                      (get_string_opt args "task_profile")
                      (fun raw ->
                        Team_session_types.task_profile_of_string
                          (String.lowercase_ascii (String.trim raw)));
                  risk_level =
                    Option.bind
                      (get_string_opt args "risk_level")
                      (fun raw ->
                        Team_session_types.risk_level_of_string
                          (String.lowercase_ascii (String.trim raw)));
                  routing_confidence = get_float_opt args "routing_confidence";
                  routing_reason = get_string_opt args "routing_reason";
                  spawn_selection_note = get_string_opt args "spawn_selection_note";
                  spawn_timeout_seconds =
                    Option.value ~default:(get_int args "spawn_timeout_seconds" 300)
                      (policy_int "timeout_seconds");
                };
              ]

let planned_worker_of_spec ?runtime_actor (spec : spawn_spec) :
    Team_session_types.planned_worker =
  {
    spawn_agent = spec.spawn_agent;
    runtime_actor;
    spawn_role = spec.spawn_role;
    spawn_model = spec.spawn_model;
    execution_scope = effective_execution_scope_of_spec spec;
    thinking_enabled = spec.thinking_enabled;
    max_turns = spec.max_turns;
    timeout_seconds = Some spec.spawn_timeout_seconds;
    worker_class = spec.worker_class;
    parent_actor = spec.parent_actor;
    capsule_mode = spec.capsule_mode;
    runtime_pool = spec.runtime_pool;
    lane_id = spec.lane_id;
    controller_level = inferred_controller_level_of_spec spec;
    control_domain = spec.control_domain;
    supervisor_actor = spec.supervisor_actor;
    model_tier = spec.model_tier;
    task_profile = spec.task_profile;
    risk_level = spec.risk_level;
    routing_confidence = spec.routing_confidence;
    routing_reason = spec.routing_reason;
    routing_escalated =
      (match spec.routing_reason with
      | Some reason ->
          contains_ci reason "fallback:"
          || contains_ci reason "escalate"
          || contains_ci reason "uncertain->35b"
      | None -> false);
  }

let resolve_target_worker_name config (session : Team_session_types.session)
    target_agent =
  let trimmed = String.trim target_agent in
  let matches_runtime_actor worker =
    match worker.Team_session_types.runtime_actor with
    | Some actor -> String.equal (String.trim actor) trimmed
    | None -> false
  in
  let matches_role worker =
    match worker.Team_session_types.spawn_role with
    | Some role -> String.equal (String.trim role) trimmed
    | None -> false
  in
  match List.find_opt matches_runtime_actor session.planned_workers with
  | Some worker -> worker.Team_session_types.runtime_actor
  | None -> (
      match
        session.planned_workers |> List.filter matches_role
      with
      | [ worker ] -> worker.Team_session_types.runtime_actor
      | _ ->
          let worker_dir =
            Team_session_store.worker_container_dir config session.session_id
              trimmed
          in
          if Room_utils.path_exists config worker_dir then Some trimmed else None)

let register_planned_workers config session_id workers =
  match Team_session_store.update_session config session_id (fun session ->
            {
              session with
              planned_workers =
                Team_session_types.dedup_planned_workers
                  (session.planned_workers @ workers);
              updated_at_iso = Types.now_iso ();
            })
  with
  | Ok updated ->
      Team_session_store.append_event config session_id
        ~event_type:"session_planned_workers_updated"
        ~detail:
          (`Assoc
            [
              ("planned_worker_count", `Int (List.length updated.planned_workers));
              ( "worker_class_counts",
                Team_session_types.worker_class_counts updated.planned_workers
                |> Team_session_types.counts_to_json );
              ( "runtime_pool_counts",
                Team_session_types.runtime_pool_counts updated.planned_workers
                |> Team_session_types.counts_to_json );
              ( "lane_counts",
                Team_session_types.lane_counts updated.planned_workers
                |> Team_session_types.counts_to_json );
              ( "controller_counts",
                Team_session_types.controller_level_counts updated.planned_workers
                |> Team_session_types.counts_to_json );
              ( "control_domain_counts",
                Team_session_types.control_domain_counts updated.planned_workers
                |> Team_session_types.counts_to_json );
              ( "tier_counts",
                Team_session_types.model_tier_counts updated.planned_workers
                |> Team_session_types.counts_to_json );
              ( "worker_size_counts",
                Team_session_types.worker_size_counts updated.planned_workers
                |> Team_session_types.counts_to_json );
              ( "task_profile_counts",
                Team_session_types.task_profile_counts updated.planned_workers
                |> Team_session_types.counts_to_json );
              ( "escalation_count",
                `Int
                  (Team_session_types.escalation_count updated.planned_workers)
              );
              ( "runtime_actors",
                `List
                  (workers
                  |> List.filter_map (fun worker ->
                         worker.Team_session_types.runtime_actor)
                  |> List.map (fun actor -> `String actor)) );
              ("ts_iso", `String (Types.now_iso ()));
            ]);
      Ok ()
  | Error e -> Error e

let ensure_session_actor config session_id actor_name =
  match Team_session_store.update_session config session_id (fun session ->
            let agent_names =
              Team_session_types.dedup_strings (session.agent_names @ [ actor_name ])
            in
            { session with agent_names; updated_at_iso = Types.now_iso () })
  with
  | Ok updated ->
      Team_session_store.append_event config session_id
        ~event_type:"session_agent_attached"
        ~detail:
          (`Assoc
            [
              ("actor", `String actor_name);
              ("agent_count", `Int (List.length updated.agent_names));
              ("ts_iso", `String (Types.now_iso ()));
            ]);
      Ok ()
  | Error e -> Error e

let detach_session_actor config session_id actor_name ~reason =
  match Team_session_store.update_session config session_id (fun session ->
            let agent_names =
              List.filter
                (fun existing -> not (String.equal existing actor_name))
                session.agent_names
            in
            { session with agent_names; updated_at_iso = Types.now_iso () })
  with
  | Ok updated ->
      Team_session_store.append_event config session_id
        ~event_type:"session_agent_detached"
        ~detail:
          (`Assoc
            [
              ("actor", `String actor_name);
              ("reason", `String reason);
              ("agent_count", `Int (List.length updated.agent_names));
              ("ts_iso", `String (Types.now_iso ()));
            ]);
      Ok ()
  | Error e -> Error e

let session_has_turn_for_actor config session_id actor_name =
  Team_session_store.read_events config session_id
  |> List.exists (fun json ->
         match
           ( Yojson.Safe.Util.member "event_type" json,
             Yojson.Safe.Util.member "detail" json
             |> Yojson.Safe.Util.member "actor" )
         with
         | `String "team_turn", `String recorded_actor ->
             String.equal (String.trim recorded_actor) actor_name
         | _ -> false)

let auto_note_message_of_spawn_output output =
  let trimmed = String.trim output in
  if trimmed = "" then
    None
  else
    Some ("[auto-note] " ^ truncate_for_event ~max_len:480 trimmed)

let reconcile_failed_spawn_actor config session_id actor_name =
  if session_has_turn_for_actor config session_id actor_name then
    Ok `Retained
  else
    detach_session_actor config session_id actor_name
      ~reason:"spawn_failed_without_turn"
    |> Result.map (fun () -> `Detached)

let extract_vote_id (text : string) =
  let re = Str.regexp "vote-[0-9-]+-[0-9]+" in
  try
    let _ = Str.search_forward re text 0 in
    Some (Str.matched_string text)
  with Not_found -> None

let status_of_engine_status_json (json : Yojson.Safe.t) =
  match Yojson.Safe.Util.member "session" json |> Yojson.Safe.Util.member "status" with
  | `String s -> s
  | _ -> "unknown"

let handle_step ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let session_opt = Team_session_store.load_session ctx.config session_id in
          let spawn_specs_result = parse_step_spawn_specs args in
          match spawn_specs_result with
          | Error e -> (false, json_error e)
          | Ok raw_spawn_specs ->
              let spawn_specs =
                match session_opt with
                | Some session ->
                    annotate_control_hierarchy_for_session session raw_spawn_specs
                | None -> raw_spawn_specs
              in
              let delegate_prompt_opt = get_string_opt args "delegate_prompt" in
              let turn_kind_result =
                if spawn_specs <> [] || Option.is_some delegate_prompt_opt then
                  parse_turn_kind_opt args
                else
                  match parse_turn_kind args with
                  | Ok kind -> Ok (Some kind)
                  | Error e -> Error e
              in
              match turn_kind_result with
              | Error e -> (false, json_error e)
              | Ok turn_kind_opt ->
              let actor_result =
                match get_string_opt args "actor" with
                | None -> Ok ctx.agent_name
                | Some actor_name
                  when String.equal (String.trim actor_name) ctx.agent_name ->
                    Ok ctx.agent_name
                | Some _ ->
                    Error
                      "actor must match the authenticated caller; omit actor to use the current agent"
              in
              match actor_result with
              | Error e -> (false, json_error e)
              | Ok actor ->
              let wait_mode = parse_wait_mode args in
              let base_message = get_string_opt args "message" in
              let target_agent = get_string_opt args "target_agent" in
              let delegate_prompt = delegate_prompt_opt in
              let task_title = get_string_opt args "task_title" in
              let task_description = get_string_opt args "task_description" in
              let task_priority = get_int args "task_priority" 3 in
              let append_spawn_event ?worker_run_id ?spawn_agent ?runtime_actor ?spawn_role
                  ?spawn_model ?execution_scope ?worker_class ?worker_size
                  ?worker_backend ?wait_mode ?trace_capability
                  ?parent_actor ?capsule_mode
                  ?runtime_pool ?lane_id ?controller_level ?control_domain
                  ?supervisor_actor ?model_tier ?task_profile ?risk_level
                  ?routing_confidence ?routing_reason ?assigned_runtime
                  ?spawn_selection_note ?tool_names ?tool_call_count ~success
                  ?exit_code
                  ?elapsed_ms ?output_preview ?error () =
                let _ = spawn_agent and _ = spawn_model and _ = model_tier in
                let detail =
                  `Assoc
                    [
                      ("actor", `String actor);
                      ("worker_run_id", Option.fold ~none:`Null ~some:(fun s -> `String s) worker_run_id);
                      ( "runtime_actor",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          runtime_actor );
                      ( "spawn_role",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          spawn_role );
                      ( "execution_scope",
                        Option.fold ~none:`Null
                          ~some:(fun scope ->
                            `String
                              (Team_session_types.execution_scope_to_string
                                 scope))
                          execution_scope );
                      ( "worker_class",
                        Option.fold ~none:`Null
                          ~some:(fun kind ->
                            `String
                              (Team_session_types.worker_class_to_string kind))
                          worker_class );
                      ( "worker_size",
                        Option.fold ~none:`Null
                          ~some:(fun size ->
                            `String
                              (Team_session_types.worker_size_to_string size))
                          worker_size );
                      ( "worker_backend",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          worker_backend );
                      ( "wait_mode",
                        Option.fold ~none:`Null ~some:(fun mode -> `String mode)
                          wait_mode );
                      ( "trace_capability",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          trace_capability );
                      ( "parent_actor",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          parent_actor );
                      ( "capsule_mode",
                        Option.fold ~none:`Null
                          ~some:(fun mode ->
                            `String
                              (Team_session_types.capsule_mode_to_string mode))
                          capsule_mode );
                      ( "runtime_pool",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          runtime_pool );
                      ( "lane_id",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          lane_id );
                      ( "controller_level",
                        Option.fold ~none:`Null
                          ~some:(fun level ->
                            `String
                              (Team_session_types.controller_level_to_string
                                 level))
                          controller_level );
                      ( "control_domain",
                        Option.fold ~none:`Null
                          ~some:(fun domain ->
                            `String
                              (Team_session_types.control_domain_to_string
                                 domain))
                          control_domain );
                      ( "supervisor_actor",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          supervisor_actor );
                      ( "task_profile",
                        Option.fold ~none:`Null
                          ~some:(fun profile ->
                            `String
                              (Team_session_types.task_profile_to_string
                                 profile))
                          task_profile );
                      ( "risk_level",
                        Option.fold ~none:`Null
                          ~some:(fun level ->
                            `String
                              (Team_session_types.risk_level_to_string level))
                          risk_level );
                      ("routing_confidence", float_opt_to_json routing_confidence);
                      ( "routing_reason",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          routing_reason );
                      ( "assigned_runtime",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          assigned_runtime );
                      ( "spawn_selection_note",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          spawn_selection_note );
                      ( "tool_names",
                        Option.fold ~none:(`List [])
                          ~some:(fun names ->
                            `List (List.map (fun name -> `String name) names))
                          tool_names );
                      ( "tool_call_count",
                        Option.fold ~none:`Null ~some:(fun n -> `Int n)
                          tool_call_count );
                      ("success", `Bool success);
                      ("exit_code", int_opt_to_json exit_code);
                      ("elapsed_ms", int_opt_to_json elapsed_ms);
                      ( "output_preview",
                        Option.fold ~none:`Null ~some:(fun s -> `String s)
                          output_preview );
                      ("error", Option.fold ~none:`Null ~some:(fun s -> `String s) error);
                      ("ts_iso", `String (Types.now_iso ()));
                    ]
                in
                Team_session_store.append_event ctx.config session_id
                  ~event_type:"team_step_spawn" ~detail
              in
              let append_delegate_event ~worker_run_id ~worker_name ~delegate_prompt ~success
                  ?execution_scope ?wait_mode ?trace_capability
                  ?resolved_runtime ?resolved_model ?routing_reason
                  ?tool_names ?tool_call_count ?output_preview ?error () =
                Team_session_store.append_event ctx.config session_id
                  ~event_type:"team_step_delegate"
                  ~detail:
                    (`Assoc
                      [
                        ("actor", `String actor);
                        ("worker_run_id", `String worker_run_id);
                        ("target_agent", `String worker_name);
                        ("delegate_prompt", `String delegate_prompt);
                        ("worker_backend", `String "local");
                        ("execution_scope", Option.fold ~none:`Null ~some:(fun scope -> `String (Team_session_types.execution_scope_to_string scope)) execution_scope);
                        ("wait_mode", Option.fold ~none:`Null ~some:(fun mode -> `String mode) wait_mode);
                        ("trace_capability", Option.fold ~none:`Null ~some:(fun s -> `String s) trace_capability);
                        ("resolved_runtime", Option.fold ~none:`Null ~some:(fun s -> `String s) resolved_runtime);
                        ("resolved_model", Option.fold ~none:`Null ~some:(fun s -> `String s) resolved_model);
                        ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) routing_reason);
                        ("success", `Bool success);
                        ( "tool_names",
                          Option.fold ~none:(`List [])
                            ~some:(fun names ->
                              `List (List.map (fun name -> `String name) names))
                            tool_names );
                        ( "tool_call_count",
                          Option.fold ~none:`Null ~some:(fun n -> `Int n)
                            tool_call_count );
                        ( "output_preview",
                          Option.fold ~none:`Null ~some:(fun s -> `String s)
                            output_preview );
                        ( "error",
                          Option.fold ~none:`Null ~some:(fun s -> `String s)
                            error );
                        ("ts_iso", `String (Types.now_iso ()));
                      ])
              in
              let append_spawn_requested_event ~worker_run_id prepared =
                Team_session_store.append_event ctx.config session_id
                  ~event_type:"team_step_spawn_requested"
                  ~detail:
                    (`Assoc
                      [
                        ("actor", `String actor);
                        ("worker_run_id", `String worker_run_id);
                        ( "runtime_actor",
                          Option.fold ~none:`Null
                            ~some:(fun s -> `String s)
                            prepared.runtime_actor_name );
                        ("spawn_role", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.spawn_role);
                        ("worker_backend", if is_local_spawn_agent prepared.spec.spawn_agent then `String "local" else `Null);
                        ("wait_mode", `String (Team_session_types.wait_mode_to_string wait_mode));
                        ("resolved_runtime", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.assigned_runtime);
                        ("resolved_model", `String prepared.runtime_model.model_id);
                        ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.routing_reason);
                        ("ts_iso", `String (Types.now_iso ()));
                      ])
              in
              let append_delegate_requested_event ~worker_run_id ~worker_name ~delegate_prompt =
                Team_session_store.append_event ctx.config session_id
                  ~event_type:"team_step_delegate_requested"
                  ~detail:
                    (`Assoc
                      [
                        ("actor", `String actor);
                        ("worker_run_id", `String worker_run_id);
                        ("target_agent", `String worker_name);
                        ("delegate_prompt", `String delegate_prompt);
                        ("worker_backend", `String "local");
                        ("wait_mode", `String (Team_session_types.wait_mode_to_string wait_mode));
                        ("ts_iso", `String (Types.now_iso ()));
                      ])
              in
              let persist_worker_run_snapshot ~worker_run_id ~worker_name
                  ~mode ~wait_mode ?execution_scope ?tool_names ?tool_call_count
                  ?requested_worker_class ?requested_worker_size
                  ?resolved_runtime ?resolved_model ?routing_reason
                  ~status
                  ~success ?output_preview ?error ?trace_capability ?trace_ref
                  ?trace_summary ?trace_validation ?evidence_session_id
                  () =
                let checkpoint_path =
                  Team_session_store.worker_container_checkpoint_path ctx.config
                    session_id worker_name
                in
                let oas_evidence =
                  Option.bind evidence_session_id (fun evidence_session_id ->
                      oas_worker_evidence_payload ~config:ctx.config
                        ~evidence_session_id)
                in
                let effective_trace_ref =
                  match Option.bind oas_evidence (fun payload -> payload.trace_ref) with
                  | Some _ as value -> value
                  | None -> trace_ref
                in
                let effective_trace_summary =
                  match
                    Option.bind oas_evidence (fun payload ->
                        payload.trace_summary_json)
                  with
                  | Some _ as value -> value
                  | None -> trace_summary
                in
                let effective_trace_validation =
                  match
                    Option.bind oas_evidence (fun payload ->
                        payload.trace_validation_json)
                  with
                  | Some _ as value -> value
                  | None -> trace_validation
                in
                let oas_worker =
                  Option.bind oas_evidence (fun payload -> payload.worker)
                in
                let effective_status =
                  match oas_worker with
                  | Some worker -> oas_worker_status_to_json worker.status
                  | None -> worker_run_status_to_json status
                in
                let trace_capability =
                  match trace_capability with
                  | _ when Option.is_some oas_worker ->
                      Option.value ~default:"summary_only"
                        (Option.map
                           (fun worker ->
                             oas_trace_capability_to_string
                               worker.Oas.Sessions.trace_capability)
                           oas_worker)
                  | Some value -> value
                  | None when Option.is_some effective_trace_ref -> "raw"
                  | None -> ignore checkpoint_path; "summary_only"
                in
                let effective_tool_names =
                  match oas_worker with
                  | Some worker when worker.tool_names <> [] -> worker.tool_names
                  | _ -> Option.value ~default:[] tool_names
                in
                let effective_resolved_model =
                  match oas_worker with
                  | Some worker -> (
                      match worker.resolved_model with
                      | Some _ as value -> value
                      | None -> resolved_model)
                  | None -> resolved_model
                in
                let effective_error =
                  match oas_worker with
                  | Some worker -> (
                      match worker.failure_reason with
                      | Some _ as value -> value
                      | None -> (
                          match worker.error with
                          | Some _ as value -> value
                          | None -> error))
                  | None -> error
                in
                let effective_output_preview =
                  match oas_worker with
                  | Some worker -> (
                      match worker.final_text with
                      | Some final_text when String.trim final_text <> "" ->
                          Some (truncate_for_event final_text)
                      | _ -> output_preview)
                  | None -> output_preview
                in
                if Room_utils.path_exists ctx.config checkpoint_path then
                  Team_session_store.save_worker_run_checkpoint_text ctx.config
                    session_id worker_run_id
                    (Team_session_store.read_text_file checkpoint_path);
                Team_session_store.save_worker_run_meta_json ctx.config session_id
                  worker_run_id
                  (`Assoc
                    [
                      ("worker_run_id", `String worker_run_id);
                      ("worker_name", `String worker_name);
                      ("mode", `String mode);
                      ("status", effective_status);
                      ("wait_mode", `String (Team_session_types.wait_mode_to_string wait_mode));
                      ("trace_capability", `String trace_capability);
                      ("success", `Bool success);
                      ("execution_scope", Option.fold ~none:`Null ~some:(fun scope -> `String (Team_session_types.execution_scope_to_string scope)) execution_scope);
                      ("requested_worker_class", Option.fold ~none:`Null ~some:(fun kind -> `String (Team_session_types.worker_class_to_string kind)) requested_worker_class);
                      ("requested_worker_size", Option.fold ~none:`Null ~some:(fun size -> `String (Team_session_types.worker_size_to_string size)) requested_worker_size);
                      ("resolved_runtime", Option.fold ~none:`Null ~some:(fun s -> `String s) resolved_runtime);
                      ("resolved_model", Option.fold ~none:`Null ~some:(fun s -> `String s) effective_resolved_model);
                      ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) routing_reason);
                      ("tool_names", `List (List.map (fun name -> `String name) effective_tool_names));
                      ("tool_call_count", Option.fold ~none:`Null ~some:(fun n -> `Int n) tool_call_count);
                      ("output_preview", Option.fold ~none:`Null ~some:(fun s -> `String s) effective_output_preview);
                      ("error", Option.fold ~none:`Null ~some:(fun s -> `String s) effective_error);
                      ("trace_ref", Option.fold ~none:`Null ~some:raw_trace_run_ref_to_json effective_trace_ref);
                      ("trace_summary", Option.fold ~none:`Null ~some:(fun json -> json) effective_trace_summary);
                      ("trace_validation", Option.fold ~none:`Null ~some:(fun json -> json) effective_trace_validation);
                      ("evidence_session_id", Option.fold ~none:`Null ~some:(fun s -> `String s) evidence_session_id);
                      ("oas_worker_run", Option.fold ~none:`Null ~some:(fun json -> json) (Option.bind oas_evidence (fun payload -> payload.worker_json)));
                      ("session_conformance", Option.fold ~none:`Null ~some:(fun json -> json) (Option.bind oas_evidence (fun payload -> payload.conformance_json)));
                      ("validated", Option.fold ~none:`Null ~some:(fun worker -> `Bool worker.Oas.Sessions.validated) oas_worker);
                      ("final_text", Option.fold ~none:`Null ~some:(fun worker -> Option.fold ~none:`Null ~some:(fun s -> `String s) worker.Oas.Sessions.final_text) oas_worker);
                      ("stop_reason", Option.fold ~none:`Null ~some:(fun worker -> Option.fold ~none:`Null ~some:(fun s -> `String s) worker.Oas.Sessions.stop_reason) oas_worker);
                      ("failure_reason", Option.fold ~none:`Null ~some:(fun worker -> Option.fold ~none:`Null ~some:(fun s -> `String s) worker.Oas.Sessions.failure_reason) oas_worker);
                      ("ts_iso", `String (Types.now_iso ()));
                    ])
              in
              let release_prepared_runtime (prepared : prepared_spawn) ~success
                  ?error ?latency_ms () =
                match prepared.runtime_lease with
                | Some lease ->
                    Local_runtime_pool.release lease ~success ?error ?latency_ms ()
                | None -> ()
              in
              let release_all_prepared prepareds ~error =
                List.iter
                  (fun prepared ->
                    release_prepared_runtime prepared ~success:false ~error ())
                  prepareds
              in
              let prepare_spawn (spec : spawn_spec) =
                let runtime_actor_name =
                  if is_local_spawn_agent spec.spawn_agent then
                    Some
                      (derived_llama_runtime_actor ~session_id
                         ~prompt:spec.spawn_prompt)
                  else
                    None
                in
                let runtime_model =
                  if is_local_spawn_agent spec.spawn_agent then
                    let model_name =
                      match spec.spawn_model with
                      | Some model_name -> Some model_name
                      | None ->
                          let default_model =
                            Llm_client.default_local_model_spec ()
                          in
                          Some default_model.model_id
                    in
                    match model_name with
                    | None -> Error "local worker model resolution failed"
                    | Some model_name -> (
                        match
                          Local_runtime_pool.acquire
                            ?preferred_pool:spec.runtime_pool
                            ~model_name:(Some model_name) ()
                        with
                        | Ok assignment ->
                            Ok
                              ( Local_runtime_pool.model_spec_of_assignment
                                  assignment,
                                Some assignment.lease,
                                Some assignment.runtime_id )
                        | Error err -> Error err)
                  else
                    Ok (Llm_client.default_local_model_spec (), None, None)
                in
                match runtime_model with
                | Error e -> Error (spec, runtime_actor_name, e)
                | Ok (runtime_model, runtime_lease, assigned_runtime) ->
                    Ok
                      {
                        worker_run_id = make_worker_run_id ();
                        spec;
                        runtime_actor_name;
                        runtime_model;
                        runtime_lease;
                        assigned_runtime;
                      }
              in
              let prepared_spawns_result =
                let rec loop acc = function
                  | [] -> Ok (List.rev acc)
                  | spec :: rest -> (
                      match prepare_spawn spec with
                      | Ok prepared -> loop (prepared :: acc) rest
                      | Error (failed_spec, runtime_actor_name, msg) ->
                          release_all_prepared (List.rev acc) ~error:msg;
                          append_spawn_event ~spawn_agent:failed_spec.spawn_agent
                            ?runtime_actor:runtime_actor_name
                            ?spawn_role:failed_spec.spawn_role
                            ?spawn_model:failed_spec.spawn_model
                            ?execution_scope:
                              (effective_execution_scope_of_spec failed_spec)
                            ?worker_class:failed_spec.worker_class
                            ?worker_size:(worker_size_of_spec failed_spec)
                            ?worker_backend:
                              (if is_local_spawn_agent failed_spec.spawn_agent
                               then Some "local" else None)
                            ?parent_actor:failed_spec.parent_actor
                            ?capsule_mode:failed_spec.capsule_mode
                            ?runtime_pool:failed_spec.runtime_pool
                            ?lane_id:failed_spec.lane_id
                            ?controller_level:(inferred_controller_level_of_spec failed_spec)
                            ?control_domain:failed_spec.control_domain
                            ?supervisor_actor:failed_spec.supervisor_actor
                            ?model_tier:failed_spec.model_tier
                            ?task_profile:failed_spec.task_profile
                            ?risk_level:failed_spec.risk_level
                            ?routing_confidence:failed_spec.routing_confidence
                            ?routing_reason:failed_spec.routing_reason
                            ?spawn_selection_note:failed_spec.spawn_selection_note
                            ~success:false ~error:msg ();
                          Error msg)
                in
                loop [] spawn_specs
              in
              let spawn_result_json =
                match prepared_spawns_result with
                | Error msg -> Some (`Assoc [ ("error", `String msg) ])
                | Ok [] -> None
                | Ok prepared_spawns ->
                    let planned_workers =
                      List.map
                        (fun prepared ->
                          planned_worker_of_spec
                            ?runtime_actor:prepared.runtime_actor_name
                            prepared.spec)
                        prepared_spawns
                    in
                    let planning_error =
                      match
                        register_planned_workers ctx.config session_id
                          planned_workers
                      with
                      | Error msg -> Some msg
                      | Ok () -> None
                    in
                    match planning_error with
                    | Some msg ->
                        List.iter
                          (fun prepared ->
                            release_prepared_runtime prepared ~success:false
                              ~error:msg ();
                            append_spawn_event
                              ~spawn_agent:prepared.spec.spawn_agent
                              ?runtime_actor:prepared.runtime_actor_name
                              ?spawn_role:prepared.spec.spawn_role
                              ?spawn_model:prepared.spec.spawn_model
                              ?execution_scope:
                                (effective_execution_scope_of_spec prepared.spec)
                              ?worker_class:prepared.spec.worker_class
                              ?worker_size:(worker_size_of_spec prepared.spec)
                              ?worker_backend:
                                (if is_local_spawn_agent prepared.spec.spawn_agent
                                 then Some "local" else None)
                              ?parent_actor:prepared.spec.parent_actor
                              ?capsule_mode:prepared.spec.capsule_mode
                              ?runtime_pool:prepared.spec.runtime_pool
                              ?lane_id:prepared.spec.lane_id
                              ?controller_level:(inferred_controller_level_of_spec prepared.spec)
                              ?control_domain:prepared.spec.control_domain
                              ?supervisor_actor:prepared.spec.supervisor_actor
                              ?model_tier:prepared.spec.model_tier
                              ?task_profile:prepared.spec.task_profile
                              ?risk_level:prepared.spec.risk_level
                              ?routing_confidence:prepared.spec.routing_confidence
                              ?routing_reason:prepared.spec.routing_reason
                              ?assigned_runtime:prepared.assigned_runtime
                              ?spawn_selection_note:
                                prepared.spec.spawn_selection_note
                              ~success:false ~error:msg ())
                          prepared_spawns;
                        Some (`Assoc [ ("error", `String msg) ])
                    | None ->
                        match ctx.proc_mgr with
                        | None ->
                            let msg =
                              "process manager unavailable for team step spawn"
                            in
                            List.iter
                              (fun prepared ->
                                release_prepared_runtime prepared ~success:false
                                  ~error:msg ();
                                append_spawn_event
                                  ~worker_run_id:prepared.worker_run_id
                                  ~spawn_agent:prepared.spec.spawn_agent
                                  ?runtime_actor:prepared.runtime_actor_name
                                  ?spawn_role:prepared.spec.spawn_role
                                  ?spawn_model:prepared.spec.spawn_model
                                  ?execution_scope:
                                    (effective_execution_scope_of_spec prepared.spec)
                                  ?worker_class:prepared.spec.worker_class
                                  ?worker_size:(worker_size_of_spec prepared.spec)
                                  ?worker_backend:
                                    (if is_local_spawn_agent prepared.spec.spawn_agent
                                     then Some "local" else None)
                                  ?parent_actor:prepared.spec.parent_actor
                                  ?capsule_mode:prepared.spec.capsule_mode
                                  ?runtime_pool:prepared.spec.runtime_pool
                                  ?lane_id:prepared.spec.lane_id
                                  ?controller_level:(inferred_controller_level_of_spec prepared.spec)
                                  ?control_domain:prepared.spec.control_domain
                                  ?supervisor_actor:prepared.spec.supervisor_actor
                                  ?model_tier:prepared.spec.model_tier
                                  ?task_profile:prepared.spec.task_profile
                                  ?risk_level:prepared.spec.risk_level
                                  ?routing_confidence:
                                    prepared.spec.routing_confidence
                                  ?routing_reason:prepared.spec.routing_reason
                                  ?assigned_runtime:prepared.assigned_runtime
                                  ?spawn_selection_note:
                                    prepared.spec.spawn_selection_note
                                  ~success:false ~error:msg ())
                              prepared_spawns;
                            Some (`Assoc [ ("error", `String msg) ])
                        | Some pm ->
                            let rec ensure_all = function
                              | [] -> Ok ()
                              | prepared :: rest -> (
                                  match prepared.runtime_actor_name with
                                  | None -> ensure_all rest
                                  | Some worker_actor -> (
                                      match
                                        ensure_session_actor ctx.config
                                          session_id worker_actor
                                      with
                                      | Ok () -> ensure_all rest
                                      | Error msg -> Error msg))
                            in
                            match ensure_all prepared_spawns with
                             | Error msg ->
                                 List.iter
                                   (fun prepared ->
                                     release_prepared_runtime prepared
                                       ~success:false ~error:msg ();
                                       append_spawn_event
                                         ~worker_run_id:prepared.worker_run_id
                                         ~spawn_agent:prepared.spec.spawn_agent
                                         ?runtime_actor:prepared.runtime_actor_name
                                         ?spawn_role:prepared.spec.spawn_role
                                         ?spawn_model:prepared.spec.spawn_model
                                         ?execution_scope:
                                           (effective_execution_scope_of_spec prepared.spec)
                                         ?worker_class:prepared.spec.worker_class
                                         ?worker_size:(worker_size_of_spec prepared.spec)
                                         ?worker_backend:
                                           (if is_local_spawn_agent prepared.spec.spawn_agent
                                            then Some "local" else None)
                                         ?parent_actor:prepared.spec.parent_actor
                                       ?capsule_mode:prepared.spec.capsule_mode
                                       ?runtime_pool:prepared.spec.runtime_pool
                                       ?lane_id:prepared.spec.lane_id
                                       ?controller_level:(inferred_controller_level_of_spec prepared.spec)
                                       ?control_domain:prepared.spec.control_domain
                                       ?supervisor_actor:prepared.spec.supervisor_actor
                                       ?model_tier:prepared.spec.model_tier
                                       ?task_profile:prepared.spec.task_profile
                                       ?risk_level:prepared.spec.risk_level
                                       ?routing_confidence:
                                         prepared.spec.routing_confidence
                                       ?routing_reason:
                                         prepared.spec.routing_reason
                                       ?assigned_runtime:prepared.assigned_runtime
                                       ?spawn_selection_note:
                                         prepared.spec.spawn_selection_note
                                       ~success:false ~error:msg ())
                                   prepared_spawns;
                                 Some (`Assoc [ ("error", `String msg) ])
                             | Ok () ->
                                 let execute_spawn index prepared =
                                   let spawn_result =
                                     Spawn_eio.spawn ~sw:ctx.sw ~proc_mgr:pm
                                       ~agent_name:prepared.spec.spawn_agent
                                       ~prompt:prepared.spec.spawn_prompt
                                       ~timeout_seconds:
                                         prepared.spec.spawn_timeout_seconds
                                       ~room_config:ctx.config
                                       ?runtime_agent_name:
                                         prepared.runtime_actor_name
                                       ~runtime_model:prepared.runtime_model
                                       ?runtime_role:prepared.spec.spawn_role
                                       ?runtime_selection_note:
                                         prepared.spec.spawn_selection_note
                                       ~worker_run_id:prepared.worker_run_id
                                       ?worker_class:prepared.spec.worker_class
                                       ?worker_size:(worker_size_of_spec prepared.spec)
                                       ?execution_scope:
                                         (effective_execution_scope_of_spec prepared.spec)
                                       ?thinking_enabled:prepared.spec.thinking_enabled
                                       ?max_turns:prepared.spec.max_turns
                                       ~runtime_session_id:session_id ()
                                   in
                                 let output_preview =
                                     truncate_for_event spawn_result.output
                                   in
                                   let trace_summary_json, trace_validation_json =
                                     match spawn_result.raw_trace_run with
                                     | Some run_ref -> (
                                         match
                                           raw_trace_session_payloads
                                             ~config:ctx.config
                                             ~fallback_session_id:session_id
                                             run_ref
                                         with
                                         | Some pair -> (Some (fst pair), Some (snd pair))
                                         | None -> (None, None))
                                     | None -> (None, None)
                                   in
                                   (match spawn_result.success with
                                   | true ->
                                       release_prepared_runtime prepared
                                         ~success:true
                                         ~latency_ms:spawn_result.elapsed_ms ()
                                   | false ->
                                       release_prepared_runtime prepared
                                         ~success:false
                                         ~error:spawn_result.output
                                         ~latency_ms:spawn_result.elapsed_ms ());
                                   persist_worker_run_snapshot
                                     ~worker_run_id:prepared.worker_run_id
                                     ~worker_name:
                                       (Option.value
                                          ~default:(Printf.sprintf "spawn-%d" index)
                                          prepared.runtime_actor_name)
                                     ~mode:"spawn" ~wait_mode
                                     ~status:
                                       (if spawn_result.success then `Completed else `Failed)
                                     ?execution_scope:
                                       (effective_execution_scope_of_spec prepared.spec)
                                     ?requested_worker_class:prepared.spec.worker_class
                                     ?requested_worker_size:(worker_size_of_spec prepared.spec)
                                     ?resolved_runtime:prepared.assigned_runtime
                                     ~resolved_model:prepared.runtime_model.model_id
                                     ?routing_reason:prepared.spec.routing_reason
                                     ~tool_names:spawn_result.tool_names
                                     ~tool_call_count:spawn_result.tool_call_count
                                     ~success:spawn_result.success
                                     ~output_preview
                                     ~evidence_session_id:
                                       (Local_agent_eio
                                        .oas_worker_evidence_session_id
                                          ~worker_run_id:
                                            prepared.worker_run_id)
                                     ?trace_ref:spawn_result.raw_trace_run
                                     ?trace_summary:trace_summary_json
                                     ?trace_validation:trace_validation_json
                                       ~trace_capability:
                                       (if Option.is_some spawn_result.raw_trace_run then
                                          "raw"
                                        else if is_local_spawn_agent prepared.spec.spawn_agent
                                        then "summary_only"
                                        else "summary_only")
                                     ();
                                   append_spawn_event
                                     ~worker_run_id:prepared.worker_run_id
                                     ~spawn_agent:prepared.spec.spawn_agent
                                     ?runtime_actor:prepared.runtime_actor_name
                                     ?spawn_role:prepared.spec.spawn_role
                                     ?spawn_model:prepared.spec.spawn_model
                                     ?execution_scope:
                                       (effective_execution_scope_of_spec prepared.spec)
                                     ?worker_class:prepared.spec.worker_class
                                     ?worker_size:(worker_size_of_spec prepared.spec)
                                     ?worker_backend:
                                       (if is_local_spawn_agent prepared.spec.spawn_agent
                                        then Some "local" else None)
                                     ~wait_mode:(Team_session_types.wait_mode_to_string wait_mode)
                                     ~trace_capability:
                                       (if is_local_spawn_agent prepared.spec.spawn_agent
                                        then "summary_only"
                                        else "summary_only")
                                     ?parent_actor:prepared.spec.parent_actor
                                     ?capsule_mode:prepared.spec.capsule_mode
                                     ?runtime_pool:prepared.spec.runtime_pool
                                     ?lane_id:prepared.spec.lane_id
                                     ?controller_level:(inferred_controller_level_of_spec prepared.spec)
                                     ?control_domain:prepared.spec.control_domain
                                     ?supervisor_actor:prepared.spec.supervisor_actor
                                     ?model_tier:prepared.spec.model_tier
                                     ?task_profile:prepared.spec.task_profile
                                     ?risk_level:prepared.spec.risk_level
                                     ?routing_confidence:prepared.spec.routing_confidence
                                     ?routing_reason:prepared.spec.routing_reason
                                     ?assigned_runtime:prepared.assigned_runtime
                                     ?spawn_selection_note:
                                       prepared.spec.spawn_selection_note
                                     ~tool_names:spawn_result.tool_names
                                     ~tool_call_count:spawn_result.tool_call_count
                                     ~success:spawn_result.success
                                     ~exit_code:spawn_result.exit_code
                                     ~elapsed_ms:spawn_result.elapsed_ms
                                     ~output_preview ();
                                   (match
                                      ( spawn_result.success,
                                        prepared.runtime_actor_name,
                                        auto_note_message_of_spawn_output
                                          spawn_result.output )
                                    with
                                   | true, Some worker_actor, Some auto_note
                                     when not
                                            (session_has_turn_for_actor
                                               ctx.config session_id worker_actor) ->
                                       ignore
                                         (record_session_turn_json
                                            ~config:ctx.config ~session_id
                                            ~actor:worker_actor
                                            ~turn_kind:Team_session_types.Turn_note
                                            ~message:(Some auto_note)
                                            ~target_agent:None
                                            ~task_title:None
                                            ~task_description:None
                                            ~task_priority:3)
                                   | _ -> ());
                                   (match (spawn_result.success, prepared.runtime_actor_name) with
                                   | false, Some worker_actor ->
                                       ignore
                                         (reconcile_failed_spawn_actor
                                            ctx.config session_id worker_actor)
                                   | _ -> ());
                                   `Assoc
                                     [
                                       ("worker_run_id", `String prepared.worker_run_id);
                                       ("runtime_actor", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.runtime_actor_name);
                                       ("spawn_role", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.spawn_role);
                                       ("execution_scope", Option.fold ~none:`Null ~some:(fun scope -> `String (Team_session_types.execution_scope_to_string scope)) (effective_execution_scope_of_spec prepared.spec));
                                       ("thinking_enabled", Option.fold ~none:`Null ~some:(fun v -> `Bool v) prepared.spec.thinking_enabled);
                                       ("max_turns", Option.fold ~none:`Null ~some:(fun n -> `Int n) prepared.spec.max_turns);
                                       ("worker_class", Option.fold ~none:`Null ~some:(fun kind -> `String (Team_session_types.worker_class_to_string kind)) prepared.spec.worker_class);
                                       ("worker_size", Option.fold ~none:`Null ~some:(fun size -> `String (Team_session_types.worker_size_to_string size)) (worker_size_of_spec prepared.spec));
                                       ("worker_backend", if is_local_spawn_agent prepared.spec.spawn_agent then `String "local" else `Null);
                                       ("wait_mode", `String (Team_session_types.wait_mode_to_string wait_mode));
                                       ("status", `String "completed");
                                       ("trace_capability", `String (if Option.is_some spawn_result.raw_trace_run then "raw" else "summary_only"));
                                       ("resolved_runtime", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.assigned_runtime);
                                       ("resolved_model", `String prepared.runtime_model.model_id);
                                       ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.routing_reason);
                                       ("tool_call_count", `Int spawn_result.tool_call_count);
                                       ("tool_names", `List (List.map (fun name -> `String name) spawn_result.tool_names));
                                       ("success", `Bool spawn_result.success);
                                       ("elapsed_ms", `Int spawn_result.elapsed_ms);
                                       ("output_preview", `String output_preview);
                                     ]
                                 in
                                 (match wait_mode with
                                 | Team_session_types.Wait_background ->
                                     let sw_bg =
                                       Option.value ~default:ctx.sw
                                         (Eio_context.get_switch_opt ())
                                     in
                                     List.iter
                                       (fun prepared ->
                                         append_spawn_requested_event
                                           ~worker_run_id:prepared.worker_run_id
                                           prepared;
                                         Eio.Fiber.fork ~sw:sw_bg (fun () ->
                                             ignore (execute_spawn 0 prepared)))
                                       prepared_spawns;
                                     let accepted =
                                       prepared_spawns
                                       |> List.map (fun prepared ->
                                              `Assoc
                                                [
                                                  ("worker_run_id", `String prepared.worker_run_id);
                                                  ("status", `String "accepted");
                                                  ("wait_mode", `String "background");
                                                  ("runtime_actor", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.runtime_actor_name);
                                                  ("spawn_role", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.spawn_role);
                                                  ("worker_class", Option.fold ~none:`Null ~some:(fun kind -> `String (Team_session_types.worker_class_to_string kind)) prepared.spec.worker_class);
                                                  ("worker_size", Option.fold ~none:`Null ~some:(fun size -> `String (Team_session_types.worker_size_to_string size)) (worker_size_of_spec prepared.spec));
                                                  ("resolved_runtime", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.assigned_runtime);
                                                  ("resolved_model", `String prepared.runtime_model.model_id);
                                                  ("routing_reason", Option.fold ~none:`Null ~some:(fun s -> `String s) prepared.spec.routing_reason);
                                                  ("ready", `Bool false);
                                                ])
                                     in
                                     Some
                                       (if List.length accepted = 1 then
                                          List.hd accepted
                                        else
                                          `Assoc
                                            [
                                              ("mode", `String "batch");
                                              ("count", `Int (List.length accepted));
                                              ("results", `List accepted);
                                            ])
                                 | Team_session_types.Wait_blocking ->
                                     let results =
                                       Array.make (List.length prepared_spawns) None
                                     in
                                     Eio.Fiber.all
                                       (List.mapi
                                          (fun index prepared () ->
                                            results.(index) <- Some (execute_spawn index prepared))
                                          prepared_spawns);
                                     let spawn_results =
                                       results |> Array.to_list
                                       |> List.filter_map (fun item -> item)
                                     in
                                     Some
                                       (if List.length spawn_results = 1 then
                                          List.hd spawn_results
                                        else
                                          `Assoc
                                            [
                                              ("mode", `String "batch");
                                              ("count", `Int (List.length spawn_results));
                                              ("results", `List spawn_results);
                                            ]))
              in
              let spawn_error =
                match spawn_result_json with
                | Some (`Assoc fields) -> (
                    match List.assoc_opt "error" fields with
                    | Some (`String e) when String.trim e <> "" -> Some e
                    | _ -> None)
                | _ -> None
              in
              match spawn_error with
              | Some e -> (false, json_error e)
              | None ->
                  let turn_json_result =
                    match turn_kind_opt with
                    | None -> Ok None
                    | Some turn_kind ->
                        record_session_turn_json ~config:ctx.config ~session_id
                          ~actor ~turn_kind ~message:base_message
                          ~target_agent ~task_title ~task_description
                          ~task_priority
                        |> Result.map Option.some
                  in
                  match turn_json_result with
                  | Error e -> (false, json_error e)
                  | Ok turn_json ->
                      let delegate_result_json =
                        match (delegate_prompt, target_agent) with
                        | None, _ -> None
                        | Some _, _ when spawn_specs <> [] ->
                            Some
                              (`Assoc
                                [
                                  ( "error",
                                    `String
                                      "delegate_prompt cannot be combined with worker spawn" );
                                ])
                        | Some _, None ->
                            Some
                              (`Assoc
                                [
                                  ( "error",
                                    `String
                                      "target_agent is required when delegate_prompt is provided" );
                                ])
                        | Some delegate_prompt, Some target_agent -> (
                            match session_opt with
                            | None ->
                                Some
                                  (`Assoc
                                    [
                                      ("error", `String "team session not found");
                                    ])
                            | Some session -> (
                                match
                                  resolve_target_worker_name ctx.config session
                                    target_agent
                                with
                                | None ->
                                    Some
                                      (`Assoc
                                        [
                                          ( "error",
                                            `String
                                              "target_agent did not match a known worker container"
                                          );
                                        ])
                                | Some worker_name -> (
                                    let worker_run_id = make_worker_run_id () in
                                    let execution_scope =
                                      Option.bind session_opt (fun session ->
                                          List.find_map
                                            (fun w ->
                                              match
                                                w.Team_session_types.runtime_actor
                                              with
                                              | Some actor
                                                when String.equal actor
                                                       worker_name ->
                                                  w.execution_scope
                                              | _ -> None)
                                            session.planned_workers)
                                    in
                                    let run_delegate () =
                                      match
                                        Local_agent_eio.continue_worker ~sw:ctx.sw
                                          ~base_path:ctx.config.base_path
                                          ~room_config:(Some ctx.config)
                                          ~worker_name ~team_session_id:session_id
                                          ~worker_run_id
                                          ~prompt:delegate_prompt ()
                                      with
                                      | Ok run_result ->
                                          let output_preview =
                                            truncate_for_event run_result.output
                                          in
                                          let trace_summary_json, trace_validation_json =
                                            match run_result.raw_trace_run with
                                            | Some run_ref -> (
                                                match
                                                  raw_trace_session_payloads
                                                    ~config:ctx.config
                                                    ~fallback_session_id:session_id
                                                    run_ref
                                                with
                                                | Some pair -> (Some (fst pair), Some (snd pair))
                                                | None -> (None, None))
                                            | None -> (None, None)
                                          in
                                          persist_worker_run_snapshot
                                            ~worker_run_id ~worker_name
                                            ~mode:"delegate"
                                            ~wait_mode ?execution_scope
                                            ~status:`Completed
                                            ~resolved_model:run_result.model_used
                                            ~resolved_runtime:"local"
                                            ~tool_names:run_result.tool_names
                                            ~tool_call_count:
                                              run_result.tool_call_count
                                            ~success:true ~output_preview
                                            ~evidence_session_id:
                                              (Local_agent_eio
                                               .oas_worker_evidence_session_id
                                                 ~worker_run_id)
                                            ?trace_ref:run_result.raw_trace_run
                                            ?trace_summary:trace_summary_json
                                            ?trace_validation:trace_validation_json
                                            ~trace_capability:
                                              (if Option.is_some run_result.raw_trace_run
                                               then "raw"
                                               else "summary_only") ();
                                          append_delegate_event ~worker_run_id
                                            ~worker_name ~delegate_prompt
                                            ?execution_scope
                                            ~wait_mode:(Team_session_types.wait_mode_to_string wait_mode)
                                            ~trace_capability:
                                              (if Option.is_some run_result.raw_trace_run
                                               then "raw"
                                               else "summary_only")
                                            ~resolved_runtime:"local"
                                            ~resolved_model:run_result.model_used
                                            ~success:true
                                            ~tool_names:run_result.tool_names
                                            ~tool_call_count:
                                              run_result.tool_call_count
                                            ~routing_reason:
                                              (Option.value ~default:"continued_worker"
                                                 (List.find_map
                                                    (fun w ->
                                                      match
                                                        w.Team_session_types.runtime_actor
                                                      with
                                                      | Some actor
                                                        when String.equal actor worker_name ->
                                                            w.routing_reason
                                                      | _ -> None)
                                                    session.planned_workers))
                                            ~output_preview ();
                                          `Assoc
                                            [
                                              ("worker_run_id", `String worker_run_id);
                                              ("worker_name", `String worker_name);
                                              ("worker_backend", `String "local");
                                              ("wait_mode", `String (Team_session_types.wait_mode_to_string wait_mode));
                                              ("status", `String "completed");
                                              ("trace_capability", `String (if Option.is_some run_result.raw_trace_run then "raw" else "summary_only"));
                                              ("resolved_runtime", `String "local");
                                              ("resolved_model", `String run_result.model_used);
                                              ( "output",
                                                `String run_result.output );
                                              ( "output_preview",
                                                `String output_preview );
                                              ( "tool_call_count",
                                                `Int run_result.tool_call_count );
                                              ( "tool_names",
                                                `List
                                                  (List.map
                                                     (fun name -> `String name)
                                                     run_result.tool_names) );
                                              ( "input_tokens",
                                                int_opt_to_json run_result.input_tokens );
                                              ( "output_tokens",
                                                int_opt_to_json run_result.output_tokens );
                                              ( "cost_usd",
                                                float_opt_to_json run_result.cost_usd );
                                            ]
                                      | Error err ->
                                          persist_worker_run_snapshot
                                            ~worker_run_id ~worker_name
                                            ~mode:"delegate" ~wait_mode
                                            ~status:`Failed
                                            ~resolved_runtime:"local"
                                            ~success:false ~error:err
                                            ~evidence_session_id:
                                              (Local_agent_eio
                                               .oas_worker_evidence_session_id
                                                 ~worker_run_id)
                                            ~trace_capability:"summary_only" ();
                                          append_delegate_event ~worker_run_id
                                            ~worker_name ~delegate_prompt
                                            ?execution_scope
                                            ~wait_mode:(Team_session_types.wait_mode_to_string wait_mode)
                                            ~trace_capability:"summary_only"
                                            ~resolved_runtime:"local"
                                            ~success:false ~error:err ();
                                          `Assoc [ ("error", `String err) ]
                                    in
                                    (match wait_mode with
                                    | Team_session_types.Wait_blocking ->
                                        Some (run_delegate ())
                                    | Team_session_types.Wait_background ->
                                        let sw_bg =
                                          Option.value ~default:ctx.sw
                                            (Eio_context.get_switch_opt ())
                                        in
                                        append_delegate_requested_event
                                          ~worker_run_id ~worker_name
                                          ~delegate_prompt;
                                        Eio.Fiber.fork ~sw:sw_bg (fun () ->
                                            ignore (run_delegate ()));
                                        Some
                                          (`Assoc
                                            [
                                              ("worker_run_id", `String worker_run_id);
                                              ("worker_name", `String worker_name);
                                              ("worker_backend", `String "local");
                                              ("status", `String "accepted");
                                              ("wait_mode", `String "background");
                                            ])))))
                      in
                      let delegate_error =
                        match delegate_result_json with
                        | Some (`Assoc fields) -> (
                            match List.assoc_opt "error" fields with
                            | Some (`String e) when String.trim e <> "" ->
                                Some e
                            | _ -> None)
                        | _ -> None
                      in
                      match delegate_error with
                      | Some e -> (false, json_error e)
                      | None ->
                      let vote_result_json =
                        match get_string_opt args "vote_topic" with
                        | None -> None
                        | Some vote_topic ->
                            let vote_options = get_string_list args "vote_options" in
                            if List.length vote_options < 2 then
                              Some
                                (`Assoc
                                  [
                                    ("error", `String "vote_options requires at least 2 items");
                                  ])
                            else
                              let required_votes = get_int args "vote_required_votes" 2 in
                              let vote_create_msg =
                                Room.vote_create ctx.config ~proposer:actor
                                  ~topic:vote_topic ~options:vote_options
                                  ~required_votes
                              in
                              let vote_id = extract_vote_id vote_create_msg in
                              Team_session_store.append_event ctx.config session_id
                                ~event_type:"team_vote_created"
                                ~detail:
                                  (`Assoc
                                    [
                                      ("actor", `String actor);
                                      ("topic", `String vote_topic);
                                      ("required_votes", `Int required_votes);
                                      ("options", `List (List.map (fun o -> `String o) vote_options));
                                      ("vote_id", Option.fold ~none:`Null ~some:(fun s -> `String s) vote_id);
                                      ("result", `String vote_create_msg);
                                      ("ts_iso", `String (Types.now_iso ()));
                                    ]);
                              let cast_json =
                                match (vote_id, get_string_opt args "vote_choice") with
                                | Some vid, Some choice ->
                                    let cast_msg =
                                      Room.vote_cast ctx.config ~agent_name:actor
                                        ~vote_id:vid ~choice
                                    in
                                    Team_session_store.append_event ctx.config session_id
                                      ~event_type:"team_vote_cast"
                                      ~detail:
                                        (`Assoc
                                          [
                                            ("actor", `String actor);
                                            ("vote_id", `String vid);
                                            ("choice", `String choice);
                                            ("result", `String cast_msg);
                                            ("ts_iso", `String (Types.now_iso ()));
                                          ]);
                                    Some (`Assoc [ ("vote_id", `String vid); ("choice", `String choice); ("result", `String cast_msg) ])
                                | _ -> None
                              in
                              Some
                                (`Assoc
                                  [
                                    ("created", `String vote_create_msg);
                                    ("vote_id", Option.fold ~none:`Null ~some:(fun s -> `String s) vote_id);
                                    ("cast", Option.fold ~none:`Null ~some:(fun j -> j) cast_json);
                                  ])
                      in
                      let vote_error =
                        match vote_result_json with
                        | Some (`Assoc fields) -> (
                            match List.assoc_opt "error" fields with
                            | Some (`String e) when String.trim e <> "" -> Some e
                            | _ -> None)
                        | _ -> None
                      in
                      match vote_error with
                      | Some e -> (false, json_error e)
                      | None ->
                          let run_json =
                            match get_string_opt args "run_task_id" with
                            | None -> None
                            | Some run_task_id ->
                                let run_agent = actor in
                                let init_json =
                                  match
                                    Run_eio.init ctx.config ~task_id:run_task_id
                                      ~agent_name:(Some run_agent)
                                  with
                                  | Ok run -> `Assoc [ ("status", `String "initialized"); ("run", Run_eio.run_record_to_json run) ]
                                  | Error e -> `Assoc [ ("status", `String "init_failed"); ("error", `String e) ]
                                in
                                let note_json =
                                  match get_string_opt args "run_note" with
                                  | None -> `Null
                                  | Some note -> (
                                      match Run_eio.append_log ctx.config ~task_id:run_task_id ~note with
                                      | Ok entry -> `Assoc [ ("status", `String "ok"); ("entry", Run_eio.log_entry_to_json entry) ]
                                      | Error e -> `Assoc [ ("status", `String "error"); ("message", `String e) ])
                                in
                                let deliverable_json =
                                  match get_string_opt args "run_deliverable" with
                                  | None -> `Null
                                  | Some content -> (
                                      match
                                        Run_eio.set_deliverable ctx.config
                                          ~task_id:run_task_id ~content
                                      with
                                      | Ok run ->
                                          Team_session_store.append_event ctx.config
                                            session_id
                                            ~event_type:"team_run_deliverable"
                                            ~detail:
                                              (`Assoc
                                                [
                                                  ("actor", `String actor);
                                                  ("run_task_id", `String run_task_id);
                                                  ("deliverable_preview", `String (truncate_for_event content));
                                                  ("ts_iso", `String (Types.now_iso ()));
                                                ]);
                                          `Assoc [ ("status", `String "ok"); ("run", Run_eio.run_record_to_json run) ]
                                      | Error e ->
                                          `Assoc [ ("status", `String "error"); ("message", `String e) ])
                                in
                                Some
                                  (`Assoc
                                    [
                                      ("task_id", `String run_task_id);
                                      ("init", init_json);
                                      ("note", note_json);
                                      ("deliverable", deliverable_json);
                                    ])
                          in
                          let response =
                            `Assoc
                              [
                                ("session_id", `String session_id);
                                ("turn", Option.value ~default:`Null turn_json);
                                ("spawn", Option.fold ~none:`Null ~some:(fun j -> j) spawn_result_json);
                                ("delegate", Option.fold ~none:`Null ~some:(fun j -> j) delegate_result_json);
                                ("vote", Option.fold ~none:`Null ~some:(fun j -> j) vote_result_json);
                                ("run", Option.fold ~none:`Null ~some:(fun j -> j) run_json);
                              ]
                          in
                          (true, json_ok [ ("result", response) ]))

let handle_finalize ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let reason = get_string args "reason" "finalize" in
          let _wait_timeout_sec = get_int args "wait_timeout_sec" 45 in
          let generate_report = get_bool args "generate_report" true in
          let generate_proof = get_bool args "generate_proof" true in
          let proof_level = parse_proof_level args in
          match
            Team_session_engine_eio.finalize_session ~config:ctx.config ~session_id
              ~final_status:Team_session_types.Interrupted ~reason
              ~generate_report
          with
          | None -> (false, json_error ("team session not found: " ^ session_id))
          | Some finalized_session ->
              let terminal_status =
                Team_session_types.status_to_string finalized_session.status
              in
              let status_json =
                Team_session_engine_eio.session_status_json ctx.config
                  finalized_session
              in
                  let report_json =
                    if generate_report then
                      match
                        Team_session_engine_eio.generate_report ~config:ctx.config
                          ~session_id ~force_regenerate:false
                      with
                      | Ok json ->
                          `Assoc [ ("status", `String "ok"); ("result", json) ]
                      | Error e ->
                          `Assoc
                            [ ("status", `String "error"); ("message", `String e) ]
                    else
                      `Null
                  in
                  let report_error =
                    match report_json with
                    | `Assoc fields -> (
                        match List.assoc_opt "status" fields with
                        | Some (`String "error") -> (
                            match List.assoc_opt "message" fields with
                            | Some (`String msg) -> Some msg
                            | _ -> Some "report generation failed")
                        | _ -> None)
                    | _ -> None
                  in
                  (match report_error with
                  | Some e -> (false, json_error e)
                  | None ->
                      let proof_json =
                        if generate_proof then
                          match
                            Team_session_engine_eio.prove_session
                              ~config:ctx.config ~session_id ~proof_level
                              ~generate_report_if_missing:generate_report
                          with
                          | Ok json ->
                              `Assoc [ ("status", `String "ok"); ("result", json) ]
                          | Error e ->
                              `Assoc
                                [
                                  ("status", `String "error");
                                  ("message", `String e);
                                ]
                        else
                          `Null
                      in
                      let proof_error =
                        match proof_json with
                        | `Assoc fields -> (
                            match List.assoc_opt "status" fields with
                            | Some (`String "error") -> (
                                match List.assoc_opt "message" fields with
                                | Some (`String msg) -> Some msg
                                | _ -> Some "proof generation failed")
                            | _ -> None)
                        | _ -> None
                      in
                      match proof_error with
                      | Some e -> (false, json_error e)
                      | None ->
                          let payload =
                            `Assoc
                              [
                                ("session_id", `String session_id);
                                ("terminal_status", `String terminal_status);
                                ("status", `String terminal_status);
                                ("status_detail", status_json);
                                ("report", report_json);
                                ("proof", proof_json);
                              ]
                          in
                          ( true,
                            json_ok
                              [
                                ("result", payload);
                              ] )))

let handle_events ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let event_types = get_string_list args "event_types" in
          let limit = get_int args "limit" 200 in
          let after_ts = get_float_opt args "after_ts" in
          (match
             Team_session_engine_eio.list_events ~config:ctx.config ~session_id
               ~event_types ~limit ~after_ts
           with
          | Ok json -> (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let handle_prove ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let generate_report_if_missing =
            get_bool args "generate_report_if_missing" true
          in
          let proof_level = parse_proof_level args in
          (match
             Team_session_engine_eio.prove_session ~config:ctx.config ~session_id
               ~proof_level
               ~generate_report_if_missing
           with
          | Ok json -> (true, json_ok [ ("result", json) ])
          | Error e -> (false, json_error e)))

let handle_verify_trace ctx args : result =
  match get_valid_session_id args with
  | Error e -> (false, json_error e)
  | Ok session_id -> (
      match ensure_session_access ctx session_id with
      | Error e -> (false, json_error e)
      | Ok () ->
          let worker_run_id =
            match get_string_opt args "worker_run_id" with
            | Some id when String.trim id <> "" -> Some (String.trim id)
            | _ -> latest_worker_run_id ctx.config session_id
          in
          let verification_result meta_json worker_run_id =
            let worker_run_summary =
              `Assoc
                [
                  ("worker_run_id", `String worker_run_id);
                  ("worker_name", Yojson.Safe.Util.member "worker_name" meta_json);
                  ("status", Yojson.Safe.Util.member "status" meta_json);
                  ("mode", Yojson.Safe.Util.member "mode" meta_json);
                  ("wait_mode", Yojson.Safe.Util.member "wait_mode" meta_json);
                  ("success", Yojson.Safe.Util.member "success" meta_json);
                  ("execution_scope", Yojson.Safe.Util.member "execution_scope" meta_json);
                  ("requested_worker_class", Yojson.Safe.Util.member "requested_worker_class" meta_json);
                  ("requested_worker_size", Yojson.Safe.Util.member "requested_worker_size" meta_json);
                  ("resolved_runtime", Yojson.Safe.Util.member "resolved_runtime" meta_json);
                  ("resolved_model", Yojson.Safe.Util.member "resolved_model" meta_json);
                  ("routing_reason", Yojson.Safe.Util.member "routing_reason" meta_json);
                  ("tool_names", Yojson.Safe.Util.member "tool_names" meta_json);
                  ("tool_call_count", Yojson.Safe.Util.member "tool_call_count" meta_json);
                  ("output_preview", Yojson.Safe.Util.member "output_preview" meta_json);
                ]
            in
            let session_root = oas_trace_session_root ctx.config in
            match evidence_session_id_of_json meta_json with
            | Some evidence_session_id -> (
                match
                  Oas.Sessions.get_proof_bundle ~session_root
                    ~session_id:evidence_session_id (),
                  Oas.Conformance.run ~session_root
                    ~session_id:evidence_session_id ()
                with
                | Ok bundle, Ok report -> (
                    match bundle.latest_raw_trace_run with
                    | Some run_ref -> (
                        match
                          Oas.Sessions.get_raw_trace_records ~session_root
                            ~session_id:evidence_session_id
                            ~worker_run_id:run_ref.worker_run_id (),
                          Oas.Sessions.get_raw_trace_summary ~session_root
                            ~session_id:evidence_session_id
                            ~worker_run_id:run_ref.worker_run_id (),
                          Oas.Sessions.validate_raw_trace_run ~session_root
                            ~session_id:evidence_session_id
                            ~worker_run_id:run_ref.worker_run_id ()
                        with
                        | Ok records, Ok summary, Ok validation ->
                            let verification =
                              verification_json ~records ~summary ~validation
                            in
                            ( true,
                              json_ok
                                [
                                  ( "result",
                                    `Assoc
                                      [
                                        ("worker_run_id", `String worker_run_id);
                                        ("trace_capability", `String "raw");
                                        ( "worker_run",
                                          Option.fold ~none:worker_run_summary
                                            ~some:oas_worker_run_to_json
                                            bundle.latest_worker_run );
                                        ( "trace_ref",
                                          raw_trace_run_ref_to_json summary.run_ref );
                                        ("verification", verification);
                                        ( "session_conformance",
                                          conformance_report_to_json report );
                                      ] );
                                ] )
                        | records_result, summary_result, validation_result ->
                            let detail =
                              match
                                records_result, summary_result,
                                validation_result
                              with
                              | Error err, _, _
                              | _, Error err, _
                              | _, _, Error err ->
                                  Oas.Error.to_string err
                              | _ -> "raw trace verification failed"
                            in
                            ( true,
                              json_ok
                                [
                                  ( "result",
                                    `Assoc
                                      [
                                        ("worker_run_id", `String worker_run_id);
                                        ("trace_capability", `String "summary_only");
                                        ("ok", `Bool false);
                                        ("error", `String detail);
                                        ( "worker_run",
                                          Option.fold ~none:worker_run_summary
                                            ~some:oas_worker_run_to_json
                                            bundle.latest_worker_run );
                                        ( "session_conformance",
                                          conformance_report_to_json report );
                                      ] );
                                ] ))
                    | None ->
                        ( true,
                          json_ok
                            [
                              ( "result",
                                `Assoc
                                  [
                                    ("worker_run_id", `String worker_run_id);
                                    ("trace_capability", `String "summary_only");
                                    ("ok", `Bool false);
                                    ( "error",
                                      `String
                                        "direct evidence proof bundle did not contain a raw trace run" );
                                    ( "worker_run",
                                      Option.fold ~none:worker_run_summary
                                        ~some:oas_worker_run_to_json
                                        bundle.latest_worker_run );
                                    ( "session_conformance",
                                      conformance_report_to_json report );
                                  ] );
                            ] ))
                | bundle_result, conformance_result ->
                    let detail =
                      match bundle_result, conformance_result with
                      | Error err, _
                      | _, Error err ->
                          Oas.Error.to_string err
                      | _ -> "direct evidence verification failed"
                    in
                    ( true,
                      json_ok
                        [
                          ( "result",
                            `Assoc
                              [
                                ("worker_run_id", `String worker_run_id);
                                ("trace_capability", `String "summary_only");
                                ("ok", `Bool false);
                                ("error", `String detail);
                                ("worker_run", worker_run_summary);
                              ] );
                        ] ))
            | None -> (
                match trace_run_locator_of_json meta_json with
                | Some locator ->
                    let trace_session_id =
                      Option.value ~default:session_id locator.session_id
                    in
                    (match
                       Oas.Sessions.get_raw_trace_records ~session_root
                         ~session_id:trace_session_id
                         ~worker_run_id:locator.worker_run_id (),
                       Oas.Sessions.get_raw_trace_summary ~session_root
                         ~session_id:trace_session_id
                         ~worker_run_id:locator.worker_run_id (),
                       Oas.Sessions.validate_raw_trace_run ~session_root
                         ~session_id:trace_session_id
                         ~worker_run_id:locator.worker_run_id ()
                     with
                    | Ok records, Ok summary, Ok validation ->
                        let verification =
                          verification_json ~records ~summary ~validation
                        in
                        ( true,
                          json_ok
                            [
                              ( "result",
                                `Assoc
                                  [
                                    ("worker_run_id", `String worker_run_id);
                                    ("trace_capability", `String "raw");
                                    ("worker_run", worker_run_summary);
                                    ( "trace_ref",
                                      raw_trace_run_ref_to_json summary.run_ref );
                                    ("verification", verification);
                                  ] );
                            ] )
                    | records_result, summary_result, validation_result ->
                        let detail =
                          match
                            records_result, summary_result, validation_result
                          with
                          | Error err, _, _
                          | _, Error err, _
                          | _, _, Error err ->
                              Oas.Error.to_string err
                          | _ -> "raw trace verification failed"
                        in
                        ( true,
                          json_ok
                            [
                              ( "result",
                                `Assoc
                                  [
                                    ("worker_run_id", `String worker_run_id);
                                    ("trace_capability", `String "summary_only");
                                    ("ok", `Bool false);
                                    ("error", `String detail);
                                    ("worker_run", worker_run_summary);
                                  ] );
                            ] ))
                | None ->
                    ( true,
                      json_ok
                        [
                          ( "result",
                            `Assoc
                              [
                                ("worker_run_id", `String worker_run_id);
                                ("trace_capability", `String "summary_only");
                                ("ok", `Bool false);
                                ( "error",
                                  `String
                                    "raw trace reference missing for worker run" );
                                ("worker_run", worker_run_summary);
                              ] );
                        ] ))
          in
          match worker_run_id with
          | None -> (false, json_error "no worker run found for session")
          | Some worker_run_id -> (
              match load_worker_run_meta ctx.config session_id worker_run_id with
              | Error e -> (false, json_error e)
              | Ok meta_json -> verification_result meta_json worker_run_id))

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_team_session_start" -> Some (handle_start ctx args)
  | "masc_team_session_step" -> Some (handle_step ctx args)
  | "masc_team_session_status" -> Some (handle_status ctx args)
  | "masc_team_session_finalize" -> Some (handle_finalize ctx args)
  | "masc_team_session_stop" -> Some (handle_stop ctx args)
  | "masc_team_session_report" -> Some (handle_report ctx args)
  | "masc_team_session_list" -> Some (handle_list ctx args)
  | "masc_team_session_compare" -> Some (handle_compare ctx args)
  | "masc_team_session_turn" -> Some (handle_turn ctx args)
  | "masc_team_session_events" -> Some (handle_events ctx args)
  | "masc_team_session_prove" -> Some (handle_prove ctx args)
  | "masc_team_session_verify_trace" -> Some (handle_verify_trace ctx args)
  | _ -> None

let schemas : tool_schema list =
  [
    {
      name = "masc_team_session_start";
      description =
        "Start a long-running team collaboration session with periodic checkpoints and final report artifacts.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "goal",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Session goal (required)");
                      ] );
                  ( "operation_id",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "description",
                          `String
                            "Optional managed CPv2 operation id to attach this team session to. When provided, the operation detachment_session_id is updated to this session." );
                      ] );
                  ( "duration_seconds",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String
                            "Session duration in seconds (default: 3600)" );
                      ] );
                  ( "duration_minutes",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String
                            "Session duration in minutes (used when duration_seconds is omitted)" );
                      ] );
                  ( "execution_scope",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "observe_only";
                              `String "limited_code_change";
                            ] );
                      ] );
                  ( "checkpoint_interval_sec",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String "Checkpoint interval in seconds (default: 60)"
                        );
                      ] );
                  ( "min_agents",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String "Minimum expected participating agents" );
                      ] );
                  ( "orchestration_mode",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "manual";
                              `String "assist";
                              `String "auto";
                            ] );
                      ] );
	                  ( "communication_mode",
	                    `Assoc
	                      [
	                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "off";
                              `String "broadcast";
                              `String "portal";
	                              `String "hybrid";
	                            ] );
	                      ] );
	                  ( "scale_profile",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ("enum", `List [ `String "standard"; `String "local64" ]);
	                      ] );
	                  ( "control_profile",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ("enum", `List [ `String "flat"; `String "hierarchical_quality_v1" ]);
	                      ] );
	                  ( "model_cascade",
	                    `Assoc
	                      [
	                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ( "fallback_policy",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "none";
                              `String "cascade_then_task";
                              `String "task_only";
                              `String "local_first_conditional";
                              `String "strict_local_only";
                              `String "cloud_first";
                            ] );
                      ] );
                  ( "instruction_profile",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "standard"; `String "strict" ]);
                      ] );
                  ( "alert_channel",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [ `String "broadcast"; `String "board"; `String "both" ]
                        );
                      ] );
                  ( "auto_resume",
                    `Assoc
                      [
                        ("type", `String "boolean");
                        ( "description",
                          `String "Recover and resume after process restart" );
                      ] );
                  ( "report_formats",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ( "agents",
                    `Assoc
                      [
                        ("type", `String "array");
                        ( "items",
                          `Assoc
                            [
                              ( "oneOf",
                                `List
                                  [
                                    `Assoc [ ("type", `String "string") ];
                                    `Assoc
                                      [
                                        ("type", `String "object");
                                        ( "properties",
                                          `Assoc
                                            [
                                              ("name", `Assoc [ ("type", `String "string") ]);
                                            ] );
                                      ];
                                  ] );
                            ] );
                      ] );
                ] );
            ("required", `List [ `String "goal" ]);
          ];
    };
    {
      name = "masc_team_session_status";
      description = "Get the current status and progress summary for a team session.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc [ ("session_id", `Assoc [ ("type", `String "string") ]) ]
            );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_step";
      description =
        "Canonical team-session write entrypoint: record a note/broadcast/portal/task/checkpoint turn, optionally spawn workers, and optionally attach vote/run evidence.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ( "turn_kind",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "enum",
                          `List
                            [
                              `String "note";
                              `String "broadcast";
                              `String "portal";
                              `String "task";
                              `String "checkpoint";
                            ] );
                      ] );
                  ( "actor",
                    `Assoc
                      [
                        ("type", `String "string");
                        ( "description",
                          `String
                            "Optional explicit actor. If provided, it must match the authenticated caller." );
                      ] );
                  ("message", `Assoc [ ("type", `String "string") ]);
                  ("target_agent", `Assoc [ ("type", `String "string") ]);
                  ("delegate_prompt", `Assoc [ ("type", `String "string") ]);
                  ("task_title", `Assoc [ ("type", `String "string") ]);
                  ("task_description", `Assoc [ ("type", `String "string") ]);
                  ("task_priority", `Assoc [ ("type", `String "integer") ]);
	                  ("spawn_role", `Assoc [ ("type", `String "string") ]);
	                  ( "execution_scope",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ( "enum",
	                          `List
	                            [
	                              `String "observe_only";
	                              `String "limited_code_change";
	                            ] );
	                      ] );
	                  ( "worker_class",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ( "enum",
	                          `List
	                            [
	                              `String "manager";
	                              `String "executor";
	                              `String "scout";
	                              `String "librarian";
	                              `String "metacog";
	                            ] );
	                      ] );
	                  ( "worker_size",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ("enum", `List [ `String "sm"; `String "lg"; `String "xlg" ]);
	                      ] );
	                  ("parent_actor", `Assoc [ ("type", `String "string") ]);
	                  ( "capsule_mode",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ( "enum",
	                          `List
	                            [
	                              `String "fresh";
	                              `String "inherit";
	                              `String "capsule";
	                            ] );
	                      ] );
	                  ("runtime_pool", `Assoc [ ("type", `String "string") ]);
	                  ("lane_id", `Assoc [ ("type", `String "string") ]);
	                  ( "control_domain",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ( "enum",
	                          `List
	                            [
	                              `String "execution";
	                              `String "quality";
	                              `String "knowledge";
	                              `String "runtime";
	                              `String "meta";
	                            ] );
	                      ] );
	                  ("supervisor_actor", `Assoc [ ("type", `String "string") ]);
	                  ( "task_profile",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ( "enum",
	                          `List
	                            [
	                              `String "extract";
	                              `String "normalize";
	                              `String "summarize";
	                              `String "verify";
	                              `String "decide";
	                              `String "synthesize";
	                            ] );
	                      ] );
	                  ( "risk_level",
	                    `Assoc
	                      [
	                        ("type", `String "string");
	                        ( "enum",
	                          `List
	                            [
	                              `String "low";
	                              `String "medium";
	                              `String "high";
	                            ] );
	                      ] );
	                  ("routing_confidence", `Assoc [ ("type", `String "number") ]);
	                  ("routing_reason", `Assoc [ ("type", `String "string") ]);
	                  ("spawn_selection_note", `Assoc [ ("type", `String "string") ]);
	                  ("spawn_prompt", `Assoc [ ("type", `String "string") ]);
	                  ("spawn_timeout_seconds", `Assoc [ ("type", `String "integer") ]);
                  ( "wait_mode",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "background"; `String "blocking" ]);
                      ] );
                  ( "worker_policy",
                    `Assoc
                      [
                        ("type", `String "object");
                        ( "properties",
                          `Assoc
                            [
                              ("thinking", `Assoc [ ("type", `String "boolean") ]);
                              ("timeout_seconds", `Assoc [ ("type", `String "integer") ]);
                              ("max_turns", `Assoc [ ("type", `String "integer") ]);
                            ] );
                      ] );
                  ( "spawn_batch",
                    `Assoc
                      [
                        ("type", `String "array");
                        ( "items",
                          `Assoc
                            [
                              ("type", `String "object");
                              ( "properties",
                                `Assoc
	                                  [
	                                    ("spawn_role", `Assoc [ ("type", `String "string") ]);
	                                    ( "execution_scope",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ( "enum",
	                                            `List
	                                              [
	                                                `String "observe_only";
	                                                `String "limited_code_change";
	                                              ] );
	                                        ] );
	                                    ( "worker_class",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ( "enum",
	                                            `List
	                                              [
	                                                `String "manager";
	                                                `String "executor";
	                                                `String "scout";
	                                                `String "librarian";
	                                                `String "metacog";
	                                              ] );
	                                        ] );
	                                    ( "worker_size",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ("enum", `List [ `String "sm"; `String "lg"; `String "xlg" ]);
	                                        ] );
	                                    ("parent_actor", `Assoc [ ("type", `String "string") ]);
	                                    ( "capsule_mode",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ( "enum",
	                                            `List
	                                              [
	                                                `String "fresh";
	                                                `String "inherit";
	                                                `String "capsule";
	                                              ] );
	                                        ] );
	                                    ("runtime_pool", `Assoc [ ("type", `String "string") ]);
	                                    ("lane_id", `Assoc [ ("type", `String "string") ]);
	                                    ( "control_domain",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ( "enum",
	                                            `List
	                                              [
	                                                `String "execution";
	                                                `String "quality";
	                                                `String "knowledge";
	                                                `String "runtime";
	                                                `String "meta";
	                                              ] );
	                                        ] );
	                                    ("supervisor_actor", `Assoc [ ("type", `String "string") ]);
	                                    ( "task_profile",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ( "enum",
	                                            `List
	                                              [
	                                                `String "extract";
	                                                `String "normalize";
	                                                `String "summarize";
	                                                `String "verify";
	                                                `String "decide";
	                                                `String "synthesize";
	                                              ] );
	                                        ] );
	                                    ( "risk_level",
	                                      `Assoc
	                                        [
	                                          ("type", `String "string");
	                                          ( "enum",
	                                            `List
	                                              [
	                                                `String "low";
	                                                `String "medium";
	                                                `String "high";
	                                              ] );
	                                        ] );
	                                    ("routing_confidence", `Assoc [ ("type", `String "number") ]);
	                                    ("routing_reason", `Assoc [ ("type", `String "string") ]);
	                                    ( "spawn_selection_note",
	                                      `Assoc [ ("type", `String "string") ] );
	                                    ("spawn_prompt", `Assoc [ ("type", `String "string") ]);
                                    ( "spawn_timeout_seconds",
                                      `Assoc [ ("type", `String "integer") ] );
                                    ( "worker_policy",
                                      `Assoc
                                        [
                                          ("type", `String "object");
                                          ( "properties",
                                            `Assoc
                                              [
                                                ("thinking", `Assoc [ ("type", `String "boolean") ]);
                                                ("timeout_seconds", `Assoc [ ("type", `String "integer") ]);
                                                ("max_turns", `Assoc [ ("type", `String "integer") ]);
                                              ] );
                                        ] );
                                  ] );
                              ( "required",
                                `List
                                  [
                                    `String "spawn_prompt";
                                  ] );
                            ] );
                      ] );
                  ("vote_topic", `Assoc [ ("type", `String "string") ]);
                  ( "vote_options",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ("vote_required_votes", `Assoc [ ("type", `String "integer") ]);
                  ("vote_choice", `Assoc [ ("type", `String "string") ]);
                  ("run_task_id", `Assoc [ ("type", `String "string") ]);
                  ("run_note", `Assoc [ ("type", `String "string") ]);
                  ("run_deliverable", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_finalize";
      description =
        "Stop session, wait for terminal status, then optionally generate report and proof in one command.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("reason", `Assoc [ ("type", `String "string") ]);
                  ("wait_timeout_sec", `Assoc [ ("type", `String "integer") ]);
                  ("generate_report", `Assoc [ ("type", `String "boolean") ]);
                  ("generate_proof", `Assoc [ ("type", `String "boolean") ]);
                  ( "proof_level",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "standard"; `String "strong" ]);
                      ] );
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_stop";
      description =
        "Request stop for a team session and optionally generate report artifacts.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("reason", `Assoc [ ("type", `String "string") ]);
                  ("generate_report", `Assoc [ ("type", `String "boolean") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_report";
      description = "Generate (or regenerate) report artifacts for a team session.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("force_regenerate", `Assoc [ ("type", `String "boolean") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_list";
      description =
        "List recent team sessions with optional status filter and health/cascade summary.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("status", `Assoc [ ("type", `String "string") ]);
                  ( "limit",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ("description", `String "Max sessions to return (default: 20)");
                      ] );
                ] );
          ];
    };
    {
      name = "masc_team_session_compare";
      description =
        "Compare two team sessions and return throughput/policy/communication deltas.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("base_session_id", `Assoc [ ("type", `String "string") ]);
                  ("target_session_id", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "base_session_id"; `String "target_session_id" ]);
          ];
    };
    {
      name = "masc_team_session_events";
      description =
        "Read team session event timeline with optional event type and timestamp filters.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ( "event_types",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                      ] );
                  ("after_ts", `Assoc [ ("type", `String "number") ]);
                  ("limit", `Assoc [ ("type", `String "integer") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_prove";
      description =
        "Generate verifiable proof artifacts (proof.json/proof.md) for a team session based on timeline evidence.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ( "generate_report_if_missing",
                    `Assoc [ ("type", `String "boolean") ] );
                  ( "proof_level",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "standard"; `String "strong" ]);
                      ] );
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
    {
      name = "masc_team_session_verify_trace";
      description =
        "Verify worker-run trace evidence for a team session using stored worker run snapshots.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ("session_id", `Assoc [ ("type", `String "string") ]);
                  ("worker_run_id", `Assoc [ ("type", `String "string") ]);
                ] );
            ("required", `List [ `String "session_id" ]);
          ];
    };
  ]
