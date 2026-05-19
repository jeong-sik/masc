type per_provider_timeout_state =
  | Per_provider_timeout_unset
  | Per_provider_timeout_invalid
  | Per_provider_timeout_set

type keeper_profile_defaults = {
  id : Ids.Keeper_id.t option;
  manifest_path : string option;
  persona_name : string option;
  goal : string option;
  short_goal : string option;
  mid_goal : string option;
  long_goal : string option;
  will : string option;
  needs : string option;
  desires : string option;
  instructions : string option;
  policy_voice_enabled : bool option;
  autoboot_enabled : bool option;
  mention_targets : string list;
  proactive_enabled : bool option;
  proactive_idle_sec : int option;
  proactive_cooldown_sec : int option;
  room_signal_prompt_enabled : bool option;
  shards : string list option;
  allowed_paths : string list option;
  sandbox_profile : Keeper_types_profile_sandbox.sandbox_profile option;
  sandbox_image : string option;
  network_mode : Keeper_types_profile_sandbox.network_mode option;
  github_identity : string option;
  git_identity_mode : string option;
  tool_preset : string option;
  tool_preset_source : string option;
  tool_also_allow : string list option;
  tool_denylist : string list option;
  active_goal_ids : string list option;
  (* Work Discovery — config-driven proactive work scanning *)
  work_discovery_enabled : bool option;
  work_discovery_sources : string list option;
  work_discovery_interval_sec : int option;
  work_discovery_guidance : string option;
  (* Telemetry Feedback — inject behavioral stats into keeper context *)
  telemetry_feedback_enabled : bool option;
  telemetry_feedback_window_hours : int option;
  per_provider_timeout_state : per_provider_timeout_state;
  (* Per-provider timeout for cascade fallback. None = use turn budget heuristic. *)
  per_provider_timeout : float option;
  always_approve : bool option;
  social_model : string option;
  cascade_name : string option;
  models : string list option;
  (* Turn budget overrides. None = inherit env default
     (MASC_KEEPER_OAS_MAX_TURNS_PER_CALL / ..._SCHEDULED_AUTONOMOUS). *)
  max_turns_per_call : int option;
  max_turns_per_call_scheduled_autonomous : int option;
  (* Per-keeper OAS CLI transport env vars (OAS 0.159+).
     Parsed from [[keeper.oas_env]] table.  Keys MUST match
     ^OAS_(CLAUDE|CODEX|GEMINI)_.+ — any other entries are dropped with
     a warning to avoid ambient env injection via keeper TOML.
     Applied via Unix.putenv right before each turn so OAS transport
     build_args picks them up.  Empty list = no overrides. *)
  oas_env : (string * string) list;
  (* Keys present under [keeper] (or other tables) that are NOT in
     [canonical_keeper_toml_key_names].  Captured at load time so
     downstream surfaces (keeper_status_detail, dashboards) can show
     drift instead of silently ignoring legacy / typo'd keys.
     Today this is also logged via [warn_unknown_keeper_toml_keys];
     the field is purely additive. *)
  unknown_toml_keys : string list;
}

let empty_keeper_profile_defaults =
  {
    id = None;
    manifest_path = None;
    persona_name = None;
    goal = None;
    short_goal = None;
    mid_goal = None;
    long_goal = None;
    will = None;
    needs = None;
    desires = None;
    instructions = None;
    policy_voice_enabled = None;
    autoboot_enabled = None;
    mention_targets = [];
    proactive_enabled = None;
    proactive_idle_sec = None;
    proactive_cooldown_sec = None;
    room_signal_prompt_enabled = None;
    shards = None;
    allowed_paths = None;
    sandbox_profile = None;
    sandbox_image = None;
    network_mode = None;
    github_identity = None;
    git_identity_mode = None;
    tool_preset = None;
    tool_preset_source = None;
    tool_also_allow = None;
    tool_denylist = None;
    active_goal_ids = None;
    work_discovery_enabled = None;
    work_discovery_sources = None;
    work_discovery_interval_sec = None;
    work_discovery_guidance = None;
    telemetry_feedback_enabled = None;
    telemetry_feedback_window_hours = None;
    per_provider_timeout_state = Per_provider_timeout_unset;
    per_provider_timeout = None;
    always_approve = None;
    social_model = None;
    max_turns_per_call = None;
    max_turns_per_call_scheduled_autonomous = None;
    cascade_name = None;
    models = None;
    unknown_toml_keys = [];
    oas_env = [];
  }
;;

type keeper_oas_context = {
  env_pairs : (string * string) list;
  gemini_mcp_disabled : bool;
  gemini_approval_mode : string option;
  gemini_approval_mode_derived : bool;
  gemini_allowed_mcp_derived : bool;
  claude_mcp_config : string option;
}

let empty_keeper_oas_context =
  {
    env_pairs = [];
    gemini_mcp_disabled = false;
    gemini_approval_mode = None;
    gemini_approval_mode_derived = false;
    gemini_allowed_mcp_derived = false;
    claude_mcp_config = None;
  }
;;

let non_empty_trimmed_assoc key pairs =
  List.assoc_opt key pairs
  |> Option.map String.trim
  |> fun value ->
  Option.bind value (fun trimmed -> if trimmed = "" then None else Some trimmed)
;;

let keeper_oas_context_of_defaults defaults =
  let module Oas_env = Keeper_types_profile_oas_env in
  let env_pairs = Oas_env.effective_oas_env defaults.oas_env in
  let gemini_mcp_disabled =
    match List.assoc_opt "OAS_GEMINI_NO_MCP" env_pairs with
    | Some value -> Oas_env.oas_env_truthy value
    | None -> false
  in
  let gemini_approval_mode_explicit =
    non_empty_trimmed_assoc "OAS_GEMINI_APPROVAL_MODE" defaults.oas_env
  in
  let gemini_approval_mode =
    non_empty_trimmed_assoc "OAS_GEMINI_APPROVAL_MODE" env_pairs
  in
  let gemini_approval_mode_derived =
    gemini_mcp_disabled
    && Option.is_none gemini_approval_mode_explicit
    && Option.is_some gemini_approval_mode
  in
  let claude_mcp_config =
    match List.assoc_opt "OAS_CLAUDE_MCP_CONFIG" env_pairs with
    | Some raw when String.trim raw <> "" -> Some raw
    | _ ->
      if
        match List.assoc_opt "OAS_CLAUDE_STRICT_MCP" env_pairs with
        | Some value -> Oas_env.oas_env_truthy value
        | None -> false
      then Some {|{"mcpServers":{}}|}
      else None
  in
  let gemini_allowed_mcp_derived =
    (not gemini_mcp_disabled)
    && not (Oas_env.oas_env_has_non_empty "OAS_GEMINI_ALLOWED_MCP" defaults.oas_env)
  in
  {
    env_pairs;
    gemini_mcp_disabled;
    gemini_approval_mode;
    gemini_approval_mode_derived;
    gemini_allowed_mcp_derived;
    claude_mcp_config;
  }
;;
