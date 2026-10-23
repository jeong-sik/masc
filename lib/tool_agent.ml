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
   A failure is [Tool_args.error_result_typed], which takes the class from
   the error code.
*)

let json_ok ~tool_name ~start_time (json : Yojson.Safe.t) : Tool_result.result =
  Tool_result.make_ok ~tool_name ~start_time ~data:json ()

let ( let* ) = Result.bind

let metric_read_failure ~tool_name ~start_time error =
  let code, message =
    match error with
    | Metrics_store_eio.Invalid_agent_id _ | Invalid_window _ ->
        Validation_error, "Metric agent_name must be an exact path component and days must be positive."
    | Source_unavailable _ | Invalid_record _ ->
        Log.Metrics.error "%s" (Metrics_store_eio.read_error_to_string error);
        Internal_error, "Metric source could not be read completely."
  in
  error_result_typed ~tool_name ~start_time ~code message

(** Defaults apply to omitted query fields only, never malformed values. *)
let metric_query args =
  match args with
  | `Assoc fields ->
      let* agent = match List.assoc_opt "agent_name" fields with
        | None -> Ok None
        | Some (`String name) when not (String.equal name "") -> Ok (Some name)
        | Some _ -> Error "agent_name must be a nonempty exact name"
      in
      let* days = match List.assoc_opt "days" fields with
        | None -> Ok 7
        | Some (`Int days) when days > 0 -> Ok days
        | Some _ -> Error "days must be a positive integer"
      in
      Ok (agent, days)
  | _ -> Error "metric arguments must be an object"

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

(** Handle masc_get_metrics. No-data and failed source reads remain distinct. *)
let handle_get_metrics ?(tool_name = Tool_schemas_agent.tool_name Get_metrics) ~start_time ctx args
  : Tool_result.result =
  match metric_query args with
  | Error message -> error_result_typed ~tool_name ~start_time ~code:Validation_error message
  | Ok (None, _) ->
      error_result_typed ~tool_name ~start_time ~code:Validation_error "agent_name is required"
  | Ok (Some target, days) ->
      (match Metrics_store_eio.calculate_agent_metrics ctx.config ~agent_id:target ~days with
       | Error error -> metric_read_failure ~tool_name ~start_time error
       | Ok (Some metrics) ->
           json_ok ~tool_name ~start_time (Metrics_store_eio.agent_metrics_to_yojson metrics)
       | Ok None ->
           error_result_typed ~tool_name ~start_time ~code:Not_found
             (Tool_guidance.to_string (Tool_guidance.No_metrics_found_for_agent { agent = target })))

(** Calculate min avg time from metrics list *)
let min_avg_time metrics_list =
  metrics_list
  |> List.filter_map (fun (_, metrics) ->
      Option.map (fun m -> m.Metrics_store_eio.avg_completion_time_s) metrics)
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

(** Handle masc_agent_fitness. Missing observations remain in the named pool
    with null metrics/components; they never contribute fabricated zero scores. *)
let handle_agent_fitness ?(tool_name = Tool_schemas_agent.tool_name Agent_fitness) ~start_time ctx args
  : Tool_result.result =
  let read () =
    let* agent_opt, days =
      metric_query args
      |> Result.map_error (fun message ->
          error_result_typed ~tool_name ~start_time ~code:Validation_error message)
    in
    let* agents =
      match agent_opt with
      | Some name -> Ok [name]
      | None ->
          let* metric_agents =
            Metrics_store_eio.get_all_agents ctx.config
            |> Result.map_error (metric_read_failure ~tool_name ~start_time)
          in
          let* workspace_agents =
            try Ok (Workspace.get_agents_raw ctx.config) with
            | (Unix.Unix_error _ | Sys_error _ | Eio.Io _) as error ->
                Log.Metrics.error "workspace agent listing failed: %s" (Printexc.to_string error);
                Error (error_result_typed ~tool_name ~start_time ~code:Internal_error
                  "Workspace agent listing could not be read.")
          in
          let names = List.map (fun (agent : Masc_domain.agent) -> agent.name) workspace_agents in
          Ok (List.sort_uniq String.compare (metric_agents @ names))
    in
    let rec read_metrics acc = function
      | [] -> Ok (List.rev acc)
      | agent_id :: rest ->
          let* metrics =
            Metrics_store_eio.calculate_agent_metrics ctx.config ~agent_id ~days
            |> Result.map_error (metric_read_failure ~tool_name ~start_time)
          in
          read_metrics ((agent_id, metrics) :: acc) rest
    in
    let* metrics_list = read_metrics [] agents in
    let min_avg = min_avg_time metrics_list in
    let agents_json = List.map (fun (agent_id, observation) ->
      let components, metrics = match observation with
        | None -> `Null, `Null
        | Some metrics ->
            let completion, reliability, speed, handoff = components_for ~min_avg metrics in
            `Assoc [ "completion", `Float completion; "reliability", `Float reliability;
                     "speed", `Float speed; "handoff", `Float handoff ],
            Metrics_store_eio.agent_metrics_to_yojson metrics
      in
      `Assoc [ "agent_id", `String agent_id; "components", components; "metrics", metrics ]
    ) metrics_list in
    Ok (`Assoc [
      "count", `Int (List.length agents_json);
      "agents", `List agents_json;
    ])
  in
  match read () with
  | Error result -> result
  | Ok json -> json_ok ~tool_name ~start_time json

(** Handle masc_agent_card *)
let handle_agent_card ?(tool_name = Tool_schemas_agent.tool_name Agent_card) ~start_time ctx args

  : Tool_result.result
  =
  let action_raw = get_string args "action" "get" in
  match agent_card_action_of_string action_raw with
  | None ->
      error_result_typed
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

(** Dispatch handler. The wire name is parsed once and the operations are
    matched, so an operation added to [Tool_schemas_agent] is a compile error
    here. [None] means the name is not this surface's. *)
let dispatch ctx ~name ~args : Tool_result.result option =
  let start = Tool_timing.start () in
  match Tool_schemas_agent.operation_of_tool_name name with
  | None -> None
  | Some Tool_schemas_agent.Get_metrics ->
      Some (handle_get_metrics ~tool_name:name ~start_time:start ctx args)
  | Some Tool_schemas_agent.Agent_fitness ->
      Some (handle_agent_fitness ~tool_name:name ~start_time:start ctx args)
  | Some Tool_schemas_agent.Agent_card ->
      Some (handle_agent_card ~tool_name:name ~start_time:start ctx args)

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let is_read_only = function
  | Tool_schemas_agent.Agent_card -> true
  | Tool_schemas_agent.Agent_fitness | Tool_schemas_agent.Get_metrics -> false

(* Registration walks the same list [dispatch] matches, so this surface cannot
   advertise a name it does not route. *)
let () =
  Tool_schemas_agent.operations
  |> List.iter (fun operation ->
       let schema = Tool_schemas_agent.schema operation in
       Tool_spec.register
         (Tool_spec.create
            ~name:(Tool_schemas_agent.tool_name operation)
            ~description:schema.description
            ~module_tag:Tool_dispatch.Mod_agent
            ~input_schema:schema.input_schema
            ~handler_binding:Tag_dispatch
            ~is_read_only:(is_read_only operation)
            ()))
