(** Tool_audit - Audit query and statistics handlers *)

open Tool_args

type context = {
  config: Room.config;
}

type audit_event = {
  timestamp: float;
  agent: string;
  event_type: string;
  success: bool;
  detail: string option;
  details: Yojson.Safe.t option;
}

let has_prefix ~prefix value =
  let prefix_len = String.length prefix in
  String.length value >= prefix_len
  && String.sub value 0 prefix_len = prefix

let normalize_event_type value =
  if has_prefix ~prefix:"tool_call:" value then
    "tool_call"
  else
    value

let details_option = function
  | `Null -> None
  | json -> Some json

let detail_string_of_details = function
  | `String value when String.trim value <> "" -> Some value
  | _ -> None

(* Convert audit event to JSON *)
let audit_event_to_json (e : audit_event) : Yojson.Safe.t =
  `Assoc [
    ("timestamp", `Float e.timestamp);
    ("agent", `String e.agent);
    ("event_type", `String e.event_type);
    ("success", `Bool e.success);
    ("detail", Json_util.string_opt_to_json e.detail);
    ("details", match e.details with Some json -> json | None -> `Null);
  ]

(* Read audit events since given timestamp from the canonical date-split audit store. *)
let read_audit_events (config : Room.config) ~since : audit_event list =
  Audit_log.read_entries ~n:100_000 config
  |> List.filter (fun (entry : Audit_log.audit_entry) -> entry.timestamp >= since)
  |> List.map (fun (entry : Audit_log.audit_entry) ->
         let details = details_option entry.details in
         let detail =
           match detail_string_of_details entry.details with
           | Some value -> Some value
           | None ->
               (match entry.outcome with
                | Audit_log.Failure reason -> Some reason
                | Audit_log.Success -> None)
         in
         {
           timestamp = entry.timestamp;
           agent = entry.agent_id;
           event_type =
             normalize_event_type (Audit_log.action_to_string entry.action);
           success =
             (match entry.outcome with
              | Audit_log.Success -> true
              | Audit_log.Failure _ -> false);
           detail;
           details;
         })

(* Handle masc_audit_query *)
let handle_audit_query ctx args =
  let agent_filter = get_string_opt args "agent" in
  let event_type = get_string args "event_type" "all" in
  let limit = get_int args "limit" 50 in
  let since_hours = get_float args "since_hours" 24.0 in
  let since = Time_compat.now () -. (since_hours *. 3600.0) in
  let events = read_audit_events ctx.config ~since in
  let filtered =
    events
    |> List.filter (fun e ->
        match agent_filter with
        | Some a -> e.agent = a
        | None -> true)
    |> List.filter (fun e ->
        if event_type = "all" then true
        else e.event_type = normalize_event_type event_type)
    (* Sort newest-first so limit returns the most recent events *)
    |> List.sort (fun a b -> Float.compare b.timestamp a.timestamp)
  in
  let limited =
    let rec take n xs =
      match xs with
      | [] -> []
      | _ when n <= 0 -> []
      | x :: rest -> x :: take (n - 1) rest
    in
    take limit filtered
  in
  let json = `Assoc [
    ("count", `Int (List.length limited));
    ("events", `List (List.map audit_event_to_json limited));
  ] in
  (true, Yojson.Safe.pretty_to_string json)

(* Handle masc_audit_stats *)
let handle_audit_stats ctx args =
  let agent_filter = get_string_opt args "agent" in
  let max_agents = get_int args "limit" 50 in
  let since = Time_compat.now () -. (24.0 *. 3600.0) in
  let events = read_audit_events ctx.config ~since in
  let all_agents =
    let from_events = List.map (fun e -> e.agent) events in
    let from_metrics = Metrics_store_eio.get_all_agents ctx.config in
    let combined = from_events @ from_metrics in
    List.sort_uniq String.compare combined
  in
  let agents = match agent_filter with
    | Some a -> [a]
    | None -> all_agents
  in
  let total_agent_count = List.length agents in
  (* Truncate to max_agents to prevent oversized responses *)
  let truncated = total_agent_count > max_agents in
  let agents =
    let rec take n xs = match xs with
      | [] -> []
      | _ when n <= 0 -> []
      | x :: rest -> x :: take (n - 1) rest
    in
    take max_agents agents
  in
  let stats_for agent_id =
    let agent_events = List.filter (fun e -> e.agent = agent_id) events in
    let count_type t =
      let normalized = normalize_event_type t in
      List.fold_left
        (fun acc e -> if e.event_type = normalized then acc + 1 else acc)
        0 agent_events
    in
    let auth_success = count_type "auth_success" in
    let auth_failure = count_type "auth_failure" in
    let anomaly = count_type "anomaly_detected" in
    let violations = count_type "security_violation" in
    let tool_calls = count_type "tool_call" in
    let auth_total = auth_success + auth_failure in
    let auth_rate =
      if auth_total = 0 then `Null
      else `Float (float_of_int auth_success /. float_of_int auth_total)
    in
    let task_rate =
      match Metrics_store_eio.calculate_agent_metrics ctx.config ~agent_id ~days:7 with
      | Some m -> `Float m.Metrics_store_eio.task_completion_rate
      | None -> `Null
    in
    `Assoc [
      ("agent_id", `String agent_id);
      ("auth_success", `Int auth_success);
      ("auth_failure", `Int auth_failure);
      ("auth_success_rate", auth_rate);
      ("anomaly_count", `Int anomaly);
      ("security_violations", `Int violations);
      ("tool_calls", `Int tool_calls);
      ("task_completion_rate", task_rate);
    ]
  in
  let json = `Assoc [
    ("count", `Int (List.length agents));
    ("total_agents", `Int total_agent_count);
    ("truncated", `Bool truncated);
    ("agents", `List (List.map stats_for agents));
  ] in
  (true, Yojson.Safe.pretty_to_string json)

(** {1 Governance Report} *)

type agent_summary = {
  agent_id : string;
  action_count : int;
  action_types : (string * int) list;
  total_cost : float;
  total_tokens : int;
  failure_rate : float;
}

type governance_report = {
  period_start : string;
  period_end : string;
  agents : agent_summary list;
  total_actions : int;
  total_cost : float;
  total_tokens : int;
  overall_failure_rate : float;
}

let governance_summary ?(since="") ?(until_time="") (entries : Audit_log.audit_entry list) : governance_report =
  (* Filter by time range if provided *)
  let since_ts = if since = "" then 0.0
    else (try float_of_string since with Failure _ -> 0.0)
  in
  let until_ts = if until_time = "" then infinity
    else (try float_of_string until_time with Failure _ -> infinity)
  in
  let filtered = List.filter (fun (e : Audit_log.audit_entry) ->
    e.timestamp >= since_ts && e.timestamp <= until_ts
  ) entries in
  (* Group by agent_id *)
  let agent_ids =
    List.map (fun (e : Audit_log.audit_entry) -> e.agent_id) filtered
    |> List.sort_uniq String.compare
  in
  let summarize_agent agent_id =
    let agent_entries = List.filter (fun (e : Audit_log.audit_entry) ->
      e.agent_id = agent_id
    ) filtered in
    let action_count = List.length agent_entries in
    (* Count actions by type *)
    let type_counts = Hashtbl.create 16 in
    List.iter (fun (e : Audit_log.audit_entry) ->
      let key = Audit_log.action_to_string e.action in
      let cur = try Hashtbl.find type_counts key with Not_found -> 0 in
      Hashtbl.replace type_counts key (cur + 1)
    ) agent_entries;
    let action_types = Hashtbl.fold (fun k v acc -> (k, v) :: acc) type_counts [] in
    let action_types = List.sort (fun (a, _) (b, _) -> String.compare a b) action_types in
    (* Sum costs *)
    let total_cost = List.fold_left (fun acc (e : Audit_log.audit_entry) ->
      acc +. (Option.value e.cost_estimate ~default:0.0)
    ) 0.0 agent_entries in
    (* Sum tokens *)
    let total_tokens = List.fold_left (fun acc (e : Audit_log.audit_entry) ->
      acc + (Option.value e.token_count ~default:0)
    ) 0 agent_entries in
    (* Calculate failure rate *)
    let failure_count = List.fold_left (fun acc (e : Audit_log.audit_entry) ->
      match e.outcome with
      | Audit_log.Failure _ -> acc + 1
      | Audit_log.Success -> acc
    ) 0 agent_entries in
    let failure_rate =
      if action_count = 0 then 0.0
      else float_of_int failure_count /. float_of_int action_count
    in
    { agent_id; action_count; action_types; total_cost; total_tokens; failure_rate }
  in
  let agents = List.map summarize_agent agent_ids in
  let total_actions = List.fold_left (fun acc (a : agent_summary) -> acc + a.action_count) 0 agents in
  let total_cost = List.fold_left (fun acc (a : agent_summary) -> acc +. a.total_cost) 0.0 agents in
  let total_tokens = List.fold_left (fun acc (a : agent_summary) -> acc + a.total_tokens) 0 agents in
  let total_failures = List.fold_left (fun acc (e : Audit_log.audit_entry) ->
    match e.outcome with
    | Audit_log.Failure _ -> acc + 1
    | Audit_log.Success -> acc
  ) 0 filtered in
  let overall_failure_rate =
    if total_actions = 0 then 0.0
    else float_of_int total_failures /. float_of_int total_actions
  in
  let period_start = if since <> "" then since
    else match filtered with
      | [] -> ""
      | first :: _ -> Printf.sprintf "%.0f" first.timestamp
  in
  let period_end = if until_time <> "" then until_time
    else match List.rev filtered with
      | [] -> ""
      | last :: _ -> Printf.sprintf "%.0f" last.timestamp
  in
  { period_start; period_end; agents; total_actions; total_cost; total_tokens; overall_failure_rate }

let agent_summary_to_json (a : agent_summary) : Yojson.Safe.t =
  `Assoc [
    ("agent_id", `String a.agent_id);
    ("action_count", `Int a.action_count);
    ("action_types", `Assoc (List.map (fun (k, v) -> (k, `Int v)) a.action_types));
    ("total_cost", `Float a.total_cost);
    ("total_tokens", `Int a.total_tokens);
    ("failure_rate", `Float a.failure_rate);
  ]

let report_to_json (report : governance_report) : Yojson.Safe.t =
  `Assoc [
    ("period_start", `String report.period_start);
    ("period_end", `String report.period_end);
    ("agents", `List (List.map agent_summary_to_json report.agents));
    ("total_actions", `Int report.total_actions);
    ("total_cost", `Float report.total_cost);
    ("total_tokens", `Int report.total_tokens);
    ("overall_failure_rate", `Float report.overall_failure_rate);
  ]

(* Handle masc_governance_report *)
let handle_governance_report ctx args =
  let since = get_string args "since" "" in
  let until_time = get_string args "until" "" in
  let entries = Audit_log.read_entries ctx.config in
  let report = governance_summary ~since ~until_time entries in
  let json = report_to_json report in
  (true, Yojson.Safe.pretty_to_string json)

(* Handle masc_audit_trail — query audit entries linked by trace_id *)
let handle_audit_trail ctx args =
  let trace_id = get_string_opt args "trace_id" in
  let agent_filter = get_string_opt args "agent_id" in
  let action_type_filter = get_string_opt args "action_type" in
  let since_hours = get_float args "since_hours" 168.0 in
  let limit = get_int args "limit" 100 in
  let since_ts = Time_compat.now () -. (since_hours *. 3600.0) in
  let entries = Audit_log.read_entries ctx.config in
  let filtered =
    entries
    |> List.filter (fun (e : Audit_log.audit_entry) -> e.timestamp >= since_ts)
    |> List.filter (fun (e : Audit_log.audit_entry) ->
        match trace_id with
        | Some tid -> e.trace_id = Some tid
        | None -> true)
    |> List.filter (fun (e : Audit_log.audit_entry) ->
        match agent_filter with
        | Some a -> String.equal e.agent_id a
        | None -> true)
    |> List.filter (fun (e : Audit_log.audit_entry) ->
        match action_type_filter with
        | Some at -> String.equal (Audit_log.action_to_string e.action) at
        | None -> true)
    |> List.sort (fun (a : Audit_log.audit_entry) (b : Audit_log.audit_entry) ->
        Float.compare b.timestamp a.timestamp)
  in
  let limited =
    let rec take n xs = match xs with
      | [] -> []
      | _ when n <= 0 -> []
      | x :: rest -> x :: take (n - 1) rest
    in
    take limit filtered
  in
  let json = `Assoc [
    ("count", `Int (List.length limited));
    ("trace_id_filter", Json_util.string_opt_to_json trace_id);
    ("entries", `List (List.map Audit_log.entry_to_json limited));
  ] in
  (true, Yojson.Safe.pretty_to_string json)

(* Dispatch handler *)
let dispatch ctx ~name ~args =
  match name with
  | "masc_audit_query" -> Some (handle_audit_query ctx args)
  | "masc_audit_stats" -> Some (handle_audit_stats ctx args)
  | "masc_governance_report" -> Some (handle_governance_report ctx args)
  | "masc_audit_trail" -> Some (handle_audit_trail ctx args)
  | _ -> None

let schemas : Types.tool_schema list = [
  (* masc_audit_query *)
  {
    name = "masc_audit_query";
    description = "Search audit logs for security events: auth success/failure, anomalies, violations, tool calls. \
Use when investigating suspicious activity, verifying trust, or debugging collaboration issues. \
Pair with masc_audit_stats for aggregate trust metrics, masc_auth_list for credential status.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by agent name (optional)");
        ]);
        ("event_type", `Assoc [
          ("type", `String "string");
          ("enum", `List [
            `String "auth_success";
            `String "auth_failure";
            `String "anomaly_detected";
            `String "security_violation";
            `String "join";
            `String "leave";
            `String "claim_task";
            `String "start_task";
            `String "done_task";
            `String "cancel_task";
            `String "release_task";
            `String "tool_call";
            `String "all"
          ]);
          ("description", `String "Filter by event type (default: all)");
          ("default", `String "all");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum events to return (default: 50)");
          ("default", `Int 50);
        ]);
        ("since_hours", `Assoc [
          ("type", `String "number");
          ("description", `String "Only show events from last N hours (default: 24)");
          ("default", `Float 24.0);
        ]);
      ]);
    ];
  };

  (* masc_audit_stats *)
  {
    name = "masc_audit_stats";
    description = "Get aggregate security and trust metrics per agent: auth success rate, anomaly count, task completion rate. \
Use when evaluating agent reliability before delegating sensitive tasks. \
Pair with masc_audit_query for detailed event logs, masc_agent_fitness for performance scores.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Specific agent to analyze (optional, shows all if omitted)");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum number of agents to include (default: 50)");
          ("default", `Int 50);
        ]);
      ]);
    ];
  };

  (* masc_governance_report *)
  {
    name = "masc_governance_report";
    description = "Generate a governance summary report from the audit trail, aggregating per-agent action counts, cost, tokens, and failure rates. \
Use when reviewing room costs, auditing agent behavior, or preparing periodic governance summaries. \
Pair with masc_governance_set to configure audit policies, or masc_governance_status for a compact overview.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("since", `Assoc [
          ("type", `String "string");
          ("description", `String "Start of period as Unix timestamp string (optional, defaults to all time)");
        ]);
        ("until", `Assoc [
          ("type", `String "string");
          ("description", `String "End of period as Unix timestamp string (optional, defaults to now)");
        ]);
      ]);
    ];
  };

  (* masc_audit_trail *)
  {
    name = "masc_audit_trail";
    description = "Query the audit trail by trace_id to follow a governance decision chain from pending_confirm through approval or rejection. \
Use when investigating why a specific action was approved, denied, or expired. \
Pair with masc_operator_confirm to see the original pending_confirm, or masc_governance_report for aggregate views.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("trace_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Trace ID linking a governance decision chain. Returns all audit entries sharing this trace_id.");
        ]);
        ("agent_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by agent who performed the action (optional).");
        ]);
        ("action_type", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by action type string, e.g. governance_decision:confirm (optional).");
        ]);
        ("since_hours", `Assoc [
          ("type", `String "number");
          ("description", `String "Only show entries from last N hours (default: 168, i.e. 7 days).");
          ("default", `Float 168.0);
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum entries to return (default: 100).");
          ("default", `Int 100);
        ]);
      ]);
    ];
  };

]
