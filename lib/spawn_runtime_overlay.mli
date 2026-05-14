(** Spawn runtime overlay.

    Spawnable CLI agent aliases and migration guards are MASC spawn runtime
    concerns. Keep them outside [Provider_adapter] so the provider registry can
    shrink toward LLM/provider capability projection only. *)

type binding =
  { canonical_name : string
  ; spawn_key : string
  ; aliases : string list
  }

val bindings : binding list
val resolve_spawn_key : string -> string option
val is_spawnable_agent : string -> bool
val spawnable_canonical_names : unit -> string list
val make_local_label : string -> string
val add_default_model_arg : agent_name:string -> string list -> string list
val bare_ollama_migration_message : unit -> string
val is_bare_ollama_label : string -> bool
