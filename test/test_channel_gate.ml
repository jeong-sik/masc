open Alcotest
open Masc_mcp

let make_message ?(content = "hello") ?(keeper_name = "luna")
    ?(channel_user_id = "user-1") ?(idempotency_key = "key-1") () =
  {
    Channel_gate.channel = Agent_identity.Discord;
    channel_user_id;
    channel_user_name = "user";
    channel_room_id = "room-1";
    keeper_name;
    content;
    idempotency_key;
    metadata = [];
  }

let reset_dedup () =
  Channel_gate.dedup_cleanup
    ~now:(Unix.gettimeofday () +. Channel_gate.dedup_ttl_sec () +. 1.0)

let test_validate_rejects_empty_keeper_name () =
  reset_dedup ();
  match Channel_gate.validate (make_message ~keeper_name:"   " ~idempotency_key:"empty-keeper" ()) with
  | Error Channel_gate.Empty_keeper_name -> ()
  | Ok () -> fail "expected Empty_keeper_name"
  | Error _ -> fail "expected Empty_keeper_name"

let test_validate_rejects_empty_content () =
  reset_dedup ();
  match Channel_gate.validate (make_message ~content:"   " ~idempotency_key:"empty-content" ()) with
  | Error Channel_gate.Empty_content -> ()
  | Ok () -> fail "expected Empty_content"
  | Error _ -> fail "expected Empty_content"

let test_validate_rejects_duplicate_message () =
  reset_dedup ();
  let key = Printf.sprintf "dup-%d" (Unix.getpid ()) in
  let message = make_message ~idempotency_key:key () in
  (match Channel_gate.validate message with
  | Ok () -> ()
  | Error _ -> fail "first validate should accept fresh idempotency key");
  match Channel_gate.validate message with
  | Error (Channel_gate.Duplicate_message dup_key) ->
      check string "duplicate key" key dup_key
  | Ok () -> fail "expected duplicate validation failure"
  | Error _ -> fail "expected Duplicate_message"

let test_validate_allows_key_after_cleanup () =
  reset_dedup ();
  let key = Printf.sprintf "cleanup-%d" (Unix.getpid ()) in
  let message = make_message ~idempotency_key:key () in
  (match Channel_gate.validate message with
  | Ok () -> ()
  | Error _ -> fail "first validate should accept fresh idempotency key");
  reset_dedup ();
  match Channel_gate.validate message with
  | Ok () -> ()
  | Error _ -> fail "cleanup should evict expired idempotency key"

let test_validation_error_to_string () =
  check string "empty content" "content is required"
    (Channel_gate.validation_error_to_string Channel_gate.Empty_content);
  check string "duplicate message"
    "duplicate message (idempotency_key=dup)"
    (Channel_gate.validation_error_to_string
       (Channel_gate.Duplicate_message "dup"))

let () =
  Alcotest.run "Channel_gate"
    [
      ( "validate",
        [
          test_case "rejects empty content" `Quick
            test_validate_rejects_empty_content;
          test_case "rejects empty keeper name" `Quick
            test_validate_rejects_empty_keeper_name;
          test_case "rejects duplicate message" `Quick
            test_validate_rejects_duplicate_message;
          test_case "allows key after cleanup" `Quick
            test_validate_allows_key_after_cleanup;
          test_case "stringifies validation errors" `Quick
            test_validation_error_to_string;
        ] );
    ]
