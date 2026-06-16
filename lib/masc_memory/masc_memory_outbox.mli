open Masc_memory_types

type t

val create : env_fs:Eio.Fs.dir Eio.Path.t -> db_path:string -> t
val enqueue : t -> memory_row -> (unit, string) result
val process_queue : 
  t -> 
  write_pgvector:(memory_row -> (unit, string) result) -> 
  write_neo4j:(memory_row -> (unit, string) result) -> 
  unit
