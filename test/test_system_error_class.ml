(** RFC-0154 PR-1.  Unit tests for the typed System_error_class SSOT.

    Covers (a) errno → variant priority over substring matching,
    (b) substring vocabulary union of the four pre-existing inline
    matchers, (c) [Other s] verbatim preservation including original
    casing, and (d) wire-tag stability for downstream consumers. *)

open Alcotest

module S = System_error_class

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

(* String payloads ([Sys_error], [Failure]) are the one place the text is read:
   the payload is a string by construction. *)
let test_classify_exn_fallback_to_string () =
  check_tag "Sys_error falls through to string" "disk_exhaustion"
    (S.classify_exn (Sys_error "No space left on device"));
  check_tag "Failure falls through to other" "other"
    (S.classify_exn (Failure "unrelated"))

(* ---- classify_exn: Eio structured paths (#49742) ---- *)

let backtrace = Printexc.get_callstack 0

let unix_backend code name arg = Eio_unix.Unix_error (code, name, arg)

(* [Eio.Exn.context] is abstract; the only way to hold one is to take it from
   an exception Eio built. *)
let eio_context =
  match Eio.Exn.create (Eio.Exn.X (unix_backend Unix.EIO "probe" "")) with
  | Eio.Exn.Io (_, context) -> context
  | _ -> failwith "Eio.Exn.create did not build an Io exception"

let test_classify_exn_eio_bare_backend () =
  check_tag "Io (X Unix_error EMFILE)" "fd_exhaustion"
    (S.classify_exn (Eio.Exn.create (Eio.Exn.X (unix_backend Unix.EMFILE "open" "/tmp"))));
  check_tag "Io (X Unix_error ENOSPC)" "disk_exhaustion"
    (S.classify_exn (Eio.Exn.create (Eio.Exn.X (unix_backend Unix.ENOSPC "write" "/tmp"))));
  check_tag "Io (X Unix_error ETIMEDOUT)" "timeout"
    (S.classify_exn (Eio.Exn.create (Eio.Exn.X (unix_backend Unix.ETIMEDOUT "read" ""))))

let test_classify_exn_eio_fs_vocabulary () =
  check_tag "Fs Permission_denied EACCES" "permission_denied"
    (S.classify_exn
       (Eio.Exn.create
          (Eio.Fs.E (Eio.Fs.Permission_denied (unix_backend Unix.EACCES "open" "/etc/shadow")))));
  check_tag "Fs Not_found ENOENT is Other" "other"
    (S.classify_exn
       (Eio.Exn.create (Eio.Fs.E (Eio.Fs.Not_found (unix_backend Unix.ENOENT "open" "/missing")))));
  check_tag "Fs File_too_large carries no errno" "other"
    (S.classify_exn (Eio.Exn.create (Eio.Fs.E Eio.Fs.File_too_large)))

let test_classify_exn_eio_net_vocabulary () =
  check_tag "Net Refused ECONNREFUSED" "connection_refused"
    (S.classify_exn
       (Eio.Exn.create
          (Eio.Net.E
             (Eio.Net.Connection_failure
                (Eio.Net.Refused (unix_backend Unix.ECONNREFUSED "connect" ""))))));
  check_tag "Net Connection_reset EPIPE is Other" "other"
    (S.classify_exn
       (Eio.Exn.create (Eio.Net.E (Eio.Net.Connection_reset (unix_backend Unix.EPIPE "write" "")))))

let test_classify_exn_eio_multiple () =
  check_tag "Multiple: first errno member decides, cancellation skipped" "disk_exhaustion"
    (S.classify_exn
       (Eio.Exn.Multiple
          [ (Eio.Cancel.Cancelled (Failure "race loser"), backtrace)
          ; (Unix.Unix_error (Unix.ENOSPC, "write", "/tmp"), backtrace)
          ]));
  check_tag "Multiple_io inside Io" "fd_exhaustion"
    (S.classify_exn
       (Eio.Exn.create
          (Eio.Exn.Multiple_io
             [ (Eio.Exn.X (unix_backend Unix.ENFILE "accept" ""), eio_context, backtrace) ])))

exception Needle_in_payload of string

(* Regression for #49742: the rendered text of an exception is no longer a
   classification input.  Each of these used to classify through
   [Printexc.to_string]; none carries a structured errno of that class. *)
let test_classify_exn_rendered_text_is_not_parsed () =
  check_tag "ENOENT with a needle in its argument" "other"
    (S.classify_exn
       (Unix.Unix_error (Unix.ENOENT, "open", "/reports/no space left on device.txt")));
  check_tag "cancellation wrapping needle text" "other"
    (S.classify_exn (Eio.Cancel.Cancelled (Failure "no space left on device during cleanup")));
  check_tag "custom exception with needle text" "other"
    (S.classify_exn (Needle_in_payload "connection refused by upstream"))

let test_classify_exn_string_payloads_keep_boundary_parse () =
  check_tag "Sys_error payload" "fd_exhaustion" (S.classify_exn (Sys_error "Too many open files"));
  check_tag "Failure payload" "timeout" (S.classify_exn (Failure "connect: timed out"))

(* ---- errno_of_unix_error / errno_of_exn ---- *)

let errno = testable (fun fmt _ -> Fmt.string fmt "<errno>") ( = )

let test_errno_of_unix_error_named () =
  List.iter
    (fun (code, expected) ->
      check errno "named errno" expected (S.errno_of_unix_error code))
    [ Unix.EMFILE, S.Emfile
    ; Unix.ENFILE, S.Enfile
    ; Unix.ENOSPC, S.Enospc
    ; Unix.EACCES, S.Eacces
    ; Unix.EPERM, S.Eperm
    ; Unix.ENOENT, S.Enoent
    ; Unix.ECONNREFUSED, S.Econnrefused
    ; Unix.ETIMEDOUT, S.Etimedout
    ; Unix.EPIPE, S.Epipe
    ; Unix.EADDRINUSE, S.Eaddrinuse
    ; Unix.EADDRNOTAVAIL, S.Eaddrnotavail
    ]

(* Every other constructor, including the payload-carrying EUNKNOWNERR, keeps
   its code so a caller that wants it loses nothing. *)
let test_errno_of_unix_error_other_keeps_code () =
  List.iter
    (fun code ->
      check errno "other errno keeps its code" (S.Other_errno code)
        (S.errno_of_unix_error code))
    [ Unix.EAGAIN; Unix.EWOULDBLOCK; Unix.EXDEV; Unix.EUNKNOWNERR 4242 ]

let test_errno_of_exn () =
  check (option errno) "Unix_error is typed" (Some S.Enospc)
    (S.errno_of_exn (Unix.Unix_error (Unix.ENOSPC, "write", "/tmp")));
  check (option errno) "Io-wrapped Unix_error is typed" (Some S.Emfile)
    (S.errno_of_exn (Eio.Exn.create (Eio.Exn.X (unix_backend Unix.EMFILE "open" "/tmp"))));
  check (option errno) "Sys_error text is not parsed" None
    (S.errno_of_exn (Sys_error "No space left on device"));
  check (option errno) "Failure is not an errno" None
    (S.errno_of_exn (Failure "unrelated"))

(* ENOENT has no class of its own in [t], and the errno is the answer: the
   result is [Other] without the text ever being read. *)
let test_classify_exn_enoent_is_other () =
  check_tag "ENOENT" "other"
    (S.classify_exn (Unix.Unix_error (Unix.ENOENT, "open", "/missing")))

(* ---- to_short_tag contract ---- *)

let test_to_short_tag_all_variants () =
  check string "Fd_exhaustion" "fd_exhaustion" (S.to_short_tag S.Fd_exhaustion);
  check string "Disk_exhaustion" "disk_exhaustion" (S.to_short_tag S.Disk_exhaustion);
  check string "Permission_denied" "permission_denied" (S.to_short_tag S.Permission_denied);
  check string "Connection_refused" "connection_refused"
    (S.to_short_tag S.Connection_refused);
  check string "Timeout" "timeout" (S.to_short_tag S.Timeout);
  check string "Other" "other" (S.to_short_tag (S.Other "anything"))

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
        ; test_case "ENOENT is Other" `Quick test_classify_exn_enoent_is_other
        ; test_case "Eio: bare backend errno" `Quick test_classify_exn_eio_bare_backend
        ; test_case "Eio: Fs vocabulary" `Quick test_classify_exn_eio_fs_vocabulary
        ; test_case "Eio: Net vocabulary" `Quick test_classify_exn_eio_net_vocabulary
        ; test_case "Eio: Multiple / Multiple_io" `Quick test_classify_exn_eio_multiple
        ; test_case "rendered text is not parsed" `Quick
            test_classify_exn_rendered_text_is_not_parsed
        ; test_case "string payloads keep boundary parse" `Quick
            test_classify_exn_string_payloads_keep_boundary_parse
        ] )
    ; ( "errno"
      , [ test_case "named errnos" `Quick test_errno_of_unix_error_named
        ; test_case "other errno keeps its code" `Quick
            test_errno_of_unix_error_other_keeps_code
        ; test_case "errno_of_exn" `Quick test_errno_of_exn
        ] )
    ; ( "wire format"
      , [ test_case "to_short_tag covers all variants" `Quick
            test_to_short_tag_all_variants
        ] )
    ]
