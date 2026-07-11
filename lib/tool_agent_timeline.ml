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

(** Tool_agent_timeline - Unified agent activity timeline.

    Collects events from multiple data sources and merges them into
    a single chronological timeline for a given agent.

    Data sources:
    - Agent session status (Workspace.get_agents_raw)
    - Task state transitions (Workspace.get_tasks_raw)
    - Broadcast messages (Workspace.get_messages_raw)
*)

open Tool_args

type tool_result = Tool_result.result

type context = {
  config : Workspace.config;
  agent_name : string;
}

(* ISO timestamp parsing (reuses Dashboard logic) *)
let parse_iso_timestamp (s : string) : float option =
  try
    let open Stdlib.Scanf in
    sscanf s "%d-%d-%dT%d:%d:%d" (fun y m d h min sec ->
        let tm =
          {
            Unix.tm_sec = sec;
            tm_min = min;
            tm_hour = h;
            tm_mday = d;
            tm_mon = m - 1;
            tm_year = y - 1900;
            tm_wday = 0;
            tm_yday = 0;
            tm_isdst = false;
          }
        in
        let (local_t, _) = Unix.mktime tm in
        let utc_tm = Unix.gmtime local_t in
        let (utc_as_local, _) = Unix.mktime utc_tm in
        let tz_offset = local_t -. utc_as_local in
        Some (local_t -. tz_offset))
  with Stdlib.Scanf.Scan_failure _ | Failure _ | End_of_file -> None

(* Event type for the unified timeline *)
type timeline_event = {
  ts : float;
  ts_iso : string;
  event_type : string;
  detail : Yojson.Safe.t;
}

let dashboard_surface = "/api/v1/agent-timeline"
let dashboard_source = "agent_timeline_read_model"

let dashboard_retention_json =
  `Assoc
    [
      ("scope", `String "multi_source_tail");
      ( "durable_store",
        `String
          ".masc/agents/*.json + .masc/tasks/*.json + \
           .masc/messages/*.json + \
           .masc/activity-events/YYYY-MM/YYYY-MM-DD.jsonl + \
           .masc/keeper_chat/*.jsonl" );
      ( "durable_stores",
        `List
          [
            `String ".masc/agents/*.json";
            `String ".masc/tasks/*.json";
            `String ".masc/messages/*.json";
            `String ".masc/activity-events/YYYY-MM/YYYY-MM-DD.jsonl";
            `String ".masc/keeper_chat/*.jsonl";
          ] );
      ( "activity_event_kinds",
        `List
          [
            `String "tool.called";
            `String "keeper.tool_exec";
            `String "keeper.contract_verdict";
            `String "keeper.friction";
            `String "keeper.turn_completed";
          ] );
    ]

let event_to_json (e : timeline_event) : Yojson.Safe.t =
  `Assoc
    [
      ("ts", `String e.ts_iso);
      ("type", `String e.event_type);
      ("detail", e.detail);
    ]

let keeper_actor_id agent_name = "keeper-" ^ agent_name ^ "-agent"

(* Keeper identity is persisted in two string forms across the stores: the
   short handle ("albini") and the full actor id ("keeper-albini-agent");
   some call sites also use the "keeper:albini" prefix form. A single agent's
   rows must match whichever form the store wrote, so every identity
   comparison routes through this one predicate.

   Root cause: keeper identity has no typed canonical representation — the
   short handle and actor id are two untyped strings used interchangeably.
   The surgical fix unifies the comparison the activity path already did;
   the proper fix is a typed [Keeper_id] with one canonical form plus
   explicit projections (RFC-scale, tracked separately). *)
let identity_matches ~(agent_name : string) (candidate : string) : bool =
  String.equal candidate agent_name
  || String.equal candidate (keeper_actor_id agent_name)
  || String.equal candidate ("keeper:" ^ agent_name)

let activity_event_matches_agent ~(agent_name : string) (e : Activity_graph.event) =
  let actor_matches =
    match e.actor with
    | Some a -> identity_matches ~agent_name a.id
    | None -> false
  in
  actor_matches
  || Safe_ops.json_string_opt "keeper_name" e.payload = Some agent_name
  || Safe_ops.json_string_opt "agent_name" e.payload = Some agent_name
  || Safe_ops.json_string_opt "name" e.payload = Some agent_name

(* Collect agent session/status events *)
let agent_events (config : Workspace.config) ~agent_name :
    timeline_event list =
  let agents = Workspace.get_active_agents config in
  agents
  |> List.filter (fun (a : Masc_domain.agent) -> identity_matches ~agent_name a.name)
  |> List.filter_map (fun (a : Masc_domain.agent) ->
         match parse_iso_timestamp a.session_bound_at with
         | Some ts ->
             Some
               {
                 ts;
                 ts_iso = a.session_bound_at;
                 event_type = "session_bound";
                 detail =
                   `Assoc
                     [
                       ("workspace", `String "default");
                       ( "status",
                         `String (Masc_domain.agent_status_to_string a.status) );
                       ( "current_task", Json_util.string_opt_to_json a.current_task );
                     ];
               }
         | None -> None)

(* Collect task-related events for an agent *)
let task_events (config : Workspace.config) ~agent_name :
    timeline_event list =
  let tasks = Workspace.get_tasks_safe config in
  tasks
  |> List.filter_map (fun (task : Masc_domain.task) ->
         match task.task_status with
         | Masc_domain.Claimed { assignee; claimed_at }
           when identity_matches ~agent_name assignee -> (
             match parse_iso_timestamp claimed_at with
             | Some ts ->
                 Some
                   {
                     ts;
                     ts_iso = claimed_at;
                     event_type = "task_claimed";
                     detail =
                       `Assoc
                         [
                           ("task_id", `String task.id);
                           ("title", `String task.title);
                           ("priority", `Int task.priority);
                         ];
                   }
             | None -> None)
         | Masc_domain.InProgress { assignee; started_at }
           when identity_matches ~agent_name assignee -> (
             match parse_iso_timestamp started_at with
             | Some ts ->
                 Some
                   {
                     ts;
                     ts_iso = started_at;
                     event_type = "task_started";
                     detail =
                       `Assoc
                         [
                           ("task_id", `String task.id);
                           ("title", `String task.title);
                           ("priority", `Int task.priority);
                         ];
                   }
             | None -> None)
         | Masc_domain.Done { assignee; completed_at; notes }
           when identity_matches ~agent_name assignee -> (
             match parse_iso_timestamp completed_at with
             | Some ts ->
                 Some
                   {
                     ts;
                     ts_iso = completed_at;
                     event_type = "task_completed";
                     detail =
                       `Assoc
                         [
                           ("task_id", `String task.id);
                           ("title", `String task.title);
                           ("priority", `Int task.priority);
                           ( "notes", Json_util.string_opt_to_json notes );
                         ];
                   }
             | None -> None)
         | Masc_domain.Cancelled { cancelled_by; cancelled_at; reason }
           when identity_matches ~agent_name cancelled_by -> (
             match parse_iso_timestamp cancelled_at with
             | Some ts ->
                 Some
                   {
                     ts;
                     ts_iso = cancelled_at;
                     event_type = "task_cancelled";
                     detail =
                       `Assoc
                         [
                           ("task_id", `String task.id);
                           ("title", `String task.title);
                           ( "reason", Json_util.string_opt_to_json reason );
                         ];
                   }
             | None -> None)
         | _ -> None)

(* Collect broadcast messages from agent *)
let message_events (config : Workspace.config) ~agent_name ~limit :
    timeline_event list =
  let messages =
    Workspace.get_messages_raw config ~since_seq:0 ~limit
  in
  messages
  |> List.filter (fun (m : Masc_domain.message) ->
         identity_matches ~agent_name m.from_agent)
  |> List.filter_map (fun (m : Masc_domain.message) ->
         match parse_iso_timestamp m.timestamp with
         | Some ts ->
             Some
               {
                 ts;
                 ts_iso = m.timestamp;
                 event_type = "broadcast";
                 detail =
                   `Assoc
                     [
                       ("content", `String m.content);
                       ("type", `String m.msg_type);
                       ( "mention", Json_util.string_opt_to_json m.mention );
                     ];
               }
         | None -> None)

(* Keep the newest [n] events. [Activity_graph.list_events ~after_seq:0]
   returns the source's newest window in seq-ascending order (oldest first),
   so this agent's newest matches sit at the tail; a front-take would discard
   exactly the recent events the tool contracts to surface (period.to = now)
   whenever a keeper exceeds the per-source cap. Mirrors [build_timeline]'s
   tail-keep on the merged list, and preserves the source's ascending order. *)
let take_last n xs =
  if n <= 0 then []
  else
    let len = List.length xs in
    if len <= n then xs
    else
      let rec skip k = function
        | [] -> []
        | _ :: rest when k > 0 -> skip (k - 1) rest
        | remaining -> remaining
      in
      skip (len - n) xs

(* Collect tool call events from Activity Graph. Two producers feed this
   source: the external MCP dispatch path ([tool.called]) and the keeper
   in-turn execution hook ([keeper.tool_exec], #23540 — without it a keeper
   working through its own turn reported tool_calls = 0). Both share the
   tool_name/success/duration_ms payload contract projected below. *)
let tool_call_events (config : Workspace.config) ~agent_name ~limit :
    timeline_event list =
  (* `list_events` limits globally before we filter by actor, so fetch a
     wider bounded window to reduce the chance that busy-workspace activity from
     other agents crowds out this agent's tool events. *)
  let scan_limit =
    let expanded = if limit <= 0 then 0 else limit * 10 in
    min 1000 (max limit expanded)
  in
  let all_events =
    Activity_graph.list_events config
      ~kinds:["tool.called"; "keeper.tool_exec"] ~after_seq:0 ~limit:scan_limit ()
  in
  all_events
  |> List.filter (activity_event_matches_agent ~agent_name)
  |> List.filter_map (fun (e : Activity_graph.event) ->
       let ts = Float.of_int e.ts_ms /. 1000.0 in
       let tool_name =
         Safe_ops.json_string ~default:"unknown" "tool_name" e.payload
       in
       let success =
         Safe_ops.json_bool ~default:true "success" e.payload
       in
       let duration_ms =
         Safe_ops.json_int ~default:0 "duration_ms" e.payload
       in
       let error_str = Safe_ops.json_string_opt "error" e.payload in
       let source_str = Safe_ops.json_string_opt "source" e.payload in
       Some
         {
           ts;
           ts_iso = e.ts_iso;
           event_type = "tool_call";
           detail =
             `Assoc
               [
                 ("tool_name", `String tool_name);
                 ("success", `Bool success);
                 ("duration_ms", `Int duration_ms);
                 ("error", Json_util.string_opt_to_json error_str);
                 ("source", Json_util.string_opt_to_json source_str);
               ];
         })
  |> take_last limit

let keeper_cdal_events (config : Workspace.config) ~agent_name ~limit :
    timeline_event list =
  let scan_limit =
    let expanded = if limit <= 0 then 0 else limit * 10 in
    min 1000 (max limit expanded)
  in
  let all_events =
    Activity_graph.list_events config
      ~kinds:["keeper.contract_verdict"; "keeper.friction"]
      ~after_seq:0 ~limit:scan_limit ()
  in
  all_events
  |> List.filter (activity_event_matches_agent ~agent_name)
  |> List.map (fun (e : Activity_graph.event) ->
       {
         ts = Float.of_int e.ts_ms /. 1000.0;
         ts_iso = e.ts_iso;
         event_type = e.kind;
         detail = e.payload;
       })
  |> take_last limit

(* Collect turn-completed events from Activity Graph *)
let turn_completed_events (config : Workspace.config) ~agent_name ~limit :
    timeline_event list =
  let scan_limit =
    let expanded = if limit <= 0 then 0 else limit * 10 in
    min 1000 (max limit expanded)
  in
  let all_events =
    Activity_graph.list_events config
      ~kinds:["keeper.turn_completed"] ~after_seq:0 ~limit:scan_limit ()
  in
  all_events
  |> List.filter (activity_event_matches_agent ~agent_name)
  |> List.filter_map (fun (e : Activity_graph.event) ->
       let ts = Float.of_int e.ts_ms /. 1000.0 in
       (* Pure-shape JSON access via Safe_ops: no exception swallow, no
          performative [Cancelled] re-raise. Behavior parity with the prior
          [try ... |> to_X with _ -> default] pattern on missing/wrong-typed
          fields; widens acceptance to string-coerced numerics per the
          codebase convention documented in Safe_ops.json_*_opt. *)
       let keeper_name = Safe_ops.json_string ~default:"unknown" "keeper_name" e.payload in
       let input_tokens = Safe_ops.json_int_opt "input_tokens" e.payload in
       let output_tokens = Safe_ops.json_int_opt "output_tokens" e.payload in
       let cache_creation_tokens =
         Safe_ops.json_int_opt "cache_creation_tokens" e.payload
       in
       let cache_read_tokens = Safe_ops.json_int_opt "cache_read_tokens" e.payload in
       let cache_miss_input_tokens =
         Safe_ops.json_int_opt "cache_miss_input_tokens" e.payload
       in
       let cost_usd = Safe_ops.json_float_opt "cost_usd" e.payload in
       let latency_ms = Safe_ops.json_int_opt "latency_ms" e.payload in
       let model_used = Safe_ops.json_string ~default:"unknown" "model_used" e.payload in
       let work_kind =
         (* RFC-0182 §3.1 cycle break — codec moved to lib/Turn_mode_codec
            (was Keeper_unified_metrics.work_kind_of_json in lib/keeper/). *)
         Turn_mode_codec.work_kind_of_json e.payload
         |> Option.value ~default:"unknown"
       in
       let context_ratio = Safe_ops.json_float_opt "context_ratio" e.payload in
       let tools_used = Safe_ops.json_string_list "tools_used" e.payload in
       let m key = Option.value ~default:`Null (Json_util.assoc_member_opt key e.payload) in
       let optional_fields =
         let reasoning =
           match m "reasoning_tokens" with
           | `Int n -> [("reasoning_tokens", `Int n)]
           | _ -> []
         in
        let tps =
          match m "tokens_per_second" with
          | `Float v -> [("tokens_per_second", `Float v)]
          | _ -> []
        in
        let prompt_tps =
          match m "prompt_per_second" with
          | `Float v -> [("prompt_per_second", `Float v)]
          | _ -> []
        in
        let hw_decode_tps =
          match m "hw_decode_tokens_per_second" with
          | `Float v -> [("hw_decode_tokens_per_second", `Float v)]
          | _ -> []
        in
         reasoning @ tps @ prompt_tps @ hw_decode_tps
       in
       Some
         {
           ts;
           ts_iso = e.ts_iso;
           event_type = "turn_completed";
           detail =
             `Assoc
               ([
                 ("keeper_name", `String keeper_name);
                 ("input_tokens", Json_util.int_opt_to_json input_tokens);
                 ("output_tokens", Json_util.int_opt_to_json output_tokens);
                 ("cache_creation_tokens", Json_util.int_opt_to_json cache_creation_tokens);
                 ("cache_read_tokens", Json_util.int_opt_to_json cache_read_tokens);
                 ("cache_miss_input_tokens", Json_util.int_opt_to_json cache_miss_input_tokens);
                 ("cost_usd", Json_util.float_opt_to_json cost_usd);
                 ("latency_ms", Json_util.int_opt_to_json latency_ms);
                 ("model_used", `String model_used);
                 ("work_kind", `String work_kind);
                 ("context_ratio", Json_util.float_opt_to_json context_ratio);
                 ("tools_used", `List (List.map (fun s -> `String s) tools_used));
               ] @ optional_fields);
         })
  |> take_last limit

(* Neutral projection of one keeper chat line for the timeline. The chat
   store (.masc/keeper_chat/<keeper>.jsonl) lives in the keeper subsystem,
   and this tool module must not reference it (RFC-0194 §3 tool -> keeper
   boundary). So a keeper-aware caller reads the store, drops tool rows and
   rows without a timestamp, and passes the surviving user/assistant lines
   in as [chat_line] values via [build_timeline]'s [load_chat]. This module
   only maps that neutral data into timeline events. *)
type chat_line = {
  cl_role : string;  (** "user" | "assistant" *)
  cl_content : string;
  cl_ts : float;
  cl_connector : string option;  (** dashboard | discord | slack | agent | ... *)
  cl_conversation_id : string option;
}

(* Map keeper chat lines into timeline events. Granularity mirrors
   [message_events]: one event per user/assistant line. That store is the
   sole record of keeper<->operator conversation turns — the activity-event
   log the other sources read carries autonomous turns but no chat, so
   before this source a keeper's chat time and actions were absent from the
   timeline entirely (task-1647). Ordering within a turn (user before
   assistant, which share one ts) is preserved by the stable sort in
   [build_timeline]; no timestamp is fabricated. *)
let chat_events (lines : chat_line list) : timeline_event list =
  List.map
    (fun (l : chat_line) ->
      {
        ts = l.cl_ts;
        ts_iso = Masc_domain.iso8601_of_unix_seconds l.cl_ts;
        event_type = "chat";
        detail =
          `Assoc
            [
              ("role", `String l.cl_role);
              ("content", `String l.cl_content);
              ("source", Json_util.string_opt_to_json l.cl_connector);
              ( "conversation_id",
                Json_util.string_opt_to_json l.cl_conversation_id );
            ];
      })
    lines

(* Build the full timeline. [load_chat] is the keeper-aware chat reader
   injected by the caller (see [chat_line]); it defaults to producing no
   chat events so this module never depends on the keeper subsystem. *)
let build_timeline ?(load_chat = fun ~agent_name:_ -> ([] : chat_line list))
    (config : Workspace.config) ~agent_name ~since_hours ~limit
    ~include_tasks ~include_board:_ ~include_tool_calls =
  let now = Time_compat.now () in
  let cutoff = now -. (since_hours *. Masc_time_constants.hour) in
  (* Collect events from the default namespace. *)
  let all_events =
    let agent_evts = agent_events config ~agent_name in
    let task_evts =
      if include_tasks then task_events config ~agent_name
      else []
    in
    let msg_evts = message_events config ~agent_name ~limit:200 in
    let tool_evts =
      if include_tool_calls then tool_call_events config ~agent_name ~limit:200
      else []
    in
    let turn_evts =
      turn_completed_events config ~agent_name ~limit:200
    in
    let chat_evts = chat_events (load_chat ~agent_name) in
    agent_evts @ task_evts @ msg_evts @ tool_evts @ turn_evts
    @ chat_evts
  in
  (* Filter by time cutoff and sort chronologically. [stable_sort] (not
     [sort]) so events sharing a timestamp keep their source order — a
     chat turn's user and assistant lines share one ts (Keeper_chat_store
     writes them together), and structural trace order must survive the
     merge rather than being scrambled by an unstable sort. No timestamp
     is rewritten to force order. *)
  let filtered =
    all_events
    |> List.filter (fun e -> Stdlib.Float.compare e.ts cutoff >= 0)
    |> List.stable_sort (fun a b -> Stdlib.Float.compare a.ts b.ts)
  in
  (* Truncate to limit — keep the most recent events (tail of sorted list) *)
  let events =
    let len = List.length filtered in
    if len > limit then
      let drop = len - limit in
      let rec skip n = function
        | [] -> []
        | _ :: rest when n > 0 -> skip (n - 1) rest
        | remaining -> remaining
      in
      skip drop filtered
    else filtered
  in
  (* Compute summary *)
  let tasks_completed =
    List.length
      (List.filter
         (fun e -> String.equal e.event_type "task_completed")
         events)
  in
  let tasks_claimed =
    List.length
      (List.filter
         (fun e -> String.equal e.event_type "task_claimed")
         events)
  in
  let messages_sent =
    List.length
      (List.filter (fun e -> String.equal e.event_type "broadcast") events)
  in
  let tool_calls =
    List.length
      (List.filter (fun e -> String.equal e.event_type "tool_call") events)
  in
  let chat_messages =
    List.length
      (List.filter (fun e -> String.equal e.event_type "chat") events)
  in
  let turn_events =
    List.filter (fun e -> String.equal e.event_type "turn_completed") events
  in
  let turns_completed = List.length turn_events in
  (* Aggregation fold-semantic decision (Task #28):
     Silent-zero on missing/malformed field is intentional and acceptable
     because (a) per-event detail is rendered separately in the
     ["events"] array below, so operators can drill down to find the
     event with the malformed payload, (b) under-reporting is honest —
     a sum of "what we could parse" beats inventing values, (c) using
     [Safe_ops.json_int_opt] / [json_float_opt] removes the implicit
     try/catch that previously could absorb non-Cancelled exceptions
     (Yojson.Safe.Util.Type_error etc.) without distinguishing them
     from a legitimately missing field. The new shape uses pure
     pattern-matching accessors and no try/catch on the hot path. *)
  let total_input_tokens =
    List.fold_left
      (fun acc e ->
        acc + Option.value (Safe_ops.json_int_opt "input_tokens" e.detail) ~default:0)
      0
      turn_events
  in
  let total_output_tokens =
    List.fold_left
      (fun acc e ->
        acc + Option.value (Safe_ops.json_int_opt "output_tokens" e.detail) ~default:0)
      0
      turn_events
  in
  let total_cost_usd =
    List.fold_left
      (fun acc e ->
        acc
        +. Option.value (Safe_ops.json_float_opt "cost_usd" e.detail) ~default:0.0)
      0.0
      turn_events
  in
  (* Active duration: time between first and last event *)
  let active_duration_minutes =
    match (events, List.rev events) with
    | first :: _, last :: _ ->
        let diff = last.ts -. first.ts in
        Float.round (diff /. 60.0)
    | _ -> 0.0
  in
  let since_iso = Masc_domain.iso8601_of_unix_seconds cutoff in
  let now_iso = Masc_domain.now_iso () in
  `Assoc
    [
      ("dashboard_surface", `String dashboard_surface);
      ("source", `String dashboard_source);
      ("retention", dashboard_retention_json);
      ("generated_at_iso", `String now_iso);
      ("agent", `String agent_name);
      ( "period",
        `Assoc [ ("from", `String since_iso); ("to", `String now_iso) ] );
      ("events", `List (List.map event_to_json events));
      ( "summary",
        `Assoc
          [
            ("tasks_completed", `Int tasks_completed);
            ("tasks_claimed", `Int tasks_claimed);
            ("messages_sent", `Int messages_sent);
            ("tool_calls", `Int tool_calls);
            ("chat_messages", `Int chat_messages);
            ("turns_completed", `Int turns_completed);
            ("total_input_tokens", `Int total_input_tokens);
            ("total_output_tokens", `Int total_output_tokens);
            ("total_cost_usd", `Float total_cost_usd);
            ("active_duration_minutes", `Float active_duration_minutes);
            ("total_events", `Int (List.length events));
          ] );
    ]

(* Schema for MCP tool registration *)
let schemas : Masc_domain.tool_schema list =
  [
    {
      name = "masc_agent_timeline";
      description =
        "Unified timeline of an agent's activity in the currently selected workspace \
         across tasks, messages, and joins.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "agent_name",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Agent name to query");
                      ] );
                  ( "since_hours",
                    `Assoc
                      [
                        ("type", `String "number");
                        ( "description",
                          `String "Look back N hours (default: 24)" );
                      ] );
                  ( "limit",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ( "description",
                          `String "Max events to return (default: 50)" );
                      ] );
                  ( "include_tasks",
                    `Assoc
                      [
                        ("type", `String "boolean");
                        ( "description",
                          `String
                            "Include task state changes (default: true)" );
                      ] );
                  ( "include_board",
                    `Assoc
                      [
                        ("type", `String "boolean");
                        ( "description",
                          `String
                            "Include board activity (default: false, \
                             reserved)" );
                      ] );
                  ( "include_tool_calls",
                    `Assoc
                      [
                        ("type", `String "boolean");
                        ( "description",
                          `String
                            "Include tool call events from Activity Graph \
                             (default: true)" );
                      ] );
                ] );
            ("required", `List [ `String "agent_name" ]);
          ];
    };
  ]

(* RFC-0189 PR-1b.13 — typed result. Caller-input violation
   ("agent_name is required") tagged [Workflow_rejection]; success
   carries the [build_timeline] [Yojson.Safe.t] envelope as
   [~data:json] first-class (drops the [Yojson.Safe.to_string]
   round-trip). *)

let handle_agent_timeline ?load_chat ~tool_name ~start_time (ctx : context) args
  : Tool_result.result
  =
  let agent_name = get_string args "agent_name" "" in
  if String.length agent_name = 0 then
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      "agent_name is required"
  else
    let since_hours = get_float args "since_hours" 24.0 in
    let limit = get_int args "limit" 50 in
    let include_tasks = get_bool args "include_tasks" true in
    let include_board = get_bool args "include_board" false in
    let include_tool_calls = get_bool args "include_tool_calls" true in
    let json =
      build_timeline ?load_chat ctx.config ~agent_name ~since_hours ~limit
        ~include_tasks ~include_board ~include_tool_calls
    in
    Tool_result.make_ok ~tool_name ~start_time ~data:json ()

(* Dispatch routes by tool name and threads [load_chat] to the handler; the
   timeline read and its telemetry live in the handler / build path, not in
   this pure router.
   TEL-OK: pure dispatch router, delegates the significant action (and its
   telemetry) to [handle_agent_timeline]; no action of its own to instrument. *)
let dispatch ?load_chat (ctx : context) ~name ~args : Tool_result.result option =
  let start = Time_compat.now () in
  match name with
  | "masc_agent_timeline" ->
      Some
        (handle_agent_timeline ?load_chat ~tool_name:name ~start_time:start ctx
           args)
  | _ -> None

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let () =
  List.iter
    (fun (s : Masc_domain.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_agent_timeline
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ()))
    schemas
