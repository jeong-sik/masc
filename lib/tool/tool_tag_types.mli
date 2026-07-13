(** Tool_tag_types — neutral dispatch tags for the Tool substrate.

    Constructors are exposed because [Tool_dispatch] re-exports this type by
    equality. Effect and product classifications intentionally do not live in
    this generic leaf. *)

(** Dispatch routing tag attached to each tool name. *)
type module_tag =
  | Mod_plan
  | Mod_operator
  | Mod_local_runtime
  | Mod_run
  | Mod_compact
  | Mod_agent
  | Mod_task
  | Mod_state
  | Mod_control
  | Mod_agent_timeline
  | Mod_schedule
  | Mod_misc
  | Mod_library
  | Mod_recurring
  | Mod_external
  | Mod_inline
  | Mod_keeper_task
