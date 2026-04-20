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

(* ---------- P1 Tick 3: Exec_semantic JSON integration ------------------ *)

let with_semantic_flag enabled f =
  (* Post-flip: empty string means "default", which is now ON.
     Use explicit "0" for the off case so the test intention is
     preserved regardless of the default. *)
  let prev = Sys.getenv_opt "MASC_BASH_SEMANTIC_EXIT" in
  Unix.putenv "MASC_BASH_SEMANTIC_EXIT" (if enabled then "1" else "0");
  let restore () =
    match prev with
    | Some v -> Unix.putenv "MASC_BASH_SEMANTIC_EXIT" v
    | None -> Unix.putenv "MASC_BASH_SEMANTIC_EXIT" ""
  in
  match f () with
  | v -> restore (); v
  | exception e -> restore (); raise e

let run_json ~cmd ~status ~output =
  Masc_mcp.Exec_core.process_result_json
    ~base_path:"/tmp"
    ~keeper_name:"exec-core-semantic"
    ~cmd
    ~status
    ~output
    ()

let test_semantic_hidden_on_explicit_off () =
  (* Post-flip: the only way the semantic field vanishes is an
     explicit operator opt-out.  Covers the "byte-identical
     pre-P1 shape" path for rare callers that need it. *)
  with_semantic_flag false (fun () ->
    let json = run_json ~cmd:"ls" ~status:(Unix.WEXITED 0) ~output:"" in
    match json |> member "semantic_exit" with
    | `Null -> ()
    | _ -> fail "semantic_exit must be absent when flag is off")

let test_semantic_ok_when_flag_on () =
  with_semantic_flag true (fun () ->
    let json = run_json ~cmd:"ls" ~status:(Unix.WEXITED 0) ~output:"" in
    let sem = json |> member "semantic_exit" in
    check string "kind=ok" "ok" (sem |> member "kind" |> to_string))

let test_semantic_fail_carries_exit_code () =
  with_semantic_flag true (fun () ->
    let json = run_json ~cmd:"ls /no/such/path"
                 ~status:(Unix.WEXITED 2) ~output:"ls: …" in
    let sem = json |> member "semantic_exit" in
    check string "kind=fail" "fail" (sem |> member "kind" |> to_string);
    check int "exit_code=2" 2 (sem |> member "exit_code" |> to_int);
    check bool "rci present" true
      (match json |> member "return_code_interpretation" with
       | `String _ -> true | _ -> false))

let test_semantic_git_not_a_repo () =
  with_semantic_flag true (fun () ->
    let json = run_json ~cmd:"git status" ~status:(Unix.WEXITED 128)
                 ~output:"fatal: not a git repository" in
    let sem = json |> member "semantic_exit" in
    check string "kind=git_not_a_repo" "git_not_a_repo"
      (sem |> member "kind" |> to_string))

let test_semantic_tool_missing_payload () =
  with_semantic_flag true (fun () ->
    let json = run_json ~cmd:"notarealtool --help"
                 ~status:(Unix.WEXITED 127)
                 ~output:"bash: notarealtool: command not found" in
    let sem = json |> member "semantic_exit" in
    check string "kind=tool_missing" "tool_missing"
      (sem |> member "kind" |> to_string);
    check string "tool=notarealtool" "notarealtool"
      (sem |> member "tool" |> to_string))

let test_semantic_flag_isolation () =
  (* Flipping off after on must hide the field again. *)
  with_semantic_flag true (fun () ->
    let _ = run_json ~cmd:"ls" ~status:(Unix.WEXITED 0) ~output:"" in
    ());
  with_semantic_flag false (fun () ->
    let json = run_json ~cmd:"ls" ~status:(Unix.WEXITED 0) ~output:"" in
    match json |> member "semantic_exit" with
    | `Null -> ()
    | _ -> fail "semantic_exit must stay absent after flag flips off")

(* ---------- P6 Tick 16: verifiable_markers JSON integration -------------- *)

let with_markers_flag enabled f =
  (* Post-flip: the unset env resolves to ON.  Use "0" for the
     off path so this helper keeps its pre-flip semantics
     (enabled=false => markers absent) irrespective of the default. *)
  let prev = Sys.getenv_opt "MASC_BASH_VERIFIABLE_MARKERS" in
  Unix.putenv "MASC_BASH_VERIFIABLE_MARKERS" (if enabled then "1" else "0");
  let restore () =
    match prev with
    | Some v -> Unix.putenv "MASC_BASH_VERIFIABLE_MARKERS" v
    | None -> Unix.putenv "MASC_BASH_VERIFIABLE_MARKERS" ""
  in
  match f () with
  | v -> restore (); v
  | exception e -> restore (); raise e

let test_markers_absent_when_flag_off () =
  with_semantic_flag true (fun () ->
    with_markers_flag false (fun () ->
      let json =
        run_json ~cmd:"git status" ~status:(Unix.WEXITED 128)
          ~output:"fatal: not a git repository"
      in
      match json |> member "verifiable_markers" with
      | `Null -> ()
      | _ -> fail "markers must be absent when flag is off"))

let test_markers_absent_when_semantic_off () =
  (* Markers require semantic; flag-on alone without semantic is no-op. *)
  with_semantic_flag false (fun () ->
    with_markers_flag true (fun () ->
      let json =
        run_json ~cmd:"git status" ~status:(Unix.WEXITED 128)
          ~output:"fatal: not a git repository"
      in
      match json |> member "verifiable_markers" with
      | `Null -> ()
      | _ -> fail "markers require semantic flag to also be on"))

let test_markers_git_not_a_repo () =
  with_semantic_flag true (fun () ->
    with_markers_flag true (fun () ->
      let json =
        run_json ~cmd:"git status" ~status:(Unix.WEXITED 128)
          ~output:"fatal: not a git repository"
      in
      let markers = json |> member "verifiable_markers" |> to_list in
      check int "one marker" 1 (List.length markers);
      let m = List.hd markers in
      check string "kind" "git_not_a_repo" (m |> member "kind" |> to_string);
      check string "confidence" "exact"
        (m |> member "confidence" |> to_string)))

let test_markers_unknown_output_emits_absent () =
  (* No producer pattern → no marker list field. *)
  with_semantic_flag true (fun () ->
    with_markers_flag true (fun () ->
      let json =
        run_json ~cmd:"ls" ~status:(Unix.WEXITED 0) ~output:"hello world"
      in
      match json |> member "verifiable_markers" with
      | `Null -> ()
      | _ -> fail "unknown output must not emit a marker list"))

(* ---------- P3 Tick 9: output_cap env-gated head+tail truncation --------- *)

let with_env key value f =
  let prev = Sys.getenv_opt key in
  Unix.putenv key (Option.value ~default:"" value);
  let restore () =
    match prev with
    | Some v -> Unix.putenv key v
    | None -> Unix.putenv key ""
  in
  match f () with
  | v -> restore (); v
  | exception e -> restore (); raise e

let test_output_cap_absent_by_default () =
  with_env "MASC_BASH_OUTPUT_CAP" None (fun () ->
    let json =
      run_json ~cmd:"ls" ~status:(Unix.WEXITED 0) ~output:"hello"
    in
    check string "output untouched" "hello" (json |> member "output" |> to_string);
    match json |> member "output_cap" with
    | `Null -> ()
    | _ -> fail "output_cap must be absent when flag is off")

let test_output_cap_on_preserves_small_output () =
  with_env "MASC_BASH_OUTPUT_CAP" (Some "1") (fun () ->
    let json =
      run_json ~cmd:"ls" ~status:(Unix.WEXITED 0) ~output:"short"
    in
    check string "short output unchanged" "short"
      (json |> member "output" |> to_string);
    let cap = json |> member "output_cap" in
    check int "total_bytes=5" 5 (cap |> member "total_bytes" |> to_int);
    check int "bytes_dropped=0" 0 (cap |> member "bytes_dropped" |> to_int))

let test_output_cap_truncates_large_output () =
  with_env "MASC_BASH_OUTPUT_CAP" (Some "1") (fun () ->
    with_env "MASC_BASH_CAP_HEAD" (Some "8") (fun () ->
      with_env "MASC_BASH_CAP_TAIL" (Some "8") (fun () ->
        let long = "HEADAAAA" ^ String.make 256 'X' ^ "TAILBBBB" in
        let json =
          run_json ~cmd:"cat big" ~status:(Unix.WEXITED 0) ~output:long
        in
        let out = json |> member "output" |> to_string in
        (* separator format from Exec_buffer.render *)
        if not (String.length out > 0 && String.length out < String.length long)
        then fail "output should be shorter than input when capped";
        let cap = json |> member "output_cap" in
        check int "total_bytes" (String.length long)
          (cap |> member "total_bytes" |> to_int);
        let dropped = cap |> member "bytes_dropped" |> to_int in
        if dropped <= 0 then fail "bytes_dropped must be positive";
        check int "head_cap=8" 8 (cap |> member "head_cap" |> to_int);
        check int "tail_cap=8" 8 (cap |> member "tail_cap" |> to_int))))

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
      ( "semantic_exit",
        [
          test_case "explicit opt-out hides field" `Quick
            test_semantic_hidden_on_explicit_off;
          test_case "ok kind on exit 0" `Quick test_semantic_ok_when_flag_on;
          test_case "fail kind carries exit_code" `Quick
            test_semantic_fail_carries_exit_code;
          test_case "git exit 128 maps to git_not_a_repo" `Quick
            test_semantic_git_not_a_repo;
          test_case "exit 127 maps to tool_missing with tool payload"
            `Quick test_semantic_tool_missing_payload;
          test_case "flag flip isolates state" `Quick
            test_semantic_flag_isolation;
        ] );
      ( "verifiable_markers",
        [
          test_case "absent when markers flag off" `Quick
            test_markers_absent_when_flag_off;
          test_case "absent when semantic flag off" `Quick
            test_markers_absent_when_semantic_off;
          test_case "git_not_a_repo emits exact marker" `Quick
            test_markers_git_not_a_repo;
          test_case "unknown output emits no marker field" `Quick
            test_markers_unknown_output_emits_absent;
        ] );
      ( "output_cap",
        [
          test_case "absent by default" `Quick
            test_output_cap_absent_by_default;
          test_case "small output unchanged, cap metadata emitted"
            `Quick test_output_cap_on_preserves_small_output;
          test_case "large output truncated with bytes_dropped > 0"
            `Quick test_output_cap_truncates_large_output;
        ] );
    ]
