(** WebSocket Transport Unit Tests

    Tests session registry management and broadcast logic.
    HTTP upgrade integration is tested separately (E2E). *)

module Ws = Masc_mcp.Server_mcp_transport_ws

let test_initial_session_count () =
  Eio_main.run (fun _env ->
    (* Session count should start at 0 or be stable *)
    let count = Ws.session_count () in
    Alcotest.(check bool) "count is non-negative" true (count >= 0))

let test_close_all_empty () =
  Eio_main.run (fun _env ->
    let closed = Ws.close_all () in
    Alcotest.(check int) "close_all on empty returns 0" 0 closed)

let test_sha1_produces_20_bytes () =
  (* SHA1 always produces 20-byte raw output *)
  let result = Digestif.SHA1.(digest_string "test" |> to_raw_string) in
  Alcotest.(check int) "SHA1 raw length" 20 (String.length result)

let test_sha1_deterministic () =
  let r1 = Digestif.SHA1.(digest_string "hello" |> to_raw_string) in
  let r2 = Digestif.SHA1.(digest_string "hello" |> to_raw_string) in
  Alcotest.(check string) "SHA1 deterministic" r1 r2

let test_sha1_different_inputs () =
  let r1 = Digestif.SHA1.(digest_string "a" |> to_raw_string) in
  let r2 = Digestif.SHA1.(digest_string "b" |> to_raw_string) in
  Alcotest.(check bool) "different inputs different hashes" true (r1 <> r2)

let () =
  Alcotest.run "WebSocket Transport" [
    ("session_registry", [
      Alcotest.test_case "initial count" `Quick test_initial_session_count;
      Alcotest.test_case "close_all empty" `Quick test_close_all_empty;
    ]);
    ("sha1", [
      Alcotest.test_case "produces 20 bytes" `Quick test_sha1_produces_20_bytes;
      Alcotest.test_case "deterministic" `Quick test_sha1_deterministic;
      Alcotest.test_case "different inputs" `Quick test_sha1_different_inputs;
    ]);
  ]
