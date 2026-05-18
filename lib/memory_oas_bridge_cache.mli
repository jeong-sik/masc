(** File-stamp caches for {!Memory_oas_bridge}. *)

module SMap : Map.S with type key = string

val cached_recent_episodes : limit:int -> Institution_eio.episode list
val persisted_episode_ids : unit -> unit SMap.t
val note_episode_flush : Institution_eio.episode -> unit

val load_procedures_cached
  :  agent_name:string
  -> Procedural_memory.procedure list

val store_procedures_cache
  :  agent_name:string
  -> Procedural_memory.procedure list
  -> unit

val top_procedures_cached
  :  agent_name:string
  -> limit:int
  -> Procedural_memory.procedure list
