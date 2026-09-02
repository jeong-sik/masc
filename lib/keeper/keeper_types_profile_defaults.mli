(** Keeper profile default records and derived AGENT_CORE context. *)

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
  remote_endpoint : string option;
  max_context_override : int option;
  telemetry_feedback_enabled : bool option;
  telemetry_feedback_window_hours : int option;
  always_allow : bool option;
  (* RFC-0390: how much of an official client's built-in tool surface this
     keeper may use. [None] keeps each runtime's own default posture. *)
  native_tool_posture : Runtime_native_tools.posture option;
  (* Which Claude Code settings layers the CLI may load. [None] keeps the
     no-layer default; a non-empty list is admitted only for Yolo keepers
     (a loaded layer can carry skills/hooks that execute outside the MASC
     approval gate). *)
  (** Profile-only Keeper Skill selection. [None] exposes all names; [Some []]
      exposes none. Names use exact equality against canonical Skill names. *)
  skill_names : string list option;
  attached_tool_allow : string list option;
      (** RFC-0403. Which of the attached services' tools this keeper takes.
          [None] is the whole offering, which is what a keeper got before
          this field existed; [Some []] is none of them. Attached tools
          only -- built-in tools choose through [defer_loading]. *)
  (* Keeper runtime assignment lives in runtime.toml [[runtime.assignments]]. *)
  agent_core_env : (string * string) list;
}

val empty_keeper_profile_defaults : keeper_profile_defaults
