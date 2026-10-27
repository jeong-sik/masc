open Alcotest

(* RFC-0204 §3.4. A cache compute is a read only while a request waits for
   it. The lane a submission carries is the one [Pool_wait] records it under,
   counted when a worker enters the job. *)

(* Without [root_switch] a stale hit cannot fork its refresh and computes it
   inline, so the reader waits for it. *)
let with_pool ?(root_switch = true) f =
  Eio_main.run (fun env ->
    Eio_guard.enable ();
    Eio.Switch.run (fun sw ->
      let clock = Eio.Stdenv.clock env in
      if root_switch then Eio_context.set_switch sw;
      let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
      Domain_pool_ref.set pool;
      Fun.protect
        ~finally:(fun () ->
          Domain_pool_ref.clear_for_tests ();
          Eio_context.For_testing.clear_root_switch ())
        (fun () ->
          Executor_pool_ref.For_testing.with_pool (Domain_pool.executor_pool pool) (fun () ->
            Dashboard_cache.invalidate_all ();
            f ~clock))))
;;

let json = testable (Fmt.of_to_string Yojson.Safe.to_string) Yojson.Safe.equal

(* Submissions a worker has entered, per lane, since the process started. *)
let entered () =
  let count lane =
    Yojson.Safe.Util.(
      Pool_wait.to_json ()
      |> member (Pool_lane.to_string lane)
      |> member "wait"
      |> member "count"
      |> to_int)
  in
  count Pool_lane.Read, count Pool_lane.Background
;;

let entered_since (read0, background0) =
  let read, background = entered () in
  read - read0, background - background0
;;

let lanes = pair int int

(* The reader answers with the stale value, so the refresh it forks is
   background work. The read stays open until the refresh has entered its
   worker, so the refresh takes its lane while the request is still being
   answered; the refresh then holds until the read has returned, so a refresh
   the read waited for would time the read out. *)
let test_a_stale_refresh_forked_by_a_read_is_background_work () =
  with_pool (fun ~clock ->
    let key = "swr-refresh-lane" in
    Dashboard_cache.seed_stale_if_missing key ~stale_for:60. (`String "stale");
    let before = entered () in
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
                   Eio.Promise.resolve start ();
                   Eio.Promise.await release;
                   Eio.Promise.resolve finish ();
                   `String "fresh")
             in
             Eio.Promise.await started;
             served)))
    in
    Eio.Promise.resolve release_refresh ();
    match answer with
    | Error `Timeout -> fail "the read waited for the refresh it forked"
    | Ok served ->
      Eio.Time.with_timeout_exn clock 5. (fun () -> Eio.Promise.await finished);
      check json "the read is answered with the stale value" (`String "stale") served;
      check lanes "the refresh entered the pool as background work" (0, 1)
        (entered_since before))
;;

(* With nothing cached the reader waits for its own compute: still a read. *)
let test_a_compute_a_read_waits_for_is_a_read () =
  with_pool (fun ~clock ->
    let before = entered () in
    let served =
      Pool_lane.with_read (fun () ->
        Dashboard_cache.get_or_compute_with_timeout "miss-lane" ~ttl:60. ~clock ~timeout_sec:5.
          (fun () -> `String "computed"))
    in
    check json "the read is answered with its compute" (`String "computed") served;
    check lanes "the compute entered the pool as a read" (1, 0) (entered_since before))
;;

(* Without a root switch the stale hit refreshes inline, before it answers:
   the read waits for that refresh, so it stays a read. *)
let test_an_inline_refresh_the_read_waits_for_is_a_read () =
  with_pool ~root_switch:false (fun ~clock ->
    let key = "swr-inline-lane" in
    Dashboard_cache.seed_stale_if_missing key ~stale_for:60. (`String "stale");
    let before = entered () in
    let _served =
      Pool_lane.with_read (fun () ->
        Dashboard_cache.get_or_compute_with_timeout key ~ttl:60. ~clock ~timeout_sec:5.
          (fun () -> `String "fresh"))
    in
    check lanes "the inline refresh entered the pool as a read" (1, 0) (entered_since before))
;;

let () =
  run "Dashboard_cache lane"
    [ ( "rfc-0204 3.4"
      , [ test_case "a stale refresh forked by a read is background work" `Quick
            test_a_stale_refresh_forked_by_a_read_is_background_work
        ; test_case "a compute a read waits for is a read" `Quick
            test_a_compute_a_read_waits_for_is_a_read
        ; test_case "an inline refresh the read waits for is a read" `Quick
            test_an_inline_refresh_the_read_waits_for_is_a_read
        ] )
    ]
;;
