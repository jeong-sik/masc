(** Dashboard HTTP repo synthesis benchmark endpoints. *)

val repo_synthesis_benchmarks_json :
  base_path:string -> ?limit:int -> unit -> Yojson.Safe.t

val repo_synthesis_benchmark_detail_json :
  base_path:string -> run_id:string -> (Yojson.Safe.t, string) result
