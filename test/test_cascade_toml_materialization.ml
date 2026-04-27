open Alcotest
open Yojson.Safe.Util

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop idx =
    if needle_len = 0 then
      true
    else if idx + needle_len > haystack_len then
      false
    else if String.sub haystack idx needle_len = needle then
      true
    else
      loop (idx + 1)
  in
  loop 0

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let rec mkdir_p path =
  if path = "" || path = "." || path = "/" then
    ()
  else if Sys.file_exists path then
    ()
  else begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let write_file path content =
  mkdir_p (Filename.dirname path);
  Out_channel.with_open_bin path (fun oc -> output_string oc content)

let read_file path =
  In_channel.with_open_bin path In_channel.input_all

let with_env name value f =
  let saved = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match saved with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let with_config_dir config_dir f =
  let reset () =
    Masc_mcp.Config_dir_resolver.reset ();
    Masc_mcp.Cascade_catalog_runtime.reset_cache_for_tests ()
  in
  with_env "MASC_BASE_PATH" None @@ fun () ->
  with_env "MASC_CONFIG_DIR" (Some config_dir) @@ fun () ->
  reset ();
  Fun.protect ~finally:reset f

let init_config_root config_dir =
  mkdir_p (Filename.concat config_dir "prompts");
  mkdir_p (Filename.concat config_dir "keepers");
  mkdir_p (Filename.concat config_dir "personas")

let repo_toml_path () =
  match Sys.getenv_opt "MASC_CASCADE_TOML_PATH" with
  | Some path when String.trim path <> "" -> path
  | _ -> failwith "MASC_CASCADE_TOML_PATH not set"

let repo_json_path () =
  match Sys.getenv_opt "MASC_CASCADE_JSON_PATH" with
  | Some path when String.trim path <> "" -> path
  | _ -> failwith "MASC_CASCADE_JSON_PATH not set"

let minimal_toml =
  {|
[big_three]
models = ["ollama:qwen3.5:35b-a3b-nvfp4"]
|}

let render_or_fail toml_path =
  match Masc_mcp.Cascade_toml_materializer.render_toml_file_to_json_string toml_path with
  | Ok rendered -> rendered
  | Error msg -> failf "unexpected TOML render failure: %s" msg

let model_names_for_profile json profile_name =
  json
  |> member (profile_name ^ "_models")
  |> to_list
  |> List.map (function
       | `String model -> model
       | value -> value |> member "model" |> to_string)

let test_repo_seed_excludes_claude_from_automatic_profiles () =
  let rendered = render_or_fail (repo_toml_path ()) |> Yojson.Safe.from_string in
  let expect_profile_models profile_name expected =
    check (list string) (profile_name ^ " models")
      expected
      (model_names_for_profile rendered profile_name)
  in
  expect_profile_models "default"
    [ "codex_cli:auto"; "gemini_cli:auto"; "codex_cli:gpt-5.3-codex-spark" ];
  expect_profile_models "big_three"
    [ "codex_cli:auto"; "gemini_cli:auto"; "codex_cli:gpt-5.3-codex-spark" ];
  expect_profile_models "governance_judge" [ "gemini_cli:auto"; "codex_cli:auto" ];
  expect_profile_models "operator_judge" [ "gemini_cli:auto"; "codex_cli:auto" ];
  check bool "governance_judge is system-only" false
    (rendered |> member "governance_judge_keeper_assignable" |> to_bool);
  check bool "operator_judge is system-only" false
    (rendered |> member "operator_judge_keeper_assignable" |> to_bool)

let test_repo_toml_renders_to_committed_json () =
  let rendered = render_or_fail (repo_toml_path ()) in
  check string "repo cascade json stays in sync with toml"
    (read_file (repo_json_path ()))
    rendered

let test_fallback_cascade_field_is_parsed () =
  match
    Masc_mcp.Cascade_toml_materializer.render_toml_string_to_json_string
      {|
[ollama_only]
models = ["ollama:qwen3.6:27b-coding-nvfp4"]
fallback_cascade = "big_three"
|}
  with
  | Error msg -> failf "expected fallback_cascade to parse, got: %s" msg
  | Ok json_str ->
      let json = Yojson.Safe.from_string json_str in
      check string "fallback_cascade key is rendered"
        "big_three"
        (json |> member "ollama_only_fallback_cascade" |> to_string)

let test_keep_alive_field_is_parsed () =
  match
    Masc_mcp.Cascade_toml_materializer.render_toml_string_to_json_string
      {|
[ollama_only]
models = ["ollama:qwen3.6:27b-coding-nvfp4"]
keep_alive = "-1"
|}
  with
  | Error msg -> failf "expected keep_alive to parse, got: %s" msg
  | Ok json_str ->
      let json = Yojson.Safe.from_string json_str in
      check string "keep_alive key is rendered"
        "-1"
        (json |> member "ollama_only_keep_alive" |> to_string)

let test_keep_alive_duration_string_is_parsed () =
  match
    Masc_mcp.Cascade_toml_materializer.render_toml_string_to_json_string
      {|
[ollama_only]
models = ["ollama:qwen3.6:27b-coding-nvfp4"]
keep_alive = "30m"
|}
  with
  | Error msg -> failf "expected keep_alive duration string to parse, got: %s" msg
  | Ok json_str ->
      let json = Yojson.Safe.from_string json_str in
      check string "keep_alive duration is rendered as-is"
        "30m"
        (json |> member "ollama_only_keep_alive" |> to_string)

let test_keep_alive_absent_is_backward_compatible () =
  match
    Masc_mcp.Cascade_toml_materializer.render_toml_string_to_json_string
      {|
[ollama_only]
models = ["ollama:qwen3.6:27b-coding-nvfp4"]
|}
  with
  | Error msg -> failf "minimal profile must parse, got: %s" msg
  | Ok json_str ->
      let json = Yojson.Safe.from_string json_str in
      check bool "keep_alive key absent when not declared" true
        (match json |> member "ollama_only_keep_alive" with
         | `Null -> true
         | _ -> false)

let test_fallback_cascade_absent_is_backward_compatible () =
  match
    Masc_mcp.Cascade_toml_materializer.render_toml_string_to_json_string
      {|
[ollama_only]
models = ["ollama:qwen3.6:27b-coding-nvfp4"]
|}
  with
  | Error msg -> failf "minimal profile must parse, got: %s" msg
  | Ok json_str ->
      let json = Yojson.Safe.from_string json_str in
      check bool "fallback_cascade key absent when not declared" true
        (match json |> member "ollama_only_fallback_cascade" with
         | `Null -> true
         | _ -> false)

let test_loader_catalog_exposes_fallback_cascade () =
  with_temp_dir "cascade-fallback-loader" @@ fun dir ->
  let json_path = Filename.concat dir "cascade.json" in
  write_file json_path
    {|{
       "ollama_only_models": ["ollama:qwen3.6:27b-coding-nvfp4"],
       "ollama_only_fallback_cascade": "big_three",
       "big_three_models": ["codex_cli:auto"]
     }|};
  match
    Masc_mcp.Cascade_config_loader.load_catalog ~config_path:json_path
  with
  | Error msg -> failf "load_catalog failed: %s" msg
  | Ok entries ->
      let find_entry name =
        List.find_opt
          (fun (e : Masc_mcp.Cascade_config_loader.catalog_entry) ->
            String.equal e.name name)
          entries
      in
      (match find_entry "ollama_only" with
       | None -> fail "ollama_only entry missing"
       | Some entry ->
           check (option string) "ollama_only fallback_cascade hint"
             (Some "big_three") entry.fallback_cascade);
      (match find_entry "big_three" with
       | None -> fail "big_three entry missing"
       | Some entry ->
           check (option string) "big_three has no fallback_cascade"
             None entry.fallback_cascade)

let test_keeper_profile_drops_unknown_fallback_target () =
  with_temp_dir "cascade-fallback-unknown" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  let json_path = Filename.concat config_dir "cascade.json" in
  write_file json_path
    {|{
       "ollama_only_models": ["ollama:qwen3.6:27b-coding-nvfp4"],
       "ollama_only_fallback_cascade": "does_not_exist",
       "big_three_models": ["codex_cli:auto"]
     }|};
  with_config_dir config_dir @@ fun () ->
  check (option string)
    "unknown fallback target is dropped, not propagated"
    None
    (Masc_mcp.Keeper_cascade_profile.fallback_cascade_for "ollama_only")

let test_keeper_profile_resolves_known_fallback_target () =
  with_temp_dir "cascade-fallback-known" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  let json_path = Filename.concat config_dir "cascade.json" in
  write_file json_path
    {|{
       "ollama_only_models": ["ollama:qwen3.6:27b-coding-nvfp4"],
       "ollama_only_fallback_cascade": "big_three",
       "big_three_models": ["codex_cli:auto"]
     }|};
  with_config_dir config_dir @@ fun () ->
  check (option string) "known fallback target is exposed"
    (Some "big_three")
    (Masc_mcp.Keeper_cascade_profile.fallback_cascade_for "ollama_only")

let test_unknown_profile_field_is_rejected () =
  match
    Masc_mcp.Cascade_toml_materializer.render_toml_string_to_json_string
      {|
[big_three]
models = ["ollama:qwen3.5:35b-a3b-nvfp4"]
unknown_field = 1
|}
  with
  | Ok _ -> fail "unknown field should be rejected"
  | Error msg ->
      check bool "error mentions unknown field" true
        (contains_substring msg "unknown field")

let test_runtime_materializes_missing_json_on_load () =
  with_temp_dir "cascade-toml-materialize" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  write_file (Filename.concat config_dir "cascade.toml") minimal_toml;
  let json_path = Filename.concat config_dir "cascade.json" in
  check bool "json missing before load" false (Sys.file_exists json_path);
  with_config_dir config_dir @@ fun () ->
  match Masc_mcp.Cascade_catalog_runtime.inspect_active () with
  | Ok (Masc_mcp.Cascade_catalog_runtime.Validated _) ->
      check bool "json materialized on load" true (Sys.file_exists json_path);
      check bool "generated json contains profile key" true
        (contains_substring (read_file json_path) "big_three_models")
  | Ok _ -> fail "expected fully validated catalog"
  | Error rejection ->
      failf "unexpected validation failure: %s"
        (Yojson.Safe.to_string
           (Masc_mcp.Cascade_catalog_runtime.rejection_to_yojson rejection))

let test_runtime_rewrites_drifted_json_from_toml () =
  with_temp_dir "cascade-toml-drift" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  let toml_path = Filename.concat config_dir "cascade.toml" in
  let json_path = Filename.concat config_dir "cascade.json" in
  write_file toml_path minimal_toml;
  write_file json_path {|{"alpha_models":["ollama:qwen3.5:35b-a3b-nvfp4"]}|};
  let expected_json = render_or_fail toml_path in
  with_config_dir config_dir @@ fun () ->
  ignore (Masc_mcp.Cascade_catalog_runtime.inspect_active ());
  check string "drifted runtime json rewritten from toml"
    expected_json (read_file json_path)

let test_invalid_toml_blocks_runtime_without_using_stale_json () =
  with_temp_dir "cascade-toml-invalid" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  write_file
    (Filename.concat config_dir "cascade.toml")
    {|
[big_three]
models = ["ollama:qwen3.5:35b-a3b-nvfp4"]
unknown_field = 1
|};
  write_file
    (Filename.concat config_dir "cascade.json")
    {|{"big_three_models":["ollama:qwen3.5:35b-a3b-nvfp4"]}|};
  with_config_dir config_dir @@ fun () ->
  match Masc_mcp.Cascade_catalog_runtime.inspect_active () with
  | Ok _ -> fail "invalid toml should block runtime load"
  | Error rejection ->
      let rendered =
        Masc_mcp.Cascade_catalog_runtime.rejection_to_yojson rejection
        |> Yojson.Safe.to_string
      in
      check bool "rejection mentions unknown field" true
        (contains_substring rendered "unknown field")

(* Phase 2 regression: when load_json fails (malformed JSON, missing
   IO, or strict-field rejection on TOML side), the resolved
   selection_trace.source must be [Load_failed _], not the bug-prior
   [Hardcoded_defaults].  Without this, an operator viewing the
   dashboard cannot distinguish a config fault from an intentional
   absence of profile.  See PR #11361. *)
let test_load_failed_source_on_malformed_json () =
  with_temp_dir "cascade-load-failed" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  let json_path = Filename.concat config_dir "cascade.json" in
  write_file json_path "{ this is not valid json";
  with_config_dir config_dir @@ fun () ->
  let _, source =
    Masc_mcp.Cascade_config.resolve_model_strings_traced
      ~config_path:json_path
      ~name:"any_profile"
      ~defaults:[ "fallback-model" ]
      ()
  in
  match source with
  | Masc_mcp.Cascade_config.Load_failed _ -> ()
  | Masc_mcp.Cascade_config.Hardcoded_defaults ->
      fail
        "regression: malformed cascade.json collapsed to \
         Hardcoded_defaults instead of Load_failed (PR #11361)"
  | _ -> fail "expected Load_failed source variant"

let test_load_failed_source_on_unknown_toml_field () =
  with_temp_dir "cascade-load-failed-toml" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  write_file
    (Filename.concat config_dir "cascade.toml")
    {|
[big_three]
models = ["ollama:qwen3.5:35b-a3b-nvfp4"]
unknown_field_for_load_failed_test = "x"
|};
  with_config_dir config_dir @@ fun () ->
  let json_path = Filename.concat config_dir "cascade.json" in
  let _, source =
    Masc_mcp.Cascade_config.resolve_model_strings_traced
      ~config_path:json_path
      ~name:"big_three"
      ~defaults:[ "fallback-model" ]
      ()
  in
  match source with
  | Masc_mcp.Cascade_config.Load_failed msg ->
      check bool
        "Load_failed message mentions the rejected field" true
        (contains_substring msg "unknown_field_for_load_failed_test")
  | Masc_mcp.Cascade_config.Hardcoded_defaults ->
      fail
        "regression: TOML strict-field rejection collapsed to \
         Hardcoded_defaults instead of Load_failed (PR #11361)"
  | _ -> fail "expected Load_failed source variant"

let test_weight_zero_is_accepted () =
  (* #10571: weight=0 = "configured but disabled" (cascade dispatcher
     skips). #10097 introduced this idiom for codex_cli; pre-fix the
     materializer rejected it and dashboard cascade.json went stale on
     every reload. *)
  match
    Masc_mcp.Cascade_toml_materializer.render_toml_string_to_json_string
      {|
[default]
models = [
  { model = "codex_cli:auto", weight = 0 },
  { model = "gemini_cli:auto", weight = 1 },
]
|}
  with
  | Error msg -> failf "weight=0 must materialize, got: %s" msg
  | Ok _ -> ()

let test_weight_negative_is_rejected () =
  match
    Masc_mcp.Cascade_toml_materializer.render_toml_string_to_json_string
      {|
[default]
models = [
  { model = "codex_cli:auto", weight = -1 },
]
|}
  with
  | Ok _ -> failf "negative weight must be rejected"
  | Error msg ->
      check bool
        (Printf.sprintf "rejection mentions weight bound — got: %s" msg)
        true
        (let n = String.length msg and sub = "weight" in
         let m = String.length sub in
         let rec loop i =
           if i + m > n then false
           else if String.sub msg i m = sub then true
           else loop (i + 1)
         in
         loop 0)

let () =
  run "cascade_toml_materialization"
    [
      ( "repo_sync",
        [
          test_case "repo toml renders to committed json" `Quick
            test_repo_toml_renders_to_committed_json;
          test_case "repo seed excludes claude from automatic profiles" `Quick
            test_repo_seed_excludes_claude_from_automatic_profiles;
        ] );
      ( "validation",
        [
          test_case "unknown profile field is rejected" `Quick
            test_unknown_profile_field_is_rejected;
          test_case "fallback_cascade field is parsed" `Quick
            test_fallback_cascade_field_is_parsed;
          test_case "fallback_cascade absent is backward compatible" `Quick
            test_fallback_cascade_absent_is_backward_compatible;
          test_case "keep_alive field is parsed" `Quick
            test_keep_alive_field_is_parsed;
          test_case "keep_alive duration string is parsed" `Quick
            test_keep_alive_duration_string_is_parsed;
          test_case "keep_alive absent is backward compatible" `Quick
            test_keep_alive_absent_is_backward_compatible;
          test_case "loader catalog exposes fallback_cascade" `Quick
            test_loader_catalog_exposes_fallback_cascade;
          test_case "keeper profile drops unknown fallback target" `Quick
            test_keeper_profile_drops_unknown_fallback_target;
          test_case "keeper profile resolves known fallback target" `Quick
            test_keeper_profile_resolves_known_fallback_target;
          test_case "weight=0 is accepted (#10571 disabled-entry idiom)"
            `Quick test_weight_zero_is_accepted;
          test_case "negative weight is rejected" `Quick
            test_weight_negative_is_rejected;
          test_case "Load_failed source on malformed cascade.json"
            `Quick test_load_failed_source_on_malformed_json;
          test_case "Load_failed source on unknown toml field"
            `Quick test_load_failed_source_on_unknown_toml_field;
        ] );
      ( "runtime",
        [
          test_case "missing json materializes on load" `Quick
            test_runtime_materializes_missing_json_on_load;
          test_case "drifted json rewrites from toml" `Quick
            test_runtime_rewrites_drifted_json_from_toml;
          test_case "invalid toml blocks runtime without stale json fallback"
            `Quick test_invalid_toml_blocks_runtime_without_using_stale_json;
        ] );
    ]
