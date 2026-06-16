open Masc_memory_types

type t

val create : env_fs:Eio.Fs.dir_ty Eio.Path.t -> env_clock:float Eio.Time.clock_ty Eio.Resource.t -> db_path:string -> t
val enqueue : t -> memory_row -> (unit, string) result
val process_queue : 
  t -> 
  write_pgvector:(memory_row -> (unit, string) result) -> 
  write_neo4j:(memory_row -> (unit, string) result) -> 
  unit

val recover_on_boot : 
  t -> 
  write_pgvector:(memory_row -> (unit, string) result) -> 
  write_neo4j:(memory_row -> (unit, string) result) -> 
  unit
