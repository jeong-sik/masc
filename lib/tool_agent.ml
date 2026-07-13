module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Tool_agent - Agent management, metrics, and capability discovery handlers *)

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
   [result_to_response] : [Workspace.update_agent_r] Ok/Error
                  projection.  Error is classified
                  [Workflow_rejection] until [Masc_domain] grows
                  a typed failure_class per error variant — at
                  that point assignment can move to the domain
                  layer. *)

let json_ok ~tool_name ~start_time (json : Yojson.Safe.t) : Tool_result.result =
  Tool_result.make_ok ~tool_name ~start_time ~data:json ()

let text_ok ~tool_name ~start_time body : Tool_result.result =
  Tool_result.ok ~tool_name ~start_time body

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

let workflow_err_plain ~tool_name ~start_time msg : Tool_result.result =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    msg

let result_to_response ~tool_name ~start_time = function
  | Ok msg -> text_ok ~tool_name ~start_time msg
  | Error e ->
      workflow_err_plain ~tool_name ~start_time
        (Masc_domain.masc_error_to_string e)

let dedupe_keep_order values =
  let seen = Hashtbl.create (List.length values) in
  List.filter
    (fun value ->
      if String.equal value "" || Hashtbl.mem seen value
      then false
      else (
        Hashtbl.replace seen value ();
        true))
    values

let find_first_some f values =
  let rec loop = function
    | [] -> None
    | value :: rest -> (
        match f value with
        | Some _ as result -> result
        | None -> loop rest)
  in
  loop values

let parse_wrapped_agent_name ~prefix ~suffix raw =
  let plen = String.length prefix in
  let slen = String.length suffix in
  let len = String.length raw in
  if len > plen + slen
     && String.equal (String.sub raw 0 plen) prefix
     && String.equal (String.sub raw (len - slen) slen) suffix
  then Some (String.sub raw plen (len - plen - slen))
  else None

let wrapped_agent_name_candidate raw =
  [ parse_wrapped_agent_name ~prefix:"keeper-" ~suffix:"-agent" raw
  ; parse_wrapped_agent_name ~prefix:"keeper_" ~suffix:"_agent" raw
  ; parse_wrapped_agent_name ~prefix:"keeper-" ~suffix:"_agent" raw
  ; parse_wrapped_agent_name ~prefix:"keeper_" ~suffix:"-agent" raw
  ]
  |> find_first_some (fun candidate -> candidate)

let strip_keeper_prefix raw =
  let prefix = "keeper-" in
  let plen = String.length prefix in
  let len = String.length raw in
  if len > plen && String.equal (String.sub raw 0 plen) prefix
  then Some (String.sub raw plen (len - plen))
  else None

let canonical_keeper_agent_name name = Printf.sprintf "keeper-%s-agent" name

let agent_name_lookup_candidates raw =
  let trimmed = String.trim raw in
  let canonical =
    match wrapped_agent_name_candidate trimmed with
    | Some value -> Some value
    | None -> strip_keeper_prefix trimmed
  in
  let agent_alias =
    match canonical with
    | Some value -> Some (canonical_keeper_agent_name value)
    | None ->
      if String.equal trimmed "" then None else Some (canonical_keeper_agent_name trimmed)
  in
  dedupe_keep_order ([ trimmed ] @ Option.to_list canonical @ Option.to_list agent_alias)

let metrics_json_with_resolution ~requested ~resolved json =
  match json with
  | `Assoc fields when not (String.equal requested resolved) ->
      `Assoc
        (fields
         @ [ "requested_agent_name", `String requested
           ; "resolved_agent_name", `String resolved
           ])
  | _ -> json

let resolve_metrics_for_agent ctx ~requested ~days =
  requested
  |> agent_name_lookup_candidates
  |> find_first_some (fun candidate ->
    match Metrics_store_eio.calculate_agent_metrics ctx.config ~agent_id:candidate ~days with
    | Some metrics -> Some (candidate, metrics)
    | None -> None)

let resolve_existing_metric_agent_id ctx ~requested ~days =
  match resolve_metrics_for_agent ctx ~requested ~days with
  | Some (resolved, _) -> resolved
  | None -> (
      match agent_name_lookup_candidates requested with
      | first :: _ -> first
      | [] -> String.trim requested)

let find_agent_by_identity agents raw =
  raw
  |> agent_name_lookup_candidates
  |> find_first_some (fun candidate ->
    List.find_opt
      (fun (agent : Masc_domain.agent) -> String.equal agent.name candidate)
      agents)

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

(* masc_agents / masc_agent_update handlers removed (2026-06-09): both read/
   wrote the disk-backed .masc/agents/ registry whose producer
   (Workspace_eio.register_agent) had zero call sites. Live agent status is
   served by the `who` resource (Session.get_agent_statuses). *)

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
    | Some (resolved, metrics) ->
        json_ok ~tool_name ~start_time
          (Metrics_store_eio.agent_metrics_to_yojson metrics
           |> metrics_json_with_resolution ~requested:target ~resolved)
    | None ->
        workflow_err_envelope ~tool_name ~start_time ~code:Not_found
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
  |> List.filter (fun t -> Stdlib.Float.compare t 0.0 > 0)
  |> List.fold_left (fun acc t -> if Stdlib.Float.compare acc 0.0 = 0 || Stdlib.Float.compare t acc < 0 then t else acc) 0.0

(** Fitness scoring weights.

    Rationale for default values:
    - completion (0.35): Task completion is the primary signal of agent utility.
      An agent that starts but never finishes is worse than a slow finisher.
    - reliability (0.25): Low error rate is the second priority.
      Agents that crash or produce errors create cascading failures in multi-agent workflows.
    - speed (0.15): Faster completion is desirable but secondary to correctness.
      Speed is normalized relative to the fastest agent in the pool to avoid
      penalizing agents working on inherently longer tasks.
    - handoff (0.10): Successful handoffs indicate cooperative capability.
      Reduced from 0.15 to accommodate the Thompson signal.
    - thompson (0.15): Beta distribution expected value from Thompson Sampling.
      Reflects accumulated vote feedback (up/down votes, quality signals,
      guard penalties). Bridges selection-time exploration data into fitness
      scoring, so agents with strong Thompson priors get a measurable fitness
      boost. Alpha/(alpha+beta) is the posterior mean — a Bayesian point
      estimate of agent quality that converges as evidence accumulates.

    Weights sum to 1.0: 0.35 + 0.25 + 0.15 + 0.10 + 0.15 = 1.0.

    These weights are configurable via [fitness_weights]. The defaults were chosen
    to prioritize "finishes correctly" over "finishes fast" based on observed MASC
    usage patterns where incomplete tasks cause more rework than slow tasks.

    TODO: Validate empirically — correlate ranking snapshots with later task
    success rate to determine if the current weighting produces better team
    compositions.  This read path must not update Thompson alpha/beta directly; real
    task outcome feedback flows through [Workspace_hooks.record_thompson_result_fn]. *)
type fitness_weights = {
  w_completion : float;
  w_reliability : float;
  w_speed : float;
  w_handoff : float;
  w_thompson : float;
}

let default_fitness_weights : fitness_weights = {
  w_completion = 0.35;
  w_reliability = 0.25;
  w_speed = 0.15;
  w_handoff = 0.10;
  w_thompson = 0.15;
}

(** Thompson Sampling confidence: Beta distribution expected value.

    alpha/(alpha+beta) is the posterior mean of the Beta distribution,
    which represents the Bayesian point estimate of agent quality based
    on accumulated vote feedback. Returns 0.0 for agents with no
    Thompson stats (no prior selection history). *)
let thompson_confidence agent_id =
  let s = Thompson_sampling.get_stats agent_id in
  let alpha = Float.max 0.0 s.Thompson_sampling.alpha in
  let beta = Float.max 0.0 s.Thompson_sampling.beta in
  let sum = alpha +. beta in
  if Float.compare sum 0.0 = 0 then 0.0
  else alpha /. sum

(** Score function for fitness calculation.
    @param weights Optional custom weights (defaults to [default_fitness_weights])
    @param agent_id Agent name for Thompson Sampling lookup *)
let score_for ?(weights = default_fitness_weights) ~min_avg ~agent_id metrics =
  let has_data = metrics.Metrics_store_eio.total_tasks > 0 in
  let completion = metrics.Metrics_store_eio.task_completion_rate in
  let reliability = if has_data then 1.0 -. metrics.Metrics_store_eio.error_rate else 0.0 in
  let handoff = if has_data then metrics.Metrics_store_eio.handoff_success_rate else 0.0 in
  let speed =
    if has_data && Stdlib.Float.compare metrics.Metrics_store_eio.avg_completion_time_s 0.0 > 0 && Stdlib.Float.compare min_avg 0.0 > 0 then
      Stdlib.Float.min 1.0 (min_avg /. metrics.Metrics_store_eio.avg_completion_time_s)
    else 0.0
  in
  let thompson = thompson_confidence agent_id in
  let score =
    (weights.w_completion *. completion)
    +. (weights.w_reliability *. reliability)
    +. (weights.w_speed *. speed)
    +. (weights.w_handoff *. handoff)
    +. (weights.w_thompson *. thompson)
  in
  (score, completion, reliability, speed, handoff, thompson)

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
        let (score, completion, reliability, speed, handoff, thompson) = score_for ~min_avg ~agent_id metrics in
        let ts = Thompson_sampling.get_stats agent_id in
        `Assoc [
          ("agent_id", `String agent_id);
          ("fitness", `Float score);
          ("components", `Assoc [
            ("completion", `Float completion);
            ("reliability", `Float reliability);
            ("speed", `Float speed);
            ("handoff", `Float handoff);
            ("thompson", `Float thompson);
          ]);
          ("thompson_stats", `Assoc [
            ("alpha", `Float ts.Thompson_sampling.alpha);
            ("beta", `Float ts.Thompson_sampling.beta);
            ("selections", `Int ts.Thompson_sampling.selections);
            ("total_votes_up", `Int ts.Thompson_sampling.total_votes_up);
            ("total_votes_down", `Int ts.Thompson_sampling.total_votes_down);
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
      workflow_err_envelope ~tool_name ~start_time ~code:Validation_error
        (Printf.sprintf "invalid action %S; expected one of: %s" action_raw
           (String.concat ", " valid_agent_card_action_strings))
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
          ( "capabilities",
            `Assoc [
              ("workspace", `Bool true);
              ("task_backlog", `Bool true);
              ("keeper_runtime", `Bool true);
              ("dashboard", `Bool true);
            ] );
          ( "tools",
            `List
              (List.map
                 (fun name -> `String name)
                 [
                   "masc_status";
                   "masc_tasks";
                   "masc_transition";
                   "masc_dashboard";
                   "masc_tool_help";
                 ]) );
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
