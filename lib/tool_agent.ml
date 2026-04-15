(** Tool_agent - Agent management, metrics, and capability discovery handlers *)

open Tool_args

type context = {
  config: Coord.config;
  agent_name: string;
}

(** Helper: result to response *)
let result_to_response = function
  | Ok msg -> (true, msg)
  | Error e -> (false, Types.masc_error_to_string e)

(** Handle masc_agents *)
let handle_agents ctx args =
  let limit = get_int args "limit" 20 |> max 1 |> min 50 in
  let json = Coord.get_agents_status ctx.config in
  let json = match json with
    | `List items -> `List (List.filteri (fun i _ -> i < limit) items)
    | other -> other
  in
  (true, Yojson.Safe.to_string json)

(** Handle masc_register_capabilities *)
let handle_register_capabilities ctx args =
  let capabilities = get_string_list args "capabilities" in
  (true, Coord.register_capabilities ctx.config ~agent_name:ctx.agent_name ~capabilities)

(** Handle masc_agent_update *)
let handle_agent_update ctx args =
  let status = get_string_opt args "status" in
  let capabilities =
    match Yojson.Safe.Util.member "capabilities" args with
    | `Null -> None
    | `List _ -> Some (get_string_list args "capabilities")
    | _ -> None
  in
  result_to_response (Coord.update_agent_r ctx.config ~agent_name:ctx.agent_name ?status ?capabilities ())

(** Handle masc_get_metrics *)
let handle_get_metrics ctx args =
  let ( let*! ) = Tool_args.( let*! ) in
  let*! target = get_string_required args "agent_name" in
  let days = get_int args "days" 7 in
  match Metrics_store_eio.calculate_agent_metrics ctx.config ~agent_id:target ~days with
  | Some metrics ->
      (true, Yojson.Safe.to_string (Metrics_store_eio.agent_metrics_to_yojson metrics))
  | None ->
      error_result_typed ~code:Not_found
        (Printf.sprintf "no metrics found for agent: %s" target)

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
  |> List.filter (fun t -> t > 0.0)
  |> List.fold_left (fun acc t -> if acc = 0.0 || t < acc then t else acc) 0.0

(** Calculate max collaborators from metrics list *)
let max_collabs metrics_list =
  metrics_list
  |> List.map (fun (_, m) -> List.length m.Metrics_store_eio.unique_collaborators)
  |> List.fold_left max 0

(** Fitness scoring weights.

    Rationale for default values:
    - completion (0.35): Task completion is the primary signal of agent utility.
      An agent that starts but never finishes is worse than a slow finisher.
    - reliability (0.25): Low error rate is the second priority.
      Agents that crash or produce errors create cascading failures in multi-agent workflows.
    - speed (0.15): Faster completion is desirable but secondary to correctness.
      Speed is normalized relative to the fastest agent in the pool to avoid
      penalizing agents working on inherently longer tasks.
    - handoff (0.15): Successful handoffs indicate cooperative capability.
      Equal weight to speed because coordination is as valuable as individual performance
      in multi-agent systems.
    - collaboration (0.10): Number of unique collaborators relative to pool max.
      Lowest weight because this is a volume metric, not a quality metric.

    These weights are configurable via [fitness_weights]. The defaults were chosen
    to prioritize "finishes correctly" over "finishes fast" based on observed MASC
    usage patterns where incomplete tasks cause more rework than slow tasks.

    TODO: Validate empirically — track selection outcomes vs task success rate
    to determine if the current weighting produces better team compositions. *)
type fitness_weights = {
  w_completion : float;
  w_reliability : float;
  w_speed : float;
  w_handoff : float;
  w_collaboration : float;
}

let default_fitness_weights : fitness_weights = {
  w_completion = 0.35;
  w_reliability = 0.25;
  w_speed = 0.15;
  w_handoff = 0.15;
  w_collaboration = 0.10;
}

(** Score function for fitness calculation.
    @param weights Optional custom weights (defaults to [default_fitness_weights]) *)
let score_for ?(weights = default_fitness_weights) ~min_avg ~max_collabs metrics =
  let has_data = metrics.Metrics_store_eio.total_tasks > 0 in
  let completion = metrics.Metrics_store_eio.task_completion_rate in
  let reliability = if has_data then 1.0 -. metrics.Metrics_store_eio.error_rate else 0.0 in
  let handoff = if has_data then metrics.Metrics_store_eio.handoff_success_rate else 0.0 in
  let speed =
    if has_data && metrics.Metrics_store_eio.avg_completion_time_s > 0.0 && min_avg > 0.0 then
      min 1.0 (min_avg /. metrics.Metrics_store_eio.avg_completion_time_s)
    else 0.0
  in
  let collab_count = List.length metrics.Metrics_store_eio.unique_collaborators in
  let collaboration =
    if max_collabs = 0 then 0.0
    else float_of_int collab_count /. float_of_int max_collabs
  in
  let score =
    (weights.w_completion *. completion)
    +. (weights.w_reliability *. reliability)
    +. (weights.w_speed *. speed)
    +. (weights.w_handoff *. handoff)
    +. (weights.w_collaboration *. collaboration)
  in
  (score, completion, reliability, speed, handoff, collaboration)

(** Handle masc_agent_fitness *)
let handle_agent_fitness ctx args =
  let agent_opt = get_string_opt args "agent_name" in
  let days = get_int args "days" 7 in
  let agents =
    match agent_opt with
    | Some a -> [a]
    | None ->
      (* Merge agents from metrics store AND room state.
         Without this, agents active on the board but without task metrics
         are invisible to fitness queries (Issue #1861). *)
      let metrics_agents = Metrics_store_eio.get_all_agents ctx.config in
      let room_agents =
        try
          Coord.get_agents_raw ctx.config
          |> List.map (fun (a : Types.agent) -> a.name)
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Misc.warn "room agents fallback (metrics_store still used): %s"
            (Printexc.to_string exn);
          []
      in
      List.sort_uniq String.compare (metrics_agents @ room_agents)
  in
  if agents = [] then
    (true, Yojson.Safe.to_string (`Assoc [("count", `Int 0); ("agents", `List [])]))
  else
    let metrics_list = List.map (fun a -> (a, metrics_for ctx ~days a)) agents in
    let min_avg = min_avg_time metrics_list in
    let max_col = max_collabs metrics_list in
    let agents_json =
      List.map (fun (agent_id, metrics) ->
        let (score, completion, reliability, speed, handoff, collaboration) = score_for ~min_avg ~max_collabs:max_col metrics in
        `Assoc [
          ("agent_id", `String agent_id);
          ("fitness", `Float score);
          ("components", `Assoc [
            ("completion", `Float completion);
            ("reliability", `Float reliability);
            ("speed", `Float speed);
            ("handoff", `Float handoff);
            ("collaboration", `Float collaboration);
          ]);
          ("metrics", Metrics_store_eio.agent_metrics_to_yojson metrics);
        ]
      ) metrics_list
    in
    let json = `Assoc [
      ("count", `Int (List.length agents_json));
      ("agents", `List agents_json);
    ] in
    (true, Yojson.Safe.to_string json)

(** Handle masc_collaboration_graph *)
let handle_collaboration_graph ctx args =
  let format = get_string args "format" "text" in
  let limit = get_int args "limit" 20 |> max 1 |> min 100 in
  let (synapses, agents) = Hebbian_eio.get_graph_data ctx.config in
  if format = "json" then
    let synapses = List.filteri (fun i _ -> i < limit) synapses in
    let json = `Assoc [
      ("agents", `List (List.map (fun a -> `String a) agents));
      ("synapses", `List (List.map Hebbian_eio.synapse_to_json synapses));
    ] in
    (true, Yojson.Safe.to_string json)
  else
    let lines =
      synapses
      |> List.sort (fun a b -> compare b.Hebbian_eio.weight a.Hebbian_eio.weight)
      |> List.filteri (fun i _ -> i < limit)
      |> List.map (fun s ->
          Printf.sprintf "%s → %s (%.2f, success:%d, failure:%d)"
            s.Hebbian_eio.from_agent s.Hebbian_eio.to_agent
            s.Hebbian_eio.weight s.Hebbian_eio.success_count s.Hebbian_eio.failure_count)
    in
    if lines = [] then
      (true, "No collaboration data yet.")
    else
      (true, String.concat "\n" lines)

(** Handle masc_agent_card *)
let handle_agent_card _ctx args =
  let action = get_string args "action" "get" in
  let card = Agent_card.generate_default ~schemas:Config.raw_all_tool_schemas () in
  let json = Agent_card.to_json card in
  let response = match action with
    | "refresh" ->
        `Assoc [
          ("status", `String "refreshed");
          ("card", json);
          ("endpoint", `String "/.well-known/agent.json");
          ("legacy_endpoint", `String "/.well-known/agent-card.json");
        ]
    | _ ->
        `Assoc [
          ("card", json);
          ("endpoint", `String "/.well-known/agent.json");
          ("legacy_endpoint", `String "/.well-known/agent-card.json");
        ]
  in
  (true, Yojson.Safe.to_string response)

(** Dispatch handler. Returns Some (success, result) if handled, None otherwise *)
let dispatch ctx ~name ~args =
  match name with
  | "masc_agents" -> Some (handle_agents ctx args)
  | "masc_register_capabilities" -> Some (handle_register_capabilities ctx args)
  | "masc_agent_update" -> Some (handle_agent_update ctx args)
  | "masc_get_metrics" -> Some (handle_get_metrics ctx args)
  | "masc_agent_fitness" -> Some (handle_agent_fitness ctx args)
  | "masc_collaboration_graph" -> Some (handle_collaboration_graph ctx args)
  | "masc_agent_card" -> Some (handle_agent_card ctx args)
  | _ -> None

let schemas = Tool_schemas_agent.schemas

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let _tool_spec_read_only =
  [ "masc_agents"; "masc_agent_card" ]
let _tool_spec_requires_join = [ "masc_register_capabilities" ]

let tool_required_permission = function
  | "masc_agents" | "masc_agent_card" | "masc_agent_fitness"
  | "masc_collaboration_graph"
  | "masc_get_metrics" ->
      Some Types.CanReadState
  | "masc_register_capabilities" | "masc_agent_update" ->
      Some Types.CanBroadcast
  | _ -> None

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_agent
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:(List.mem s.name _tool_spec_read_only)
           ~is_idempotent:(List.mem s.name _tool_spec_read_only)
           ~requires_join:(List.mem s.name _tool_spec_requires_join)
           ?required_permission:(tool_required_permission s.name)
           ()))
    schemas
