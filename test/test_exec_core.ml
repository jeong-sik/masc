open Alcotest
open Yojson.Safe.Util

let get_string_field json key =
  json |> member key |> to_string

let test_rg_no_match_is_semantic_success () =
  let json =
    Masc_mcp.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"exec-core"
      ~cmd:"rg missing_pattern lib/"
      ~status:(Unix.WEXITED 1)
      ~output:""
      ()
  in
  check bool "ok" true (json |> member "ok" |> to_bool);
  check string "semantic_status" "no_match"
    (get_string_field json "semantic_status");
  check string "family" "search"
    (json |> member "classification" |> member "family" |> to_string)

let test_find_partial_is_semantic_success () =
  let json =
    Masc_mcp.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"exec-core"
      ~cmd:"find lib -name '*.ml'"
      ~status:(Unix.WEXITED 1)
      ~output:"lib/exec_core.ml\nfind: lib/private: Permission denied"
      ()
  in
  check bool "ok" false (json |> member "ok" |> to_bool);
  check string "semantic_status" "partial"
    (get_string_field json "semantic_status")

let test_find_missing_path_is_runtime_error () =
  let json =
    Masc_mcp.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"exec-core"
      ~cmd:"find /tmp /definitely-missing-path-xyz"
      ~status:(Unix.WEXITED 1)
      ~output:"find: /definitely-missing-path-xyz: No such file or directory"
      ()
  in
  check bool "ok" false (json |> member "ok" |> to_bool);
  check string "semantic_status" "runtime_error"
    (get_string_field json "semantic_status")

let test_blocked_json_adds_classification () =
  let json =
    Masc_mcp.Exec_core.blocked_result_json
      ~cmd:"git push origin main"
      ~error:"write_operation_gated"
      ~reason:"write preset required"
      ~retryability:Masc_mcp.Exec_core.Operator_required
      ()
  in
  check string "error" "write_operation_gated"
    (get_string_field json "error");
  check string "semantic_status" "blocked"
    (get_string_field json "semantic_status");
  check string "family" "git_write"
    (json |> member "classification" |> member "family" |> to_string);
  check string "risk" "high"
    (json |> member "classification" |> member "risk" |> to_string);
  check string "hint"
    "Revise the command or switch to the structured shell tool that matches the intent."
    (get_string_field json "hint");
  check string "recovery_hint"
    "Revise the command or switch to the structured shell tool that matches the intent."
    (get_string_field json "recovery_hint");
  check string "retryability" "operator_required"
    (get_string_field json "retryability")

let test_regex_pipe_inside_quotes_keeps_no_match_semantics () =
  let json =
    Masc_mcp.Exec_core.process_result_json
      ~base_path:"/tmp"
      ~keeper_name:"exec-core"
      ~cmd:"rg 'a|b' lib/"
      ~status:(Unix.WEXITED 1)
      ~output:""
      ()
  in
  check bool "ok" true (json |> member "ok" |> to_bool);
  check string "semantic_status" "no_match"
    (get_string_field json "semantic_status")

let test_unknown_write_is_not_git_write () =
  let classification =
    Masc_mcp.Exec_core.classify_command ~cmd:"mkdir tmp/generated"
  in
  check string "family" "unknown"
    (Masc_mcp.Exec_core.classification_to_json classification
     |> member "family" |> to_string);
  check bool "write_intent" true classification.write_intent

let temp_dir () =
  let path = Filename.temp_file "exec_core_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Sys.readdir path
      |> Array.iter (fun entry -> remove_tree (Filename.concat path entry));
      Unix.rmdir path
  | _ ->
      Unix.unlink path

let test_large_output_persists_artifact () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
      let output = String.make 17000 'x' in
      let json =
        Masc_mcp.Exec_core.process_result_json
          ~artifact_policy:Masc_mcp.Exec_core.Persist_if_large
          ~base_path
          ~keeper_name:"exec-core"
          ~cmd:"cat README.md"
          ~status:(Unix.WEXITED 0)
          ~output
          ()
      in
      let refs = json |> member "artifact_refs" |> to_list in
      check int "one artifact ref" 1 (List.length refs);
      let artifact_path = List.hd refs |> member "path" |> to_string in
      check bool "artifact exists" true (Sys.file_exists artifact_path);
      check int "artifact bytes" (String.length output)
        ((List.hd refs |> member "bytes" |> to_int));
      check string "persisted contents" output
        (Fs_compat.load_file artifact_path))

let test_inline_only_keeps_artifact_refs_empty () =
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> remove_tree base_path)
    (fun () ->
      let output = String.make 17000 'x' in
      let json =
        Masc_mcp.Exec_core.process_result_json
          ~artifact_policy:Masc_mcp.Exec_core.Inline_only
          ~base_path
          ~keeper_name:"exec-core"
          ~cmd:"cat README.md"
          ~status:(Unix.WEXITED 0)
          ~output
          ()
      in
      let refs = json |> member "artifact_refs" |> to_list in
      check int "no artifact ref" 0 (List.length refs))

let () =
  run "exec_core"
    [
      ( "semantic_status",
        [
          test_case "rg no match is semantic success" `Quick
            test_rg_no_match_is_semantic_success;
          test_case "find partial is recoverable but not success" `Quick
            test_find_partial_is_semantic_success;
          test_case "find missing path is runtime error" `Quick
            test_find_missing_path_is_runtime_error;
          test_case "quoted regex pipe keeps no-match semantics" `Quick
            test_regex_pipe_inside_quotes_keeps_no_match_semantics;
          test_case "blocked json adds classification" `Quick
            test_blocked_json_adds_classification;
          test_case "unknown write is not git_write" `Quick
            test_unknown_write_is_not_git_write;
          test_case "large output persists artifact" `Quick
            test_large_output_persists_artifact;
          test_case "inline only keeps artifact refs empty" `Quick
            test_inline_only_keeps_artifact_refs_empty;
        ] );
    ]
