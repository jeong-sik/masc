type keeper_profile_defaults = {
  id : Ids.Keeper_id.t option;
  manifest_path : string option;
  instructions : string option;
  (* Per-keeper autonomous-turn instructions. When non-empty and the turn
     channel is Scheduled_autonomous, this replaces [instructions] in the
     system prompt. When absent, autonomous turns fall back to [instructions]
     — zero behavioral change for keepers that don't set it. *)
  autonomous_instructions : string option;
  autoboot_enabled : bool option;
  mention_targets : string list;
  proactive_enabled : bool option;
  allowed_paths : string list option;
  sandbox_profile : Keeper_types_profile_sandbox.sandbox_profile option;
  sandbox_image : string option;
  network_mode : Keeper_types_profile_sandbox.network_mode option;
  multimodal_policy : Keeper_types_profile_sandbox.multimodal_policy option;
  (* User message this keeper's autonomous turns are woken with, overriding the
     fleet [autonomous.wake_prompt]. Distinct from [instructions]: that frames
     the system prompt once, this is the conversation input the keeper receives
     every cycle and which the durable checkpoint keeps. [None] inherits. *)
  autonomous_wake_prompt : string option;
  max_context_override : int option;
  (* Telemetry Feedback — inject behavioral stats into keeper context *)
  telemetry_feedback_enabled : bool option;
  telemetry_feedback_window_hours : int option;
  always_allow : bool option;
  (* Per-keeper AGENT_CORE CLI transport env vars (AGENT_CORE 0.159+).
     Parsed from [[keeper.agent_core_env]] table.  Keys MUST match
     ^AGENT_CORE_[A-Z]+_.+ — any other entries are dropped with
     a warning to avoid ambient env injection via keeper TOML.
     Applied via Unix.putenv right before each turn so AGENT_CORE transport
     build_args picks them up.  Empty list = no overrides. *)
  agent_core_env : (string * string) list;
}

let empty_keeper_profile_defaults =
  {
    id = None;
    manifest_path = None;
    instructions = None;
    autonomous_instructions = None;
    autoboot_enabled = None;
    mention_targets = [];
    proactive_enabled = None;
    allowed_paths = None;
    sandbox_profile = None;
    sandbox_image = None;
    network_mode = None;
    multimodal_policy = None;
    autonomous_wake_prompt = None;
    max_context_override = None;
    telemetry_feedback_enabled = None;
    telemetry_feedback_window_hours = None;
    always_allow = None;
    agent_core_env = [];
  }
;;
