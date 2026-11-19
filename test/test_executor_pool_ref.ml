open Alcotest

(* A job submitted through [Executor_pool_ref] runs on the heap its pool's
   domain started with. The caller tunes its own domain first, so a job that
   resized its worker on entry, as the server's heap, would show 4M words on
   a pool started on the plain policy. *)
let test_job_keeps_the_heap_its_domain_started_with () =
  let runtime_words =
    Domain.join (Domain.spawn (fun () -> (Gc.get ()).Gc.minor_heap_size))
  in
  Minor_heap.apply Minor_heap.Tuned;
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let pool =
        Eio.Executor_pool.create ~sw ~domain_count:1
          (Minor_heap.domain_mgr Minor_heap.Runtime_default (Eio.Stdenv.domain_mgr env))
      in
      let main_domain = (Domain.self () :> int) in
      let where, words =
        Executor_pool_ref.For_testing.with_pool pool (fun () ->
          Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
            (Domain.self () :> int), (Gc.get ()).Gc.minor_heap_size))
      in
      check bool "the job ran off the main domain" true (where <> main_domain);
      check int "the job ran on the runtime heap" runtime_words words))
;;

let () =
  run "Executor pool reference"
    [ ( "worker entry"
      , [ test_case "a submitted job keeps its domain's heap" `Quick
            test_job_keeps_the_heap_its_domain_started_with
        ] )
    ]
;;
