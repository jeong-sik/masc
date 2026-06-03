(** Tool_tag_types — neutral classification variants for the Tool substrate.

    Zero-dependency leaf module. Holds the two pure nullary sums that the
    domain side ([Tool_name.Domain_tool]) attaches to each tool and that the
    substrate ([Tool_dispatch], [Tool_catalog_inference]) consumes:

    - [module_tag]: dispatch routing tag.
    - [effect_domain]: inferred effect classification.

    PR-S2 (tool⊥domain cut): these types live below [Tool_name] so the domain
    submodules can produce them. [Tool_dispatch] and [Tool_catalog_inference]
    re-export them by type-equality, keeping their public contracts and all
    [Tool_dispatch.Mod_*] / [Tool_catalog.<effect_domain>] call sites
    byte-identical. *)

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
  | Mod_misc
  | Mod_library
  | Mod_external
  | Mod_inline
  | Mod_shard

type effect_domain =
  | Read_only
  | Masc_workspace
  | Playground_write
  | Host_repo_write
