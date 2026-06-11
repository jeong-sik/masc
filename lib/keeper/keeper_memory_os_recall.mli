(** Keeper_memory_os_recall — render bounded advisory context from Memory OS files.

    Recall is intentionally one-way at prompt time: it reads persisted facts
    and episodes, sanitizes them, and returns an advisory block suitable for
    OAS [extra_system_context]. *)

val render_context
  :  keeper_id:string
  -> now:float
  -> ?max_facts:int
  -> ?max_episodes:int
  -> unit
  -> string
