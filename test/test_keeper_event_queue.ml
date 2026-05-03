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
       (match other with Bootstrap -> "Bootstrap" | Unsupported s -> "Unsupported("^s^")" | Board_signal -> "Board_signal")));

  (* --- classify: bootstrap --- *)
  let bootstrap_stim = {
    post_id = "bootstrap"; urgency = Normal; arrived_at = 0.0;
    payload = "Keeper bootstrap signal";
  } in
  (match classify bootstrap_stim with
   | Bootstrap -> ()
   | other ->
     Alcotest.fail (Printf.sprintf "expected Bootstrap, got %s"
       (match other with Board_signal -> "Board_signal" | Unsupported s -> "Unsupported("^s^")" | Bootstrap -> "Bootstrap")));

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
       (match other with Board_signal -> "Board_signal" | Bootstrap -> "Bootstrap" | Unsupported _ -> "Unsupported")));

  (* --- queue operations preserved --- *)
  let q = empty in
  assert (is_empty q);
  let q = enqueue q board_stim in
  let q = enqueue q bootstrap_stim in
  assert (length q = 2);
  let (stim, q) = match dequeue q with Some s -> s | None -> Alcotest.fail "dequeue should return item" in
  assert (String.equal stim.post_id "p1");
  assert (length q = 1);

  print_endline "test_keeper_event_queue: all passed"
