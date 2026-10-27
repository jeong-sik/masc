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
      Pool_lane.with_read (fun () -> Executor_pool_ref.submit_or_inline Pool_lane.current)
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
    Pool_lane.with_read (fun () -> Executor_pool_ref.submit_or_inline ignore);
    let read_after, _ = wait_counts "read" in
    let background_after, _ = wait_counts "background" in
    check int "one read submission" 1 (read_after - read_before);
    check int "no background submission" 0 (background_after - background_before);
    Executor_pool_ref.submit_or_inline ignore;
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
      (fun () -> Pool_lane.with_read (fun () -> Executor_pool_ref.submit_or_inline ignore))
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
    Pool_lane.with_read (fun () -> Executor_pool_ref.submit_or_inline ignore);
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
      (fun () -> Pool_lane.with_read (fun () -> Executor_pool_ref.submit_or_inline (fun () -> ran := true)))
      (fun () -> Eio.Time.sleep (Eio.Stdenv.clock env) 0.03);
    release ();
    let waits_after, _ = counts "read" "wait" in
    let abandoned_after, _ = counts "read" "abandoned" in
    check bool "the cancelled job never ran" false !ran;
    check int "no wait recorded" 0 (waits_after - waits_before);
    check int "one abandoned submission" 1 (abandoned_after - abandoned_before))
;;

(* Bucket [i] holds spans at most its bound and above the previous one. *)
let test_a_span_on_a_bound_belongs_to_that_bucket () =
  let ms n = Mtime.Span.of_uint64_ns (Int64.of_float (n *. 1e6)) in
  let place span =
    let _, before = counts "background" "abandoned" in
    Pool_wait.record_abandoned Pool_lane.Background span;
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
        ] )
    ]
;;
