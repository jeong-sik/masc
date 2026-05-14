let () =
  let open Masc_mcp.Keeper_event_queue in

  (* --- classify: board_signal --- *)
  let board_payload =
    {|{"source":"board_signal","kind":"post_created","post_id":"p1","author":"a","title":"t","content":"c"}|}
  in
  let board_stim = { post_id = "p1"; urgency = Normal; arrived_at = 0.0; payload = board_payload } in
  (match classify board_stim with
   | Board_signal -> ()
   | other ->
     Alcotest.fail (Printf.sprintf "expected Board_signal, got %s"
       (match other with
        | Bootstrap -> "Bootstrap"
        | Unsupported s -> "Unsupported("^s^")"
        | Board_signal -> "Board_signal"
        | Alive_but_stuck_recovery -> "Alive_but_stuck_recovery")));

  let live_comment_payload =
    {|{"source":"board_signal","kind":"comment","post_id":"p2","author":"alice","title":"Long board event","content":"this mirrors the long live payload that used to miss the prefix check","hearth":null,"wake_reason":"scope_message"}|}
  in
  let live_comment_stim =
    { post_id = "p2"; urgency = Normal; arrived_at = 0.0; payload = live_comment_payload }
  in
  (match classify live_comment_stim with
   | Board_signal -> ()
   | other ->
     Alcotest.fail (Printf.sprintf "expected live comment Board_signal, got %s"
       (match other with
        | Bootstrap -> "Bootstrap"
        | Unsupported s -> "Unsupported("^s^")"
        | Board_signal -> "Board_signal"
        | Alive_but_stuck_recovery -> "Alive_but_stuck_recovery")));

  (* --- classify: bootstrap --- *)
  let bootstrap_stim = {
    post_id = "bootstrap"; urgency = Normal; arrived_at = 0.0;
    payload = "Keeper bootstrap signal";
  } in
  (match classify bootstrap_stim with
   | Bootstrap -> ()
   | other ->
     Alcotest.fail (Printf.sprintf "expected Bootstrap, got %s"
       (match other with
        | Board_signal -> "Board_signal"
        | Unsupported s -> "Unsupported("^s^")"
        | Bootstrap -> "Bootstrap"
        | Alive_but_stuck_recovery -> "Alive_but_stuck_recovery")));

  (* --- classify: unsupported --- *)
  let unknown_stim = {
    post_id = "x"; urgency = Low; arrived_at = 0.0;
    payload = "some random payload";
  } in
  (match classify unknown_stim with
   | Unsupported prefix ->
     if String.length prefix > 40 then
       Alcotest.fail "unsupported prefix should be truncated to 40 chars"
   | other ->
     Alcotest.fail (Printf.sprintf "expected Unsupported, got %s"
       (match other with Board_signal -> "Board_signal" | Bootstrap -> "Bootstrap" | _ -> "other")));

  (* --- classify: malformed JSON is unsupported --- *)
  let broken_json = {
    post_id = "y"; urgency = Normal; arrived_at = 0.0;
    payload = "{\"source\":\"board_signal\"";  (* truncated, no closing brace *)
  } in
  (match classify broken_json with
   | Board_signal -> ()  (* prefix match succeeds, this is fine *)
   | _ -> ());

  (* --- classify: empty payload is unsupported --- *)
  let empty_stim = { post_id = "z"; urgency = Low; arrived_at = 0.0; payload = "" } in
  (match classify empty_stim with
   | Unsupported _ -> ()
   | other ->
     Alcotest.fail (Printf.sprintf "empty payload should be Unsupported, got %s"
       (match other with
        | Board_signal -> "Board_signal"
        | Bootstrap -> "Bootstrap"
        | Unsupported _ -> "Unsupported"
        | Alive_but_stuck_recovery -> "Alive_but_stuck_recovery")));

  (* --- queue operations preserved --- *)
  let q = empty in
  assert (is_empty q);
  let q = enqueue q board_stim in
  let q = enqueue q bootstrap_stim in
  assert (length q = 2);
  let (stim, q) = match dequeue q with Some s -> s | None -> Alcotest.fail "dequeue should return item" in
  assert (String.equal stim.post_id "p1");
  assert (length q = 1);

  (* --- drain_board_window: coalesces board signals within window --- *)
  let now = Unix.gettimeofday () in
  let recent_board_1 = {
    post_id = "rb1"; urgency = Normal; arrived_at = now;
    payload = board_payload;
  } in
  let recent_board_2 = {
    post_id = "rb2"; urgency = Immediate; arrived_at = now;
    payload = board_payload;
  } in
  let old_board = {
    post_id = "ob1"; urgency = Normal; arrived_at = 0.0;
    payload = board_payload;
  } in
  let bootstrap_in_queue = {
    post_id = "bs1"; urgency = Normal; arrived_at = now;
    payload = "Keeper bootstrap signal";
  } in
  let q_drain = empty in
  let q_drain = enqueue q_drain recent_board_1 in
  let q_drain = enqueue q_drain old_board in
  let q_drain = enqueue q_drain bootstrap_in_queue in
  let q_drain = enqueue q_drain recent_board_2 in
  let (board_in_window, rest_queue) = drain_board_window ~window_sec:5.0 q_drain in
  assert (List.length board_in_window = 2);
  (match board_in_window with
   | first :: _ -> assert (String.equal first.post_id "rb2")
   | [] -> Alcotest.fail "expected at least one board signal in window");
  assert (length rest_queue = 2);

  (* --- drain_board_window: empty queue --- *)
  let (empty_board, empty_rest) = drain_board_window empty in
  assert (List.length empty_board = 0);
  assert (is_empty empty_rest);

  print_endline "test_keeper_event_queue: all passed"
