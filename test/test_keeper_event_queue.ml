let () =
  let open Keeper_event_queue in
  let board_payload () =
    Board_signal
      { kind = Post_created
      ; author = "a"
      ; title = "t"
      ; content = "c"
      ; hearth = None
      ; updated_at = None
      }
  in

  (* --- typed payload kind labels (RFC-0020): the stimulus kind is a
         closed variant, not classified from a JSON-prefixed string --- *)
  assert (is_board_signal (board_payload ()));
  assert (not (is_board_signal Bootstrap));
  assert (String.equal (payload_kind_label (board_payload ())) "board_signal");
  assert (String.equal (payload_kind_label Bootstrap) "bootstrap");
  assert (String.equal (payload_kind_label No_progress_recovery) "no_progress_recovery");

  (* RFC-0266: Fusion_completed is a non-board stimulus with its own label. *)
  let fusion_payload () =
    Fusion_completed
      { run_id = "fus-1"; ok = true; resolved_answer = "ok"; board_post_id = "post-1" }
  in
  assert (not (is_board_signal (fusion_payload ())));
  assert (String.equal (payload_kind_label (fusion_payload ())) "fusion_completed");
  assert (
    String.equal
      (fusion_completion_post_id
         { run_id = "fus-1"; ok = true; resolved_answer = "ok"; board_post_id = "post-1" })
      "post-1");
  assert (
    String.equal
      (fusion_completion_post_id
         { run_id = "fus-2"; ok = false; resolved_answer = "sink_failed"; board_post_id = "" })
      "fusion-run:fus-2");

  (* --- queue operations preserved --- *)
  let board_stim =
    { post_id = "p1"; urgency = Normal; arrived_at = 0.0; payload = board_payload () }
  in
  let bootstrap_stim =
    { post_id = "bootstrap"; urgency = Normal; arrived_at = 0.0; payload = Bootstrap }
  in
  let q = empty in
  assert (is_empty q);
  let q = enqueue q board_stim in
  let q = enqueue q bootstrap_stim in
  assert (length q = 2);
  let stim, q =
    match dequeue q with
    | Some s -> s
    | None -> Alcotest.fail "dequeue should return item"
  in
  assert (String.equal stim.post_id "p1");
  assert (length q = 1);

  (* --- drain_board_window: coalesces board signals within window --- *)
  let now = Unix.gettimeofday () in
  let recent_board_1 =
    { post_id = "rb1"; urgency = Normal; arrived_at = now; payload = board_payload () }
  in
  let recent_board_2 =
    { post_id = "rb2"; urgency = Immediate; arrived_at = now; payload = board_payload () }
  in
  let old_board =
    { post_id = "ob1"; urgency = Normal; arrived_at = 0.0; payload = board_payload () }
  in
  let bootstrap_in_queue =
    { post_id = "bs1"; urgency = Normal; arrived_at = now; payload = Bootstrap }
  in
  let q_drain = empty in
  let q_drain = enqueue q_drain recent_board_1 in
  let q_drain = enqueue q_drain old_board in
  let q_drain = enqueue q_drain bootstrap_in_queue in
  let q_drain = enqueue q_drain recent_board_2 in
  let board_in_window, rest_queue = drain_board_window ~window_sec:5.0 q_drain in
  assert (List.length board_in_window = 2);
  (match board_in_window with
   | first :: _ -> assert (String.equal first.post_id "rb2") (* urgency-sorted: Immediate first *)
   | [] -> Alcotest.fail "expected at least one board signal in window");
  assert (length rest_queue = 2);

  (* --- drain_board_window: empty queue --- *)
  let empty_board, empty_rest = drain_board_window empty in
  assert (List.length empty_board = 0);
  assert (is_empty empty_rest);

  (* --- durable snapshot codec: preserves FIFO order and typed payloads --- *)
  let queue_for_snapshot =
    let q = enqueue empty board_stim in
    let q = enqueue q bootstrap_stim in
    let q =
      enqueue
        q
         { post_id = "np1"
         ; urgency = Immediate
         ; arrived_at = 1.5
         ; payload = No_progress_recovery
         }
    in
    enqueue
      q
         { post_id = "fp1"
         ; urgency = Low
         ; arrived_at = 2.5
         ; payload =
             Fusion_completed
               { run_id = "fus-3"
               ; ok = false
               ; resolved_answer = "denied"
               ; board_post_id = ""
               }
         }
  in
  let restored =
    match queue_of_yojson (queue_to_yojson queue_for_snapshot) with
    | Ok queue -> queue
    | Error msg -> Alcotest.fail ("queue snapshot round-trip failed: " ^ msg)
  in
  assert (length restored = 4);
  let first, restored =
    match dequeue restored with
    | Some item -> item
    | None -> Alcotest.fail "snapshot restore should preserve first item"
  in
  assert (String.equal first.post_id "p1");
  let second, restored =
    match dequeue restored with
    | Some item -> item
    | None -> Alcotest.fail "snapshot restore should preserve second item"
  in
  assert (String.equal second.post_id "bootstrap");
  let third, restored =
    match dequeue restored with
    | Some item -> item
    | None -> Alcotest.fail "snapshot restore should preserve third item"
  in
  assert (String.equal third.post_id "np1");
  assert (
    match third.payload with
    | No_progress_recovery -> true
    | _ -> false);
  let fourth, restored =
    match dequeue restored with
    | Some item -> item
    | None -> Alcotest.fail "snapshot restore should preserve fourth item"
  in
  assert (String.equal fourth.post_id "fp1");
  assert (
    match fourth.payload with
    | Fusion_completed { run_id; ok; resolved_answer; board_post_id } ->
      String.equal run_id "fus-3"
      && (not ok)
      && String.equal resolved_answer "denied"
      && String.equal board_post_id ""
    | _ -> false);
  assert (is_empty restored);
  (match queue_of_yojson (`Assoc [ "schema", `String "wrong"; "items", `List [] ]) with
   | Ok _ -> Alcotest.fail "wrong queue snapshot schema should be rejected"
   | Error _ -> ());

  print_endline "test_keeper_event_queue: all passed"
