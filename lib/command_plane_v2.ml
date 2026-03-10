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

type chain_record = {
  kind : string;
  backend : string;
  chain_id : string option;
  goal : string option;
  run_id : string option;
  status : string;
  history_event : Yojson.Safe.t option;
  mermaid : string option;
  preview_run : Yojson.Safe.t option;
  viewer_path : string option;
  last_sync_at : string option;
}

type operation_record = {
  operation_id : string;
  objective : string;
  intent_id : string option;
  assigned_unit_id : string;
  autonomy_level : string;
  policy_class : string;
  budget_class : string;
  workload_profile : string;
  stage : string option;
  artifact_scope : string list;
  depends_on_operation_ids : string list;
  search_strategy : string;
  detachment_session_id : string option;
  trace_id : string;
  checkpoint_ref : string option;
  active_goal_ids : string list;
  note : string option;
  created_by : string;
  source : string;
  status : operation_status;
  chain : chain_record option;
  created_at : string;
  updated_at : string;
}

type intent_state =
  | Adopted
  | Active_intent
  | Blocked_intent
  | Suspended_intent
  | Handoff_ready
  | Completed_intent
  | Dropped_intent

type intent_focus = {
  stage : string option;
  artifact_scope : string list;
  unit_id : string option;
  verification_state : string option;
}

type intent_record = {
  intent_id : string;
  title : string;
  owner : string;
  workload_profile : string;
  success_metric : Yojson.Safe.t option;
  invariants : string list;
  artifact_priors : string list;
  state : intent_state;
  current_focus : intent_focus;
  checkpoint_ref : string option;
  source : string;
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

let control_plane_root_dir config =
  Filename.concat (Room_utils.masc_root_dir config) "control-plane"

let legacy_control_plane_root_dir config =
  Filename.concat (Filename.concat config.Room.base_path ".masc") "control-plane"

let units_path config =
  Filename.concat (control_plane_dir config) "units.json"

let operations_path config =
  Filename.concat (control_plane_dir config) "operations.json"

let intents_path config =
  Filename.concat (control_plane_dir config) "intents.json"

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

let swarm_live_dirs config =
  List.sort_uniq String.compare
    [
      Filename.concat (control_plane_root_dir config) "swarm-live";
      Filename.concat (legacy_control_plane_root_dir config) "swarm-live";
    ]

let swarm_live_run_dirs config run_id =
  let normalized =
    let filename = Room_utils.safe_filename run_id in
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
    let value = String.trim collapsed in
    if value = "" then "auto" else value
  in
  swarm_live_dirs config
  |> List.concat_map (fun dir ->
         [ Filename.concat dir normalized; Filename.concat dir run_id ])
  |> List.sort_uniq String.compare

let find_swarm_live_artifact_path config run_id filename =
  swarm_live_run_dirs config run_id
  |> List.find_map (fun dir ->
         let path = Filename.concat dir filename in
         if Sys.file_exists path || Room_utils.path_exists config path then Some path else None)

let find_swarm_live_artifact_json config run_id filename =
  match find_swarm_live_artifact_path config run_id filename with
  | Some path when Sys.file_exists path -> Some (Room_utils.read_json_local path)
  | Some path -> Room_utils.read_json_opt config path
  | None -> None

let search_stats_path config =
  Filename.concat (control_plane_dir config) "search-stats.json"
module StringSet = Set.Make (String)

let nonempty_string = function
  | Some raw ->
      let value = String.trim raw in
      if value = "" then None else Some value
  | None -> None

let dedup_strings xs =
  let _, acc =
    List.fold_left
      (fun (seen, acc) x ->
        if StringSet.mem x seen then (seen, acc)
        else (StringSet.add x seen, x :: acc))
      (StringSet.empty, []) xs
  in
  List.rev acc

let filter_nonempty_strings xs =
  xs
  |> List.filter_map (fun raw ->
         let value = String.trim raw in
         if value = "" then None else Some value)
  |> dedup_strings

let option_first_some left right =
  match left with
  | Some _ -> left
  | None -> right

let option_or_else left right =
  match left with
  | Some _ -> left
  | None -> right ()

let option_exists predicate = function
  | Some value -> predicate value
  | None -> false

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
  let normalized = String.trim collapsed in
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

let operation_workload_profile (operation : operation_record) =
  Cp_search_fabric.normalized_workload_profile operation.workload_profile

let operation_search_strategy (operation : operation_record) =
  Cp_search_fabric.strategy_of_string (Some operation.search_strategy)

let operation_stage_key (operation : operation_record) =
  Cp_search_fabric.normalized_stage operation.stage

let validate_workload_profile raw =
  match Cp_search_fabric.normalized_workload_profile raw with
  | "coding_task" | "research_pipeline" as value -> Ok value
  | other -> Error (Printf.sprintf "unsupported workload_profile: %s" other)

let normalize_stage = function
  | Some value ->
      let trimmed = String.trim value |> String.lowercase_ascii in
      if trimmed = "" then None else Some trimmed
  | None -> None

let validate_stage_for_workload ~workload_profile stage =
  let stage = normalize_stage stage in
  let allowed =
    match workload_profile with
    | "coding_task" -> [ "decompose"; "inspect"; "implement"; "verify"; "review" ]
    | "research_pipeline" -> [ "normalize"; "verify"; "curate"; "rank"; "audit" ]
    | _ -> []
  in
  match stage with
  | None -> Ok None
  | Some value when List.mem value allowed -> Ok (Some value)
  | Some value ->
      Error
        (Printf.sprintf "unsupported %s stage: %s" workload_profile value)

let validate_search_strategy = function
  | "legacy" | "best_first_v1" as value -> Ok value
  | other -> Error (Printf.sprintf "unsupported search_strategy: %s" other)

let room_search_strategy_default config =
  match (Room.read_state config).search_strategy_default with
  | Some ("legacy" | "best_first_v1" as value) -> value
  | _ -> "best_first_v1"

let room_speculation_enabled config =
  (Room.read_state config).speculation_enabled

let room_speculation_budget config =
  match (Room.read_state config).speculation_budget with
  | Some value when value > 0 -> value
  | _ -> 2

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

let string_of_intent_state = function
  | Adopted -> "adopted"
  | Active_intent -> "active"
  | Blocked_intent -> "blocked"
  | Suspended_intent -> "suspended"
  | Handoff_ready -> "handoff_ready"
  | Completed_intent -> "completed"
  | Dropped_intent -> "dropped"

let intent_state_of_string = function
  | "adopted" -> Some Adopted
  | "active" -> Some Active_intent
  | "blocked" -> Some Blocked_intent
  | "suspended" -> Some Suspended_intent
  | "handoff_ready" -> Some Handoff_ready
  | "completed" -> Some Completed_intent
  | "dropped" -> Some Dropped_intent
  | _ -> None

let intent_focus_to_json (focus : intent_focus) =
  `Assoc
    [
      ("stage", match focus.stage with Some value -> `String value | None -> `Null);
      ("artifact_scope", json_list_of_strings focus.artifact_scope);
      ("unit_id", match focus.unit_id with Some value -> `String value | None -> `Null);
      ( "verification_state",
        match focus.verification_state with
        | Some value -> `String value
        | None -> `Null );
    ]

let intent_focus_of_json json =
  {
    stage = get_string_opt json "stage";
    artifact_scope = get_string_list json "artifact_scope";
    unit_id = get_string_opt json "unit_id";
    verification_state = get_string_opt json "verification_state";
  }

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
  let chain_json =
    match operation.chain with
    | Some chain ->
        `Assoc
          [
            ("kind", `String chain.kind);
            ("backend", `String chain.backend);
            ("chain_id", match chain.chain_id with Some value -> `String value | None -> `Null);
            ("goal", match chain.goal with Some value -> `String value | None -> `Null);
            ("run_id", match chain.run_id with Some value -> `String value | None -> `Null);
            ("status", `String chain.status);
            ("history_event", match chain.history_event with Some value -> value | None -> `Null);
            ("mermaid", match chain.mermaid with Some value -> `String value | None -> `Null);
            ("preview_run", match chain.preview_run with Some value -> value | None -> `Null);
            ("viewer_path", match chain.viewer_path with Some value -> `String value | None -> `Null);
            ("last_sync_at", match chain.last_sync_at with Some value -> `String value | None -> `Null);
          ]
    | None -> `Null
  in
  `Assoc
    [
      ("operation_id", `String operation.operation_id);
      ("objective", `String operation.objective);
      ("intent_id", match operation.intent_id with Some value -> `String value | None -> `Null);
      ("assigned_unit_id", `String operation.assigned_unit_id);
      ("autonomy_level", `String operation.autonomy_level);
      ("policy_class", `String operation.policy_class);
      ("budget_class", `String operation.budget_class);
      ("workload_profile", `String (operation_workload_profile operation));
      ("stage", match operation.stage with Some value -> `String value | None -> `Null);
      ("artifact_scope", json_list_of_strings operation.artifact_scope);
      ("depends_on_operation_ids", json_list_of_strings operation.depends_on_operation_ids);
      ("search_strategy", `String operation.search_strategy);
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
      ("chain", chain_json);
      ("created_at", `String operation.created_at);
      ("updated_at", `String operation.updated_at);
    ]

let operation_of_json json =
  let chain_of_json = function
    | (`Assoc _ as value) -> (
        match get_string_opt value "kind", get_string_opt value "status" with
        | Some kind, Some status ->
            Some
              {
                kind;
                backend = get_string_default value "backend" "legacy";
                chain_id = get_string_opt value "chain_id";
                goal = get_string_opt value "goal";
                run_id = get_string_opt value "run_id";
                status;
                history_event =
                  (match U.member "history_event" value with
                  | `Null -> None
                  | `Assoc _ as json -> Some json
                  | _ -> None);
                mermaid = get_string_opt value "mermaid";
                preview_run =
                  (match U.member "preview_run" value with
                  | `Null -> None
                  | `Assoc _ as json -> Some json
                  | _ -> None);
                viewer_path = get_string_opt value "viewer_path";
                last_sync_at = get_string_opt value "last_sync_at";
              }
        | _ -> None)
    | _ -> None
  in
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
            intent_id = get_string_opt json "intent_id";
            assigned_unit_id;
            autonomy_level = get_string_default json "autonomy_level" "L4_Autonomous";
            policy_class = get_string_default json "policy_class" "strict";
            budget_class = get_string_default json "budget_class" "standard";
            workload_profile =
              Cp_search_fabric.normalized_workload_profile
                (get_string_default json "workload_profile" "coding_task");
            stage = normalize_stage (get_string_opt json "stage");
            artifact_scope = get_string_list json "artifact_scope";
            depends_on_operation_ids = get_string_list json "depends_on_operation_ids";
            search_strategy = get_string_default json "search_strategy" "best_first_v1";
            detachment_session_id = get_string_opt json "detachment_session_id";
            trace_id;
            checkpoint_ref = get_string_opt json "checkpoint_ref";
            active_goal_ids = get_string_list json "active_goal_ids";
            note = get_string_opt json "note";
            created_by;
            source = get_string_default json "source" "managed";
            status;
            chain =
              (match U.member "chain" json with
              | `Assoc _ as value -> chain_of_json value
              | _ -> None);
            created_at = get_string_default json "created_at" (Types.now_iso ());
            updated_at = get_string_default json "updated_at" (Types.now_iso ());
          }

let intent_to_json (intent : intent_record) =
  `Assoc
    [
      ("intent_id", `String intent.intent_id);
      ("title", `String intent.title);
      ("owner", `String intent.owner);
      ("workload_profile", `String intent.workload_profile);
      ( "success_metric",
        match intent.success_metric with Some value -> value | None -> `Null );
      ("invariants", json_list_of_strings intent.invariants);
      ("artifact_priors", json_list_of_strings intent.artifact_priors);
      ("state", `String (string_of_intent_state intent.state));
      ("current_focus", intent_focus_to_json intent.current_focus);
      ("checkpoint_ref", match intent.checkpoint_ref with Some value -> `String value | None -> `Null);
      ("source", `String intent.source);
      ("created_at", `String intent.created_at);
      ("updated_at", `String intent.updated_at);
    ]

let intent_of_json json =
  match
    get_string_opt json "intent_id",
    get_string_opt json "title",
    get_string_opt json "owner",
    get_string_opt json "workload_profile",
    get_string_opt json "state"
  with
  | Some intent_id, Some title, Some owner, Some workload_profile, Some state_raw -> (
      match intent_state_of_string state_raw with
      | Some state ->
          Some
            {
              intent_id;
              title;
              owner;
              workload_profile =
                Cp_search_fabric.normalized_workload_profile workload_profile;
              success_metric =
                (match U.member "success_metric" json with
                | `Null -> None
                | value -> Some value);
              invariants = get_string_list json "invariants";
              artifact_priors = get_string_list json "artifact_priors";
              state;
              current_focus =
                (match U.member "current_focus" json with
                | `Assoc _ as value -> intent_focus_of_json value
                | _ ->
                    {
                      stage = None;
                      artifact_scope = [];
                      unit_id = None;
                      verification_state = None;
                    });
              checkpoint_ref = get_string_opt json "checkpoint_ref";
              source = get_string_default json "source" "managed";
              created_at = get_string_default json "created_at" (Types.now_iso ());
              updated_at = get_string_default json "updated_at" (Types.now_iso ());
            }
      | None -> None)
  | _ -> None

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

let read_search_stats config =
  ensure_dirs config;
  Cp_search_fabric.load_store (search_stats_path config)

let write_search_stats config store =
  ensure_dirs config;
  Cp_search_fabric.save_store (search_stats_path config) store

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

let read_intents config =
  ensure_dirs config;
  if not (Room_utils.path_exists config (intents_path config)) then
    []
  else
    match Room_utils.read_json_opt config (intents_path config) with
    | Some (`Assoc fields) -> (
        match List.assoc_opt "intents" fields with
        | Some (`List rows) -> List.filter_map intent_of_json rows
        | _ -> [])
    | Some (`List rows) -> List.filter_map intent_of_json rows
    | _ -> []

let write_intents config intents =
  ensure_dirs config;
  Room_utils.write_json config (intents_path config)
    (`Assoc
      [
        ("version", `String "cp-v2");
        ("updated_at", `String (Types.now_iso ()));
        ("intents", `List (List.map intent_to_json intents));
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
              let trimmed = String.trim line in
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

let next_intent_id () =
  next_event_id "intent"

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
           intent_id = None;
           assigned_unit_id;
           autonomy_level =
             Team_session_types.orchestration_mode_to_string session.orchestration_mode;
           policy_class =
             Team_session_types.execution_scope_to_string session.execution_scope;
           budget_class =
             Team_session_types.communication_mode_to_string session.communication_mode;
           workload_profile = "coding_task";
           stage = Some "implement";
           artifact_scope = [];
           depends_on_operation_ids = [];
           search_strategy = room_search_strategy_default config;
           detachment_session_id = Some session.session_id;
           trace_id = session.session_id;
           checkpoint_ref = nonempty_string (Some session.artifacts_dir);
           active_goal_ids = [];
           note = session.stop_reason;
           created_by = session.created_by;
           source = "projected";
           status = operation_status_of_session session.status;
           chain = None;
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
            intent_id = None;
            assigned_unit_id;
            autonomy_level = "L5_Independent";
            policy_class = "swarm";
            budget_class = "adaptive";
            workload_profile = "coding_task";
            stage = None;
            artifact_scope = [];
            depends_on_operation_ids = [];
            search_strategy = room_search_strategy_default config;
            detachment_session_id = None;
            trace_id = "swarm-trace-" ^ safe_slug swarm_id;
            checkpoint_ref = None;
            active_goal_ids = [];
            note = Some (Printf.sprintf "Projected from .masc/swarm.json with behavior=%s" behavior);
            created_by = "swarm";
            source = "projected";
            status = Active;
            chain = None;
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

type snapshot_state = {
  config : Room.config;
  agents : Types.agent list;
  managed_units : unit_record list;
  units : unit_record list;
  source : string;
  intents : intent_record list;
  operations : operation_record list;
  detachments : detachment_record list;
  decisions : policy_decision_record list;
  live_agents : string list;
  status_map : (string * string) list;
  child_map : (string * unit_record list) list;
  unit_lookup : (string * unit_record) list;
}

let build_snapshot_state config =
  let agents, managed_units, units, source = topology_units config in
  let intents = read_intents config in
  let operations = all_operations config units in
  let detachments = all_detachments config units operations in
  let decisions = all_policy_decisions config in
  let live_agents = live_agent_names agents in
  let status_map = agent_status_map agents in
  let child_map = children_map units in
  let unit_lookup = unit_map units in
  {
    config;
    agents;
    managed_units;
    units;
    source;
    intents;
    operations;
    detachments;
    decisions;
    live_agents;
    status_map;
    child_map;
    unit_lookup;
  }

let topology_json_from_state (state : snapshot_state) =
  let agents = state.agents in
  let managed_units = state.managed_units in
  let units = state.units in
  let source = state.source in
  let operations = state.operations in
  let child_map = state.child_map in
  let lookup = state.unit_lookup in
  let roots =
    units
    |> List.filter (fun (unit : unit_record) ->
           match unit.parent_unit_id with
           | None -> true
           | Some parent_id -> lookup_unit units parent_id = None)
    |> List.sort (fun (a : unit_record) (b : unit_record) ->
           compare (kind_order a.kind, a.label) (kind_order b.kind, b.label))
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

let topology_json config =
  topology_json_from_state (build_snapshot_state config)

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

let list_detachments_json_from_state ?operation_id ?detachment_id
    (state : snapshot_state) =
  let units = state.units in
  let operations = state.operations in
  let detachments =
    state.detachments
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

let list_detachments_json ?operation_id ?detachment_id config =
  list_detachments_json_from_state ?operation_id ?detachment_id
    (build_snapshot_state config)

let list_policy_decisions_json_from_state ?decision_id (state : snapshot_state) =
  let decisions =
    state.decisions
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

let list_policy_decisions_json ?decision_id config =
  list_policy_decisions_json_from_state ?decision_id (build_snapshot_state config)

let capacity_json_from_state (state : snapshot_state) =
  let units = state.units in
  let operations = state.operations in
  let live_agents = state.live_agents in
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

let capacity_json config =
  capacity_json_from_state (build_snapshot_state config)

let list_alerts_json_from_state config (state : snapshot_state) =
  let units = state.units in
  let operations = state.operations in
  let live_agents = state.live_agents in
  let status_map = state.status_map in
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
  state.decisions
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

let list_alerts_json config =
  list_alerts_json_from_state config (build_snapshot_state config)

let iso_of_unix timestamp =
  let tm = Unix.gmtime timestamp in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
    tm.tm_hour tm.tm_min tm.tm_sec

let file_mtime path =
  try Some (Unix.stat path).st_mtime with _ -> None

let read_jsonl_local path =
  match Safe_ops.read_file_safe path with
  | Error _ -> []
  | Ok content ->
      content
      |> String.split_on_char '\n'
      |> List.filter_map (fun line ->
             let trimmed = String.trim line in
             if trimmed = "" then None
             else
               match Safe_ops.parse_json_safe ~context:path trimmed with
               | Ok json -> Some json
               | Error _ -> None)

let swarm_live_dir config =
  Filename.concat (control_plane_dir config) "swarm-live"

type swarm_live_artifact = {
  run_id : string;
  run_dir : string;
  path : string;
  captured_at : float;
}

type slot_metrics = {
  peak_hot_slots : int option;
  ctx_per_slot : int option;
  captured_at : string option;
}

type runtime_doctor = {
  checked_at : string option;
  provider_base_url : string option;
  provider_reachable : bool option;
  provider_status_code : int option;
  provider_error : string option;
  provider_model_id : string option;
  actual_model_id : string option;
  slot_url : string option;
  slot_reachable : bool option;
  slot_status_code : int option;
  expected_slots : int option;
  actual_slots : int option;
  expected_ctx : int option;
  actual_ctx : int option;
  runtime_blocker : string option;
  detail : string option;
}

let latest_swarm_live_artifact config filename =
  let root = swarm_live_dir config in
  match Safe_ops.list_dir_safe root with
  | Error _ -> None
  | Ok entries ->
      entries
      |> List.filter_map (fun run_id ->
             let run_dir = Filename.concat root run_id in
             if Sys.file_exists run_dir && Sys.is_directory run_dir then
               let path = Filename.concat run_dir filename in
               match file_mtime path with
               | Some captured_at ->
                   Some { run_id; run_dir; path; captured_at }
               | None -> None
             else None)
      |> List.sort (fun (left : swarm_live_artifact) (right : swarm_live_artifact) ->
             Float.compare right.captured_at left.captured_at)
      |> list_hd_opt

let read_slot_metrics_from_json path =
  match Safe_ops.read_json_file_safe path with
  | Error _ -> None
  | Ok json ->
      Some
        {
          peak_hot_slots =
            (match U.member "peak_active_slots" json with
            | `Int value -> Some value
            | `Intlit value -> int_of_string_opt value
            | _ -> None);
          ctx_per_slot =
            (match U.member "ctx_per_slot" json with
            | `Int value -> Some value
            | `Intlit value -> int_of_string_opt value
            | _ -> None);
          captured_at = get_string_opt json "last_sample_at";
        }

let read_slot_metrics_from_samples path =
  let rows = read_jsonl_local path in
  let peak_hot_slots =
    rows
    |> List.fold_left
         (fun acc row ->
           max acc
             (match U.member "active_slots" row with
             | `Int value -> value
             | `Intlit value -> Option.value ~default:0 (int_of_string_opt value)
             | _ -> 0))
         0
  in
  let ctx_per_slot =
    rows
    |> List.find_map (fun row ->
           match U.member "ctx_per_slot" row with
           | `Int value -> Some value
           | `Intlit value -> int_of_string_opt value
           | _ -> None)
  in
  let captured_at =
    rows
    |> List.rev
    |> List.find_map (fun row -> get_string_opt row "timestamp")
  in
  if rows = [] then None
  else Some { peak_hot_slots = Some peak_hot_slots; ctx_per_slot; captured_at }

let read_slot_metrics run_dir =
  let telemetry_path = Filename.concat run_dir "slot-telemetry.json" in
  if Sys.file_exists telemetry_path then
    read_slot_metrics_from_json telemetry_path
  else
    let samples_path = Filename.concat run_dir "slot-samples.jsonl" in
    if Sys.file_exists samples_path then read_slot_metrics_from_samples samples_path
    else None

let read_runtime_doctor_json run_dir =
  let doctor_path = Filename.concat run_dir "runtime-doctor.json" in
  if not (Sys.file_exists doctor_path) then
    None
  else
    match Safe_ops.read_json_file_safe doctor_path with
    | Error _ -> None
    | Ok json ->
        Some
          {
            checked_at = get_string_opt json "checked_at";
            provider_base_url = get_string_opt json "provider_base_url";
            provider_reachable = U.member "provider_reachable" json |> U.to_bool_option;
            provider_status_code = U.member "provider_status_code" json |> U.to_int_option;
            provider_error = get_string_opt json "provider_error";
            provider_model_id = get_string_opt json "provider_model_id";
            actual_model_id = get_string_opt json "actual_model_id";
            slot_url = get_string_opt json "slot_url";
            slot_reachable = U.member "slot_reachable" json |> U.to_bool_option;
            slot_status_code = U.member "slot_status_code" json |> U.to_int_option;
            expected_slots = U.member "expected_slots" json |> U.to_int_option;
            actual_slots = U.member "actual_slots" json |> U.to_int_option;
            expected_ctx = U.member "expected_ctx" json |> U.to_int_option;
            actual_ctx = U.member "actual_ctx" json |> U.to_int_option;
            runtime_blocker = get_string_opt json "runtime_blocker";
            detail = get_string_opt json "detail";
          }

let swarm_proof_json config =
  let workers_json
      ?expected ?joined ?current_task_bound ?fresh_heartbeats ?done_workers
      ?final_markers () =
    `Assoc
      [
        ("expected", Option.value ~default:`Null (Option.map (fun v -> `Int v) expected));
        ("joined", Option.value ~default:`Null (Option.map (fun v -> `Int v) joined));
        ( "current_task_bound",
          Option.value ~default:`Null
            (Option.map (fun v -> `Int v) current_task_bound) );
        ( "fresh_heartbeats",
          Option.value ~default:`Null
            (Option.map (fun v -> `Int v) fresh_heartbeats) );
        ("done", Option.value ~default:`Null (Option.map (fun v -> `Int v) done_workers));
        ("final", Option.value ~default:`Null (Option.map (fun v -> `Int v) final_markers));
      ]
  in
  match latest_swarm_live_artifact config "swarm-live-summary.json" with
  | Some summary_artifact -> (
      match Safe_ops.read_json_file_safe summary_artifact.path with
      | Ok summary_json ->
          let slot_metrics = read_slot_metrics summary_artifact.run_dir in
          let captured_at =
            Option.value
              ~default:(iso_of_unix summary_artifact.captured_at)
              (Option.bind slot_metrics (fun metrics -> metrics.captured_at))
          in
          `Assoc
            [
              ("status", `String "present");
              ("source", `String "artifact");
              ("run_id", `String summary_artifact.run_id);
              ("captured_at", `String captured_at);
              ( "pass",
                match U.member "pass" summary_json with
                | `Bool value -> `Bool value
                | _ -> `Null );
              ( "peak_hot_slots",
                match Option.bind slot_metrics (fun metrics -> metrics.peak_hot_slots) with
                | Some value -> `Int value
                | None -> `Null );
              ( "ctx_per_slot",
                match Option.bind slot_metrics (fun metrics -> metrics.ctx_per_slot) with
                | Some value -> `Int value
                | None -> `Null );
              ( "workers",
                workers_json
                  ?expected:
                    (match U.member "worker_count" summary_json with
                    | `Int value -> Some value
                    | `Intlit value -> int_of_string_opt value
                    | _ -> None)
                  ?done_workers:
                    (match U.member "completed_workers" summary_json with
                    | `Int value -> Some value
                    | `Intlit value -> int_of_string_opt value
                    | _ -> None)
                  ?final_markers:
                    (match U.member "final_markers_seen" summary_json with
                    | `Int value -> Some value
                    | `Intlit value -> int_of_string_opt value
                    | _ -> None)
                  () );
              ("artifact_ref", `String summary_artifact.path);
              ("missing_reason", `Null);
            ]
      | Error _ -> `Assoc
          [
            ("status", `String "missing");
            ("source", `String "none");
            ("run_id", `Null);
            ("captured_at", `Null);
            ("pass", `Null);
            ("peak_hot_slots", `Null);
            ("ctx_per_slot", `Null);
            ("workers", workers_json ());
            ("artifact_ref", `Null);
            ( "missing_reason",
              `String
                "Latest swarm-live summary artifact could not be read." );
          ] )
  | None -> (
      match latest_swarm_live_artifact config "slot-samples.jsonl" with
      | Some slot_artifact -> (
          match read_slot_metrics_from_samples slot_artifact.path with
          | Some metrics ->
              `Assoc
                [
                  ("status", `String "fallback");
                  ("source", `String "slot_samples");
                  ("run_id", `String slot_artifact.run_id);
                  ( "captured_at",
                    match metrics.captured_at with
                    | Some value -> `String value
                    | None -> `String (iso_of_unix slot_artifact.captured_at) );
                  ("pass", `Null);
                  ( "peak_hot_slots",
                    match metrics.peak_hot_slots with
                    | Some value -> `Int value
                    | None -> `Null );
                  ( "ctx_per_slot",
                    match metrics.ctx_per_slot with
                    | Some value -> `Int value
                    | None -> `Null );
                  ("workers", workers_json ());
                  ("artifact_ref", `String slot_artifact.path);
                  ( "missing_reason",
                    `String
                      "Only slot samples were found; worker completion proof is unavailable." );
                ]
          | None ->
              `Assoc
                [
                  ("status", `String "missing");
                  ("source", `String "none");
                  ("run_id", `Null);
                  ("captured_at", `Null);
                  ("pass", `Null);
                  ("peak_hot_slots", `Null);
                  ("ctx_per_slot", `Null);
                  ("workers", workers_json ());
                  ("artifact_ref", `Null);
                  ( "missing_reason",
                    `String
                      "Latest slot sample artifact could not be read." );
                ] )
      | None ->
          `Assoc
            [
              ("status", `String "missing");
              ("source", `String "none");
              ("run_id", `Null);
              ("captured_at", `Null);
              ("pass", `Null);
              ("peak_hot_slots", `Null);
              ("ctx_per_slot", `Null);
              ("workers", workers_json ());
              ("artifact_ref", `Null);
              ( "missing_reason",
                `String
                  "No swarm-live proof artifacts were found under .masc/control-plane/swarm-live." );
            ] )

let topology_summary_json_from_state (state : snapshot_state) =
  let summary =
    {
      total_units = List.length state.units;
      company_count =
        List.length
          (List.filter
             (fun (unit : unit_record) -> unit.kind = Company)
             state.units);
      platoon_count =
        List.length
          (List.filter
             (fun (unit : unit_record) -> unit.kind = Platoon)
             state.units);
      squad_count =
        List.length
          (List.filter
             (fun (unit : unit_record) -> unit.kind = Squad)
             state.units);
      leaf_agent_unit_count =
        List.length
          (List.filter
             (fun (unit : unit_record) -> unit.kind = Agent_unit)
             state.units);
      live_agent_count = List.length state.live_agents;
      managed_unit_count = List.length state.managed_units;
      active_operation_count =
        state.operations
        |> List.filter (fun (operation : operation_record) ->
               active_operation_status operation.status)
        |> List.length;
    }
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("source", `String state.source);
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
    ]

let operations_summary_json_from_state (state : snapshot_state) =
  let search_store = read_search_stats state.config in
  let readiness_of_operation (operation : operation_record) =
    let blockers =
      operation.depends_on_operation_ids
      |> List.filter_map (fun dep_id ->
             match operation_by_id state.operations dep_id with
             | Some upstream when upstream.status = Completed -> None
             | Some upstream when Option.is_some upstream.checkpoint_ref -> None
             | Some _upstream ->
                 Some
                   {
                     Cp_microarch_summary.strategy = operation.search_strategy;
                     readiness = "blocked";
                     status = string_of_operation_status operation.status;
                     candidate_count = 0;
                     best_score = None;
                     workload_profile = operation_workload_profile operation;
                     stage = operation.stage;
                     artifact_scope_count = List.length operation.artifact_scope;
                     artifact_scope_key =
                       (match List.sort_uniq String.compare operation.artifact_scope with
                       | [] -> None
                       | scopes -> Some (String.concat "|" scopes));
                   }
             | None ->
                 Some
                   {
                     Cp_microarch_summary.strategy = operation.search_strategy;
                     readiness = "blocked";
                     status = string_of_operation_status operation.status;
                     candidate_count = 0;
                     best_score = None;
                     workload_profile = operation_workload_profile operation;
                     stage = operation.stage;
                     artifact_scope_count = List.length operation.artifact_scope;
                     artifact_scope_key =
                       (match List.sort_uniq String.compare operation.artifact_scope with
                       | [] -> None
                       | scopes -> Some (String.concat "|" scopes));
                   })
    in
    if blockers = [] then "ready" else "blocked"
  in
  let search_rows =
    List.map
      (fun (operation : operation_record) ->
        let stats =
          Cp_search_fabric.lookup_stats search_store
            ~unit_id:operation.assigned_unit_id
            ~workload_profile:(operation_workload_profile operation)
            ~stage:(operation_stage_key operation)
        in
        {
          Cp_microarch_summary.strategy = operation.search_strategy;
          readiness = readiness_of_operation operation;
          status = string_of_operation_status operation.status;
          candidate_count =
            (match operation_search_strategy operation with
            | Cp_search_fabric.Best_first_v1 -> 1
            | Cp_search_fabric.Legacy -> 0);
          best_score =
            (match operation_search_strategy operation with
            | Cp_search_fabric.Best_first_v1 ->
                Some (Cp_search_fabric.posterior_mean stats *. 100.0)
            | Cp_search_fabric.Legacy -> None);
          workload_profile = operation_workload_profile operation;
          stage = operation.stage;
          artifact_scope_count = List.length operation.artifact_scope;
          artifact_scope_key =
            (match List.sort_uniq String.compare operation.artifact_scope with
            | [] -> None
            | scopes -> Some (String.concat "|" scopes));
        })
      state.operations
  in
  let managed_count =
    List.length
      (List.filter
         (fun (operation : operation_record) -> operation.source = "managed")
         state.operations)
  in
  let active_count =
    List.length
      (List.filter
         (fun (operation : operation_record) -> operation.status = Active)
         state.operations)
  in
  let paused_count =
    List.length
      (List.filter
         (fun (operation : operation_record) -> operation.status = Paused)
         state.operations)
  in
  let microarch = Cp_microarch_summary.summary_json ~search_rows in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length state.operations));
            ("active", `Int active_count);
            ("paused", `Int paused_count);
            ("managed", `Int managed_count);
            ("projected", `Int (List.length state.operations - managed_count));
          ] );
      ("microarch", microarch);
    ]

let detachments_summary_json_from_state (state : snapshot_state) =
  let projected_count =
    List.length
      (List.filter
         (fun (detachment : detachment_record) -> detachment.source <> "managed")
         state.detachments)
  in
  let count_status status =
    List.length
      (List.filter
         (fun (detachment : detachment_record) ->
           String.equal detachment.status status)
         state.detachments)
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length state.detachments));
            ("active", `Int (count_status "active"));
            ("awaiting_approval", `Int (count_status "awaiting_approval"));
            ("stalled", `Int (count_status "stalled"));
            ("projected", `Int projected_count);
          ] );
    ]

let intents_summary_json_from_state (state : snapshot_state) =
  let count_state target =
    state.intents
    |> List.filter (fun (intent : intent_record) -> intent.state = target)
    |> List.length
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length state.intents));
            ("active", `Int (count_state Active_intent));
            ("blocked", `Int (count_state Blocked_intent));
            ("handoff_ready", `Int (count_state Handoff_ready));
          ] );
      ("intents", `List (List.map intent_to_json state.intents));
    ]

let summary_json config =
  let state = build_snapshot_state config in
  let alerts =
    list_alerts_json_from_state config state
    |> U.member "summary"
  in
  let decisions =
    list_policy_decisions_json_from_state state
    |> U.member "summary"
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("topology", topology_summary_json_from_state state);
      ("intents", intents_summary_json_from_state state);
      ("operations", operations_summary_json_from_state state);
      ("detachments", detachments_summary_json_from_state state);
      ("alerts", `Assoc [ ("summary", alerts) ]);
      ("decisions", `Assoc [ ("summary", decisions) ]);
      ("swarm_proof", swarm_proof_json config);
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
              let trimmed = String.trim line in
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

let string_contains ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len = 0 then true
  else
    let rec loop idx =
      if idx + needle_len > haystack_len then false
      else if String.sub haystack idx needle_len = needle then true
      else loop (idx + 1)
    in
    loop 0

let string_contains_ci ~needle haystack =
  string_contains ~needle:(String.lowercase_ascii needle)
    (String.lowercase_ascii haystack)

let json_string_opt key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let json_event_field event key =
  Option.bind (json_string_opt key event) (function
    | `String value -> Some value
    | _ -> None)

let float_age_seconds timestamp =
  Option.map
    (fun ts -> max 0. (Unix.gettimeofday () -. ts))
    (Room.parse_iso_time_opt timestamp)

let timestamp_on_or_after ~boundary timestamp =
  match Room.parse_iso_time_opt timestamp with
  | Some ts -> ts >= boundary
  | None -> false

let run_tokens run_id =
  let safe = safe_slug run_id in
  [
    run_id;
    safe;
    "run_id=" ^ run_id;
    "run_id=" ^ safe;
    "swarm-live:" ^ run_id;
    "swarm-live:" ^ safe;
    "live-harness-" ^ run_id;
    "live-harness-" ^ safe;
  ]
  |> filter_nonempty_strings

let value_matches_tokens tokens value =
  List.exists (fun token -> string_contains_ci ~needle:token value) tokens

let option_matches_tokens tokens = function
  | Some value -> value_matches_tokens tokens value
  | None -> false

let best_overlap expected_names rows roster_of =
  let overlap_count row =
    roster_of row
    |> List.fold_left
         (fun acc name -> if List.mem name expected_names then acc + 1 else acc)
         0
  in
  rows
  |> List.map (fun row -> (row, overlap_count row))
  |> List.filter (fun (_, score) -> score > 0)
  |> List.sort (fun (_, left) (_, right) -> compare right left)
  |> list_hd_opt

let extract_run_id_from_note token =
  token
  |> String.split_on_char ' '
  |> List.find_map (fun part ->
         let trimmed = String.trim part in
         if String.length trimmed > 7
            && String.equal (String.lowercase_ascii (String.sub trimmed 0 7)) "run_id="
         then
           nonempty_string
             (Some
                (String.sub trimmed 7 (String.length trimmed - 7)
                |> String.trim))
         else None)

let extract_int_field_from_note ~field token =
  let prefix = String.lowercase_ascii field ^ "=" in
  let prefix_len = String.length prefix in
  token
  |> String.split_on_char ' '
  |> List.find_map (fun part ->
         let trimmed = String.trim part in
         if String.length trimmed > prefix_len
            && String.equal
                 (String.lowercase_ascii (String.sub trimmed 0 prefix_len))
                 prefix
         then
           int_of_string_opt
             (String.sub trimmed prefix_len (String.length trimmed - prefix_len)
             |> String.trim)
         else None)

let extract_run_id_from_prefixed_token ~prefix token =
  let prefix_len = String.length prefix in
  if String.length token > prefix_len
     && String.equal
          (String.lowercase_ascii (String.sub token 0 prefix_len))
          (String.lowercase_ascii prefix)
  then
    nonempty_string
      (Some
         (String.sub token prefix_len (String.length token - prefix_len)
         |> String.trim))
  else None

let extract_run_id token =
  option_or_else
    (extract_run_id_from_note token)
    (fun () ->
      option_or_else
        (extract_run_id_from_prefixed_token ~prefix:"swarm-live:" token)
        (fun () ->
          extract_run_id_from_prefixed_token ~prefix:"live-harness-" token))

let count_true rows predicate =
  List.fold_left (fun acc row -> if predicate row then acc + 1 else acc) 0 rows

let checklist_item ~id ~title ~status ~detail ~next_tool =
  `Assoc
    [
      ("id", `String id);
      ("title", `String title);
      ("status", `String status);
      ("detail", `String detail);
      ("next_tool", `String next_tool);
    ]

let blocker_item ~code ~severity ~title ~detail ~next_tool =
  `Assoc
    [
      ("code", `String code);
      ("severity", `String severity);
      ("title", `String title);
      ("detail", `String detail);
      ("next_tool", `String next_tool);
    ]

let swarm_live_json config ?run_id ?operation_id () =
  let room_id = Room.current_room_id config in
  let agents = Room.get_agents_raw config in
  let tasks = Room.get_tasks_raw config in
  let messages = Room.get_messages_raw config ~since_seq:0 ~limit:400 in
  let _, _, units, _ = topology_units config in
  let operations = all_operations config units in
  let detachments = all_detachments config units operations in
  let decisions = all_policy_decisions config in
  let selected_operation =
    match operation_id with
    | Some value ->
        option_or_else
          (operation_by_id operations value)
          (fun () ->
            operations
            |> List.find_opt (fun (operation : operation_record) ->
                   String.equal operation.trace_id value))
    | None -> (
        match run_id with
        | Some value ->
            let tokens = run_tokens value in
            operations
            |> List.find_opt (fun (operation : operation_record) ->
                   value_matches_tokens tokens operation.operation_id
                   || value_matches_tokens tokens operation.objective
                   || option_matches_tokens tokens operation.note
                   || option_matches_tokens tokens operation.checkpoint_ref
                   || value_matches_tokens tokens operation.trace_id)
        | None ->
            operations
            |> List.find_opt (fun (operation : operation_record) ->
                   option_matches_tokens [ "swarm-live"; "agent swarm"; "harness" ]
                     operation.note
                   || value_matches_tokens [ "swarm-live"; "agent swarm"; "harness" ]
                        operation.objective))
  in
  let effective_run_id =
    match run_id with
    | Some value -> value
    | None -> (
        match selected_operation with
        | Some operation -> (
            let candidates =
              [
                operation.note;
                operation.checkpoint_ref;
              ]
              |> List.filter_map Fun.id
            in
            candidates |> List.find_map extract_run_id
            |> Option.value ~default:"swarm-live")
        | None -> "swarm-live")
  in
  let operation_started_at =
    Option.bind selected_operation (fun (operation : operation_record) ->
        Room.parse_iso_time_opt operation.created_at)
  in
  let message_in_scope (message : Types.message) =
    match operation_started_at with
    | Some boundary -> timestamp_on_or_after ~boundary message.timestamp
    | None -> true
  in
  let task_in_scope (task : Types.task) =
    match operation_started_at with
    | Some boundary -> timestamp_on_or_after ~boundary task.created_at
    | None -> true
  in
  let scoped_tasks = tasks |> List.filter task_in_scope in
  let harness_summary =
    find_swarm_live_artifact_json config effective_run_id "swarm-live-summary.json"
  in
  let slot_telemetry =
    find_swarm_live_artifact_json config effective_run_id "slot-telemetry.json"
  in
  let runtime_doctor =
    Option.bind
      (find_swarm_live_artifact_path config effective_run_id "runtime-doctor.json")
      (fun path ->
        let run_dir = Filename.dirname path in
        read_runtime_doctor_json run_dir)
  in
  let live_slot_samples =
    match find_swarm_live_artifact_path config effective_run_id "slot-samples.jsonl" with
    | Some path when not (Option.is_some slot_telemetry) && Sys.file_exists path ->
        read_jsonl_local path
    | _ -> []
  in
  let worker_count_from_artifact =
    Option.bind harness_summary (fun json ->
        U.member "worker_count" json |> U.to_int_option)
  in
  let worker_count_from_operation =
    Option.bind selected_operation (fun (operation : operation_record) ->
        Option.bind operation.note
          (extract_int_field_from_note ~field:"worker_count"))
  in
  let required_final_markers =
    Option.bind harness_summary (fun json ->
        U.member "required_final_markers" json |> U.to_int_option)
  in
  let required_final_markers_from_operation =
    Option.bind selected_operation (fun (operation : operation_record) ->
        Option.bind operation.note
          (extract_int_field_from_note ~field:"required_final_markers"))
  in
  let min_hot_slots =
    Option.bind harness_summary (fun json ->
        U.member "min_hot_slots" json |> U.to_int_option)
  in
  let min_hot_slots_from_operation =
    Option.bind selected_operation (fun (operation : operation_record) ->
        Option.bind operation.note
          (extract_int_field_from_note ~field:"min_hot_slots"))
  in
  let min_hot_slots =
    Option.value min_hot_slots
      ~default:(Option.value min_hot_slots_from_operation ~default:10)
  in
  let plans =
    Agent_swarm_live_harness.build_worker_plans
      ~worker_count:
        (Option.value worker_count_from_artifact
           ~default:(Option.value worker_count_from_operation ~default:12))
      effective_run_id
  in
  let expected_workers = List.map (fun (plan : Agent_swarm_live_harness.worker_plan) -> plan.name) plans in
  let operation_detachments =
    detachments
    |> List.filter (fun (detachment : detachment_record) ->
           match selected_operation with
           | Some operation -> String.equal detachment.operation_id operation.operation_id
           | None -> true)
  in
  let matched_detachment =
    match selected_operation with
    | Some _ ->
        best_overlap expected_workers operation_detachments
          (fun (row : detachment_record) -> row.roster)
        |> Option.map fst
    | None ->
        best_overlap expected_workers detachments
          (fun (row : detachment_record) -> row.roster)
        |> Option.map fst
  in
  let matched_squad =
    match selected_operation with
    | Some operation ->
        option_or_else
          (lookup_unit units operation.assigned_unit_id)
          (fun () ->
            Option.bind matched_detachment (fun (detachment : detachment_record) ->
                lookup_unit units detachment.assigned_unit_id))
    | None ->
        option_or_else
          (Option.bind matched_detachment (fun (detachment : detachment_record) ->
               lookup_unit units detachment.assigned_unit_id))
          (fun () ->
            units
            |> List.filter (fun (unit : unit_record) -> unit.kind = Squad)
            |> fun rows ->
            best_overlap expected_workers rows
              (fun (unit : unit_record) -> unit.roster)
            |> Option.map fst)
  in
  let pending_decisions =
    decisions
    |> List.filter (fun (decision : policy_decision_record) ->
           String.equal decision.status "pending"
           &&
           match selected_operation with
           | Some operation -> decision.operation_id = Some operation.operation_id
           | None -> true)
  in
  let relevant_traces =
    list_traces_json config ?operation_id:(Option.map (fun (operation : operation_record) -> operation.operation_id) selected_operation)
      ~limit:12 ()
    |> U.member "events"
    |> U.to_list
  in
  let message_matches_run (message : Types.message) =
    value_matches_tokens (run_tokens effective_run_id) message.content
    || List.mem message.from_agent expected_workers
  in
  let matching_messages =
    messages
    |> List.filter (fun message -> message_in_scope message && message_matches_run message)
    |> List.sort (fun (left : Types.message) (right : Types.message) -> compare right.seq left.seq)
  in
  let recent_messages =
    matching_messages
    |> List.filteri (fun idx _ -> idx < 12)
    |> List.rev
  in
  let message_contains ~from_agent needle =
    List.exists
      (fun (message : Types.message) ->
        String.equal message.from_agent from_agent
        && string_contains ~needle message.content)
      matching_messages
  in
  let message_starts_with ~from_agent prefix =
    let prefix_len = String.length prefix in
    List.exists
      (fun (message : Types.message) ->
        String.equal message.from_agent from_agent
        && String.length message.content >= prefix_len
        && String.sub message.content 0 prefix_len = prefix)
      matching_messages
  in
  let task_by_id =
    List.map (fun (task : Types.task) -> (task.id, task)) tasks
  in
  let find_agent name =
    agents |> List.find_opt (fun (agent : Types.agent) -> String.equal agent.name name)
  in
  let find_task_title task_id =
    List.assoc_opt task_id task_by_id |> Option.map (fun (task : Types.task) -> task.title)
  in
  let find_task_status task_id =
    List.assoc_opt task_id task_by_id
    |> Option.map (fun (task : Types.task) -> Types.string_of_task_status task.task_status)
  in
  let task_assignee (task : Types.task) =
    match task.task_status with
    | Types.Claimed { assignee; _ }
    | Types.InProgress { assignee; _ }
    | Types.Done { assignee; _ } -> Some assignee
    | Types.Todo | Types.Cancelled _ -> None
  in
  let task_done (task : Types.task) =
    match task.task_status with
    | Types.Done _ -> true
    | _ -> false
  in
  let worker_rows =
    plans
    |> List.map (fun (plan : Agent_swarm_live_harness.worker_plan) ->
           let agent = find_agent plan.name in
           let current_task = Option.bind agent (fun (value : Types.agent) -> value.current_task) in
           let heartbeat_age_sec =
             Option.bind agent (fun (value : Types.agent) -> float_age_seconds value.last_seen)
           in
           let task_matches_run =
             match current_task with
             | Some task_id -> (
                 match List.assoc_opt task_id task_by_id with
                 | Some task ->
                     value_matches_tokens (run_tokens effective_run_id) task.title
                     || value_matches_tokens [ plan.name ] task.title
                 | None -> false)
             | None -> false
           in
           let assigned_task =
             scoped_tasks
             |> List.find_opt (fun (task : Types.task) ->
                    match task_assignee task with
                    | Some assignee when String.equal assignee plan.name ->
                        value_matches_tokens (run_tokens effective_run_id) task.title
                        || value_matches_tokens [ plan.name ] task.title
                    | _ -> false)
           in
           let last_message =
             recent_messages
             |> List.find_opt (fun (message : Types.message) ->
                    String.equal message.from_agent plan.name)
           in
           let claim_marker_seen =
             message_contains ~from_agent:plan.name plan.claim_marker
           in
           let done_marker_seen =
             message_contains ~from_agent:plan.name plan.done_marker
           in
           let final_marker_seen =
             message_starts_with ~from_agent:plan.name plan.final_marker
           in
           let runtime_assisted_final_marker_seen =
             List.exists
               (fun (message : Types.message) ->
                 String.equal message.from_agent plan.name
                 && string_contains
                      ~needle:
                        (Printf.sprintf
                           "RUNTIME_ASSISTED_FINAL_MARKER expected=%s"
                           plan.final_marker)
                      message.content)
               matching_messages
           in
           let completed_task =
             if done_marker_seen || final_marker_seen
                || runtime_assisted_final_marker_seen
             then
               tasks
               |> List.find_opt (fun (task : Types.task) ->
                      match task_assignee task with
                      | Some assignee when String.equal assignee plan.name ->
                          value_matches_tokens (run_tokens effective_run_id) task.title
                      | _ -> false)
             else
               None
           in
           let joined =
             Option.is_some agent
             || Option.is_some assigned_task
             || Option.is_some completed_task
             || Option.is_some last_message
             || claim_marker_seen
             || done_marker_seen
             || final_marker_seen
             || runtime_assisted_final_marker_seen
           in
           let task_bound =
             task_matches_run || Option.is_some assigned_task
             || Option.is_some completed_task
           in
           let bound_task_id =
             option_first_some (if task_matches_run then current_task else None)
               (option_first_some
                  (Option.map (fun (task : Types.task) -> task.id) assigned_task)
                  (Option.map (fun (task : Types.task) -> task.id) completed_task))
           in
           let bound_task_title =
             match bound_task_id with
             | Some value -> find_task_title value
             | None ->
                 option_first_some
                   (Option.map (fun (task : Types.task) -> task.title) assigned_task)
                   (Option.map (fun (task : Types.task) -> task.title) completed_task)
           in
           let bound_task_status =
             match bound_task_id with
             | Some value -> find_task_status value
             | None ->
                 option_first_some
                   (assigned_task
                    |> Option.map (fun (task : Types.task) ->
                           Types.string_of_task_status task.task_status))
                   (completed_task
                    |> Option.map (fun (task : Types.task) ->
                           Types.string_of_task_status task.task_status))
           in
           let completed =
             match option_first_some assigned_task completed_task with
             | Some task -> task_done task
             | None ->
                 done_marker_seen
                 && (final_marker_seen || runtime_assisted_final_marker_seen)
           in
           let heartbeat_fresh =
             match heartbeat_age_sec with
             | Some age -> age <= Room.heartbeat_timeout_seconds
             | None -> completed
           in
           `Assoc
             [
               ("name", `String plan.name);
               ("role", `String (Agent_swarm_live_harness.string_of_worker_role plan.role));
               ("lane", `String (Agent_swarm_live_harness.string_of_fixture_lane plan.lane));
               ("joined", `Bool joined);
               ("live_presence", `Bool (Option.is_some agent));
               ("completed", `Bool completed);
               ( "status",
                 match agent with
                 | Some value -> `String (Types.string_of_agent_status value.status)
                 | None -> `String "offline" );
               ("current_task", match current_task with Some value -> `String value | None -> `Null);
               ("bound_task_id", match bound_task_id with Some value -> `String value | None -> `Null);
               ("bound_task_title", match bound_task_title with Some value -> `String value | None -> `Null);
               ("bound_task_status", match bound_task_status with Some value -> `String value | None -> `Null);
               ("current_task_matches_run", `Bool task_bound);
               ("squad_member", `Bool (option_exists (fun (unit : unit_record) -> List.mem plan.name unit.roster) matched_squad));
               ("detachment_member", `Bool (option_exists (fun (detachment : detachment_record) -> List.mem plan.name detachment.roster) matched_detachment));
               ( "last_seen",
                 match agent with
                 | Some value -> `String value.last_seen
                 | None -> `Null );
               ("heartbeat_age_sec", match heartbeat_age_sec with Some value -> `Float value | None -> `Null);
               ("heartbeat_fresh", `Bool heartbeat_fresh);
               ("claim_marker_seen", `Bool claim_marker_seen);
               ("done_marker_seen", `Bool done_marker_seen);
               ("final_marker_seen", `Bool final_marker_seen);
               ("runtime_assisted_final_marker_seen", `Bool runtime_assisted_final_marker_seen);
               ("claim_marker", `String plan.claim_marker);
               ("done_marker", `String plan.done_marker);
               ("final_marker", `String plan.final_marker);
               ( "last_message",
                 match last_message with
                 | Some message ->
                     `Assoc
                       [
                         ("seq", `Int message.seq);
                         ("content", `String message.content);
                         ("timestamp", `String message.timestamp);
                       ]
                 | None -> `Null );
             ])
  in
  let joined_workers =
    count_true worker_rows (fun row ->
        U.member "joined" row |> U.to_bool_option |> Option.value ~default:false)
  in
  let current_task_bound =
    count_true worker_rows (fun row ->
        U.member "bound_task_id" row <> `Null
        && U.member "current_task_matches_run" row |> U.to_bool_option
           |> Option.value ~default:false)
  in
  let fresh_heartbeats =
    count_true worker_rows (fun row ->
        U.member "heartbeat_fresh" row |> U.to_bool_option |> Option.value ~default:false)
  in
  let claim_markers_seen =
    count_true worker_rows (fun row ->
        U.member "claim_marker_seen" row |> U.to_bool_option |> Option.value ~default:false)
  in
  let done_markers_seen =
    count_true worker_rows (fun row ->
        U.member "done_marker_seen" row |> U.to_bool_option |> Option.value ~default:false)
  in
  let final_markers_seen =
    count_true worker_rows (fun row ->
        U.member "final_marker_seen" row |> U.to_bool_option |> Option.value ~default:false)
  in
  let runtime_assisted_final_markers_seen =
    count_true worker_rows (fun row ->
        U.member "runtime_assisted_final_marker_seen" row |> U.to_bool_option
        |> Option.value ~default:false)
  in
  let completed_workers =
    count_true worker_rows (fun row ->
        match U.member "bound_task_status" row |> U.to_string_option with
        | Some status -> String.equal status "done"
        | None -> false)
  in
  let artifact_completed_workers =
    Option.bind harness_summary (fun json ->
        U.member "completed_workers" json |> U.to_int_option)
  in
  let artifact_final_markers_seen =
    Option.bind harness_summary (fun json ->
        U.member "final_markers_seen" json |> U.to_int_option)
  in
  let artifact_runtime_assisted_final_markers_seen =
    Option.bind harness_summary (fun json ->
        U.member "runtime_assisted_final_markers" json |> U.to_int_option)
  in
  let effective_completed_workers =
    match selected_operation with
    | Some _ -> completed_workers
    | None ->
        if completed_workers > 0 then completed_workers
        else Option.value artifact_completed_workers ~default:0
  in
  let effective_final_markers_seen =
    match selected_operation with
    | Some _ -> final_markers_seen
    | None ->
        if final_markers_seen > 0 then final_markers_seen
        else Option.value artifact_final_markers_seen ~default:0
  in
  let effective_runtime_assisted_final_markers_seen =
    match selected_operation with
    | Some _ -> runtime_assisted_final_markers_seen
    | None ->
        if runtime_assisted_final_markers_seen > 0 then
          runtime_assisted_final_markers_seen
        else
          Option.value artifact_runtime_assisted_final_markers_seen ~default:0
  in
  let live_sample_count = List.length live_slot_samples in
  let live_peak_hot_slots =
    live_slot_samples
    |> List.fold_left
         (fun acc row ->
           let value =
             U.member "active_slots" row |> U.to_int_option |> Option.value ~default:0
           in
           max acc value)
         0
  in
  let live_last_sample = List.rev live_slot_samples |> list_hd_opt in
  let live_total_slots =
    option_or_else
      (Option.bind live_last_sample (fun row -> U.member "total_slots" row |> U.to_int_option))
      (fun () ->
        live_slot_samples
        |> List.find_map (fun row -> U.member "total_slots" row |> U.to_int_option))
    |> Option.value ~default:0
  in
  let live_ctx_per_slot =
    option_or_else
      (Option.bind live_last_sample (fun row -> U.member "ctx_per_slot" row |> U.to_int_option))
      (fun () ->
        live_slot_samples
        |> List.find_map (fun row -> U.member "ctx_per_slot" row |> U.to_int_option))
    |> Option.value ~default:0
  in
  let live_active_slots_now =
    Option.bind live_last_sample (fun row -> U.member "active_slots" row |> U.to_int_option)
    |> Option.value ~default:0
  in
  let live_last_sample_at =
    Option.bind live_last_sample (fun row -> U.member "timestamp" row |> U.to_string_option)
  in
  let live_telemetry_timeline =
    live_slot_samples
    |> List.rev
    |> List.filteri (fun idx _ -> idx < 60)
    |> List.rev
    |> List.map (fun row ->
           `Assoc
             [
               ("timestamp", option_or_else (U.member "timestamp" row |> U.to_string_option) (fun () -> Some "") |> Option.value ~default:"" |> fun value -> `String value);
               ( "active_slots",
                 `Int
                   (U.member "active_slots" row |> U.to_int_option
                   |> Option.value ~default:0) );
               ( "active_slot_ids",
                 match U.member "active_slot_ids" row with
                 | `List values -> `List values
                 | _ -> `List [] );
             ])
  in
  let total_slots =
    Option.bind slot_telemetry (fun json ->
        U.member "total_slots" json |> U.to_int_option)
    |> Option.value ~default:live_total_slots
  in
  let ctx_per_slot =
    Option.bind slot_telemetry (fun json ->
        U.member "ctx_per_slot" json |> U.to_int_option)
    |> Option.value ~default:live_ctx_per_slot
  in
  let active_slots_now =
    Option.bind slot_telemetry (fun json ->
        U.member "active_slots_now" json |> U.to_int_option)
    |> Option.value ~default:live_active_slots_now
  in
  let peak_hot_slots =
    Option.bind slot_telemetry (fun json ->
        U.member "peak_active_slots" json |> U.to_int_option)
    |> Option.value ~default:live_peak_hot_slots
  in
  let sample_count =
    Option.bind slot_telemetry (fun json ->
        U.member "sample_count" json |> U.to_int_option)
    |> Option.value ~default:live_sample_count
  in
  let hot_window_ok =
    Option.bind slot_telemetry (fun json ->
        U.member "hot_window_ok" json |> U.to_bool_option)
    |> Option.value ~default:(live_peak_hot_slots >= min_hot_slots)
  in
  let last_sample_at =
    option_or_else
      (Option.bind slot_telemetry (fun json ->
           U.member "last_sample_at" json |> U.to_string_option))
      (fun () -> live_last_sample_at)
  in
  let slot_url =
    option_or_else
      (Option.bind runtime_doctor (fun doctor -> doctor.slot_url))
      (fun () ->
         Option.bind slot_telemetry (fun json ->
             U.member "slot_url" json |> U.to_string_option))
  in
  let telemetry_timeline =
    match slot_telemetry with
    | Some json -> (
        match U.member "timeline" json with
        | `List rows -> rows
        | _ -> [])
    | None -> live_telemetry_timeline
  in
  let provider_base_url =
    Option.bind runtime_doctor (fun doctor -> doctor.provider_base_url)
  in
  let provider_reachable =
    option_or_else
      (Option.bind runtime_doctor (fun doctor -> doctor.provider_reachable))
      (fun () ->
         if total_slots > 0 || sample_count > 0 then Some true else None)
  in
  let provider_status_code =
    Option.bind runtime_doctor (fun doctor -> doctor.provider_status_code)
  in
  let provider_model_id =
    Option.bind runtime_doctor (fun doctor -> doctor.provider_model_id)
  in
  let actual_model_id =
    Option.bind runtime_doctor (fun doctor -> doctor.actual_model_id)
  in
  let expected_slots =
    Option.bind runtime_doctor (fun doctor -> doctor.expected_slots)
  in
  let actual_slots =
    option_or_else
      (Option.bind runtime_doctor (fun doctor -> doctor.actual_slots))
      (fun () -> Some total_slots)
  in
  let expected_ctx =
    Option.bind runtime_doctor (fun doctor -> doctor.expected_ctx)
  in
  let actual_ctx =
    option_or_else
      (Option.bind runtime_doctor (fun doctor -> doctor.actual_ctx))
      (fun () -> Some ctx_per_slot)
  in
  let slot_reachable =
    Option.bind runtime_doctor (fun doctor -> doctor.slot_reachable)
  in
  let slot_status_code =
    Option.bind runtime_doctor (fun doctor -> doctor.slot_status_code)
  in
  let runtime_detail =
    option_or_else
      (Option.bind runtime_doctor (fun doctor -> doctor.detail))
      (fun () -> Option.bind runtime_doctor (fun doctor -> doctor.provider_error))
  in
  let runtime_checked_at =
    Option.bind runtime_doctor (fun doctor -> doctor.checked_at)
  in
  let runtime_blocker =
    option_or_else
      (Option.bind runtime_doctor (fun doctor -> doctor.runtime_blocker))
      (fun () ->
         match provider_reachable with
         | Some false -> Some "provider_unreachable"
         | _ -> (
             match provider_model_id, actual_model_id with
             | Some expected, Some actual when not (String.equal expected actual) ->
                 Some "provider_model_mismatch"
             | _ -> (
                 match expected_ctx, actual_ctx with
                 | Some expected, Some actual when expected <> actual ->
                     Some "ctx_mismatch"
                 | _ -> (
                     match expected_slots, actual_slots with
                     | Some expected, Some actual when actual < expected ->
                         Some "slot_count_insufficient"
                     | _ -> None))))
  in
  let detachment_exists = matched_detachment <> None in
  let operation_ready =
    match selected_operation with
    | Some operation ->
        not
          (operation.status = Cancelled || operation.status = Failed)
    | None -> false
  in
  let detachment_roster_matches =
    match matched_detachment with
    | Some detachment ->
        let left = List.sort String.compare detachment.roster in
        let right = List.sort String.compare expected_workers in
        left = right
    | None -> false
  in
  let expected_count = List.length expected_workers in
  let required_final_markers =
    Option.value required_final_markers
      ~default:
        (Option.value required_final_markers_from_operation
           ~default:expected_count)
  in
  let pass_hot_concurrency =
    peak_hot_slots >= min_hot_slots
    && hot_window_ok
  in
  let pass_end_to_end =
    joined_workers = expected_count
    && current_task_bound = expected_count
    && fresh_heartbeats = expected_count
    && effective_completed_workers = expected_count
  in
  let checklist =
    [
      checklist_item ~id:"active-operation" ~title:"Active operation exists"
        ~status:(if operation_ready then "pass" else "fail")
        ~detail:
          (match selected_operation with
          | Some operation -> Printf.sprintf "%s · %s" operation.operation_id (string_of_operation_status operation.status)
          | None -> "No managed operation matches this run yet.")
        ~next_tool:"masc_operation_start";
      checklist_item ~id:"detachment-materialized" ~title:"Detachment materialized after tick"
        ~status:(if detachment_exists then "pass" else "fail")
        ~detail:
          (match matched_detachment with
          | Some detachment -> Printf.sprintf "%s · %s" detachment.detachment_id detachment.status
          | None -> "No matching detachment yet.")
        ~next_tool:"masc_dispatch_tick";
      checklist_item ~id:"worker-joins" ~title:"Expected workers joined"
        ~status:(if joined_workers = expected_count then "pass" else "fail")
        ~detail:(Printf.sprintf "%d / %d workers have live or recorded run evidence" joined_workers expected_count)
        ~next_tool:"masc_join";
      checklist_item ~id:"current-task" ~title:"Workers have current_task bindings"
        ~status:(if current_task_bound = expected_count then "pass" else "fail")
        ~detail:(Printf.sprintf "%d / %d workers have run-scoped task ownership or clean completion evidence" current_task_bound expected_count)
        ~next_tool:"masc_plan_set_task";
      checklist_item ~id:"final-markers" ~title:"Model final markers observed"
        ~status:(if effective_final_markers_seen >= required_final_markers then "pass" else "warn")
        ~detail:
          (Printf.sprintf
             "%d / %d model markers seen; runtime-assisted=%d; completed=%d / %d; detachment roster match=%s"
             effective_final_markers_seen required_final_markers
             effective_runtime_assisted_final_markers_seen
             effective_completed_workers expected_count
             (if detachment_roster_matches then "yes" else "no"))
        ~next_tool:"masc_observe_traces";
      checklist_item ~id:"hot-slots" ~title:"Peak hot slots reached threshold"
        ~status:(if pass_hot_concurrency then "pass" else "fail")
        ~detail:
          (Printf.sprintf "peak hot slots=%d, active now=%d, ctx=%d, samples=%d"
             peak_hot_slots active_slots_now ctx_per_slot sample_count)
        ~next_tool:"restart llama hot profile";
    ]
  in
  let blockers = ref [] in
  if not operation_ready then
    blockers :=
      blocker_item ~code:"missing-operation" ~severity:"bad"
        ~title:"No matching operation"
        ~detail:"The harness has not created a managed CPv2 operation for this run yet."
        ~next_tool:"masc_operation_start"
      :: !blockers;
  if operation_ready && not detachment_exists then
    blockers :=
      blocker_item ~code:"missing-detachment" ~severity:"bad"
        ~title:"Operation has no detachment"
        ~detail:"Run the scheduler once so CPv2 can materialize the squad detachment."
        ~next_tool:"masc_dispatch_tick"
      :: !blockers;
  if joined_workers < expected_count then
    blockers :=
      blocker_item ~code:"missing-workers" ~severity:"bad"
        ~title:"Not all workers joined"
        ~detail:(Printf.sprintf "%d of %d workers have live or recorded run evidence." joined_workers expected_count)
        ~next_tool:"masc_join"
      :: !blockers;
  (match runtime_blocker with
  | Some "provider_unreachable" ->
      blockers :=
        blocker_item ~code:"provider_unreachable" ~severity:"bad"
          ~title:"Provider is unreachable"
          ~detail:
            (Option.value runtime_detail
               ~default:"Local provider proxy or llama runtime did not answer the smoke check.")
          ~next_tool:"restart llama hot profile"
        :: !blockers
  | Some "provider_model_mismatch" ->
      blockers :=
        blocker_item ~code:"provider_model_mismatch" ~severity:"bad"
          ~title:"Provider model does not match the requested hot profile"
          ~detail:
            (Printf.sprintf "expected=%s actual=%s"
               (Option.value provider_model_id ~default:"unknown")
               (Option.value actual_model_id ~default:"unknown"))
          ~next_tool:"restart llama hot profile"
        :: !blockers
  | Some "slot_count_insufficient" ->
      blockers :=
        blocker_item ~code:"slot_count_insufficient" ~severity:"bad"
          ~title:"Runtime exposed fewer slots than the hot profile requires"
          ~detail:
            (Printf.sprintf "expected_slots=%s actual_slots=%s"
               (match expected_slots with Some value -> string_of_int value | None -> "n/a")
               (match actual_slots with Some value -> string_of_int value | None -> "n/a"))
          ~next_tool:"restart llama hot profile"
        :: !blockers
  | Some "ctx_mismatch" ->
      blockers :=
        blocker_item ~code:"ctx_mismatch" ~severity:"bad"
          ~title:"Runtime context does not match the required hot profile"
          ~detail:
            (Printf.sprintf "expected_ctx=%s actual_ctx=%s"
               (match expected_ctx with Some value -> string_of_int value | None -> "n/a")
               (match actual_ctx with Some value -> string_of_int value | None -> "n/a"))
          ~next_tool:"restart llama hot profile"
        :: !blockers
  | Some other ->
      blockers :=
        blocker_item ~code:other ~severity:"bad"
          ~title:"Runtime verification failed"
          ~detail:(Option.value runtime_detail ~default:"The hot runtime contract did not pass.")
          ~next_tool:"restart llama hot profile"
        :: !blockers
  | None -> ());
  if not pass_hot_concurrency && not (Option.is_some runtime_blocker) then
    blockers :=
      blocker_item ~code:"hot-slot-threshold" ~severity:"bad"
        ~title:"Hot concurrency target not reached"
        ~detail:
          (Printf.sprintf "peak hot slots=%d, active now=%d, total slots=%d, ctx=%d"
             peak_hot_slots active_slots_now total_slots ctx_per_slot)
        ~next_tool:"restart llama hot profile"
      :: !blockers;
  if current_task_bound < expected_count then
    blockers :=
      blocker_item ~code:"current-task-gap" ~severity:"warn"
        ~title:"Claimed-without-current_task gap"
        ~detail:"At least one worker is missing run-scoped task ownership or current_task evidence."
        ~next_tool:"masc_plan_set_task"
      :: !blockers;
  if fresh_heartbeats < expected_count then
    blockers :=
      blocker_item ~code:"stale-heartbeat" ~severity:"warn"
        ~title:"Stale worker heartbeat"
        ~detail:"At least one worker heartbeat is stale or missing."
        ~next_tool:"masc_heartbeat"
      :: !blockers;
  if pending_decisions <> [] then
    blockers :=
      blocker_item ~code:"pending-approval" ~severity:"warn"
        ~title:"Pending approval blocks swarm progress"
        ~detail:(Printf.sprintf "%d pending decision(s) for this operation." (List.length pending_decisions))
        ~next_tool:"masc_policy_approve"
      :: !blockers;
  if effective_completed_workers < expected_count then
    blockers :=
      blocker_item ~code:"incomplete-workers" ~severity:"warn"
        ~title:"Not all workers completed"
        ~detail:
          (Printf.sprintf "%d of %d workers reached task completion." effective_completed_workers expected_count)
        ~next_tool:"masc_observe_traces"
      :: !blockers;
  if effective_final_markers_seen < required_final_markers then
    blockers :=
      blocker_item ~code:"missing-final-markers" ~severity:"warn"
        ~title:"Model final markers incomplete"
        ~detail:
          (Printf.sprintf
             "%d of %d model-emitted final markers observed (%d runtime-assisted)."
             effective_final_markers_seen required_final_markers
             effective_runtime_assisted_final_markers_seen)
        ~next_tool:"masc_observe_traces"
      :: !blockers;
  let recommended_next_tool =
    match runtime_blocker with
    | Some _ -> "restart llama hot profile"
    | None ->
        if not operation_ready then
          "masc_operation_start"
        else if not detachment_exists then
          "masc_dispatch_tick"
        else if current_task_bound < expected_count then
          "masc_plan_set_task"
        else if fresh_heartbeats < expected_count then
          "masc_heartbeat"
        else if not pass_hot_concurrency then
          "restart llama hot profile"
        else if pass_end_to_end then
          "masc_operation_finalize"
        else if effective_final_markers_seen < required_final_markers then
          "masc_observe_traces"
        else
          "masc_observe_traces"
  in
  let has_bad_blocker =
    List.exists
      (fun row ->
        U.member "severity" row |> U.to_string_option
        |> (function Some value -> String.equal value "bad" | None -> false))
      !blockers
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("run_id", `String effective_run_id);
      ("room_id", `String room_id);
      ("operation_id", match selected_operation with Some operation -> `String operation.operation_id | None -> `Null);
      ("recommended_next_tool", `String recommended_next_tool);
      ( "summary",
        `Assoc
          [
            ("expected_workers", `Int expected_count);
            ("joined_workers", `Int joined_workers);
            ( "live_workers",
              `Int
                (count_true worker_rows (fun row ->
                     U.member "live_presence" row |> U.to_bool_option
                     |> Option.value ~default:false)) );
            ("squad_roster_size", `Int (Option.map (fun (unit : unit_record) -> List.length unit.roster) matched_squad |> Option.value ~default:0));
            ("detachment_roster_size", `Int (Option.map (fun (detachment : detachment_record) -> List.length detachment.roster) matched_detachment |> Option.value ~default:0));
            ("current_task_bound", `Int current_task_bound);
            ("fresh_heartbeats", `Int fresh_heartbeats);
            ("claim_markers_seen", `Int claim_markers_seen);
            ("done_markers_seen", `Int done_markers_seen);
            ("final_markers_seen", `Int effective_final_markers_seen);
            ("runtime_assisted_final_markers", `Int effective_runtime_assisted_final_markers_seen);
            ("completed_workers", `Int effective_completed_workers);
            ("peak_hot_slots", `Int peak_hot_slots);
            ("hot_window_ok", `Bool hot_window_ok);
            ("pass_hot_concurrency", `Bool pass_hot_concurrency);
            ("pass_end_to_end", `Bool pass_end_to_end);
            ("pending_decisions", `Int (List.length pending_decisions));
            ("pass", `Bool (pass_hot_concurrency && pass_end_to_end && not has_bad_blocker));
          ] );
      ( "provider",
        `Assoc
          [
            ("slot_url", match slot_url with Some value -> `String value | None -> `Null);
            ("provider_base_url", match provider_base_url with Some value -> `String value | None -> `Null);
            ("provider_reachable", match provider_reachable with Some value -> `Bool value | None -> `Null);
            ("provider_status_code", match provider_status_code with Some value -> `Int value | None -> `Null);
            ("provider_model_id", match provider_model_id with Some value -> `String value | None -> `Null);
            ("actual_model_id", match actual_model_id with Some value -> `String value | None -> `Null);
            ("expected_slots", match expected_slots with Some value -> `Int value | None -> `Null);
            ("actual_slots", match actual_slots with Some value -> `Int value | None -> `Null);
            ("expected_ctx", match expected_ctx with Some value -> `Int value | None -> `Null);
            ("actual_ctx", match actual_ctx with Some value -> `Int value | None -> `Null);
            ("slot_reachable", match slot_reachable with Some value -> `Bool value | None -> `Null);
            ("slot_status_code", match slot_status_code with Some value -> `Int value | None -> `Null);
            ("runtime_blocker", match runtime_blocker with Some value -> `String value | None -> `Null);
            ("detail", match runtime_detail with Some value -> `String value | None -> `Null);
            ("checked_at", match runtime_checked_at with Some value -> `String value | None -> `Null);
            ("total_slots", `Int total_slots);
            ("ctx_per_slot", `Int ctx_per_slot);
            ("active_slots_now", `Int active_slots_now);
            ("peak_active_slots", `Int peak_hot_slots);
            ("sample_count", `Int sample_count);
            ("last_sample_at", match last_sample_at with Some value -> `String value | None -> `Null);
            ("timeline", `List telemetry_timeline);
          ] );
      ("operation", match selected_operation with Some operation -> operation_to_json operation | None -> `Null);
      ("squad", match matched_squad with Some unit -> unit_to_json unit | None -> `Null);
      ("detachment", match matched_detachment with Some detachment -> detachment_to_json detachment | None -> `Null);
      ("workers", `List worker_rows);
      ("checklist", `List checklist);
      ("blockers", `List (List.rev !blockers));
      ( "recent_messages",
        `List
          (List.map
             (fun (message : Types.message) ->
               `Assoc
                 [
                   ("seq", `Int message.seq);
                   ("from", `String message.from_agent);
                   ("content", `String message.content);
                   ("timestamp", `String message.timestamp);
                 ])
             recent_messages) );
      ("recent_trace_events", `List relevant_traces);
      ( "truth_notes",
        `List
          [
            `String "This endpoint is a read model over room state, CPv2 operations, detachments, decisions, and broadcasts.";
            `String "Workers that already left can still count as joined/task-bound when completed task ownership was recorded; final markers remain extra proof.";
            `String "claim != planning current_task; this surface prefers live room agent state but falls back to run-scoped task ownership.";
            `String "dispatch tick must materialize the detachment before roster and heartbeat checks can pass.";
            `String "Hot concurrency proof comes from llama.cpp /slots telemetry captured by the live harness and stored under .masc/control-plane/swarm-live/<run_id>.";
            `String "Runtime viability comes from runtime-doctor.json plus slot telemetry; hot-swarm pass never silently degrades ctx or slots.";
          ] );
    ]

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

let lookup_intent intents intent_id =
  List.find_opt
    (fun (intent : intent_record) -> String.equal intent.intent_id intent_id)
    intents

let replace_intent intents (updated : intent_record) =
  updated
  :: List.filter
       (fun (intent : intent_record) ->
         not (String.equal intent.intent_id updated.intent_id))
       intents

let empty_intent_focus =
  {
    stage = None;
    artifact_scope = [];
    unit_id = None;
    verification_state = None;
  }

let verification_state_of_operation (operation : operation_record) =
  match operation.status, operation.stage with
  | Failed, _ -> Some "failed"
  | Cancelled, _ -> Some "cancelled"
  | Completed, Some "review" -> Some "reviewed"
  | Completed, Some "verify" -> Some "verified"
  | Completed, Some "implement" -> Some "implemented"
  | _, Some "review" -> Some "reviewing"
  | _, Some "verify" -> Some "verifying"
  | _, Some "implement" -> Some "implementing"
  | _ -> None

let focus_of_operation (operation : operation_record) =
  {
    stage = operation.stage;
    artifact_scope = operation.artifact_scope;
    unit_id = Some operation.assigned_unit_id;
    verification_state = verification_state_of_operation operation;
  }

let touch_intent_from_operation config ~actor (operation : operation_record)
    ~state =
  match operation.intent_id with
  | None -> ()
  | Some intent_id -> (
      match lookup_intent (read_intents config) intent_id with
      | None -> ()
      | Some intent ->
          let linked_operations =
            let operations : operation_record list = read_operations config in
            let filtered =
              List.filter
                (fun (linked_operation : operation_record) ->
                  match linked_operation.intent_id with
                  | Some current -> String.equal current intent_id
                  | None -> false)
                operations
            in
            List.sort
              (fun (left : operation_record) (right : operation_record) ->
                String.compare right.updated_at left.updated_at)
              filtered
          in
          let aggregated_state =
            if
              List.exists
                (fun (linked_operation : operation_record) ->
                  linked_operation.status = Failed)
                linked_operations
            then
              Blocked_intent
            else if
              List.exists
                (fun (linked_operation : operation_record) ->
                  linked_operation.status = Active
                  || linked_operation.status = Planned)
                linked_operations
            then
              Active_intent
            else if
              List.exists
                (fun (linked_operation : operation_record) ->
                  linked_operation.status = Paused)
                linked_operations
            then
              Suspended_intent
            else if
              linked_operations <> []
              &&
              List.for_all
                (fun (linked_operation : operation_record) ->
                  linked_operation.status = Completed)
                linked_operations
            then
              Completed_intent
            else if
              linked_operations <> []
              &&
              List.for_all
                (fun (linked_operation : operation_record) ->
                  linked_operation.status = Cancelled)
                linked_operations
            then
              Dropped_intent
            else
              state
          in
          let updated =
            {
              intent with
              state = aggregated_state;
              current_focus = focus_of_operation operation;
              checkpoint_ref =
                option_first_some operation.checkpoint_ref intent.checkpoint_ref;
              updated_at = Types.now_iso ();
            }
          in
          write_intents config (replace_intent (read_intents config) updated);
          append_event config
            {
              event_id = next_event_id "evt";
              trace_id = next_trace_id ();
              event_type = "intent_synced_from_operation";
              operation_id = Some operation.operation_id;
              unit_id = None;
              actor = Some actor;
              source = "control_plane";
              ts = Types.now_iso ();
              detail =
                `Assoc
                  [
                    ("intent_id", `String updated.intent_id);
                    ("intent_state", `String (string_of_intent_state updated.state));
                  ];
            })

let with_intent config intent_id f =
  let intents = read_intents config in
  match lookup_intent intents intent_id with
  | None -> Error (Printf.sprintf "intent not found: %s" intent_id)
  | Some intent -> f intents intent

let stage_order_for_workload = function
  | "coding_task" -> [ "decompose"; "inspect"; "implement"; "verify"; "review" ]
  | "research_pipeline" -> [ "normalize"; "verify"; "curate"; "rank"; "audit" ]
  | _ -> []

let next_stage_for workload_profile stage =
  let order = stage_order_for_workload workload_profile in
  match stage with
  | None ->
      List.nth_opt order 0
  | Some current -> (
      match List.find_opt (fun stage_name -> String.equal stage_name current) order with
      | None -> None
      | Some stage_name ->
          let rec loop = function
            | [] | [ _ ] -> None
            | head :: next :: _ when String.equal head stage_name -> Some next
            | _ :: rest -> loop rest
          in
          loop order)

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

let search_upstreams operations (operation : operation_record) =
  operation.depends_on_operation_ids
  |> List.map (fun upstream_id ->
         match
           List.find_opt
             (fun (candidate : operation_record) ->
               String.equal candidate.operation_id upstream_id)
             operations
         with
         | Some upstream ->
             {
               Cp_search_fabric.operation_id = upstream.operation_id;
               status = string_of_operation_status upstream.status;
               checkpoint_ref = upstream.checkpoint_ref;
             }
         | None ->
             {
               Cp_search_fabric.operation_id = upstream_id;
               status = "missing";
               checkpoint_ref = None;
             })

let operation_readiness operations operation =
  match operation_search_strategy operation with
  | Cp_search_fabric.Legacy -> Cp_search_fabric.Ready
  | Cp_search_fabric.Best_first_v1 ->
      Cp_search_fabric.readiness_for_operation
        ~upstreams:(search_upstreams operations operation)

let sync_managed_detachments config units (operation : operation_record) =
  let operations = read_operations config in
  let detachments = read_detachments config in
  let existing_for_operation =
    detachments
    |> List.filter (fun (detachment : detachment_record) ->
           String.equal detachment.operation_id operation.operation_id
           && String.equal detachment.source "managed")
  in
  let readiness = operation_readiness operations operation in
  let targets =
    match operation_search_strategy operation, readiness with
    | Cp_search_fabric.Best_first_v1, Cp_search_fabric.Blocked _ -> []
    | _ -> (
        match detachment_targets_for_operation units operation with
        | [] -> []
        | rows -> rows)
  in
  let target_count = max 1 (List.length targets) in
  let updated_rows =
    match operation_search_strategy operation, readiness, targets with
    | Cp_search_fabric.Best_first_v1, Cp_search_fabric.Blocked _, _ -> []
    | _, _, [] ->
        [ default_detachment_for_operation config units operation ]
    | _, _, rows ->
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

let search_operation_descriptor (operation : operation_record) =
  {
    Cp_search_fabric.operation_id = Some operation.operation_id;
    objective = operation.objective;
    assigned_unit_id = Some operation.assigned_unit_id;
    workload_profile = operation_workload_profile operation;
    stage = operation.stage;
    artifact_scope = operation.artifact_scope;
    depends_on_operation_ids = operation.depends_on_operation_ids;
    created_at = operation.created_at;
  }

let operation_active_count operations unit_id =
  operations
  |> List.filter (fun (operation : operation_record) ->
         active_operation_status operation.status
         && String.equal operation.assigned_unit_id unit_id)
  |> List.length

let search_candidates_for_operation config units operations
    (operation : operation_record) =
  let current_unit_id = Some operation.assigned_unit_id in
  candidate_units_for_operation units operations current_unit_id
  |> List.filter_map (fun (unit : unit_record) ->
         match unit_guard_json config unit.unit_id with
         | Error _ -> None
         | Ok _ ->
             if decision_requires_approval units current_unit_id unit.unit_id then
               None
             else
               Some
                 {
                   Cp_search_fabric.unit_id = unit.unit_id;
                   label = unit.label;
                   capability_profile = unit.capability_profile;
                   active_operation_cap = unit.budget.active_operation_cap;
                   active_operations = operation_active_count operations unit.unit_id;
                   current_assignment = String.equal unit.unit_id operation.assigned_unit_id;
                 })

let candidate_matches_scope candidate scope =
  let haystack =
    String.concat " "
      [ candidate.Cp_search_fabric.unit_id; candidate.label; candidate.routing_reason ]
    |> String.lowercase_ascii
  in
  let terms =
    scope
    |> List.concat_map (fun raw ->
           raw
           |> String.split_on_char '/'
           |> List.concat_map (String.split_on_char '.'))
    |> List.map String.trim
    |> List.filter (fun value -> String.length value >= 3)
  in
  List.exists
    (fun term ->
      let term = String.lowercase_ascii term in
      let len_term = String.length term in
      let len_haystack = String.length haystack in
      let rec loop idx =
        if idx > len_haystack - len_term then false
        else if String.sub haystack idx len_term = term then true
        else loop (idx + 1)
      in
      len_haystack >= len_term && loop 0)
    terms

let apply_intent_forecast_bias config (operations : operation_record list)
    (operation : operation_record)
    (candidates : Cp_search_fabric.scored_candidate list) =
  match operation.intent_id with
  | None -> candidates
  | Some intent_id -> (
      match lookup_intent (read_intents config) intent_id with
      | None -> candidates
      | Some intent ->
          let unresolved_for_operation (current_operation : operation_record) =
            current_operation.depends_on_operation_ids
            |> List.filter_map (fun dep_id ->
                   match operation_by_id operations dep_id with
                   | Some upstream when upstream.status = Completed -> None
                   | Some upstream when Option.is_some upstream.checkpoint_ref -> None
                   | Some upstream -> Some upstream.operation_id
                   | None -> Some dep_id)
          in
          let linked : operation_record list =
            let filtered =
              List.filter
                (fun (linked_operation : operation_record) ->
                  match linked_operation.intent_id with
                  | Some current -> String.equal current intent_id
                  | None -> false)
                operations
            in
            List.sort
              (fun (left : operation_record) (right : operation_record) ->
                String.compare right.updated_at left.updated_at)
              filtered
          in
          let latest_operation = List.nth_opt linked 0 in
          let recommended_stage =
            match latest_operation with
            | Some latest when latest.status = Completed ->
                next_stage_for intent.workload_profile latest.stage
            | Some latest -> latest.stage
            | None ->
                option_first_some (next_stage_for intent.workload_profile intent.current_focus.stage)
                  intent.current_focus.stage
          in
          let recommended_scope =
            match latest_operation with
            | Some latest when latest.artifact_scope <> [] -> latest.artifact_scope
            | _ ->
                if intent.current_focus.artifact_scope <> [] then
                  intent.current_focus.artifact_scope
                else
                  intent.artifact_priors
          in
          let verification_ready =
            match normalize_stage operation.stage with
            | Some ("verify" | "review") -> unresolved_for_operation operation = []
            | _ -> true
          in
          candidates
          |> List.map (fun (candidate : Cp_search_fabric.scored_candidate) ->
                 let intent_successor =
                   (if recommended_stage = operation.stage then 10.0 else 0.0)
                   +. if candidate_matches_scope candidate recommended_scope then 5.0 else 0.0
                 in
                 let verification_readiness =
                   match normalize_stage operation.stage with
                   | Some "verify" ->
                       if verification_ready then 10.0 else 0.0
                   | Some "review" ->
                       if verification_ready then 10.0 else 0.0
                   | _ -> 0.0
                 in
                 let breakdown =
                   {
                     candidate.breakdown with
                     intent_successor;
                     verification_readiness;
                     total =
                       candidate.breakdown.total
                       +. intent_successor +. verification_readiness;
                   }
                 in
                 {
                   candidate with
                   breakdown;
                   routing_reason =
                     Printf.sprintf "%s intent=%.1f verify=%.1f"
                       candidate.routing_reason intent_successor
                       verification_readiness;
                 })
          |> List.sort (fun left right ->
                 let left : Cp_search_fabric.scored_candidate = left in
                 let right : Cp_search_fabric.scored_candidate = right in
                 compare
                   (right.breakdown.total, right.breakdown.capability_match, right.label)
                   (left.breakdown.total, left.breakdown.capability_match, left.label)))

let operation_search_candidates config units operations
    (operation : operation_record) =
  let stats = read_search_stats config in
  Cp_search_fabric.score_candidates ~store:stats
    ~operation:(search_operation_descriptor operation)
    ~candidates:(search_candidates_for_operation config units operations operation)
  |> apply_intent_forecast_bias config operations operation

let take_list n xs =
  let rec loop acc remaining count =
    match remaining, count with
    | _, count when count <= 0 -> List.rev acc
    | [], _ -> List.rev acc
    | item :: rest, _ -> loop (item :: acc) rest (count - 1)
  in
  loop [] xs n

let speculative_candidates_for_operation (operation : operation_record)
    (candidates : Cp_search_fabric.scored_candidate list) =
  List.map
    (fun (candidate : Cp_search_fabric.scored_candidate) ->
      {
        Speculative_engine.label = candidate.unit_id;
        prompt =
          Printf.sprintf
            "Objective: %s\nWorkload: %s\nStage: %s\nArtifact scope: %s\nCandidate unit: %s\nSearch score: %.1f\nRouting reason: %s\n\nDecide whether this is the best execution target. Keep the answer concise."
            operation.objective
            (operation_workload_profile operation)
            (operation_stage_key operation)
            (if operation.artifact_scope = [] then "(unspecified)"
             else String.concat ", " operation.artifact_scope)
            candidate.unit_id
            candidate.breakdown.total
            candidate.routing_reason;
        metadata =
          `Assoc
            [
              ("unit_id", `String candidate.unit_id);
              ("score", `Float candidate.breakdown.total);
              ("routing_reason", `String candidate.routing_reason);
            ];
      })
    candidates

let speculative_pick_candidate config (operation : operation_record)
    (candidates : Cp_search_fabric.scored_candidate list) =
  if
    not (room_speculation_enabled config)
    || operation_search_strategy operation <> Cp_search_fabric.Best_first_v1
    ||
    not
      (String.equal (operation_workload_profile operation) "coding_task"
       &&
       match normalize_stage operation.stage with
       | Some ("inspect" | "review") -> true
       | _ -> false)
    || List.length candidates < 2
  then
    None
  else
    let budget = min (room_speculation_budget config) (List.length candidates) in
    let candidates = take_list budget candidates in
    match
      Speculative_engine.speculate Tool_risc.global_spec_engine
        ~goal:(Printf.sprintf "route-%s" operation.operation_id)
        ~original_query:operation.objective
        ~candidates:(speculative_candidates_for_operation operation candidates)
    with
    | Ok outcome ->
        List.find_opt
          (fun (candidate : Cp_search_fabric.scored_candidate) ->
            String.equal candidate.unit_id outcome.candidate_label)
          candidates
    | Error _ -> None

let operation_search_json config units operations (operation : operation_record) =
  let readiness = operation_readiness operations operation in
  let candidates =
    match operation_search_strategy operation with
    | Cp_search_fabric.Legacy -> []
    | Cp_search_fabric.Best_first_v1 ->
        operation_search_candidates config units operations operation
  in
  let selected_unit_id =
    match candidates with
    | best :: _ -> Some best.Cp_search_fabric.unit_id
    | [] -> Some operation.assigned_unit_id
  in
  let base_json =
    Cp_search_fabric.summary_json
      ~strategy:(operation_search_strategy operation)
      ~readiness ~candidates ~selected_unit_id
  in
  match base_json with
  | `Assoc fields ->
      `Assoc
        ( ("speculation",
           `Assoc
             [
               ("enabled", `Bool (room_speculation_enabled config));
               ( "stage_allowed",
                 `Bool
                   (String.equal (operation_workload_profile operation) "coding_task"
                    &&
                    match normalize_stage operation.stage with
                    | Some ("inspect" | "review") -> true
                    | _ -> false) );
               ("budget", `Int (room_speculation_budget config));
             ] )
        :: fields )
  | other -> other

let update_search_stats_for_operation config operation ~outcome =
  let stage = operation_stage_key operation in
  let workload_profile = operation_workload_profile operation in
  let current = read_search_stats config in
  let updated =
    match outcome with
    | `Success ->
        Cp_search_fabric.record_success current
          ~unit_id:operation.assigned_unit_id ~workload_profile ~stage
    | `Failure ->
        Cp_search_fabric.record_failure current
          ~unit_id:operation.assigned_unit_id ~workload_profile ~stage
  in
  write_search_stats config updated

let operation_card_json config units operations (operation : operation_record) =
  let unit_label =
    lookup_unit units operation.assigned_unit_id
    |> Option.map (fun (unit : unit_record) -> unit.label)
    |> Option.value ~default:operation.assigned_unit_id
  in
  let intent_json =
    match operation.intent_id with
    | Some intent_id -> (
        match lookup_intent (read_intents config) intent_id with
        | Some intent -> intent_to_json intent
        | None ->
            `Assoc
              [
                ("status", `String "error");
                ("message", `String (Printf.sprintf "intent not found: %s" intent_id));
              ])
    | None -> `Null
  in
  `Assoc
    [
      ("operation", operation_to_json operation);
      ("assigned_unit_label", `String unit_label);
      ("intent", intent_json);
      ("search", operation_search_json config units operations operation);
    ]

let list_operations_json_from_state ?operation_id (state : snapshot_state) =
  let units = state.units in
  let operations =
    state.operations
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
  let microarch =
    operations_summary_json_from_state { state with operations }
    |> U.member "microarch"
  in
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
      ("microarch", microarch);
      ( "operations",
        `List
          (List.map
             (operation_card_json state.config units state.operations)
             operations) );
    ]

let list_operations_json ?operation_id config =
  list_operations_json_from_state ?operation_id (build_snapshot_state config)

let linked_operations_for_intent config intent_id =
  let operations : operation_record list = read_operations config in
  let filtered =
    List.filter
      (fun (operation : operation_record) ->
        match operation.intent_id with
        | Some current -> String.equal current intent_id
        | None -> false)
      operations
  in
  List.sort
    (fun (left : operation_record) (right : operation_record) ->
      String.compare right.updated_at left.updated_at)
    filtered

let intent_focus_json focus = intent_focus_to_json focus

let unresolved_dependencies operations (operation : operation_record) =
  operation.depends_on_operation_ids
  |> List.filter_map (fun dep_id ->
         match operation_by_id operations dep_id with
         | Some upstream when upstream.status = Completed -> None
         | Some upstream when Option.is_some upstream.checkpoint_ref -> None
         | Some upstream -> Some upstream.operation_id
         | None -> Some dep_id)

let intent_forecast_json config intent_id ?(limit = 3) () =
  with_intent config intent_id (fun _ intent ->
      let operations = linked_operations_for_intent config intent_id in
      let latest_operation = List.nth_opt operations 0 in
      let base_focus =
        match latest_operation with
        | Some operation -> focus_of_operation operation
        | None ->
            {
              intent.current_focus with
              artifact_scope =
                if intent.current_focus.artifact_scope <> [] then
                  intent.current_focus.artifact_scope
                else
                  intent.artifact_priors;
            }
      in
      let risk_flags =
        let flags = ref [] in
        (match latest_operation with
        | None -> flags := "no_linked_operations" :: !flags
        | Some operation ->
            if operation.status = Failed then
              flags := "failed_operation_present" :: !flags;
            if
              String.equal intent.workload_profile "coding_task"
              && base_focus.artifact_scope = []
              &&
              match base_focus.stage with
              | Some "decompose" | None -> false
              | _ -> true
            then
              flags := "missing_artifact_scope" :: !flags;
            if
              match normalize_stage operation.stage with
              | Some ("verify" | "review") ->
                  unresolved_dependencies operations operation <> []
              | _ -> false
            then
              flags := "verification_gap" :: !flags);
        List.rev !flags
      in
      let blocked_by =
        match latest_operation with
        | Some operation -> unresolved_dependencies operations operation
        | None -> []
      in
      let candidate_focuses =
        let artifact_scope =
          if base_focus.artifact_scope <> [] then base_focus.artifact_scope
          else intent.artifact_priors
        in
        let make_candidate ~stage ~score ~reason =
          let verification_state =
            match stage with
            | Some "verify" -> Some "needs_implement_checkpoint"
            | Some "review" -> Some "needs_verify_checkpoint"
            | Some "implement" -> Some "code_change_pending"
            | _ -> base_focus.verification_state
          in
          `Assoc
            [
              ("stage", match stage with Some value -> `String value | None -> `Null);
              ("artifact_scope", json_list_of_strings artifact_scope);
              ("unit_id", match base_focus.unit_id with Some value -> `String value | None -> `Null);
              ( "verification_state",
                match verification_state with Some value -> `String value | None -> `Null );
              ("successor_score", `Float score);
              ("reason", `String reason);
            ]
        in
        match latest_operation with
        | None ->
            [ make_candidate ~stage:(next_stage_for intent.workload_profile None)
                ~score:0.9 ~reason:"bootstrap from adopted intent" ]
        | Some operation -> (
            let next_stage = next_stage_for intent.workload_profile operation.stage in
            match operation.status with
            | Completed ->
                [
                  make_candidate ~stage:next_stage ~score:0.92
                    ~reason:"advance to successor stage after completed operation";
                  make_candidate ~stage:operation.stage ~score:0.35
                    ~reason:"keep recent focus warm for follow-up";
                ]
            | Active | Planned | Paused ->
                [
                  make_candidate ~stage:operation.stage ~score:0.78
                    ~reason:"continue active focus";
                  make_candidate ~stage:next_stage ~score:0.58
                    ~reason:"prepare successor stage in parallel";
                ]
            | Failed | Cancelled ->
                [
                  make_candidate ~stage:operation.stage ~score:0.25
                    ~reason:"recover failed focus before advancing";
                ])
      in
      let candidate_focuses =
        candidate_focuses
        |> List.filteri (fun idx _ -> idx < limit)
      in
      let recommended_focus =
        match candidate_focuses with
        | (`Assoc _ as focus) :: _ -> focus
        | _ -> intent_focus_json base_focus
      in
      Ok
        (`Assoc
          [
            ("intent", intent_to_json intent);
            ("current_focus", intent_focus_json base_focus);
            ("candidate_next_states", `List candidate_focuses);
            ("risk_flags", json_list_of_strings risk_flags);
            ("blocked_by", json_list_of_strings blocked_by);
            ("recommended_focus", recommended_focus);
          ]))

let list_intents_json ?intent_id config =
  let intents = read_intents config in
  let rows =
    intents
    |> List.filter (fun (intent : intent_record) ->
           match intent_id with
           | Some value -> String.equal intent.intent_id value
           | None -> true)
  in
  let state_count state =
    rows
    |> List.filter (fun (intent : intent_record) -> intent.state = state)
    |> List.length
  in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ( "summary",
        `Assoc
          [
            ("total", `Int (List.length rows));
            ("active", `Int (state_count Active_intent));
            ("blocked", `Int (state_count Blocked_intent));
            ("handoff_ready", `Int (state_count Handoff_ready));
          ] );
      ("intents", `List (List.map intent_to_json rows));
    ]

let create_intent_json config ~(actor : string) json =
  let title =
    match get_string_opt json "title" with
    | Some value -> value
    | None -> invalid_arg "title is required"
  in
  let workload_profile_raw =
    get_string_default json "workload_profile" "coding_task"
  in
  let* workload_profile = validate_workload_profile workload_profile_raw in
  let current_focus =
    match U.member "current_focus" json with
    | `Assoc _ as value -> intent_focus_of_json value
    | _ -> empty_intent_focus
  in
  let intent =
    {
      intent_id = next_intent_id ();
      title;
      owner = get_string_default json "owner" actor;
      workload_profile;
      success_metric =
        (match U.member "success_metric" json with
        | `Null -> None
        | value -> Some value);
      invariants = get_string_list json "invariants";
      artifact_priors = get_string_list json "artifact_priors";
      state =
        (match get_string_opt json "state" with
        | Some value -> (
            match intent_state_of_string value with
            | Some state -> state
            | None -> Adopted)
        | None -> Adopted);
      current_focus;
      checkpoint_ref = get_string_opt json "checkpoint_ref";
      source = "managed";
      created_at = Types.now_iso ();
      updated_at = Types.now_iso ();
    }
  in
  let intents = read_intents config in
  write_intents config (intent :: intents);
  append_cp_event config ~trace_id:(next_trace_id ()) ~event_type:"intent_created"
    ~actor (`Assoc [ ("intent_id", `String intent.intent_id) ]);
  Ok intent

let update_intent_json config ~(actor : string) json =
  let intent_id =
    match get_string_opt json "intent_id" with
    | Some value -> value
    | None -> invalid_arg "intent_id is required"
  in
  with_intent config intent_id (fun intents intent ->
      let workload_profile =
        match get_string_opt json "workload_profile" with
        | Some value -> validate_workload_profile value
        | None -> Ok intent.workload_profile
      in
      let* workload_profile = workload_profile in
      let current_focus =
        match U.member "current_focus" json with
        | `Assoc _ as value -> intent_focus_of_json value
        | _ -> intent.current_focus
      in
      let state =
        match get_string_opt json "state" with
        | Some value -> (
            match intent_state_of_string value with
            | Some state -> state
            | None ->
                invalid_arg
                  (Printf.sprintf "unsupported intent state: %s" value))
        | None -> intent.state
      in
      let updated =
        {
          intent with
          title = get_string_default json "title" intent.title;
          owner = get_string_default json "owner" intent.owner;
          workload_profile;
          success_metric =
            (match U.member "success_metric" json with
            | `Null -> intent.success_metric
            | value -> Some value);
          invariants =
            (match U.member "invariants" json with
            | `List _ -> get_string_list json "invariants"
            | _ -> intent.invariants);
          artifact_priors =
            (match U.member "artifact_priors" json with
            | `List _ -> get_string_list json "artifact_priors"
            | _ -> intent.artifact_priors);
          state;
          current_focus;
          checkpoint_ref =
            option_first_some (get_string_opt json "checkpoint_ref")
              intent.checkpoint_ref;
          updated_at = Types.now_iso ();
        }
      in
      write_intents config (replace_intent intents updated);
      append_cp_event config ~trace_id:(next_trace_id ()) ~event_type:"intent_updated"
        ~actor (`Assoc [ ("intent_id", `String updated.intent_id) ]);
      Ok updated)

let snapshot_json config =
  let state = build_snapshot_state config in
  let topology = topology_json_from_state state in
  let intents = intents_summary_json_from_state state in
  let operations = list_operations_json_from_state state in
  let detachments = list_detachments_json_from_state state in
  let alerts = list_alerts_json_from_state config state in
  let decisions = list_policy_decisions_json_from_state state in
  let capacity = capacity_json_from_state state in
  let traces = list_traces_json config ~limit:10 () in
  `Assoc
    [
      ("version", `String "cp-v2");
      ("generated_at", `String (Types.now_iso ()));
      ("topology", topology);
      ("intents", intents);
      ("operations", operations);
      ("detachments", detachments);
      ("alerts", alerts);
      ("decisions", decisions);
      ("capacity", capacity);
      ("traces", traces);
    ]

let operation_status_json config ?operation_id () =
  list_operations_json ?operation_id config

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
      touch_intent_from_operation config ~actor updated ~state:Active_intent;
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
      let next_chain_status =
        match status with
        | Planned -> Some "pending"
        | Active -> Some "running"
        | Paused -> Some "paused"
        | Cancelled -> Some "cancelled"
        | Completed -> Some "completed"
        | Failed -> Some "failed"
      in
      let updated =
        {
          current with
          status;
          chain =
            (match current.chain, next_chain_status with
            | Some chain, Some chain_status ->
                Some { chain with status = chain_status }
            | None, Some _ -> None
            | existing, None -> existing);
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
      let intent_state =
        match status with
        | Planned | Active -> Active_intent
        | Paused -> Suspended_intent
        | Completed -> Completed_intent
        | Cancelled -> Dropped_intent
        | Failed -> Blocked_intent
      in
      touch_intent_from_operation config ~actor updated ~state:intent_state;
      append_cp_event config ~trace_id:updated.trace_id ~event_type
        ~operation_id:updated.operation_id ~unit_id:updated.assigned_unit_id ~actor
        (`Assoc [ ("status", `String (string_of_operation_status status)) ]);
      Ok updated)

let update_operation config ~(actor : string) ~operation_id ?event_type ?detail f =
  with_operation config operation_id (fun operations current ->
      let updated : operation_record =
        f current |> fun (operation : operation_record) -> { operation with updated_at = Types.now_iso () }
      in
      write_operations config (replace_operation operations updated);
      let _, _, units, _ = topology_units config in
      let _ = sync_managed_detachments config units updated in
      (match event_type with
      | Some current_event_type ->
          append_cp_event config ~trace_id:updated.trace_id ~event_type:current_event_type
            ~operation_id:updated.operation_id ~unit_id:updated.assigned_unit_id
            ~actor
            (Option.value ~default:(`Assoc []) detail)
      | None -> ());
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
  let validate_coding_dependency_requirement ~stage ~depends_on_operation_ids =
    let expected_stage =
      match stage with
      | "verify" -> Some "implement"
      | "review" -> Some "verify"
      | _ -> None
    in
    match expected_stage with
    | None -> Ok ()
    | Some expected_stage ->
        if depends_on_operation_ids = [] then
          Error
            (Printf.sprintf
               "coding_task %s stage requires at least one %s dependency"
               stage expected_stage)
        else
          let operations = read_operations config in
          if
            List.exists
              (fun dep_id ->
                match operation_by_id operations dep_id with
                | Some dependency ->
                    String.equal (operation_workload_profile dependency) "coding_task"
                    && normalize_stage dependency.stage = Some expected_stage
                | None -> false)
              depends_on_operation_ids
          then
            Ok ()
          else
            Error
              (Printf.sprintf
                 "coding_task %s stage requires a coding_task %s dependency"
                 stage expected_stage)
  in
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
      let workload_profile_raw =
        get_string_default json "workload_profile" "coding_task"
      in
      let search_strategy_raw =
        get_string_default json "search_strategy" (room_search_strategy_default config)
      in
      let depends_on_operation_ids = get_string_list json "depends_on_operation_ids" in
      let requested_intent_id = get_string_opt json "intent_id" in
      let raw_artifact_scope = get_string_list json "artifact_scope" in
      let* workload_profile = validate_workload_profile workload_profile_raw in
      let* stage =
        validate_stage_for_workload ~workload_profile (get_string_opt json "stage")
      in
      let* search_strategy = validate_search_strategy search_strategy_raw in
      let* intent_binding =
        match requested_intent_id with
        | None -> Ok None
        | Some intent_id ->
            with_intent config intent_id (fun _ intent ->
                if not (String.equal intent.workload_profile workload_profile) then
                  Error
                    (Printf.sprintf
                       "intent workload_profile mismatch: intent=%s operation=%s"
                       intent.workload_profile workload_profile)
                else
                  Ok (Some intent))
      in
      let artifact_scope =
        match intent_binding with
        | Some intent when raw_artifact_scope = [] -> intent.artifact_priors
        | _ -> raw_artifact_scope
      in
      let* () =
        match workload_profile, stage with
        | "coding_task", Some ("verify" | "review" as stage_name) ->
            validate_coding_dependency_requirement ~stage:stage_name
              ~depends_on_operation_ids
        | _ -> Ok ()
      in
      let chain =
        match U.member "chain" json with
        | (`Assoc _ as chain_json) -> (
            match get_string_opt chain_json "kind", get_string_opt chain_json "status" with
            | Some kind, Some status ->
                Some
                  {
                    kind;
                    backend = get_string_default chain_json "backend" "legacy";
                    chain_id = get_string_opt chain_json "chain_id";
                    goal = get_string_opt chain_json "goal";
                    run_id = get_string_opt chain_json "run_id";
                    status;
                    history_event =
                      (match U.member "history_event" chain_json with
                      | `Null -> None
                      | `Assoc _ as json -> Some json
                      | _ -> None);
                    mermaid = get_string_opt chain_json "mermaid";
                    preview_run =
                      (match U.member "preview_run" chain_json with
                      | `Null -> None
                      | `Assoc _ as json -> Some json
                      | _ -> None);
                    viewer_path = get_string_opt chain_json "viewer_path";
                    last_sync_at = get_string_opt chain_json "last_sync_at";
                  }
            | _ -> None)
        | _ -> None
      in
      let checkpoint_ref =
        match get_string_opt json "checkpoint_ref", chain with
        | Some value, _ -> Some value
        | None, Some { run_id = Some run_id; _ } -> Some run_id
        | None, _ -> None
      in
      let operation =
        {
          operation_id = next_operation_id ();
          objective;
          intent_id = Option.map (fun (intent : intent_record) -> intent.intent_id) intent_binding;
          assigned_unit_id;
          autonomy_level = get_string_default json "autonomy_level" "L4_Autonomous";
          policy_class = get_string_default json "policy_class" "strict";
          budget_class = get_string_default json "budget_class" "standard";
          workload_profile;
          stage;
          artifact_scope;
          depends_on_operation_ids;
          search_strategy;
          detachment_session_id = get_string_opt json "detachment_session_id";
          trace_id = next_trace_id ();
          checkpoint_ref;
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
          chain;
          created_at = Types.now_iso ();
          updated_at = Types.now_iso ();
        }
      in
      let operations = read_operations config in
      write_operations config (operation :: operations);
      let _, _, units, _ = topology_units config in
      let _ =
        match operation_search_strategy operation with
        | Cp_search_fabric.Legacy -> sync_managed_detachments config units operation
        | Cp_search_fabric.Best_first_v1 -> []
      in
      touch_intent_from_operation config ~actor operation ~state:Active_intent;
      append_cp_event config ~trace_id:operation.trace_id ~event_type:"operation_started"
        ~operation_id:operation.operation_id ~unit_id:operation.assigned_unit_id ~actor
        (`Assoc
          [
            ("objective", `String operation.objective);
            ("intent_id", match operation.intent_id with Some value -> `String value | None -> `Null);
            ("autonomy_level", `String operation.autonomy_level);
            ("policy_class", `String operation.policy_class);
            ("workload_profile", `String (operation_workload_profile operation));
            ("stage", match operation.stage with Some value -> `String value | None -> `Null);
            ("artifact_scope", json_list_of_strings operation.artifact_scope);
            ("search_strategy", `String operation.search_strategy);
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
      touch_intent_from_operation config ~actor updated ~state:Active_intent;
      if operation_search_strategy updated = Cp_search_fabric.Best_first_v1 then
        update_search_stats_for_operation config updated ~outcome:`Success;
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
      Result.map
        (fun operation ->
          if operation_search_strategy operation = Cp_search_fabric.Best_first_v1 then
            update_search_stats_for_operation config operation ~outcome:`Success;
          operation_to_json operation)
        (update_operation_status config ~actor ~operation_id ~status:Completed
           ~note:(get_string_opt json "note") ~event_type:"operation_finalized")

let dispatch_plan_json config json =
  let _, _, units, _ = topology_units config in
  let operations = all_operations config units in
  let operation_id = get_string_opt json "operation_id" in
  let operation =
    match operation_id with
    | Some value -> operation_by_id operations value
    | None -> None
  in
  let current_unit_id = Option.map (fun (op : operation_record) -> op.assigned_unit_id) operation in
  let strategy =
    match operation with
    | Some op -> operation_search_strategy op
    | None -> Cp_search_fabric.Legacy
  in
  let readiness =
    match operation with
    | Some op -> operation_readiness operations op
    | None -> Cp_search_fabric.Ready
  in
  let scored_candidates =
    match operation with
    | Some op when strategy = Cp_search_fabric.Best_first_v1 ->
        operation_search_candidates config units operations op
    | Some op ->
        let preview_op = { op with search_strategy = "best_first_v1" } in
        operation_search_candidates config units operations preview_op
    | None -> []
  in
  let recommended_units =
    if scored_candidates <> [] then
      scored_candidates
      |> List.map (fun (candidate : Cp_search_fabric.scored_candidate) ->
             `Assoc
               [
                 ( "unit",
                   match lookup_unit units candidate.unit_id with
                   | Some unit -> unit_to_json unit
                   | None ->
                       `Assoc
                         [
                           ("unit_id", `String candidate.unit_id);
                           ("label", `String candidate.label);
                         ] );
                 ("score", `Float candidate.breakdown.total);
                 ( "score_breakdown",
                   Cp_search_fabric.breakdown_to_json candidate.breakdown );
                 ("routing_reason", `String candidate.routing_reason);
               ])
    else
      candidate_units_for_operation units operations current_unit_id
      |> List.filter_map (fun (unit : unit_record) ->
             match unit_guard_json config unit.unit_id with
             | Ok guard ->
                 Some
                   (`Assoc
                     [
                       ("unit", unit_to_json unit);
                       ("guard", guard);
                       ("score", `Null);
                       ("score_breakdown", `Null);
                       ("routing_reason", `String "legacy candidate ordering");
                     ])
             | Error _ -> None)
  in
  `Assoc
    [
      ("status", `String "ok");
      ("strategy", `String (Cp_search_fabric.strategy_to_string strategy));
      ( "readiness",
        match readiness with
        | Cp_search_fabric.Ready -> `String "ready"
        | Cp_search_fabric.Blocked _ -> `String "blocked" );
      ( "dependency_blockers",
        match readiness with
        | Cp_search_fabric.Ready -> `List []
        | Cp_search_fabric.Blocked blockers ->
            `List (List.map Cp_search_fabric.blocker_to_json blockers) );
      ("recommended_units", `List recommended_units);
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

let detachment_status_detail_json config units agents operations
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
  let search_json =
    operation_by_id operations detachment.operation_id
    |> Option.map (operation_search_json config units operations)
    |> Option.value ~default:`Null
  in
  `Assoc
    [
      ("detachment", detachment_to_json detachment);
      ("assigned_unit_label", `String unit_label);
      ("operation", operation_json);
      ("search", search_json);
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

let maybe_apply_best_first_assignment config ~actor units operations
    (operation : operation_record) =
  match operation_search_strategy operation with
  | Cp_search_fabric.Legacy -> operation
  | Cp_search_fabric.Best_first_v1 -> (
      match operation_readiness operations operation with
      | Cp_search_fabric.Blocked _ -> operation
      | Cp_search_fabric.Ready -> (
          let candidates =
            operation_search_candidates config units operations operation
          in
          match candidates with
          | [] -> operation
          | best :: _ ->
              let best =
                match speculative_pick_candidate config operation candidates with
                | Some candidate -> candidate
                | None -> best
              in
              let current =
                candidates
                |> List.find_opt (fun (candidate : Cp_search_fabric.scored_candidate) ->
                       String.equal candidate.unit_id operation.assigned_unit_id)
              in
              let should_move =
                match current with
                | Some current_candidate ->
                    String.equal best.unit_id current_candidate.unit_id
                    |> not
                    && Cp_search_fabric.should_rebalance ~current:current_candidate
                         ~best ~min_gain:15.0
                | None -> not (String.equal best.unit_id operation.assigned_unit_id)
              in
              if not should_move then
                operation
              else
                match
                  apply_operation_assignment config ~actor operation
                    ~target_unit_id:best.unit_id
                    ~note:
                      (Some
                         (Printf.sprintf "best_first_v1 routed to %s (score=%.1f)"
                            best.unit_id best.breakdown.total))
                    ~event_type:"operation_search_routed"
                with
                | Ok updated ->
                    append_cp_event config ~trace_id:updated.trace_id
                      ~event_type:"operation_search_scored"
                      ~operation_id:updated.operation_id
                      ~unit_id:updated.assigned_unit_id ~actor
                      (`Assoc
                        [
                          ("selected_unit_id", `String best.unit_id);
                          ("score", `Float best.breakdown.total);
                          ( "score_breakdown",
                            Cp_search_fabric.breakdown_to_json best.breakdown );
                          ("routing_reason", `String best.routing_reason);
                        ]);
                    updated
                | Error _ -> operation))

let dispatch_tick_json config ~(actor : string) json =
  let filter_operation_id = get_string_opt json "operation_id" in
  let filter_detachment_id = get_string_opt json "detachment_id" in
  let agents, _, units, _ = topology_units config in
  let live_agents = live_agent_names agents in
  let all_managed_operations = read_operations config in
  let managed_operations =
    all_managed_operations
    |> List.filter (fun (operation : operation_record) ->
           match filter_operation_id with
           | Some value -> String.equal operation.operation_id value
           | None -> true)
  in
  let planned_operations =
    managed_operations
    |> List.map
         (maybe_apply_best_first_assignment config ~actor units
            all_managed_operations)
  in
  let synced =
    planned_operations
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
      planned_operations
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
                      if operation_search_strategy operation = Cp_search_fabric.Best_first_v1 then
                        update_search_stats_for_operation config operation
                          ~outcome:`Failure;
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
