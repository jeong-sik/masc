(** Regression tests for [Keeper_checkpoint_store.is_not_found_detail]
    and [classify_sdk_error] (#6654 follow-up).

    Background: on 2026-04-12 /loop observed a keeper logging 334
    copies of [OAS checkpoint I/O error: file load failed on
    trace-1775487505102-6a347: Eio.Io Fs Not_found Unix_error (No such
    file or directory, "openat", ...)] in a tight retry loop. The
    expected behavior for a missing trace checkpoint is a silent
    [Not_found] classification so the keeper either takes a cold boot
    path or moves on. Instead the classifier fell through to
    [Io_error], which [keeper_context_core.ml] treats as a non-trivial
    failure worth logging at every retry.

    Root cause: [Agent_sdk.Error.FileOpFailed.detail] is populated by
    [Printexc.to_string] in [oas/lib/fs_result.ml], so an Eio filesystem
    ENOENT renders as literally [Eio.Io Fs Not_found Unix_error ...].
    [is_not_found_detail] only matched three legacy prefixes
    ([no_such_file], [no such file], [unix_error (enoent]) and never
    recognized the rendered Eio exception string.

    These tests lock the classifier to:
    - the three legacy prefixes (regression guard)
    - the Eio.Io rendered form observed in production
    - a canonical "no such file or directory" substring anywhere in
      the detail (robust against wrapper layers prepending context) *)

module Store = Masc_mcp.Keeper_checkpoint_store

let check_not_found name detail =
  Alcotest.(check bool) name true (Store.is_not_found_detail detail)

let check_not_classified_as_not_found name detail =
  Alcotest.(check bool) name false (Store.is_not_found_detail detail)

(* ─── Legacy prefixes (regression guard) ─────────────────────── *)

let test_legacy_no_such_file_prefix () =
  check_not_found "no_such_file underscore prefix (legacy)"
    "no_such_file: trace-xyz"

let test_legacy_no_such_file_space_prefix () =
  check_not_found "no such file prefix"
    "No such file or directory"

let test_legacy_unix_error_prefix () =
  check_not_found "unix_error(enoent prefix (POSIX)"
    "Unix_error (ENOENT, \"openat\", \"/tmp/x\")"

(* ─── Regression: Eio.Io rendered form from Printexc ─────────── *)

let test_eio_io_fs_not_found_rendered () =
  (* Exact detail string observed in /tmp/masc-6647-restart2.log for
     trace-1775487505102-6a347 — the keeper looping fix target. *)
  check_not_found
    "Eio.Io Fs Not_found Unix_error rendered by Printexc.to_string"
    "Eio.Io Fs Not_found Unix_error (No such file or directory, \
     \"openat\", \"/Users/dancer/me/.masc/traces/trace-123/trace-123.json\"), \
     \n  opening <fs:/Users/dancer/me/.masc/traces/trace-123/trace-123.json>"

(* ─── Substring fallback: wrapper layers may prepend context ──── *)

let test_substring_embedded_no_such_file () =
  check_not_found
    "substring match for 'no such file or directory' anywhere in detail"
    "load trace-abc: wrapped error: Sys_error \
     \"/path/trace.json: No such file or directory\""

(* ─── Negative cases ─────────────────────────────────────────── *)

let test_parse_error_not_misclassified () =
  check_not_classified_as_not_found
    "JSON parse error must stay classified as Parse_error"
    "JSON error: Unexpected end of input"

let test_permission_denied_not_misclassified () =
  check_not_classified_as_not_found
    "permission denied must stay classified as Io_error"
    "Unix_error (EACCES, \"openat\", \"/path/trace.json\")"

let () =
  Alcotest.run "Keeper_checkpoint_classify"
    [
      ( "is_not_found_detail",
        [
          Alcotest.test_case "legacy no_such_file underscore prefix" `Quick
            test_legacy_no_such_file_prefix;
          Alcotest.test_case "legacy 'No such file' prefix" `Quick
            test_legacy_no_such_file_space_prefix;
          Alcotest.test_case "legacy Unix_error(ENOENT prefix" `Quick
            test_legacy_unix_error_prefix;
          Alcotest.test_case
            "Eio.Io Fs Not_found Unix_error rendered (regression)"
            `Quick test_eio_io_fs_not_found_rendered;
          Alcotest.test_case
            "'no such file or directory' substring match" `Quick
            test_substring_embedded_no_such_file;
          Alcotest.test_case "JSON parse error not misclassified" `Quick
            test_parse_error_not_misclassified;
          Alcotest.test_case "EACCES not misclassified" `Quick
            test_permission_denied_not_misclassified;
        ] );
    ]
