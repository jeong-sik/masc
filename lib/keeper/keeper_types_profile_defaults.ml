type keeper_profile_defaults = {
  id : Ids.Keeper_id.t option;
  manifest_path : string option;
  persona_name : string option;
  instructions : string option;
  autoboot_enabled : bool option;
  mention_targets : string list;
  proactive_enabled : bool option;
  allowed_paths : string list option;
  sandbox_profile : Keeper_types_profile_sandbox.sandbox_profile option;
  sandbox_image : string option;
  network_mode : Keeper_types_profile_sandbox.network_mode option;
  multimodal_policy : Keeper_types_profile_sandbox.multimodal_policy option;
  (* Telemetry Feedback — inject behavioral stats into keeper context *)
  telemetry_feedback_enabled : bool option;
  telemetry_feedback_window_hours : int option;
  always_allow : bool option;
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
    instructions = None;
    autoboot_enabled = None;
    mention_targets = [];
    proactive_enabled = None;
    allowed_paths = None;
    sandbox_profile = None;
    sandbox_image = None;
    network_mode = None;
    multimodal_policy = None;
    telemetry_feedback_enabled = None;
    telemetry_feedback_window_hours = None;
    always_allow = None;
    unknown_toml_keys = [];
    oas_env = [];
  }
;;
