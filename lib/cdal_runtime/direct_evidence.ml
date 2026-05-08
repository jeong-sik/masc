open Runtime
open Result_syntax

type options =
  { session_root : string option
  ; session_id : string
  ; goal : string
  ; title : string option
  ; tag : string option
  ; worker_id : string option
  ; runtime_actor : string option
  ; role : string option
  ; aliases : string list
  ; requested_provider : string option
  ; requested_model : string option
  ; requested_policy : string option
  ; workdir : string option
  }

let now () = Unix.gettimeofday ()
let first_some = Util.first_some
let validation_error detail = Error.Io (ValidationFailed { detail })

let safe_name name =
  let trimmed = String.trim name in
  let base = if trimmed = "" then "agent" else trimmed in
  String.map
    (function
      | '/' | '\\' | ' ' | '\t' | '\n' | '\r' -> '_'
      | c -> c)
    base
;;

let save_events store session_id (events : event list) =
  let content =
    events
    |> List.map (fun event -> event |> event_to_yojson |> Yojson.Safe.to_string)
    |> String.concat "\n"
    |> fun body -> if body = "" then "" else body ^ "\n"
  in
  Runtime_store.save_text (Runtime_store.events_path store session_id) content
;;

let lifecycle_snapshot_or_default (agent : Agent.t) : Agent.lifecycle_snapshot =
  match Agent.lifecycle_snapshot agent with
  | Some snapshot -> snapshot
  | None ->
    let cfg = (Agent.state agent).config in
    { Agent_lifecycle.current_run_id = None
    ; agent_name = cfg.name
    ; worker_id = Some cfg.name
    ; runtime_actor = Some cfg.name
    ; status = Completed
    ; requested_provider = None
    ; requested_model = Some (Types.model_to_string cfg.model)
    ; resolved_provider = None
    ; resolved_model = Some (Types.model_to_string cfg.model)
    ; last_error = None
    ; accepted_at = None
    ; ready_at = None
    ; first_progress_at = None
    ; started_at = None
    ; last_progress_at = None
    ; finished_at = None
    }
;;

let default_runtime_actor (agent : Agent.t) options =
  first_some options.runtime_actor (Some (Agent.state agent).config.name)
;;

let default_worker_id (agent : Agent.t) options =
  first_some options.worker_id (default_runtime_actor agent options)
;;

let primary_alias aliases =
  match aliases with
  | alias :: _ when String.trim alias <> "" -> Some alias
  | _ -> None
;;

let workdir_policy_to_json = function
  | Tool.Required -> `String "required"
  | Tool.Recommended -> `String "recommended"
  | Tool.None_expected -> `String "none_expected"
;;

let shell_constraints_to_json (shell : Tool.shell_constraints) =
  `Assoc
    [ "single_command_only", `Bool shell.single_command_only
    ; "shell_metacharacters_allowed", `Bool shell.shell_metacharacters_allowed
    ; "chaining_allowed", `Bool shell.chaining_allowed
    ; "redirection_allowed", `Bool shell.redirection_allowed
    ; "pipes_allowed", `Bool shell.pipes_allowed
    ; ( "workdir_policy"
      , Option.value
          ~default:`Null
          (Option.map workdir_policy_to_json shell.workdir_policy) )
    ]
;;

let tool_contracts_to_json tools =
  `List
    (List.map
       (fun (tool : Tool.t) ->
          let descriptor = Tool.descriptor tool in
          let kind =
            match Option.bind descriptor (fun d -> d.kind) with
            | Some value -> `String value
            | None -> `Null
          in
          let shell =
            match Option.bind descriptor (fun d -> d.shell) with
            | Some shell -> shell_constraints_to_json shell
            | None -> `Null
          in
          let notes =
            descriptor
            |> Option.map (fun (d : Tool.descriptor) -> d.notes)
            |> Option.value ~default:[]
          in
          let examples =
            descriptor
            |> Option.map (fun (d : Tool.descriptor) -> d.examples)
            |> Option.value ~default:[]
          in
          let mutation_class =
            match Option.bind descriptor (fun d -> d.mutation_class) with
            | Some value -> `String value
            | None -> `Null
          in
          `Assoc
            [ "name", `String tool.schema.name
            ; "description", `String tool.schema.description
            ; "origin", `String "local"
            ; "kind", kind
            ; "mutation_class", mutation_class
            ; "shell", shell
            ; "notes", Util.json_of_string_list notes
            ; "examples", Util.json_of_string_list examples
            ])
       tools)
;;

let worker_status_of_lifecycle = function
  | Agent.Accepted -> Sessions.Accepted
  | Agent.Ready -> Sessions.Ready
  | Agent.Running -> Sessions.Running
  | Agent.Completed -> Sessions.Completed
  | Agent.Failed -> Sessions.Failed
;;

type raw_details =
  { validated : bool
  ; tool_names : string list
  ; final_text : string option
  ; stop_reason : string option
  ; error : string option
  ; paired_tool_result_count : int
  ; has_file_write : bool
  ; verification_pass_after_file_write : bool
  ; failure_reason : string option
  }

let empty_raw_details =
  { validated = false
  ; tool_names = []
  ; final_text = None
  ; stop_reason = None
  ; error = None
  ; paired_tool_result_count = 0
  ; has_file_write = false
  ; verification_pass_after_file_write = false
  ; failure_reason = None
  }
;;

let raw_details_of_run run_ref =
  let* validation = Raw_trace_query.validate_run run_ref in
  Ok
    { validated = validation.ok
    ; tool_names = validation.tool_names
    ; final_text = validation.final_text
    ; stop_reason = validation.stop_reason
    ; error = validation.failure_reason
    ; paired_tool_result_count = validation.paired_tool_result_count
    ; has_file_write = validation.has_file_write
    ; verification_pass_after_file_write = validation.verification_pass_after_file_write
    ; failure_reason = validation.failure_reason
    }
;;

let worker_run_of_agent
      ~(agent : Agent.t)
      ~options
      ~(snapshot : Agent.lifecycle_snapshot)
      raw_details
  =
  let aliases = options.aliases in
  let worker_id = default_worker_id agent options in
  let runtime_actor = default_runtime_actor agent options in
  { Sessions.worker_run_id =
      Option.value ~default:"direct-untracked" snapshot.current_run_id
  ; worker_id
  ; agent_name = (Agent.state agent).config.name
  ; runtime_actor
  ; role = options.role
  ; aliases
  ; primary_alias = primary_alias aliases
  ; provider = snapshot.resolved_provider
  ; model = snapshot.resolved_model
  ; requested_provider = first_some snapshot.requested_provider options.requested_provider
  ; requested_model = first_some snapshot.requested_model options.requested_model
  ; requested_policy = options.requested_policy
  ; resolved_provider = snapshot.resolved_provider
  ; resolved_model = snapshot.resolved_model
  ; status = worker_status_of_lifecycle snapshot.status
  ; trace_capability =
      (match snapshot.current_run_id with
       | Some _ -> Sessions.Raw
       | None -> Sessions.No_trace)
  ; validated =
      (match snapshot.status with
       | Agent.Completed -> raw_details.validated
       | Agent.Accepted | Agent.Ready | Agent.Running | Agent.Failed -> false)
  ; tool_names = raw_details.tool_names
  ; final_text = raw_details.final_text
  ; stop_reason = raw_details.stop_reason
  ; error = first_some snapshot.last_error raw_details.error
  ; failure_reason = first_some snapshot.last_error raw_details.failure_reason
  ; accepted_at = snapshot.accepted_at
  ; ready_at = snapshot.ready_at
  ; first_progress_at = snapshot.first_progress_at
  ; started_at = snapshot.started_at
  ; finished_at = snapshot.finished_at
  ; last_progress_at = snapshot.last_progress_at
  ; policy_snapshot = options.requested_policy
  ; paired_tool_result_count = raw_details.paired_tool_result_count
  ; has_file_write = raw_details.has_file_write
  ; verification_pass_after_file_write = raw_details.verification_pass_after_file_write
  }
;;

let current_worker_run ~(agent : Agent.t) ~raw_trace ~options () =
  let snapshot = lifecycle_snapshot_or_default agent in
  let raw_details =
    match
      match Raw_trace.last_run raw_trace with
      | Some run -> Some run
      | None -> Agent.last_raw_trace_run agent
    with
    | Some run -> raw_details_of_run run
    | None -> Ok empty_raw_details
  in
  let* raw_details = raw_details in
  Ok (worker_run_of_agent ~agent ~options ~snapshot raw_details)
;;

let extract_prompt (records : Raw_trace.record list) =
  records
  |> List.find_map (fun (record : Raw_trace.record) ->
    match record.record_type, record.prompt with
    | Raw_trace.Run_started, Some prompt -> Some prompt
    | _ -> None)
  |> Option.value ~default:""
;;

let extract_text_deltas (records : Raw_trace.record list) =
  records
  |> List.filter_map (fun (record : Raw_trace.record) ->
    match record.record_type, record.block_kind, record.assistant_block with
    | Raw_trace.Assistant_block, Some "text", Some (`Assoc fields) ->
      (match List.assoc_opt "text" fields with
       | Some (`String text) when String.trim text <> "" -> Some (record.ts, text)
       | _ -> None)
    | _ -> None)
;;

let write_latest_run_to_session store session_id agent_name (run_ref : Raw_trace.run_ref) =
  let* records = Raw_trace_query.read_run run_ref in
  let path =
    Filename.concat
      (Runtime_store.raw_traces_dir store session_id)
      (safe_name agent_name ^ ".jsonl")
  in
  let content =
    records
    |> List.map (fun record ->
      record |> Raw_trace.record_to_json |> Yojson.Safe.to_string)
    |> String.concat "\n"
    |> fun body -> if body = "" then "" else body ^ "\n"
  in
  let* () = Runtime_store.save_text path content in
  let* runs = Raw_trace_query.read_runs ~path () in
  match
    List.find_opt
      (fun (candidate : Raw_trace.run_ref) ->
         String.equal candidate.worker_run_id run_ref.worker_run_id)
      runs
  with
  | Some run -> Ok (run, records)
  | None ->
    Error
      (validation_error
         (Printf.sprintf
            "Failed to materialize latest raw trace run %s"
            run_ref.worker_run_id))
;;

let apply_events initial_session (events : event list) =
  List.fold_left
    (fun acc event ->
       let* session = acc in
       Runtime_projection.apply_event session event)
    (Ok initial_session)
    events
;;

let make_event seq ts kind = { seq; ts; kind }

let persist ~agent ~raw_trace ~(options : options) () =
  let cfg = (Agent.state agent).config in
  let snapshot = lifecycle_snapshot_or_default agent in
  let terminal =
    match snapshot.status with
    | Agent.Completed | Agent.Failed -> true
    | Agent.Accepted | Agent.Ready | Agent.Running -> false
  in
  if not terminal
  then
    Error
      (validation_error
         "Direct evidence materialization requires a terminal direct-agent run")
  else
    let* store = Runtime_store.create ?root:options.session_root () in
    let raw_session_id = Raw_trace.session_id raw_trace in
    let* () =
      match raw_session_id with
      | Some value when not (String.equal value options.session_id) ->
        Error
          (validation_error
             (Printf.sprintf
                "Raw trace session_id %s did not match requested session_id %s"
                value
                options.session_id))
      | _ -> Ok ()
    in
    let last_run =
      match Raw_trace.last_run raw_trace with
      | Some run -> Some run
      | None -> Agent.last_raw_trace_run agent
    in
    let* last_run =
      match last_run with
      | Some run -> Ok run
      | None -> Error (validation_error "No raw trace run was available")
    in
    let* raw_run, latest_records =
      write_latest_run_to_session store options.session_id cfg.name last_run
    in
    let existing_bundle =
      match
        Sessions.get_proof_bundle
          ?session_root:options.session_root
          ~session_id:options.session_id
          ()
      with
      | Ok bundle ->
        (match bundle.Sessions.latest_raw_trace_run with
         | Some existing when String.equal existing.worker_run_id raw_run.worker_run_id ->
           Some bundle
         | _ -> None)
      | Error _ -> None
    in
    match existing_bundle with
    | Some bundle -> Ok bundle
    | None ->
      let* raw_summary = Raw_trace_query.summarize_run raw_run in
      let* raw_validation = Raw_trace_query.validate_run raw_run in
      let prompt = extract_prompt latest_records in
      let selected_provider =
        first_some snapshot.requested_provider options.requested_provider
      in
      let selected_model = first_some snapshot.requested_model options.requested_model in
      let start_request =
        { session_id = Some options.session_id
        ; goal = options.goal
        ; participants = [ cfg.name ]
        ; provider = selected_provider
        ; model = selected_model
        ; permission_mode = options.requested_policy
        ; system_prompt = cfg.system_prompt
        ; max_turns = Some cfg.max_turns
        ; workdir = options.workdir
        }
      in
      let initial_session =
        let session = Runtime_projection.initial_session start_request in
        { session with
          title = options.title
        ; tag = options.tag
        ; participants =
            session.participants
            |> List.map (fun (participant : Runtime.participant) ->
              if String.equal participant.name cfg.name
              then
                { participant with
                  worker_id = default_worker_id agent options
                ; runtime_actor = default_runtime_actor agent options
                ; role = first_some options.role participant.role
                ; aliases = options.aliases
                }
              else participant)
        }
      in
      let started_at = Option.value raw_summary.started_at ~default:(now ()) in
      let finished_at =
        Option.value
          raw_summary.finished_at
          ~default:(Option.value snapshot.finished_at ~default:started_at)
      in
      let deltas = extract_text_deltas latest_records in
      let base_events =
        [ make_event
            1
            (started_at -. 0.003)
            (Session_started { goal = options.goal; participants = [ cfg.name ] })
        ; make_event
            2
            (started_at -. 0.002)
            (Turn_recorded { actor = None; message = prompt })
        ; make_event
            3
            (started_at -. 0.001)
            (Agent_spawn_requested
               { participant_name = cfg.name
               ; role = first_some options.role None
               ; prompt
               ; provider = selected_provider
               ; model = selected_model
               ; permission_mode = options.requested_policy
               })
        ; make_event
            4
            started_at
            (Agent_became_live
               { participant_name = cfg.name
               ; summary = Some "direct-agent-started"
               ; provider = snapshot.resolved_provider
               ; model = snapshot.resolved_model
               ; error = None
               ; raw_trace_run_id = Some raw_run.worker_run_id
               ; stop_reason = None
               ; completion_anomaly = None
               ; failure_cause = None
               })
        ]
        @ (deltas
           |> List.mapi (fun index (ts, text) ->
             make_event
               (5 + index)
               ts
               (Agent_output_delta { participant_name = cfg.name; delta = text })))
        @ [ make_event
              (5 + List.length deltas)
              finished_at
              (match snapshot.status with
               | Agent.Failed ->
                 Agent_failed
                   { participant_name = cfg.name
                   ; summary = raw_summary.final_text
                   ; provider = snapshot.resolved_provider
                   ; model = snapshot.resolved_model
                   ; error = first_some snapshot.last_error raw_summary.error
                   ; raw_trace_run_id = Some raw_run.worker_run_id
                   ; stop_reason = raw_summary.stop_reason
                   ; completion_anomaly = None
                   ; failure_cause =
                       first_some snapshot.last_error raw_summary.error
                       |> Option.map (fun detail -> Runtime.Execution_error detail)
                   }
               | Agent.Accepted | Agent.Ready | Agent.Running | Agent.Completed ->
                 Agent_completed
                   { participant_name = cfg.name
                   ; summary = raw_summary.final_text
                   ; provider = snapshot.resolved_provider
                   ; model = snapshot.resolved_model
                   ; error = None
                   ; raw_trace_run_id = Some raw_run.worker_run_id
                   ; stop_reason = raw_summary.stop_reason
                   ; completion_anomaly = None
                   ; failure_cause = None
                   })
          ; make_event
              (6 + List.length deltas)
              (finished_at +. 0.001)
              (Finalize_requested { reason = None })
          ; make_event
              (7 + List.length deltas)
              (finished_at +. 0.002)
              (match snapshot.status with
               | Agent.Failed ->
                 Session_failed
                   { outcome = first_some snapshot.last_error raw_summary.error }
               | Agent.Accepted | Agent.Ready | Agent.Running | Agent.Completed ->
                 Session_completed { outcome = raw_summary.stop_reason })
          ]
      in
      let* terminal_session = apply_events initial_session base_events in
      let* () = Runtime_store.save_session store terminal_session in
      let* () = save_events store options.session_id base_events in
      let telemetry =
        Runtime_evidence.build_telemetry_report terminal_session base_events
      in
      let telemetry_json =
        Runtime_evidence.telemetry_report_to_json telemetry
        |> Yojson.Safe.pretty_to_string
      in
      let telemetry_md = Runtime_evidence.telemetry_report_to_markdown telemetry in
      let report = Runtime_projection.build_report terminal_session base_events in
      let proof = Runtime_projection.build_proof terminal_session base_events in
      let* () = Runtime_store.save_report store report in
      let* () = Runtime_store.save_proof store proof in
      let* telemetry_json_artifact =
        Artifact_service.save_text_internal
          store
          ~session_id:options.session_id
          ~name:"runtime-telemetry-json"
          ~kind:"json"
          ~content:telemetry_json
      in
      let* telemetry_md_artifact =
        Artifact_service.save_text_internal
          store
          ~session_id:options.session_id
          ~name:"runtime-telemetry"
          ~kind:"markdown"
          ~content:telemetry_md
      in
      let raw_trace_manifest =
        Runtime_evidence.build_raw_trace_manifest
          ~session_id:options.session_id
          ~latest_raw_trace_run:(Some raw_run)
          ~raw_trace_runs:[ raw_run ]
          ~raw_trace_summaries:[ raw_summary ]
          ~raw_trace_validations:[ raw_validation ]
      in
      let raw_trace_json =
        Runtime_evidence.raw_trace_manifest_to_json raw_trace_manifest
        |> Yojson.Safe.pretty_to_string
      in
      let* raw_trace_artifact =
        Artifact_service.save_text_internal
          store
          ~session_id:options.session_id
          ~name:"runtime-raw-trace-json"
          ~kind:"json"
          ~content:raw_trace_json
      in
      let tool_catalog_json =
        tool_contracts_to_json (Tool_set.to_list (Agent.tools agent))
        |> Yojson.Safe.pretty_to_string
      in
      let* tool_catalog_artifact =
        Artifact_service.save_text_internal
          store
          ~session_id:options.session_id
          ~name:"tool-catalog"
          ~kind:"json"
          ~content:tool_catalog_json
      in
      let* telemetry_json_path =
        Artifact_service.persisted_path telemetry_json_artifact
      in
      let* telemetry_md_path = Artifact_service.persisted_path telemetry_md_artifact in
      let* raw_trace_json_path = Artifact_service.persisted_path raw_trace_artifact in
      let* tool_catalog_path = Artifact_service.persisted_path tool_catalog_artifact in
      let evidence =
        Runtime_evidence.build_evidence_bundle
          ~session_id:options.session_id
          (Runtime_evidence.base_evidence_file_specs store options.session_id
           @ [ "telemetry_json", telemetry_json_path
             ; "telemetry_md", telemetry_md_path
             ; "raw_trace_json", raw_trace_json_path
             ; "tool_catalog_json", tool_catalog_path
             ])
      in
      let evidence_json =
        Runtime_evidence.evidence_bundle_to_json evidence |> Yojson.Safe.pretty_to_string
      in
      let* evidence_artifact =
        Artifact_service.save_text_internal
          store
          ~session_id:options.session_id
          ~name:"runtime-evidence"
          ~kind:"json"
          ~content:evidence_json
      in
      let artifact_events =
        [ telemetry_json_artifact
        ; telemetry_md_artifact
        ; raw_trace_artifact
        ; tool_catalog_artifact
        ; evidence_artifact
        ]
        |> List.mapi (fun index (artifact : Runtime.artifact) ->
          make_event
            (8 + List.length deltas + index)
            (finished_at +. 0.003 +. (float_of_int index *. 0.001))
            (Runtime_evidence.artifact_attached_event artifact))
      in
      let all_events = base_events @ artifact_events in
      let* final_session = apply_events initial_session all_events in
      let final_report = Runtime_projection.build_report final_session all_events in
      let final_proof = Runtime_projection.build_proof final_session all_events in
      let final_telemetry =
        Runtime_evidence.build_telemetry_report final_session all_events
      in
      let final_telemetry_json =
        Runtime_evidence.telemetry_report_to_json final_telemetry
        |> Yojson.Safe.pretty_to_string
      in
      let final_telemetry_md =
        Runtime_evidence.telemetry_report_to_markdown final_telemetry
      in
      let* () = Runtime_store.save_session store final_session in
      let* () = save_events store options.session_id all_events in
      let* () = Runtime_store.save_report store final_report in
      let* () = Runtime_store.save_proof store final_proof in
      let* () =
        Artifact_service.overwrite_text_internal
          telemetry_json_artifact
          ~content:final_telemetry_json
      in
      let* () =
        Artifact_service.overwrite_text_internal
          telemetry_md_artifact
          ~content:final_telemetry_md
      in
      let final_evidence =
        Runtime_evidence.build_evidence_bundle
          ~session_id:options.session_id
          (Runtime_evidence.base_evidence_file_specs store options.session_id
           @ [ "telemetry_json", telemetry_json_path
             ; "telemetry_md", telemetry_md_path
             ; "raw_trace_json", raw_trace_json_path
             ; "tool_catalog_json", tool_catalog_path
             ])
      in
      let final_evidence_json =
        Runtime_evidence.evidence_bundle_to_json final_evidence
        |> Yojson.Safe.pretty_to_string
      in
      let* () =
        Artifact_service.overwrite_text_internal
          evidence_artifact
          ~content:final_evidence_json
      in
      Sessions.get_proof_bundle
        ?session_root:options.session_root
        ~session_id:options.session_id
        ()
;;

let get_worker_run ~agent ~raw_trace ~options () =
  current_worker_run ~agent ~raw_trace ~options ()
;;

let get_proof_bundle ~agent ~raw_trace ~options () = persist ~agent ~raw_trace ~options ()

let get_conformance ~agent ~raw_trace ~options () =
  let* bundle = get_proof_bundle ~agent ~raw_trace ~options () in
  Ok (Conformance.report bundle)
;;

let run_conformance ~agent ~raw_trace ~options () =
  let* report = get_conformance ~agent ~raw_trace ~options () in
  Ok report
;;

[@@@coverage off]
(* === Inline tests === *)

let%test "safe_name replaces slashes and spaces" = safe_name "my agent/v1" = "my_agent_v1"
let%test "safe_name replaces backslash" = safe_name "path\\to" = "path_to"
let%test "safe_name replaces tab and newline" = safe_name "a\tb\nc" = "a_b_c"
let%test "safe_name trims whitespace" = safe_name "  agent  " = "agent"
let%test "safe_name empty string becomes agent" = safe_name "" = "agent"
let%test "safe_name whitespace only becomes agent" = safe_name "   " = "agent"
let%test "safe_name normal string unchanged" = safe_name "my-agent_v1" = "my-agent_v1"

let%test "primary_alias returns first non-empty alias" =
  primary_alias [ "alice"; "bob" ] = Some "alice"
;;

let%test "primary_alias empty list returns None" = primary_alias [] = None
let%test "primary_alias blank first returns None" = primary_alias [ "  "; "bob" ] = None

let%test "worker_status_of_lifecycle Accepted" =
  worker_status_of_lifecycle Agent.Accepted = Sessions.Accepted
;;

let%test "worker_status_of_lifecycle Ready" =
  worker_status_of_lifecycle Agent.Ready = Sessions.Ready
;;

let%test "worker_status_of_lifecycle Running" =
  worker_status_of_lifecycle Agent.Running = Sessions.Running
;;

let%test "worker_status_of_lifecycle Completed" =
  worker_status_of_lifecycle Agent.Completed = Sessions.Completed
;;

let%test "worker_status_of_lifecycle Failed" =
  worker_status_of_lifecycle Agent.Failed = Sessions.Failed
;;

let%test "empty_raw_details has expected defaults" =
  empty_raw_details.validated = false
  && empty_raw_details.tool_names = []
  && empty_raw_details.final_text = None
  && empty_raw_details.stop_reason = None
  && empty_raw_details.error = None
  && empty_raw_details.paired_tool_result_count = 0
  && empty_raw_details.has_file_write = false
  && empty_raw_details.verification_pass_after_file_write = false
  && empty_raw_details.failure_reason = None
;;

let%test "validation_error creates Io error" =
  match validation_error "test detail" with
  | Error.Io (ValidationFailed { detail }) -> detail = "test detail"
  | _ -> false
;;

let%test "workdir_policy_to_json Required" =
  workdir_policy_to_json Tool.Required = `String "required"
;;

let%test "workdir_policy_to_json Recommended" =
  workdir_policy_to_json Tool.Recommended = `String "recommended"
;;

let%test "workdir_policy_to_json None_expected" =
  workdir_policy_to_json Tool.None_expected = `String "none_expected"
;;

let%test "make_event creates event with correct fields" =
  let event =
    make_event 42 1234.0 (Session_started { goal = "test"; participants = [ "a" ] })
  in
  event.seq = 42 && event.ts = 1234.0
;;

let%test "extract_prompt empty records returns empty" = extract_prompt [] = ""
let%test "extract_text_deltas empty records returns empty" = extract_text_deltas [] = []
