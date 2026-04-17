(** Tool_autoresearch — MCP tool dispatch for the Autoresearch loop.

    Inspired by Karpathy's autoresearch pattern: autonomous experiment cycles
    that generate hypotheses, measure metrics, and keep/discard changes via git.

    Schemas are defined in {!Tool_autoresearch_schemas}.

    @since 2.80.0 *)

open Tool_args

(* Re-export sub-modules *)
include Tool_autoresearch_registry
include Tool_autoresearch_broadcast
type context = Tool_autoresearch_context.t
let schemas = Tool_autoresearch_schemas.schemas

type tool_result = bool * string

let persisted_summary_json (summary : Autoresearch.persisted_summary) =
  `Assoc
    [
      ("loop_id", `String summary.loop_id);
      ("goal", `String summary.goal);
      ("metric_fn", `String summary.metric_fn);
      ("model_model", `String summary.model_model);
      ("target_file", `String summary.target_file);
      ("target_score", Json_util.float_opt_to_json summary.target_score);
      ( "target_reached",
        `Bool
          (match summary.target_score with
           | None -> false
           | Some target ->
               if summary.lower_is_better then summary.best_score <= target
               else summary.best_score >= target) );
      ("status", `String (Autoresearch.status_to_string summary.status));
      ("current_cycle", `Int summary.current_cycle);
      ("baseline", `Float summary.baseline);
      ("best_score", `Float summary.best_score);
      ("best_cycle", `Int summary.best_cycle);
      ( "queued_hypothesis",
        Json_util.string_opt_to_json summary.queued_hypothesis );
      ("total_keeps", `Int summary.total_keeps);
      ("total_discards", `Int summary.total_discards);
      ("max_cycles", `Int summary.max_cycles);
      ("cycle_timeout_s", `Float summary.cycle_timeout_s);
      ("workdir", `String summary.workdir);
      ("source_workdir", `String summary.source_workdir);
      ("elapsed_s", `Float summary.elapsed_s);
      ("recent_cycles", `List []);
      ( "program_note",
        Json_util.string_opt_to_json summary.program_note );
      ("warnings", `List (List.map (fun value -> `String value) summary.warnings));
      ("patience", `Int summary.patience);
      ("consecutive_discards", `Int summary.consecutive_discards);
      ("build_verify_fn", Json_util.string_opt_to_json summary.build_verify_fn);
      ("lower_is_better", `Bool summary.lower_is_better);
      ("error", Json_util.string_opt_to_json summary.error_message);
    ]

let resolve_loop_id args =
  match get_string_opt args "loop_id" with
  | Some id -> Some id
  | None -> Autoresearch.with_loops_ro (fun () -> !latest_loop_id)

type start_params = {
  goal : string;
  metric_fn : string;
  target_file : string;
  source_workdir : string;
  max_cycles : int;
  cycle_timeout_s : float;
  model_model : string;
  baseline_override : float option;
  target_score : float option;
  patience : int option;
  build_verify_fn : string option;
  lower_is_better : bool;
}

let prepare_start_params (ctx : context) args =
  let goal = get_string args "goal" "" in
  let metric_fn = get_string args "metric_fn" "" in
  let target_file = get_string args "target_file" "" in
  let source_workdir = get_string args "workdir" ctx.base_path in
  let max_cycles = get_int args "max_cycles" 100 in
  let cycle_timeout_s = get_float args "cycle_timeout_s" 300.0 in
  let model_model_result =
    match get_string_opt args "model_model" with
    | Some m -> Ok m
    | None -> Provider_adapter.default_model_label_result ()
  in
  match model_model_result with
  | Error e -> Error (Printf.sprintf "no default model configured: %s" e)
  | Ok model_model ->
  if goal = "" then
    Error "goal is required"
  else if metric_fn = "" then
    Error "metric_fn is required"
  else if target_file = "" then
    Error "target_file is required"
  else
    (* Validate metric_fn early to reject shell injection before any state is created *)
    match Autoresearch_metric.validate_metric_fn metric_fn with
    | Error e -> Error e
    | Ok metric_fn ->
    let build_verify_fn = get_string_opt args "build_verify_fn" in
    let validated_build_verify_fn =
      match build_verify_fn with
      | Some cmd -> (
        match Autoresearch_metric.validate_metric_fn cmd with
        | Error e -> Error (Printf.sprintf "build_verify_fn: %s" e)
        | Ok _ -> Ok (Some cmd))
      | None -> Ok None
    in
    match validated_build_verify_fn with
    | Error e -> Error e
    | Ok build_verify_fn ->
      Ok
        {
          goal;
          metric_fn;
          target_file;
          source_workdir;
          max_cycles;
          cycle_timeout_s;
          model_model;
          baseline_override = get_float_opt args "baseline";
          target_score = get_float_opt args "target_score";
          patience = get_int_opt args "patience";
          build_verify_fn;
          lower_is_better = get_bool args "lower_is_better" false;
        }

let register_loop (ctx : context) state =
  Autoresearch.save_state ~base_path:ctx.base_path state;
  Autoresearch.with_loops_rw (fun () ->
    Hashtbl.replace active_loops state.loop_id state;
    latest_loop_id := Some state.loop_id);
  state

let prepare_managed_target_file ~source_workdir ~managed_workdir target_file =
  match Autoresearch.validate_target_file ~workdir:managed_workdir target_file with
  | Ok _ -> Ok []
  | Error managed_error ->
      match Autoresearch.validate_target_file ~workdir:source_workdir target_file with
      | Error _ ->
          Error (Printf.sprintf "Invalid target_file: %s" managed_error)
      | Ok source_abs ->
          (match
             Autoresearch.resolve_target_file_path ~workdir:managed_workdir
               target_file
           with
          | Error path_error ->
              Error (Printf.sprintf "Invalid target_file: %s" path_error)
          | Ok managed_abs ->
              try
                Fs_compat.mkdir_p (Filename.dirname managed_abs);
                Fs_compat.save_file managed_abs
                  (Autoresearch.read_file source_abs);
                Ok [ "target_file_seeded_from_source" ]
              with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
                Error
                  (Printf.sprintf
                     "Failed to seed target_file into managed worktree: %s"
                     (Printexc.to_string exn)))

let setup_running_loop (ctx : context) (params : start_params) =
  let state =
    Autoresearch.create_state ~goal:params.goal ~metric_fn:params.metric_fn
      ?author:ctx.agent_name
      ~model_model:params.model_model ~target_file:params.target_file
      ?target_score:params.target_score
      ~cycle_timeout_s:params.cycle_timeout_s ~max_cycles:params.max_cycles
      ?patience:params.patience ?build_verify_fn:params.build_verify_fn
      ~lower_is_better:params.lower_is_better
      ~workdir:params.source_workdir ()
  in
  match
    Autoresearch.prepare_managed_worktree ~base_path:ctx.base_path
      ~source_workdir:params.source_workdir ~loop_id:state.loop_id
  with
  | Error message -> Error message
  | Ok (managed_workdir, source_workdir, warnings) -> (
      match
        prepare_managed_target_file ~source_workdir ~managed_workdir
          params.target_file
      with
      | Error message -> Error message
      | Ok target_file_warnings ->
          let warnings = warnings @ target_file_warnings in
          let state = { state with workdir = managed_workdir; warnings } in
          let baseline_result =
            match params.baseline_override with
            | Some baseline -> Ok baseline
            | None -> (
                match
                  Autoresearch.measure_metric ~workdir:managed_workdir
                    ~timeout_s:params.cycle_timeout_s params.metric_fn
                with
                | Ok (baseline, _ms) -> Ok baseline
                | Error e ->
                    Error
                      (Printf.sprintf "Failed to measure baseline: %s" e))
          in
          match baseline_result with
          | Error message -> Error message
          | Ok baseline ->
              let state =
                Autoresearch.complete_if_finished
                  { state with baseline; best_score = baseline; source_workdir }
              in
              Ok (register_loop ctx state))

let status_json (ctx : context) ~loop_id json_fields =
  let strip_keys keys fields =
    List.filter (fun (key, _value) -> not (List.mem key keys)) fields
  in
  let base_fields =
    match json_fields with
    | `Assoc fields ->
        strip_keys
          [
            "session_id";
            "operation_id";
            "task_id";
            "program_note";
            "queued_hypothesis";
          ]
          fields
    | _ -> [ ("error", `String "invalid status payload") ]
  in
  let link =
    Autoresearch.load_swarm_link_by_loop ~base_path:ctx.base_path loop_id
  in
  let queued_hypothesis = Hashtbl.find_opt pending_hypotheses loop_id in
  let link_fields =
    match link with
    | Some link ->
        [
          ("session_id", `String link.session_id);
          ( "operation_id",
            Json_util.string_opt_to_json link.operation_id );
          ("task_id", Json_util.string_opt_to_json link.task_id);
        ]
    | None ->
        [ ("session_id", `Null); ("operation_id", `Null); ("task_id", `Null) ]
  in
  `Assoc
    (base_fields
    @ link_fields
    @ [
        ( "queued_hypothesis",
          Json_util.string_opt_to_json queued_hypothesis );
      ])

let build_swarm_goal ~goal ~target_file ~program_note =
  match program_note with
  | Some note ->
      Printf.sprintf
        "Autoresearch swarm goal: %s\nTarget file: %s\nProgram note:\n%s"
        goal target_file note
  | None ->
      Printf.sprintf "Autoresearch swarm goal: %s\nTarget file: %s" goal
        target_file

let parse_operation_id json =
  match Yojson.Safe.Util.member "operation_id" json with
  | `String value when String.trim value <> "" -> Some (String.trim value)
  | _ -> None

let handle_start (ctx : context) args =
  match prepare_start_params ctx args with
  | Error message -> `Assoc [ ("error", `String message) ]
  | Ok params -> (
      match setup_running_loop ctx params with
      | Error message -> `Assoc [ ("error", `String message) ]
      | Ok state ->
      broadcast_loop_lifecycle "autoresearch_started" state;
      `Assoc [
        ("loop_id", `String state.loop_id);
        ("status", `String (Autoresearch.status_to_string state.status));
        ("goal", `String params.goal);
        ("metric_fn", `String params.metric_fn);
        ("target_file", `String params.target_file);
        ("model_model", `String params.model_model);
        ("baseline", `Float state.baseline);
        ("target_score", Json_util.float_opt_to_json state.target_score);
        ("target_reached", `Bool (Autoresearch.target_reached state));
        ("max_cycles", `Int params.max_cycles);
        ("cycle_timeout_s", `Float params.cycle_timeout_s);
        ("workdir", `String state.workdir);
        ("source_workdir", `String state.source_workdir);
        ("queued_hypothesis", `Null);
        ("patience", `Int state.patience);
        ("build_verify_fn", Json_util.string_opt_to_json state.build_verify_fn);
        ("warnings", `List (List.map (fun value -> `String value) state.warnings));
      ])

let handle_status (ctx : context) args =
  match resolve_loop_id args with
  | None -> `Assoc [("error", `String "No autoresearch loop running")]
  | Some id ->
    let in_memory = Autoresearch.with_loops_ro (fun () ->
      match Hashtbl.find_opt active_loops id with
      | Some state -> Some (Autoresearch.summary state)
      | None -> None)
    in
    match in_memory with
    | Some json -> status_json ctx ~loop_id:id json
    | None -> (
        match Autoresearch.load_state ~base_path:ctx.base_path id with
        | Some summary -> status_json ctx ~loop_id:id (persisted_summary_json summary)
        | None ->
            `Assoc [("error", `String (Printf.sprintf "Loop %s not found" id))])

let handle_stop (ctx : context) args =
  let reason = get_string args "reason" "manual stop" in
  match resolve_loop_id args with
  | None -> `Assoc [("error", `String "No autoresearch loop running")]
  | Some id ->
    match Autoresearch.stop_loop ~base_path:ctx.base_path ~reason id with
    | None -> `Assoc [("error", `String (Printf.sprintf "Loop %s not found" id))]
    | Some state ->
        let _config = Coord.default_config ctx.base_path in
        broadcast_loop_lifecycle "autoresearch_stopped" state;
        (match Autoresearch.load_swarm_link_by_loop ~base_path:ctx.base_path id with
        | Some _link ->
            (* Team_session_store removed — skip event append *)
            ()
        | None -> ());
        `Assoc [
          ("loop_id", `String id);
          ("status", `String "stopped");
          ("reason", `String reason);
          ("final_cycle", `Int state.current_cycle);
          ("best_score", `Float state.best_score);
          ("best_cycle", `Int state.best_cycle);
          ("total_keeps", `Int state.total_keeps);
          ("total_discards", `Int state.total_discards);
        ]

let handle_inject (ctx : context) args =
  let hypothesis = get_string args "hypothesis" "" in
  if hypothesis = "" then
    `Assoc [("error", `String "hypothesis is required")]
  else
    match resolve_loop_id args with
    | None -> `Assoc [("error", `String "No autoresearch loop running")]
    | Some id ->
      Autoresearch.with_loops_rw (fun () ->
        match Hashtbl.find_opt active_loops id with
        | None -> `Assoc [("error", `String (Printf.sprintf "Loop %s not found" id))]
        | Some state ->
          if state.status <> Autoresearch.Running then
            `Assoc [("error", `String "Loop is not running")]
          else begin
            let state = { state with queued_hypothesis = Some hypothesis } in
            Hashtbl.replace active_loops id state;
            Autoresearch.save_state ~base_path:ctx.base_path state;
            Hashtbl.replace pending_hypotheses id hypothesis;
            `Assoc [
              ("loop_id", `String id);
              ("status", `String "hypothesis_queued");
              ("hypothesis", `String hypothesis);
              ("will_test_at_cycle", `Int (state.current_cycle + 1));
            ]
          end)

(* ================================================================ *)
(* Dispatch                                                         *)
(* ================================================================ *)

(** Wrap a Yojson.Safe.t result into (success, json_string).
    Returns (false, ...) if the JSON contains an "error" key. *)
let wrap_result json =
  let s = Yojson.Safe.to_string json in
  let is_error = match json with
    | `Assoc fields -> List.mem_assoc "error" fields
    | _ -> false
  in
  (not is_error, s)

(** Handle record_finding — persist a structured research finding. *)
let handle_record_finding (ctx : context) args =
  let keeper_name = match ctx.agent_name with Some n -> n | None -> "unknown" in
  let goal = Safe_ops.json_string ~default:"" "goal" args in
  let hypothesis = Safe_ops.json_string ~default:"" "hypothesis" args in
  let evidence = Safe_ops.json_string ~default:"" "evidence" args in
  let conclusion = Safe_ops.json_string ~default:"" "conclusion" args in
  if goal = "" || hypothesis = "" || evidence = "" || conclusion = "" then
    `Assoc [("error", `String "goal, hypothesis, evidence, conclusion are required")]
  else
    let loop_id = Safe_ops.json_string ~default:"" "loop_id" args in
    let confidence = Safe_ops.json_string ~default:"medium" "confidence" args in
    let tags = match Yojson.Safe.Util.member "tags" args with
      | `List items -> List.filter_map Yojson.Safe.Util.to_string_option items
      | _ -> []
    in
    let cycle_start = Safe_ops.json_int_opt "cycle_start" args in
    let cycle_end = Safe_ops.json_int_opt "cycle_end" args in
    let cycle_range = match cycle_start, cycle_end with
      | Some a, Some b -> Some (a, b)
      | Some a, None -> Some (a, a)  (* single cycle *)
      | None, Some b -> Some (b, b)
      | None, None -> None
    in
    let finding : Autoresearch_knowledge.finding = {
      id = Autoresearch_knowledge.generate_finding_id ();
      loop_id;
      keeper_name;
      goal;
      hypothesis;
      evidence;
      conclusion;
      confidence = Autoresearch_knowledge.confidence_of_string confidence;
      tags;
      related_findings = [];
      cycle_range;
      timestamp = Unix.gettimeofday ();
    } in
    Autoresearch_knowledge.record_finding ~finding

(** Handle search_findings — search previous research findings by keyword. *)
let handle_search_findings _ctx args =
  let query = Safe_ops.json_string ~default:"" "query" args in
  if query = "" then
    `Assoc [("error", `String "query is required")]
  else
    let limit = Safe_ops.json_int ~default:10 "limit" args in
    let findings = Autoresearch_knowledge.search_findings ~query ~limit () in
    `Assoc [
      ("ok", `Bool true);
      ("count", `Int (List.length findings));
      ("findings", `List (List.map Autoresearch_knowledge.finding_to_yojson findings));
    ]

(** Dispatch an autoresearch tool call (standard MCP pattern). *)
let dispatch (ctx : context) ~name ~args : tool_result option =
  match name with
  | "masc_autoresearch_start" -> Some (wrap_result (handle_start ctx args))
  | "masc_autoresearch_status" -> Some (wrap_result (handle_status ctx args))
  | "masc_autoresearch_stop" -> Some (wrap_result (handle_stop ctx args))
  | "masc_autoresearch_inject" -> Some (wrap_result (handle_inject ctx args))
  | "masc_autoresearch_cycle" -> Some (wrap_result (Tool_autoresearch_cycle.handle_cycle ctx args))
  | _ -> None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let _tool_spec_system_internal = [ "masc_autoresearch_status" ]

let tool_required_permission = function
  | "masc_autoresearch_status" ->
      Some Types.CanReadState
  | "masc_autoresearch_start" | "masc_autoresearch_cycle"
  | "masc_autoresearch_inject" | "masc_autoresearch_stop" ->
      Some Types.CanAdmin
  | _ -> None

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      let is_system = List.mem s.name _tool_spec_system_internal in
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_autoresearch
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~visibility:(if is_system then Tool_catalog.Hidden else Tool_catalog.Default)
           ~allow_direct_call_when_hidden:is_system
           ?required_permission:(tool_required_permission s.name)
           ()))
    schemas
