open Alcotest

let lane = testable (Fmt.of_to_string Pool_lane.to_string) ( = )

let test_unmarked_is_background () =
  check lane "outside Eio" Pool_lane.Background (Pool_lane.current ());
  Eio_main.run (fun _env ->
    check lane "an unmarked fiber" Pool_lane.Background (Pool_lane.current ()))
;;

(* A fiber forked during a read sees [Read] while the read is answered and
   [Background] once [with_read] has returned, also when it raised. *)
let lanes_of_a_fiber_that_outlives_its_read ~raise_in_read =
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let during = ref Pool_lane.Background in
      let after = ref Pool_lane.Read in
      let release, resolve_release = Eio.Promise.create () in
      let forked_done, resolve_forked_done = Eio.Promise.create () in
      let inside = ref Pool_lane.Background in
      (try
         Pool_lane.with_read (fun () ->
           inside := Pool_lane.current ();
           Eio.Fiber.fork ~sw (fun () ->
             during := Pool_lane.current ();
             Eio.Promise.await release;
             after := Pool_lane.current ();
             Eio.Promise.resolve resolve_forked_done ());
           if raise_in_read then failwith "handler failed")
       with
       | Failure _ -> ());
      check lane "after with_read in its own fiber" Pool_lane.Background (Pool_lane.current ());
      Eio.Promise.resolve resolve_release ();
      Eio.Promise.await forked_done;
      !inside, !during, !after))
;;

let test_read_ends_for_every_fiber () =
  List.iter
    (fun raise_in_read ->
      let label = if raise_in_read then " (read raised)" else "" in
      let inside, during, after = lanes_of_a_fiber_that_outlives_its_read ~raise_in_read in
      check lane ("inside with_read" ^ label) Pool_lane.Read inside;
      check lane ("forked during the read" ^ label) Pool_lane.Read during;
      check lane ("the same fiber after the read" ^ label) Pool_lane.Background after)
    [ false; true ]
;;

(* A fiber forked under [with_background] inside a read is background work;
   the read and its other fibers keep [Read]. Outside Eio it runs [f]. *)
let test_with_background_unmarks_inside_a_read () =
  check int "outside Eio" 1 (Pool_lane.with_background (fun () -> 1));
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let forked = ref Pool_lane.Read in
      let sibling = ref Pool_lane.Background in
      let under, after =
        Pool_lane.with_read (fun () ->
          let under = Pool_lane.with_background Pool_lane.current in
          Pool_lane.with_background (fun () ->
            Eio.Fiber.fork ~sw (fun () -> forked := Pool_lane.current ()));
          Eio.Fiber.fork ~sw (fun () -> sibling := Pool_lane.current ());
          under, Pool_lane.current ())
      in
      check lane "under with_background" Pool_lane.Background under;
      check lane "a fiber forked under with_background" Pool_lane.Background !forked;
      check lane "a sibling forked outside it" Pool_lane.Read !sibling;
      check lane "the read after with_background returns" Pool_lane.Read after))
;;

let with_pool f =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let pool =
        Eio.Executor_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env)
      in
      Executor_pool_ref.For_testing.with_pool pool (fun () -> f env sw pool)))
;;

let test_pool_job_does_not_inherit_the_lane () =
  with_pool (fun _env _sw _pool ->
    let in_job =
      Pool_lane.with_read (fun () -> Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ Pool_lane.current)
    in
    check lane "a pool job submitted during a read" Pool_lane.Background in_job)
;;

let member path json =
  List.fold_left (fun json key -> Yojson.Safe.Util.member key json) json path
;;

let wait_counts lane_name =
  let json = Pool_wait.to_json () in
  let h = member [ lane_name; "wait" ] json in
  ( Yojson.Safe.Util.to_int (member [ "count" ] h)
  , List.map Yojson.Safe.Util.to_int (Yojson.Safe.Util.to_list (member [ "buckets" ] h)) )
;;

let bounds () =
  Pool_wait.to_json () |> member [ "bucket_upper_ms" ] |> Yojson.Safe.Util.to_list
  |> List.map Yojson.Safe.Util.to_number
;;

let diff after before = List.map2 ( - ) after before

let test_wait_is_recorded_under_the_submitting_lane () =
  with_pool (fun _env _sw _pool ->
    let read_before, _ = wait_counts "read" in
    let background_before, _ = wait_counts "background" in
    Pool_lane.with_read (fun () -> Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ ignore);
    let read_after, _ = wait_counts "read" in
    let background_after, _ = wait_counts "background" in
    check int "one read submission" 1 (read_after - read_before);
    check int "no background submission" 0 (background_after - background_before);
    Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ ignore;
    let background_last, _ = wait_counts "background" in
    check int "one background submission" 1 (background_last - background_after))
;;

let counts lane_name kind =
  let h = member [ lane_name; kind ] (Pool_wait.to_json ()) in
  ( Yojson.Safe.Util.to_int (member [ "count" ] h)
  , List.map Yojson.Safe.Util.to_int (Yojson.Safe.Util.to_list (member [ "buckets" ] h)) )
;;

let occupy_the_only_worker sw pool =
  let occupied, occupy = Eio.Promise.create () in
  let release, release_worker = Eio.Promise.create () in
  let blocker =
    Eio.Executor_pool.submit_fork ~sw pool ~weight:1.0 (fun () ->
      Eio.Promise.resolve occupy ();
      Eio.Promise.await release)
  in
  Eio.Promise.await occupied;
  fun () ->
    Eio.Promise.resolve release_worker ();
    ignore (Eio.Promise.await_exn blocker)
;;

(* The only worker is held until 30 ms after the submission, so the job waited
   at least 30 ms by construction: its observation lands above every bucket
   bound below 30 ms. *)
let test_a_queued_wait_lands_above_its_lower_buckets () =
  with_pool (fun env sw pool ->
    let release = occupy_the_only_worker sw pool in
    let _, before = counts "read" "wait" in
    Eio.Fiber.both
      (fun () -> Pool_lane.with_read (fun () -> Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ ignore))
      (fun () ->
        Eio.Time.sleep (Eio.Stdenv.clock env) 0.03;
        release ());
    let _, after = counts "read" "wait" in
    let added = diff after before in
    check int "one observation" 1 (List.fold_left ( + ) 0 added);
    List.iteri
      (fun i n ->
        match List.nth_opt (bounds ()) i with
        | Some upper when upper < 30. ->
          check int (Printf.sprintf "nothing at or below %g ms" upper) 0 n
        | Some _ | None -> ())
      added)
;;

let test_run_is_recorded_under_the_submitting_lane () =
  with_pool (fun _env _sw _pool ->
    let before, _ = counts "read" "run" in
    Pool_lane.with_read (fun () -> Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ ignore);
    let after, _ = counts "read" "run" in
    check int "one read run" 1 (after - before))
;;

(* A read that gave up while queued is counted as abandoned, not as a wait. *)
let test_a_cancelled_queued_submission_is_abandoned () =
  with_pool (fun env sw pool ->
    let release = occupy_the_only_worker sw pool in
    let waits_before, _ = counts "read" "wait" in
    let abandoned_before, _ = counts "read" "abandoned" in
    let ran = ref false in
    Eio.Fiber.first
      (fun () -> Pool_lane.with_read (fun () -> Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () -> ran := true)))
      (fun () -> Eio.Time.sleep (Eio.Stdenv.clock env) 0.03);
    release ();
    let waits_after, _ = counts "read" "wait" in
    let abandoned_after, _ = counts "read" "abandoned" in
    check bool "the cancelled job never ran" false !ran;
    check int "no wait recorded" 0 (waits_after - waits_before);
    check int "one abandoned submission" 1 (abandoned_after - abandoned_before))
;;

(* RFC-0474 L4a. *)
let in_flight_wait_counts lane_name =
  member [ lane_name; "wait_by_in_flight_workers" ] (Pool_wait.to_json ())
  |> Yojson.Safe.Util.to_list
  |> List.map (fun h -> Yojson.Safe.Util.to_int (member [ "count" ] h))
;;

let in_flight_workers lane_name =
  member [ lane_name; "in_flight_workers" ] (Pool_wait.to_json ()) |> Yojson.Safe.Util.to_number
;;

(* A read holds the only worker at the 1.0 default; the next read is
   submitted while it waits and is counted at one worker's weight in flight.
   The holder is released only after the next submission is queued. *)
let test_a_wait_is_counted_by_the_weight_in_flight () =
  with_pool (fun _env sw _pool ->
    let before = in_flight_wait_counts "read" in
    let started, start = Eio.Promise.create () in
    let release, release_holder = Eio.Promise.create () in
    let holder =
      Eio.Fiber.fork_promise ~sw (fun () ->
        Pool_lane.with_read (fun () ->
          Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () ->
            Eio.Promise.resolve start ();
            Eio.Promise.await release)))
    in
    Eio.Promise.await started;
    check (float 0.) "one worker's weight in flight" 1.0 (in_flight_workers "read");
    Eio.Fiber.both
      (fun () -> Pool_lane.with_read (fun () -> Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ ignore))
      (fun () -> Eio.Promise.resolve release_holder ());
    Eio.Promise.await_exn holder;
    check (list int) "the holder at 0 workers in flight, the next at 1" [ 1; 1; 0; 0 ]
      (diff (in_flight_wait_counts "read") before);
    check (float 0.) "nothing in flight after both returned" 0.0 (in_flight_workers "read"))
;;

let test_a_run_is_counted_by_the_weight_it_declared () =
  with_pool (fun _env _sw _pool ->
    let io_before, _ = counts "read" "run_declared_io" in
    let cpu_before, _ = counts "read" "run_declared_cpu" in
    Pool_lane.with_read (fun () ->
      Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ ~weight:0.05 ignore;
      Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ ignore);
    let io_after, _ = counts "read" "run_declared_io" in
    let cpu_after, _ = counts "read" "run_declared_cpu" in
    check int "the 0.05 job" 1 (io_after - io_before);
    check int "the job at the 1.0 default" 1 (cpu_after - cpu_before))
;;

let test_a_job_that_raises_leaves_no_weight_in_flight () =
  with_pool (fun _env _sw _pool ->
    let before = in_flight_workers "read" in
    (match Pool_lane.with_read (fun () -> Executor_pool_ref.submit_or_inline ~name:__FUNCTION__ (fun () -> failwith "job failed")) with
     | () -> fail "the job's exception did not reach the caller"
     | exception Failure _ -> ());
    check (float 0.) "the weight left with the job" before (in_flight_workers "read"))
;;

(* RFC-0474 L4c. *)
let named lane_name name =
  member [ lane_name; "by_name" ] (Pool_wait.to_json ())
  |> Yojson.Safe.Util.to_list
  |> List.find_opt (fun row -> member [ "name" ] row = `String name)
;;

let named_int lane_name name field =
  match named lane_name name with
  | Some row -> Yojson.Safe.Util.to_int (member [ field ] row)
  | None -> fail (Printf.sprintf "%s: no %s row in %s.by_name" field name lane_name)
;;

let named_ms lane_name name field =
  match named lane_name name with
  | Some row -> Yojson.Safe.Util.to_number (member [ field ] row)
  | None -> fail (Printf.sprintf "%s: no %s row in %s.by_name" field name lane_name)
;;

(* Two names on one lane are counted apart, and the one that ran longer in
   all is listed first. The long job sleeps on the worker for 20 ms, so its
   run time is at least that by construction. *)
let test_a_job_is_counted_under_its_name () =
  with_pool (fun env _sw _pool ->
    let clock = Eio.Stdenv.clock env in
    let short = "l4c test short job" in
    let long = "l4c test long job" in
    Pool_lane.with_read (fun () ->
      Executor_pool_ref.submit_or_inline ~name:short ignore;
      Executor_pool_ref.submit_or_inline ~name:short ignore;
      Executor_pool_ref.submit_or_inline ~name:long (fun () -> Eio.Time.sleep clock 0.02));
    check int "the short name's jobs" 2 (named_int "read" short "count");
    check int "the long name's job" 1 (named_int "read" long "count");
    check bool "the long job ran at least 20 ms" true (named_ms "read" long "run_sum_ms" >= 20.);
    check bool "neither name reached the background lane" true
      (Option.is_none (named "background" short) && Option.is_none (named "background" long));
    let order =
      member [ "read"; "by_name" ] (Pool_wait.to_json ())
      |> Yojson.Safe.Util.to_list
      |> List.filter_map (fun row ->
        match member [ "name" ] row with
        | `String n when n = short || n = long -> Some n
        | _ -> None)
    in
    check (list string) "longest run time first" [ long; short ] order)
;;

let test_an_abandoned_job_is_counted_under_its_name () =
  with_pool (fun env sw pool ->
    let release = occupy_the_only_worker sw pool in
    let name = "l4c test abandoned job" in
    Eio.Fiber.first
      (fun () -> Pool_lane.with_read (fun () -> Executor_pool_ref.submit_or_inline ~name ignore))
      (fun () -> Eio.Time.sleep (Eio.Stdenv.clock env) 0.03);
    release ();
    check int "one abandoned submission" 1 (named_int "read" name "abandoned");
    check int "no job entered a worker" 0 (named_int "read" name "count"))
;;

(* Bucket [i] holds spans at most its bound and above the previous one. *)
let test_a_span_on_a_bound_belongs_to_that_bucket () =
  let ms n = Mtime.Span.of_uint64_ns (Int64.of_float (n *. 1e6)) in
  let place span =
    let _, before = counts "background" "abandoned" in
    Pool_wait.record_abandoned Pool_lane.Background ~name:__FUNCTION__ span;
    let _, after = counts "background" "abandoned" in
    let rec index i = function
      | [] -> fail "no bucket changed"
      | 0 :: rest -> index (i + 1) rest
      | _ :: _ -> i
    in
    index 0 (diff after before)
  in
  let bounds = bounds () in
  check int "exactly 1 ms is the first bucket" 0 (place (ms 1.));
  check int "just above 1 ms is the second" 1
    (place (Mtime.Span.add (ms 1.) (Mtime.Span.of_uint64_ns 1L)));
  check int "above every bound is the overflow bucket" (List.length bounds)
    (place (ms 20_000.))
;;

let () =
  run "Pool lane"
    [ ( "lane"
      , [ test_case "an unmarked fiber is background" `Quick test_unmarked_is_background
        ; test_case "a read ends for every fiber that carries it" `Quick
            test_read_ends_for_every_fiber
        ; test_case "a pool job does not inherit the lane" `Quick
            test_pool_job_does_not_inherit_the_lane
        ; test_case "with_background unmarks inside a read" `Quick
            test_with_background_unmarks_inside_a_read
        ] )
    ; ( "wait"
      , [ test_case "wait is recorded under the submitting lane" `Quick
            test_wait_is_recorded_under_the_submitting_lane
        ; test_case "a queued wait lands above its lower buckets" `Quick
            test_a_queued_wait_lands_above_its_lower_buckets
        ; test_case "run is recorded under the submitting lane" `Quick
            test_run_is_recorded_under_the_submitting_lane
        ; test_case "a cancelled queued submission is abandoned" `Quick
            test_a_cancelled_queued_submission_is_abandoned
        ; test_case "a span on a bound belongs to that bucket" `Quick
            test_a_span_on_a_bound_belongs_to_that_bucket
        ; test_case "a wait is counted by the weight in flight" `Quick
            test_a_wait_is_counted_by_the_weight_in_flight
        ; test_case "a run is counted by the weight it declared" `Quick
            test_a_run_is_counted_by_the_weight_it_declared
        ; test_case "a job that raises leaves no weight in flight" `Quick
            test_a_job_that_raises_leaves_no_weight_in_flight
        ; test_case "a job is counted under its name" `Quick
            test_a_job_is_counted_under_its_name
        ; test_case "an abandoned job is counted under its name" `Quick
            test_an_abandoned_job_is_counted_under_its_name
        ] )
    ]
;;
