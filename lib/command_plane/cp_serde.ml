include Cp_paths

let nonempty_string = function
  | Some raw ->
      let value = String.trim raw in
      if value = "" then None else Some value
  | None -> None

let dedup_strings = Dashboard_utils.dedup_strings

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
  | `Intlit value -> (Option.value ~default:default (int_of_string_opt value))
  | _ -> default

let get_float_default json key default =
  match U.member key json with
  | `Float value -> value
  | `Int value -> float_of_int value
  | `Intlit value -> (try float_of_string value with Failure _ -> default)
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

let legacy_chain_run_id json =
  match U.member "chain" json with
  | `Assoc _ as chain_json -> get_string_opt chain_json "run_id"
  | _ -> None

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

let normalize_workload_template = function
  | Some value ->
      let trimmed = String.trim value |> String.lowercase_ascii in
      if trimmed = "" then None else Some trimmed
  | None -> None

let validate_workload_template raw =
  match normalize_workload_template (Some raw) with
  | Some ("coding_team" | "research_team" | "ops_governance_team" as value) ->
      Ok value
  | Some other ->
      Error (Printf.sprintf "unsupported workload_template: %s" other)
  | None -> Error "unsupported workload_template: "

let workload_template_defaults = function
  | "coding_team" -> Some ("coding_task", Some "decompose")
  | "research_team" -> Some ("research_pipeline", Some "normalize")
  | "ops_governance_team" -> Some ("research_pipeline", Some "audit")
  | _ -> None

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
      ("stage", Json_util.string_opt_to_json focus.stage);
      ("artifact_scope", json_list_of_strings focus.artifact_scope);
      ("unit_id", Json_util.string_opt_to_json focus.unit_id);
      ("verification_state", Json_util.string_opt_to_json focus.verification_state);
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
      ("parent_unit_id", Json_util.string_opt_to_json unit.parent_unit_id);
      ("leader_id", Json_util.string_opt_to_json unit.leader_id);
      ("roster", json_list_of_strings unit.roster);
      ("capability_profile", json_list_of_strings unit.capability_profile);
      ("policy", policy_to_json unit.policy);
      ("budget", budget_to_json unit.budget);
      ("source", `String unit.source);
      ("created_at", `String unit.created_at);
      ("updated_at", `String unit.updated_at);
    ]

let unit_of_json json =
  match Option.bind (get_string_opt json "kind") unit_kind_of_string with
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
      ("intent_id", Json_util.string_opt_to_json operation.intent_id);
      ("assigned_unit_id", `String operation.assigned_unit_id);
      ("policy_class", `String operation.policy_class);
      ("budget_class", `String operation.budget_class);
      ("workload_template", Json_util.string_opt_to_json operation.workload_template);
      ("workload_profile", `String (operation_workload_profile operation));
      ("stage", Json_util.string_opt_to_json operation.stage);
      ("artifact_scope", json_list_of_strings operation.artifact_scope);
      ("depends_on_operation_ids", json_list_of_strings operation.depends_on_operation_ids);
      ("search_strategy", `String operation.search_strategy);
      ("detachment_session_id", Json_util.string_opt_to_json operation.detachment_session_id);
      ("trace_id", `String operation.trace_id);
      ("checkpoint_ref", Json_util.string_opt_to_json operation.checkpoint_ref);
      ("active_goal_ids", json_list_of_strings operation.active_goal_ids);
      ("note", Json_util.string_opt_to_json operation.note);
      ("created_by", `String operation.created_by);
      ("source", `String operation.source);
      ("status", `String (string_of_operation_status operation.status));
      ("chain", `Null);
      ("created_at", `String operation.created_at);
      ("updated_at", `String operation.updated_at);
    ]

(* operation_of_json tolerates a legacy "chain" key in stored JSON for
   backwards compatibility and keeps chain.run_id as a checkpoint_ref
   fallback without reintroducing chain_record. *)
let operation_of_json json =
  match Option.bind (get_string_opt json "status") operation_status_of_string with
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
            policy_class = get_string_default json "policy_class" "strict";
            budget_class = get_string_default json "budget_class" "standard";
            workload_template =
              normalize_workload_template (get_string_opt json "workload_template");
            workload_profile =
              Cp_search_fabric.normalized_workload_profile
                (get_string_default json "workload_profile" "coding_task");
            stage = normalize_stage (get_string_opt json "stage");
            artifact_scope = get_string_list json "artifact_scope";
            depends_on_operation_ids = get_string_list json "depends_on_operation_ids";
            search_strategy = get_string_default json "search_strategy" "best_first_v1";
            detachment_session_id = get_string_opt json "detachment_session_id";
            trace_id;
            checkpoint_ref =
              option_or_else (get_string_opt json "checkpoint_ref") (fun () ->
                  legacy_chain_run_id json);
            active_goal_ids = get_string_list json "active_goal_ids";
            note = get_string_opt json "note";
            created_by;
            source = get_string_default json "source" "managed";
            status;
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
      ("checkpoint_ref", Json_util.string_opt_to_json intent.checkpoint_ref);
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
      ("operation_id", Json_util.string_opt_to_json event.operation_id);
      ("unit_id", Json_util.string_opt_to_json event.unit_id);
      ("actor", Json_util.string_opt_to_json event.actor);
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
      ("leader_id", Json_util.string_opt_to_json detachment.leader_id);
      ("roster", json_list_of_strings detachment.roster);
      ("session_id", Json_util.string_opt_to_json detachment.session_id);
      ("checkpoint_ref", Json_util.string_opt_to_json detachment.checkpoint_ref);
      ("runtime_kind", Json_util.string_opt_to_json detachment.runtime_kind);
      ("runtime_ref", Json_util.string_opt_to_json detachment.runtime_ref);
      ("source", `String detachment.source);
      ("status", `String detachment.status);
      ("last_event_at", Json_util.string_opt_to_json detachment.last_event_at);
      ("last_progress_at", Json_util.string_opt_to_json detachment.last_progress_at);
      ("heartbeat_deadline", Json_util.string_opt_to_json detachment.heartbeat_deadline);
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
      ("operation_id", Json_util.string_opt_to_json decision.operation_id);
      ("target_unit_id", Json_util.string_opt_to_json decision.target_unit_id);
      ("requested_by", `String decision.requested_by);
      ("status", `String decision.status);
      ("reason", Json_util.string_opt_to_json decision.reason);
      ("source", `String decision.source);
      ("detail", decision.detail);
      ("created_at", `String decision.created_at);
      ("decided_at", Json_util.string_opt_to_json decision.decided_at);
      ("expires_at", Json_util.string_opt_to_json decision.expires_at);
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
