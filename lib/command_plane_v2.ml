module U = Yojson.Safe.Util

let ( let* ) = Result.bind

type unit_kind =
  | Company
  | Platoon
  | Squad
  | Agent_unit

type policy_envelope = {
  policy_class : string;
  approval_class : string;
  tool_allowlist : string list;
  model_allowlist : string list;
  requires_human_for : string list;
  autonomy_level : string;
  escalation_timeout_sec : int;
  kill_switch : bool;
  frozen : bool;
}

type budget_envelope = {
  headcount_cap : int;
  active_operation_cap : int;
  max_cost_usd : float;
  max_tokens : int;
}

type unit_record = {
  unit_id : string;
  label : string;
  kind : unit_kind;
  parent_unit_id : string option;
  leader_id : string option;
  roster : string list;
  capability_profile : string list;
  policy : policy_envelope;
  budget : budget_envelope;
  source : string;
  created_at : string;
  updated_at : string;
}

type operation_status =
  | Planned
  | Active
  | Paused
  | Completed
  | Cancelled
  | Failed

type operation_record = {
  operation_id : string;
  objective : string;
  assigned_unit_id : string;
  autonomy_level : string;
  policy_class : string;
  budget_class : string;
  detachment_session_id : string option;
  trace_id : string;
  checkpoint_ref : string option;
  active_goal_ids : string list;
  note : string option;
  created_by : string;
  source : string;
  status : operation_status;
  created_at : string;
  updated_at : string;
}

type event_record = {
  event_id : string;
  trace_id : string;
  event_type : string;
  operation_id : string option;
  unit_id : string option;
  actor : string option;
  source : string;
  ts : string;
  detail : Yojson.Safe.t;
}

type detachment_record = {
  detachment_id : string;
  operation_id : string;
  assigned_unit_id : string;
  leader_id : string option;
  roster : string list;
  session_id : string option;
  checkpoint_ref : string option;
  runtime_kind : string option;
  runtime_ref : string option;
  source : string;
  status : string;
  last_event_at : string option;
  last_progress_at : string option;
  heartbeat_deadline : string option;
  created_at : string;
  updated_at : string;
}

type policy_decision_record = {
  decision_id : string;
  trace_id : string;
  requested_action : string;
  scope_type : string;
  scope_id : string;
  operation_id : string option;
  target_unit_id : string option;
  requested_by : string;
  status : string;
  reason : string option;
  source : string;
  detail : Yojson.Safe.t;
  created_at : string;
  decided_at : string option;
  expires_at : string option;
}

type topology_summary = {
  total_units : int;
  company_count : int;
  platoon_count : int;
  squad_count : int;
  leaf_agent_unit_count : int;
  live_agent_count : int;
  managed_unit_count : int;
  active_operation_count : int;
}

let control_plane_dir config =
  Filename.concat (Room.masc_dir config) "control-plane"

let units_path config =
  Filename.concat (control_plane_dir config) "units.json"

let operations_path config =
  Filename.concat (control_plane_dir config) "operations.json"

let events_path config =
  Filename.concat (control_plane_dir config) "events.jsonl"

let detachments_path config =
  Filename.concat (control_plane_dir config) "detachments.json"

let decisions_path config =
  Filename.concat (control_plane_dir config) "decisions.json"

let traces_dir config =
  Filename.concat (control_plane_dir config) "traces"

let operator_dir config =
  Filename.concat (Room.masc_dir config) "operator"

let operator_pending_confirms_path config =
  Filename.concat (operator_dir config) "pending_confirms.json"

let operator_action_log_path config =
  Filename.concat (operator_dir config) "action_log.jsonl"

let swarm_path config =
  Filename.concat config.Room.base_path ".masc/swarm.json"

let string_starts_with s prefix =
  let len_s = String.length s in
  let len_p = String.length prefix in
  len_s >= len_p && String.sub s 0 len_p = prefix

let trim s = String.trim s

let nonempty_string = function
  | Some raw ->
      let value = trim raw in
      if value = "" then None else Some value
  | None -> None

let dedup_strings xs =
  let rec loop seen acc = function
    | [] -> List.rev acc
    | x :: rest ->
        if List.mem x seen then
          loop seen acc rest
        else
          loop (x :: seen) (x :: acc) rest
  in
  loop [] [] xs

let filter_nonempty_strings xs =
  xs
  |> List.filter_map (fun raw ->
         let value = trim raw in
         if value = "" then None else Some value)
  |> dedup_strings

let option_first_some left right =
  match left with
  | Some _ -> left
  | None -> right

let list_hd_opt = function
  | head :: _ -> Some head
  | [] -> None

let safe_slug raw =
  let filename = Room_utils.safe_filename raw in
  let lowered =
    String.lowercase_ascii filename
    |> String.map (fun c -> if c = '.' then '-' else c)
  in
  let rec collapse_dash acc = function
    | [] -> acc
    | '-' :: '-' :: rest -> collapse_dash acc ('-' :: rest)
    | ch :: rest -> collapse_dash (ch :: acc) rest
  in
  let collapsed =
    lowered |> String.to_seq |> List.of_seq |> collapse_dash [] |> List.rev
    |> List.to_seq |> String.of_seq
  in
  let normalized = trim collapsed in
  if normalized = "" then "auto" else normalized

let json_list_of_strings xs =
  `List (List.map (fun value -> `String value) xs)

let get_string_opt json key =
  json |> U.member key |> U.to_string_option |> nonempty_string

let get_string_default json key default =
  match get_string_opt json key with
  | Some value -> value
  | None -> default

let get_int_default json key default =
  match U.member key json with
  | `Int value -> value
  | `Intlit value -> (try int_of_string value with _ -> default)
  | _ -> default

let get_float_default json key default =
  match U.member key json with
  | `Float value -> value
  | `Int value -> float_of_int value
  | `Intlit value -> (try float_of_string value with _ -> default)
  | _ -> default

let get_bool_default json key default =
  match U.member key json with
  | `Bool value -> value
  | _ -> default

let get_string_list json key =
  match U.member key json with
  | `List xs ->
      xs
      |> List.filter_map (function
             | `String value -> nonempty_string (Some value)
             | _ -> None)
      |> dedup_strings
  | _ -> []

let string_of_unit_kind = function
  | Company -> "company"
  | Platoon -> "platoon"
  | Squad -> "squad"
  | Agent_unit -> "agent"

let unit_kind_of_string = function
  | "company" -> Some Company
  | "platoon" -> Some Platoon
  | "squad" -> Some Squad
  | "agent" -> Some Agent_unit
  | _ -> None

let string_of_operation_status = function
  | Planned -> "planned"
  | Active -> "active"
  | Paused -> "paused"
  | Completed -> "completed"
  | Cancelled -> "cancelled"
  | Failed -> "failed"

let operation_status_of_string = function
  | "planned" -> Some Planned
  | "active" -> Some Active
  | "paused" -> Some Paused
  | "completed" -> Some Completed
  | "cancelled" -> Some Cancelled
  | "failed" -> Some Failed
  | _ -> None

let kind_order = function
  | Company -> 0
  | Platoon -> 1
  | Squad -> 2
  | Agent_unit -> 3

let default_policy kind =
  match kind with
  | Company ->
      {
        policy_class = "strategic";
        approval_class = "strict";
        tool_allowlist = [];
        model_allowlist = [];
        requires_human_for =
          [ "cross_platoon_rebalance"; "budget_class_change"; "kill_switch" ];
        autonomy_level = "L5_Independent";
        escalation_timeout_sec = 1800;
        kill_switch = false;
        frozen = false;
      }
  | Platoon ->
      {
        policy_class = "tactical";
        approval_class = "strict";
        tool_allowlist = [];
        model_allowlist = [];
        requires_human_for = [ "cross_squad_rebalance"; "budget_burst" ];
        autonomy_level = "L4_Autonomous";
        escalation_timeout_sec = 1200;
        kill_switch = false;
        frozen = false;
      }
  | Squad ->
      {
        policy_class = "execution";
        approval_class = "guarded";
        tool_allowlist = [];
        model_allowlist = [];
        requires_human_for = [ "destructive_tool"; "cross_squad_escalation" ];
        autonomy_level = "L3_Guided";
        escalation_timeout_sec = 900;
        kill_switch = false;
        frozen = false;
      }
  | Agent_unit ->
      {
        policy_class = "worker";
        approval_class = "guarded";
        tool_allowlist = [];
        model_allowlist = [];
        requires_human_for = [ "destructive_tool" ];
        autonomy_level = "L2_Suggestive";
        escalation_timeout_sec = 600;
        kill_switch = false;
        frozen = false;
      }

let default_budget kind =
  match kind with
  | Company ->
      { headcount_cap = 128; active_operation_cap = 24; max_cost_usd = 50.0; max_tokens = 5_000_000 }
  | Platoon ->
      { headcount_cap = 32; active_operation_cap = 8; max_cost_usd = 15.0; max_tokens = 1_500_000 }
  | Squad ->
      { headcount_cap = 8; active_operation_cap = 3; max_cost_usd = 5.0; max_tokens = 500_000 }
  | Agent_unit ->
      { headcount_cap = 1; active_operation_cap = 1; max_cost_usd = 1.0; max_tokens = 100_000 }

let policy_to_json (policy : policy_envelope) =
  `Assoc
    [
      ("policy_class", `String policy.policy_class);
      ("approval_class", `String policy.approval_class);
      ("tool_allowlist", json_list_of_strings policy.tool_allowlist);
      ("model_allowlist", json_list_of_strings policy.model_allowlist);
      ("requires_human_for", json_list_of_strings policy.requires_human_for);
      ("autonomy_level", `String policy.autonomy_level);
      ("escalation_timeout_sec", `Int policy.escalation_timeout_sec);
      ("kill_switch", `Bool policy.kill_switch);
      ("frozen", `Bool policy.frozen);
    ]

let policy_of_json json kind =
  let defaults = default_policy kind in
  {
    policy_class = get_string_default json "policy_class" defaults.policy_class;
    approval_class = get_string_default json "approval_class" defaults.approval_class;
    tool_allowlist = get_string_list json "tool_allowlist";
    model_allowlist = get_string_list json "model_allowlist";
    requires_human_for =
      (let requested = get_string_list json "requires_human_for" in
       if requested = [] then defaults.requires_human_for else requested);
    autonomy_level = get_string_default json "autonomy_level" defaults.autonomy_level;
    escalation_timeout_sec =
      get_int_default json "escalation_timeout_sec" defaults.escalation_timeout_sec;
    kill_switch = get_bool_default json "kill_switch" defaults.kill_switch;
    frozen = get_bool_default json "frozen" defaults.frozen;
  }

let budget_to_json (budget : budget_envelope) =
  `Assoc
    [
      ("headcount_cap", `Int budget.headcount_cap);
      ("active_operation_cap", `Int budget.active_operation_cap);
      ("max_cost_usd", `Float budget.max_cost_usd);
      ("max_tokens", `Int budget.max_tokens);
    ]

let budget_of_json json kind =
  let defaults = default_budget kind in
  {
    headcount_cap = get_int_default json "headcount_cap" defaults.headcount_cap;
    active_operation_cap =
      get_int_default json "active_operation_cap" defaults.active_operation_cap;
    max_cost_usd = get_float_default json "max_cost_usd" defaults.max_cost_usd;
    max_tokens = get_int_default json "max_tokens" defaults.max_tokens;
  }

let unit_to_json (unit : unit_record) =
  `Assoc
    [
      ("unit_id", `String unit.unit_id);
      ("label", `String unit.label);
      ("kind", `String (string_of_unit_kind unit.kind));
      ( "parent_unit_id",
        match unit.parent_unit_id with Some value -> `String value | None -> `Null );
      ("leader_id", match unit.leader_id with Some value -> `String value | None -> `Null);
      ("roster", json_list_of_strings unit.roster);
      ("capability_profile", json_list_of_strings unit.capability_profile);
      ("policy", policy_to_json unit.policy);
      ("budget", budget_to_json unit.budget);
      ("source", `String unit.source);
      ("created_at", `String unit.created_at);
      ("updated_at", `String unit.updated_at);
    ]

let unit_of_json json =
  match
    (match get_string_opt json "kind" with
    | Some value -> unit_kind_of_string value
    | None -> None)
  with
  | None -> None
  | Some kind ->
      let unit_id = get_string_default json "unit_id" "" in
      let label = get_string_default json "label" "" in
      if unit_id = "" || label = "" then
        None
      else
        let policy_json =
          match U.member "policy" json with `Assoc _ as value -> value | _ -> `Assoc []
        in
        let budget_json =
          match U.member "budget" json with `Assoc _ as value -> value | _ -> `Assoc []
        in
        Some
          {
            unit_id;
            label;
            kind;
            parent_unit_id = get_string_opt json "parent_unit_id";
            leader_id = get_string_opt json "leader_id";
            roster = get_string_list json "roster";
            capability_profile = get_string_list json "capability_profile";
            policy = policy_of_json policy_json kind;
            budget = budget_of_json budget_json kind;
            source = get_string_default json "source" "managed";
            created_at = get_string_default json "created_at" (Types.now_iso ());
            updated_at = get_string_default json "updated_at" (Types.now_iso ());
          }

let operation_to_json (operation : operation_record) =
  `Assoc
    [
      ("operation_id", `String operation.operation_id);
      ("objective", `String operation.objective);
      ("assigned_unit_id", `String operation.assigned_unit_id);
      ("autonomy_level", `String operation.autonomy_level);
      ("policy_class", `String operation.policy_class);
      ("budget_class", `String operation.budget_class);
      ( "detachment_session_id",
        match operation.detachment_session_id with
        | Some value -> `String value
        | None -> `Null );
      ("trace_id", `String operation.trace_id);
      ("checkpoint_ref", match operation.checkpoint_ref with Some value -> `String value | None -> `Null);
      ("active_goal_ids", json_list_of_strings operation.active_goal_ids);
      ("note", match operation.note with Some value -> `String value | None -> `Null);
      ("created_by", `String operation.created_by);
      ("source", `String operation.source);
      ("status", `String (string_of_operation_status operation.status));
      ("created_at", `String operation.created_at);
      ("updated_at", `String operation.updated_at);
    ]

let operation_of_json json =
  match
    (match get_string_opt json "status" with
    | Some value -> operation_status_of_string value
    | None -> None)
  with
  | None -> None
  | Some status ->
      let operation_id = get_string_default json "operation_id" "" in
      let objective = get_string_default json "objective" "" in
      let assigned_unit_id = get_string_default json "assigned_unit_id" "" in
      let trace_id = get_string_default json "trace_id" "" in
      let created_by = get_string_default json "created_by" "" in
      if operation_id = "" || objective = "" || assigned_unit_id = "" || trace_id = "" || created_by = "" then
        None
      else
        Some
          {
            operation_id;
            objective;
            assigned_unit_id;
            autonomy_level = get_string_default json "autonomy_level" "L4_Autonomous";
            policy_class = get_string_default json "policy_class" "strict";
            budget_class = get_string_default json "budget_class" "standard";
            detachment_session_id = get_string_opt json "detachment_session_id";
            trace_id;
            checkpoint_ref = get_string_opt json "checkpoint_ref";
            active_goal_ids = get_string_list json "active_goal_ids";
            note = get_string_opt json "note";
            created_by;
            source = get_string_default json "source" "managed";
            status;
            created_at = get_string_default json "created_at" (Types.now_iso ());
            updated_at = get_string_default json "updated_at" (Types.now_iso ());
          }

let event_to_json (event : event_record) =
  `Assoc
    [
      ("event_id", `String event.event_id);
      ("trace_id", `String event.trace_id);
      ("event_type", `String event.event_type);
      ("operation_id", match event.operation_id with Some value -> `String value | None -> `Null);
      ("unit_id", match event.unit_id with Some value -> `String value | None -> `Null);
      ("actor", match event.actor with Some value -> `String value | None -> `Null);
      ("source", `String event.source);
      ("ts", `String event.ts);
      ("detail", event.detail);
    ]

let event_of_json json =
  match get_string_opt json "event_id", get_string_opt json "trace_id", get_string_opt json "event_type" with
  | Some event_id, Some trace_id, Some event_type ->
      let detail =
        match U.member "detail" json with
        | `Assoc _ as value -> value
        | `List _ as value -> value
        | `String _ as value -> value
        | `Int _ as value -> value
        | `Float _ as value -> value
        | `Bool _ as value -> value
        | `Null -> `Assoc []
        | value -> value
      in
      Some
        {
          event_id;
          trace_id;
          event_type;
          operation_id = get_string_opt json "operation_id";
          unit_id = get_string_opt json "unit_id";
          actor = get_string_opt json "actor";
          source = get_string_default json "source" "control_plane";
          ts = get_string_default json "ts" (Types.now_iso ());
          detail;
        }
  | _ -> None

let detachment_to_json (detachment : detachment_record) =
  `Assoc
    [
      ("detachment_id", `String detachment.detachment_id);
      ("operation_id", `String detachment.operation_id);
      ("assigned_unit_id", `String detachment.assigned_unit_id);
      ("leader_id", match detachment.leader_id with Some value -> `String value | None -> `Null);
      ("roster", json_list_of_strings detachment.roster);
      ("session_id", match detachment.session_id with Some value -> `String value | None -> `Null);
      ( "checkpoint_ref",
        match detachment.checkpoint_ref with Some value -> `String value | None -> `Null );
      ("runtime_kind", match detachment.runtime_kind with Some value -> `String value | None -> `Null);
      ("runtime_ref", match detachment.runtime_ref with Some value -> `String value | None -> `Null);
      ("source", `String detachment.source);
      ("status", `String detachment.status);
      ("last_event_at", match detachment.last_event_at with Some value -> `String value | None -> `Null);
      ("last_progress_at", match detachment.last_progress_at with Some value -> `String value | None -> `Null);
      ( "heartbeat_deadline",
        match detachment.heartbeat_deadline with Some value -> `String value | None -> `Null );
      ("created_at", `String detachment.created_at);
      ("updated_at", `String detachment.updated_at);
    ]

let detachment_of_json json =
  match get_string_opt json "detachment_id", get_string_opt json "operation_id", get_string_opt json "assigned_unit_id" with
  | Some detachment_id, Some operation_id, Some assigned_unit_id ->
      Some
        {
          detachment_id;
          operation_id;
          assigned_unit_id;
          leader_id = get_string_opt json "leader_id";
          roster = get_string_list json "roster";
          session_id = get_string_opt json "session_id";
          checkpoint_ref = get_string_opt json "checkpoint_ref";
          runtime_kind = get_string_opt json "runtime_kind";
          runtime_ref = get_string_opt json "runtime_ref";
          source = get_string_default json "source" "managed";
          status = get_string_default json "status" "active";
          last_event_at = get_string_opt json "last_event_at";
          last_progress_at = get_string_opt json "last_progress_at";
          heartbeat_deadline = get_string_opt json "heartbeat_deadline";
          created_at = get_string_default json "created_at" (Types.now_iso ());
          updated_at = get_string_default json "updated_at" (Types.now_iso ());
        }
  | _ -> None

let policy_decision_to_json (decision : policy_decision_record) =
  `Assoc
    [
      ("decision_id", `String decision.decision_id);
      ("trace_id", `String decision.trace_id);
      ("requested_action", `String decision.requested_action);
      ("scope_type", `String decision.scope_type);
      ("scope_id", `String decision.scope_id);
      ("operation_id", match decision.operation_id with Some value -> `String value | None -> `Null);
      ( "target_unit_id",
        match decision.target_unit_id with Some value -> `String value | None -> `Null );
      ("requested_by", `String decision.requested_by);
      ("status", `String decision.status);
      ("reason", match decision.reason with Some value -> `String value | None -> `Null);
      ("source", `String decision.source);
      ("detail", decision.detail);
      ("created_at", `String decision.created_at);
      ("decided_at", match decision.decided_at with Some value -> `String value | None -> `Null);
      ("expires_at", match decision.expires_at with Some value -> `String value | None -> `Null);
    ]

let policy_decision_of_json json =
  match
    get_string_opt json "decision_id",
    get_string_opt json "trace_id",
    get_string_opt json "requested_action",
    get_string_opt json "scope_type",
    get_string_opt json "scope_id",
    get_string_opt json "requested_by",
    get_string_opt json "status"
  with
  | Some decision_id, Some trace_id, Some requested_action, Some scope_type, Some scope_id, Some requested_by, Some status ->
      let detail =
        match U.member "detail" json with
        | `Assoc _ as value -> value
        | `List _ as value -> value
        | `Null -> `Assoc []
        | value -> value
      in
      Some
        {
          decision_id;
          trace_id;
          requested_action;
          scope_type;
          scope_id;
          operation_id = get_string_opt json "operation_id";
          target_unit_id = get_string_opt json "target_unit_id";
          requested_by;
          status;
          reason = get_string_opt json "reason";
          source = get_string_default json "source" "managed";
          detail;
          created_at = get_string_default json "created_at" (Types.now_iso ());
          decided_at = get_string_opt json "decided_at";
          expires_at = get_string_opt json "expires_at";
        }
  | _ -> None

let ensure_dirs config =
  Room_utils.mkdir_p (control_plane_dir config);
  Room_utils.mkdir_p (traces_dir config)

let read_units config =
  ensure_dirs config;
  if not (Room_utils.path_exists config (units_path config)) then
    []
  else
    match Room_utils.read_json_opt config (units_path config) with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "units" fields with
        | Some (`List rows) -> List.filter_map unit_of_json rows
        | _ -> [])
    | Some (`List rows) -> List.filter_map unit_of_json rows
    | _ -> []

let write_units config units =
  ensure_dirs config;
  Room_utils.write_json config (units_path config)
    (`Assoc
      [
        ("version", `String "cp-v2");
        ("updated_at", `String (Types.now_iso ()));
        ("units", `List (List.map unit_to_json units));
      ])

let read_operations config =
  ensure_dirs config;
  if not (Room_utils.path_exists config (operations_path config)) then
    []
  else
    match Room_utils.read_json_opt config (operations_path config) with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "operations" fields with
        | Some (`List rows) -> List.filter_map operation_of_json rows
        | _ -> [])
    | Some (`List rows) -> List.filter_map operation_of_json rows
    | _ -> []

let write_operations config operations =
  ensure_dirs config;
  Room_utils.write_json config (operations_path config)
    (`Assoc
      [
        ("version", `String "cp-v2");
        ("updated_at", `String (Types.now_iso ()));
        ("operations", `List (List.map operation_to_json operations));
      ])

let read_detachments config =
  ensure_dirs config;
  if not (Room_utils.path_exists config (detachments_path config)) then
    []
  else
    match Room_utils.read_json_opt config (detachments_path config) with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "detachments" fields with
        | Some (`List rows) -> List.filter_map detachment_of_json rows
        | _ -> [])
    | Some (`List rows) -> List.filter_map detachment_of_json rows
    | _ -> []

let write_detachments config detachments =
  ensure_dirs config;
  Room_utils.write_json config (detachments_path config)
    (`Assoc
      [
        ("version", `String "cp-v2");
        ("updated_at", `String (Types.now_iso ()));
        ("detachments", `List (List.map detachment_to_json detachments));
      ])

let read_policy_decisions config =
  ensure_dirs config;
  if not (Room_utils.path_exists config (decisions_path config)) then
    []
  else
    match Room_utils.read_json_opt config (decisions_path config) with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "decisions" fields with
        | Some (`List rows) -> List.filter_map policy_decision_of_json rows
        | _ -> [])
    | Some (`List rows) -> List.filter_map policy_decision_of_json rows
    | _ -> []

let write_policy_decisions config decisions =
  ensure_dirs config;
  Room_utils.write_json config (decisions_path config)
    (`Assoc
      [
        ("version", `String "cp-v2");
        ("updated_at", `String (Types.now_iso ()));
        ("decisions", `List (List.map policy_decision_to_json decisions));
      ])

let read_events config =
  ensure_dirs config;
  if not (Room_utils.path_exists config (events_path config)) then
    []
  else
    In_channel.with_open_text (events_path config) (fun ic ->
        let rec loop acc =
          match input_line ic with
          | line ->
              let trimmed = trim line in
              let acc' =
                if trimmed = "" then
                  acc
                else
                  match Safe_ops.parse_json_safe ~context:"command_plane_v2.events" trimmed with
                  | Ok json -> (
                      match event_of_json json with
                      | Some event -> event :: acc
                      | None -> acc)
                  | Error _ -> acc
              in
              loop acc'
          | exception End_of_file -> List.rev acc
        in
        loop [])

let append_event config (event : event_record) =
  ensure_dirs config;
  let line = Yojson.Safe.to_string (event_to_json event) ^ "\n" in
  let path = events_path config in
  let oc = open_out_gen [ Open_creat; Open_append; Open_wronly ] 0o600 path in
  Common.protect ~module_name:"command_plane_v2" ~finally_label:"close_out"
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc line)

let next_event_id prefix =
  Printf.sprintf "%s-%s-%04x" prefix
    (Int64.to_string (Int64.of_float (Unix.gettimeofday () *. 1000.0)))
    (Random.bits () land 0xffff)

let next_operation_id () =
  next_event_id "op"

let next_trace_id () =
  next_event_id "trace"

let validate_parent_kind child_kind parent_kind =
  match child_kind, parent_kind with
  | Company, _ -> false
  | Platoon, Company -> true
  | Squad, Company | Squad, Platoon -> true
  | Agent_unit, Squad -> true
  | _ -> false

let unit_map units =
  List.fold_left (fun acc (unit : unit_record) -> (unit.unit_id, unit) :: acc) [] units

let lookup_unit units unit_id =
  List.find_opt (fun (unit : unit_record) -> String.equal unit.unit_id unit_id) units

let validate_unit_shape units (unit : unit_record) =
  match unit.kind, unit.parent_unit_id with
  | Company, Some _ -> Error "company units cannot have a parent"
  | Company, None -> Ok ()
  | (Platoon | Squad | Agent_unit), None ->
      Error "non-company units require parent_unit_id"
  | kind, Some parent_id -> (
      match lookup_unit units parent_id with
      | None -> Error (Printf.sprintf "parent unit not found: %s" parent_id)
      | Some parent ->
          if validate_parent_kind kind parent.kind then Ok ()
          else
            Error
              (Printf.sprintf "invalid hierarchy: %s cannot be nested under %s"
                 (string_of_unit_kind kind) (string_of_unit_kind parent.kind)))

let resolve_unit_id label kind provided =
  match nonempty_string provided with
  | Some value -> value
  | None ->
      let prefix =
        match kind with
        | Company -> "company"
        | Platoon -> "platoon"
        | Squad -> "squad"
        | Agent_unit -> "agent"
      in
      Printf.sprintf "%s-%s" prefix (safe_slug label)

let effective_units_for_validation config managed_units =
  if lookup_unit managed_units "company-runtime" <> None then
    managed_units
  else
    let live_names =
      Room.get_agents_raw config
      |> List.map (fun (agent : Types.agent) -> agent.name)
      |> List.sort_uniq String.compare
    in
    let now = Types.now_iso () in
    let runtime_root =
      {
        unit_id = "company-runtime";
        label = "Runtime Company";
        kind = Company;
        parent_unit_id = None;
        leader_id = List.nth_opt live_names 0;
        roster = live_names;
        capability_profile = [];
        policy = default_policy Company;
        budget = default_budget Company;
        source = "auto";
        created_at = now;
        updated_at = now;
      }
    in
    runtime_root :: managed_units

let upsert_unit config ~(actor : string) json =
  let managed_units = read_units config in
  let effective_units = effective_units_for_validation config managed_units in
  let kind =
    match
      (match get_string_opt json "kind" with
      | Some value -> unit_kind_of_string value
      | None -> None)
    with
    | Some value -> value
    | None -> invalid_arg "kind is required (company|platoon|squad|agent)"
  in
  let label =
    match get_string_opt json "label" with
    | Some value -> value
    | None -> invalid_arg "label is required"
  in
  let unit_id = resolve_unit_id label kind (get_string_opt json "unit_id") in
  let existing = lookup_unit managed_units unit_id in
  let created_at =
    match existing with
    | Some unit -> unit.created_at
    | None -> Types.now_iso ()
  in
  let policy_json =
    match U.member "policy" json with `Assoc _ as value -> value | _ -> `Assoc []
  in
  let budget_json =
    match U.member "budget" json with `Assoc _ as value -> value | _ -> `Assoc []
  in
  let unit =
    {
      unit_id;
      label;
      kind;
      parent_unit_id = get_string_opt json "parent_unit_id";
      leader_id = get_string_opt json "leader_id";
      roster = get_string_list json "roster";
      capability_profile = get_string_list json "capability_profile";
      policy = policy_of_json policy_json kind;
      budget = budget_of_json budget_json kind;
      source = "managed";
      created_at;
      updated_at = Types.now_iso ();
    }
  in
  match
    validate_unit_shape
      (List.filter
         (fun (row : unit_record) -> not (String.equal row.unit_id unit_id))
         effective_units)
      unit
  with
  | Error message -> Error message
  | Ok () ->
      let next_units =
        unit
        :: List.filter
             (fun (row : unit_record) -> not (String.equal row.unit_id unit_id))
             managed_units
      in
      write_units config next_units;
      append_event config
        {
          event_id = next_event_id "evt";
          trace_id = next_trace_id ();
          event_type =
            if existing = None then "unit_defined" else "unit_updated";
          operation_id = None;
          unit_id = Some unit_id;
          actor = Some actor;
          source = "control_plane";
          ts = Types.now_iso ();
          detail =
            `Assoc
              [
                ("label", `String label);
                ("kind", `String (string_of_unit_kind kind));
                ("roster_size", `Int (List.length unit.roster));
              ];
        };
      Ok unit

let auto_leaf_unit agent_name squad_id =
  let now = Types.now_iso () in
  {
    unit_id = Printf.sprintf "agent-%s" (safe_slug agent_name);
    label = agent_name;
    kind = Agent_unit;
    parent_unit_id = Some squad_id;
    leader_id = Some agent_name;
    roster = [ agent_name ];
    capability_profile = [];
    policy = default_policy Agent_unit;
    budget = default_budget Agent_unit;
    source = "auto";
    created_at = now;
    updated_at = now;
  }

let chunk size xs =
  let rec loop acc current n rest =
    match rest with
    | [] ->
        let acc' = if current = [] then acc else List.rev current :: acc in
        List.rev acc'
    | x :: tail ->
        if n = size then
          loop (List.rev current :: acc) [ x ] 1 tail
        else
          loop acc (x :: current) (n + 1) tail
  in
  if size <= 0 then [ xs ] else loop [] [] 0 xs

let build_auto_units agents =
  let live_names =
    agents
    |> List.map (fun (agent : Types.agent) -> agent.name)
    |> List.sort_uniq String.compare
  in
  let now = Types.now_iso () in
  let company_id = "company-runtime" in
  let company =
    {
      unit_id = company_id;
      label = "Runtime Company";
      kind = Company;
      parent_unit_id = None;
      leader_id = List.nth_opt live_names 0;
      roster = live_names;
      capability_profile = [];
      policy = default_policy Company;
      budget = default_budget Company;
      source = "auto";
      created_at = now;
      updated_at = now;
    }
  in
  let platoon_chunks = chunk 24 live_names in
  let units = ref [ company ] in
  List.iteri
    (fun platoon_idx platoon_roster ->
      let platoon_id = Printf.sprintf "platoon-auto-%02d" (platoon_idx + 1) in
      let platoon =
        {
          unit_id = platoon_id;
          label = Printf.sprintf "Platoon %d" (platoon_idx + 1);
          kind = Platoon;
          parent_unit_id = Some company_id;
          leader_id = List.nth_opt platoon_roster 0;
          roster = platoon_roster;
          capability_profile = [];
          policy = default_policy Platoon;
          budget = default_budget Platoon;
          source = "auto";
          created_at = now;
          updated_at = now;
        }
      in
      units := platoon :: !units;
      platoon_roster
      |> chunk 6
      |> List.iteri (fun squad_idx squad_roster ->
             let squad_id =
               Printf.sprintf "squad-auto-%02d-%02d" (platoon_idx + 1) (squad_idx + 1)
             in
             let squad =
               {
                 unit_id = squad_id;
                 label = Printf.sprintf "Squad %d.%d" (platoon_idx + 1) (squad_idx + 1);
                 kind = Squad;
                 parent_unit_id = Some platoon_id;
                 leader_id = List.nth_opt squad_roster 0;
                 roster = squad_roster;
                 capability_profile = [];
                 policy = default_policy Squad;
                 budget = default_budget Squad;
                 source = "auto";
                 created_at = now;
                 updated_at = now;
               }
             in
             units := squad :: !units;
             List.iter (fun agent_name -> units := auto_leaf_unit agent_name squad_id :: !units) squad_roster))
    platoon_chunks;
  List.rev !units

let augment_managed_units units agents =
  let live_names =
    agents
    |> List.map (fun (agent : Types.agent) -> agent.name)
    |> List.sort_uniq String.compare
  in
  if units = [] then
    build_auto_units agents
  else
    let now = Types.now_iso () in
    let missing_parent unit =
      match unit.parent_unit_id with
      | None -> true
      | Some parent_id -> lookup_unit units parent_id = None
    in
    let roots = List.filter missing_parent units in
    let roots_need_runtime_root =
      match roots with
      | [ root ] when root.kind = Company -> false
      | _ -> true
    in
    let runtime_root_id = "company-runtime" in
    let rewritten_units =
      if roots_need_runtime_root then
        List.map
          (fun unit ->
            if missing_parent unit then
              { unit with parent_unit_id = Some runtime_root_id }
            else
              unit)
          units
      else
        units
    in
    let root_units =
      if roots_need_runtime_root then
        [
          {
            unit_id = runtime_root_id;
            label = "Runtime Company";
            kind = Company;
            parent_unit_id = None;
            leader_id = List.nth_opt live_names 0;
            roster = live_names;
            capability_profile = [];
            policy = default_policy Company;
            budget = default_budget Company;
            source = "auto";
            created_at = now;
            updated_at = now;
          };
        ]
      else
        []
    in
    let assigned_agents =
      rewritten_units
      |> List.concat_map (fun (unit : unit_record) -> unit.roster)
      |> List.sort_uniq String.compare
    in
    let unassigned =
      live_names |> List.filter (fun agent_name -> not (List.mem agent_name assigned_agents))
    in
    let fallback_parent_id =
      rewritten_units
      |> List.find_opt (fun (unit : unit_record) -> unit.kind = Platoon)
      |> Option.map (fun (unit : unit_record) -> unit.unit_id)
      |> option_first_some
           (rewritten_units
           |> List.find_opt (fun (unit : unit_record) -> unit.kind = Company)
           |> Option.map (fun (unit : unit_record) -> unit.unit_id))
      |> Option.value ~default:runtime_root_id
    in
    let unassigned_units =
      if unassigned = [] then
        []
      else
        let squad_id = "squad-unassigned" in
        let squad =
          {
            unit_id = squad_id;
            label = "Unassigned Squad";
            kind = Squad;
            parent_unit_id = Some fallback_parent_id;
            leader_id = List.nth_opt unassigned 0;
            roster = unassigned;
            capability_profile = [ "unassigned" ];
            policy = default_policy Squad;
            budget = default_budget Squad;
            source = "auto";
            created_at = now;
            updated_at = now;
          }
        in
        squad :: List.map (fun agent_name -> auto_leaf_unit agent_name squad_id) unassigned
    in
    root_units @ rewritten_units @ unassigned_units

let operation_status_of_session (status : Team_session_types.session_status) =
  match status with
  | Running -> Active
  | Paused -> Paused
  | Completed -> Completed
  | Interrupted -> Cancelled
  | Failed -> Failed

let choose_unit_for_session units (session : Team_session_types.session) =
  let session_agents = session.agent_names |> filter_nonempty_strings in
  let overlap (unit : unit_record) =
    List.fold_left
      (fun acc agent_name -> if List.mem agent_name unit.roster then acc + 1 else acc)
      0 session_agents
  in
  let cmp (score_a, rank_a, roster_a) (score_b, rank_b, roster_b) =
    match Int.compare score_a score_b with
    | 0 -> (
        match Int.compare rank_b rank_a with
        | 0 -> Int.compare roster_b roster_a
        | other -> other)
    | other -> other
  in
  let candidates : (unit_record * int * int * int) list =
    units
    |> List.filter (fun (unit : unit_record) ->
           unit.kind = Squad || unit.kind = Platoon || unit.kind = Company)
    |> List.map (fun (unit : unit_record) ->
           (unit, overlap unit, kind_order unit.kind, List.length unit.roster))
  in
  candidates
  |> List.sort (fun (_, score_a, rank_a, roster_a) (_, score_b, rank_b, roster_b) ->
         cmp (score_b, rank_b, roster_b) (score_a, rank_a, roster_a))
  |> List.filter (fun (_unit, score, _rank, _roster) -> score > 0)
  |> List.map (fun ((unit : unit_record), _, _, _) -> unit.unit_id)
  |> list_hd_opt

let iso_of_unix unix_ts =
  let tm = Unix.gmtime unix_ts in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour
    tm.Unix.tm_min tm.Unix.tm_sec

let days_from_civil year month day =
  let year = if month <= 2 then year - 1 else year in
  let era = if year >= 0 then year / 400 else (year - 399) / 400 in
  let yoe = year - (era * 400) in
  let month_prime = if month > 2 then month - 3 else month + 9 in
  let doy = ((153 * month_prime) + 2) / 5 + day - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468

let parse_iso_timestamp (s : string) : float option =
  try
    let open Scanf in
    sscanf s "%04d-%02d-%02dT%02d:%02d:%02dZ" (fun y m d h min sec ->
        let days = days_from_civil y m d in
        let seconds =
          (days * 86_400) + (h * 3_600) + (min * 60) + sec
        in
        Some (float_of_int seconds))
  with Scanf.Scan_failure _ | Failure _ | End_of_file -> None

let iso_after_seconds base seconds =
  parse_iso_timestamp base
  |> Option.map (fun ts -> iso_of_unix (ts +. float_of_int seconds))

let iso_expired_at now deadline =
  match parse_iso_timestamp deadline with
  | Some ts -> ts <= now
  | None -> false

let rec descendant_units_of_kind units unit_id kind =
  let direct_children =
    units
    |> List.filter (fun (unit : unit_record) ->
           match unit.parent_unit_id with
           | Some parent_id -> String.equal parent_id unit_id
           | None -> false)
  in
  let direct_matches =
    direct_children
    |> List.filter (fun (unit : unit_record) -> unit.kind = kind)
  in
  direct_matches
  @ List.concat_map
      (fun (child : unit_record) -> descendant_units_of_kind units child.unit_id kind)
      direct_children

let projected_team_session_operations config units managed_operations =
  let managed_session_ids =
    managed_operations
    |> List.filter_map (fun (operation : operation_record) -> operation.detachment_session_id)
    |> List.sort_uniq String.compare
  in
  Team_session_store.list_sessions config
  |> List.filter (fun (session : Team_session_types.session) ->
         not (List.mem session.session_id managed_session_ids))
  |> List.map (fun (session : Team_session_types.session) ->
         let assigned_unit_id =
           choose_unit_for_session units session
           |> Option.value
                ~default:
                  (match units with
                  | (unit : unit_record) :: _ -> unit.unit_id
                  | [] -> "company-runtime")
         in
         {
           operation_id = "detachment-" ^ session.session_id;
           objective = session.goal;
           assigned_unit_id;
           autonomy_level =
             Team_session_types.orchestration_mode_to_string session.orchestration_mode;
           policy_class =
             Team_session_types.execution_scope_to_string session.execution_scope;
           budget_class =
             Team_session_types.communication_mode_to_string session.communication_mode;
           detachment_session_id = Some session.session_id;
           trace_id = session.session_id;
           checkpoint_ref = nonempty_string (Some session.artifacts_dir);
           active_goal_ids = [];
           note = session.stop_reason;
           created_by = session.created_by;
           source = "projected";
           status = operation_status_of_session session.status;
           created_at = session.created_at_iso;
           updated_at = session.updated_at_iso;
         })

let projected_swarm_operations config units managed_operations =
  let swarm_json =
    if Room_utils.path_exists config (swarm_path config) then
      Room_utils.read_json_opt config (swarm_path config)
    else
      None
  in
  match swarm_json with
  | Some (`Assoc _ as root) ->
      let config_json =
        match U.member "config" root with `Assoc _ as value -> value | _ -> `Assoc []
      in
      let swarm_id = get_string_default config_json "id" "swarm-runtime" in
      let operation_id = "swarm-" ^ safe_slug swarm_id in
      let already_managed =
        List.exists (fun (operation : operation_record) -> String.equal operation.operation_id operation_id) managed_operations
      in
      if already_managed then
        []
      else
        let swarm_name = get_string_default config_json "name" "Runtime Swarm" in
        let behavior = get_string_default config_json "behavior" "flocking" in
        let generation = get_int_default root "generation" 0 in
        let assigned_unit_id =
          units
          |> List.find_opt (fun (unit : unit_record) -> unit.kind = Company)
          |> Option.map (fun (unit : unit_record) -> unit.unit_id)
          |> Option.value ~default:"company-runtime"
        in
        let last_evolution =
          match U.member "last_evolution" root with
          | `Float value -> iso_of_unix value
          | `Int value -> iso_of_unix (float_of_int value)
          | _ -> Types.now_iso ()
        in
        [
          {
            operation_id;
            objective = Printf.sprintf "Swarm %s (%s) generation %d" swarm_name behavior generation;
            assigned_unit_id;
            autonomy_level = "L5_Independent";
            policy_class = "swarm";
            budget_class = "adaptive";
            detachment_session_id = None;
            trace_id = "swarm-trace-" ^ safe_slug swarm_id;
            checkpoint_ref = None;
            active_goal_ids = [];
            note = Some (Printf.sprintf "Projected from .masc/swarm.json with behavior=%s" behavior);
            created_by = "swarm";
            source = "projected";
            status = Active;
            created_at = last_evolution;
            updated_at = last_evolution;
          };
        ]
  | _ -> []

let all_operations config units =
  let managed = read_operations config in
  managed
  @ projected_team_session_operations config units managed
  @ projected_swarm_operations config units managed

let operation_by_id operations operation_id =
  List.find_opt
    (fun (operation : operation_record) -> String.equal operation.operation_id operation_id)
    operations

let projected_team_session_detachments config operations =
  operations
  |> List.filter_map (fun (operation : operation_record) ->
         match operation.detachment_session_id with
         | None when operation.source = "projected" -> None
         | None -> None
         | Some session_id -> (
             match Team_session_store.load_session config session_id with
             | None -> None
             | Some session ->
                 Some
                   {
                     detachment_id = "detachment-" ^ session_id;
                     operation_id = operation.operation_id;
                     assigned_unit_id = operation.assigned_unit_id;
                     leader_id = Some session.created_by;
                     roster = filter_nonempty_strings session.agent_names;
                     session_id = Some session_id;
                     checkpoint_ref = nonempty_string (Some session.artifacts_dir);
                     runtime_kind = Some "team_session";
                     runtime_ref = Some session_id;
                     source = "projected";
                     status = string_of_operation_status operation.status;
                     last_event_at = Option.map iso_of_unix session.last_event_at;
                     last_progress_at = Option.map iso_of_unix session.last_event_at;
                     heartbeat_deadline = None;
                     created_at = session.created_at_iso;
                     updated_at = session.updated_at_iso;
                   }))

let projected_swarm_detachments config operations =
  let swarm_json =
    if Room_utils.path_exists config (swarm_path config) then
      Room_utils.read_json_opt config (swarm_path config)
    else
      None
  in
  match swarm_json with
  | Some (`Assoc _ as root) ->
      let config_json =
        match U.member "config" root with `Assoc _ as value -> value | _ -> `Assoc []
      in
      let swarm_id = get_string_default config_json "id" "swarm-runtime" in
      let operation_id = "swarm-" ^ safe_slug swarm_id in
      let roster =
        match U.member "agents" root with
        | `List rows ->
            rows
            |> List.filter_map (fun row ->
                   match row with
                   | `Assoc _ ->
                       option_first_some (get_string_opt row "name") (get_string_opt row "id")
                   | _ -> None)
            |> dedup_strings
        | _ -> []
      in
      (match operation_by_id operations operation_id with
      | None -> []
      | Some operation ->
          let last_evolution =
            match U.member "last_evolution" root with
            | `Float value -> Some (iso_of_unix value)
            | `Int value -> Some (iso_of_unix (float_of_int value))
            | _ -> None
          in
          [
            {
              detachment_id = "detachment-" ^ safe_slug swarm_id;
              operation_id;
              assigned_unit_id = operation.assigned_unit_id;
              leader_id = list_hd_opt roster;
              roster;
              session_id = None;
              checkpoint_ref = None;
              runtime_kind = Some "swarm_projection";
              runtime_ref = Some swarm_id;
              source = "projected";
              status = "active";
              last_event_at = last_evolution;
              last_progress_at = last_evolution;
              heartbeat_deadline = None;
              created_at = Option.value ~default:(Types.now_iso ()) last_evolution;
              updated_at = Option.value ~default:(Types.now_iso ()) last_evolution;
            };
          ])
  | _ -> []

let all_detachments config units operations =
  let managed = read_detachments config in
  let managed_operation_ids =
    managed
    |> List.map (fun (detachment : detachment_record) -> detachment.operation_id)
    |> List.sort_uniq String.compare
  in
  let projected_ops =
    operations
    |> List.filter (fun (operation : operation_record) ->
           not (List.mem operation.operation_id managed_operation_ids))
  in
  let _ = units in
  managed
  @ projected_team_session_detachments config projected_ops
  @ projected_swarm_detachments config projected_ops

let projected_operator_decisions config =
  if not (Room_utils.path_exists config (operator_pending_confirms_path config)) then
    []
  else
    match Room_utils.read_json_opt config (operator_pending_confirms_path config) with
    | Some (`List rows) ->
        rows
        |> List.filter_map (fun row ->
               let decision_id =
                 option_first_some
                   (get_string_opt row "token")
                   (get_string_opt row "trace_id")
               in
               let requested_action = get_string_default row "action_type" "operator_action" in
               let scope_type = get_string_default row "target_type" "operator" in
               let scope_id =
                 get_string_default row "target_id"
                   (get_string_default row "trace_id" "operator")
               in
               match decision_id with
               | None -> None
               | Some token ->
                   Some
                     {
                       decision_id = "legacy-" ^ token;
                       trace_id = get_string_default row "trace_id" token;
                       requested_action;
                       scope_type;
                       scope_id;
                       operation_id = None;
                       target_unit_id = None;
                       requested_by = get_string_default row "actor" "operator";
                       status = "pending";
                       reason = Some "Projected from operator pending confirmation queue";
                       source = "projected_operator";
                       detail = row;
                       created_at = get_string_default row "created_at" (Types.now_iso ());
                       decided_at = None;
                       expires_at = get_string_opt row "expires_at";
                     })
    | _ -> []

let all_policy_decisions config =
  let managed = read_policy_decisions config in
  let managed_ids =
    managed
    |> List.map (fun (decision : policy_decision_record) -> decision.decision_id)
    |> List.sort_uniq String.compare
  in
  let projected =
    projected_operator_decisions config
    |> List.filter (fun (decision : policy_decision_record) ->
           not (List.mem decision.decision_id managed_ids))
  in
  managed @ projected

let live_agent_names agents =
  agents
  |> List.filter (fun (agent : Types.agent) ->
         match agent.status with
         | Active | Busy | Listening -> true
         | Inactive -> false)
  |> List.map (fun (agent : Types.agent) -> agent.name)
  |> List.sort_uniq String.compare

let agent_status_map agents =
  List.map (fun (agent : Types.agent) -> (agent.name, Types.string_of_agent_status agent.status)) agents

let agent_status_for agents agent_name =
  match List.assoc_opt agent_name agents with
  | Some status -> status
  | None -> "offline"

let active_operation_status = function
  | Active | Planned -> true
  | Paused | Completed | Cancelled | Failed -> false

let children_map units =
  List.fold_left
    (fun acc unit ->
      match unit.parent_unit_id with
      | None -> acc
      | Some parent_id ->
          let existing = match List.assoc_opt parent_id acc with Some xs -> xs | None -> [] in
          (parent_id, unit :: existing)
          :: List.remove_assoc parent_id acc)
    [] units

let rec descendant_ids child_map unit_id =
  let children = match List.assoc_opt unit_id child_map with Some xs -> xs | None -> [] in
  let direct = List.map (fun (unit : unit_record) -> unit.unit_id) children in
  direct @ List.concat_map (fun child_id -> descendant_ids child_map child_id) direct

let rec build_tree_json ~child_map ~unit_lookup ~agent_statuses ~live_agents ~operations unit_id =
  match List.assoc_opt unit_id unit_lookup with
  | None -> None
  | Some (unit : unit_record) ->
      let children =
        match List.assoc_opt unit_id child_map with
        | Some rows ->
            rows
            |> List.sort (fun (a : unit_record) (b : unit_record) ->
                   compare (kind_order a.kind, a.label) (kind_order b.kind, b.label))
            |> List.filter_map (fun (child : unit_record) ->
                   build_tree_json ~child_map ~unit_lookup ~agent_statuses
                     ~live_agents ~operations child.unit_id)
        | None -> []
      in
      let descendants = descendant_ids child_map unit_id in
      let covered_unit_ids = unit_id :: descendants in
      let descendant_op_count =
        operations
        |> List.filter (fun (operation : operation_record) ->
               active_operation_status operation.status
               && List.mem operation.assigned_unit_id covered_unit_ids)
        |> List.length
      in
      let live_roster =
        unit.roster |> List.filter (fun name -> List.mem name live_agents) |> List.length
      in
      let leader_status =
        match unit.leader_id with
        | Some leader -> agent_status_for agent_statuses leader
        | None -> "missing"
      in
      let reasons = ref [] in
      if unit.leader_id = None then reasons := "leader_missing" :: !reasons;
      if unit.leader_id <> None && leader_status = "offline" then reasons := "leader_offline" :: !reasons;
      if List.length unit.roster > unit.budget.headcount_cap then reasons := "headcount_cap_exceeded" :: !reasons;
      if descendant_op_count > unit.budget.active_operation_cap then
        reasons := "active_operation_cap_exceeded" :: !reasons;
      if unit.roster <> [] && live_roster = 0 then reasons := "roster_offline" :: !reasons;
      let health =
        if List.exists (fun reason ->
               reason = "leader_offline" || reason = "active_operation_cap_exceeded")
             !reasons
        then "bad"
        else if !reasons <> [] then "warn"
        else "ok"
      in
      Some
        (`Assoc
          [
            ("unit", unit_to_json unit);
            ("leader_status", `String leader_status);
            ("roster_total", `Int (List.length unit.roster));
            ("roster_live", `Int live_roster);
            ("active_operation_count", `Int descendant_op_count);
            ("health", `String health);
            ("reasons", json_list_of_strings (List.rev !reasons));
            ("children", `List children);
          ])

let topology_units config =
  let agents = Room.get_agents_raw config in
  let managed_units = read_units config in
  let normalized_units = augment_managed_units managed_units agents in
  let source =
    if managed_units = [] then "auto"
    else if List.length normalized_units > List.length managed_units then "hybrid"
    else "explicit"
  in
  (agents, managed_units, normalized_units, source)

let topology_json config =
  let agents, managed_units, units, source = topology_units config in
  let operations = all_operations config units in
  let child_map = children_map units in
  let lookup = unit_map units in
  let roots =
    units
    |> List.filter (fun (unit : unit_record) ->
           match unit.parent_unit_id with
           | None -> true
           | Some parent_id -> lookup_unit units parent_id = None)
    |> List.sort (fun a b -> compare (kind_order a.kind, a.label) (kind_order b.kind, b.label))
  in
  let trees =
    roots
    |> List.filter_map (fun (unit : unit_record) ->
           build_tree_json ~child_map ~unit_lookup:lookup
             ~agent_statuses:(agent_status_map agents)
             ~live_agents:(live_agent_names agents) ~operations unit.unit_id)
  in
  let summary =
    {
      total_units = List.length units;
      company_count = List.length (List.filter (fun (unit : unit_record) -> unit.kind = Company) units);
      platoon_count = List.length (List.filter (fun (unit : unit_record) -> unit.kind = Platoon) units);
      squad_count = List.length (List.filter (fun (unit : unit_record) -> unit.kind = Squad) units);
      leaf_agent_unit_count = List.length (List.filter (fun (unit : unit_record) -> unit.kind = Agent_unit) units);
      live_agent_count = List.length (live_agent_names agents);
      managed_unit_count = List.length managed_units;
      active_operation_count =
        operations
        |> List.filter (fun (operation : operation_record) -> active_operation_status operation.status)
        |> List.length;
    }
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("source", `String source);
      ( "summary",
        `Assoc
          [
            ("total_units", `Int summary.total_units);
            ("company_count", `Int summary.company_count);
            ("platoon_count", `Int summary.platoon_count);
            ("squad_count", `Int summary.squad_count);
            ("leaf_agent_unit_count", `Int summary.leaf_agent_unit_count);
            ("live_agent_count", `Int summary.live_agent_count);
            ("managed_unit_count", `Int summary.managed_unit_count);
            ("active_operation_count", `Int summary.active_operation_count);
          ] );
      ("units", `List trees);
    ]

let list_units_json config =
  let _, managed_units, normalized_units, source = topology_units config in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("source", `String source);
      ("managed_units", `List (List.map unit_to_json managed_units));
      ("effective_units", `List (List.map unit_to_json normalized_units));
    ]

let operation_card_json units (operation : operation_record) =
  let unit_label =
    lookup_unit units operation.assigned_unit_id
    |> Option.map (fun (unit : unit_record) -> unit.label)
    |> Option.value ~default:operation.assigned_unit_id
  in
  `Assoc
    [
      ("operation", operation_to_json operation);
      ("assigned_unit_label", `String unit_label);
    ]

let list_operations_json ?operation_id config =
  let _, _, units, _ = topology_units config in
  let operations =
    all_operations config units
    |> List.filter (fun (operation : operation_record) ->
           match operation_id with
           | None -> true
           | Some value ->
               String.equal operation.operation_id value
               || String.equal operation.trace_id value)
  in
  let managed_count =
    List.length
      (List.filter (fun (operation : operation_record) -> operation.source = "managed") operations)
  in
  let projected_count = List.length operations - managed_count in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length operations));
            ( "active",
              `Int
                (List.length
                   (List.filter
                      (fun (op : operation_record) -> op.status = Active)
                      operations)) );
            ( "paused",
              `Int
                (List.length
                   (List.filter
                      (fun (op : operation_record) -> op.status = Paused)
                      operations)) );
            ("managed", `Int managed_count);
            ("projected", `Int projected_count);
          ] );
      ("operations", `List (List.map (operation_card_json units) operations));
    ]

let list_detachments_json ?operation_id ?detachment_id config =
  let _, _, units, _ = topology_units config in
  let operations = all_operations config units in
  let detachments =
    all_detachments config units operations
    |> List.filter (fun (detachment : detachment_record) ->
           let operation_match =
             match operation_id with
             | None -> true
             | Some value ->
                 String.equal detachment.operation_id value
                 ||
                 match operation_by_id operations detachment.operation_id with
                 | Some operation -> String.equal operation.trace_id value
                 | None -> false
           in
           let detachment_match =
             match detachment_id with
             | None -> true
             | Some value -> String.equal detachment.detachment_id value
           in
           operation_match && detachment_match)
  in
  let rows =
    detachments
    |> List.map (fun (detachment : detachment_record) ->
           let operation =
             operation_by_id operations detachment.operation_id
             |> Option.map operation_to_json
             |> Option.value ~default:`Null
           in
           let unit_label =
             lookup_unit units detachment.assigned_unit_id
             |> Option.map (fun (unit : unit_record) -> unit.label)
             |> Option.value ~default:detachment.assigned_unit_id
           in
            `Assoc
              [
                ("detachment", detachment_to_json detachment);
                ("assigned_unit_label", `String unit_label);
                ("operation", operation);
              ])
  in
  let projected_count =
    List.length
      (List.filter (fun (detachment : detachment_record) -> detachment.source <> "managed") detachments)
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length detachments));
            ( "active",
              `Int
                (List.length
                   (List.filter
                      (fun (row : detachment_record) ->
                        String.equal row.status "active")
                      detachments)) );
            ( "awaiting_approval",
              `Int
                (List.length
                   (List.filter
                      (fun (row : detachment_record) ->
                        String.equal row.status "awaiting_approval")
                      detachments)) );
            ( "stalled",
              `Int
                (List.length
                   (List.filter
                      (fun (row : detachment_record) ->
                        String.equal row.status "stalled")
                      detachments)) );
            ("projected", `Int projected_count);
          ] );
      ("detachments", `List rows);
    ]

let list_policy_decisions_json ?decision_id config =
  let decisions =
    all_policy_decisions config
    |> List.filter (fun (decision : policy_decision_record) ->
           match decision_id with
           | None -> true
           | Some value ->
               String.equal decision.decision_id value
               || String.equal decision.trace_id value)
    |> List.sort (fun (a : policy_decision_record) (b : policy_decision_record) ->
           String.compare b.created_at a.created_at)
  in
  let count_status status =
    List.length (List.filter (fun (decision : policy_decision_record) -> String.equal decision.status status) decisions)
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length decisions));
            ("pending", `Int (count_status "pending"));
            ("approved", `Int (count_status "approved"));
            ("denied", `Int (count_status "denied"));
          ] );
      ("decisions", `List (List.map policy_decision_to_json decisions));
    ]

let capacity_json config =
  let agents, _, units, _ = topology_units config in
  let operations = all_operations config units in
  let live_agents = live_agent_names agents in
  let rows =
    units
    |> List.map (fun (unit : unit_record) ->
           let live_count =
             unit.roster |> List.filter (fun agent_name -> List.mem agent_name live_agents) |> List.length
           in
           let active_ops =
             operations
             |> List.filter (fun (operation : operation_record) ->
                    active_operation_status operation.status
                    && String.equal operation.assigned_unit_id unit.unit_id)
             |> List.length
           in
           let utilization =
             if unit.budget.active_operation_cap <= 0 then 0.0
             else float_of_int active_ops /. float_of_int unit.budget.active_operation_cap
           in
           `Assoc
             [
               ("unit", unit_to_json unit);
               ("roster_total", `Int (List.length unit.roster));
               ("roster_live", `Int live_count);
               ("headcount_cap", `Int unit.budget.headcount_cap);
               ("active_operations", `Int active_ops);
               ("active_operation_cap", `Int unit.budget.active_operation_cap);
               ("utilization", `Float utilization);
             ])
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("capacity", `List rows);
    ]

let list_alerts_json config =
  let agents, _, units, _ = topology_units config in
  let operations = all_operations config units in
  let live_agents = live_agent_names agents in
  let status_map = agent_status_map agents in
  let alerts = ref [] in
  let push_alert ~severity ~kind ~scope_type ~scope_id ~title ~detail =
    alerts :=
      `Assoc
        [
          ("alert_id", `String (next_event_id "alert"));
          ("severity", `String severity);
          ("kind", `String kind);
          ("scope_type", `String scope_type);
          ("scope_id", `String scope_id);
          ("title", `String title);
          ("detail", `String detail);
          ("timestamp", `String (Types.now_iso ()));
        ]
      :: !alerts
  in
  List.iter
    (fun (unit : unit_record) ->
      let live_roster =
        unit.roster |> List.filter (fun name -> List.mem name live_agents) |> List.length
      in
      let active_ops =
        operations
        |> List.filter (fun (operation : operation_record) ->
               active_operation_status operation.status
               && String.equal operation.assigned_unit_id unit.unit_id)
        |> List.length
      in
      if unit.leader_id = None then
        push_alert ~severity:"warn" ~kind:"leader_missing" ~scope_type:"unit"
          ~scope_id:unit.unit_id ~title:(unit.label ^ " has no leader")
          ~detail:"Assign a leader before enabling automatic dispatch.";
      (match unit.leader_id with
      | Some leader when agent_status_for status_map leader = "offline" ->
          push_alert ~severity:"bad" ~kind:"leader_offline" ~scope_type:"unit"
            ~scope_id:unit.unit_id ~title:(unit.label ^ " leader is offline")
            ~detail:"Reassign leadership or recall the unit."
      | _ -> ());
      if List.length unit.roster > unit.budget.headcount_cap then
        push_alert ~severity:"warn" ~kind:"headcount_cap_exceeded" ~scope_type:"unit"
          ~scope_id:unit.unit_id ~title:(unit.label ^ " is over headcount cap")
          ~detail:
            (Printf.sprintf "%d assigned vs cap %d" (List.length unit.roster)
               unit.budget.headcount_cap);
      if unit.policy.frozen then
        push_alert ~severity:"warn" ~kind:"unit_frozen" ~scope_type:"unit"
          ~scope_id:unit.unit_id ~title:(unit.label ^ " is frozen")
          ~detail:"Dispatch into this unit is blocked until it is unfrozen.";
      if unit.policy.kill_switch then
        push_alert ~severity:"bad" ~kind:"kill_switch_enabled" ~scope_type:"unit"
          ~scope_id:unit.unit_id ~title:(unit.label ^ " kill-switch is enabled")
          ~detail:"All new operation assignment should stop until the switch is cleared.";
      if active_ops > unit.budget.active_operation_cap then
        push_alert ~severity:"bad" ~kind:"operation_cap_exceeded" ~scope_type:"unit"
          ~scope_id:unit.unit_id ~title:(unit.label ^ " exceeded active operation cap")
          ~detail:
            (Printf.sprintf "%d active vs cap %d" active_ops
               unit.budget.active_operation_cap);
      if unit.roster <> [] && live_roster = 0 then
        push_alert ~severity:"warn" ~kind:"roster_offline" ~scope_type:"unit"
          ~scope_id:unit.unit_id ~title:(unit.label ^ " has no live roster")
          ~detail:"All assigned agents are quiet or offline.")
    units;
  List.iter
    (fun (operation : operation_record) ->
      if active_operation_status operation.status then (
        match lookup_unit units operation.assigned_unit_id with
        | None ->
            push_alert ~severity:"bad" ~kind:"orphaned_operation" ~scope_type:"operation"
              ~scope_id:operation.operation_id
              ~title:(operation.operation_id ^ " is assigned to a missing unit")
              ~detail:"Reassign this operation before it continues."
        | Some _ -> ());
      match operation.detachment_session_id with
      | Some session_id -> (
          match Team_session_store.load_session config session_id with
          | Some session -> (
              match session.last_event_at with
              | Some last_event_at ->
                  let age_sec = max 0. (Unix.gettimeofday () -. last_event_at) in
                  if age_sec > 1800. then
                    push_alert ~severity:"warn" ~kind:"detachment_quiet"
                      ~scope_type:"operation" ~scope_id:operation.operation_id
                      ~title:(operation.operation_id ^ " detachment went quiet")
                      ~detail:
                        (Printf.sprintf "No detachment event for %.0fs" age_sec)
              | None -> ())
          | None -> ())
      | None -> ())
    operations;
  all_policy_decisions config
  |> List.iter (fun (decision : policy_decision_record) ->
         if String.equal decision.status "pending" then
           push_alert ~severity:"warn" ~kind:"approval_pending"
             ~scope_type:decision.scope_type ~scope_id:decision.scope_id
             ~title:(Printf.sprintf "%s waiting for approval" decision.requested_action)
             ~detail:
               (match decision.reason with
               | Some reason -> reason
               | None -> "Pending policy gate approval"));
  let ordered =
    List.rev !alerts
    |> List.sort (fun a b ->
           let severity_rank json =
             match get_string_default json "severity" "warn" with
             | "bad" -> 0
             | "warn" -> 1
             | _ -> 2
           in
           compare (severity_rank a) (severity_rank b))
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length ordered));
            ("bad", `Int (List.length (List.filter (fun json -> get_string_default json "severity" "" = "bad") ordered)));
            ("warn", `Int (List.length (List.filter (fun json -> get_string_default json "severity" "" = "warn") ordered)));
          ] );
      ("alerts", `List ordered);
    ]

let recent_team_session_trace_events config session_id limit =
  Team_session_store.read_events ~max_events:limit config session_id
  |> List.filter_map (fun json ->
         let event_type = get_string_opt json "event_type" in
         let timestamp = get_string_opt json "ts_iso" in
         let detail =
           match U.member "detail" json with
           | `Assoc _ as value -> value
           | `List _ as value -> value
           | `Null -> `Assoc []
           | value -> value
         in
         match event_type, timestamp with
         | Some event_type, Some timestamp ->
             Some
               (`Assoc
                 [
                   ("event_id", `String (next_event_id "trace"));
                   ("trace_id", `String session_id);
                   ("event_type", `String event_type);
                   ("source", `String "team_session");
                   ("timestamp", `String timestamp);
                   ("detail", detail);
                 ])
         | _ -> None)

let recent_operator_trace_events config ?trace_id limit =
  if not (Room_utils.path_exists config (operator_action_log_path config)) then
    []
  else
    In_channel.with_open_text (operator_action_log_path config) (fun ic ->
        let rec loop acc =
          match input_line ic with
          | line ->
              let trimmed = trim line in
              let acc' =
                if trimmed = "" then
                  acc
                else
                  match Safe_ops.parse_json_safe ~context:"command_plane_v2.operator_log" trimmed with
                  | Ok (`Assoc _ as row) ->
                      let row_trace_id = get_string_opt row "trace_id" in
                      let keep =
                        match trace_id, row_trace_id with
                        | None, _ -> true
                        | Some expected, Some actual -> String.equal expected actual
                        | Some _, None -> false
                      in
                      if keep then
                        `Assoc
                          [
                            ("event_id", `String (next_event_id "trace"));
                            ("trace_id", `String (get_string_default row "trace_id" "operator"));
                            ("event_type", `String (get_string_default row "action_type" "operator_action"));
                            ("operation_id", `Null);
                            ("unit_id", `Null);
                            ("actor", match get_string_opt row "actor" with Some value -> `String value | None -> `Null);
                            ("source", `String "operator");
                            ("timestamp", `String (get_string_default row "created_at" (Types.now_iso ())));
                            ("detail", row);
                          ]
                        :: acc
                      else
                        acc
                  | Ok _ | Error _ -> acc
              in
              loop acc'
          | exception End_of_file -> List.rev acc
        in
        loop []
        |> List.rev |> List.filteri (fun idx _ -> idx < limit) |> List.rev)

let recent_swarm_trace_events config limit =
  if not (Room_utils.path_exists config (swarm_path config)) then
    []
  else
    match Room_utils.read_json_opt config (swarm_path config) with
    | Some (`Assoc _ as root) ->
        let config_json =
          match U.member "config" root with `Assoc _ as value -> value | _ -> `Assoc []
        in
        let swarm_id = get_string_default config_json "id" "swarm-runtime" in
        let generation = get_int_default root "generation" 0 in
        let timestamp =
          match U.member "last_evolution" root with
          | `Float value -> iso_of_unix value
          | `Int value -> iso_of_unix (float_of_int value)
          | _ -> Types.now_iso ()
        in
        [
          `Assoc
            [
              ("event_id", `String (next_event_id "trace"));
              ("trace_id", `String ("swarm-trace-" ^ safe_slug swarm_id));
              ("event_type", `String "swarm_projected");
              ("operation_id", `String ("swarm-" ^ safe_slug swarm_id));
              ("unit_id", `Null);
              ("actor", `String "swarm");
              ("source", `String "swarm");
              ("timestamp", `String timestamp);
              ("detail", `Assoc [ ("generation", `Int generation); ("config", config_json) ]);
            ];
        ]
        |> List.filteri (fun idx _ -> idx < limit)
    | _ -> []

let list_traces_json config ?operation_id ?(limit = 25) () =
  let events =
    read_events config
    |> List.filter (fun (event : event_record) ->
           match operation_id with
           | None -> true
           | Some operation_ref ->
               (match event.operation_id with
               | Some value -> String.equal value operation_ref
               | None -> false)
               || String.equal event.trace_id operation_ref)
  in
  let cp_events =
    events
    |> List.rev
    |> List.filteri (fun idx _ -> idx < limit)
    |> List.rev
    |> List.map (fun (event : event_record) ->
           `Assoc
             [
               ("event_id", `String event.event_id);
               ("trace_id", `String event.trace_id);
               ("event_type", `String event.event_type);
               ("operation_id", match event.operation_id with Some value -> `String value | None -> `Null);
               ("unit_id", match event.unit_id with Some value -> `String value | None -> `Null);
               ("actor", match event.actor with Some value -> `String value | None -> `Null);
               ("source", `String event.source);
               ("timestamp", `String event.ts);
               ("detail", event.detail);
             ])
  in
  let team_session_events =
    match operation_id with
    | Some operation_ref -> (
        let _, _, units, _ = topology_units config in
        let operations = all_operations config units in
        match
          operations
          |> List.find_opt (fun (operation : operation_record) ->
                 String.equal operation.operation_id operation_ref
                 || String.equal operation.trace_id operation_ref)
        with
        | Some operation -> (
            match operation.detachment_session_id with
            | Some session_id -> recent_team_session_trace_events config session_id limit
            | None -> [])
        | None -> [])
    | None -> []
  in
  let operator_events =
    match operation_id with
    | Some operation_ref -> recent_operator_trace_events config ~trace_id:operation_ref limit
    | None -> recent_operator_trace_events config limit
  in
  let merged = cp_events @ team_session_events @ operator_events in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("events", `List merged);
    ]

let snapshot_json config =
  let topology = topology_json config in
  let operations = list_operations_json config in
  let detachments = list_detachments_json config in
  let alerts = list_alerts_json config in
  let decisions = list_policy_decisions_json config in
  let capacity = capacity_json config in
  let traces = list_traces_json config ~limit:10 () in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("topology", topology);
      ("operations", operations);
      ("detachments", detachments);
      ("alerts", alerts);
      ("decisions", decisions);
      ("capacity", capacity);
      ("traces", traces);
    ]

let operation_status_json config ?operation_id () =
  list_operations_json ?operation_id config

let unit_guard_json config unit_id =
  let agents, _, units, _ = topology_units config in
  match lookup_unit units unit_id with
  | None -> Error (Printf.sprintf "assigned unit not found: %s" unit_id)
  | Some unit ->
      let live_count =
        unit.roster
        |> List.filter (fun name -> List.mem name (live_agent_names agents))
        |> List.length
      in
      let active_count =
        all_operations config units
        |> List.filter (fun (operation : operation_record) ->
               active_operation_status operation.status
               && String.equal operation.assigned_unit_id unit.unit_id)
        |> List.length
      in
      if unit.leader_id = None then
        Error "assigned unit has no leader"
      else if unit.policy.kill_switch then
        Error "assigned unit has kill-switch enabled"
      else if unit.policy.frozen then
        Error "assigned unit is frozen"
      else if live_count = 0 then
        Error "assigned unit has no live agents"
      else if active_count >= unit.budget.active_operation_cap then
        Error
          (Printf.sprintf "assigned unit reached active operation cap (%d)"
             unit.budget.active_operation_cap)
      else
        Ok
          (`Assoc
            [
              ("unit_id", `String unit.unit_id);
              ("live_roster", `Int live_count);
              ("active_operations", `Int active_count);
              ("active_operation_cap", `Int unit.budget.active_operation_cap);
            ])

let replace_operation operations (updated : operation_record) =
  updated
  :: List.filter
       (fun (operation : operation_record) ->
         not (String.equal operation.operation_id updated.operation_id))
       operations

let replace_detachment detachments (updated : detachment_record) =
  updated
  :: List.filter
       (fun (detachment : detachment_record) ->
         not (String.equal detachment.detachment_id updated.detachment_id))
       detachments

let append_cp_event config ~trace_id ~event_type ?operation_id ?unit_id ~actor detail =
  append_event config
    {
      event_id = next_event_id "evt";
      trace_id;
      event_type;
      operation_id;
      unit_id;
      actor = Some actor;
      source = "control_plane";
      ts = Types.now_iso ();
      detail;
    }

let detachment_targets_for_operation units (operation : operation_record) =
  let dedup_by_unit_id rows =
    rows
    |> List.sort_uniq (fun (left : unit_record) (right : unit_record) ->
           String.compare left.unit_id right.unit_id)
  in
  match lookup_unit units operation.assigned_unit_id with
  | Some ({ kind = Company | Platoon; _ } as unit) ->
      let squads = descendant_units_of_kind units unit.unit_id Squad |> dedup_by_unit_id in
      if squads = [] then [ unit ] else squads
  | Some ({ kind = Squad; _ } as unit) -> [ unit ]
  | Some ({ kind = Agent_unit; parent_unit_id = Some parent_id; _ } as unit) -> (
      match lookup_unit units parent_id with
      | Some ({ kind = Squad; _ } as squad) -> [ squad ]
      | _ -> [ unit ])
  | Some unit -> [ unit ]
  | None -> []

let detachment_id_for_operation (operation : operation_record) target_count
    (target_unit : unit_record) =
  if target_count <= 1 then
    "det-" ^ operation.operation_id
  else
    Printf.sprintf "det-%s-%s" operation.operation_id (safe_slug target_unit.unit_id)

let detachment_semantic_equal (left : detachment_record) (right : detachment_record) =
  String.equal left.detachment_id right.detachment_id
  && String.equal left.operation_id right.operation_id
  && String.equal left.assigned_unit_id right.assigned_unit_id
  && left.leader_id = right.leader_id
  && left.roster = right.roster
  && left.session_id = right.session_id
  && left.checkpoint_ref = right.checkpoint_ref
  && left.runtime_kind = right.runtime_kind
  && left.runtime_ref = right.runtime_ref
  && String.equal left.source right.source
  && String.equal left.status right.status
  && left.last_event_at = right.last_event_at
  && left.last_progress_at = right.last_progress_at
  && left.heartbeat_deadline = right.heartbeat_deadline
  && String.equal left.created_at right.created_at

let make_detachment_runtime config (target_unit : unit_record) (operation : operation_record)
    ~target_count ~base =
  let session_id =
    if target_count = 1 then option_first_some operation.detachment_session_id base.session_id
    else None
  in
  let session_last_event =
    match session_id with
    | Some value -> (
        match Team_session_store.load_session config value with
        | Some session -> Option.map iso_of_unix session.last_event_at
        | None -> None)
    | None -> None
  in
  let last_progress_at =
    option_first_some session_last_event
      (option_first_some base.last_progress_at (Some operation.updated_at))
  in
  let heartbeat_deadline =
    if operation.status = Active || operation.status = Planned then
      Option.bind last_progress_at (fun base_ts ->
          iso_after_seconds base_ts target_unit.policy.escalation_timeout_sec)
    else
      None
  in
  let draft =
    {
      detachment_id = detachment_id_for_operation operation target_count target_unit;
      operation_id = operation.operation_id;
      assigned_unit_id = target_unit.unit_id;
      leader_id = option_first_some target_unit.leader_id base.leader_id;
      roster = if target_unit.roster <> [] then target_unit.roster else base.roster;
      session_id;
      checkpoint_ref = option_first_some operation.checkpoint_ref base.checkpoint_ref;
      runtime_kind =
        (if target_count = 1 && session_id <> None then Some "team_session"
         else Some "managed");
      runtime_ref =
        (if target_count = 1 then option_first_some session_id (Some target_unit.unit_id)
         else Some target_unit.unit_id);
      source = "managed";
      status = string_of_operation_status operation.status;
      last_event_at = option_first_some session_last_event base.last_event_at;
      last_progress_at;
      heartbeat_deadline;
      created_at = base.created_at;
      updated_at = Types.now_iso ();
    }
  in
  if detachment_semantic_equal draft base then
    { draft with updated_at = base.updated_at }
  else
    draft

let default_detachment_for_operation config units (operation : operation_record) =
  let fallback_target =
    match detachment_targets_for_operation units operation with
    | target :: _ -> target
    | [] ->
        {
          unit_id = operation.assigned_unit_id;
          label = operation.assigned_unit_id;
          kind = Squad;
          parent_unit_id = None;
          leader_id = None;
          roster = [];
          capability_profile = [];
          policy = default_policy Squad;
          budget = default_budget Squad;
          source = "managed";
          created_at = operation.created_at;
          updated_at = operation.updated_at;
        }
  in
  make_detachment_runtime config fallback_target operation ~target_count:1
    ~base:
      {
        detachment_id = "det-" ^ operation.operation_id;
        operation_id = operation.operation_id;
        assigned_unit_id = fallback_target.unit_id;
        leader_id = fallback_target.leader_id;
        roster = fallback_target.roster;
        session_id = operation.detachment_session_id;
        checkpoint_ref = operation.checkpoint_ref;
        runtime_kind = None;
        runtime_ref = None;
        source = "managed";
        status = string_of_operation_status operation.status;
        last_event_at = None;
        last_progress_at = Some operation.updated_at;
        heartbeat_deadline = None;
        created_at = operation.created_at;
        updated_at = operation.updated_at;
      }

let sync_managed_detachments config units (operation : operation_record) =
  let detachments = read_detachments config in
  let existing_for_operation =
    detachments
    |> List.filter (fun (detachment : detachment_record) ->
           String.equal detachment.operation_id operation.operation_id
           && String.equal detachment.source "managed")
  in
  let targets =
    match detachment_targets_for_operation units operation with
    | [] -> []
    | rows -> rows
  in
  let target_count = max 1 (List.length targets) in
  let updated_rows =
    match targets with
    | [] ->
        [ default_detachment_for_operation config units operation ]
    | rows ->
        rows
        |> List.map (fun (target_unit : unit_record) ->
               let detachment_id =
                 detachment_id_for_operation operation target_count target_unit
               in
               let base =
                 existing_for_operation
                 |> List.find_opt (fun (detachment : detachment_record) ->
                        String.equal detachment.detachment_id detachment_id)
                 |> Option.value
                      ~default:
                        {
                          detachment_id;
                          operation_id = operation.operation_id;
                          assigned_unit_id = target_unit.unit_id;
                          leader_id = target_unit.leader_id;
                          roster = target_unit.roster;
                          session_id = operation.detachment_session_id;
                          checkpoint_ref = operation.checkpoint_ref;
                          runtime_kind = None;
                          runtime_ref = None;
                          source = "managed";
                          status = string_of_operation_status operation.status;
                          last_event_at = None;
                          last_progress_at = Some operation.updated_at;
                          heartbeat_deadline = None;
                          created_at = operation.created_at;
                          updated_at = operation.updated_at;
                        }
               in
               make_detachment_runtime config target_unit operation ~target_count ~base)
  in
  let remaining =
    detachments
    |> List.filter (fun (detachment : detachment_record) ->
           not
             (String.equal detachment.operation_id operation.operation_id
              && String.equal detachment.source "managed"))
  in
  write_detachments config (updated_rows @ remaining);
  updated_rows

let sync_managed_detachment config units (operation : operation_record) =
  match sync_managed_detachments config units operation with
  | row :: _ -> row
  | [] -> default_detachment_for_operation config units operation

let with_operation config operation_id f =
  let operations = read_operations config in
  match
    List.find_opt
      (fun (operation : operation_record) ->
        String.equal operation.operation_id operation_id)
      operations
  with
  | None -> Error (Printf.sprintf "operation not found: %s" operation_id)
  | Some current -> f operations current

let rec nearest_ancestor units unit_id predicate =
  match lookup_unit units unit_id with
  | Some unit when predicate unit -> Some unit
  | Some unit -> (
      match unit.parent_unit_id with
      | Some parent_id -> nearest_ancestor units parent_id predicate
      | None -> None)
  | None -> None

let platoon_ancestor_id units unit_id =
  nearest_ancestor units unit_id (fun (unit : unit_record) -> unit.kind = Platoon)
  |> Option.map (fun (unit : unit_record) -> unit.unit_id)

let company_ancestor_id units unit_id =
  nearest_ancestor units unit_id (fun (unit : unit_record) -> unit.kind = Company)
  |> Option.map (fun (unit : unit_record) -> unit.unit_id)

let same_platoon units left right =
  match platoon_ancestor_id units left, platoon_ancestor_id units right with
  | Some a, Some b -> String.equal a b
  | _ -> false

let list_children_of_kind units parent_id kind =
  units
  |> List.filter (fun (unit : unit_record) ->
         unit.kind = kind
         &&
         match unit.parent_unit_id with
         | Some value -> String.equal value parent_id
         | None -> false)

let candidate_units_for_operation units operations current_unit_id =
  let score_unit (unit : unit_record) =
    let active_count =
      operations
      |> List.filter (fun (operation : operation_record) ->
             active_operation_status operation.status
             && String.equal operation.assigned_unit_id unit.unit_id)
      |> List.length
    in
    let capacity_left = max 0 (unit.budget.active_operation_cap - active_count) in
    let same_parent =
      match current_unit_id with
      | Some source -> same_platoon units source unit.unit_id
      | None -> false
    in
    (if same_parent then 1000 else 0) + (capacity_left * 10) + List.length unit.roster
  in
  units
  |> List.filter (fun (unit : unit_record) ->
         (unit.kind = Squad || unit.kind = Platoon)
         && not unit.policy.kill_switch && not unit.policy.frozen)
  |> List.sort (fun a b -> compare (score_unit b, b.label) (score_unit a, a.label))

let decision_requires_approval units source_unit_id target_unit_id =
  match lookup_unit units target_unit_id with
  | None -> true
  | Some target ->
      if target.policy.approval_class = "strict" then
        true
      else
        match source_unit_id with
        | None -> false
        | Some source when String.equal source target_unit_id -> false
        | Some source -> not (same_platoon units source target_unit_id)

let company_scope_id_for units source_unit_id target_unit_id =
  option_first_some
    (Option.bind target_unit_id (fun unit_id -> company_ancestor_id units unit_id))
    (Option.bind source_unit_id (fun unit_id -> company_ancestor_id units unit_id))
  |> Option.value ~default:"company-runtime"

let find_pending_decision config ~requested_action ?operation_id ?target_unit_id () =
  all_policy_decisions config
  |> List.find_opt (fun (decision : policy_decision_record) ->
         String.equal decision.status "pending"
         && String.equal decision.requested_action requested_action
         &&
         match operation_id, decision.operation_id with
         | None, _ -> true
         | Some expected, Some actual -> String.equal expected actual
         | Some _, None -> false
         &&
         match target_unit_id, decision.target_unit_id with
         | None, _ -> true
         | Some expected, Some actual -> String.equal expected actual
         | Some _, None -> false)

let create_policy_decision config ~(actor : string) ~requested_action ~scope_type
    ~scope_id ?operation_id ?target_unit_id ~reason ?(source = "managed") detail =
  let decision =
    {
      decision_id = next_event_id "dec";
      trace_id = next_trace_id ();
      requested_action;
      scope_type;
      scope_id;
      operation_id;
      target_unit_id;
      requested_by = actor;
      status = "pending";
      reason;
      source;
      detail;
      created_at = Types.now_iso ();
      decided_at = None;
      expires_at = None;
    }
  in
  let decisions = read_policy_decisions config in
  write_policy_decisions config (decision :: decisions);
  append_cp_event config ~trace_id:decision.trace_id ~event_type:"policy_decision_requested"
    ?operation_id ?unit_id:target_unit_id ~actor
    (`Assoc
      [
        ("decision_id", `String decision.decision_id);
        ("requested_action", `String requested_action);
        ("scope_type", `String scope_type);
        ("scope_id", `String scope_id);
      ]);
  decision

let apply_operation_assignment config ~(actor : string) (operation : operation_record)
    ~target_unit_id ~note ~event_type =
  match unit_guard_json config target_unit_id with
  | Error message -> Error message
  | Ok _ ->
      let updated =
        {
          operation with
          assigned_unit_id = target_unit_id;
          note =
            (match note, operation.note with
            | Some value, _ -> Some value
            | None, existing -> existing);
          updated_at = Types.now_iso ();
        }
      in
      let operations = read_operations config in
      write_operations config (replace_operation operations updated);
      let _, _, units, _ = topology_units config in
      let _ = sync_managed_detachments config units updated in
      append_cp_event config ~trace_id:updated.trace_id ~event_type
        ~operation_id:updated.operation_id ~unit_id:updated.assigned_unit_id ~actor
        (`Assoc
          [
            ("from_unit_id", `String operation.assigned_unit_id);
            ("to_unit_id", `String target_unit_id);
          ]);
      Ok updated

let update_operation_status config ~(actor : string) ~operation_id ~status ~note ~event_type =
  with_operation config operation_id (fun operations current ->
      let updated =
        {
          current with
          status;
          note =
            (match note, current.note with
            | Some value, _ -> Some value
            | None, existing -> existing);
          updated_at = Types.now_iso ();
        }
      in
      write_operations config (replace_operation operations updated);
      let _, _, units, _ = topology_units config in
      let _ = sync_managed_detachments config units updated in
      append_cp_event config ~trace_id:updated.trace_id ~event_type
        ~operation_id:updated.operation_id ~unit_id:updated.assigned_unit_id ~actor
        (`Assoc [ ("status", `String (string_of_operation_status status)) ]);
      Ok updated)

let update_unit config ~(actor : string) ~unit_id f ~event_type detail =
  let units = read_units config in
  match lookup_unit units unit_id with
  | None -> Error (Printf.sprintf "unit not found: %s" unit_id)
  | Some current ->
      let updated : unit_record = f current in
      let validation_pool =
        List.filter
          (fun (unit : unit_record) -> not (String.equal unit.unit_id updated.unit_id))
          (effective_units_for_validation config units)
      in
      (match validate_unit_shape validation_pool updated with
      | Error message -> Error message
      | Ok () ->
          write_units config (updated :: validation_pool);
          append_cp_event config ~trace_id:(next_trace_id ()) ~event_type
            ~unit_id:updated.unit_id ~actor detail;
          Ok updated)

let start_operation config ~(actor : string) json =
  let assigned_unit_id =
    match get_string_opt json "assigned_unit_id" with
    | Some value -> value
    | None -> invalid_arg "assigned_unit_id is required"
  in
  let objective =
    match get_string_opt json "objective" with
    | Some value -> value
    | None -> invalid_arg "objective is required"
  in
  match unit_guard_json config assigned_unit_id with
  | Error message -> Error message
  | Ok _ ->
      let operation =
        {
          operation_id = next_operation_id ();
          objective;
          assigned_unit_id;
          autonomy_level = get_string_default json "autonomy_level" "L4_Autonomous";
          policy_class = get_string_default json "policy_class" "strict";
          budget_class = get_string_default json "budget_class" "standard";
          detachment_session_id = get_string_opt json "detachment_session_id";
          trace_id = next_trace_id ();
          checkpoint_ref = get_string_opt json "checkpoint_ref";
          active_goal_ids = get_string_list json "active_goal_ids";
          note = get_string_opt json "note";
          created_by = actor;
          source = "managed";
          status =
            (match
               (match get_string_opt json "status" with
               | Some value -> operation_status_of_string value
               | None -> None)
             with
            | Some value -> value
            | None -> Active);
          created_at = Types.now_iso ();
          updated_at = Types.now_iso ();
        }
      in
      let operations = read_operations config in
      write_operations config (operation :: operations);
      let _, _, units, _ = topology_units config in
      let _ = sync_managed_detachments config units operation in
      append_cp_event config ~trace_id:operation.trace_id ~event_type:"operation_started"
        ~operation_id:operation.operation_id ~unit_id:operation.assigned_unit_id ~actor
        (`Assoc
          [
            ("objective", `String operation.objective);
            ("autonomy_level", `String operation.autonomy_level);
            ("policy_class", `String operation.policy_class);
          ]);
      Ok operation

let checkpoint_operation config ~(actor : string) json =
  let operation_id =
    match get_string_opt json "operation_id" with
    | Some value -> value
    | None -> invalid_arg "operation_id is required"
  in
  let checkpoint_ref =
    match get_string_opt json "checkpoint_ref" with
    | Some value -> value
    | None -> invalid_arg "checkpoint_ref is required"
  in
  let operations = read_operations config in
  match
    List.find_opt
      (fun (operation : operation_record) ->
        String.equal operation.operation_id operation_id)
      operations
  with
  | None -> Error (Printf.sprintf "operation not found: %s" operation_id)
  | Some current ->
      let updated =
        {
          current with
          checkpoint_ref = Some checkpoint_ref;
          note =
            (match get_string_opt json "note", current.note with
            | Some note, _ -> Some note
            | None, existing -> existing);
          updated_at = Types.now_iso ();
        }
      in
      let next_operations =
        replace_operation operations updated
      in
      write_operations config next_operations;
      let _, _, units, _ = topology_units config in
      let _ = sync_managed_detachments config units updated in
      append_cp_event config ~trace_id:updated.trace_id ~event_type:"operation_checkpointed"
        ~operation_id:updated.operation_id ~unit_id:updated.assigned_unit_id ~actor
        (`Assoc [ ("checkpoint_ref", `String checkpoint_ref) ]);
      Ok updated

let pause_operation_json config ~(actor : string) json =
  match get_string_opt json "operation_id" with
  | None -> Error "operation_id is required"
  | Some operation_id ->
      Result.map operation_to_json
        (update_operation_status config ~actor ~operation_id ~status:Paused
           ~note:(get_string_opt json "note") ~event_type:"operation_paused")

let resume_operation_json config ~(actor : string) json =
  match get_string_opt json "operation_id" with
  | None -> Error "operation_id is required"
  | Some operation_id ->
      Result.map operation_to_json
        (update_operation_status config ~actor ~operation_id ~status:Active
           ~note:(get_string_opt json "note") ~event_type:"operation_resumed")

let stop_operation_json config ~(actor : string) json =
  match get_string_opt json "operation_id" with
  | None -> Error "operation_id is required"
  | Some operation_id ->
      Result.map operation_to_json
        (update_operation_status config ~actor ~operation_id ~status:Cancelled
           ~note:(get_string_opt json "note") ~event_type:"operation_stopped")

let finalize_operation_json config ~(actor : string) json =
  match get_string_opt json "operation_id" with
  | None -> Error "operation_id is required"
  | Some operation_id ->
      Result.map operation_to_json
        (update_operation_status config ~actor ~operation_id ~status:Completed
           ~note:(get_string_opt json "note") ~event_type:"operation_finalized")

let dispatch_plan_json config json =
  let _, _, units, _ = topology_units config in
  let operations = all_operations config units in
  let operation_id = get_string_opt json "operation_id" in
  let current_unit_id =
    match operation_id with
    | Some value -> operation_by_id operations value |> Option.map (fun (op : operation_record) -> op.assigned_unit_id)
    | None -> get_string_opt json "assigned_unit_id"
  in
  let candidates =
    candidate_units_for_operation units operations current_unit_id
    |> List.filter_map (fun (unit : unit_record) ->
           match unit_guard_json config unit.unit_id with
           | Ok guard ->
               Some (`Assoc [ ("unit", unit_to_json unit); ("guard", guard) ])
           | Error _ -> None)
  in
  `Assoc
    [
      ("status", `String "ok");
      ("recommended_units", `List candidates);
      ("current_unit_id", match current_unit_id with Some value -> `String value | None -> `Null);
    ]

let request_or_apply_assignment config ~(actor : string) ~requested_action json =
  let operation_id =
    match get_string_opt json "operation_id" with
    | Some value -> value
    | None -> invalid_arg "operation_id is required"
  in
  let target_unit_id =
    match get_string_opt json "target_unit_id" with
    | Some value -> value
    | None -> invalid_arg "target_unit_id is required"
  in
  with_operation config operation_id (fun _ current ->
      let _, _, units, _ = topology_units config in
      let needs_approval =
        decision_requires_approval units (Some current.assigned_unit_id) target_unit_id
      in
      if needs_approval then
        let decision =
          match
            find_pending_decision config ~requested_action ~operation_id
              ~target_unit_id ()
          with
          | Some existing -> existing
          | None ->
              create_policy_decision config ~actor ~requested_action
                ~scope_type:"company"
                ~scope_id:
                  (company_scope_id_for units (Some current.assigned_unit_id)
                     (Some target_unit_id))
                ~operation_id ~target_unit_id
                ~reason:
                  (Some
                     (Printf.sprintf "%s from %s to %s requires company approval"
                        requested_action current.assigned_unit_id target_unit_id))
                (`Assoc
                  [
                    ( "apply",
                      `Assoc
                        [
                          ("kind", `String "reassign_operation");
                          ("operation_id", `String operation_id);
                          ("target_unit_id", `String target_unit_id);
                          ( "note",
                            match get_string_opt json "note" with
                            | Some value -> `String value
                            | None -> `Null );
                        ] );
                    ( "preview",
                      `Assoc
                        [
                          ("from_unit_id", `String current.assigned_unit_id);
                          ("to_unit_id", `String target_unit_id);
                        ] );
                  ])
        in
        Ok
          (`Assoc
            [
              ("status", `String "pending_approval");
              ("decision", policy_decision_to_json decision);
              ("operations", list_operations_json config);
              ("decisions", list_policy_decisions_json config);
            ])
      else
        Result.map
          (fun operation ->
            `Assoc
              [
                ("status", `String "ok");
                ("result", operation_to_json operation);
                ("operations", list_operations_json config);
              ])
          (apply_operation_assignment config ~actor current ~target_unit_id
             ~note:(get_string_opt json "note") ~event_type:requested_action))

let dispatch_assign_json config ~(actor : string) json =
  try request_or_apply_assignment config ~actor ~requested_action:"dispatch_assign" json
  with Invalid_argument message -> Error message

let dispatch_rebalance_json config ~(actor : string) json =
  try request_or_apply_assignment config ~actor ~requested_action:"dispatch_rebalance" json
  with Invalid_argument message -> Error message

let dispatch_escalate_json config ~(actor : string) json =
  try
    let operation_id =
      match get_string_opt json "operation_id" with
      | Some value -> value
      | None -> invalid_arg "operation_id is required"
    in
    with_operation config operation_id (fun _ current ->
        let _, _, units, _ = topology_units config in
        let target_unit_id =
          match get_string_opt json "target_unit_id" with
          | Some value -> value
          | None ->
              nearest_ancestor units current.assigned_unit_id
                (fun (unit : unit_record) -> unit.kind = Platoon || unit.kind = Company)
              |> Option.map (fun (unit : unit_record) -> unit.unit_id)
              |> Option.value ~default:current.assigned_unit_id
        in
        request_or_apply_assignment config ~actor ~requested_action:"dispatch_escalate"
          (`Assoc
            [
              ("operation_id", `String operation_id);
              ("target_unit_id", `String target_unit_id);
              ("note", match get_string_opt json "note" with Some value -> `String value | None -> `Null);
            ]))
  with Invalid_argument message -> Error message

let dispatch_recall_json config ~(actor : string) json =
  match get_string_opt json "operation_id" with
  | None -> Error "operation_id is required"
  | Some operation_id ->
      Result.map
        (fun operation ->
          `Assoc
            [
              ("status", `String "ok");
              ("result", operation_to_json operation);
              ("operations", list_operations_json config);
            ])
        (update_operation_status config ~actor ~operation_id ~status:Paused
           ~note:(get_string_opt json "note") ~event_type:"dispatch_recall")

let unit_update_json config ~(actor : string) json =
  try
    match upsert_unit config ~actor json with
    | Ok unit ->
        Ok
          (`Assoc
            [
              ("status", `String "ok");
              ("result", unit_to_json unit);
              ("topology", topology_json config);
            ])
    | Error message -> Error message
  with Invalid_argument message -> Error message

let unit_reparent_json config ~(actor : string) json =
  try
    let unit_id =
      match get_string_opt json "unit_id" with
      | Some value -> value
      | None -> invalid_arg "unit_id is required"
    in
    let parent_unit_id = get_string_opt json "parent_unit_id" in
    update_unit config ~actor ~unit_id
      (fun current ->
        { current with parent_unit_id; updated_at = Types.now_iso () })
      ~event_type:"unit_reparented"
      (`Assoc [ ("parent_unit_id", match parent_unit_id with Some value -> `String value | None -> `Null) ])
    |> Result.map (fun unit ->
           `Assoc
             [
               ("status", `String "ok");
               ("result", unit_to_json unit);
               ("topology", topology_json config);
             ])
  with Invalid_argument message -> Error message

let unit_reassign_json config ~(actor : string) json =
  try
    let unit_id =
      match get_string_opt json "unit_id" with
      | Some value -> value
      | None -> invalid_arg "unit_id is required"
    in
    let leader_id = get_string_opt json "leader_id" in
    let roster =
      match U.member "roster" json with
      | `List _ -> get_string_list json "roster"
      | _ -> []
    in
    update_unit config ~actor ~unit_id
      (fun current ->
        {
          current with
          leader_id = option_first_some leader_id current.leader_id;
          roster = if roster = [] then current.roster else roster;
          updated_at = Types.now_iso ();
        })
      ~event_type:"unit_reassigned"
      (`Assoc
        [
          ("leader_id", match leader_id with Some value -> `String value | None -> `Null);
          ("roster", if roster = [] then json_list_of_strings [] else json_list_of_strings roster);
        ])
    |> Result.map (fun unit ->
           `Assoc
             [
               ("status", `String "ok");
               ("result", unit_to_json unit);
               ("topology", topology_json config);
             ])
  with Invalid_argument message -> Error message

let policy_status_json config =
  `Assoc
    [
      ("status", `String "ok");
      ("decisions", list_policy_decisions_json config);
      ("capacity", capacity_json config);
      ("topology", topology_json config);
    ]

let policy_apply_unit_toggle config ~(actor : string) ~unit_id ~event_type ~field json =
  let enabled =
    match U.member "enabled" json with
    | `Bool value -> value
    | `String raw -> String.equal (String.lowercase_ascii raw) "true"
    | _ -> get_bool_default json "enabled" true
  in
  update_unit config ~actor ~unit_id
    (fun current ->
      let policy =
        match field with
        | "kill_switch" -> { current.policy with kill_switch = enabled }
        | "frozen" -> { current.policy with frozen = enabled }
        | _ -> current.policy
      in
      { current with policy; updated_at = Types.now_iso () })
    ~event_type
    (`Assoc [ ("enabled", `Bool enabled); ("field", `String field) ])
  |> Result.map (fun unit ->
         `Assoc
           [
             ("status", `String "ok");
             ("result", unit_to_json unit);
             ("topology", topology_json config);
             ("alerts", list_alerts_json config);
           ])

let policy_freeze_unit_json config ~(actor : string) json =
  match get_string_opt json "unit_id" with
  | None -> Error "unit_id is required"
  | Some unit_id -> (
      let _, _, units, _ = topology_units config in
      let enabled =
        match U.member "enabled" json with
        | `Bool value -> value
        | `String raw -> String.equal (String.lowercase_ascii raw) "true"
        | _ -> get_bool_default json "enabled" true
      in
      match
        find_pending_decision config ~requested_action:"policy_freeze_unit"
          ~target_unit_id:unit_id ()
      with
      | Some decision ->
          Ok
            (`Assoc
              [
                ("status", `String "pending_approval");
                ("decision", policy_decision_to_json decision);
                ("decisions", list_policy_decisions_json config);
              ])
      | None ->
          let company_id = company_scope_id_for units None (Some unit_id) in
          let decision =
            create_policy_decision config ~actor
              ~requested_action:"policy_freeze_unit" ~scope_type:"company"
              ~scope_id:company_id ~target_unit_id:unit_id
              ~reason:
                (Some
                   (Printf.sprintf "%s freeze toggle on %s requires company approval"
                      (if enabled then "Enabling" else "Clearing")
                      unit_id))
              (`Assoc
                [
                  ( "apply",
                    `Assoc
                      [
                        ("kind", `String "toggle_unit_policy");
                        ("unit_id", `String unit_id);
                        ("field", `String "frozen");
                        ("enabled", `Bool enabled);
                      ] );
                ])
          in
          Ok
            (`Assoc
              [
                ("status", `String "pending_approval");
                ("decision", policy_decision_to_json decision);
                ("decisions", list_policy_decisions_json config);
              ]))

let policy_kill_switch_json config ~(actor : string) json =
  match get_string_opt json "unit_id" with
  | None -> Error "unit_id is required"
  | Some unit_id -> (
      let _, _, units, _ = topology_units config in
      let enabled =
        match U.member "enabled" json with
        | `Bool value -> value
        | `String raw -> String.equal (String.lowercase_ascii raw) "true"
        | _ -> get_bool_default json "enabled" true
      in
      match
        find_pending_decision config ~requested_action:"policy_kill_switch"
          ~target_unit_id:unit_id ()
      with
      | Some decision ->
          Ok
            (`Assoc
              [
                ("status", `String "pending_approval");
                ("decision", policy_decision_to_json decision);
                ("decisions", list_policy_decisions_json config);
              ])
      | None ->
          let company_id = company_scope_id_for units None (Some unit_id) in
          let decision =
            create_policy_decision config ~actor
              ~requested_action:"policy_kill_switch" ~scope_type:"company"
              ~scope_id:company_id ~target_unit_id:unit_id
              ~reason:
                (Some
                   (Printf.sprintf "%s kill-switch on %s requires company approval"
                      (if enabled then "Enabling" else "Clearing")
                      unit_id))
              (`Assoc
                [
                  ( "apply",
                    `Assoc
                      [
                        ("kind", `String "toggle_unit_policy");
                        ("unit_id", `String unit_id);
                        ("field", `String "kill_switch");
                        ("enabled", `Bool enabled);
                      ] );
                ])
          in
          Ok
            (`Assoc
              [
                ("status", `String "pending_approval");
                ("decision", policy_decision_to_json decision);
                ("decisions", list_policy_decisions_json config);
              ]))

let policy_update_json config ~(actor : string) json =
  try
    let unit_id =
      match get_string_opt json "unit_id" with
      | Some value -> value
      | None -> invalid_arg "unit_id is required"
    in
    let policy_json =
      match U.member "policy" json with `Assoc _ as value -> value | _ -> `Assoc []
    in
    let budget_json =
      match U.member "budget" json with `Assoc _ as value -> value | _ -> `Assoc []
    in
    update_unit config ~actor ~unit_id
      (fun current ->
        {
          current with
          policy = policy_of_json policy_json current.kind;
          budget = budget_of_json budget_json current.kind;
          updated_at = Types.now_iso ();
        })
      ~event_type:"unit_policy_updated"
      (`Assoc [ ("policy", policy_json); ("budget", budget_json) ])
    |> Result.map (fun unit ->
           `Assoc
             [
               ("status", `String "ok");
               ("result", unit_to_json unit);
               ("topology", topology_json config);
               ("capacity", capacity_json config);
             ])
  with Invalid_argument message -> Error message

let apply_policy_decision config ~(actor : string) (decision : policy_decision_record) =
  let apply =
    match U.member "apply" decision.detail with `Assoc _ as value -> value | _ -> `Assoc []
  in
  match get_string_opt apply "kind" with
  | Some "reassign_operation" -> (
      match get_string_opt apply "operation_id", get_string_opt apply "target_unit_id" with
      | Some operation_id, Some target_unit_id ->
          with_operation config operation_id (fun _ current ->
              apply_operation_assignment config ~actor current ~target_unit_id
                ~note:(get_string_opt apply "note") ~event_type:"policy_assignment_applied")
          |> Result.map operation_to_json
      | _ -> Error "decision apply payload missing operation_id or target_unit_id")
  | Some "toggle_unit_policy" -> (
      match get_string_opt apply "unit_id", get_string_opt apply "field" with
      | Some unit_id, Some field ->
          policy_apply_unit_toggle config ~actor ~unit_id
            ~event_type:
              (if String.equal field "kill_switch" then
                 "unit_kill_switch_toggled"
               else
                 "unit_freeze_toggled")
            ~field (`Assoc [ ("enabled", U.member "enabled" apply) ])
      | _ -> Error "decision apply payload missing unit_id or field")
  | Some other -> Error (Printf.sprintf "unsupported decision apply kind: %s" other)
  | None -> Error "decision apply payload missing kind"

let update_decision_status config ~(actor : string) ~decision_id ~status ?reason () =
  let decisions = read_policy_decisions config in
  match
    List.find_opt
      (fun (decision : policy_decision_record) -> String.equal decision.decision_id decision_id)
      decisions
  with
  | None -> Error (Printf.sprintf "decision not found or not managed: %s" decision_id)
  | Some decision ->
      let updated =
        {
          decision with
          status;
          reason = option_first_some reason decision.reason;
          decided_at = Some (Types.now_iso ());
        }
      in
      write_policy_decisions config
        (updated
        :: List.filter
             (fun (row : policy_decision_record) ->
               not (String.equal row.decision_id decision_id))
             decisions);
      append_cp_event config ~trace_id:updated.trace_id
        ~event_type:
          (if String.equal status "approved" then "policy_decision_approved"
           else "policy_decision_denied")
        ?operation_id:updated.operation_id ?unit_id:updated.target_unit_id ~actor
        (`Assoc [ ("decision_id", `String decision_id); ("status", `String status) ]);
      Ok updated

let policy_approve_json config ~(actor : string) json =
  match get_string_opt json "decision_id" with
  | None -> Error "decision_id is required"
  | Some decision_id ->
      let decisions = read_policy_decisions config in
      (match
         List.find_opt
           (fun (decision : policy_decision_record) -> String.equal decision.decision_id decision_id)
           decisions
       with
      | None -> Error "decision not found or is legacy projected decision"
      | Some decision ->
          if not (String.equal decision.status "pending") then
            Error "decision is not pending"
          else
            let* result = apply_policy_decision config ~actor decision in
            let* updated =
              update_decision_status config ~actor ~decision_id ~status:"approved" ()
                ?reason:(get_string_opt json "reason")
            in
            Ok
              (`Assoc
                [
                  ("status", `String "ok");
                  ("decision", policy_decision_to_json updated);
                  ("result", result);
                  ("operations", list_operations_json config);
                  ("decisions", list_policy_decisions_json config);
                ]))

let policy_deny_json config ~(actor : string) json =
  match get_string_opt json "decision_id" with
  | None -> Error "decision_id is required"
  | Some decision_id ->
      let* updated =
        update_decision_status config ~actor ~decision_id ~status:"denied" ()
          ?reason:(get_string_opt json "reason")
      in
      Ok
        (`Assoc
          [
            ("status", `String "ok");
            ("decision", policy_decision_to_json updated);
            ("decisions", list_policy_decisions_json config);
          ])

let detachment_status_detail_json _config units agents operations
    (detachment : detachment_record) =
  let now = Time_compat.now () in
  let leader_status =
    match detachment.leader_id with
    | Some leader -> agent_status_for (agent_status_map agents) leader
    | None -> "missing"
  in
  let heartbeat_expired =
    match detachment.heartbeat_deadline with
    | Some deadline -> iso_expired_at now deadline
    | None -> false
  in
  let progress_age_sec =
    Option.bind detachment.last_progress_at parse_iso_timestamp
    |> Option.map (fun ts -> max 0 (int_of_float (now -. ts)))
  in
  let unit_label =
    lookup_unit units detachment.assigned_unit_id
    |> Option.map (fun (unit : unit_record) -> unit.label)
    |> Option.value ~default:detachment.assigned_unit_id
  in
  let operation_json =
    operation_by_id operations detachment.operation_id
    |> Option.map operation_to_json |> Option.value ~default:`Null
  in
  `Assoc
    [
      ("detachment", detachment_to_json detachment);
      ("assigned_unit_label", `String unit_label);
      ("operation", operation_json);
      ("leader_status", `String leader_status);
      ("heartbeat_expired", `Bool heartbeat_expired);
      ( "progress_age_sec",
        match progress_age_sec with Some value -> `Int value | None -> `Null );
      ( "needs_attention",
        `Bool
          (heartbeat_expired
           || String.equal leader_status "offline"
           || String.equal leader_status "missing"
           || String.equal detachment.status "stalled"
           || String.equal detachment.status "awaiting_approval") );
    ]

let detachment_status_json config json =
  let operation_id = get_string_opt json "operation_id" in
  let detachment_id = get_string_opt json "detachment_id" in
  let agents, _, units, _ = topology_units config in
  let operations = all_operations config units in
  let detachments =
    all_detachments config units operations
    |> List.filter (fun (detachment : detachment_record) ->
           (match operation_id with
           | Some value -> String.equal detachment.operation_id value
           | None -> true)
           &&
           match detachment_id with
           | Some value -> String.equal detachment.detachment_id value
           | None -> true)
  in
  match detachments with
  | [] -> Error "detachment not found"
  | detachment :: _ ->
      Ok
        (`Assoc
          [
            ("status", `String "ok");
            ("result", detachment_status_detail_json config units agents operations detachment);
          ])

let stalled_or_quiet_detachment now (detachment : detachment_record) =
  match detachment.heartbeat_deadline with
  | Some deadline when iso_expired_at now deadline -> true
  | _ ->
      Option.bind detachment.last_progress_at parse_iso_timestamp
      |> Option.map (fun ts -> now -. ts > 1800.0)
      |> Option.value ~default:false

let pick_failover_leader live_agents (detachment : detachment_record) =
  detachment.roster
  |> List.filter (fun agent_name -> List.mem agent_name live_agents)
  |> List.find_opt (fun agent_name ->
         match detachment.leader_id with
         | Some current -> not (String.equal current agent_name)
         | None -> true)

let maybe_escalation_target units (detachment : detachment_record) =
  match lookup_unit units detachment.assigned_unit_id with
  | Some ({ kind = Squad; parent_unit_id = Some parent_id; _ } as _unit) -> Some parent_id
  | Some unit when unit.kind = Platoon || unit.kind = Company -> unit.parent_unit_id
  | Some ({ parent_unit_id = Some parent_id; _ } as _unit) -> Some parent_id
  | _ -> None

let dispatch_tick_json config ~(actor : string) json =
  let filter_operation_id = get_string_opt json "operation_id" in
  let filter_detachment_id = get_string_opt json "detachment_id" in
  let agents, _, units, _ = topology_units config in
  let live_agents = live_agent_names agents in
  let managed_operations =
    read_operations config
    |> List.filter (fun (operation : operation_record) ->
           match filter_operation_id with
           | Some value -> String.equal operation.operation_id value
           | None -> true)
  in
  let synced =
    managed_operations
    |> List.concat_map (fun (operation : operation_record) ->
           sync_managed_detachments config units operation)
    |> List.filter (fun (detachment : detachment_record) ->
           match filter_detachment_id with
           | Some value -> String.equal detachment.detachment_id value
           | None -> true)
  in
  let now = Time_compat.now () in
  let operations_by_id =
    List.map (fun (operation : operation_record) -> (operation.operation_id, operation))
      managed_operations
  in
  let decisions = ref [] in
  let failovers = ref [] in
  let escalations = ref [] in
  let stale_count = ref 0 in
  let upsert_detachment_row updated =
    write_detachments config (replace_detachment (read_detachments config) updated)
  in
  List.iter
    (fun (detachment : detachment_record) ->
      let is_stalled = stalled_or_quiet_detachment now detachment in
      let leader_status =
        match detachment.leader_id with
        | Some leader -> agent_status_for (agent_status_map agents) leader
        | None -> "missing"
      in
      if is_stalled then incr stale_count;
      if is_stalled || String.equal leader_status "offline" || String.equal leader_status "missing" then
        match pick_failover_leader live_agents detachment with
        | Some next_leader ->
            let refreshed =
              {
                detachment with
                leader_id = Some next_leader;
                status = "active";
                last_event_at = Some (Types.now_iso ());
                heartbeat_deadline =
                  (match lookup_unit units detachment.assigned_unit_id with
                  | Some unit ->
                      Option.bind
                        (option_first_some detachment.last_progress_at
                           (Some (Types.now_iso ())))
                        (fun base_ts ->
                          iso_after_seconds base_ts unit.policy.escalation_timeout_sec)
                  | None -> detachment.heartbeat_deadline);
                updated_at = Types.now_iso ();
              }
            in
            upsert_detachment_row refreshed;
            append_cp_event config
              ~trace_id:
                (match List.assoc_opt detachment.operation_id operations_by_id with
                | Some operation -> operation.trace_id
                | None -> next_trace_id ())
              ~event_type:"detachment_failed_over"
              ~operation_id:detachment.operation_id ~unit_id:detachment.assigned_unit_id
              ~actor
              (`Assoc
                [
                  ("detachment_id", `String detachment.detachment_id);
                  ("from_leader", match detachment.leader_id with Some value -> `String value | None -> `Null);
                  ("to_leader", `String next_leader);
                ]);
            failovers := refreshed.detachment_id :: !failovers
        | None ->
            (match
               maybe_escalation_target units detachment,
               List.assoc_opt detachment.operation_id operations_by_id
             with
            | Some target_unit_id, Some operation ->
                let pending =
                  find_pending_decision config ~requested_action:"dispatch_escalate"
                    ~operation_id:operation.operation_id ~target_unit_id ()
                in
                let refreshed =
                  {
                    detachment with
                    status =
                      (match pending with
                      | Some _ -> "awaiting_approval"
                      | None -> "stalled");
                    updated_at = Types.now_iso ();
                  }
                in
                upsert_detachment_row refreshed;
                let decision =
                  match pending with
                  | Some existing -> existing
                  | None ->
                      create_policy_decision config ~actor
                        ~requested_action:"dispatch_escalate"
                        ~scope_type:"company"
                        ~scope_id:
                          (company_scope_id_for units
                             (Some detachment.assigned_unit_id)
                             (Some target_unit_id))
                        ~operation_id:operation.operation_id
                        ~target_unit_id
                        ~reason:
                          (Some
                             (Printf.sprintf
                                "Detachment %s is stalled and needs escalation"
                                detachment.detachment_id))
                        (`Assoc
                          [
                            ( "apply",
                              `Assoc
                                [
                                  ("kind", `String "reassign_operation");
                                  ("operation_id", `String operation.operation_id);
                                  ("target_unit_id", `String target_unit_id);
                                ] );
                            ("detachment_id", `String detachment.detachment_id);
                          ])
                in
                decisions := decision.decision_id :: !decisions;
                escalations := detachment.detachment_id :: !escalations
            | _ -> ())
      else
        ())
    synced;
  let operations_json =
    list_operations_json ?operation_id:filter_operation_id config
  in
  let detachments_json =
    list_detachments_json ?operation_id:filter_operation_id ?detachment_id:filter_detachment_id
      config
  in
  Ok
    (`Assoc
      [
        ("status", `String "ok");
        ( "summary",
          `Assoc
            [
              ("operations_considered", `Int (List.length managed_operations));
              ("detachments_considered", `Int (List.length synced));
              ("stale_detachments", `Int !stale_count);
              ("failovers_applied", `Int (List.length !failovers));
              ("escalations_requested", `Int (List.length !escalations));
              ("approvals_pending", `Int (List.length !decisions));
            ] );
        ("failovers", json_list_of_strings (List.rev !failovers));
        ("escalations", json_list_of_strings (List.rev !escalations));
        ("decisions", json_list_of_strings (List.rev !decisions));
        ("operations", operations_json);
        ("detachments", detachments_json);
      ])

let observe_operations_json config =
  `Assoc
    [
      ("status", `String "ok");
      ("operations", list_operations_json config);
      ("detachments", list_detachments_json config);
    ]

let observe_capacity_json config =
  `Assoc
    [
      ("status", `String "ok");
      ("capacity", capacity_json config);
      ("alerts", list_alerts_json config);
    ]
