(** Tool_tag_types — neutral dispatch tags for the Tool substrate.

    This zero-dependency leaf owns only [module_tag]. Tool effects and product
    semantics belong to their concrete execution boundary, not the generic
    dispatch substrate. *)

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
  | Mod_external
  | Mod_inline
  | Mod_keeper_task
