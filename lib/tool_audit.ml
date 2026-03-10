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
}

(* Audit log path *)
let audit_log_path (config : Room.config) =
  Filename.concat (Room_utils.masc_dir config) "audit.log"

(* Convert audit event to JSON *)
let audit_event_to_json (e : audit_event) : Yojson.Safe.t =
  `Assoc [
    ("timestamp", `Float e.timestamp);
    ("agent", `String e.agent);
    ("event_type", `String e.event_type);
    ("success", `Bool e.success);
    ("detail", match e.detail with Some d -> `String d | None -> `Null);
  ]

(* Read audit events since given timestamp *)
let read_audit_events (config : Room.config) ~since : audit_event list =
  let path = audit_log_path config in
  if not (Sys.file_exists path) then []
  else
    let content = In_channel.with_open_text path In_channel.input_all in
    let lines = String.split_on_char '\n' content |> List.filter (fun s -> String.trim s <> "") in
    List.filter_map (fun line ->
      try
        let json = Yojson.Safe.from_string line in
        let module U = Yojson.Safe.Util in
        let timestamp = json |> U.member "timestamp" |> U.to_float in
        if timestamp < since then None
        else
          let agent = json |> U.member "agent" |> U.to_string in
          let event_type = json |> U.member "event_type" |> U.to_string in
          let success = json |> U.member "success" |> U.to_bool in
          let detail = json |> U.member "detail" |> U.to_string_option in
          Some { timestamp; agent; event_type; success; detail }
      with Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ -> None
    ) lines

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
        else e.event_type = event_type)
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
  let since = Time_compat.now () -. (24.0 *. 3600.0) in
  let events = read_audit_events ctx.config ~since in
  let agents =
    let from_events = List.map (fun e -> e.agent) events in
    let from_metrics = Metrics_store_eio.get_all_agents ctx.config in
    let combined = from_events @ from_metrics in
    List.sort_uniq String.compare combined
  in
  let agents = match agent_filter with
    | Some a -> [a]
    | None -> agents
  in
  let stats_for agent_id =
    let agent_events = List.filter (fun e -> e.agent = agent_id) events in
    let count_type t =
      List.fold_left (fun acc e -> if e.event_type = t then acc + 1 else acc) 0 agent_events
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

(* Dispatch handler *)
let dispatch ctx ~name ~args =
  match name with
  | "masc_audit_query" -> Some (handle_audit_query ctx args)
  | "masc_audit_stats" -> Some (handle_audit_stats ctx args)
  | "masc_governance_report" -> Some (handle_governance_report ctx args)
  | _ -> None
