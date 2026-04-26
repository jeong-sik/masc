(* #9771: pin canonical metric name + label vocabulary for the
   semaphore wait timeout counter.  The keepalive path emits this
   counter at three sites:
     - [autonomous_queue_head]: fairness FIFO head wait exceeded
     - [autonomous]: autonomous-track semaphore acquire timeout
     - [turn]: shared turn semaphore acquire timeout

   Test exercises the counter directly so the metric vocabulary
   is pinned independently of the surrounding Eio + semaphore
   plumbing. *)

let counter_for ~keeper ~channel =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Prometheus.metric_keeper_semaphore_wait_timeout
    ~labels:[ "keeper", keeper; "channel", channel ]
    ()
;;

let test_metric_name_stable () =
  Alcotest.(check string)
    "semaphore wait timeout canonical metric name"
    "masc_keeper_semaphore_wait_timeout_total"
    Masc_mcp.Prometheus.metric_keeper_semaphore_wait_timeout
;;

let test_increments_per_channel () =
  let keeper = "sangsu-test-9771" in
  let channels = [ "autonomous_queue_head"; "autonomous"; "turn" ] in
  List.iter
    (fun channel ->
       let before = counter_for ~keeper ~channel in
       Masc_mcp.Prometheus.inc_counter
         Masc_mcp.Prometheus.metric_keeper_semaphore_wait_timeout
         ~labels:[ "keeper", keeper; "channel", channel ]
         ();
       Alcotest.(check (float 0.0001))
         (Printf.sprintf "%s +1" channel)
         (before +. 1.0)
         (counter_for ~keeper ~channel))
    channels
;;

let test_keeper_isolation () =
  (* Different keepers must land in different series. *)
  let channel = "autonomous" in
  let keeper_a = "alpha-9771" in
  let keeper_b = "beta-9771" in
  let before_a = counter_for ~keeper:keeper_a ~channel in
  Masc_mcp.Prometheus.inc_counter
    Masc_mcp.Prometheus.metric_keeper_semaphore_wait_timeout
    ~labels:[ "keeper", keeper_b; "channel", channel ]
    ();
  Alcotest.(check (float 0.0001))
    "alpha unaffected by beta"
    before_a
    (counter_for ~keeper:keeper_a ~channel)
;;

let test_channel_isolation () =
  (* Different channels for the same keeper must not bleed. *)
  let keeper = "channel-iso-9771" in
  let before_turn = counter_for ~keeper ~channel:"turn" in
  Masc_mcp.Prometheus.inc_counter
    Masc_mcp.Prometheus.metric_keeper_semaphore_wait_timeout
    ~labels:[ "keeper", keeper; "channel", "autonomous_queue_head" ]
    ();
  Alcotest.(check (float 0.0001))
    "turn channel unchanged when queue_head fires"
    before_turn
    (counter_for ~keeper ~channel:"turn")
;;

let () =
  Alcotest.run
    "keeper_semaphore_wait_counter_9771"
    [ ( "metric_name"
      , [ Alcotest.test_case "canonical name stable" `Quick test_metric_name_stable ] )
    ; ( "counter"
      , [ Alcotest.test_case "all 3 channels increment" `Quick test_increments_per_channel
        ] )
    ; ( "isolation"
      , [ Alcotest.test_case "keepers isolated" `Quick test_keeper_isolation
        ; Alcotest.test_case "channels isolated" `Quick test_channel_isolation
        ] )
    ]
;;
