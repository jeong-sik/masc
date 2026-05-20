(** RFC-0154 PR-1.  Unit tests for the typed System_error_class SSOT.

    Covers (a) errno → variant priority over substring matching,
    (b) substring vocabulary union of the four pre-existing inline
    matchers, (c) [Other s] verbatim preservation including original
    casing, and (d) wire-tag stability for downstream consumers. *)

open Alcotest

module S = Masc_mcp.System_error_class

let tag = testable Fmt.string String.equal

let check_tag label expected actual = check tag label expected (S.to_short_tag actual)

(* ---- classify_string: errno-keyword substrings ---- *)

let test_classify_string_fd_too_many_open_files () =
  check_tag "too many open files" "fd_exhaustion"
    (S.classify_string "Sys_error(\"Eio.Io Unix_error (Too many open files in system, ...)\")")

let test_classify_string_fd_errno_substrings () =
  check_tag "ENFILE" "fd_exhaustion" (S.classify_string "ENFILE: too many");
  check_tag "EMFILE" "fd_exhaustion" (S.classify_string "EMFILE on open");
  check_tag "file descriptor" "fd_exhaustion" (S.classify_string "Too many file descriptors");
  check_tag "os error 24" "fd_exhaustion" (S.classify_string "io error: os error 24")

let test_classify_string_disk_substrings () =
  check_tag "no space left" "disk_exhaustion"
    (S.classify_string "No space left on device, \"write\", \"/tmp/x\"");
  check_tag "ENOSPC" "disk_exhaustion" (S.classify_string "ENOSPC on append");
  check_tag "disk quota" "disk_exhaustion" (S.classify_string "Disk quota exceeded");
  check_tag "quota exceeded" "disk_exhaustion" (S.classify_string "Quota exceeded");
  check_tag "disk full" "disk_exhaustion" (S.classify_string "disk full");
  check_tag "not enough space" "disk_exhaustion" (S.classify_string "not enough space available")

let test_classify_string_permission_substrings () =
  check_tag "permission denied" "permission_denied" (S.classify_string "Permission denied");
  check_tag "EACCES" "permission_denied" (S.classify_string "EACCES on open");
  check_tag "EPERM" "permission_denied" (S.classify_string "EPERM: cannot bind");
  check_tag "operation not permitted" "permission_denied"
    (S.classify_string "Operation not permitted")

let test_classify_string_connection_refused () =
  check_tag "connection refused" "connection_refused" (S.classify_string "Connection refused");
  check_tag "ECONNREFUSED" "connection_refused" (S.classify_string "ECONNREFUSED on connect")

let test_classify_string_timeout () =
  check_tag "ETIMEDOUT" "timeout" (S.classify_string "ETIMEDOUT on read");
  check_tag "timed out" "timeout" (S.classify_string "connect: timed out");
  check_tag "operation timed out" "timeout" (S.classify_string "Operation timed out")

(* ---- classify_string: case-insensitive ---- *)

let test_classify_string_case_insensitive () =
  check_tag "uppercase FD" "fd_exhaustion" (S.classify_string "TOO MANY OPEN FILES");
  check_tag "mixed case disk" "disk_exhaustion" (S.classify_string "Disk FULL")

(* ---- classify_string: unclassified → Other s verbatim ---- *)

let test_classify_string_other_preserves_input () =
  let raw = "Unrelated_error(BadCert)" in
  match S.classify_string raw with
  | S.Other s ->
    check string "Other preserves original casing" raw s;
    check_tag "tag is 'other'" "other" (S.Other s)
  | _ -> fail "expected Other variant"

let test_classify_string_empty_input () =
  check_tag "empty string → Other" "other" (S.classify_string "")

(* ---- classify_exn: errno priority over string match ---- *)

let test_classify_exn_errno_emfile () =
  check_tag "EMFILE" "fd_exhaustion"
    (S.classify_exn (Unix.Unix_error (Unix.EMFILE, "open", "/tmp")))

let test_classify_exn_errno_enfile () =
  check_tag "ENFILE" "fd_exhaustion"
    (S.classify_exn (Unix.Unix_error (Unix.ENFILE, "open", "/tmp")))

let test_classify_exn_errno_enospc () =
  check_tag "ENOSPC" "disk_exhaustion"
    (S.classify_exn (Unix.Unix_error (Unix.ENOSPC, "write", "/tmp")))

let test_classify_exn_errno_eacces () =
  check_tag "EACCES" "permission_denied"
    (S.classify_exn (Unix.Unix_error (Unix.EACCES, "open", "/etc/shadow")))

let test_classify_exn_errno_eperm () =
  check_tag "EPERM" "permission_denied"
    (S.classify_exn (Unix.Unix_error (Unix.EPERM, "bind", "")))

let test_classify_exn_errno_econnrefused () =
  check_tag "ECONNREFUSED" "connection_refused"
    (S.classify_exn (Unix.Unix_error (Unix.ECONNREFUSED, "connect", "")))

let test_classify_exn_errno_etimedout () =
  check_tag "ETIMEDOUT" "timeout"
    (S.classify_exn (Unix.Unix_error (Unix.ETIMEDOUT, "read", "")))

(* Regression: errno priority means an EMFILE Unix_error must classify
   as fd_exhaustion even though Printexc.to_string would also surface
   "Too many open files" via the substring path.  Both paths must
   agree, and the errno path must execute first. *)
let test_classify_exn_errno_priority_over_string () =
  check_tag "Unix_error errno path wins" "fd_exhaustion"
    (S.classify_exn (Unix.Unix_error (Unix.EMFILE, "syscall", "arg")))

(* Falls back to string classify for non-Unix_error exceptions. *)
let test_classify_exn_fallback_to_string () =
  check_tag "Sys_error falls through to string" "disk_exhaustion"
    (S.classify_exn (Sys_error "No space left on device"));
  check_tag "Failure falls through to other" "other"
    (S.classify_exn (Failure "unrelated"))

(* ---- to_short_tag / to_raw_text contract ---- *)

let test_to_short_tag_all_variants () =
  check string "Fd_exhaustion" "fd_exhaustion" (S.to_short_tag S.Fd_exhaustion);
  check string "Disk_exhaustion" "disk_exhaustion" (S.to_short_tag S.Disk_exhaustion);
  check string "Permission_denied" "permission_denied" (S.to_short_tag S.Permission_denied);
  check string "Connection_refused" "connection_refused"
    (S.to_short_tag S.Connection_refused);
  check string "Timeout" "timeout" (S.to_short_tag S.Timeout);
  check string "Other" "other" (S.to_short_tag (S.Other "anything"))

let test_to_raw_text_other_returns_input () =
  check string "Other returns verbatim payload" "Original_Error_Message"
    (S.to_raw_text (S.Other "Original_Error_Message"))

let test_to_raw_text_named_returns_short_label () =
  check string "Fd_exhaustion canonical text" "fd_exhaustion"
    (S.to_raw_text S.Fd_exhaustion);
  check string "Disk_exhaustion canonical text" "disk_exhaustion"
    (S.to_raw_text S.Disk_exhaustion)

let () =
  run "system_error_class"
    [ ( "classify_string"
      , [ test_case "FD: too many open files" `Quick test_classify_string_fd_too_many_open_files
        ; test_case "FD: errno substrings" `Quick test_classify_string_fd_errno_substrings
        ; test_case "Disk: substrings" `Quick test_classify_string_disk_substrings
        ; test_case "Permission: substrings" `Quick
            test_classify_string_permission_substrings
        ; test_case "Connection refused" `Quick test_classify_string_connection_refused
        ; test_case "Timeout" `Quick test_classify_string_timeout
        ; test_case "case-insensitive" `Quick test_classify_string_case_insensitive
        ; test_case "Other preserves input" `Quick test_classify_string_other_preserves_input
        ; test_case "empty string" `Quick test_classify_string_empty_input
        ] )
    ; ( "classify_exn"
      , [ test_case "EMFILE" `Quick test_classify_exn_errno_emfile
        ; test_case "ENFILE" `Quick test_classify_exn_errno_enfile
        ; test_case "ENOSPC" `Quick test_classify_exn_errno_enospc
        ; test_case "EACCES" `Quick test_classify_exn_errno_eacces
        ; test_case "EPERM" `Quick test_classify_exn_errno_eperm
        ; test_case "ECONNREFUSED" `Quick test_classify_exn_errno_econnrefused
        ; test_case "ETIMEDOUT" `Quick test_classify_exn_errno_etimedout
        ; test_case "errno priority over string match" `Quick
            test_classify_exn_errno_priority_over_string
        ; test_case "fallback to classify_string" `Quick
            test_classify_exn_fallback_to_string
        ] )
    ; ( "wire format"
      , [ test_case "to_short_tag covers all variants" `Quick
            test_to_short_tag_all_variants
        ; test_case "to_raw_text on Other returns input" `Quick
            test_to_raw_text_other_returns_input
        ; test_case "to_raw_text on named returns short label" `Quick
            test_to_raw_text_named_returns_short_label
        ] )
    ]
