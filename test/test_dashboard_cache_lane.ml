open Alcotest

(* RFC-0204 §3.4. The server's two pools, one domain each: a cache compute
   runs on the read pool only while a request waits for it. *)

let domain () = (Domain.self () :> int)

(* Without [root_switch] a stale hit cannot fork its refresh and computes it
   inline, so the reader waits for it. *)
let with_pools ?(root_switch = true) f =
  Eio_main.run (fun env ->
    Eio_guard.enable ();
    Eio.Switch.run (fun sw ->
      let clock = Eio.Stdenv.clock env in
      let dm = Eio.Stdenv.domain_mgr env in
      if root_switch then Eio_context.set_switch sw;
      let background = Domain_pool.create ~sw ~domain_count:1 dm in
      let read = Domain_pool.create ~sw ~domain_count:1 dm in
      let background_domain = Domain_pool.submit_cpu background domain in
      let read_domain = Domain_pool.submit_cpu read domain in
      Domain_pool_ref.set background;
      Domain_pool_ref.set_read read;
      Fun.protect
        ~finally:(fun () ->
          Domain_pool_ref.clear_for_tests ();
          Eio_context.For_testing.clear_root_switch ())
        (fun () ->
          Executor_pool_ref.For_testing.with_pool (Domain_pool.executor_pool background) (fun () ->
            Executor_pool_ref.For_testing.with_read_pool (Domain_pool.executor_pool read) (fun () ->
              Dashboard_cache.invalidate_all ();
              f ~clock ~background_domain ~read_domain)))))
;;

let json = testable (Fmt.of_to_string Yojson.Safe.to_string) Yojson.Safe.equal

(* The reader answers with the stale value, so the refresh it forks is
   background work. The read stays open until the refresh has started, so the
   refresh picks its pool while the request is still being answered; the
   refresh then holds until the read has returned, so a refresh the read waited
   for would time the read out. *)
let test_a_stale_refresh_forked_by_a_read_runs_on_the_shared_pool () =
  with_pools (fun ~clock ~background_domain ~read_domain:_ ->
    let key = "swr-refresh-lane" in
    Dashboard_cache.seed_stale_if_missing key ~stale_for:60. (`String "stale");
    let started, start = Eio.Promise.create () in
    let release, release_refresh = Eio.Promise.create () in
    let finished, finish = Eio.Promise.create () in
    let answer =
      Eio.Time.with_timeout clock 5. (fun () ->
        Ok
          (Pool_lane.with_read (fun () ->
             let served =
               Dashboard_cache.get_or_compute_with_timeout key ~ttl:60. ~clock ~timeout_sec:5.
                 (fun () ->
                   Eio.Promise.resolve start (domain ());
                   Eio.Promise.await release;
                   Eio.Promise.resolve finish ();
                   `String "fresh")
             in
             served, Eio.Promise.await started)))
    in
    Eio.Promise.resolve release_refresh ();
    match answer with
    | Error `Timeout -> fail "the read waited for the refresh it forked"
    | Ok (served, refresh_domain) ->
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await finished);
      check json "the read is answered with the stale value" (`String "stale") served;
      check int "the refresh ran on the shared pool" background_domain refresh_domain)
;;

(* With nothing cached the reader waits for its own compute: still a read. *)
let test_a_compute_a_read_waits_for_runs_on_the_read_pool () =
  with_pools (fun ~clock ~background_domain:_ ~read_domain ->
    let computed_on = ref None in
    let served =
      Pool_lane.with_read (fun () ->
        Dashboard_cache.get_or_compute_with_timeout "miss-lane" ~ttl:60. ~clock ~timeout_sec:5.
          (fun () ->
            computed_on := Some (domain ());
            `String "computed"))
    in
    check json "the read is answered with its compute" (`String "computed") served;
    check (option int) "the compute ran on the read pool" (Some read_domain) !computed_on)
;;

(* Without a root switch the stale hit refreshes inline, before it answers:
   the read waits for that refresh, so it stays a read. *)
let test_an_inline_refresh_the_read_waits_for_runs_on_the_read_pool () =
  with_pools ~root_switch:false (fun ~clock ~background_domain:_ ~read_domain ->
    let key = "swr-inline-lane" in
    Dashboard_cache.seed_stale_if_missing key ~stale_for:60. (`String "stale");
    let refreshed_on = ref None in
    let _served =
      Pool_lane.with_read (fun () ->
        Dashboard_cache.get_or_compute_with_timeout key ~ttl:60. ~clock ~timeout_sec:5.
          (fun () ->
            refreshed_on := Some (domain ());
            `String "fresh"))
    in
    check (option int) "the inline refresh ran on the read pool" (Some read_domain) !refreshed_on)
;;

let () =
  run "Dashboard_cache lane"
    [ ( "rfc-0204 3.4"
      , [ test_case "a stale refresh forked by a read runs on the shared pool" `Quick
            test_a_stale_refresh_forked_by_a_read_runs_on_the_shared_pool
        ; test_case "a compute a read waits for runs on the read pool" `Quick
            test_a_compute_a_read_waits_for_runs_on_the_read_pool
        ; test_case "an inline refresh the read waits for runs on the read pool" `Quick
            test_an_inline_refresh_the_read_waits_for_runs_on_the_read_pool
        ] )
    ]
;;
