(** MCP tools for long-running team sessions (1h orchestration). *)

open Tool_args
module Oas = Agent_sdk

type 'a context = 'a Tool_team_session_step.context = {
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
      ("worker_id", Option.fold ~none:`Null ~some:(fun s -> `String s) worker.worker_id);
      ("agent_name", `String worker.agent_name);
      ( "runtime_actor",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          worker.runtime_actor );
      ("role", Option.fold ~none:`Null ~some:(fun s -> `String s) worker.role);
      ("aliases", `List (List.map (fun alias -> `String alias) worker.aliases));
      ( "primary_alias",
        Option.fold ~none:`Null ~some:(fun s -> `String s)
          worker.primary_alias );
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
      ("accepted_at", Option.fold ~none:`Null ~some:(fun ts -> `Float ts) worker.accepted_at);
      ("ready_at", Option.fold ~none:`Null ~some:(fun ts -> `Float ts) worker.ready_at);
      ( "first_progress_at",
        Option.fold ~none:`Null ~some:(fun ts -> `Float ts)
          worker.first_progress_at );
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

type oas_worker_evidence = Tool_team_session_step.oas_worker_evidence = {
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
         | Oas.Raw_trace.Run_started | Oas.Raw_trace.Hook_invoked -> None)

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


(* Routing, spawn spec parsing, model inference, worker management *)
include Tool_team_session_routing

let step_deps : Tool_team_session_step.step_deps =
  {
    json_error;
    json_ok;
    get_valid_session_id;
    ensure_session_access;
    parse_step_spawn_specs;
    annotate_control_hierarchy_for_session;
    parse_turn_kind;
    parse_turn_kind_opt;
    parse_wait_mode;
    int_opt_to_json;
    float_opt_to_json;
    truncate_for_event;
    make_worker_run_id;
    derived_llama_runtime_actor;
    is_local_spawn_agent;
    effective_execution_scope_of_spec;
    worker_size_of_spec;
    inferred_controller_level_of_spec;
    planned_worker_of_spec;
    register_planned_workers;
    ensure_session_actor;
    record_session_turn_json;
    resolve_target_worker_name;
    session_has_turn_for_actor;
    auto_note_message_of_spawn_output;
    reconcile_failed_spawn_actor;
    extract_vote_id;
    oas_worker_evidence_payload;
    oas_trace_capability_to_string;
    oas_worker_status_to_json;
    worker_run_status_to_json;
    raw_trace_run_ref_to_json;
    raw_trace_session_payloads;
  }

let handle_step ctx args : result =
  Tool_team_session_step.handle_step step_deps ctx args

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

include Tool_team_session_schemas
