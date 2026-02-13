(** Tool_keeper — MCP-native persistent "keeper" agents.

    Goal: Make long-lived assistants easy to use via MCP without external scripts.

    Design:
    - Event-driven: no autonomous tight loop (avoids burning tokens when idle).
    - Persistent context: stored under .masc/perpetual/<trace_id>/ via Context_manager checkpoints.
    - Automatic succession: when context_ratio crosses threshold, hydrate a successor context
      using Succession DNA and rotate trace_id.
    - Optional presence keepalive: periodically touch Room.heartbeat for the keeper's agent name.

    Tools:
    - masc_keeper_up: create/update keeper + start keepalive
    - masc_keeper_status: inspect keeper meta + current context stats
    - masc_keeper_msg: append message, run one LLM turn, persist, auto-handoff if needed
    - masc_keeper_down: stop keepalive + optionally remove meta/session dirs
    - masc_keeper_list: list all keepers
*)

open Types

type 'a context = {
  config: Room.config;
  sw: Eio.Switch.t;
  clock: 'a Eio.Time.clock;
}

type tool_result = bool * string

(* --------------------------------------------------------------- *)
(* Schemas                                                         *)
(* --------------------------------------------------------------- *)

let schemas : Types.tool_schema list = [
  {
    name = "masc_keeper_up";
    description = "Create or update a persistent keeper agent (event-driven). \
Stores context on disk and keeps presence alive. Auto-handoff is enabled by default.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle (stable). Example: 'lodge-helper'");
        ]);
        ("goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper goal/system purpose (required when creating)");
        ]);
        ("models", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Model cascade (provider:model). Examples: 'claude:opus', 'ollama:glm-4.7-flash', 'glm:glm-4.7', 'openrouter:...'.");
        ]);
        ("verify", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Enable verifier model feedback (default: false for keeper).");
        ]);
        ("presence_keepalive", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, periodically refresh Room.heartbeat for the keeper agent (default: true).");
        ]);
        ("presence_keepalive_sec", `Assoc [
          ("type", `String "integer");
          ("description", `String "Presence keepalive interval seconds (default: 30).");
        ]);
        ("auto_handoff", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, automatically rotate trace_id when context gets large (default: true).");
        ]);
        ("handoff_threshold", `Assoc [
          ("type", `String "number");
          ("description", `String "Context ratio threshold for auto-handoff (default: 0.85).");
        ]);
        ("handoff_cooldown_sec", `Assoc [
          ("type", `String "integer");
          ("description", `String "Minimum seconds between handoffs (default: 300).");
        ]);
        ("context_budget", `Assoc [
          ("type", `String "number");
          ("description", `String "How much compressed context to transfer to successor (0.0-1.0, default: 0.6).");
        ]);
      ]);
      ("required", `List [`String "name"]);
    ];
  };

  {
    name = "masc_keeper_status";
    description = "Get keeper status (meta + current context stats + monitoring tails).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle");
        ]);
        ("tail_turns", `Assoc [
          ("type", `String "integer");
          ("description", `String "How many recent turns to include from keeper metrics (default: 5).");
        ]);
        ("tail_messages", `Assoc [
          ("type", `String "integer");
          ("description", `String "How many recent history messages to include (default: 10).");
        ]);
        ("tail_bytes", `Assoc [
          ("type", `String "integer");
          ("description", `String "How many bytes from the end of files to scan for tails (default: 200000).");
        ]);
      ]);
      ("required", `List [`String "name"]);
    ];
  };

  {
    name = "masc_keeper_msg";
    description = "Send a message to a keeper and get a reply. \
Persists context + checkpoints. Auto-handoff is applied when needed.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle");
        ]);
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "User message");
        ]);
        ("goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: set goal when creating keeper inline");
        ]);
        ("models", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Optional: set models when creating keeper inline");
        ]);
        ("new_goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: replace keeper goal (persisted)");
        ]);
      ]);
      ("required", `List [`String "name"; `String "message"]);
    ];
  };

  {
    name = "masc_keeper_down";
    description = "Stop keeper presence keepalive and optionally remove keeper files.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle");
        ]);
        ("remove_meta", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Delete .masc/perpetual-keepers/<name>.json (default: true).");
        ]);
        ("remove_session", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Delete .masc/perpetual/<trace_id>/ directory (default: false).");
        ]);
      ]);
      ("required", `List [`String "name"]);
    ];
  };

  {
    name = "masc_keeper_list";
    description = "List keepers from .masc/perpetual-keepers.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max keepers to return (default: 50).");
        ]);
      ]);
    ];
  };
]

(* --------------------------------------------------------------- *)
(* Helpers                                                          *)
(* --------------------------------------------------------------- *)

let get_string args key default =
  Safe_ops.json_string ~default key args

let get_string_opt args key =
  match Safe_ops.json_string_opt key args with
  | Some "" -> None
  | other -> other

let get_bool args key default =
  Safe_ops.json_bool ~default key args

let get_bool_opt args key =
  let open Yojson.Safe.Util in
  try
    match args |> member key with
    | `Null -> None
    | j -> Some (to_bool j)
  with Type_error _ -> None

let get_int args key default =
  Safe_ops.json_int ~default key args

let get_float args key default =
  Safe_ops.json_float ~default key args

let get_string_list args key =
  Safe_ops.json_string_list key args

let validate_name name =
  (* Same rule as keeper script: conservative handle chars only. *)
  let re = Str.regexp "^[A-Za-z0-9._-]+$" in
  name <> "" && Str.string_match re name 0

let take n xs =
  let rec go i acc = function
    | [] -> List.rev acc
    | _ when i <= 0 -> List.rev acc
    | x :: rest -> go (i - 1) (x :: acc) rest
  in
  go n [] xs

let mkdir_p path =
  let rec go p =
    if p = "" || p = "/" then ()
    else if Sys.file_exists p then ()
    else begin
      go (Filename.dirname p);
      (try Unix.mkdir p 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
    end
  in
  go path

let keeper_dir config =
  let d = Filename.concat (Room.masc_dir config) "perpetual-keepers" in
  mkdir_p d;
  d

let keeper_meta_path config name =
  Filename.concat (keeper_dir config) (name ^ ".json")

let session_base_dir config =
  (* Keep consistent with Perpetual_loop.default_config. *)
  Filename.concat (Room.masc_dir config) "perpetual"

let keeper_agent_name name =
  (* Make it look like a generated nickname so Room.join uses it as-is. *)
  Printf.sprintf "keeper-%s-agent" name

type keeper_meta = {
  name: string;
  agent_name: string;
  trace_id: string;
  trace_history: string list;
  goal: string;
  models: string list;
  generation: int;
  verify: bool;
  presence_keepalive: bool;
  presence_keepalive_sec: int;
  auto_handoff: bool;
  handoff_threshold: float;
  handoff_cooldown_sec: int;
  context_budget: float;
  last_handoff_ts: float;
  created_at: string;
  updated_at: string;
  total_turns: int;
  total_input_tokens: int;
  total_output_tokens: int;
  total_tokens: int;
  total_cost_usd: float;
  last_turn_ts: float;
  last_model_used: string;
  last_input_tokens: int;
  last_output_tokens: int;
  last_total_tokens: int;
  last_latency_ms: int;
  compaction_count: int;
  last_compaction_ts: float;
  last_compaction_before_tokens: int;
  last_compaction_after_tokens: int;
}

let now_iso () = Types.now_iso ()

let meta_to_json (m : keeper_meta) : Yojson.Safe.t =
  `Assoc [
    ("name", `String m.name);
    ("agent_name", `String m.agent_name);
    ("trace_id", `String m.trace_id);
    ("trace_history", `List (List.map (fun s -> `String s) m.trace_history));
    ("goal", `String m.goal);
    ("models", `List (List.map (fun s -> `String s) m.models));
    ("generation", `Int m.generation);
    ("verify", `Bool m.verify);
    ("presence_keepalive", `Bool m.presence_keepalive);
    ("presence_keepalive_sec", `Int m.presence_keepalive_sec);
    ("auto_handoff", `Bool m.auto_handoff);
    ("handoff_threshold", `Float m.handoff_threshold);
    ("handoff_cooldown_sec", `Int m.handoff_cooldown_sec);
    ("context_budget", `Float m.context_budget);
    ("last_handoff_ts", `Float m.last_handoff_ts);
    ("created_at", `String m.created_at);
    ("updated_at", `String m.updated_at);
    ("total_turns", `Int m.total_turns);
    ("total_input_tokens", `Int m.total_input_tokens);
    ("total_output_tokens", `Int m.total_output_tokens);
    ("total_tokens", `Int m.total_tokens);
    ("total_cost_usd", `Float m.total_cost_usd);
    ("last_turn_ts", `Float m.last_turn_ts);
    ("last_model_used", `String m.last_model_used);
    ("last_input_tokens", `Int m.last_input_tokens);
    ("last_output_tokens", `Int m.last_output_tokens);
    ("last_total_tokens", `Int m.last_total_tokens);
    ("last_latency_ms", `Int m.last_latency_ms);
    ("compaction_count", `Int m.compaction_count);
    ("last_compaction_ts", `Float m.last_compaction_ts);
    ("last_compaction_before_tokens", `Int m.last_compaction_before_tokens);
    ("last_compaction_after_tokens", `Int m.last_compaction_after_tokens);
  ]

let meta_of_json (json : Yojson.Safe.t) : (keeper_meta, string) result =
  try
    let name = Safe_ops.json_string ~default:"" "name" json in
    let agent_name = Safe_ops.json_string ~default:"" "agent_name" json in
    let trace_id = Safe_ops.json_string ~default:"" "trace_id" json in
    let trace_history =
      Safe_ops.json_string_list "trace_history" json |> List.filter validate_name
    in
    let goal = Safe_ops.json_string ~default:"" "goal" json in
    let models = Safe_ops.json_string_list "models" json in
    let generation = Safe_ops.json_int ~default:0 "generation" json in
    let verify = Safe_ops.json_bool ~default:false "verify" json in
    let presence_keepalive = Safe_ops.json_bool ~default:true "presence_keepalive" json in
    let presence_keepalive_sec = Safe_ops.json_int ~default:30 "presence_keepalive_sec" json in
    let auto_handoff = Safe_ops.json_bool ~default:true "auto_handoff" json in
    let handoff_threshold = Safe_ops.json_float ~default:0.85 "handoff_threshold" json in
    let handoff_cooldown_sec = Safe_ops.json_int ~default:300 "handoff_cooldown_sec" json in
    let context_budget = Safe_ops.json_float ~default:0.6 "context_budget" json in
    let last_handoff_ts = Safe_ops.json_float ~default:0.0 "last_handoff_ts" json in
    let created_at = Safe_ops.json_string ~default:"" "created_at" json in
    let updated_at = Safe_ops.json_string ~default:"" "updated_at" json in
    let total_turns = Safe_ops.json_int ~default:0 "total_turns" json in
    let total_input_tokens = Safe_ops.json_int ~default:0 "total_input_tokens" json in
    let total_output_tokens = Safe_ops.json_int ~default:0 "total_output_tokens" json in
    let total_tokens = Safe_ops.json_int ~default:0 "total_tokens" json in
    let total_cost_usd = Safe_ops.json_float ~default:0.0 "total_cost_usd" json in
    let last_turn_ts = Safe_ops.json_float ~default:0.0 "last_turn_ts" json in
    let last_model_used = Safe_ops.json_string ~default:"" "last_model_used" json in
    let last_input_tokens = Safe_ops.json_int ~default:0 "last_input_tokens" json in
    let last_output_tokens = Safe_ops.json_int ~default:0 "last_output_tokens" json in
    let last_total_tokens = Safe_ops.json_int ~default:0 "last_total_tokens" json in
    let last_latency_ms = Safe_ops.json_int ~default:0 "last_latency_ms" json in
    let compaction_count = Safe_ops.json_int ~default:0 "compaction_count" json in
    let last_compaction_ts = Safe_ops.json_float ~default:0.0 "last_compaction_ts" json in
    let last_compaction_before_tokens = Safe_ops.json_int ~default:0 "last_compaction_before_tokens" json in
    let last_compaction_after_tokens = Safe_ops.json_int ~default:0 "last_compaction_after_tokens" json in
    if not (validate_name name) then
      Error "invalid keeper meta (bad name)"
    else if not (validate_name trace_id) then
      Error "invalid keeper meta (bad trace_id)"
    else
      Ok {
        name;
        agent_name = if agent_name = "" then keeper_agent_name name else agent_name;
        trace_id;
        trace_history;
        goal;
        models;
        generation;
        verify;
        presence_keepalive;
        presence_keepalive_sec;
        auto_handoff;
        handoff_threshold;
        handoff_cooldown_sec;
        context_budget;
        last_handoff_ts;
        created_at = if created_at = "" then now_iso () else created_at;
        updated_at = if updated_at = "" then now_iso () else updated_at;
        total_turns;
        total_input_tokens;
        total_output_tokens;
        total_tokens;
        total_cost_usd;
        last_turn_ts;
        last_model_used;
        last_input_tokens;
        last_output_tokens;
        last_total_tokens;
        last_latency_ms;
        compaction_count;
        last_compaction_ts;
        last_compaction_before_tokens;
        last_compaction_after_tokens;
      }
  with exn ->
    Error (Printf.sprintf "meta parse error: %s" (Printexc.to_string exn))

let write_meta config (m : keeper_meta) : (unit, string) result =
  let path = keeper_meta_path config m.name in
  let content = Yojson.Safe.pretty_to_string (meta_to_json m) in
  try
    let oc = open_out path in
    Common.protect ~module_name:"tool_keeper" ~finally_label:"close_out"
      ~finally:(fun () -> close_out_noerr oc)
      (fun () -> output_string oc content);
    Ok ()
  with exn ->
    Error (Printf.sprintf "failed to write meta %s: %s" path (Printexc.to_string exn))

let read_meta config name : (keeper_meta option, string) result =
  let path = keeper_meta_path config name in
  if not (Sys.file_exists path) then Ok None
  else
    match Safe_ops.read_json_file_safe path with
    | Error e -> Error e
    | Ok json ->
      (match meta_of_json json with
       | Ok m -> Ok (Some m)
       | Error e -> Error e)

let model_specs_of_strings (model_strs : string list) : (Llm_client.model_spec list, string) result =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | s :: rest ->
      (match Llm_client.model_spec_of_string s with
       | Ok spec -> go (spec :: acc) rest
       | Error e -> Error (Printf.sprintf "Bad model spec %s: %s" s e))
  in
  go [] model_strs

let ensure_api_keys (models : Llm_client.model_spec list) : (unit, string) result =
  let missing =
    List.filter_map (fun (m : Llm_client.model_spec) ->
      match m.api_key_env with
      | None -> None
      | Some env ->
        let v = Sys.getenv_opt env |> Option.value ~default:"" in
        if v = "" then Some env else None
    ) models
  in
  match missing with
  | [] -> Ok ()
  | xs -> Error (Printf.sprintf "Missing API key env vars: %s" (String.concat ", " xs))

let keeper_metrics_path config name =
  Filename.concat (keeper_dir config) (name ^ ".metrics.jsonl")

let append_jsonl_line path (json : Yojson.Safe.t) =
  let line = Yojson.Safe.to_string json ^ "\n" in
  let fd = Unix.openfile path
    [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND] 0o644 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
    let _ = Unix.write_substring fd line 0 (String.length line) in
    ())

let cost_usd_of_usage (usage : Llm_client.token_usage) (model : Llm_client.model_spec) : float =
  let input_cost = float_of_int usage.input_tokens *. model.cost_per_1k_input /. 1000.0 in
  let output_cost = float_of_int usage.output_tokens *. model.cost_per_1k_output /. 1000.0 in
  input_cost +. output_cost

let model_spec_for_used (specs : Llm_client.model_spec list) (model_used : string) :
  Llm_client.model_spec option =
  let used =
    match String.split_on_char ':' model_used with
    | [base; "latest"] -> base
    | _ -> model_used
  in
  List.find_opt (fun (m : Llm_client.model_spec) ->
    m.model_id = model_used || m.model_id = used
  ) specs

let read_file_tail_lines path ~max_bytes ~max_lines : string list =
  if max_lines <= 0 || max_bytes <= 0 then []
  else if not (Sys.file_exists path) then []
  else
    try
      let ic = open_in_bin path in
      Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        let len = in_channel_length ic in
        let start = max 0 (len - max_bytes) in
        seek_in ic start;
        let remaining = len - start in
        let buf = Bytes.create remaining in
        really_input ic buf 0 remaining;
        let chunk = Bytes.to_string buf in
        let lines =
          chunk
          |> String.split_on_char '\n'
          |> List.filter (fun s -> String.trim s <> "")
        in
        let n = List.length lines in
        let drop = max 0 (n - max_lines) in
        lines |> List.mapi (fun i s -> (i, s)) |> List.filter (fun (i, _) -> i >= drop) |> List.map snd
      )
    with _ ->
      []

let parse_agent_status (config : Room.config) ~(agent_name : string) : Yojson.Safe.t =
  let agent_file =
    Filename.concat (Room.agents_dir config) (Room.safe_filename agent_name ^ ".json")
  in
  if not (Sys.file_exists agent_file) then
    `Assoc [("exists", `Bool false)]
  else
    match Safe_ops.read_json_file_safe agent_file with
    | Error _ -> `Assoc [("exists", `Bool true); ("error", `String "failed_to_read")]
    | Ok json ->
      (match Types.agent_of_yojson json with
       | Error _ -> `Assoc [("exists", `Bool true); ("error", `String "failed_to_parse")]
       | Ok (agent : Types.agent) ->
         let now_ts = Time_compat.now () in
         let joined_ts = Resilience.Time.parse_iso8601_opt agent.joined_at |> Option.value ~default:0.0 in
         let last_seen_ts = Resilience.Time.parse_iso8601_opt agent.last_seen |> Option.value ~default:0.0 in
         let age_s = if joined_ts <= 0.0 then 0.0 else now_ts -. joined_ts in
         let last_seen_ago_s = if last_seen_ts <= 0.0 then 0.0 else now_ts -. last_seen_ts in
         `Assoc [
           ("exists", `Bool true);
           ("name", `String agent.name);
           ("agent_type", `String agent.agent_type);
           ("status", `String (Types.string_of_agent_status agent.status));
           ("capabilities", `List (List.map (fun s -> `String s) agent.capabilities));
           ("current_task", match agent.current_task with None -> `Null | Some t -> `String t);
           ("joined_at", `String agent.joined_at);
           ("last_seen", `String agent.last_seen);
           ("age_s", `Float age_s);
           ("last_seen_ago_s", `Float last_seen_ago_s);
           ("is_zombie", `Bool (Room.is_zombie_agent agent.last_seen));
         ])

let build_keeper_system_prompt goal =
  Printf.sprintf
    "You are a keeper agent with persistent memory.\n\
     Your goal: %s\n\
     You will receive user messages. Reply clearly and concisely.\n\
     Do not output [GOAL_COMPLETE] unless explicitly requested.\n"
    goal

let load_context_from_checkpoint ~trace_id ~primary_model_max_tokens ~base_dir =
  let session = Context_manager.create_session ~session_id:trace_id ~base_dir in
  match Context_manager.load_latest_checkpoint session with
  | None -> (session, None)
  | Some ckpt ->
    let ctx = Context_manager.restore_checkpoint ckpt ~max_tokens:primary_model_max_tokens in
    (session, Some ctx)

let save_checkpoint session (ctx : Context_manager.working_context) ~generation =
  let ckpt = Context_manager.create_checkpoint ctx ~generation in
  Context_manager.save_checkpoint session ckpt;
  ckpt

let compact_if_needed (ctx : Context_manager.working_context) =
  let ratio = Context_manager.context_ratio ctx in
  if ratio >= 0.5 then
    Context_manager.compact ctx Context_manager.[PruneToolOutputs; MergeContiguous; DropLowImportance; SummarizeOld]
  else
    ctx

let generate_trace_id () =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let rnd = Random.int 99999 in
  Printf.sprintf "trace-%d-%05d" ts rnd

(* Presence keepalive fibers keyed by keeper name. *)
let keepalives : (string, bool ref) Hashtbl.t = Hashtbl.create 8

let start_keepalive (ctx : _ context) (m : keeper_meta) : unit =
  if not m.presence_keepalive then ()
  else if Hashtbl.mem keepalives m.name then ()
  else begin
    let stop = ref false in
    Hashtbl.replace keepalives m.name stop;
    (* Ensure the keeper agent exists in room (skip join if already present). *)
    (try
       if not (Room.is_agent_joined ctx.config ~agent_name:m.agent_name) then
         ignore (Room.join ctx.config ~agent_name:m.agent_name ~capabilities:["keeper"] ())
     with _ -> ());
    Eio.Fiber.fork ~sw:ctx.sw (fun () ->
      let rec loop () =
        if !stop then ()
        else begin
          (try ignore (Room.heartbeat ctx.config ~agent_name:m.agent_name) with _ -> ());
          Eio.Time.sleep ctx.clock (float_of_int (max 5 (min 300 m.presence_keepalive_sec)));
          loop ()
        end
      in
      loop ())
  end

let stop_keepalive name =
  match Hashtbl.find_opt keepalives name with
  | None -> ()
  | Some stop ->
    stop := true;
    Hashtbl.remove keepalives name

(* --------------------------------------------------------------- *)
(* Handlers                                                         *)
(* --------------------------------------------------------------- *)

let handle_keeper_up ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "❌ invalid keeper name (allowed: [A-Za-z0-9._-])")
  else
    let goal_opt = get_string_opt args "goal" in
    let models_in = get_string_list args "models" in
    let verify_opt = get_bool_opt args "verify" in
    let presence_keepalive_opt = get_bool_opt args "presence_keepalive" in
    let presence_keepalive_sec_opt = Safe_ops.json_int_opt "presence_keepalive_sec" args in
    let auto_handoff_opt = get_bool_opt args "auto_handoff" in
    let handoff_threshold_opt = Safe_ops.json_float_opt "handoff_threshold" args in
    let handoff_cooldown_sec_opt = Safe_ops.json_int_opt "handoff_cooldown_sec" args in
    let context_budget_opt = Safe_ops.json_float_opt "context_budget" args in
    match read_meta ctx.config name with
    | Error e -> (false, Printf.sprintf "❌ %s" e)
    | Ok None ->
      (* Create new keeper *)
      let goal = Option.value ~default:"" goal_opt in
      if goal = "" then
        (false, "❌ goal is required when creating a keeper")
      else if models_in = [] then
        (false, "❌ models is required when creating a keeper")
      else
        let verify = Option.value ~default:false verify_opt in
        let presence_keepalive = Option.value ~default:true presence_keepalive_opt in
        let presence_keepalive_sec = Option.value ~default:30 presence_keepalive_sec_opt in
        let auto_handoff = Option.value ~default:true auto_handoff_opt in
        let handoff_threshold = Option.value ~default:0.85 handoff_threshold_opt in
        let handoff_cooldown_sec = Option.value ~default:300 handoff_cooldown_sec_opt in
        let context_budget = Option.value ~default:0.6 context_budget_opt in
        (match model_specs_of_strings models_in with
         | Error e -> (false, "❌ " ^ e)
         | Ok specs ->
           (match ensure_api_keys specs with
           | Error e -> (false, "❌ " ^ e)
           | Ok () ->
             let trace_id = generate_trace_id () in
             let primary = match specs with
               | m :: _ -> m
               | [] -> Llm_client.ollama_glm
             in
             let base_dir = session_base_dir ctx.config in
             mkdir_p base_dir;
             let session = Context_manager.create_session ~session_id:trace_id ~base_dir in
             let system_prompt = build_keeper_system_prompt goal in
             let ctx0 = Context_manager.create ~system_prompt ~max_tokens:primary.max_context in
             ignore (save_checkpoint session ctx0 ~generation:0);
             let meta = {
               name;
               agent_name = keeper_agent_name name;
               trace_id;
               trace_history = [];
               goal;
               models = models_in;
               generation = 0;
               verify;
               presence_keepalive;
               presence_keepalive_sec;
               auto_handoff;
               handoff_threshold;
               handoff_cooldown_sec;
               context_budget;
               last_handoff_ts = 0.0;
               created_at = now_iso ();
               updated_at = now_iso ();
               total_turns = 0;
               total_input_tokens = 0;
               total_output_tokens = 0;
               total_tokens = 0;
               total_cost_usd = 0.0;
               last_turn_ts = 0.0;
               last_model_used = "";
               last_input_tokens = 0;
               last_output_tokens = 0;
               last_total_tokens = 0;
               last_latency_ms = 0;
               compaction_count = 0;
               last_compaction_ts = 0.0;
               last_compaction_before_tokens = 0;
               last_compaction_after_tokens = 0;
             } in
             match write_meta ctx.config meta with
             | Error e -> (false, "❌ " ^ e)
             | Ok () ->
               start_keepalive ctx meta;
               let json = `Assoc [
                 ("name", `String meta.name);
                 ("agent_name", `String meta.agent_name);
                 ("trace_id", `String meta.trace_id);
                 ("generation", `Int meta.generation);
                 ("goal", `String meta.goal);
                 ("models", `List (List.map (fun s -> `String s) meta.models));
                 ("presence_keepalive", `Bool meta.presence_keepalive);
                 ("presence_keepalive_sec", `Int meta.presence_keepalive_sec);
                 ("auto_handoff", `Bool meta.auto_handoff);
                 ("handoff_threshold", `Float meta.handoff_threshold);
               ] in
               (true, Yojson.Safe.pretty_to_string json)))
    | Ok (Some old) ->
      (* Update existing keeper meta (goal/models optional) *)
      let goal = match get_string_opt args "goal" with Some g -> g | None -> old.goal in
      let models = if models_in <> [] then models_in else old.models in
      let updated = { old with
        goal;
        models;
        verify = Option.value ~default:old.verify verify_opt;
        presence_keepalive = Option.value ~default:old.presence_keepalive presence_keepalive_opt;
        presence_keepalive_sec = Option.value ~default:old.presence_keepalive_sec presence_keepalive_sec_opt;
        auto_handoff = Option.value ~default:old.auto_handoff auto_handoff_opt;
        handoff_threshold = Option.value ~default:old.handoff_threshold handoff_threshold_opt;
        handoff_cooldown_sec = Option.value ~default:old.handoff_cooldown_sec handoff_cooldown_sec_opt;
        context_budget = Option.value ~default:old.context_budget context_budget_opt;
        updated_at = now_iso ();
      } in
      (match write_meta ctx.config updated with
       | Error e -> (false, "❌ " ^ e)
       | Ok () ->
         stop_keepalive updated.name;
         start_keepalive ctx updated;
         (true, Yojson.Safe.pretty_to_string (meta_to_json updated)))

let handle_keeper_status ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (false, Printf.sprintf "❌ keeper not found: %s" name)
    | Ok (Some m) ->
      let tail_turns = max 0 (get_int args "tail_turns" 5) in
      let tail_messages = max 0 (get_int args "tail_messages" 10) in
      let tail_bytes = max 1_000 (get_int args "tail_bytes" 200_000) in
      let models = m.models in
      (match model_specs_of_strings models with
       | Error e -> (false, "❌ " ^ e)
       | Ok specs ->
         let primary = match specs with m0 :: _ -> m0 | [] -> Llm_client.ollama_glm in
         let base_dir = session_base_dir ctx.config in
         let (_session, ctx_opt) = load_context_from_checkpoint
           ~trace_id:m.trace_id ~primary_model_max_tokens:primary.max_context ~base_dir in
         let ctx_stats = match ctx_opt with
           | None -> `Assoc [("has_checkpoint", `Bool false)]
           | Some c -> `Assoc [
               ("has_checkpoint", `Bool true);
               ("context_ratio", `Float (Context_manager.context_ratio c));
               ("context_tokens", `Int c.token_count);
               ("context_max", `Int c.max_tokens);
               ("message_count", `Int (List.length c.messages));
             ]
         in
         let keepalive_running = `Bool (Hashtbl.mem keepalives m.name) in
         let agent_status = parse_agent_status ctx.config ~agent_name:m.agent_name in
         let now_ts = Time_compat.now () in
         let created_ts =
           Resilience.Time.parse_iso8601_opt m.created_at |> Option.value ~default:0.0
         in
         let keeper_age_s = if created_ts <= 0.0 then 0.0 else now_ts -. created_ts in
         let last_turn_ago_s = if m.last_turn_ts <= 0.0 then 0.0 else now_ts -. m.last_turn_ts in
         let last_handoff_ago_s = if m.last_handoff_ts <= 0.0 then 0.0 else now_ts -. m.last_handoff_ts in
         let last_compaction_ago_s = if m.last_compaction_ts <= 0.0 then 0.0 else now_ts -. m.last_compaction_ts in

         let models_resolved = `List (List.map (fun (s : Llm_client.model_spec) ->
           `Assoc [
             ("provider", `String (Llm_client.string_of_provider s.provider));
             ("model_id", `String s.model_id);
             ("max_context", `Int s.max_context);
             ("api_key_env", match s.api_key_env with None -> `Null | Some k -> `String k);
           ]
         ) specs) in

         let metrics_tail =
           let lines = read_file_tail_lines (keeper_metrics_path ctx.config m.name)
             ~max_bytes:tail_bytes ~max_lines:tail_turns in
           `List (List.filter_map (fun line ->
             try Some (Yojson.Safe.from_string line) with _ -> None
           ) lines)
         in

         let history_tail =
           let history_path =
             Filename.concat (Filename.concat (session_base_dir ctx.config) m.trace_id) "history.jsonl"
           in
           let lines = read_file_tail_lines history_path
             ~max_bytes:tail_bytes ~max_lines:tail_messages in
           let open Yojson.Safe.Util in
           `List (List.filter_map (fun line ->
             try
               let j = Yojson.Safe.from_string line in
               let role = j |> member "role" |> to_string_option |> Option.value ~default:"unknown" in
               let content = j |> member "content" |> to_string_option |> Option.value ~default:"" in
               let preview =
                 if String.length content > 200 then String.sub content 0 200 ^ "..."
                 else content
               in
               Some (`Assoc [("role", `String role); ("content", `String preview)])
             with _ -> None
           ) lines)
         in

         let json = `Assoc [
           ("meta", meta_to_json m);
           ("keepalive_running", keepalive_running);
           ("agent", agent_status);
           ("keeper_age_s", `Float keeper_age_s);
           ("last_turn_ago_s", `Float last_turn_ago_s);
           ("last_handoff_ago_s", `Float last_handoff_ago_s);
           ("last_compaction_ago_s", `Float last_compaction_ago_s);
           ("models_resolved", models_resolved);
           ("context", ctx_stats);
           ("metrics_tail", metrics_tail);
           ("history_tail", history_tail);
         ] in
         (true, Yojson.Safe.pretty_to_string json))

let handle_keeper_msg ctx args : tool_result =
  let name = get_string args "name" "" in
  let message = get_string args "message" "" in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else if message = "" then
    (false, "❌ message is required")
  else
    let inline_goal = get_string_opt args "goal" in
    let inline_models = get_string_list args "models" in
    (* Ensure keeper exists (create inline if missing) *)
    let ensure_keeper () : (keeper_meta, string) result =
      match read_meta ctx.config name with
      | Error e -> Error e
      | Ok (Some m) -> Ok m
      | Ok None ->
        let goal = Option.value ~default:"" inline_goal in
        if goal = "" then Error "keeper not found and goal not provided"
        else if inline_models = [] then Error "keeper not found and models not provided"
        else
          let trace_id = generate_trace_id () in
          let meta = {
            name;
            agent_name = keeper_agent_name name;
            trace_id;
            trace_history = [];
            goal;
            models = inline_models;
            generation = 0;
            verify = false;
            presence_keepalive = true;
            presence_keepalive_sec = 30;
            auto_handoff = true;
            handoff_threshold = 0.85;
            handoff_cooldown_sec = 300;
            context_budget = 0.6;
            last_handoff_ts = 0.0;
            created_at = now_iso ();
            updated_at = now_iso ();
            total_turns = 0;
            total_input_tokens = 0;
            total_output_tokens = 0;
            total_tokens = 0;
            total_cost_usd = 0.0;
            last_turn_ts = 0.0;
            last_model_used = "";
            last_input_tokens = 0;
            last_output_tokens = 0;
            last_total_tokens = 0;
            last_latency_ms = 0;
            compaction_count = 0;
            last_compaction_ts = 0.0;
            last_compaction_before_tokens = 0;
            last_compaction_after_tokens = 0;
          } in
          let base_dir = session_base_dir ctx.config in
          mkdir_p base_dir;
          (match model_specs_of_strings meta.models with
           | Error e -> Error e
           | Ok specs ->
             (match ensure_api_keys specs with
              | Error e -> Error e
              | Ok () ->
                let primary = match specs with m0 :: _ -> m0 | [] -> Llm_client.ollama_glm in
                let session = Context_manager.create_session ~session_id:trace_id ~base_dir in
                let system_prompt = build_keeper_system_prompt goal in
                let ctx0 = Context_manager.create ~system_prompt ~max_tokens:primary.max_context in
                ignore (save_checkpoint session ctx0 ~generation:0);
                match write_meta ctx.config meta with
                | Error e -> Error e
                | Ok () -> Ok meta))
    in
    match ensure_keeper () with
    | Error e -> (false, "❌ " ^ e)
    | Ok meta0 ->
      (* Update goal if requested *)
      let meta =
        match get_string_opt args "new_goal" with
        | None -> meta0
        | Some ng ->
          let updated = { meta0 with goal = ng; updated_at = now_iso () } in
          ignore (write_meta ctx.config updated);
          updated
      in
      start_keepalive ctx meta;
      (match model_specs_of_strings meta.models with
       | Error e -> (false, "❌ " ^ e)
       | Ok specs ->
         (match ensure_api_keys specs with
          | Error e -> (false, "❌ " ^ e)
          | Ok () ->
            let primary = match specs with m0 :: _ -> m0 | [] -> Llm_client.ollama_glm in
            let base_dir = session_base_dir ctx.config in
            mkdir_p base_dir;
            let (session, ctx_opt) = load_context_from_checkpoint
              ~trace_id:meta.trace_id ~primary_model_max_tokens:primary.max_context ~base_dir in
            let ctx_work =
              match ctx_opt with
              | Some c -> c
              | None ->
                Context_manager.create
                  ~system_prompt:(build_keeper_system_prompt meta.goal)
                  ~max_tokens:primary.max_context
            in
            let user_msg = Llm_client.user_msg message in
            let ctx_work = Context_manager.append ctx_work user_msg in
            Context_manager.persist_message session user_msg;

            (* Single-turn LLM call with cascade *)
            let requests =
              List.map (fun (model : Llm_client.model_spec) ->
                let msgs =
                  (Llm_client.system_msg ctx_work.system_prompt) :: ctx_work.messages
                in
                ({
                  Llm_client.model;
                  messages = msgs;
                  temperature = 0.7;
                  max_tokens = 4096;
                  tools = [];
                  response_format = `Text;
                } : Llm_client.completion_request)
              ) specs
            in
            match Llm_client.cascade requests with
            | Error e ->
              (false, Printf.sprintf "❌ LLM failed: %s" e)
            | Ok resp ->
              let assistant_msg = Llm_client.assistant_msg resp.content in
              let ctx_work = Context_manager.append ctx_work assistant_msg in
              Context_manager.persist_message session assistant_msg;
              let now_ts = Time_compat.now () in
              let used_model =
                model_spec_for_used specs resp.model_used
                |> Option.value ~default:primary
              in
              let cost_usd = cost_usd_of_usage resp.usage used_model in

              (* Compact opportunistically to control growth. *)
              let before_compact_tokens = ctx_work.token_count in
              let ctx_work = compact_if_needed ctx_work in
              let after_compact_tokens = ctx_work.token_count in
              let compacted = after_compact_tokens < before_compact_tokens in

              let ctx_ratio = Context_manager.context_ratio ctx_work in
              let meta_turn = { meta with
                updated_at = now_iso ();
                total_turns = meta.total_turns + 1;
                total_input_tokens = meta.total_input_tokens + resp.usage.input_tokens;
                total_output_tokens = meta.total_output_tokens + resp.usage.output_tokens;
                total_tokens = meta.total_tokens + resp.usage.total_tokens;
                total_cost_usd = meta.total_cost_usd +. cost_usd;
                last_turn_ts = now_ts;
                last_model_used = resp.model_used;
                last_input_tokens = resp.usage.input_tokens;
                last_output_tokens = resp.usage.output_tokens;
                last_total_tokens = resp.usage.total_tokens;
                last_latency_ms = resp.latency_ms;
                compaction_count = meta.compaction_count + (if compacted then 1 else 0);
                last_compaction_ts = (if compacted then now_ts else meta.last_compaction_ts);
                last_compaction_before_tokens =
                  (if compacted then before_compact_tokens else meta.last_compaction_before_tokens);
                last_compaction_after_tokens =
                  (if compacted then after_compact_tokens else meta.last_compaction_after_tokens);
              } in

              ignore (save_checkpoint session ctx_work ~generation:meta_turn.generation);

              let do_handoff =
                meta_turn.auto_handoff &&
                ctx_ratio >= meta_turn.handoff_threshold &&
                (now_ts -. meta_turn.last_handoff_ts >= float_of_int meta_turn.handoff_cooldown_sec)
              in

              let metrics_path = keeper_metrics_path ctx.config meta_turn.name in

              if not do_handoff then begin
                (match write_meta ctx.config meta_turn with
                 | Ok () -> ()
                 | Error e -> Printf.eprintf "[keeper:%s] failed to write meta: %s\n%!" meta_turn.name e);

                (try
                   let metrics_json = `Assoc [
                     ("ts", `String (now_iso ()));
                     ("ts_unix", `Float now_ts);
                     ("name", `String meta_turn.name);
                     ("agent_name", `String meta_turn.agent_name);
                     ("trace_id", `String meta_turn.trace_id);
                     ("generation", `Int meta_turn.generation);
                     ("model_used", `String resp.model_used);
                     ("usage", `Assoc [
                       ("input_tokens", `Int resp.usage.input_tokens);
                       ("output_tokens", `Int resp.usage.output_tokens);
                       ("total_tokens", `Int resp.usage.total_tokens);
                     ]);
                     ("latency_ms", `Int resp.latency_ms);
                     ("cost_usd", `Float cost_usd);
                     ("context_ratio", `Float ctx_ratio);
                     ("context_tokens", `Int ctx_work.token_count);
                     ("context_max", `Int ctx_work.max_tokens);
                     ("message_count", `Int (List.length ctx_work.messages));
                     ("compacted", `Bool compacted);
                     ("compaction_before_tokens", `Int before_compact_tokens);
                     ("compaction_after_tokens", `Int after_compact_tokens);
                     ("handoff", `Assoc [("performed", `Bool false)]);
                   ] in
                   append_jsonl_line metrics_path metrics_json
                 with _ -> ());

                let json = `Assoc [
                  ("name", `String meta_turn.name);
                  ("trace_id", `String meta_turn.trace_id);
                  ("generation", `Int meta_turn.generation);
                  ("model_used", `String resp.model_used);
                  ("usage", `Assoc [
                    ("input_tokens", `Int resp.usage.input_tokens);
                    ("output_tokens", `Int resp.usage.output_tokens);
                    ("total_tokens", `Int resp.usage.total_tokens);
                  ]);
                  ("latency_ms", `Int resp.latency_ms);
                  ("cost_usd", `Float cost_usd);
                  ("reply", `String resp.content);
                  ("context_ratio", `Float ctx_ratio);
                  ("compacted", `Bool compacted);
                ] in
                (true, Yojson.Safe.pretty_to_string json)
              end else begin
                (* Auto-handoff: hydrate successor context + rotate trace_id. *)
                let next_model =
                  match specs with
                  | _m0 :: m1 :: _ -> m1
                  | m0 :: _ -> m0
                  | [] -> primary
                in
                let metrics = Succession.{
                  total_turns = meta_turn.total_turns;
                  total_tokens_used = meta_turn.total_tokens;
                  total_cost_usd = meta_turn.total_cost_usd;
                  tasks_completed = 0;
                  errors_encountered = 0;
                  elapsed_seconds = 0.0;
                } in
                let dna = Succession.extract_dna
                  ~working_ctx:ctx_work
                  ~session_ctx:session
                  ~goal:meta_turn.goal
                  ~generation:meta_turn.generation
                  ~trace_id:meta_turn.trace_id
                  ~metrics
                in
                let spec = Succession.{
                  model = next_model;
                  inherit_tools = false;
                  context_budget = meta_turn.context_budget;
                } in
                let successor_ctx = Succession.hydrate dna spec in
                let successor_trace = generate_trace_id () in
                let successor_session = Context_manager.create_session
                  ~session_id:successor_trace ~base_dir in
                ignore (save_checkpoint successor_session successor_ctx ~generation:(meta_turn.generation + 1));

                let prev_trace_id = meta_turn.trace_id in
                let trace_history = take 20 (prev_trace_id :: meta_turn.trace_history) in
                let meta' = { meta_turn with
                  trace_id = successor_trace;
                  trace_history;
                  generation = meta_turn.generation + 1;
                  last_handoff_ts = now_ts;
                  updated_at = now_iso ();
                } in
                ignore (write_meta ctx.config meta');

                (try
                   let metrics_json = `Assoc [
                     ("ts", `String (now_iso ()));
                     ("ts_unix", `Float now_ts);
                     ("name", `String meta'.name);
                     ("agent_name", `String meta'.agent_name);
                     ("trace_id", `String prev_trace_id);
                     ("generation", `Int meta_turn.generation);
                     ("model_used", `String resp.model_used);
                     ("usage", `Assoc [
                       ("input_tokens", `Int resp.usage.input_tokens);
                       ("output_tokens", `Int resp.usage.output_tokens);
                       ("total_tokens", `Int resp.usage.total_tokens);
                     ]);
                     ("latency_ms", `Int resp.latency_ms);
                     ("cost_usd", `Float cost_usd);
                     ("context_ratio", `Float ctx_ratio);
                     ("context_tokens", `Int ctx_work.token_count);
                     ("context_max", `Int ctx_work.max_tokens);
                     ("message_count", `Int (List.length ctx_work.messages));
                     ("compacted", `Bool compacted);
                     ("compaction_before_tokens", `Int before_compact_tokens);
                     ("compaction_after_tokens", `Int after_compact_tokens);
                     ("handoff", `Assoc [
                       ("performed", `Bool true);
                       ("prev_trace_id", `String prev_trace_id);
                       ("new_trace_id", `String meta'.trace_id);
                       ("to_model", `String next_model.model_id);
                       ("new_generation", `Int meta'.generation);
                     ]);
                   ] in
                   append_jsonl_line metrics_path metrics_json
                 with _ -> ());

                let json = `Assoc [
                  ("name", `String meta'.name);
                  ("reply", `String resp.content);
                  ("model_used", `String resp.model_used);
                  ("latency_ms", `Int resp.latency_ms);
                  ("cost_usd", `Float cost_usd);
                  ("context_ratio", `Float ctx_ratio);
                  ("compacted", `Bool compacted);
                  ("handoff", `Assoc [
                    ("performed", `Bool true);
                    ("prev_trace_id", `String prev_trace_id);
                    ("new_trace_id", `String meta'.trace_id);
                    ("to_model", `String next_model.model_id);
                    ("new_generation", `Int meta'.generation);
                  ]);
                ] in
                (true, Yojson.Safe.pretty_to_string json)
              end))

let handle_keeper_down ctx args : tool_result =
  let name = get_string args "name" "" in
  if not (validate_name name) then
    (false, "❌ invalid keeper name")
  else
    let remove_meta = get_bool args "remove_meta" true in
    let remove_session = get_bool args "remove_session" false in
    stop_keepalive name;
    match read_meta ctx.config name with
    | Error e -> (false, "❌ " ^ e)
    | Ok None -> (true, Printf.sprintf "keeper already absent: %s" name)
    | Ok (Some m) ->
      if remove_meta then
        Safe_ops.remove_file_logged ~context:"keeper_down" (keeper_meta_path ctx.config name);
      if remove_session then begin
        let rec rm_rf path =
          if Sys.file_exists path then begin
            if Sys.is_directory path then begin
              Sys.readdir path |> Array.iter (fun entry ->
                rm_rf (Filename.concat path entry)
              );
              Unix.rmdir path
            end else
              Sys.remove path
          end
        in
        if validate_name m.trace_id then
          let dir = Filename.concat (session_base_dir ctx.config) m.trace_id in
          (try rm_rf dir with _ -> ())
      end;
      let json = `Assoc [
        ("name", `String name);
        ("stopped", `Bool true);
        ("remove_meta", `Bool remove_meta);
        ("remove_session", `Bool remove_session);
      ] in
      (true, Yojson.Safe.pretty_to_string json)

let handle_keeper_list ctx args : tool_result =
  let limit = max 0 (get_int args "limit" 50) in
  let dir = keeper_dir ctx.config in
  match Safe_ops.list_dir_safe dir with
  | Error e -> (false, "❌ " ^ e)
  | Ok files ->
    let keepers =
      files
      |> List.filter (fun f -> Filename.check_suffix f ".json")
      |> List.map Filename.remove_extension
      |> List.filter validate_name
      |> List.sort String.compare
      |> take limit
    in
    let json = `Assoc [
      ("count", `Int (List.length keepers));
      ("keepers", `List (List.map (fun k -> `String k) keepers));
    ] in
    (true, Yojson.Safe.pretty_to_string json)

(* Start keepalive fibers for existing keepers (best-effort). *)
let start_existing_keepalives ctx =
  let dir = keeper_dir ctx.config in
  match Safe_ops.list_dir_safe dir with
  | Error _ -> ()
  | Ok files ->
    files
    |> List.filter (fun f -> Filename.check_suffix f ".json")
    |> List.iter (fun f ->
      let name = Filename.remove_extension f in
      match read_meta ctx.config name with
      | Ok (Some m) -> start_keepalive ctx m
      | _ -> ())

let dispatch ctx ~name ~args : tool_result option =
  (* Lazy boot: when any keeper tool is used, attach keepalives for existing keepers. *)
  (try start_existing_keepalives ctx with _ -> ());
  match name with
  | "masc_keeper_up" -> Some (handle_keeper_up ctx args)
  | "masc_keeper_status" -> Some (handle_keeper_status ctx args)
  | "masc_keeper_msg" -> Some (handle_keeper_msg ctx args)
  | "masc_keeper_down" -> Some (handle_keeper_down ctx args)
  | "masc_keeper_list" -> Some (handle_keeper_list ctx args)
  | _ -> None
