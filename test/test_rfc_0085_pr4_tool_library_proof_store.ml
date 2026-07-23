open Alcotest

(** RFC-0085 PR-4 — tool_library /tmp fallback 박멸.

    Verifies:
    - lib/tool_library.ml: ~default:"/tmp" 리터럴 fallback 제거
      (Host_config.host()-based로 변경).

    The companion contract proof-store guards were dropped with the CDAL
    purge (#19469 Track B and the final removal): the module is gone, so the
    /tmp-fallback invariant it guarded is moot.

    AST-based via Ast_grep. *)

let test_no_tmp_default_in_tool_library () =
  let path = "lib/tool_library.ml" in
  (* "/tmp" 문자열 자체가 fallback에 등장하지 않아야 한다. *)
  let n = Ast_grep.count_string_literals ~module_path:path ~needle:"/tmp" in
  check int "/tmp literal removed from tool_library fallback" 0 n
;;

let test_tool_library_uses_host_config () =
  let path = "lib/tool_library.ml" in
  let n = Ast_grep.count_calls ~module_path:path ~callee:"Host_config.host" in
  if n < 1
  then failf "tool_library.ml must call Host_config.host >= 1, got %d" n
;;

let () =
  run
    "rfc-0085-pr-4-tool-library"
    [ ( "tool_library"
      , [ test_case "no /tmp literal" `Quick test_no_tmp_default_in_tool_library
        ; test_case "uses Host_config.host" `Quick test_tool_library_uses_host_config
        ] )
    ]
;;
