type keeper_profile_defaults = {
  id : Ids.Keeper_id.t option;
  manifest_path : string option;
  instructions : string option;
  autoboot_enabled : bool option;
  mention_targets : string list;
  proactive_enabled : bool option;
  sandbox_profile : Keeper_types_profile_sandbox.sandbox_profile option;
  sandbox_image : string option;
  network_mode : Keeper_types_profile_sandbox.network_mode option;
  (* Phase 1 SSH lane: name of the [exec.ssh.endpoints.<name>] registry
     entry a [Remote_ssh] keeper dispatches through. Required when
     [sandbox_profile] is [Remote_ssh] — enforced at meta validation with
     [remote_ssh_endpoint_missing]; the registry itself arrives with
     Phase 1 task 2. *)
  remote_endpoint : string option;
  microvm_backend : Keeper_microvm_backend.t option;
  max_context_override : int option;
  (* Telemetry Feedback — inject behavioral stats into keeper context *)
  telemetry_feedback_enabled : bool option;
  telemetry_feedback_window_hours : int option;
  always_allow : bool option;
  (* RFC-0390: how much of an official client's built-in tool surface this
     keeper may use. [None] keeps each runtime's own default posture. *)
  native_tool_posture : Runtime_native_tools.posture option;
  (* Profile-only Skill selection; explicit empty is distinct from absence. *)
  skill_names : string list option;
  (* RFC-0403: which of the attached services' tools this keeper takes.
     [None] is every tool the attached providers offer, which is what a
     keeper got before this field existed. Attached tools only: built-in
     tools already choose through [defer_loading], and two axes over one
     tool would leave no way to read which one held it back. *)
  attached_tool_allow : string list option;
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
    sandbox_profile = None;
    sandbox_image = None;
    network_mode = None;
    remote_endpoint = None;
    microvm_backend = None;
    max_context_override = None;
    telemetry_feedback_enabled = None;
    telemetry_feedback_window_hours = None;
    always_allow = None;
    native_tool_posture = None;
    skill_names = None;
    attached_tool_allow = None;
    agent_core_env = [];
  }
;;
