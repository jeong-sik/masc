(** Tool_tag_types — neutral classification variants for the Tool substrate.

    Zero-dependency leaf module. Holds the two pure nullary sums that the
    substrate ([Tool_dispatch], [Tool_catalog_inference]) consumes.

    Constructors are exposed (not abstract): [Tool_dispatch] and
    [Tool_catalog_inference] re-export these types by type-equality, so the
    [Tool_dispatch.Mod_*] / [Tool_catalog.<effect_domain>] call sites must keep
    seeing the constructors. Hiding them would break the re-export contract. *)

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
  | Mod_agent_timeline
  | Mod_schedule
  | Mod_misc
  | Mod_library
  | Mod_recurring
  | Mod_external
  | Mod_inline
  | Mod_shard
  | Mod_keeper_task

(** Inferred effect classification for a tool. *)
type effect_domain =
  | Read_only
  | Masc_workspace
  | Playground_write
  | Host_repo_write
