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
  autoboot_enabled : bool option;
  mention_targets : string list;
  proactive_enabled : bool option;
  proactive_idle_sec : int option;
  proactive_cooldown_sec : int option;
  shards : string list option;
  allowed_paths : string list option;
  sandbox_profile : Keeper_types_profile_sandbox.sandbox_profile option;
  sandbox_image : string option;
  network_mode : Keeper_types_profile_sandbox.network_mode option;
  tool_access : string list option;
  tool_denylist : string list option;
  active_goal_ids : string list option;
  (* Telemetry Feedback — inject behavioral stats into keeper context *)
  telemetry_feedback_enabled : bool option;
  telemetry_feedback_window_hours : int option;
  per_provider_timeout_state : per_provider_timeout_state;
  per_provider_timeout : float option;
  always_approve : bool option;
  (* Turn budget overrides. None = inherit env default
     (MASC_KEEPER_OAS_MAX_TURNS_PER_CALL / ..._SCHEDULED_AUTONOMOUS). *)
  max_turns_per_call : int option;
  max_turns_per_call_scheduled_autonomous : int option;
  (* Per-keeper OAS CLI transport env vars (OAS 0.159+).
     Parsed from [[keeper.oas_env]] table.  Keys MUST match
     ^OAS_[A-Z]+_.+ — any other entries are dropped with
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
    autoboot_enabled = None;
    mention_targets = [];
    proactive_enabled = None;
    proactive_idle_sec = None;
    proactive_cooldown_sec = None;
    shards = None;
    allowed_paths = None;
    sandbox_profile = None;
    sandbox_image = None;
    network_mode = None;
    tool_access = None;
    tool_denylist = None;
    active_goal_ids = None;
    telemetry_feedback_enabled = None;
    telemetry_feedback_window_hours = None;
    per_provider_timeout_state = Per_provider_timeout_unset;
    per_provider_timeout = None;
    always_approve = None;
    max_turns_per_call = None;
    max_turns_per_call_scheduled_autonomous = None;
    unknown_toml_keys = [];
    oas_env = [];
  }
;;
