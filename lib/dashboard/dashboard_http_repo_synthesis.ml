(** Dashboard HTTP repo synthesis benchmark — read-only benchmark run summary
    and detail for the repo-synthesis proof ladder. *)

let repo_synthesis_benchmarks_json ~(base_path : string) ?(limit = 20) () =
  Repo_synthesis_benchmark.bench_summary_json ~base_path ~limit ()

let repo_synthesis_benchmark_detail_json ~(base_path : string) ~(run_id : string) =
  Repo_synthesis_benchmark.bench_detail_json ~base_path ~run_id
