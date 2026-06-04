open Alcotest

let test_valid_safe_sh () =
  let result = [%safe_sh "ls"] in
  match result with
  | Ok (Typed_capabilities.Safe_IR _) ->
      Alcotest.(check bool) "is safe IR" true true
  | Error _ ->
      Alcotest.fail "Expected Ok, got Error"

let () =
  run "ppx_safe_shell" [
    "valid", [
      test_case "safe_sh ls" `Quick test_valid_safe_sh;
    ];
  ]
