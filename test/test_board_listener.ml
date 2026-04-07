(** Test Board_listener — hermetic tests for pure logic.

    Tests event_to_sse_json parsing, stats serialization,
    and listener state management without PG. *)

open Masc_mcp

let () = Mirage_crypto_rng_unix.use_default ()

(* --- event_to_sse_json --- *)

let test_event_to_sse_json_valid () =
  let payload = {|{"type":"post_created","post_id":"p1","author":"alice"}|} in
  match Board_listener.event_to_sse_json payload with
  | Some json ->
      let s = Yojson.Safe.to_string json in
      Alcotest.(check bool) "has jsonrpc" true (String.length s > 0);
      let obj = Yojson.Safe.Util.to_assoc json in
      Alcotest.(check string) "jsonrpc field"
        "2.0" (Yojson.Safe.Util.to_string (List.assoc "jsonrpc" obj));
      Alcotest.(check string) "method field"
        "notifications/board" (Yojson.Safe.Util.to_string (List.assoc "method" obj));
      let params = List.assoc "params" obj in
      let ptype = Yojson.Safe.Util.member "type" params |> Yojson.Safe.Util.to_string in
      Alcotest.(check string) "params.type" "post_created" ptype
  | None -> Alcotest.fail "expected Some for valid JSON"

let test_event_to_sse_json_invalid () =
  match Board_listener.event_to_sse_json "not valid json {{{" with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None for invalid JSON"

let test_event_to_sse_json_empty () =
  match Board_listener.event_to_sse_json "{}" with
  | Some json ->
      let params = Yojson.Safe.Util.member "params" json in
      Alcotest.(check string) "empty object wrapped"
        "{}" (Yojson.Safe.to_string params)
  | None -> Alcotest.fail "expected Some for empty object"

let test_event_to_sse_json_nested () =
  let payload = {|{"type":"post_voted","data":{"score":42,"nested":{"deep":true}}}|} in
  match Board_listener.event_to_sse_json payload with
  | Some json ->
      let params = Yojson.Safe.Util.member "params" json in
      let score = Yojson.Safe.Util.(member "data" params |> member "score" |> to_int) in
      Alcotest.(check int) "nested score preserved" 42 score
  | None -> Alcotest.fail "expected Some for nested JSON"

(* --- Board_pg_notify event_to_json --- *)

let test_pg_notify_post_created () =
  let json_str = Board_pg_notify.event_to_json
    (Post_created { post_id = "p1"; author = "alice"; hearth = Some "general" }) in
  let json = Yojson.Safe.from_string json_str in
  let typ = Yojson.Safe.Util.(member "type" json |> to_string) in
  Alcotest.(check string) "type" "post_created" typ;
  let hearth = Yojson.Safe.Util.(member "hearth" json |> to_string) in
  Alcotest.(check string) "hearth" "general" hearth

let test_pg_notify_post_created_no_hearth () =
  let json_str = Board_pg_notify.event_to_json
    (Post_created { post_id = "p2"; author = "bob"; hearth = None }) in
  let json = Yojson.Safe.from_string json_str in
  let hearth = Yojson.Safe.Util.member "hearth" json in
  Alcotest.(check bool) "no hearth field" true
    (hearth = `Null || not (List.mem_assoc "hearth" (Yojson.Safe.Util.to_assoc json)))

let test_pg_notify_post_voted () =
  let json_str = Board_pg_notify.event_to_json
    (Post_voted { post_id = "p1"; voter = "alice"; direction = "up"; new_score = 5 }) in
  let json = Yojson.Safe.from_string json_str in
  Alcotest.(check string) "type" "post_voted"
    Yojson.Safe.Util.(member "type" json |> to_string);
  Alcotest.(check int) "new_score" 5
    Yojson.Safe.Util.(member "new_score" json |> to_int)

let test_pg_notify_comment_added () =
  let json_str = Board_pg_notify.event_to_json
    (Comment_added { post_id = "p1"; comment_id = "c1"; author = "alice" }) in
  let json = Yojson.Safe.from_string json_str in
  Alcotest.(check string) "type" "comment_added"
    Yojson.Safe.Util.(member "type" json |> to_string);
  Alcotest.(check string) "comment_id" "c1"
    Yojson.Safe.Util.(member "comment_id" json |> to_string)

let test_pg_notify_comment_voted () =
  let json_str = Board_pg_notify.event_to_json
    (Comment_voted { comment_id = "c1"; voter = "bob"; direction = "down" }) in
  let json = Yojson.Safe.from_string json_str in
  Alcotest.(check string) "type" "comment_voted"
    Yojson.Safe.Util.(member "type" json |> to_string);
  Alcotest.(check string) "direction" "down"
    Yojson.Safe.Util.(member "direction" json |> to_string)

(* --- pg_notify max_notify_payload --- *)

let test_pg_notify_max_payload () =
  Alcotest.(check bool) "max payload < 8000"
    true (Board_pg_notify.max_notify_payload < 8000);
  Alcotest.(check bool) "max payload > 0"
    true (Board_pg_notify.max_notify_payload > 0)

(* --- Board_listener constants --- *)

let test_listener_channel () =
  Alcotest.(check string) "channel name" "masc_board" Board_listener.channel

let test_listener_poll_interval () =
  Alcotest.(check bool) "poll_interval > 0" true (Board_listener.poll_interval_s > 0.0)

let test_listener_max_batch () =
  Alcotest.(check bool) "max_batch > 0" true (Board_listener.max_batch_size > 0)

(* --- Runner --- *)

let () =
  Alcotest.run "Board_listener" [
    ("event_to_sse_json", [
      Alcotest.test_case "valid JSON" `Quick test_event_to_sse_json_valid;
      Alcotest.test_case "invalid JSON" `Quick test_event_to_sse_json_invalid;
      Alcotest.test_case "empty object" `Quick test_event_to_sse_json_empty;
      Alcotest.test_case "nested JSON" `Quick test_event_to_sse_json_nested;
    ]);
    ("pg_notify_events", [
      Alcotest.test_case "post_created with hearth" `Quick test_pg_notify_post_created;
      Alcotest.test_case "post_created no hearth" `Quick test_pg_notify_post_created_no_hearth;
      Alcotest.test_case "post_voted" `Quick test_pg_notify_post_voted;
      Alcotest.test_case "comment_added" `Quick test_pg_notify_comment_added;
      Alcotest.test_case "comment_voted" `Quick test_pg_notify_comment_voted;
    ]);
    ("pg_notify_safety", [
      Alcotest.test_case "max_payload bounds" `Quick test_pg_notify_max_payload;
    ]);
    ("listener_config", [
      Alcotest.test_case "channel" `Quick test_listener_channel;
      Alcotest.test_case "poll_interval" `Quick test_listener_poll_interval;
      Alcotest.test_case "max_batch" `Quick test_listener_max_batch;
    ]);
  ]
