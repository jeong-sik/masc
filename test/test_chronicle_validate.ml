(** Chronicle_validate — validation tests.
    Uses git_capture_hook_for_tests for isolated mock git output.
    @since Project Chronicle Phase 4 *)

open Alcotest

module CV = Masc_mcp.Chronicle_validate
module CT = Masc_mcp.Chronicle_types

(* --- Helpers --- *)

let epoch ?(key_files = []) ?(rfc_refs = [])
    ?(start_commit = "abc123") ?(end_commit = "def456") () =
  { CT.id = "test-epoch"
  ; CT.label = "Test Epoch"
  ; CT.repo = "test-repo"
  ; CT.start_date = "2026-01-01"
  ; CT.end_date = "2026-01-15"
  ; CT.start_commit
  ; CT.end_commit
  ; CT.goal_ids = [ "TEST-1" ]
  ; CT.status = CT.Completed
  ; CT.causation = []
  ; CT.outcomes_achieved = [ "built feature" ]
  ; CT.outcomes_failed = []
  ; CT.lessons = []
  ; CT.key_files
  ; CT.rfc_refs
  ; CT.historian_validated_at = None
  }

(* --- SHA check tests --- *)

let test_sha_both_exist () =
  let mock_hook ~workdir:_ = function
    | [ "cat-file"; "-t"; "abc123" ] ->
      Some (Unix.WEXITED 0, "commit\n")
    | [ "cat-file"; "-t"; "def456" ] ->
      Some (Unix.WEXITED 0, "commit\n")
    | _ -> None
  in
  CV.set_git_capture_hook_for_tests mock_hook;
  Fun.protect
    ~finally:(fun () -> CV.clear_git_capture_hook_for_tests ())
    (fun () ->
      let result =
        CV.validate_epoch ~workdir:"/fake/repo" (epoch ())
      in
      check bool "sha_check" true result.CV.sha_check;
      check bool "is_valid" true result.CV.is_valid;
      check int "no warnings" 0 (List.length result.CV.warnings))

let test_sha_start_missing () =
  let mock_hook ~workdir:_ = function
    | [ "cat-file"; "-t"; "bad000" ] ->
      Some (Unix.WEXITED 128, "fatal: Not a valid object\n")
    | [ "cat-file"; "-t"; "def456" ] ->
      Some (Unix.WEXITED 0, "commit\n")
    | _ -> None
  in
  CV.set_git_capture_hook_for_tests mock_hook;
  Fun.protect
    ~finally:(fun () -> CV.clear_git_capture_hook_for_tests ())
    (fun () ->
      let result =
        CV.validate_epoch ~workdir:"/fake/repo"
          (epoch ~start_commit:"bad000" ())
      in
      check bool "sha_check" false result.CV.sha_check;
      check bool "is_valid" false result.CV.is_valid;
      check bool "has warnings" true
        (List.length result.CV.warnings > 0))

let test_sha_end_missing () =
  let mock_hook ~workdir:_ = function
    | [ "cat-file"; "-t"; "abc123" ] ->
      Some (Unix.WEXITED 0, "commit\n")
    | [ "cat-file"; "-t"; "bad999" ] ->
      Some (Unix.WEXITED 128, "fatal: Not a valid object\n")
    | _ -> None
  in
  CV.set_git_capture_hook_for_tests mock_hook;
  Fun.protect
    ~finally:(fun () -> CV.clear_git_capture_hook_for_tests ())
    (fun () ->
      let result =
        CV.validate_epoch ~workdir:"/fake/repo"
          (epoch ~end_commit:"bad999" ())
      in
      check bool "sha_check" false result.CV.sha_check;
      check bool "is_valid" false result.CV.is_valid)

(* --- File range check tests --- *)

let test_file_range_all_covered () =
  let mock_hook ~workdir:_ = function
    | [ "cat-file"; "-t"; _ ] ->
      Some (Unix.WEXITED 0, "commit\n")
    | [ "diff"; "--name-only"; "abc123..def456" ] ->
      Some (Unix.WEXITED 0, "lib/foo.ml\nlib/bar.ml\nlib/baz.ml\n")
    | _ -> None
  in
  CV.set_git_capture_hook_for_tests mock_hook;
  Fun.protect
    ~finally:(fun () -> CV.clear_git_capture_hook_for_tests ())
    (fun () ->
      let ep =
        epoch
          ~key_files:
            [ { CT.path = "lib/foo.ml"; CT.role = "source" }
            ; { CT.path = "lib/bar.ml"; CT.role = "source" }
            ]
          ()
      in
      let result = CV.validate_epoch ~workdir:"/fake/repo" ep in
      check bool "file_range_check" true result.CV.file_range_check;
      check bool "is_valid" true result.CV.is_valid)

let test_file_range_missing () =
  let mock_hook ~workdir:_ = function
    | [ "cat-file"; "-t"; _ ] ->
      Some (Unix.WEXITED 0, "commit\n")
    | [ "diff"; "--name-only"; "abc123..def456" ] ->
      Some (Unix.WEXITED 0, "lib/foo.ml\n")
    | _ -> None
  in
  CV.set_git_capture_hook_for_tests mock_hook;
  Fun.protect
    ~finally:(fun () -> CV.clear_git_capture_hook_for_tests ())
    (fun () ->
      let ep =
        epoch
          ~key_files:
            [ { CT.path = "lib/foo.ml"; CT.role = "source" }
            ; { CT.path = "lib/missing.ml"; CT.role = "source" }
            ]
          ()
      in
      let result = CV.validate_epoch ~workdir:"/fake/repo" ep in
      check bool "file_range_check" false result.CV.file_range_check;
      check bool "is_valid" false result.CV.is_valid)

let test_file_range_no_key_files () =
  let mock_hook ~workdir:_ = function
    | [ "cat-file"; "-t"; _ ] ->
      Some (Unix.WEXITED 0, "commit\n")
    | _ -> None
  in
  CV.set_git_capture_hook_for_tests mock_hook;
  Fun.protect
    ~finally:(fun () -> CV.clear_git_capture_hook_for_tests ())
    (fun () ->
      let ep = epoch ~key_files:[] () in
      let result = CV.validate_epoch ~workdir:"/fake/repo" ep in
      check bool "file_range_check passes" true
        result.CV.file_range_check)

let test_file_range_single_commit () =
  let mock_hook ~workdir:_ = function
    | [ "cat-file"; "-t"; _ ] ->
      Some (Unix.WEXITED 0, "commit\n")
    | [ "show"; "--name-only"; "--pretty=format:"; "same123" ] ->
      Some (Unix.WEXITED 0, "\nlib/core.ml\nlib/helper.ml\n")
    | _ -> None
  in
  CV.set_git_capture_hook_for_tests mock_hook;
  Fun.protect
    ~finally:(fun () -> CV.clear_git_capture_hook_for_tests ())
    (fun () ->
      let ep =
        epoch ~start_commit:"same123" ~end_commit:"same123"
          ~key_files:[ { CT.path = "lib/core.ml"; CT.role = "source" } ]
          ()
      in
      let result = CV.validate_epoch ~workdir:"/fake/repo" ep in
      check bool "file_range_check" true result.CV.file_range_check)

(* --- Score tests --- *)

let test_score_perfect () =
  let mock_hook ~workdir:_ = function
    | [ "cat-file"; "-t"; _ ] ->
      Some (Unix.WEXITED 0, "commit\n")
    | _ -> Some (Unix.WEXITED 0, "")
  in
  CV.set_git_capture_hook_for_tests mock_hook;
  Fun.protect
    ~finally:(fun () -> CV.clear_git_capture_hook_for_tests ())
    (fun () ->
      let ep = epoch () in
      let result = CV.validate_epoch ~workdir:"/fake/repo" ep in
      (* sha=0.3 + file=0.3 + rfc_neutral=0.4 = 1.0 *)
      check bool "score >= 0.9" true
        (result.CV.verification_score >= 0.9))

let test_score_all_fail () =
  let mock_hook ~workdir:_ = function
    | [ "cat-file"; "-t"; _ ] ->
      Some (Unix.WEXITED 1, "")
    | _ -> None
  in
  CV.set_git_capture_hook_for_tests mock_hook;
  Fun.protect
    ~finally:(fun () -> CV.clear_git_capture_hook_for_tests ())
    (fun () ->
      let ep =
        epoch ~key_files:[ { CT.path = "lib/foo.ml"; CT.role = "source" } ]
          ~rfc_refs:[ "RFC-0001" ] ()
      in
      let result = CV.validate_epoch ~workdir:"/fake/repo" ep in
      (* sha=0.0 + file=0.0 + rfc=0.0 = 0.0 *)
      check bool "is_valid" false result.CV.is_valid;
      check bool "score ~0.0" true
        (result.CV.verification_score < 0.01))

(* --- RFC refs tests --- *)

let test_rfc_refs_empty () =
  let mock_hook ~workdir:_ = function
    | [ "cat-file"; "-t"; _ ] ->
      Some (Unix.WEXITED 0, "commit\n")
    | _ -> Some (Unix.WEXITED 0, "")
  in
  CV.set_git_capture_hook_for_tests mock_hook;
  Fun.protect
    ~finally:(fun () -> CV.clear_git_capture_hook_for_tests ())
    (fun () ->
      let ep = epoch ~rfc_refs:[] () in
      let result = CV.validate_epoch ~workdir:"/fake/repo" ep in
      check int "empty rfc_refs_valid" 0
        (List.length result.CV.rfc_refs_valid))

let test_rfc_refs_nonexistent () =
  let mock_hook ~workdir:_ = function
    | [ "cat-file"; "-t"; _ ] ->
      Some (Unix.WEXITED 0, "commit\n")
    | _ -> Some (Unix.WEXITED 0, "")
  in
  CV.set_git_capture_hook_for_tests mock_hook;
  Fun.protect
    ~finally:(fun () -> CV.clear_git_capture_hook_for_tests ())
    (fun () ->
      let ep = epoch ~rfc_refs:[ "RFC-0001" ] () in
      let result = CV.validate_epoch ~workdir:"/fake/repo" ep in
      check int "1 rfc ref" 1 (List.length result.CV.rfc_refs_valid);
      check bool "rfc not found" false
        (List.hd result.CV.rfc_refs_valid);
      check bool "has rfc warning" true
        (List.length result.CV.warnings > 0))

(* --- Test runner --- *)

let () =
  run "Chronicle_validate"
    [ ( "sha_check",
        [ test_case "both exist" `Quick test_sha_both_exist
        ; test_case "start missing" `Quick test_sha_start_missing
        ; test_case "end missing" `Quick test_sha_end_missing
        ] )
    ; ( "file_range_check",
        [ test_case "all covered" `Quick test_file_range_all_covered
        ; test_case "missing file" `Quick test_file_range_missing
        ; test_case "no key files" `Quick test_file_range_no_key_files
        ; test_case "single commit" `Quick test_file_range_single_commit
        ] )
    ; ( "score",
        [ test_case "perfect score" `Quick test_score_perfect
        ; test_case "all fail" `Quick test_score_all_fail
        ] )
    ; ( "rfc_refs",
        [ test_case "empty refs" `Quick test_rfc_refs_empty
        ; test_case "nonexistent" `Quick test_rfc_refs_nonexistent
        ] )
    ]
