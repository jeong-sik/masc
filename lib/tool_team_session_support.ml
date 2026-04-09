(** Foundation utilities for team session tools.

    Types, JSON helpers, parsers, validators, session access checks,
    and OAS trace utilities. *)

open Tool_args

type 'a context = 'a Tool_team_session_step.context = {
  config : Room.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
}

type result = bool * string

let json_error message =
  Yojson.Safe.to_string
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])

let json_ok fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

let team_session_process_mgr_result (ctx : _ context) =
  match ctx.proc_mgr with
  | Some process_mgr -> Ok process_mgr
  | None -> (
      match Process_eio.get_proc_mgr () with
      | Ok process_mgr -> Ok process_mgr
      | Error _ -> Error "process_mgr not available for team session start")

let team_session_net_result (ctx : _ context) =
  match ctx.net with
  | Some net -> Ok net
  | None -> (
      match Eio_context.get_net_opt () with
      | Some net -> Ok net
      | None -> Error "team session start requires Eio net")

let team_session_start_env_result (ctx : _ context) =
  Result.bind (team_session_process_mgr_result ctx) (fun process_mgr ->
      Result.map
        (fun net ->
          object
            method clock = ctx.clock
            method process_mgr = process_mgr
            method net = net
          end)
        (team_session_net_result ctx))

let parse_execution_scope args =
  match String.lowercase_ascii (get_string args "execution_scope" "limited_code_change") with
  | "observe_only" -> Team_session_types.Observe_only
  | _ -> Team_session_types.Limited_code_change

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
  let base_path = Filename.dirname (Room_utils.masc_dir config) in
  Worker_container.oas_trace_session_root ~base_path

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
      with
      | Yojson.Safe.Util.Type_error _ -> None
      | exn ->
          Log.Session.warn "trace_ref parse unexpected: %s" (Printexc.to_string exn);
          None)
  | _ -> None

let evidence_session_id_of_json json =
  match Yojson.Safe.Util.member "evidence_session_id" json with
  | `String value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let oas_trace_capability_to_string : Oas.Sessions.trace_capability -> string = function
  | Oas.Sessions.Raw -> "raw"
  | Oas.Sessions.Summary_only -> "summary_only"
  | Oas.Sessions.No_trace -> "none"

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
            | Some summary -> Some (Oas.Raw_trace.run_summary_to_yojson summary)
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
            | Some validation -> Some (Oas.Raw_trace.run_validation_to_yojson validation)
            | None -> None)
        | None -> None
      in
      Some
        {
          trace_ref = latest_trace_run;
          trace_summary_json;
          trace_validation_json;
          worker_json = Option.map Oas.Sessions.worker_run_to_yojson worker;
          conformance_json = Some (Oas.Conformance.report_to_yojson report);
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
      ("summary", Oas.Raw_trace.run_summary_to_yojson summary);
      ("validation", Oas.Raw_trace.run_validation_to_yojson validation);
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
        ( Oas.Raw_trace.run_summary_to_yojson summary,
          Oas.Raw_trace.run_validation_to_yojson validation )
  | _ -> (
      match Oas.Raw_trace_query.summarize_run run_ref, Oas.Raw_trace_query.validate_run run_ref with
      | Ok summary, Ok validation ->
          Some
            ( Oas.Raw_trace.run_summary_to_yojson summary,
              Oas.Raw_trace.run_validation_to_yojson validation )
      | _ -> None)

let record_session_turn_json ~(config : Room.config) ~session_id ~actor
    ~turn_kind ~message ~target_agent ~task_title ~task_description
    ~task_priority =
  Team_session_engine_eio.record_turn ~config ~session_id ~actor ~turn_kind
    ~message ~target_agent ~task_title ~task_description ~task_priority
