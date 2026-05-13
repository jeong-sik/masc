open Alcotest

let make_msg ?(channel = "discord") ?(content = "hello") ?(keeper_name = "luna")
    ?(channel_user_id = "user-1") ?(idempotency_key = "key-1") () : Gate_protocol.inbound_message =
  {
    channel;
    channel_user_id;
    channel_user_name = "user";
    channel_room_id = "room-1";
    keeper_name;
    content;
    idempotency_key;
    metadata = [];
  }

let no_dedup _ = false
let always_dedup _ = true

(* ── Validation tests (pure, no Eio) ────────────────────────── *)

let test_validate_ok () =
  match Gate_protocol.validate ~max_content_length:4000 ~dedup_check:no_dedup (make_msg ()) with
  | Ok () -> ()
  | Error _ -> fail "expected valid message"

let test_validate_empty_content () =
  match Gate_protocol.validate ~max_content_length:4000 ~dedup_check:no_dedup (make_msg ~content:"  " ()) with
  | Error Gate_protocol.Empty_content -> ()
  | _ -> fail "expected Empty_content"

let test_validate_content_too_long () =
  let long = String.make 101 'x' in
  match Gate_protocol.validate ~max_content_length:100 ~dedup_check:no_dedup (make_msg ~content:long ()) with
  | Error (Gate_protocol.Content_too_long 101) -> ()
  | _ -> fail "expected Content_too_long"

let test_validate_empty_keeper_name () =
  match Gate_protocol.validate ~max_content_length:4000 ~dedup_check:no_dedup (make_msg ~keeper_name:"" ()) with
  | Error Gate_protocol.Empty_keeper_name -> ()
  | _ -> fail "expected Empty_keeper_name"

let test_validate_empty_user_id () =
  match Gate_protocol.validate ~max_content_length:4000 ~dedup_check:no_dedup (make_msg ~channel_user_id:"" ()) with
  | Error Gate_protocol.Empty_channel_user_id -> ()
  | _ -> fail "expected Empty_channel_user_id"

let test_validate_empty_idempotency_key () =
  match Gate_protocol.validate ~max_content_length:4000 ~dedup_check:no_dedup (make_msg ~idempotency_key:"" ()) with
  | Error Gate_protocol.Empty_idempotency_key -> ()
  | _ -> fail "expected Empty_idempotency_key"

let test_validate_duplicate () =
  match Gate_protocol.validate ~max_content_length:4000 ~dedup_check:always_dedup (make_msg ()) with
  | Error (Gate_protocol.Duplicate_message "key-1") -> ()
  | _ -> fail "expected Duplicate_message"

let test_validate_keeper_name_checked_before_content () =
  match Gate_protocol.validate ~max_content_length:4000 ~dedup_check:no_dedup
    (make_msg ~keeper_name:"" ~content:"  " ()) with
  | Error Gate_protocol.Empty_keeper_name -> ()
  | _ -> fail "keeper_name should be checked before content"

(* ── JSON round-trip tests ───────────────────────────────────── *)

let test_inbound_of_json_basic () =
  let json =
    `Assoc [
      ("channel", `String "telegram");
      ("channel_user_id", `String "u1");
      ("channel_user_name", `String "alice");
      ("channel_room_id", `String "r1");
      ("keeper_name", `String "luna");
      ("content", `String "hi");
      ("idempotency_key", `String "k1");
    ]
  in
  match Gate_protocol.inbound_of_json json with
  | Ok msg ->
      check string "channel" "telegram" msg.channel;
      check string "content" "hi" msg.content
  | Error e -> fail e

let test_inbound_of_json_normalizes_case () =
  let json =
    `Assoc [
      ("channel", `String "  DisCord  ");
      ("channel_user_id", `String "u1");
      ("channel_user_name", `String "bob");
      ("channel_room_id", `String "r1");
      ("keeper_name", `String "luna");
      ("content", `String "hello");
      ("idempotency_key", `String "k2");
    ]
  in
  match Gate_protocol.inbound_of_json json with
  | Ok msg -> check string "channel lowercased and trimmed" "discord" msg.channel
  | Error e -> fail e

let test_inbound_of_json_with_metadata () =
  let json =
    `Assoc [
      ("channel", `String "slack");
      ("channel_user_id", `String "u1");
      ("channel_user_name", `String "carol");
      ("channel_room_id", `String "r1");
      ("keeper_name", `String "luna");
      ("content", `String "hey");
      ("idempotency_key", `String "k3");
      ("metadata", `Assoc [("x-channel-guild-id", `String "g1"); ("num", `Int 42)]);
    ]
  in
  match Gate_protocol.inbound_of_json json with
  | Ok msg ->
      check int "metadata has 1 string entry" 1 (List.length msg.metadata);
      check string "guild id" "g1" (List.assoc "x-channel-guild-id" msg.metadata)
  | Error e -> fail e

let test_inbound_of_json_invalid () =
  match Gate_protocol.inbound_of_json (`String "not an object") with
  | Error _ -> ()
  | Ok _ -> fail "expected parse error"

let test_inbound_of_json_accepts_destination_id () =
  let json =
    `Assoc [
      ("channel", `String "discord");
      ("channel_user_id", `String "u1");
      ("channel_user_name", `String "alice");
      ("channel_room_id", `String "r1");
      ("destination_id", `String "luna");
      ("content", `String "hi");
      ("idempotency_key", `String "k-dest");
    ]
  in
  match Gate_protocol.inbound_of_json json with
  | Ok msg -> check string "destination_id maps to keeper_name" "luna" msg.keeper_name
  | Error e -> fail e

let test_inbound_of_json_destination_id_wins_over_keeper_name () =
  let json =
    `Assoc [
      ("channel", `String "discord");
      ("channel_user_id", `String "u1");
      ("channel_user_name", `String "alice");
      ("channel_room_id", `String "r1");
      ("destination_id", `String "new-name");
      ("keeper_name", `String "legacy-name");
      ("content", `String "hi");
      ("idempotency_key", `String "k-both");
    ]
  in
  match Gate_protocol.inbound_of_json json with
  | Ok msg ->
      check string "destination_id takes precedence" "new-name" msg.keeper_name
  | Error e -> fail e

let test_inbound_of_json_keeper_name_still_works () =
  let json =
    `Assoc [
      ("channel", `String "discord");
      ("channel_user_id", `String "u1");
      ("channel_user_name", `String "alice");
      ("channel_room_id", `String "r1");
      ("keeper_name", `String "legacy-only");
      ("content", `String "hi");
      ("idempotency_key", `String "k-legacy");
    ]
  in
  match Gate_protocol.inbound_of_json json with
  | Ok msg ->
      check string "keeper_name alone still routes" "legacy-only" msg.keeper_name
  | Error e -> fail e

let test_outbound_emits_destination_id () =
  let out : Gate_protocol.outbound_message = {
    keeper_name = "luna";
    content = "hi";
    structured = None;
    turn_stats = None;
  } in
  let json = Gate_protocol.outbound_to_json out in
  let open Yojson.Safe.Util in
  check string "destination_id present" "luna" (json |> member "destination_id" |> to_string);
  (* B2 Phase 3 — legacy keeper_name key is no longer emitted. *)
  (match json |> member "keeper_name" with
   | `Null -> ()
   | _ -> fail "keeper_name should no longer be emitted")

let test_outbound_to_json_roundtrip () =
  let out : Gate_protocol.outbound_message = {
    keeper_name = "luna";
    content = "reply text";
    structured = None;
    turn_stats = Some { model_used = "m1"; duration_ms = 100; tokens_used = 50 };
  } in
  let json = Gate_protocol.outbound_to_json out in
  let open Yojson.Safe.Util in
  check bool "ok" true (json |> member "ok" |> to_bool);
  check string "reply" "reply text" (json |> member "reply" |> to_string);
  check string "destination_id" "luna" (json |> member "destination_id" |> to_string);
  let stats = json |> member "turn_stats" in
  check bool "model redacted" true (stats |> member "model_used" = `Null);
  check int "duration" 100 (stats |> member "duration_ms" |> to_int)

let test_error_json () =
  let json = Gate_protocol.error_json "something broke" in
  let open Yojson.Safe.Util in
  check bool "ok is false" false (json |> member "ok" |> to_bool);
  check string "error" "something broke" (json |> member "error" |> to_string)

(* ── String conversion tests ─────────────────────────────────── *)

let test_validation_error_strings () =
  check string "empty content" "content is required"
    (Gate_protocol.validation_error_to_string Gate_protocol.Empty_content);
  check string "empty keeper" "keeper_name is required"
    (Gate_protocol.validation_error_to_string Gate_protocol.Empty_keeper_name);
  check string "duplicate" "duplicate message (idempotency_key=k)"
    (Gate_protocol.validation_error_to_string (Gate_protocol.Duplicate_message "k"))

let test_gate_error_strings () =
  check string "keeper error" "keeper error: boom"
    (Gate_protocol.gate_error_to_string (Gate_protocol.Keeper_error "boom"));
  check string "unavailable" "keeper dispatch unavailable"
    (Gate_protocol.gate_error_to_string Gate_protocol.Dispatch_unavailable);
  check string "internal" "internal error"
    (Gate_protocol.gate_error_to_string (Gate_protocol.Internal "details"))

let () =
  Alcotest.run "Gate_protocol"
    [
      ( "validate",
        [
          test_case "accepts valid" `Quick test_validate_ok;
          test_case "rejects empty content" `Quick test_validate_empty_content;
          test_case "rejects too-long content" `Quick test_validate_content_too_long;
          test_case "rejects empty keeper" `Quick test_validate_empty_keeper_name;
          test_case "rejects empty user_id" `Quick test_validate_empty_user_id;
          test_case "rejects empty idempotency_key" `Quick test_validate_empty_idempotency_key;
          test_case "rejects duplicate" `Quick test_validate_duplicate;
          test_case "keeper checked before content" `Quick test_validate_keeper_name_checked_before_content;
        ] );
      ( "json",
        [
          test_case "inbound basic" `Quick test_inbound_of_json_basic;
          test_case "inbound normalizes case" `Quick test_inbound_of_json_normalizes_case;
          test_case "inbound with metadata" `Quick test_inbound_of_json_with_metadata;
          test_case "inbound invalid" `Quick test_inbound_of_json_invalid;
          test_case "inbound accepts destination_id" `Quick test_inbound_of_json_accepts_destination_id;
          test_case "destination_id wins over keeper_name" `Quick test_inbound_of_json_destination_id_wins_over_keeper_name;
          test_case "inbound keeper_name still works" `Quick test_inbound_of_json_keeper_name_still_works;
          test_case "outbound emits destination_id" `Quick test_outbound_emits_destination_id;
          test_case "outbound roundtrip" `Quick test_outbound_to_json_roundtrip;
          test_case "error_json" `Quick test_error_json;
        ] );
      ( "strings",
        [
          test_case "validation error strings" `Quick test_validation_error_strings;
          test_case "gate error strings" `Quick test_gate_error_strings;
        ] );
    ]
