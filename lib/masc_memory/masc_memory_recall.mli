open Masc_memory_types

type t

val create : 
  worker:Masc_domain_worker.t ->
  env_clock:float Eio.Time.clock_ty Eio.Resource.t ->
  supabase_client:unit ->
  neo4j_client:unit ->
  t

val pre_embed_speculative : t -> sw:Eio.Switch.t -> current_input_prefix:string -> unit
val recall : 
  t -> 
  query:string -> 
  max_results:int -> 
  (memory_row list, string) result
