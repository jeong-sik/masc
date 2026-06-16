type t

val create : domain_mgr:Eio.Domain_manager.ty Eio.Domain_manager.t -> t
val run_cpu_intensive : t -> (unit -> 'a) -> 'a
val compute_local_embedding : t -> text:string -> float array
