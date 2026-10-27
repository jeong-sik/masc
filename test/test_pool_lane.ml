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

(* A job queued behind a 30 ms occupant of the only worker waited at least
   30 ms: its observation lands above every bucket bound below 30 ms. *)
let test_a_queued_wait_lands_above_its_lower_buckets () =
  with_pool (fun env sw pool ->
    let clock = Eio.Stdenv.clock env in
    let occupied, occupy = Eio.Promise.create () in
    let blocker =
      Eio.Executor_pool.submit_fork ~sw pool ~weight:1.0 (fun () ->
        Eio.Promise.resolve occupy ();
        Eio.Time.sleep clock 0.03)
    in
    Eio.Promise.await occupied;
    let _, before = wait_counts "read" in
    Pool_lane.with_read (fun () -> Executor_pool_ref.submit_or_inline ignore);
    ignore (Eio.Promise.await_exn blocker);
    let _, after = wait_counts "read" in
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
        ] )
    ]
;;
