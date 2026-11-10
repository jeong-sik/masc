open Alcotest

module Inv = Keeper_invariant

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

let test_sandbox_isolation_root_slash () =
  (* Regression for the prefix="//" degenerate case: when root is "/", every
     absolute path must be treated as in-sandbox. *)
  let roots = ["/"] in
  let paths = ["/etc/passwd"; "/tmp/file"; "/"] in
  require_ok "root slash"
    (Inv.sandbox_isolation ~sandbox_roots:roots ~sandbox_paths:paths)

(* Sibling-prefix safety: /srv/.../alice-evil/ must NOT satisfy root
   /srv/.../alice/. This is what the trailing-slash trick on the root
   protects against. Without it, a hostile sibling directory whose name
   shares a literal prefix with a legitimate keeper's root would slip
   through the prefix check. *)
let test_sandbox_isolation_sibling_prefix_rejected () =
  let roots = ["/srv/masc/keepers/alice"] in
  let paths = ["/srv/masc/keepers/alice-evil/leak.txt"] in
  require_error "sibling prefix rejected"
    (Inv.sandbox_isolation ~sandbox_roots:roots ~sandbox_paths:paths)

(* Path-traversal safety: `..` segments are collapsed before the prefix
   check, so /srv/.../alice/../../etc/passwd cannot escape its root.
   This guards [normalize_path] from being quietly removed in a future
   refactor. *)
let test_sandbox_isolation_path_traversal_rejected () =
  let roots = ["/srv/masc/keepers/alice"] in
  let paths = ["/srv/masc/keepers/alice/../../etc/passwd"] in
  require_error "path traversal rejected"
    (Inv.sandbox_isolation ~sandbox_roots:roots ~sandbox_paths:paths)

let () =
  run "Keeper Invariant"
    [
      ( "sandbox_isolation",
        [
          test_case "ok" `Quick test_sandbox_isolation_ok;
          test_case "violation" `Quick test_sandbox_isolation_violation;
          test_case "multi_root" `Quick test_sandbox_isolation_multi_root;
          test_case "empty_roots" `Quick test_sandbox_isolation_empty_roots;
          test_case "sibling_prefix_rejected" `Quick
            test_sandbox_isolation_sibling_prefix_rejected;
          test_case "path_traversal_rejected" `Quick
            test_sandbox_isolation_path_traversal_rejected;
          test_case "root_slash" `Quick test_sandbox_isolation_root_slash;
        ] );
    ]
