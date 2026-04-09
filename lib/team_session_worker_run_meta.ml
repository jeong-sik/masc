module U = Yojson.Safe.Util

type oas_worker_evidence = Tool_team_session_step_types.oas_worker_evidence = {
  trace_ref : Oas.Raw_trace.run_ref option;
  trace_summary_json : Yojson.Safe.t option;
  trace_validation_json : Yojson.Safe.t option;
  worker_json : Yojson.Safe.t option;
  conformance_json : Yojson.Safe.t option;
  worker : Oas.Sessions.worker_run option;
}

let proof_result_status_to_string = Oas_worker_exec.proof_result_status_to_string

let oas_trace_session_root config =
  Filename.concat (Room_utils.masc_dir config) "oas-runtime"

let load_oas_worker_evidence ~(config : Room.config)
    ~(evidence_session_id : string) =
  let session_root = oas_trace_session_root config in
  match
    Oas.Sessions.get_proof_bundle ~session_root ~session_id:evidence_session_id
      (),
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
            | Some validation ->
                Some (Oas.Raw_trace.run_validation_to_yojson validation)
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

let supported_local_worker_tool_names =
  Tool_catalog.tools_for_surface Tool_catalog.Local_worker

let observe_only_policy : Tool_access_policy.t =
  {
    allow = Surface Tool_catalog.Local_worker;
    deny =
      Names
        [
          "masc_add_task";
          "masc_claim_next";
          "masc_transition";
          "masc_board_post";
          "masc_board_comment";
          "masc_board_vote";
          "masc_worktree_create";
          "masc_worktree_remove";
          "masc_run_init";
          "masc_run_plan";
          "masc_run_log";
          "masc_run_deliverable";
          "masc_repair_loop_start";
          "masc_repair_loop_iterate";
          "masc_repair_loop_stop";
        ];
  }

let supported_local_worker_tool_names_for_scope execution_scope =
  match execution_scope with
  | Some Team_session_types.Observe_only ->
      Tool_access_policy.resolve observe_only_policy
  | Some Team_session_types.Limited_code_change
  | Some Team_session_types.Autonomous
  | None ->
      supported_local_worker_tool_names

let local_shell_tool_names_of_scope = function
  | Team_session_types.Observe_only ->
      [ "file_read"; "shell_exec" ]
  | _ ->
      [ "file_read"; "file_write"; "shell_exec" ]

let json_string_list values =
  `List (List.map (fun value -> `String value) values)

let dedup_tool_names values =
  Team_session_types.dedup_strings values |> List.sort String.compare

let tool_surface_source_of_mode = function
  | "swarm" -> Some "swarm_masc_tools"
  | "spawn" | "delegate" -> Some "local_worker_tools"
  | _ -> None

let trace_capability_to_string : Oas.Sessions.trace_capability -> string =
  function
  | Oas.Sessions.Raw -> "raw"
  | Oas.Sessions.Summary_only -> "summary_only"
  | Oas.Sessions.No_trace -> "none"

let prefer_option primary fallback =
  match primary with Some _ -> primary | None -> fallback

let prefer_nonempty_string primary fallback =
  match primary with
  | Some value when String.trim value <> "" -> Some value
  | _ -> fallback

let string_member_opt key json =
  match U.member key json with
  | `String value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let int_member_opt key json =
  match U.member key json with
  | `Int value -> Some value
  | `Intlit value -> int_of_string_opt value
  | _ -> None

let bool_member ~default key json =
  match U.member key json with
  | `Bool value -> value
  | _ -> default

let json_member_opt key json =
  match U.member key json with `Null -> None | other -> Some other

let string_list_member key json =
  match U.member key json with
  | `List items ->
      items
      |> List.filter_map (function
           | `String value when String.trim value <> "" ->
               Some (String.trim value)
           | _ -> None)
  | _ -> []

let execution_scope_member_opt key json =
  string_member_opt key json
  |> Option.map (fun value ->
         Team_session_types.execution_scope_of_string
           (String.lowercase_ascii value))

let worker_class_member_opt key json =
  match string_member_opt key json with
  | Some value ->
      Team_session_types.worker_class_of_string
        (String.lowercase_ascii value)
  | None -> None

let wait_mode_member key json =
  string_member_opt key json
  |> Option.map String.lowercase_ascii
  |> Option.map Team_session_types.wait_mode_of_string
  |> Option.value ~default:Team_session_types.Wait_background

let trace_ref_member_opt key json =
  match U.member key json with
  | `Assoc _ as value -> (
      match Oas.Raw_trace.run_ref_of_yojson value with
      | Ok run_ref -> Some run_ref
      | Error msg ->
          Log.Session.warn
            "team_session_worker_run_meta: dropping invalid trace_ref: %s"
            msg;
          None)
  | _ -> None

let load_saved_proof ~(config : Room.config) ~(session_id : string)
    ~(worker_run_id : string) =
  let path =
    Team_session_store.worker_run_proof_path config session_id worker_run_id
  in
  if not (Room_utils.path_exists config path) then
    None
  else
    match Oas.Cdal_proof.of_json (Room_utils.read_json config path) with
    | Ok proof -> Some proof
    | Error msg ->
        Log.Session.warn
          "team_session_worker_run_meta: dropping invalid saved proof for worker_run=%s: %s"
          worker_run_id msg;
        None

let rec canonicalize_json = function
  | `Assoc fields ->
      `Assoc
        (fields
        |> List.map (fun (key, value) -> (key, canonicalize_json value))
        |> List.sort (fun (left, _) (right, _) -> String.compare left right))
  | `List items -> `List (List.map canonicalize_json items)
  | other -> other

let comparable_json json =
  match json with
  | `Assoc fields ->
      `Assoc
        (fields
        |> List.filter (fun (key, _) -> not (String.equal key "ts_iso"))
        |> List.map (fun (key, value) -> (key, canonicalize_json value))
        |> List.sort (fun (left, _) (right, _) -> String.compare left right))
  | other -> canonicalize_json other

let changed_fields ~before ~after =
  let before_fields =
    match before with `Assoc fields -> fields | _ -> []
  in
  let after_fields =
    match after with `Assoc fields -> fields | _ -> []
  in
  let keys =
    List.map fst before_fields @ List.map fst after_fields
    |> List.filter (fun key -> not (String.equal key "ts_iso"))
    |> Team_session_types.dedup_strings
    |> List.sort String.compare
  in
  List.filter
    (fun key ->
      let before_value =
        List.assoc_opt key before_fields |> Option.value ~default:`Null
      in
      let after_value =
        List.assoc_opt key after_fields |> Option.value ~default:`Null
      in
      not
        (Yojson.Safe.equal (canonicalize_json before_value)
           (canonicalize_json after_value)))
    keys

let tool_surface_fields ~mode ?execution_scope ?(proof : Oas.Cdal_proof.t option)
    () =
  let tool_surface_masc_names =
    match mode, execution_scope with
    | "swarm", Some scope ->
        supported_local_worker_tool_names_for_scope (Some scope)
    | ("spawn" | "delegate"), Some scope ->
        supported_local_worker_tool_names_for_scope (Some scope)
    | _ -> []
  in
  let tool_surface_shell_names =
    match mode, execution_scope with
    | ("spawn" | "delegate"), Some scope ->
        local_shell_tool_names_of_scope scope
    | _ -> []
  in
  let tool_surface_names =
    let proof_tool_names =
      match proof with
      | Some proof -> proof.capability_snapshot.tools
      | None -> []
    in
    dedup_tool_names
      (proof_tool_names @ tool_surface_masc_names @ tool_surface_shell_names)
  in
  [
    ( "tool_surface_status",
      `String
        (if tool_surface_names <> [] then "available" else "missing") );
    ( "tool_surface_source",
      Option.fold ~none:`Null ~some:(fun value -> `String value)
        (if tool_surface_names <> [] then tool_surface_source_of_mode mode
         else None) );
    ("tool_surface_names", json_string_list tool_surface_names);
    ("tool_surface_masc_names", json_string_list tool_surface_masc_names);
    ("tool_surface_shell_names", json_string_list tool_surface_shell_names);
  ]

let proof_fields ~(config : Room.config) ~(session_id : string)
    ~(worker_run_id : string) ?(persist_proof_json = false)
    ?(proof : Oas.Cdal_proof.t option) () =
  let null_fields =
    [
      ("cdal_run_id", `Null);
      ("contract_id", `Null);
      ("requested_execution_mode", `Null);
      ("effective_execution_mode", `Null);
      ("risk_class", `Null);
      ("result_status", `Null);
      ("tool_trace_refs", `List []);
      ("raw_evidence_refs", `List []);
      ("checkpoint_ref", `Null);
      ("proof_path", `Null);
      ("proof_present", `Bool false);
      ("proof_run_id", `Null);
      ("proof_status", `Null);
      ("proof_risk_class", `Null);
      ("proof_execution_mode", `Null);
      ("proof_evidence_count", `Null);
    ]
  in
  match proof with
  | None -> null_fields
  | Some proof -> (
      match Repo_synthesis_benchmark.validate_run_id proof.run_id with
      | Error msg ->
          Log.Session.warn
            "team_session_worker_run_meta: dropping invalid proof_run_id for worker_run=%s: %s"
            worker_run_id msg;
          null_fields
      | Ok run_id ->
          let proof_path =
            Team_session_store.worker_run_proof_path config session_id
              worker_run_id
          in
          if persist_proof_json then
            Team_session_store.save_worker_run_proof_json config session_id
              worker_run_id (Oas.Cdal_proof.to_json proof);
          [
            ("cdal_run_id", `String run_id);
            ("contract_id", `String proof.contract_id);
            ( "requested_execution_mode",
              `String
                (Oas.Execution_mode.to_string proof.requested_execution_mode)
            );
            ( "effective_execution_mode",
              `String
                (Oas.Execution_mode.to_string proof.effective_execution_mode)
            );
            ("risk_class", `String (Oas.Risk_class.to_string proof.risk_class));
            ( "result_status",
              `String (proof_result_status_to_string proof.result_status) );
            ("tool_trace_refs", json_string_list proof.tool_trace_refs);
            ("raw_evidence_refs", json_string_list proof.raw_evidence_refs);
            ( "checkpoint_ref",
              Option.fold ~none:`Null ~some:(fun value -> `String value)
                proof.checkpoint_ref );
            ("proof_path", `String proof_path);
            ("proof_present", `Bool true);
            ("proof_run_id", `String run_id);
            ( "proof_status",
              `String (proof_result_status_to_string proof.result_status) );
            ("proof_risk_class", `String (Oas.Risk_class.to_string proof.risk_class));
            ( "proof_execution_mode",
              `String
                (Oas.Execution_mode.to_string proof.effective_execution_mode)
            );
            ("proof_evidence_count", `Int (List.length proof.raw_evidence_refs));
          ])

let build_json ~(config : Room.config) ~(session_id : string)
    ~(worker_run_id : string) ~(worker_name : string) ~(mode : string)
    ~(wait_mode : Team_session_types.wait_mode) ?execution_scope
    ?requested_worker_class ?resolved_runtime ?resolved_model ?routing_reason
    ?(tool_names : string list option) ?tool_call_count ~(status : Yojson.Safe.t)
    ~(success : bool) ?output_preview ?error ?trace_capability ?trace_ref
    ?trace_summary ?trace_validation ?evidence_session_id
    ?(oas_evidence : oas_worker_evidence option) ?final_text ?stop_reason
    ?failure_reason ?(proof : Oas.Cdal_proof.t option)
    ?(persist_proof_json = false) () =
  let oas_worker = Option.bind oas_evidence (fun payload -> payload.worker) in
  let effective_trace_ref =
    prefer_option (Option.bind oas_evidence (fun payload -> payload.trace_ref))
      trace_ref
  in
  let effective_trace_summary =
    prefer_option
      (Option.bind oas_evidence (fun payload -> payload.trace_summary_json))
      trace_summary
  in
  let effective_trace_validation =
    prefer_option
      (Option.bind oas_evidence (fun payload -> payload.trace_validation_json))
      trace_validation
  in
  let effective_status =
    match oas_worker with
    | Some worker -> Oas.Sessions.worker_status_to_yojson worker.status
    | None -> status
  in
  let effective_trace_capability =
    match oas_worker with
    | Some worker ->
        trace_capability_to_string worker.Oas.Sessions.trace_capability
    | None -> (
        match trace_capability with
        | Some value -> value
        | None when Option.is_some effective_trace_ref -> "raw"
        | None -> "summary_only")
  in
  let effective_tool_names =
    match oas_worker with
    | Some worker when worker.tool_names <> [] -> worker.tool_names
    | _ -> Option.value ~default:[] tool_names
  in
  let effective_resolved_model =
    match oas_worker with
    | Some worker -> prefer_option worker.resolved_model resolved_model
    | None -> resolved_model
  in
  let effective_error =
    match oas_worker with
    | Some worker ->
        prefer_nonempty_string worker.failure_reason
          (prefer_nonempty_string worker.error error)
    | None -> error
  in
  let effective_final_text =
    match oas_worker with
    | Some worker -> prefer_nonempty_string worker.final_text final_text
    | None -> final_text
  in
  let effective_output_preview =
    prefer_nonempty_string effective_final_text output_preview
  in
  let effective_stop_reason =
    match oas_worker with
    | Some worker -> prefer_nonempty_string worker.stop_reason stop_reason
    | None -> stop_reason
  in
  let effective_failure_reason =
    match oas_worker with
    | Some worker ->
        prefer_nonempty_string worker.failure_reason failure_reason
    | None -> failure_reason
  in
  let tool_surface_fields =
    tool_surface_fields ~mode ?execution_scope ?proof ()
  in
  let proof_fields =
    proof_fields ~config ~session_id ~worker_run_id ~persist_proof_json ?proof
      ()
  in
  `Assoc
    ([
       ("worker_run_id", `String worker_run_id);
       ("worker_name", `String worker_name);
       ("mode", `String mode);
       ("status", effective_status);
       ("wait_mode", `String (Team_session_types.wait_mode_to_string wait_mode));
       ("trace_capability", `String effective_trace_capability);
       ("success", `Bool success);
       ( "execution_scope",
         Option.fold ~none:`Null
           ~some:(fun scope ->
             `String (Team_session_types.execution_scope_to_string scope))
           execution_scope );
       ( "requested_worker_class",
         Option.fold ~none:`Null
           ~some:(fun kind ->
             `String (Team_session_types.worker_class_to_string kind))
           requested_worker_class );
       ( "resolved_runtime",
         Option.fold ~none:`Null ~some:(fun value -> `String value)
           resolved_runtime );
       ( "resolved_model",
         Option.fold ~none:`Null ~some:(fun value -> `String value)
           effective_resolved_model );
       ( "routing_reason",
         Option.fold ~none:`Null ~some:(fun value -> `String value)
           routing_reason );
       ("tool_names", json_string_list effective_tool_names);
       ( "tool_call_count",
         Option.fold ~none:`Null ~some:(fun value -> `Int value)
           tool_call_count );
       ( "output_preview",
         Option.fold ~none:`Null ~some:(fun value -> `String value)
           effective_output_preview );
       ( "error",
         Option.fold ~none:`Null ~some:(fun value -> `String value)
           effective_error );
       ( "trace_ref",
         Option.fold ~none:`Null ~some:Oas.Raw_trace.run_ref_to_yojson
           effective_trace_ref );
       ( "trace_summary",
         Option.fold ~none:`Null ~some:(fun json -> json)
           effective_trace_summary );
       ( "trace_validation",
         Option.fold ~none:`Null ~some:(fun json -> json)
           effective_trace_validation );
       ( "evidence_session_id",
         Option.fold ~none:`Null ~some:(fun value -> `String value)
           evidence_session_id );
       ( "oas_worker_run",
         Option.fold ~none:`Null ~some:(fun json -> json)
           (Option.bind oas_evidence (fun payload -> payload.worker_json)) );
       ( "session_conformance",
         Option.fold ~none:`Null ~some:(fun json -> json)
           (Option.bind oas_evidence (fun payload -> payload.conformance_json))
       );
       ( "validated",
         Option.fold ~none:`Null
           ~some:(fun worker -> `Bool worker.Oas.Sessions.validated)
           oas_worker );
       ( "final_text",
         Option.fold ~none:`Null ~some:(fun value -> `String value)
           effective_final_text );
       ( "stop_reason",
         Option.fold ~none:`Null ~some:(fun value -> `String value)
           effective_stop_reason );
       ( "failure_reason",
         Option.fold ~none:`Null ~some:(fun value -> `String value)
           effective_failure_reason );
       ("ts_iso", `String (Types.now_iso ()));
     ]
    @ tool_surface_fields @ proof_fields)

let persist ~(config : Room.config) ~(session_id : string)
    ~(worker_run_id : string) ~(worker_name : string) ~(mode : string)
    ~(wait_mode : Team_session_types.wait_mode) ?execution_scope
    ?requested_worker_class ?resolved_runtime ?resolved_model ?routing_reason
    ?(tool_names : string list option) ?tool_call_count ~(status : Yojson.Safe.t)
    ~(success : bool) ?output_preview ?error ?trace_capability ?trace_ref
    ?trace_summary ?trace_validation ?evidence_session_id
    ?(oas_evidence : oas_worker_evidence option) ?final_text ?stop_reason
    ?failure_reason ?(proof : Oas.Cdal_proof.t option) () =
  let json =
    build_json ~config ~session_id ~worker_run_id ~worker_name ~mode ~wait_mode
      ?execution_scope ?requested_worker_class ?resolved_runtime
      ?resolved_model ?routing_reason ?tool_names ?tool_call_count ~status
      ~success ?output_preview ?error ?trace_capability ?trace_ref
      ?trace_summary ?trace_validation ?evidence_session_id ?oas_evidence
      ?final_text ?stop_reason ?failure_reason ?proof
      ~persist_proof_json:true ()
  in
  Team_session_store.save_worker_run_meta_json config session_id worker_run_id
    json

type repair_status =
  | Repair_would_apply
  | Repair_applied
  | Repair_unchanged
  | Repair_skipped

type repair_item = {
  worker_run_id : string;
  status : repair_status;
  reason : string;
  changed_fields : string list;
  evidence_session_id : string option;
}

type repair_summary = {
  session_id : string;
  worker_run_filter : string option;
  dry_run : bool;
  scanned_count : int;
  changed_count : int;
  applied_count : int;
  unchanged_count : int;
  skipped_count : int;
  items : repair_item list;
}

let repair_status_to_string = function
  | Repair_would_apply -> "would_repair"
  | Repair_applied -> "repaired"
  | Repair_unchanged -> "unchanged"
  | Repair_skipped -> "skipped"

let repair_item_to_yojson (item : repair_item) =
  `Assoc
    [
      ("worker_run_id", `String item.worker_run_id);
      ("status", `String (repair_status_to_string item.status));
      ("reason", `String item.reason);
      ("changed_fields", json_string_list item.changed_fields);
      ( "evidence_session_id",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          item.evidence_session_id );
    ]

let repair_summary_to_yojson (summary : repair_summary) =
  `Assoc
    [
      ("session_id", `String summary.session_id);
      ( "worker_run_id",
        Option.fold ~none:`Null ~some:(fun value -> `String value)
          summary.worker_run_filter );
      ("dry_run", `Bool summary.dry_run);
      ("scanned_count", `Int summary.scanned_count);
      ("changed_count", `Int summary.changed_count);
      ("applied_count", `Int summary.applied_count);
      ("unchanged_count", `Int summary.unchanged_count);
      ("skipped_count", `Int summary.skipped_count);
      ("items", `List (List.map repair_item_to_yojson summary.items));
    ]

let mode_of_existing_meta json =
  match string_member_opt "mode" json with
  | Some value -> value
  | None -> (
      match string_member_opt "tool_surface_source" json with
      | Some "swarm_masc_tools" -> "swarm"
      | _ -> "delegate")

let status_of_existing_meta json =
  match U.member "status" json with
  | `Null -> `String "failed"
  | other -> other

let candidate_json_of_existing_meta ~(config : Room.config)
    ~(session_id : string) ~(worker_run_id : string) ~(existing_meta : Yojson.Safe.t)
    ?(oas_evidence : oas_worker_evidence option)
    ?(proof : Oas.Cdal_proof.t option) () =
  build_json ~config ~session_id ~worker_run_id
    ~worker_name:
      (string_member_opt "worker_name" existing_meta
      |> Option.value ~default:worker_run_id)
    ~mode:(mode_of_existing_meta existing_meta)
    ~wait_mode:(wait_mode_member "wait_mode" existing_meta)
    ?execution_scope:(execution_scope_member_opt "execution_scope" existing_meta)
    ?requested_worker_class:
      (worker_class_member_opt "requested_worker_class" existing_meta)
    ?resolved_runtime:(string_member_opt "resolved_runtime" existing_meta)
    ?resolved_model:(string_member_opt "resolved_model" existing_meta)
    ?routing_reason:(string_member_opt "routing_reason" existing_meta)
    ?tool_names:(Some (string_list_member "tool_names" existing_meta))
    ?tool_call_count:(int_member_opt "tool_call_count" existing_meta)
    ~status:(status_of_existing_meta existing_meta)
    ~success:(bool_member ~default:false "success" existing_meta)
    ?output_preview:(string_member_opt "output_preview" existing_meta)
    ?error:(string_member_opt "error" existing_meta)
    ?trace_capability:(string_member_opt "trace_capability" existing_meta)
    ?trace_ref:(trace_ref_member_opt "trace_ref" existing_meta)
    ?trace_summary:(json_member_opt "trace_summary" existing_meta)
    ?trace_validation:(json_member_opt "trace_validation" existing_meta)
    ?evidence_session_id:(string_member_opt "evidence_session_id" existing_meta)
    ?oas_evidence
    ?final_text:(string_member_opt "final_text" existing_meta)
    ?stop_reason:(string_member_opt "stop_reason" existing_meta)
    ?failure_reason:(string_member_opt "failure_reason" existing_meta)
    ?proof ~persist_proof_json:false ()

let repair_session_with ~(config : Room.config) ~(session_id : string)
    ?worker_run_id ~(dry_run : bool)
    ~(load_oas_evidence : evidence_session_id:string -> oas_worker_evidence option)
    ~(load_saved_proof :
       session_id:string -> worker_run_id:string -> Oas.Cdal_proof.t option)
    () =
  match Team_session_store.load_session config session_id with
  | None -> Error (Printf.sprintf "team session not found: %s" session_id)
  | Some _ ->
      let available_worker_run_ids =
        Team_session_store.list_worker_run_ids config session_id
      in
      let worker_run_ids =
        match worker_run_id with
        | Some target when List.mem target available_worker_run_ids -> Ok [ target ]
        | Some target ->
            Error (Printf.sprintf "worker run not found: %s" target)
        | None -> Ok available_worker_run_ids
      in
      Result.map
        (fun worker_run_ids ->
          let items =
            List.map
              (fun worker_run_id ->
                let meta_path =
                  Team_session_store.worker_run_meta_path config session_id
                    worker_run_id
                in
                if not (Room_utils.path_exists config meta_path) then
                  {
                    worker_run_id;
                    status = Repair_skipped;
                    reason = "meta_missing";
                    changed_fields = [];
                    evidence_session_id = None;
                  }
                else
                  let existing_meta = Room_utils.read_json config meta_path in
                  let evidence_session_id =
                    string_member_opt "evidence_session_id" existing_meta
                  in
                  let oas_evidence =
                    Option.bind evidence_session_id (fun evidence_session_id ->
                        load_oas_evidence ~evidence_session_id)
                  in
                  let proof =
                    load_saved_proof ~session_id ~worker_run_id
                  in
                  if Option.is_none oas_evidence && Option.is_none proof then
                    {
                      worker_run_id;
                      status = Repair_skipped;
                      reason = "recoverable_source_missing";
                      changed_fields = [];
                      evidence_session_id;
                    }
                  else
                    let candidate_json =
                      candidate_json_of_existing_meta ~config ~session_id
                        ~worker_run_id ~existing_meta ?oas_evidence ?proof ()
                    in
                    let candidate_json =
                      Team_session_store.normalize_worker_run_meta_json config
                        ~session_id ~worker_run_id candidate_json
                    in
                    let changed_fields =
                      changed_fields ~before:existing_meta ~after:candidate_json
                    in
                    if changed_fields = [] then
                      {
                        worker_run_id;
                        status = Repair_unchanged;
                        reason = "already_enriched";
                        changed_fields;
                        evidence_session_id;
                      }
                    else (
                      if not dry_run then begin
                        Team_session_store.save_worker_run_meta_json config
                          session_id worker_run_id candidate_json;
                        Option.iter
                          (fun proof ->
                            Team_session_store.save_worker_run_proof_json config
                              session_id worker_run_id
                              (Oas.Cdal_proof.to_json proof))
                          proof
                      end;
                      {
                        worker_run_id;
                        status =
                          (if dry_run then Repair_would_apply
                           else Repair_applied);
                        reason =
                          (if dry_run then "repair_available" else "repaired");
                        changed_fields;
                        evidence_session_id;
                      }))
              worker_run_ids
          in
          let count_by predicate =
            List.fold_left
              (fun acc item -> if predicate item then acc + 1 else acc)
              0 items
          in
          {
            session_id;
            worker_run_filter = worker_run_id;
            dry_run;
            scanned_count = List.length worker_run_ids;
            changed_count =
              count_by (fun item ->
                  match item.status with
                  | Repair_would_apply | Repair_applied -> true
                  | Repair_unchanged | Repair_skipped -> false);
            applied_count =
              count_by (fun item -> item.status = Repair_applied);
            unchanged_count =
              count_by (fun item -> item.status = Repair_unchanged);
            skipped_count =
              count_by (fun item -> item.status = Repair_skipped);
            items;
          })
        worker_run_ids

let repair_session ~(config : Room.config) ~(session_id : string) ?worker_run_id
    ~(dry_run : bool) () =
  repair_session_with ~config ~session_id ?worker_run_id ~dry_run
    ~load_oas_evidence:(fun ~evidence_session_id ->
      load_oas_worker_evidence ~config ~evidence_session_id)
    ~load_saved_proof:(fun ~session_id ~worker_run_id ->
      load_saved_proof ~config ~session_id ~worker_run_id)
    ()
