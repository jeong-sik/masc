open Alcotest

(** RFC-0085 PR-2 — auto_responder /tmp 리터럴 박멸.

    Verifies that lib/auto_responder.ml no longer carries the hardcoded
    "/tmp/auto-responder.log" or "/tmp/auto_debug.log" string literals;
    both call-sites now route through (Host_config.host ()).log_dir.

    Uses Ast_grep (AST-based, RFC-0085 PR-1) so docstring or comment
    references to "/tmp/auto" do not produce false positives. *)

let test_no_tmp_auto_literal_in_auto_responder () =
  let path = "lib/auto_responder.ml" in
  let count = Ast_grep.count_string_literals ~module_path:path ~needle:"/tmp/auto" in
  check int "/tmp/auto* literals removed from auto_responder.ml" 0 count
;;

let test_host_log_dir_used_in_auto_responder () =
  let path = "lib/auto_responder.ml" in
  let count = Ast_grep.count_calls ~module_path:path ~callee:"Host_config.host" in
  if count < 1
  then failf "auto_responder.ml must call Host_config.host >= 1, got %d" count
;;

let () =
  run
    "rfc-0085-pr-2-auto-responder-log-dir"
    [ ( "literal purge"
      , [ test_case
            "no /tmp/auto* literals"
            `Quick
            test_no_tmp_auto_literal_in_auto_responder
        ; test_case "Host_config.host used" `Quick test_host_log_dir_used_in_auto_responder
        ] )
    ]
;;
