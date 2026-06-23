(** Keeper profile default records and derived OAS context. *)

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
  telemetry_feedback_enabled : bool option;
  telemetry_feedback_window_hours : int option;
  per_provider_timeout_state : per_provider_timeout_state;
  per_provider_timeout : float option;
  always_approve : bool option;
  (* No per-keeper [model]/[runtime_id] field: keeper→runtime assignment lives
     solely in runtime.toml [[runtime.assignments]] (persona⊥{model,runtime}). *)
  max_turns_per_call : int option;
  max_turns_per_call_scheduled_autonomous : int option;
  oas_env : (string * string) list;
  unknown_toml_keys : string list;
}

val empty_keeper_profile_defaults : keeper_profile_defaults
