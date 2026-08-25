(* The repeated-call yield compares these fingerprints, so what they hash is
   behavior: a measurement field in the output must not break identity, and a
   changed answer must. The live shape this pins: a keeper ran [gh auth status]
   four times in one run and the four results differed only at
   execution_time_ms, so the yield never saw the loop (2026-08-24). *)

open Alcotest
module P = Masc.Keeper_tool_progress_identity

let fingerprints ~output =
  match
    P.digest_tool_io ~tool_name:"Execute"
      ~input:(`Assoc [ ("argv", `List [ `String "gh"; `String "auth" ]) ])
      ~output_text:output
  with
  | Some io -> io
  | None -> fail "digest_tool_io returned no fingerprints"

let execute_payload ~elapsed_ms ~stdout =
  Printf.sprintf
    {|{"ok":true,"status":{"kind":"exit","code":0},"output":%S,"typed":true,"execution_time_ms":%d}|}
    stdout elapsed_ms

let test_measurement_does_not_name_identity () =
  let a = fingerprints ~output:(execute_payload ~elapsed_ms:1170 ~stdout:"logged in") in
  let b = fingerprints ~output:(execute_payload ~elapsed_ms:1471 ~stdout:"logged in") in
  check string "same answer, different measurement: same fingerprint"
    a.P.output_fingerprint b.P.output_fingerprint

let test_nested_measurement_is_dropped_too () =
  let shape ms =
    Printf.sprintf
      {|{"ok":true,"steps":[{"cmd":"a","execution_time_ms":%d}],"output":"x"}|} ms
  in
  let a = fingerprints ~output:(shape 10) in
  let b = fingerprints ~output:(shape 99) in
  check string "nested measurement dropped" a.P.output_fingerprint
    b.P.output_fingerprint

let test_a_changed_answer_changes_identity () =
  let a = fingerprints ~output:(execute_payload ~elapsed_ms:5 ~stdout:"branch main") in
  let b = fingerprints ~output:(execute_payload ~elapsed_ms:5 ~stdout:"branch dev") in
  check bool "different stdout: different fingerprint" false
    (String.equal a.P.output_fingerprint b.P.output_fingerprint)

let test_field_order_does_not_name_identity () =
  let a = fingerprints ~output:{|{"ok":true,"status":"exit"}|} in
  let b = fingerprints ~output:{|{"status":"exit","ok":true}|} in
  check string "canonicalized order" a.P.output_fingerprint b.P.output_fingerprint

let test_non_json_output_keeps_the_byte_hash () =
  let a = fingerprints ~output:"plain text answer" in
  let b = fingerprints ~output:"plain text answer" in
  let c = fingerprints ~output:"plain text different" in
  check string "equal text: equal fingerprint" a.P.output_fingerprint
    b.P.output_fingerprint;
  check bool "different text: different fingerprint" false
    (String.equal a.P.output_fingerprint c.P.output_fingerprint)

let () =
  run "keeper_tool_progress_identity"
    [ ( "identity"
      , [ test_case "measurement does not name identity" `Quick
            test_measurement_does_not_name_identity
        ; test_case "nested measurement is dropped too" `Quick
            test_nested_measurement_is_dropped_too
        ; test_case "a changed answer changes identity" `Quick
            test_a_changed_answer_changes_identity
        ; test_case "field order does not name identity" `Quick
            test_field_order_does_not_name_identity
        ; test_case "non-JSON output keeps the byte hash" `Quick
            test_non_json_output_keeps_the_byte_hash
        ] )
    ]
