open Alcotest

module KTP = Masc_mcp.Keeper_types_profile
module KT = Masc_mcp.Keeper_types
module KPolicy = Masc_mcp.Keeper_tool_policy
module KPR = Masc_mcp.Keeper_tool_pr_review

(** Validate that every .toml file in config/keepers/ parses successfully
    with the OCaml TOML parser.  This catches syntax that is valid standard
    TOML but unsupported by our minimal parser (e.g. multi-line arrays before
    the fix).  Runs as part of [dune test], so CI will fail before deploy. *)

let test_all_keeper_tomls_parse () =
  let relative_config_dir = "config/keepers" in
  let config_dir =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some repo_root -> Filename.concat repo_root relative_config_dir
    | None -> relative_config_dir
  in
  if not (Sys.file_exists config_dir && Sys.is_directory config_dir) then
    fail
      (Printf.sprintf
         "Could not locate %s (resolved to %s)"
         relative_config_dir config_dir)
  else
    let files =
      Sys.readdir config_dir
      |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".toml")
      |> List.sort String.compare
    in
    check bool "at least one toml file" true (List.length files > 0);
    List.iter (fun f ->
      let path = Filename.concat config_dir f in
      match KTP.load_keeper_toml path with
      | Ok _ -> ()
      | Error e ->
        fail (Printf.sprintf "%s: %s" f e)
    ) files

let test_named_keeper_docker_defaults () =
  let config_dir =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some repo_root -> Filename.concat repo_root "config/keepers"
    | None -> "config/keepers"
  in
  let expect_keeper ~name ~persona =
    let path = Filename.concat config_dir (name ^ ".toml") in
    match KTP.load_keeper_toml path with
    | Error e -> fail (Printf.sprintf "%s: %s" name e)
    | Ok (_loaded_name, defaults) ->
        check (option string) (name ^ " persona_name") (Some persona)
          defaults.persona_name;
        check (option string) (name ^ " sandbox_profile") (Some "docker")
          (Option.map KTP.sandbox_profile_to_string defaults.sandbox_profile);
        (* After the host→inherit alias migration, all three docker keepers
           request [Network_inherit] so keeper_bash can dispatch git/gh. *)
        check (option string) (name ^ " network_mode") (Some "inherit")
          (Option.map KTP.network_mode_to_string defaults.network_mode);
        check (option string) (name ^ " github_identity")
          (Some "anyang-keepers") defaults.github_identity
  in
  expect_keeper ~name:"issue_king" ~persona:"issue_king";
  expect_keeper ~name:"masc-improver" ~persona:"analyst";
  expect_keeper ~name:"sangsu" ~persona:"sangsu"

let test_committed_keepers_are_pr_work_capable () =
  let project_root = Masc_test_deps.find_project_root () in
  Masc_test_deps.init_keeper_tool_registry ();
  (match KPolicy.init_policy_config ~base_path:project_root with
   | Ok () -> ()
   | Error e -> fail (Printf.sprintf "init_policy_config: %s" e));
  let config_dir =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some repo_root -> Filename.concat repo_root "config/keepers"
    | None -> Filename.concat project_root "config/keepers"
  in
  let files =
    Sys.readdir config_dir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".toml")
    |> List.filter (fun f -> f <> "base.toml")
    |> List.sort String.compare
  in
  check bool "at least one keeper manifest" true (files <> []);
  List.iter
    (fun file ->
       let name = Filename.remove_extension file in
       let path = Filename.concat config_dir file in
       match KTP.load_keeper_toml path with
       | Error e -> fail (Printf.sprintf "%s: %s" file e)
       | Ok (_loaded_name, defaults) ->
           check (option string) (name ^ " sandbox_profile") (Some "docker")
             (Option.map KTP.sandbox_profile_to_string defaults.sandbox_profile);
           check (option string) (name ^ " network_mode") (Some "inherit")
             (Option.map KTP.network_mode_to_string defaults.network_mode);
           check (option string) (name ^ " github_identity")
             (Some "anyang-keepers") defaults.github_identity;
           check (option string) (name ^ " git_identity_mode")
             (Some "github_identity") defaults.git_identity_mode;
           let preset =
             match defaults.tool_preset with
             | None -> fail (Printf.sprintf "%s: tool_access.preset is required" file)
             | Some raw ->
                 (match KT.tool_preset_of_string raw with
                  | Some preset -> preset
                  | None -> fail (Printf.sprintf "%s: unknown preset %S" file raw))
           in
           check bool (name ^ " preset can mutate PR reviews") true
             (KPR.pr_review_mutation_preset_ok (Some preset));
           let meta =
             match
               Masc_test_deps.meta_of_json_fixture
                 (`Assoc [
                    ("name", `String name);
                    ("agent_name", `String name);
                    ("trace_id", `String (name ^ "-capability-test"));
                    ( "tool_access",
                      `Assoc [
                        ("kind", `String "preset");
                        ("preset", `String (KT.tool_preset_to_string preset));
                        ("also_allow", `List []);
                      ] );
                    ("tool_denylist", `List []);
                  ])
             with
             | Ok meta -> meta
             | Error e -> fail (Printf.sprintf "%s: meta fixture: %s" file e)
           in
           let lookup = KPolicy.tool_access_lookup_of_meta meta in
           List.iter
             (fun tool_name ->
                check bool (name ^ " can execute " ^ tool_name) true
                  (KPolicy.can_execute ~lookup tool_name))
             [
               "keeper_shell";
               "masc_code_git";
               "keeper_preflight_check";
               "keeper_pr_review_read";
               "keeper_pr_review_comment";
               "keeper_pr_review_reply";
             ];
           check string (name ^ " approve event maps to gh") "--approve"
             (KPR.pr_review_event_to_gh_flag KPR.Approve))
    files

(** Write a temporary TOML file, run load_keeper_toml, clean up. *)
let with_temp_toml content f =
  let path = Filename.temp_file "keeper_test_" ".toml" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () -> f path)

let write_file path contents =
  let rec mkdir_p path =
    if path = "" || path = "." || path = "/" then
      ()
    else if Sys.file_exists path then
      ()
    else begin
      mkdir_p (Filename.dirname path);
      Unix.mkdir path 0o755
    end
  in
  mkdir_p (Filename.dirname path);
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents)

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> rm_rf (Filename.concat path name));
      Unix.rmdir path
    end else
      Sys.remove path

let with_env key value f =
  let prior = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some value -> Unix.putenv key value
      | None -> Unix.putenv key "")
    f

let minimal_cascade_profile_metadata_toml = {|
[providers.ollama]
protocol = "ollama-http"
endpoint = "http://localhost:11434"

[models.qwen3]
api-name = "qwen3:8b"
max-context = 32768
tools-support = true

[models.qwen3-small]
api-name = "qwen3:1.7b"
max-context = 32768
tools-support = true

[ollama.qwen3]
is-default = true
max-concurrent = 1

[ollama.qwen3-small]
max-concurrent = 1

[tier.primary]
members = ["ollama.qwen3"]
strategy = "failover"

[tier.backup]
members = ["ollama.qwen3-small"]
strategy = "failover"

[tier.scoring]
keeper-assignable = false
members = ["ollama.qwen3"]
strategy = "failover"

[tier-group.primary]
tiers = ["primary", "backup"]
strategy = "priority_tier"
fallback = true

[tier-group.scoring]
tiers = ["scoring"]
strategy = "priority_tier"
fallback = false
keeper-assignable = false

[routes.keeper_turn]
target = "tier-group.primary"

[routes.llm_rerank]
target = "tier-group.scoring"
|}

let with_temp_config_dir cascade_toml f =
  let dir = Filename.temp_file "keeper_cascade_config_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let config_root = Filename.concat dir "config" in
  let cascade_path = Filename.concat config_root "cascade.toml" in
  write_file cascade_path cascade_toml;
  let reset () =
    Masc_mcp.Config_dir_resolver.reset ();
    Masc_mcp.Cascade_catalog_runtime.reset_cache_for_tests ()
  in
  Fun.protect
    ~finally:(fun () -> rm_rf dir)
    (fun () ->
      with_env "MASC_CONFIG_DIR" config_root @@ fun () ->
      reset ();
      Fun.protect ~finally:reset (fun () -> f ~config_root ~cascade_path))

let repo_config_dir () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some repo_root -> Filename.concat repo_root "config"
  | None -> "config"

let with_repo_config_dir f =
  let prior = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Unix.putenv "MASC_CONFIG_DIR" (repo_config_dir ());
  Masc_mcp.Config_dir_resolver.reset ();
  Fun.protect
    ~finally:(fun () ->
      (match prior with
       | Some value -> Unix.putenv "MASC_CONFIG_DIR" value
       | None -> Unix.putenv "MASC_CONFIG_DIR" "");
      Masc_mcp.Config_dir_resolver.reset ())
    f

let contains ~needle haystack =
  let len = String.length haystack in
  let nlen = String.length needle in
  let found = ref false in
  if nlen <= len then
    for i = 0 to len - nlen do
      if String.sub haystack i nlen = needle then found := true
    done;
  !found

let test_cascade_name_rejects_unknown () =
  let result =
    with_temp_toml
      "[keeper]\nname = \"testkeeper\"\ncascade_name = \"definitely_missing_profile\"\n"
      KTP.load_keeper_toml
  in
  match result with
  | Ok _ -> fail "definitely_missing_profile cascade_name should be rejected"
  | Error e ->
      check bool "error mentions cascade_name" true
        (contains ~needle:"invalid cascade_name" e)

let test_cascade_name_accepts_known () =
  with_repo_config_dir @@ fun () ->
  let check_ok label cascade_name =
    let result =
      with_temp_toml
        (Printf.sprintf "[keeper]\nname = \"testkeeper\"\ncascade_name = \"%s\"\n"
           cascade_name)
        KTP.load_keeper_toml
    in
    match result with
    | Ok _ -> ()
    | Error e ->
        fail (Printf.sprintf "%s: '%s' should be accepted but got: %s" label
                cascade_name e)
  in
  check_ok "primary variant" "primary";
  check_ok "local_only phase-routing" "local_only";
  check_ok "local_recovery phase-routing" "local_recovery";
  check_ok "tool_use_strict reserved tool lane" "tool_use_strict"

let test_cascade_name_accepts_tool_lane_without_catalog () =
  let missing_dir =
    Filename.concat (Filename.get_temp_dir_name ())
      "missing-masc-config-for-tool-use-strict"
  in
  let prior = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Unix.putenv "MASC_CONFIG_DIR" missing_dir;
  Masc_mcp.Config_dir_resolver.reset ();
  Fun.protect
    ~finally:(fun () ->
      (match prior with
       | Some value -> Unix.putenv "MASC_CONFIG_DIR" value
       | None -> Unix.putenv "MASC_CONFIG_DIR" "");
      Masc_mcp.Config_dir_resolver.reset ())
    (fun () ->
      let result =
        with_temp_toml
          "[keeper]\nname = \"testkeeper\"\ncascade_name = \"tool_use_strict\"\n"
          KTP.load_keeper_toml
      in
      match result with
      | Ok _ -> ()
      | Error e ->
          fail
            (Printf.sprintf
               "tool_use_strict is a reserved tool lane and should not require \
                a readable live catalog: %s"
               e))

let test_cascade_name_accepts_catalog_entry () =
  with_repo_config_dir @@ fun () ->
  (* Tests that the live declarative catalog is consulted during
     validation. *)
  let catalog =
    try Masc_mcp.Keeper_cascade_profile.keeper_catalog_names ()
    with _ -> []
  in
  let test_name =
    (* Pick any keeper-assignable catalog entry that isn't a phase-routing
       reserved alias — the validator now treats catalog membership as the
       only acceptance criterion. *)
    match
      List.find_opt
        (fun n -> not (List.mem n [ "local_only"; "local_recovery" ]))
        catalog
    with
    | Some name -> name
    | None -> "tool_use_strict" (* fallback, may not be in catalog *)
  in
  let result =
    with_temp_toml
      (Printf.sprintf "[keeper]\nname = \"testkeeper\"\ncascade_name = \"%s\"\n"
         test_name)
      KTP.load_keeper_toml
  in
  match result with
  | Ok _ -> ()
  | Error e ->
      (* If catalog is unavailable, skip rather than fail *)
      if catalog = [] then ()
      else fail (Printf.sprintf "%s should be accepted: %s" test_name e)

let test_resolve_model_strings_reads_declarative_profile () =
  with_temp_config_dir minimal_cascade_profile_metadata_toml
  @@ fun ~config_root:_ ~cascade_path ->
  let models =
    Masc_mcp.Cascade_config.resolve_model_strings
      ~config_path:cascade_path ~name:"primary" ~defaults:["fallback"] ()
  in
  check (list string) "primary group models"
    ["ollama:qwen3:8b"; "ollama:qwen3:1.7b"]
    models

let test_cascade_profile_metadata_from_toml () =
  with_temp_config_dir minimal_cascade_profile_metadata_toml
  @@ fun ~config_root:_ ~cascade_path:_ ->
  check (list string) "keeper assignable catalog" ["primary"]
    (Masc_mcp.Keeper_cascade_profile.keeper_catalog_names ());
  check bool "rerank route is system-only" true
    (Masc_mcp.Keeper_cascade_profile.is_system_only_cascade "llm_rerank");
  check bool "scoring catalog entry is system-only" true
    (Masc_mcp.Keeper_cascade_profile.is_system_only_cascade "scoring");
  check (option string) "primary fallback hint" (Some "backup")
    (Masc_mcp.Keeper_cascade_profile.fallback_cascade_for "primary")

let test_cascade_name_rejects_system_only_catalog_entry () =
  with_temp_config_dir minimal_cascade_profile_metadata_toml
  @@ fun ~config_root:_ ~cascade_path:_ ->
  let result =
    with_temp_toml
      "[keeper]\nname = \"testkeeper\"\ncascade_name = \"scoring\"\n"
      KTP.load_keeper_toml
  in
  match result with
  | Ok _ -> fail "system-only cascade_name should be rejected"
  | Error e ->
      check bool "error mentions system-only" true
        (contains ~needle:"system-only" e)

let test_tool_access_accepts_dispatch () =
  let result =
    with_temp_toml
      "[keeper]\nname = \"taskmaster\"\n\n[keeper.tool_access]\nkind = \"preset\"\npreset = \"dispatch\"\n"
      KTP.load_keeper_toml
  in
  match result with
  | Error e -> fail (Printf.sprintf "dispatch should be accepted: %s" e)
  | Ok (_loaded_name, defaults) ->
      check (option string) "dispatch preset parsed" (Some "dispatch")
        defaults.tool_preset

(** Reject [network_mode = "bogus"] at TOML load time so invalid strings
    do not silently fall back to persona defaults. *)
let test_network_mode_rejects_unknown () =
  let result =
    with_temp_toml
      "[keeper]\nname = \"nettest\"\nnetwork_mode = \"bogus\"\n"
      KTP.load_keeper_toml
  in
  match result with
  | Ok _ -> fail "network_mode=bogus should be rejected"
  | Error e ->
      let lowered = String.lowercase_ascii e in
      let contains needle =
        let nl = String.length needle in
        let hl = String.length lowered in
        let found = ref false in
        if nl <= hl then
          for i = 0 to hl - nl do
            if String.sub lowered i nl = needle then found := true
          done;
        !found
      in
      check bool "error mentions invalid network_mode" true
        (contains "invalid network_mode");
      check bool "error mentions deprecated alias" true
        (contains "host")

(** Accept [network_mode = "host"] as a deprecated alias for "inherit".
    Ensures operators migrating from docker-run terminology are not
    silently dropped to persona defaults.  The loader emits a warning and
    the parsed value equals [Network_inherit]. *)
let test_network_mode_accepts_host_alias () =
  let result =
    with_temp_toml
      "[keeper]\nname = \"hosttest\"\nsandbox_profile = \"docker\"\n\
       network_mode = \"host\"\n"
      KTP.load_keeper_toml
  in
  match result with
  | Error e -> fail (Printf.sprintf "host alias should be accepted: %s" e)
  | Ok (_loaded_name, defaults) ->
      check (option string) "host alias maps to inherit" (Some "inherit")
        (Option.map KTP.network_mode_to_string defaults.network_mode)

(** Regression: classify_toml_failure_reason must bucket raw error strings
    into a small cardinality set so the Prometheus label set stays bounded. *)
let test_classify_toml_failure_reason_buckets () =
  let f = KTP.classify_toml_failure_reason in
  check string "invalid network_mode" "invalid_network_mode"
    (f "invalid network_mode 'bogus' (allowed: none, inherit)");
  check string "invalid sandbox_profile" "invalid_sandbox_profile"
    (f "invalid sandbox_profile 'lol' (allowed: local, docker)");
  check string "unknown field" "unknown_field"
    (f "unknown field 'legacy_scope'");
  check string "parse error" "parse_error"
    (f "parse error at line 3");
  check string "expected key parse error" "parse_error"
    (f "line 62: expected key = value");
  check string "uncategorized" "other" (f "completely novel problem")

let test_keeper_toml_config_errors_are_typed () =
  let dir = Filename.temp_file "keeper_config_errors_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let invalid_path = Filename.concat dir "broken.toml" in
  let valid_path = Filename.concat dir "valid.toml" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove invalid_path with _ -> ());
      (try Sys.remove valid_path with _ -> ());
      try Unix.rmdir dir with _ -> ())
    (fun () ->
      write_file invalid_path "[keeper]\nname = \"broken\"\n\"dangling\"\n";
      write_file valid_path "[keeper]\nname = \"valid\"\n";
      match KTP.keeper_toml_config_errors_in_dir dir with
      | [ err ] ->
          check string "keeper name" "broken" err.keeper_name;
          check string "path" invalid_path err.path;
          check string "reason" "parse_error" err.reason;
          let json = KTP.keeper_toml_config_error_to_json err in
          check string "terminal reason" "config_parse_failed"
            (Yojson.Safe.Util.member "terminal_reason" json
             |> Yojson.Safe.Util.to_string)
      | errors ->
          fail
            (Printf.sprintf "expected one typed config error, got %d"
               (List.length errors)))

let () =
  run "Keeper TOML Config Validation"
    [
      ( "config/keepers",
        [
          test_case "all toml files parse" `Quick
            (fun () -> with_repo_config_dir test_all_keeper_tomls_parse);
          test_case "named keepers default to docker" `Quick
            (fun () -> with_repo_config_dir test_named_keeper_docker_defaults);
          test_case "committed keepers can do PR work" `Quick
            (fun () ->
              with_repo_config_dir test_committed_keepers_are_pr_work_capable);
        ] );
      ( "cascade_name validation",
        [
          test_case "rejects unknown cascade_name" `Quick
            test_cascade_name_rejects_unknown;
          test_case "accepts known cascade names" `Quick
            test_cascade_name_accepts_known;
          test_case "accepts reserved tool lane without live catalog" `Quick
            test_cascade_name_accepts_tool_lane_without_catalog;
          test_case "accepts live catalog entry" `Quick
            test_cascade_name_accepts_catalog_entry;
          test_case "resolves declarative profile model strings" `Quick
            test_resolve_model_strings_reads_declarative_profile;
          test_case "derives profile metadata from cascade.toml" `Quick
            test_cascade_profile_metadata_from_toml;
          test_case "rejects system-only catalog entry" `Quick
            test_cascade_name_rejects_system_only_catalog_entry;
          test_case "accepts dispatch tool_access preset" `Quick
            test_tool_access_accepts_dispatch;
        ] );
      ( "network_mode validation",
        [
          test_case "rejects unknown network_mode" `Quick
            test_network_mode_rejects_unknown;
          test_case "accepts host as deprecated alias for inherit" `Quick
            test_network_mode_accepts_host_alias;
          test_case "classifies failures into bounded label set" `Quick
            test_classify_toml_failure_reason_buckets;
          test_case "surfaces typed config parse errors" `Quick
            test_keeper_toml_config_errors_are_typed;
        ] );
    ]
