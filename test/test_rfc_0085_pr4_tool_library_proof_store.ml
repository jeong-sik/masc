open Alcotest

(** RFC-0085 PR-4 — tool_library + cdal proof_store /tmp fallback 박멸.

    Verifies:
    - lib/tool_library.ml: ~default:"/tmp" 리터럴 fallback 제거
      (Host_config.host()-based로 변경).
    - lib/cdal_runtime/proof_store.ml: Not_found -> "/tmp" 리터럴 및
      home-level [.oas] fallback 제거. cdal_runtime sub-library는
      masc_mcp 본 라이브러리와 격리되어 있으므로 MASC_BASE_PATH /
      cwd 순서만 직접 사용한다.

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

let test_no_home_default_in_proof_store () =
  let path = "lib/cdal_runtime/proof_store.ml" in
  let n = Ast_grep.count_string_literals ~module_path:path ~needle:"HOME" in
  check int "HOME literal removed from proof_store fallback" 0 n
;;

let test_proof_store_uses_base_path_input_only () =
  let path = "lib/cdal_runtime/proof_store.ml" in
  let masc_base =
    Ast_grep.count_string_literals ~module_path:path ~needle:"MASC_BASE_PATH"
  in
  let legacy_me_root =
    Ast_grep.count_string_literals ~module_path:path ~needle:(String.concat "" [ "ME"; "_ROOT" ])
  in
  if masc_base < 1 || legacy_me_root <> 0
  then
    failf
      "proof_store fallback should use MASC_BASE_PATH only, got MASC_BASE_PATH=%d legacy-root=%d"
      masc_base
      legacy_me_root
;;

let () =
  run
    "rfc-0085-pr-4-tool-library-proof-store"
    [ ( "tool_library"
      , [ test_case "no /tmp literal" `Quick test_no_tmp_default_in_tool_library
        ; test_case "uses Host_config.host" `Quick test_tool_library_uses_host_config
        ] )
    ; ( "proof_store"
      , [ test_case "no /tmp literal" `Quick test_no_tmp_default_in_proof_store
        ; test_case "no HOME literal" `Quick test_no_home_default_in_proof_store
        ; test_case
            "uses base-path input only"
            `Quick
            test_proof_store_uses_base_path_input_only
        ] )
    ]
;;
