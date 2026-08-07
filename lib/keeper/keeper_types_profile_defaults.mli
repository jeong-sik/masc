(** Keeper profile default records and derived OAS context. *)

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
  telemetry_feedback_enabled : bool option;
  telemetry_feedback_window_hours : int option;
  always_allow : bool option;
  (* Keeper runtime assignment lives in runtime.toml [[runtime.assignments]]. *)
  oas_env : (string * string) list;
}

val empty_keeper_profile_defaults : keeper_profile_defaults
