open Alcotest

let tuned_words = 4 * 1024 * 1024

(* A job submitted through [Executor_pool_ref] is pool work like one through
   [Domain_pool]: it runs on a domain with the tuned minor heap. A fresh
   one-domain pool has had no other job, so nothing else tuned that domain. *)
let test_job_runs_on_the_tuned_minor_heap () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let pool =
        Eio.Executor_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env)
      in
      let main_domain = (Domain.self () :> int) in
      let where, words =
        Executor_pool_ref.For_testing.with_pool pool (fun () ->
          Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
            (Domain.self () :> int), (Gc.get ()).Gc.minor_heap_size))
      in
      check bool "the job ran off the main domain" true (where <> main_domain);
      check bool
        (Printf.sprintf "the worker's minor heap is the tuned size, got %d words" words)
        true
        (words >= tuned_words)))
;;

let () =
  run "Executor pool reference"
    [ ( "worker entry"
      , [ test_case "a submitted job runs on the tuned minor heap" `Quick
            test_job_runs_on_the_tuned_minor_heap
        ] )
    ]
;;
