open Alcotest

module Inv = Masc_mcp.Keeper_invariant

let require_ok label = function
  | Ok () -> ()
  | Error msg -> failf "%s: %s" label msg

let require_error label = function
  | Ok () -> failf "%s: expected error but got Ok" label
  | Error _ -> ()

(* ================================================================ *)
(* sandbox_isolation tests                                          *)
(* ================================================================ *)

let test_sandbox_isolation_ok () =
  let roots = ["/tmp/masc_sandbox_turn_1"] in
  let paths =
    ["/tmp/masc_sandbox_turn_1/foo.ml"; "/tmp/masc_sandbox_turn_1/bar/baz.ml"]
  in
  require_ok "sandbox ok" (Inv.sandbox_isolation ~sandbox_roots:roots ~sandbox_paths:paths)

let test_sandbox_isolation_violation () =
  let roots = ["/tmp/masc_sandbox_turn_1"] in
  let paths = ["/tmp/masc_sandbox_turn_1/foo.ml"; "/etc/passwd"] in
  require_error "sandbox violation" (Inv.sandbox_isolation ~sandbox_roots:roots ~sandbox_paths:paths)

let test_sandbox_isolation_multi_root () =
  let roots = ["/tmp/masc_sandbox_turn_1"; "/var/lib/masc/sandbox/turn_2"] in
  let paths = ["/var/lib/masc/sandbox/turn_2/file.ml"] in
  require_ok "multi root" (Inv.sandbox_isolation ~sandbox_roots:roots ~sandbox_paths:paths)

let test_sandbox_isolation_empty_roots () =
  let roots = [] in
  let paths = ["/tmp/masc_sandbox_turn_1/foo.ml"] in
  require_error "empty roots" (Inv.sandbox_isolation ~sandbox_roots:roots ~sandbox_paths:paths)

(* ================================================================ *)
(* credential_isolation tests                                         *)
(* ================================================================ *)

let test_credential_isolation_ok () =
  let credential = { Inv.keeper_id = "keeper_a"; github_account = "gh_a" } in
  let others = [{ Inv.keeper_id = "keeper_b"; github_account = "gh_b" }] in
  require_ok "credential ok"
    (Inv.credential_isolation ~keeper:"keeper_a" ~credential ~other_keepers:others)

let test_credential_isolation_violation () =
  let credential = { Inv.keeper_id = "keeper_a"; github_account = "gh_a" } in
  let others = [{ Inv.keeper_id = "keeper_a"; github_account = "gh_a" }] in
  require_error "credential violation"
    (Inv.credential_isolation ~keeper:"keeper_a" ~credential ~other_keepers:others)

let test_credential_isolation_same_keeper_diff_account () =
  let credential = { Inv.keeper_id = "keeper_a"; github_account = "gh_a" } in
  let others = [{ Inv.keeper_id = "keeper_a"; github_account = "gh_b" }] in
  require_ok "same keeper diff account"
    (Inv.credential_isolation ~keeper:"keeper_a" ~credential ~other_keepers:others)

(* ================================================================ *)
(* tool_surface_monotonicity tests                                    *)
(* ================================================================ *)

let test_tool_monotonicity_ok () =
  let before = ["tool_a"; "tool_b"; "tool_c"] in
  let after = ["tool_a"; "tool_b"] in
  require_ok "tool ok" (Inv.tool_surface_monotonicity ~before ~after)

let test_tool_monotonicity_equal () =
  let before = ["tool_a"; "tool_b"] in
  let after = ["tool_b"; "tool_a"] in
  require_ok "tool equal" (Inv.tool_surface_monotonicity ~before ~after)

let test_tool_monotonicity_violation () =
  let before = ["tool_a"; "tool_b"] in
  let after = ["tool_a"; "tool_b"; "tool_c"] in
  require_error "tool violation" (Inv.tool_surface_monotonicity ~before ~after)

(* ================================================================ *)
(* check_all tests                                                    *)
(* ================================================================ *)

let test_check_all_ok () =
  let roots = ["/tmp/masc_sandbox_turn_1"] in
  let paths = ["/tmp/masc_sandbox_turn_1/foo.ml"] in
  let credential = { Inv.keeper_id = "keeper_a"; github_account = "gh_a" } in
  let others = [{ Inv.keeper_id = "keeper_b"; github_account = "gh_b" }] in
  let before_tools = ["tool_a"] in
  let after_tools = ["tool_a"] in
  require_ok "check_all ok"
    (Inv.check_all ~sandbox_roots:roots ~sandbox_paths:paths ~keeper:"keeper_a"
       ~credential ~other_keepers:others ~before_tools ~after_tools)

let test_check_all_first_error () =
  let roots = ["/tmp/masc_sandbox_turn_1"] in
  let paths = ["/etc/passwd"] in
  let credential = { Inv.keeper_id = "keeper_a"; github_account = "gh_a" } in
  let others = [] in
  let before_tools = ["tool_a"] in
  let after_tools = ["tool_a"] in
  let result =
    Inv.check_all ~sandbox_roots:roots ~sandbox_paths:paths ~keeper:"keeper_a"
      ~credential ~other_keepers:others ~before_tools ~after_tools
  in
  match result with
  | Ok () -> failf "check_all first error: expected sandbox error"
  | Error msg ->
    if String.starts_with ~prefix:"Sandbox isolation" msg then ()
    else failf "check_all first error: expected sandbox error, got: %s" msg

let () =
  run "Keeper Invariant"
    [
      ( "sandbox_isolation",
        [
          test_case "ok" `Quick test_sandbox_isolation_ok;
          test_case "violation" `Quick test_sandbox_isolation_violation;
          test_case "multi_root" `Quick test_sandbox_isolation_multi_root;
          test_case "empty_roots" `Quick test_sandbox_isolation_empty_roots;
        ] );
      ( "credential_isolation",
        [
          test_case "ok" `Quick test_credential_isolation_ok;
          test_case "violation" `Quick test_credential_isolation_violation;
          test_case "same_keeper_diff_account" `Quick
            test_credential_isolation_same_keeper_diff_account;
        ] );
      ( "tool_surface_monotonicity",
        [
          test_case "ok" `Quick test_tool_monotonicity_ok;
          test_case "equal" `Quick test_tool_monotonicity_equal;
          test_case "violation" `Quick test_tool_monotonicity_violation;
        ] );
      ( "check_all",
        [
          test_case "ok" `Quick test_check_all_ok;
          test_case "first_error" `Quick test_check_all_first_error;
        ] );
    ]
