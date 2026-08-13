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
  (* User message this keeper's autonomous turns are woken with, overriding the
     fleet [autonomous.wake_prompt]. Distinct from [instructions]: that frames
     the system prompt once, this is the conversation input the keeper receives
     every cycle and which the durable checkpoint keeps. [None] inherits. *)
  autonomous_wake_prompt : string option;
  active_goal_ids : string list option;
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
    autoboot_enabled = None;
    mention_targets = [];
    proactive_enabled = None;
    allowed_paths = None;
    sandbox_profile = None;
    sandbox_image = None;
    network_mode = None;
    multimodal_policy = None;
    autonomous_wake_prompt = None;
    active_goal_ids = None;
    max_context_override = None;
    telemetry_feedback_enabled = None;
    telemetry_feedback_window_hours = None;
    always_allow = None;
    agent_core_env = [];
  }
;;

type sandbox_route_resolution =
  | Sandbox_route of
      { sandbox_profile : Keeper_types_profile_sandbox.sandbox_profile
      ; network_mode : Keeper_types_profile_sandbox.network_mode
      }
  | Sandbox_profile_missing of { manifest_path : string }

let resolve_sandbox_route
      ~fallback_sandbox_profile
      ~fallback_network_mode
      defaults
  =
  match defaults.sandbox_profile, defaults.manifest_path with
  | None, Some manifest_path -> Sandbox_profile_missing { manifest_path }
  | sandbox_profile, manifest_path ->
    let sandbox_profile =
      Option.value sandbox_profile ~default:fallback_sandbox_profile
    in
    let network_default =
      match manifest_path with
      | Some _ ->
        Keeper_types_profile_sandbox.default_network_mode_for_profile
          sandbox_profile
      | None -> fallback_network_mode
    in
    let network_mode =
      Option.value defaults.network_mode ~default:network_default
    in
    Sandbox_route { sandbox_profile; network_mode }
;;
