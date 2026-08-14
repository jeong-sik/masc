(* RFC-0378 §5.1 — the address parse boundary.

   Feature under test: every slug the attribution path can emit is
   constructible into a [Code_address.t], two transport spellings of the
   same remote mint the same address, and every shape the partitioned
   store cannot join on is rejected at mint time instead of landing as an
   unreadable record. *)

module A = Agent_observation.Code_address

let check_ok ~codebase ~path () =
  match A.v ~codebase ~path with
  | Ok addr ->
    Alcotest.(check string) "codebase" codebase (A.codebase addr);
    Alcotest.(check string) "path" path (A.path addr)
  | Error e -> Alcotest.failf "expected Ok, got %s" (A.invalid_to_string e)
;;

let check_rejected ~codebase ~path expected () =
  match A.v ~codebase ~path with
  | Ok _ -> Alcotest.fail "expected rejection"
  | Error e ->
    Alcotest.(check string)
      "reason"
      (A.invalid_to_string expected)
      (A.invalid_to_string e)
;;

let slug_of remote =
  match Agent_observation.canonical_url_of_remote remote with
  | Some s -> s
  | None -> Alcotest.failf "canonical_url_of_remote rejected %s" remote
;;

let test_resolver_output_is_always_constructible () =
  check_ok
    ~codebase:(slug_of "https://github.com/jeong-sik/masc.git")
    ~path:"lib/ide/ide_paths.ml"
    ()
;;

let test_transport_spellings_mint_the_same_address () =
  let a = A.v ~codebase:(slug_of "git@github.com:jeong-sik/masc.git") ~path:"lib/x.ml" in
  let b = A.v ~codebase:(slug_of "https://github.com/jeong-sik/masc") ~path:"lib/x.ml" in
  match a, b with
  | Ok a, Ok b -> Alcotest.(check bool) "same address" true (A.equal a b)
  | _ -> Alcotest.fail "construction failed"
;;

let () =
  Alcotest.run
    "code_address"
    [ ( "mint"
      , [ Alcotest.test_case
            "resolver output constructs"
            `Quick
            test_resolver_output_is_always_constructible
        ; Alcotest.test_case
            "transport-independent join"
            `Quick
            test_transport_spellings_mint_the_same_address
        ; Alcotest.test_case
            "valid literal"
            `Quick
            (check_ok ~codebase:"github.com_jeong-sik_masc" ~path:"lib/ide/ide_paths.ml")
        ] )
    ; ( "reject"
      , [ Alcotest.test_case
            "absolute path"
            `Quick
            (check_rejected ~codebase:"github.com_x_y" ~path:"/etc/passwd" A.Absolute_path)
        ; Alcotest.test_case
            "dotdot segment"
            `Quick
            (check_rejected
               ~codebase:"github.com_x_y"
               ~path:"lib/../secrets"
               A.Unnormalized_path)
        ; Alcotest.test_case
            "dot segment"
            `Quick
            (check_rejected ~codebase:"github.com_x_y" ~path:"./lib/x.ml" A.Unnormalized_path)
        ; Alcotest.test_case
            "empty segment"
            `Quick
            (check_rejected ~codebase:"github.com_x_y" ~path:"lib//x.ml" A.Unnormalized_path)
        ; Alcotest.test_case
            "trailing slash"
            `Quick
            (check_rejected ~codebase:"github.com_x_y" ~path:"lib/" A.Unnormalized_path)
        ; Alcotest.test_case
            "empty path"
            `Quick
            (check_rejected ~codebase:"github.com_x_y" ~path:"" A.Empty_path)
        ; Alcotest.test_case
            "NUL byte"
            `Quick
            (check_rejected
               ~codebase:"github.com_x_y"
               ~path:"lib/\x00secret.ml"
               A.Malformed_path)
        ; Alcotest.test_case
            "empty codebase"
            `Quick
            (check_rejected ~codebase:"" ~path:"lib/x.ml" A.Empty_codebase)
        ; Alcotest.test_case
            "uppercase codebase"
            `Quick
            (check_rejected ~codebase:"GitHub.com_x" ~path:"lib/x.ml" A.Malformed_codebase)
        ; Alcotest.test_case
            "slash in codebase"
            `Quick
            (check_rejected ~codebase:"github.com/x" ~path:"lib/x.ml" A.Malformed_codebase)
        ; Alcotest.test_case
            "dot codebase"
            `Quick
            (check_rejected ~codebase:"." ~path:"lib/x.ml" A.Malformed_codebase)
        ; Alcotest.test_case
            "bare token codebase"
            `Quick
            (check_rejected ~codebase:"github" ~path:"lib/x.ml" A.Malformed_codebase)
        ; Alcotest.test_case
            "separator without host and path"
            `Quick
            (check_rejected ~codebase:"_" ~path:"lib/x.ml" A.Malformed_codebase)
        ; Alcotest.test_case
            "orphan partition is not a codebase"
            `Quick
            (check_rejected ~codebase:"_orphan" ~path:"lib/x.ml" A.Malformed_codebase)
        ; Alcotest.test_case
            "separator without repository path"
            `Quick
            (check_rejected ~codebase:"github.com_" ~path:"lib/x.ml" A.Malformed_codebase)
        ; Alcotest.test_case
            "single joined repository segment cannot start with dotdot"
            `Quick
            (check_rejected ~codebase:"a_..repo" ~path:"lib/x.ml" A.Malformed_codebase)
        ] )
    ]
;;
