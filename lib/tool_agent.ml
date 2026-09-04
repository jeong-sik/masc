(** Tool_agent - Agent metrics, fitness, and card handlers. *)

open Tool_args

type context = {
  config: Workspace.config;
  agent_name: string;
}

(* RFC-0189 PR-1b.14 — typed result helpers.

   [json_ok]    : Yojson.Safe.t passes as [~data:json] first-class
                  (drops the [Yojson.Safe.to_string] round-trip).
   [text_ok]    : opaque text remains [`String body].
   [workflow_err_envelope] : error wrapped through
                  [Tool_args.error_response_typed ~code msg].  Both
                  call sites (Not_found in get_metrics,
                  Validation_error in agent_card) are caller-input
                  rejections.
*)

let json_ok ~tool_name ~start_time (json : Yojson.Safe.t) : Tool_result.result =
  Tool_result.make_ok ~tool_name ~start_time ~data:json ()

let workflow_err_envelope ~tool_name ~start_time ~code msg : Tool_result.result =
  let data =
    Tool_args.error_assoc
      [ "error_code", `String (Tool_args.error_code_to_string code)
      ; "message", `String msg
      ]
  in
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    ~data
    (Yojson.Safe.to_string data)

(* RFC-0393: an agent is looked up under exactly the name the caller
   supplied. The wrapped [keeper-<name>-agent] spellings and the
   candidate fan-out that accepted them are gone — the relationship
   between a keeper and its agent-plane row is data, not an encoding
   recoverable from the string. *)
let resolve_metrics_for_agent ctx ~requested ~days =
  let agent_id = String.trim requested in
  match Metrics_store_eio.calculate_agent_metrics ctx.config ~agent_id ~days with
  | Some metrics -> Some (agent_id, metrics)
  | None -> None

let resolve_existing_metric_agent_id ctx ~requested ~days =
  match resolve_metrics_for_agent ctx ~requested ~days with
  | Some (resolved, _) -> resolved
  | None -> String.trim requested

let find_agent_by_identity agents raw =
  let name = String.trim raw in
  List.find_opt
    (fun (agent : Masc_domain.agent) -> String.equal agent.name name)
    agents

(* Issue #8501: Variant SSOT for masc_agent_card.action.  Adding a
   new constructor forces compilation in [agent_card_action_to_string]
   AND extends [valid_agent_card_action_strings]; the schema in
   [tool_schemas_agent.ml] mirrors the SSOT (cycle-aware, sync test).
   The previous code used a string match with a wildcard `_ -> Get`
   branch which silently routed any unknown action to Get. *)
type agent_card_action =
  | Agent_card_get
  | Agent_card_refresh

let agent_card_action_to_string = function
  | Agent_card_get -> "get"
  | Agent_card_refresh -> "refresh"

let valid_agent_card_action_strings =
  [ Agent_card_get; Agent_card_refresh ] |> List.map agent_card_action_to_string

let agent_card_action_of_string raw =
  match String.lowercase_ascii (String.trim raw) with
  | "get" -> Some Agent_card_get
  | "refresh" -> Some Agent_card_refresh
  | _ -> None

(** Handle masc_get_metrics *)
let handle_get_metrics ?(tool_name = "masc_get_metrics") ?(start_time = 0.0) ctx args
  : Tool_result.result
  =
  (* Original used [let*! target = get_string_required] which
     wrapped "agent_name is required" as a raw message with no envelope.
     Existing
     test [test_get_metrics_missing_agent_name] parses
     [result.message] as JSON expecting [status = "error"], i.e.
     it was already broken on the raw-message path.  Promote here
     to [workflow_err_envelope ~code:Validation_error] so the
     envelope is present *and* the failure_class is correctly
     [Workflow_rejection]. *)
  let target = get_string args "agent_name" "" in
  if String.equal target "" then
    workflow_err_envelope ~tool_name ~start_time ~code:Validation_error
      "agent_name is required"
  else
    let days = get_int args "days" 7 in
    match resolve_metrics_for_agent ctx ~requested:target ~days with
    | Some (_resolved, metrics) ->
        json_ok ~tool_name ~start_time
          (Metrics_store_eio.agent_metrics_to_yojson metrics)
    | None ->
        workflow_err_envelope
          ~tool_name
          ~start_time
          ~code:Not_found
          (Tool_guidance.to_string
             (Tool_guidance.No_metrics_found_for_agent { agent = target }))

(** Create default metrics for agent *)
let create_default_metrics ~agent_id ~days =
  let now = Time_compat.now () in
  { Metrics_store_eio.agent_id = agent_id;
    period_start = now -. Masc_time_constants.days_to_seconds days;
    period_end = now;
    total_tasks = 0;
    completed_tasks = 0;
    failed_tasks = 0;
    avg_completion_time_s = 0.0;
    task_completion_rate = 0.0;
    error_rate = 0.0;
    handoff_success_rate = 0.0;
    unique_collaborators = [];
  }

(** Get metrics for agent, with default fallback *)
let metrics_for ctx ~days agent_id =
  match Metrics_store_eio.calculate_agent_metrics ctx.config ~agent_id ~days with
  | Some m -> m
  | None -> create_default_metrics ~agent_id ~days

(** Calculate min avg time from metrics list *)
let min_avg_time metrics_list =
  metrics_list
  |> List.map (fun (_, m) -> m.Metrics_store_eio.avg_completion_time_s)
  |> List.filter (fun t -> Stdlib.Float.compare t 0.0 > 0)
  |> List.fold_left (fun acc t -> if Stdlib.Float.compare acc 0.0 = 0 || Stdlib.Float.compare t acc < 0 then t else acc) 0.0

(** Fitness components, each reported as a separate observation.

    - completion: task completion rate as recorded by the metrics store.
    - reliability: [1 - error_rate]; 0.0 when the agent has no recorded tasks.
    - speed: [min_avg / avg_completion_time_s] capped at 1.0, where [min_avg]
      is the fastest average duration in the queried pool; 0.0 when the agent
      has no recorded tasks or no measured duration.
    - handoff: handoff success rate; 0.0 when the agent has no recorded tasks.

    [speed] is pool-relative by construction, so component values are only
    comparable within a single response. *)
let components_for ~min_avg metrics =
  let has_data = metrics.Metrics_store_eio.total_tasks > 0 in
  let completion = metrics.Metrics_store_eio.task_completion_rate in
  let reliability = if has_data then 1.0 -. metrics.Metrics_store_eio.error_rate else 0.0 in
  let handoff = if has_data then metrics.Metrics_store_eio.handoff_success_rate else 0.0 in
  let speed =
    if has_data && Stdlib.Float.compare metrics.Metrics_store_eio.avg_completion_time_s 0.0 > 0 && Stdlib.Float.compare min_avg 0.0 > 0 then
      Stdlib.Float.min 1.0 (min_avg /. metrics.Metrics_store_eio.avg_completion_time_s)
    else 0.0
  in
  (completion, reliability, speed, handoff)

(** Handle masc_agent_fitness *)
let handle_agent_fitness ?(tool_name = "masc_agent_fitness") ?(start_time = 0.0) ctx args
  : Tool_result.result
  =
  let agent_opt = get_string_opt args "agent_name" in
  let days = get_int args "days" 7 in
  let agents =
    match agent_opt with
    | Some a -> [ resolve_existing_metric_agent_id ctx ~requested:a ~days ]
    | None ->
      (* Merge agents from metrics store AND workspace state.
         Without this, agents active on the board but without task metrics
         are invisible to fitness queries (Issue #1861). *)
      let metrics_agents = Metrics_store_eio.get_all_agents ctx.config in
      let workspace_agents =
        try
          Workspace.get_agents_raw ctx.config
          |> List.map (fun (a : Masc_domain.agent) -> a.name)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Misc.warn "workspace agents fallback (metrics_store still used): %s"
            (Stdlib.Printexc.to_string exn);
          []
      in
      List.sort_uniq String.compare (metrics_agents @ workspace_agents)
  in
  if Stdlib.List.length agents = 0 then
    json_ok ~tool_name ~start_time
      (`Assoc [("count", `Int 0); ("agents", `List [])])
  else
    let metrics_list = List.map (fun a -> (a, metrics_for ctx ~days a)) agents in
    let min_avg = min_avg_time metrics_list in

    let agents_json =
      List.map (fun (agent_id, metrics) ->
        let (completion, reliability, speed, handoff) = components_for ~min_avg metrics in
        `Assoc [
          ("agent_id", `String agent_id);
          ("components", `Assoc [
            ("completion", `Float completion);
            ("reliability", `Float reliability);
            ("speed", `Float speed);
            ("handoff", `Float handoff);
          ]);
          ("metrics", Metrics_store_eio.agent_metrics_to_yojson metrics);
        ]
      ) metrics_list
    in
    let json = `Assoc [
      ("count", `Int (List.length agents_json));
      ("agents", `List agents_json);
    ] in
    json_ok ~tool_name ~start_time json

(** Handle masc_agent_card *)
let handle_agent_card ?(tool_name = "masc_agent_card") ?(start_time = 0.0) ctx args
  : Tool_result.result
  =
  let action_raw = get_string args "action" "get" in
  match agent_card_action_of_string action_raw with
  | None ->
      workflow_err_envelope
        ~tool_name
        ~start_time
        ~code:Validation_error
        (Tool_guidance.to_string
           (Tool_guidance.Invalid_agent_card_action
              { action_quoted = Printf.sprintf "%S" action_raw
              ; valid_actions = String.concat ", " valid_agent_card_action_strings
              }))
  | Some action ->
      let agents = Workspace.get_agents_raw ctx.config in
      let target = get_string_opt args "agent_name" in
      let target_agent = Option.bind target (find_agent_by_identity agents) in
      let json =
        `Assoc [
          ("schema", `String "masc.agent_card.v1");
          ("name", `String "MASC");
          ("description", `String "MASC multi-agent workspace MCP server");
          ("action", `String (agent_card_action_to_string action));
          ("requested_by", `String ctx.agent_name);
          ("base_path", `String ctx.config.base_path);
          ("workspace_path", `String ctx.config.workspace_path);
          ("agent_count", `Int (List.length agents));
          ( "agent",
            match target_agent with
            | Some agent -> Masc_domain.agent_to_yojson agent
            | None -> `Null );
        ]
      in
      json_ok ~tool_name ~start_time json

(** Dispatch handler. Returns Some (Tool_result.result) if handled, None otherwise *)
let dispatch ctx ~name ~args : Tool_result.result option =
  let start = Time_compat.now () in
  match name with
  | "masc_get_metrics" ->
      Some (handle_get_metrics ~tool_name:name ~start_time:start ctx args)
  | "masc_agent_fitness" ->
      Some (handle_agent_fitness ~tool_name:name ~start_time:start ctx args)
  | "masc_agent_card" ->
      Some (handle_agent_card ~tool_name:name ~start_time:start ctx args)
  | _ -> None

let schemas = Tool_schemas_agent.schemas

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let tool_spec_read_only =
  [ "masc_agent_card" ]

let () =
  List.iter
    (fun (s : Masc_domain.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_agent
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:(List.mem s.name tool_spec_read_only)
           ()))
    schemas
