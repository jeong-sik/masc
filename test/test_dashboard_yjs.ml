module DY = Masc_mcp.Dashboard_yjs

let byte_codes s =
  List.init (String.length s) (fun i -> Char.code s.[i])

let check_frame name payload expected_prefix =
  let frame = DY.frame_update payload in
  let expected = expected_prefix @ byte_codes payload in
  Alcotest.(check (list int)) name expected (byte_codes frame)

let test_empty_payload () =
  check_frame "empty payload frame" "" [ 0; 2; 0 ]

let test_small_payload () =
  check_frame "small payload frame" "abc" [ 0; 2; 3 ]

let test_multibyte_varint_payload () =
  let payload = String.make 130 'x' in
  check_frame "130-byte payload frame" payload [ 0; 2; 0x82; 0x01 ]

let () =
  Alcotest.run "dashboard_yjs"
    [
      ( "frame_update",
        [
          Alcotest.test_case "empty payload" `Quick test_empty_payload;
          Alcotest.test_case "small payload" `Quick test_small_payload;
          Alcotest.test_case "multi-byte varint payload" `Quick
            test_multibyte_varint_payload;
        ] );
    ]
