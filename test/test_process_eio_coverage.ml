open Alcotest

module M = Masc_mcp

let contains haystack needle =
  let len_h = String.length haystack and len_n = String.length needle in
  let rec loop i =
    if i + len_n > len_h then false
    else if String.sub haystack i len_n = needle then true
    else loop (i + 1)
  in
  loop 0

let test_should_retry_unix_fallback_on_bind_error () =
  let exn = Unix.Unix_error (Unix.EADDRINUSE, "bind", "") in
  check bool "retry bind eaddrinuse" true
    (M.Process_eio.should_retry_unix_fallback exn)

let test_should_retry_unix_fallback_on_cancelled_bind_error () =
  let exn =
    Eio.Cancel.Cancelled (Unix.Unix_error (Unix.EADDRINUSE, "bind", ""))
  in
  check bool "retry cancelled bind eaddrinuse" true
    (M.Process_eio.should_retry_unix_fallback exn)

let test_run_argv_fallback_preserves_env () =
  let output =
    M.Process_eio.run_argv ~env:[| "PROCESS_EIO_TEST_VAR=ok" |] [ "/usr/bin/env" ]
  in
  check bool "env visible in fallback" true
    (contains output "PROCESS_EIO_TEST_VAR=ok")

let test_run_argv_with_stdin_fallback_preserves_input () =
  let output =
    M.Process_eio.run_argv_with_stdin ~stdin_content:"ping\n" [ "/bin/cat" ]
  in
  check string "stdin content round-trips" "ping\n" output

let () =
  run "Process_eio coverage"
    [
      ( "fallback",
        [
          test_case "retry-on-bind-eaddrinuse" `Quick
            test_should_retry_unix_fallback_on_bind_error;
          test_case "retry-on-cancelled-bind-eaddrinuse" `Quick
            test_should_retry_unix_fallback_on_cancelled_bind_error;
          test_case "argv-fallback-preserves-env" `Quick
            test_run_argv_fallback_preserves_env;
          test_case "argv-with-stdin-fallback-preserves-input" `Quick
            test_run_argv_with_stdin_fallback_preserves_input;
        ] );
    ]
