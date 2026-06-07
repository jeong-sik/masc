open Alcotest

let run_eio f = Eio_main.run (fun _env -> f ())

let test_blocks_at_max_concurrent () =
  Masc.Runtime_lane_capacity.reset_for_test ();
  run_eio (fun () ->
    let result =
      Masc.Runtime_lane_capacity.with_lane_capacity
        ~timeout_s:0.001
        ~lane_key:"ollama_cloud"
        ~max_concurrent:1
        (fun ~capacity_wait_ms:_ ->
           (* Inner attempt to same lane should be rejected *)
           let inner =
             Masc.Runtime_lane_capacity.with_lane_capacity
               ~timeout_s:0.001
               ~lane_key:"ollama_cloud"
               ~max_concurrent:1
               (fun ~capacity_wait_ms:_ -> ())
           in
           match inner with
           | Error { Masc.Runtime_lane_capacity.lane_key; limit; inflight; _ } ->
             check string "lane_key" "ollama_cloud" lane_key;
             check int "limit" 1 limit;
             check int "inflight" 1 inflight
           | Ok () -> fail "second concurrent request bypassed lane capacity")
    in
    match result with
    | Ok () -> ()
    | Error err ->
      failf "first request rejected limit=%d inflight=%d" err.limit err.inflight);
  check int "released" 0 (Masc.Runtime_lane_capacity.inflight_for_test "ollama_cloud")
;;

let test_different_lanes_independent () =
  Masc.Runtime_lane_capacity.reset_for_test ();
  run_eio (fun () ->
    let result =
      Masc.Runtime_lane_capacity.with_lane_capacity
        ~timeout_s:0.001
        ~lane_key:"ollama_cloud"
        ~max_concurrent:1
        (fun ~capacity_wait_ms:_ ->
           (* Different lane should be admitted independently *)
           let inner =
             Masc.Runtime_lane_capacity.with_lane_capacity
               ~timeout_s:0.001
               ~lane_key:"runpod_mtp"
               ~max_concurrent:1
               (fun ~capacity_wait_ms:_ -> ())
           in
           match inner with
           | Ok () -> ()
           | Error err ->
             failf "different lane rejected lane_key=%s" err.lane_key)
    in
    match result with
    | Ok () -> ()
    | Error err ->
      failf "first request rejected lane=%s" err.lane_key);
  check int "ollama released" 0 (Masc.Runtime_lane_capacity.inflight_for_test "ollama_cloud");
  check int "runpod released" 0 (Masc.Runtime_lane_capacity.inflight_for_test "runpod_mtp")
;;

let test_disabled_allows_unlimited () =
  Masc.Runtime_lane_capacity.reset_for_test ();
  run_eio (fun () ->
    let result =
      Masc.Runtime_lane_capacity.with_lane_capacity
        ~timeout_s:0.001
        ~lane_key:"ollama_cloud"
        ~max_concurrent:0
        (fun ~capacity_wait_ms:_ ->
           (* Disabled gate: inner request to same lane should pass *)
           let inner =
             Masc.Runtime_lane_capacity.with_lane_capacity
               ~timeout_s:0.001
               ~lane_key:"ollama_cloud"
               ~max_concurrent:0
               (fun ~capacity_wait_ms:_ -> ())
           in
           match inner with
           | Ok () -> ()
           | Error err ->
             failf "rejected while disabled lane=%s" err.lane_key)
    in
    match result with
    | Ok () -> ()
    | Error err ->
      failf "first request rejected while disabled lane=%s" err.lane_key);
  (* Disabled gate should not increment counters *)
  check int "no counter leak" 0 (Masc.Runtime_lane_capacity.inflight_for_test "ollama_cloud")
;;

let test_release_on_exception () =
  Masc.Runtime_lane_capacity.reset_for_test ();
  (* with_lane_capacity uses Fun.protect ~finally, so the release runs
     even when the body raises. The exception re-propagates, so we
     catch it here to observe the counter state afterwards. *)
  (try
    run_eio (fun () ->
      ignore
        (Masc.Runtime_lane_capacity.with_lane_capacity
           ~timeout_s:0.001
           ~lane_key:"ollama_cloud"
           ~max_concurrent:1
           (fun ~capacity_wait_ms:_ ->
              raise Exit)))
  with Exit -> ());
  check int "released after exception" 0
    (Masc.Runtime_lane_capacity.inflight_for_test "ollama_cloud")
;;

let () =
  run
    "runtime_lane_capacity"
    [ ( "lane gate"
      , [ test_case "blocks at max_concurrent" `Quick test_blocks_at_max_concurrent
        ; test_case "different lanes are independent"
            `Quick test_different_lanes_independent
        ; test_case "disabled allows unlimited" `Quick test_disabled_allows_unlimited
        ; test_case "releases on exception" `Quick test_release_on_exception
        ] )
    ]
