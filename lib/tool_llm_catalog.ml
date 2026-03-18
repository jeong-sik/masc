[@@@warning "-32-33-69"]
(** Tool_llm_catalog — LLM endpoint discovery and capacity management.

    Thin MCP tool layer over {!Llm_discovery_cache}.
    Provides agents with visibility into available LLM infrastructure:
    - list: enumerate configured endpoints and loaded models
    - status: current slot utilization and capacity
    - recommend: pick best endpoint for a given task type

    @since 2.113.0 *)

open Types

(* ── Types ───────────────────────────────────────────────── *)

type result = bool * string

let json_error message =
  Yojson.Safe.to_string
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])

let json_ok fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

let string_opt_to_json = function Some v -> `String v | None -> `Null

(* ── Handlers ────────────────────────────────────────────── *)

let handle_list _ctx _args : result =
  let endpoints = Llm_discovery_cache.get_cached_or_refresh () in
  (true, json_ok [
    ("result", `Assoc [
      ("endpoints", `List (List.map Llm_discovery_cache.endpoint_to_json endpoints));
      ("count", `Int (List.length endpoints));
    ]);
  ])

let handle_status _ctx _args : result =
  let endpoints = Llm_discovery_cache.get_cached_or_refresh () in
  let total_cap = List.fold_left (fun acc (e : Llm_discovery_cache.endpoint_info) ->
    acc + Option.value ~default:0 e.slots_total) 0 endpoints in
  let available = List.fold_left (fun acc (e : Llm_discovery_cache.endpoint_info) ->
    acc + Option.value ~default:0 e.slots_idle) 0 endpoints in
  let active = List.fold_left (fun acc (e : Llm_discovery_cache.endpoint_info) ->
    acc + Option.value ~default:0 e.slots_busy) 0 endpoints in
  let permits_available = Llm_client.llm_semaphore_available () in
  let permits_in_use = Llm_client.llm_permits_in_use () in
  (true, json_ok [
    ("result", `Assoc [
      ("endpoints", `List (List.map Llm_discovery_cache.endpoint_to_json endpoints));
      ("summary", `Assoc [
        ("total_capacity", `Int total_cap);
        ("available_capacity", `Int available);
        ("active_requests", `Int active);
        ("masc_permits_available", `Int permits_available);
        ("masc_permits_in_use", `Int permits_in_use);
        ("masc_max_concurrent_llm", `Int Llm_client.max_concurrent_llm);
      ]);
      ("cache_age_seconds", `Float (Llm_discovery_cache.cache_age_seconds ()));
    ]);
  ])

let handle_recommend _ctx args : result =
  let endpoints = Llm_discovery_cache.get_cached_or_refresh () in
  let task_type =
    args |> Yojson.Safe.Util.member "task_type"
    |> Yojson.Safe.Util.to_string_option
  in
  let needs_reasoning = match task_type with
    | Some "reasoning" | Some "analysis" | Some "planning" -> true
    | _ -> false
  in
  let healthy = List.filter (fun (e : Llm_discovery_cache.endpoint_info) ->
    e.healthy) endpoints in
  let with_idle = List.filter (fun (e : Llm_discovery_cache.endpoint_info) ->
    match e.slots_idle with Some n -> n > 0 | None -> true) healthy in
  let candidates = if with_idle <> [] then with_idle else healthy in
  let scored = List.map (fun (e : Llm_discovery_cache.endpoint_info) ->
    let idle_score = Option.value ~default:0 e.slots_idle in
    let reasoning_bonus = if needs_reasoning && e.supports_reasoning then 10 else 0 in
    (e, idle_score + reasoning_bonus)
  ) candidates in
  let sorted = List.sort (fun (_, a) (_, b) -> compare b a) scored in
  match sorted with
  | (best, _score) :: _ ->
    let reason =
      match best.slots_idle, needs_reasoning with
      | Some n, true when n > 0 && best.supports_reasoning ->
        Printf.sprintf "%d idle slot(s), reasoning supported" n
      | Some n, _ when n > 0 ->
        Printf.sprintf "%d idle slot(s) available" n
      | _ -> "best available endpoint"
    in
    (true, json_ok [
      ("result", `Assoc [
        ("recommended_endpoint", `String best.url);
        ("model", string_opt_to_json best.model);
        ("reason", `String reason);
        ("endpoint_detail", Llm_discovery_cache.endpoint_to_json best);
      ]);
    ])
  | [] ->
    (true, json_ok [
      ("result", `Assoc [
        ("recommended_endpoint", `Null);
        ("model", `Null);
        ("reason", `String "no healthy endpoints available");
      ]);
    ])

(* ── Dispatch ────────────────────────────────────────────── *)

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_llm_catalog" ->
    let action =
      args |> Yojson.Safe.Util.member "action"
      |> Yojson.Safe.Util.to_string_option
      |> Option.value ~default:"status"
    in
    (match action with
     | "list" -> Some (handle_list ctx args)
     | "status" -> Some (handle_status ctx args)
     | "recommend" -> Some (handle_recommend ctx args)
     | other -> Some (false, json_error (Printf.sprintf "unknown action: %s" other)))
  | _ -> None

(* ── Schemas ─────────────────────────────────────────────── *)

let schemas : tool_schema list = [
  { name = "masc_llm_catalog";
    description =
      "Query local LLM infrastructure status and get endpoint recommendations. \
       Actions: 'list' (enumerate endpoints), 'status' (slot utilization + \
       MASC permit state), 'recommend' (pick best endpoint for task_type: \
       reasoning|analysis|planning|generation|general). Use before spawning \
       local LLM workers to check available capacity.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "list"; `String "status"; `String "recommend"]);
          ("description", `String "list: endpoints and models. status: slot/capacity detail. recommend: best endpoint for task.");
        ]);
        ("task_type", `Assoc [
          ("type", `String "string");
          ("description", `String "For recommend action: reasoning, analysis, planning, generation, general");
        ]);
      ]);
    ];
  };
]
