open Alcotest
open Masc_mcp

let make_message ?(content = "hello") ?(keeper_name = "luna")
    ?(channel_user_id = "user-1") ?(idempotency_key = "key-1") () =
  {
    Channel_gate.channel = "discord";
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

let unique_key prefix =
  Printf.sprintf "%s-%d-%.0f" prefix (Unix.getpid ())
    (Unix.gettimeofday () *. 1_000_000.)

let test_validate_accepts_valid_message () =
  reset_dedup ();
  match Channel_gate.validate (make_message ~idempotency_key:(unique_key "ok") ()) with
  | Ok () -> ()
  | Error _ -> fail "expected valid message to pass validation"

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
  let key = unique_key "dup" in
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
  let key = unique_key "cleanup" in
  let message = make_message ~idempotency_key:key () in
  (match Channel_gate.validate message with
  | Ok () -> ()
  | Error _ -> fail "first validate should accept fresh idempotency key");
  reset_dedup ();
  match Channel_gate.validate message with
  | Ok () -> ()
  | Error _ -> fail "cleanup should evict expired idempotency key"

let test_failed_validation_does_not_consume_idempotency_key () =
  reset_dedup ();
  let key = unique_key "retryable" in
  (match
     Channel_gate.validate
       (make_message ~content:"   " ~idempotency_key:key ())
   with
  | Error Channel_gate.Empty_content -> ()
  | Ok () -> fail "expected invalid message to fail"
  | Error _ -> fail "expected Empty_content");
  match Channel_gate.validate (make_message ~idempotency_key:key ()) with
  | Ok () -> ()
  | Error _ -> fail "failed validation should not consume idempotency key"

let test_validate_serializes_duplicate_race_under_eio () =
  reset_dedup ();
  let key = unique_key "concurrent" in
  let with_eio f =
    Eio_main.run @@ fun _env ->
    Eio_guard.enable ();
    Fun.protect ~finally:Eio_guard.disable f
  in
  with_eio (fun () ->
    let results = Array.make 16 (Error Channel_gate.Empty_content) in
    Eio.Fiber.all
      (List.init 16 (fun i -> fun () ->
         results.(i) <- Channel_gate.validate (make_message ~idempotency_key:key ())
      ));
    let ok_count, duplicate_count =
      Array.fold_left
        (fun (oks, dups) -> function
          | Ok () -> (oks + 1, dups)
          | Error (Channel_gate.Duplicate_message dup_key) ->
              check string "duplicate key is preserved" key dup_key;
              (oks, dups + 1)
          | Error err ->
              fail
                (Printf.sprintf "unexpected validation result: %s"
                   (Channel_gate.validation_error_to_string err)))
        (0, 0) results
    in
    check int "exactly one fresh message wins" 1 ok_count;
    check int "all other fibers see duplicate" 15 duplicate_count)

let test_validation_error_to_string () =
  check string "empty content" "content is required"
    (Channel_gate.validation_error_to_string Channel_gate.Empty_content);
  check string "empty keeper name" "keeper_name is required"
    (Channel_gate.validation_error_to_string Channel_gate.Empty_keeper_name);
  check string "duplicate message"
    "duplicate message (idempotency_key=dup)"
    (Channel_gate.validation_error_to_string
       (Channel_gate.Duplicate_message "dup"))

let () =
  Alcotest.run "Channel_gate"
    [
      ( "validate",
        [
          test_case "accepts valid message" `Quick
            test_validate_accepts_valid_message;
          test_case "rejects empty content" `Quick
            test_validate_rejects_empty_content;
          test_case "rejects empty keeper name" `Quick
            test_validate_rejects_empty_keeper_name;
          test_case "rejects duplicate message" `Quick
            test_validate_rejects_duplicate_message;
          test_case "allows key after cleanup" `Quick
            test_validate_allows_key_after_cleanup;
          test_case "failed validation does not consume key" `Quick
            test_failed_validation_does_not_consume_idempotency_key;
          test_case "serializes duplicate race under eio" `Quick
            test_validate_serializes_duplicate_race_under_eio;
          test_case "stringifies validation errors" `Quick
            test_validation_error_to_string;
        ] );
    ]
