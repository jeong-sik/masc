(** Tool_model_catalog — MCP tool layer over OAS Discovery (via {!Discovery_cache}).

    All probing logic is in OAS Provider Discovery.
    This module provides the MCP tool interface for agents.

    @since 2.113.0 *)

open Types
module D = Discovery_cache

(* ── Types ───────────────────────────────────────────────── *)

type result = bool * string

let json_error message =
  Yojson.Safe.to_string
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])

let json_ok fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

let string_opt_to_json = Json_util.string_opt_to_json

(* ── Handlers ────────────────────────────────────────────── *)

let handle_list _ctx _args : result =
  let endpoints = D.get_cached_or_refresh () in
  (true, json_ok [
    ("result", `Assoc [
      ("endpoints", `List (List.map D.endpoint_to_json endpoints));
      ("count", `Int (List.length endpoints));
    ]);
  ])

let handle_status _ctx _args : result =
  let endpoints = D.get_cached_or_refresh () in
  let summary = D.summary_to_json endpoints in
  let permits_available = Inference_utils.model_permits_available () in
  let permits_in_use = Inference_utils.model_permits_in_use () in
  (true, json_ok [
    ("result", `Assoc [
      ("endpoints", `List (List.map D.endpoint_to_json endpoints));
      ("summary", summary);
      ("cascade_metrics", Oas_worker.cascade_metrics_json ());
      ("masc_permits", `Assoc [
        ("available", `Int permits_available);
        ("in_use", `Int permits_in_use);
        ("max_concurrent", `Int Inference_utils.max_concurrent_models);
      ]);
      ("cache_age_seconds", `Float (D.cache_age_seconds ()));
    ]);
  ])

let handle_recommend _ctx args : result =
  let endpoints = D.get_cached_or_refresh () in
  let task_type =
    args |> Yojson.Safe.Util.member "task_type"
    |> Yojson.Safe.Util.to_string_option
  in
  let needs_reasoning = match task_type with
    | Some "reasoning" | Some "analysis" | Some "planning" -> true
    | _ -> false
  in
  let healthy = List.filter (fun (e : D.endpoint_info) -> e.healthy) endpoints in
  let with_idle = List.filter (fun (e : D.endpoint_info) ->
    match e.slots with Some s -> s.idle > 0 | None -> true) healthy in
  let candidates = if with_idle <> [] then with_idle else healthy in
  let scored = List.map (fun (e : D.endpoint_info) ->
    let idle = match e.slots with Some s -> s.idle | None -> 0 in
    let reasoning_bonus =
      if needs_reasoning && e.capabilities.supports_reasoning then 10 else 0
    in
    (e, idle + reasoning_bonus)
  ) candidates in
  let sorted = List.sort (fun (_, a) (_, b) -> compare b a) scored in
  match sorted with
  | (best, _) :: _ ->
    let reason =
      let idle = match best.slots with Some s -> s.idle | None -> 0 in
      match idle, needs_reasoning with
      | n, true when n > 0 && best.capabilities.supports_reasoning ->
        Printf.sprintf "%d idle slot(s), reasoning supported" n
      | n, _ when n > 0 ->
        Printf.sprintf "%d idle slot(s) available" n
      | _ -> "best available endpoint"
    in
    let model_id = match best.models with
      | m :: _ -> Some m.id | [] -> None
    in
    (true, json_ok [
      ("result", `Assoc [
        ("recommended_endpoint", `String best.url);
        ("model", string_opt_to_json model_id);
        ("reason", `String reason);
        ("endpoint_detail", D.endpoint_to_json best);
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
  | "masc_model_catalog" ->
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
  { name = "masc_model_catalog";
    description =
      "Query MODEL provider infrastructure status and get endpoint recommendations. \
       Actions: 'list' (enumerate endpoints), 'status' (slot utilization + \
       MASC permit state + cascade runtime metrics), 'recommend' (pick best endpoint for task_type: \
       reasoning|analysis|planning|generation|general). Uses OAS Discovery \
       to probe OpenAI-compatible endpoints.";
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

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_model_catalog
           ~input_schema:s.input_schema
           ()))
    schemas
