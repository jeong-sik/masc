open Alcotest

(* RFC-0204 §5.1. Each pool has one worker; the background worker is held
   for the whole test, so a read that went to the background pool could never
   start. *)

let domain () = (Domain.self () :> int)

(* The domain of a one-domain pool's only worker, learned before it is held. *)
let worker_domain pool = Domain_pool.submit_cpu ~name:__FUNCTION__ pool domain

let with_pools f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let dm = Eio.Stdenv.domain_mgr env in
      let background = Domain_pool.create ~sw ~domain_count:1 dm in
      let read = Domain_pool.create ~sw ~domain_count:1 dm in
      let read_domain = worker_domain read in
      Domain_pool_ref.set background;
      Domain_pool_ref.set_read read;
      Fun.protect ~finally:Domain_pool_ref.clear_for_tests (fun () ->
        Executor_pool_ref.For_testing.with_pool (Domain_pool.executor_pool background) (fun () ->
          Executor_pool_ref.For_testing.with_read_pool (Domain_pool.executor_pool read) (fun () ->
            f env sw background read_domain)))))
;;

(* Hold the background pool's only worker and learn its domain. *)
let occupy_background sw background =
  let occupied, occupy = Eio.Promise.create () in
  let release, release_worker = Eio.Promise.create () in
  let blocker =
    Eio.Executor_pool.submit_fork ~sw (Domain_pool.executor_pool background) ~weight:1.0
      (fun () ->
        Eio.Promise.resolve occupy (domain ());
        Eio.Promise.await release)
  in
  let background_domain = Eio.Promise.await occupied in
  background_domain, fun () ->
    Eio.Promise.resolve release_worker ();
    ignore (Eio.Promise.await_exn blocker)
;;

(* The read starts while the background worker is held. The timeout only
   ends the old behaviour, where the read waits behind the held worker; it
   fails after 10 s instead of hanging. *)
let starts_beside_held_background env submit =
  match
    Eio.Time.with_timeout (Eio.Stdenv.clock env) 10.0 (fun () ->
      Ok (Pool_lane.with_read (fun () -> submit domain)))
  with
  | Ok where -> Some where
  | Error `Timeout -> None
;;

let test_a_read_starts_while_the_background_pool_is_full () =
  with_pools (fun env sw background read_domain ->
    let _background_domain, release = occupy_background sw background in
    Fun.protect ~finally:release (fun () ->
      let check_submit name submit =
        match starts_beside_held_background env submit with
        | None -> fail (name ^ ": the read waited behind the held background worker")
        | Some where -> check int (name ^ ": the read ran on the read pool") read_domain where
      in
      check_submit "Executor_pool_ref.submit_or_inline" (fun f -> Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ f);
      check_submit "Domain_pool_ref.submit_io_or_inline" (Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__);
      check_submit "Domain_pool_ref.submit_cpu_or_inline" (Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__);
      check_submit "Executor_pool_ref.submit_strict" (fun f ->
        match Executor_pool_ref.submit_strict ~name:__FUNCTION__ f with
        | Ok where -> where
        | Error error -> fail (Executor_pool_ref.strict_submit_error_to_string error))))
;;

(* Background work keeps the background pool, and a read's nested submit
   runs inline on the read worker instead of queueing again. *)
let test_background_work_and_nested_reads_stay_put () =
  with_pools (fun _env _sw background read_domain ->
    let background_domain = worker_domain background in
    check int "Executor_pool_ref background work runs on the shared pool" background_domain
      (Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ domain);
    check int "Domain_pool_ref background work runs on the shared pool" background_domain
      (Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ domain);
    check int "a read runs on the read pool" read_domain
      (Pool_lane.with_read (fun () -> Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ domain));
    let background_job = Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ domain in
    let read_job, nested =
      Pool_lane.with_read (fun () ->
        Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ (fun () ->
          domain (), Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ domain))
    in
    check bool "background and read jobs ran on different domains" true
      (background_job <> read_job);
    check int "a read's nested submit stays on its domain" read_job nested)
;;

let test_without_a_read_pool_reads_use_the_shared_pool () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let shared = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
      Domain_pool_ref.clear_for_tests ();
      Domain_pool_ref.set shared;
      Fun.protect ~finally:Domain_pool_ref.clear_for_tests (fun () ->
        let caller = domain () in
        let where = Pool_lane.with_read (fun () -> Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ domain) in
        check bool "the read still ran on a pool domain" true (where <> caller))))
;;

let () =
  run "Read pool"
    [ ( "isolation"
      , [ test_case "a read starts while the background pool is full" `Quick
            test_a_read_starts_while_the_background_pool_is_full
        ; test_case "background work and nested reads stay put" `Quick
            test_background_work_and_nested_reads_stay_put
        ; test_case "without a read pool reads use the shared pool" `Quick
            test_without_a_read_pool_reads_use_the_shared_pool
        ] )
    ]
;;
