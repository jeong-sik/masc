(** Reputation_ledger_v2 — Append-only event ledger for v2 agent accountability.

    Storage layout: [.masc/reputation_v2/YYYY-MM/DD.jsonl]
    Each line is a self-describing JSON object with an [event_type] discriminator.

    @since v2 Accountability & Reputation Roadmap
*)

(** {1 Types} *)

type error_kind = Error_kind of string

let error_kind_of_string value = Error_kind value
let error_kind_to_string (Error_kind value) = value

type tool_outcome_event = {
  agent_id : string;
  tool_name : string;
  success : bool;
  error_kind : error_kind option;
  raw_trace_run_id : string option;
  timestamp : float;
}

type goal_completion_event = {
  agent_id : string;
  task_id : string;
  task_title : string;
  completed_within_budget : bool;
  on_topic : bool;
  raw_trace_run_id : string option;
  timestamp : float;
}

type safety_violation_event = {
  agent_id : string;
  violation_kind : string;
  tool_name : string option;
  raw_trace_run_id : string option;
  timestamp : float;
}

type ledger_event =
  | Tool_outcome of tool_outcome_event
  | Goal_completion of goal_completion_event
  | Safety_violation of safety_violation_event

(** {1 Internal helpers} *)

let store_cache : (string, Dated_jsonl.t) Hashtbl.t = Hashtbl.create 4
let store_cache_mu = Eio.Mutex.create ()

let ledger_dir base_path =
  Filename.concat (Common.masc_dir_from_base_path ~base_path) "reputation_v2"

let get_store (config : Coord.config) : Dated_jsonl.t =
  let base_path = config.base_path in
  Eio.Mutex.use_rw ~protect:true store_cache_mu (fun () ->
    match Hashtbl.find_opt store_cache base_path with
    | Some store -> store
    | None ->
        let store = Dated_jsonl.create ~base_dir:(ledger_dir base_path) () in
        Hashtbl.replace store_cache base_path store;
        store)

let event_date_string ts =
  let tm = Unix.gmtime ts in
  Printf.sprintf "%04d-%02d-%02d"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday

let opt_string_field key = function
  | Some s ->
      let trimmed = String.trim s in
      if trimmed <> "" then [ (key, `String trimmed) ] else []
  | None -> []

(** {1 JSON serialization} *)

let tool_outcome_to_json (e : tool_outcome_event) : Yojson.Safe.t =
  `Assoc (
    [ ("event_type", `String "tool_outcome")
    ; ("agent_id", `String e.agent_id)
    ; ("tool_name", `String e.tool_name)
    ; ("success", `Bool e.success)
    ; ("ts", `Float e.timestamp)
    ; ("ts_iso", `String (Types.iso8601_of_unix_seconds e.timestamp))
    ]
    @ opt_string_field "error_kind"
        (Option.map error_kind_to_string e.error_kind)
    @ opt_string_field "raw_trace_run_id" e.raw_trace_run_id)

let goal_completion_to_json (e : goal_completion_event) : Yojson.Safe.t =
  `Assoc (
    [ ("event_type", `String "goal_completion")
    ; ("agent_id", `String e.agent_id)
    ; ("task_id", `String e.task_id)
    ; ("task_title", `String e.task_title)
    ; ("completed_within_budget", `Bool e.completed_within_budget)
    ; ("on_topic", `Bool e.on_topic)
    ; ("ts", `Float e.timestamp)
    ; ("ts_iso", `String (Types.iso8601_of_unix_seconds e.timestamp))
    ]
    @ opt_string_field "raw_trace_run_id" e.raw_trace_run_id)

let safety_violation_to_json (e : safety_violation_event) : Yojson.Safe.t =
  `Assoc (
    [ ("event_type", `String "safety_violation")
    ; ("agent_id", `String e.agent_id)
    ; ("violation_kind", `String e.violation_kind)
    ; ("ts", `Float e.timestamp)
    ; ("ts_iso", `String (Types.iso8601_of_unix_seconds e.timestamp))
    ]
    @ opt_string_field "tool_name" e.tool_name
    @ opt_string_field "raw_trace_run_id" e.raw_trace_run_id)

let ledger_event_to_json = function
  | Tool_outcome e -> tool_outcome_to_json e
  | Goal_completion e -> goal_completion_to_json e
  | Safety_violation e -> safety_violation_to_json e

let ledger_event_of_json json : ledger_event option =
  match Safe_ops.json_string_opt "event_type" json with
  | Some "tool_outcome" ->
    let agent_id = Safe_ops.json_string ~default:"" "agent_id" json in
    let tool_name = Safe_ops.json_string ~default:"" "tool_name" json in
    let ts = Safe_ops.json_float ~default:0.0 "ts" json in
    if agent_id = "" || tool_name = "" || ts = 0.0 then None
    else
      Some (Tool_outcome {
        agent_id;
        tool_name;
        success = Safe_ops.json_bool ~default:false "success" json;
        error_kind =
          Option.map error_kind_of_string
            (Safe_ops.json_string_opt "error_kind" json);
        raw_trace_run_id = Safe_ops.json_string_opt "raw_trace_run_id" json;
        timestamp = ts;
      })
  | Some "goal_completion" ->
    let agent_id = Safe_ops.json_string ~default:"" "agent_id" json in
    let task_id = Safe_ops.json_string ~default:"" "task_id" json in
    let ts = Safe_ops.json_float ~default:0.0 "ts" json in
    if agent_id = "" || task_id = "" || ts = 0.0 then None
    else
      Some (Goal_completion {
        agent_id;
        task_id;
        task_title = Safe_ops.json_string ~default:"" "task_title" json;
        completed_within_budget = Safe_ops.json_bool ~default:true "completed_within_budget" json;
        on_topic = Safe_ops.json_bool ~default:true "on_topic" json;
        raw_trace_run_id = Safe_ops.json_string_opt "raw_trace_run_id" json;
        timestamp = ts;
      })
  | Some "safety_violation" ->
    let agent_id = Safe_ops.json_string ~default:"" "agent_id" json in
    let violation_kind = Safe_ops.json_string ~default:"" "violation_kind" json in
    let ts = Safe_ops.json_float ~default:0.0 "ts" json in
    if agent_id = "" || violation_kind = "" || ts = 0.0 then None
    else
      Some (Safety_violation {
        agent_id;
        violation_kind;
        tool_name = Safe_ops.json_string_opt "tool_name" json;
        raw_trace_run_id = Safe_ops.json_string_opt "raw_trace_run_id" json;
        timestamp = ts;
      })
  | _ -> None

(** {1 Emitters} *)

let append_event (config : Coord.config) (event : ledger_event) =
  Dated_jsonl.append (get_store config) (ledger_event_to_json event)

let emit_tool_outcome config ~agent_id ~tool_name ~success
    ?error_kind ?raw_trace_run_id () =
  if String.trim agent_id = "" then ()
  else
    let ts = Time_compat.now () in
    append_event config
      (Tool_outcome { agent_id; tool_name; success; error_kind;
                      raw_trace_run_id; timestamp = ts })

let emit_goal_completion config ~agent_id ~task_id ~task_title
    ~completed_within_budget ~on_topic ?raw_trace_run_id () =
  if String.trim agent_id = "" then ()
  else
    let ts = Time_compat.now () in
    append_event config
      (Goal_completion { agent_id; task_id; task_title;
                         completed_within_budget; on_topic;
                         raw_trace_run_id; timestamp = ts })

let emit_safety_violation config ~agent_id ~violation_kind
    ?tool_name ?raw_trace_run_id () =
  if String.trim agent_id = "" then ()
  else
    let ts = Time_compat.now () in
    append_event config
      (Safety_violation { agent_id; violation_kind; tool_name;
                          raw_trace_run_id; timestamp = ts })

(** {1 Readers} *)

let read_events_for_agent (config : Coord.config) ~agent_id ~window_days
    : ledger_event list =
  if String.trim agent_id = "" then []
  else begin
    let now = Time_compat.now () in
    let since = event_date_string (now -. (float_of_int window_days *. 86400.0)) in
    let until = event_date_string now in
    let store = get_store config in
    Dated_jsonl.read_range store ~since ~until
    |> List.filter_map ledger_event_of_json
    |> List.filter (fun ev ->
        let ev_agent =
          match ev with
          | Tool_outcome e -> e.agent_id
          | Goal_completion e -> e.agent_id
          | Safety_violation e -> e.agent_id
        in
        ev_agent = agent_id)
  end

(** {1 Aggregate metrics} *)

type agent_ledger_metrics = {
  tool_calls : int;
  tool_successes : int;
  goal_completions : int;
  goal_adherent_completions : int;
  safety_violations : int;
  execution_reliability : float;
  goal_adherence : float;
  safety_compliance : float;
}

let default_ledger_metrics : agent_ledger_metrics =
  { tool_calls = 0; tool_successes = 0;
    goal_completions = 0; goal_adherent_completions = 0;
    safety_violations = 0;
    execution_reliability = 1.0;
    goal_adherence = 1.0;
    safety_compliance = 1.0 }

let clamp01 v = Float.max 0.0 (Float.min 1.0 v)

let compute_ledger_metrics (config : Coord.config) ~agent_id ~window_days
    : agent_ledger_metrics =
  let events = read_events_for_agent config ~agent_id ~window_days in
  let tool_calls = ref 0 in
  let tool_successes = ref 0 in
  let goal_completions = ref 0 in
  let goal_adherent = ref 0 in
  let safety_violations = ref 0 in
  List.iter (function
    | Tool_outcome e ->
        incr tool_calls;
        if e.success then incr tool_successes
    | Goal_completion e ->
        incr goal_completions;
        if e.completed_within_budget && e.on_topic then incr goal_adherent
    | Safety_violation _ ->
        incr safety_violations)
    events;
  let execution_reliability =
    if !tool_calls > 0 then
      float_of_int !tool_successes /. float_of_int !tool_calls
    else 1.0
  in
  let goal_adherence =
    if !goal_completions > 0 then
      float_of_int !goal_adherent /. float_of_int !goal_completions
    else 1.0
  in
  (* Safety compliance: 1.0 - penalty.  Each violation subtracts 0.2,
     capped at 1.0 penalty so the score floors at 0.0. *)
  let safety_compliance =
    clamp01 (1.0 -. (0.2 *. float_of_int !safety_violations))
  in
  { tool_calls = !tool_calls;
    tool_successes = !tool_successes;
    goal_completions = !goal_completions;
    goal_adherent_completions = !goal_adherent;
    safety_violations = !safety_violations;
    execution_reliability;
    goal_adherence;
    safety_compliance }
