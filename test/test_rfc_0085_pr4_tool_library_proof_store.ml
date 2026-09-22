open Alcotest

(** lib/tool_library.ml resolves no path of its own.

    The library lives under the workspace the request already carries
    ([Tool_library.context.base_path]), so the module names no directory
    literal, reads no environment variable, and asks no host for a fallback
    root. A regression on any of the three sends documents somewhere the rest
    of the request does not look.

    AST-based via Ast_grep. *)

let path = "lib/tool_library.ml"

let test_no_tmp_default_in_tool_library () =
  let n = Ast_grep.count_string_literals ~module_path:path ~needle:"/tmp" in
  check int "no /tmp literal" 0 n
;;

let test_tool_library_reads_no_environment () =
  let getenv_opt = Ast_grep.count_calls ~module_path:path ~callee:"Sys.getenv_opt" in
  let getenv = Ast_grep.count_calls ~module_path:path ~callee:"Sys.getenv" in
  check int "no Sys.getenv_opt call" 0 getenv_opt;
  check int "no Sys.getenv call" 0 getenv
;;

let test_tool_library_asks_no_host_for_a_root () =
  let n = Ast_grep.count_calls ~module_path:path ~callee:"Host_config.host" in
  check int "no Host_config.host fallback" 0 n
;;

let () =
  run
    "rfc-0085-pr-4-tool-library"
    [ ( "tool_library"
      , [ test_case "no /tmp literal" `Quick test_no_tmp_default_in_tool_library
        ; test_case "reads no environment" `Quick test_tool_library_reads_no_environment
        ; test_case
            "asks no host for a root"
            `Quick
            test_tool_library_asks_no_host_for_a_root
        ] )
    ]
;;
