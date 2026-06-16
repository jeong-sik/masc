open Masc_memory_types

type t

val create : 
  outbox:Masc_memory_outbox.t -> 
  recall:Masc_memory_recall.t ->
  env_fs:Eio.Fs.dir_ty Eio.Path.t ->
  t

val generate_consolidation_proposals : 
  t -> 
  llm_client:unit -> 
  (consolidation_proposal list, string) result

val apply_approved_proposal : 
  t -> 
  proposal_id:string -> 
  (unit, string) result
