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
                 (Pool_work.cpu ~name:__FUNCTION__ (fun () ->
                   Eio.Promise.resolve start ();
                   Eio.Promise.await release;
                   Eio.Promise.resolve finish ();
                   `String "fresh"))
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
          (Pool_work.cpu ~name:__FUNCTION__ (fun () -> `String "computed")))
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
          (Pool_work.cpu ~name:__FUNCTION__ (fun () -> `String "fresh")))
    in
    check lanes "the inline refresh entered the pool as a read" (1, 0) (entered_since before))
;;

(* RFC-0474 L4b. The cache submits a compute once, with the weight of the
   kind the caller declared. On the one worker, two I/O computes run side by
   side while they wait, and two CPU computes take turns. Each compute holds
   until the test releases it, so a compute the worker did not admit beside
   the other cannot start before then. Every wait is bounded, so a failure
   reports instead of hanging. *)

let wait_bound_s = 5.0

let within ~clock what f =
  match Eio.Time.with_timeout clock wait_bound_s (fun () -> Ok (f ())) with
  | Ok value -> value
  | Error `Timeout -> fail what
;;

(* What a held compute saw when it started: the weight its lane had in flight,
   its own included, and how many held computes had already returned. *)
type start =
  { in_flight : int
  ; returned_before : int
  }

type held =
  { work : Yojson.Safe.t Pool_work.t
  ; started : start Eio.Promise.t
  ; returned : unit Eio.Promise.t
  ; release : unit -> unit
  }

let held ~declare ~lane ~returned_count value =
  let started, start = Eio.Promise.create () in
  let released, release = Eio.Promise.create () in
  let returned, return = Eio.Promise.create () in
  let work =
    declare (fun () ->
      Eio.Promise.resolve start
        { in_flight = Pool_wait.in_flight lane; returned_before = Atomic.get returned_count };
      Eio.Promise.await released;
      Atomic.incr returned_count;
      Eio.Promise.resolve return ();
      value)
  in
  { work; started; returned; release = (fun () -> ignore (Eio.Promise.try_resolve release ())) }
;;

let release_all helds () = List.iter (fun h -> h.release ()) helds

(* A miss read in its own fiber: the reader waits for the compute. *)
let read_in_fiber ~sw key h =
  Eio.Fiber.fork_promise ~sw (fun () ->
    Pool_lane.with_read (fun () -> Dashboard_cache.get_or_compute key ~ttl:60. h.work))
;;

let test_two_io_computes_share_the_one_worker () =
  with_pool (fun ~clock ->
    let returned_count = Atomic.make 0 in
    let a = held ~declare:(Pool_work.io ~name:__FUNCTION__) ~lane:Pool_lane.Read ~returned_count (`String "a") in
    let b = held ~declare:(Pool_work.io ~name:__FUNCTION__) ~lane:Pool_lane.Read ~returned_count (`String "b") in
    Fun.protect ~finally:(release_all [ a; b ]) (fun () ->
      Eio.Switch.run (fun sw ->
        let served_a = read_in_fiber ~sw "l4b-io-a" a in
        let served_b = read_in_fiber ~sw "l4b-io-b" b in
        let start_a, start_b =
          within ~clock "an I/O compute waited for the other to return" (fun () ->
            Eio.Fiber.pair
              (fun () -> Eio.Promise.await a.started)
              (fun () -> Eio.Promise.await b.started))
        in
        check (pair int int) "both started before either returned" (0, 0)
          (start_a.returned_before, start_b.returned_before);
        release_all [ a; b ] ();
        let served =
          within ~clock "an I/O compute never returned" (fun () ->
            Eio.Promise.await_exn served_a, Eio.Promise.await_exn served_b)
        in
        check (pair json json) "each read is answered with its compute"
          (`String "a", `String "b") served)))
;;

let test_two_cpu_computes_take_turns_on_the_one_worker () =
  with_pool (fun ~clock ->
    let returned_count = Atomic.make 0 in
    let a = held ~declare:(Pool_work.cpu ~name:__FUNCTION__) ~lane:Pool_lane.Read ~returned_count (`String "a") in
    let b = held ~declare:(Pool_work.cpu ~name:__FUNCTION__) ~lane:Pool_lane.Read ~returned_count (`String "b") in
    Fun.protect ~finally:(release_all [ a; b ]) (fun () ->
      Eio.Switch.run (fun sw ->
        let served_a = read_in_fiber ~sw "l4b-cpu-a" a in
        let served_b = read_in_fiber ~sw "l4b-cpu-b" b in
        let first, second =
          within ~clock "no CPU compute started" (fun () ->
            Eio.Fiber.first
              (fun () -> ignore (Eio.Promise.await a.started); a, b)
              (fun () -> ignore (Eio.Promise.await b.started); b, a))
        in
        check bool "the other waits while the first holds the worker" false
          (Eio.Promise.is_resolved second.started);
        first.release ();
        let first_start = Eio.Promise.await first.started in
        let second_start =
          within ~clock "the second CPU compute never started" (fun () ->
            Eio.Promise.await second.started)
        in
        check int "the second started after the first returned" 1
          second_start.returned_before;
        check int "each ran with nothing else in flight on its lane"
          first_start.in_flight second_start.in_flight;
        second.release ();
        let served =
          within ~clock "a CPU compute never returned" (fun () ->
            Eio.Promise.await_exn served_a, Eio.Promise.await_exn served_b)
        in
        check (pair json json) "each read is answered with its compute"
          (`String "a", `String "b") served)))
;;

(* A stale hit answers at once and refreshes in a background fiber; the
   declared kind reaches that submit too. *)
let test_two_io_refreshes_share_the_one_worker () =
  with_pool (fun ~clock ->
    let returned_count = Atomic.make 0 in
    let a = held ~declare:(Pool_work.io ~name:__FUNCTION__) ~lane:Pool_lane.Background ~returned_count (`String "a") in
    let b = held ~declare:(Pool_work.io ~name:__FUNCTION__) ~lane:Pool_lane.Background ~returned_count (`String "b") in
    Fun.protect ~finally:(release_all [ a; b ]) (fun () ->
      let read key h =
        Dashboard_cache.seed_stale_if_missing key ~stale_for:60. (`String "stale");
        Pool_lane.with_read (fun () -> Dashboard_cache.get_or_compute key ~ttl:60. h.work)
      in
      let served = read "l4b-refresh-a" a, read "l4b-refresh-b" b in
      check (pair json json) "both reads are answered with the stale value"
        (`String "stale", `String "stale") served;
      let start_a, start_b =
        within ~clock "an I/O refresh waited for the other to return" (fun () ->
          Eio.Fiber.pair
            (fun () -> Eio.Promise.await a.started)
            (fun () -> Eio.Promise.await b.started))
      in
      check (pair int int) "both refreshes started before either returned" (0, 0)
        (start_a.returned_before, start_b.returned_before);
      release_all [ a; b ] ();
      within ~clock "an I/O refresh never returned" (fun () ->
        Eio.Fiber.both
          (fun () -> Eio.Promise.await a.returned)
          (fun () -> Eio.Promise.await b.returned))))
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
    ; ( "rfc-0474 l4b"
      , [ test_case "two I/O computes share the one worker" `Quick
            test_two_io_computes_share_the_one_worker
        ; test_case "two CPU computes take turns on the one worker" `Quick
            test_two_cpu_computes_take_turns_on_the_one_worker
        ; test_case "two I/O refreshes share the one worker" `Quick
            test_two_io_refreshes_share_the_one_worker
        ] )
    ]
;;
