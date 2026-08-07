type keeper_profile_defaults = {
  id : Ids.Keeper_id.t option;
  manifest_path : string option;
  instructions : string option;
  autoboot_enabled : bool option;
  mention_targets : string list;
  proactive_enabled : bool option;
  allowed_paths : string list option;
  sandbox_profile : Keeper_types_profile_sandbox.sandbox_profile option;
  sandbox_image : string option;
  network_mode : Keeper_types_profile_sandbox.network_mode option;
  multimodal_policy : Keeper_types_profile_sandbox.multimodal_policy option;
  active_goal_ids : string list option;
  max_context_override : int option;
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
}

let empty_keeper_profile_defaults =
  {
    id = None;
    manifest_path = None;
    instructions = None;
    autoboot_enabled = None;
    mention_targets = [];
    proactive_enabled = None;
    allowed_paths = None;
    sandbox_profile = None;
    sandbox_image = None;
    network_mode = None;
    multimodal_policy = None;
    active_goal_ids = None;
    max_context_override = None;
    telemetry_feedback_enabled = None;
    telemetry_feedback_window_hours = None;
    always_allow = None;
    oas_env = [];
  }
;;
