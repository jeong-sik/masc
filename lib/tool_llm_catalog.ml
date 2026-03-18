[@@@warning "-32-33-69"]
(** Tool_llm_catalog — LLM endpoint discovery and capacity management.

    Provides agents with visibility into available LLM infrastructure:
    - list: enumerate configured endpoints and loaded models
    - status: current slot utilization and capacity
    - recommend: pick best endpoint for a given task type

    @since 2.95.0 *)

open Types

(* ── Types ───────────────────────────────────────────────── *)

type result = bool * string

let json_error message =
  Yojson.Safe.to_string
    (`Assoc [ ("status", `String "error"); ("message", `String message) ])

let json_ok fields =
  Yojson.Safe.to_string (`Assoc (("status", `String "ok") :: fields))

let int_opt_to_json = function Some v -> `Int v | None -> `Null
let string_opt_to_json = function Some v -> `String v | None -> `Null

(* ── Env config ──────────────────────────────────────────── *)

let default_endpoint = "http://127.0.0.1:8085"

let endpoints_from_env () =
  match Sys.getenv_opt "LLM_ENDPOINTS" with
  | None | Some "" -> [default_endpoint]
  | Some value ->
    value
    |> String.split_on_char ','
    |> List.map String.trim
    |> List.filter (fun s -> s <> "")

(* ── HTTP probing via curl (consistent with tool_llama) ──── *)

let http_get_json ?(timeout_sec = 5) url =
  let status, body =
    Process_eio.run_argv_with_status ~timeout_sec:10.0
      [ "curl"; "-sS"; "--http1.1"; "--max-time";
        string_of_int (max 1 timeout_sec); url ]
  in
  match status with
  | Unix.WEXITED 0 ->
    (try Ok (Yojson.Safe.from_string body)
     with Yojson.Json_error msg -> Error msg)
  | Unix.WEXITED code ->
    Error (Printf.sprintf "curl exit %d for %s" code url)
  | _ -> Error (Printf.sprintf "curl failed for %s" url)

let http_get_ok ?(timeout_sec = 3) url =
  let status, _ =
    Process_eio.run_argv_with_status ~timeout_sec:5.0
      [ "curl"; "-sS"; "--http1.1"; "--max-time";
        string_of_int (max 1 timeout_sec); url ]
  in
  match status with Unix.WEXITED 0 -> true | _ -> false

(* ── Parsers ─────────────────────────────────────────────── *)

let parse_models json =
  let open Yojson.Safe.Util in
  match member "data" json with
  | `List items ->
    items |> List.filter_map (fun item ->
      match item |> member "id" |> to_string_option with
      | Some id ->
        let owned_by =
          item |> member "owned_by" |> to_string_option
          |> Option.value ~default:"unknown"
        in
        Some (id, owned_by)
      | None -> None)
  | _ -> []

let parse_props json =
  let open Yojson.Safe.Util in
  match member "total_slots" json with
  | `Int total_slots ->
    let dgs = member "default_generation_settings" json in
    let ctx_size = match dgs with
      | `Assoc _ ->
        (match member "n_ctx" dgs with `Int n -> n | _ -> 0)
      | _ -> 0
    in
    let model = match dgs with
      | `Assoc _ ->
        (match member "model" dgs with `String s -> s | _ -> "")
      | _ -> ""
    in
    Some (total_slots, ctx_size, model)
  | _ -> None

let parse_slots json =
  let open Yojson.Safe.Util in
  let items = match json with `List items -> items | _ -> [] in
  if items = [] then None
  else
    let total = List.length items in
    let busy = List.fold_left (fun acc slot ->
      let is_busy =
        (slot |> member "is_processing" |> to_bool_option
         |> Option.value ~default:false)
        || (match slot |> member "state" with
            | `Int n -> n <> 0 | _ -> false)
      in
      if is_busy then acc + 1 else acc
    ) 0 items in
    Some (total, busy, total - busy)

let string_contains_ci ~haystack ~needle =
  let h = String.lowercase_ascii haystack in
  let n = String.lowercase_ascii needle in
  let nlen = String.length n in
  let hlen = String.length h in
  if nlen > hlen then false
  else
    let found = ref false in
    let i = ref 0 in
    while !i <= hlen - nlen && not !found do
      if String.sub h !i nlen = n then found := true;
      incr i
    done;
    !found

(* ── Probe single endpoint ───────────────────────────────── *)

type endpoint_info = {
  url: string;
  healthy: bool;
  model: string option;
  context_size: int option;
  slots_total: int option;
  slots_busy: int option;
  slots_idle: int option;
  supports_reasoning: bool;
  supports_tools: bool;
  supports_streaming: bool;
}

let probe_endpoint url =
  let base = String.trim url in
  let healthy = http_get_ok (base ^ "/health") in
  if not healthy then
    { url = base; healthy = false; model = None; context_size = None;
      slots_total = None; slots_busy = None; slots_idle = None;
      supports_reasoning = false; supports_tools = false;
      supports_streaming = false }
  else
    let models = match http_get_json (base ^ "/v1/models") with
      | Ok json -> parse_models json | Error _ -> [] in
    let props = match http_get_json (base ^ "/props") with
      | Ok json -> parse_props json | Error _ -> None in
    let slots = match http_get_json (base ^ "/slots") with
      | Ok json -> parse_slots json | Error _ -> None in
    let model_id = match models with (id, _) :: _ -> Some id | [] -> None in
    let has_qwen = List.exists (fun (id, _) ->
      string_contains_ci ~haystack:id ~needle:"qwen") models in
    { url = base;
      healthy = true;
      model = (match props with Some (_, _, m) when m <> "" -> Some m
                               | _ -> model_id);
      context_size = (match props with Some (_, ctx, _) when ctx > 0 -> Some ctx
                                      | _ -> None);
      slots_total = (match slots with Some (t, _, _) -> Some t
                                     | None -> Option.map (fun (t, _, _) -> t) props);
      slots_busy = (match slots with Some (_, b, _) -> Some b | None -> None);
      slots_idle = (match slots with Some (_, _, i) -> Some i | None -> None);
      supports_reasoning = has_qwen;
      supports_tools = true;
      supports_streaming = true;
    }

let endpoint_to_json (e : endpoint_info) =
  `Assoc [
    ("url", `String e.url);
    ("healthy", `Bool e.healthy);
    ("model", string_opt_to_json e.model);
    ("context_size", int_opt_to_json e.context_size);
    ("slots", `Assoc [
      ("total", int_opt_to_json e.slots_total);
      ("busy", int_opt_to_json e.slots_busy);
      ("idle", int_opt_to_json e.slots_idle);
    ]);
    ("capabilities", `Assoc [
      ("reasoning", `Bool e.supports_reasoning);
      ("tools", `Bool e.supports_tools);
      ("streaming", `Bool e.supports_streaming);
    ]);
  ]

(* ── Discovery cache (Eio.Mutex protected) ───────────────── *)

let cached_endpoints : endpoint_info list ref = ref []
let cache_updated_at : float ref = ref 0.0
let cache_ttl = 30.0

let refresh_cache () =
  let endpoints = endpoints_from_env () in
  let results = List.map probe_endpoint endpoints in
  cached_endpoints := results;
  cache_updated_at := Time_compat.now ()

let get_cached_or_refresh () =
  let now = Time_compat.now () in
  if now -. !cache_updated_at > cache_ttl || !cached_endpoints = [] then
    refresh_cache ();
  !cached_endpoints

(* ── Handlers ────────────────────────────────────────────── *)

let handle_list _ctx _args : result =
  let endpoints = get_cached_or_refresh () in
  (true, json_ok [
    ("result", `Assoc [
      ("endpoints", `List (List.map endpoint_to_json endpoints));
      ("count", `Int (List.length endpoints));
    ]);
  ])

let handle_status _ctx _args : result =
  let endpoints = get_cached_or_refresh () in
  let total_cap = List.fold_left (fun acc (e : endpoint_info) ->
    acc + Option.value ~default:0 e.slots_total) 0 endpoints in
  let available = List.fold_left (fun acc (e : endpoint_info) ->
    acc + Option.value ~default:0 e.slots_idle) 0 endpoints in
  let active = List.fold_left (fun acc (e : endpoint_info) ->
    acc + Option.value ~default:0 e.slots_busy) 0 endpoints in
  let permits_available = Llm_client.llm_semaphore_available () in
  let permits_in_use = Llm_client.llm_permits_in_use () in
  (true, json_ok [
    ("result", `Assoc [
      ("endpoints", `List (List.map endpoint_to_json endpoints));
      ("summary", `Assoc [
        ("total_capacity", `Int total_cap);
        ("available_capacity", `Int available);
        ("active_requests", `Int active);
        ("masc_permits_available", `Int permits_available);
        ("masc_permits_in_use", `Int permits_in_use);
        ("masc_max_concurrent_llm", `Int Llm_client.max_concurrent_llm);
      ]);
      ("cached_at", `Float !cache_updated_at);
    ]);
  ])

let handle_recommend _ctx args : result =
  let endpoints = get_cached_or_refresh () in
  let task_type =
    args |> Yojson.Safe.Util.member "task_type"
    |> Yojson.Safe.Util.to_string_option
  in
  let needs_reasoning = match task_type with
    | Some "reasoning" | Some "analysis" | Some "planning" -> true
    | _ -> false
  in
  let healthy = List.filter (fun (e : endpoint_info) -> e.healthy) endpoints in
  let with_idle = List.filter (fun (e : endpoint_info) ->
    match e.slots_idle with Some n -> n > 0 | None -> true) healthy in
  let candidates = if with_idle <> [] then with_idle else healthy in
  let scored = List.map (fun (e : endpoint_info) ->
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
        ("endpoint_detail", endpoint_to_json best);
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
