open Alcotest

(** RFC-0085 PR-4 — tool_library + cdal proof_store /tmp fallback 박멸.

    Verifies:
    - lib/tool_library.ml: ~default:"/tmp" 리터럴 fallback 제거
      (Host_config.host()-based로 변경).
    - lib/cdal_runtime/proof_store.ml: Not_found -> "/tmp" 리터럴 제거
      (cdal_runtime sub-library는 masc_mcp 본 라이브러리와 격리되어
       있어 Filename.get_temp_dir_name () 직접 사용 — cdal-local
       fallback, RFC-OAS-011 격리 보존).

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

let test_no_tmp_default_in_proof_store () =
  let path = "lib/cdal_runtime/proof_store.ml" in
  let n = Ast_grep.count_string_literals ~module_path:path ~needle:"/tmp" in
  check int "/tmp literal removed from proof_store fallback" 0 n
;;

let () =
  run
    "rfc-0085-pr-4-tool-library-proof-store"
    [ ( "tool_library"
      , [ test_case "no /tmp literal" `Quick test_no_tmp_default_in_tool_library
        ; test_case "uses Host_config.host" `Quick test_tool_library_uses_host_config
        ] )
    ; ( "proof_store"
      , [ test_case "no /tmp literal" `Quick test_no_tmp_default_in_proof_store ] )
    ]
;;
