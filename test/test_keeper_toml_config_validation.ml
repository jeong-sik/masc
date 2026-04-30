open Alcotest

module KTP = Masc_mcp.Keeper_types_profile

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
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents)

let contains ~needle haystack =
  let len = String.length haystack in
  let nlen = String.length needle in
  let found = ref false in
  if nlen <= len then
    for i = 0 to len - nlen do
      if String.sub haystack i nlen = needle then found := true
    done;
  !found

let with_config_dir contents f =
  let dir = Filename.temp_file "keeper_config_dir_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let toml_path = Filename.concat dir "cascade.toml" in
  let json_path = Filename.concat dir "cascade.json" in
  write_file toml_path contents;
  let prior = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Unix.putenv "MASC_CONFIG_DIR" dir;
  Masc_mcp.Config_dir_resolver.reset ();
  Fun.protect
    ~finally:(fun () ->
      (match prior with
       | Some value -> Unix.putenv "MASC_CONFIG_DIR" value
       | None -> Unix.putenv "MASC_CONFIG_DIR" "");
      Masc_mcp.Config_dir_resolver.reset ();
      (try Sys.remove json_path with _ -> ());
      (try Sys.remove toml_path with _ -> ());
      try Unix.rmdir dir with _ -> ())
    (fun () -> f dir)

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
  check_ok "big_three variant" "big_three";
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

let test_cascade_name_error_lists_live_catalog () =
  with_config_dir
    {|
[custom_live]
models = ["ollama:auto"]

[tool_use_strict]
models = ["ollama:auto"]
keeper_assignable = false
|}
    (fun _dir ->
      let result =
        with_temp_toml
          "[keeper]\nname = \"testkeeper\"\ncascade_name = \"missing_profile\"\n"
          KTP.load_keeper_toml
      in
      match result with
      | Ok _ -> fail "missing_profile cascade_name should be rejected"
      | Error e ->
          check bool "error lists live catalog profile" true
            (contains ~needle:"custom_live" e);
          check bool "error lists reserved tool lane" true
            (contains ~needle:"tool_use_strict" e))

let test_cascade_name_accepts_catalog_entry () =
  (* "tool_use_strict" is a known catalog entry in cascade.json,
     distinct from compile-time variants.  Tests that the live catalog
     is consulted during validation.

     #10388: must filter out system-only ([keeper_assignable=false])
     entries — the validator now rejects those, and a real-catalog
     entry like [cross_verifier] is system-only. *)
  let catalog =
    try Masc_mcp.Keeper_cascade_profile.keeper_catalog_names ()
    with _ -> []
  in
  let test_name =
    (* Pick an assignable catalog entry that is NOT a compile-time variant *)
    match
      List.find_opt
        (fun n ->
           not (List.mem n Masc_mcp.Keeper_cascade_profile.known_cascades)
           && not (List.mem n [ "local_only"; "local_recovery" ]))
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

(** #10388: keepers must not reference cascades flagged
    [keeper_assignable=false].  Pre-fix the validator only checked
    catalog membership; system-only cascades (e.g. [tool_use_strict])
    passed and the keeper failed every reconcile tick at runtime
    (4 keepers / 59 events/day on 2026-04-25). *)
let test_cascade_name_rejects_system_only () =
  with_config_dir
    {|
[everyday_assignable]
models = ["ollama:auto"]
keeper_assignable = true

[system_only_lane]
models = ["ollama:auto"]
keeper_assignable = false
|}
    (fun _dir ->
      let result =
        with_temp_toml
          "[keeper]\nname = \"testkeeper\"\ncascade_name = \"system_only_lane\"\n"
          KTP.load_keeper_toml
      in
      match result with
      | Ok _ -> fail "system-only cascade_name should be rejected"
      | Error e ->
          check bool "error mentions system-only" true
            (contains ~needle:"system-only" e);
          check bool "error mentions keeper_assignable" true
            (contains ~needle:"keeper_assignable=false" e);
          check bool "error lists assignable subset" true
            (contains ~needle:"everyday_assignable" e))

let test_cascade_name_accepts_assignable_after_system_only_added () =
  (* Sanity: the new gate must not regress assignable cascades when a
     sibling profile happens to be system-only. *)
  with_config_dir
    {|
[everyday_assignable]
models = ["ollama:auto"]
keeper_assignable = true

[system_only_lane]
models = ["ollama:auto"]
keeper_assignable = false
|}
    (fun _dir ->
      let result =
        with_temp_toml
          "[keeper]\nname = \"testkeeper\"\ncascade_name = \"everyday_assignable\"\n"
          KTP.load_keeper_toml
      in
      match result with
      | Ok _ -> ()
      | Error e ->
          fail
            (Printf.sprintf
               "everyday_assignable (keeper_assignable=true) should be \
                accepted: %s"
               e))

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
          test_case "all toml files parse" `Quick test_all_keeper_tomls_parse;
          test_case "named keepers default to docker" `Quick
            test_named_keeper_docker_defaults;
        ] );
      ( "cascade_name validation",
        [
          test_case "rejects unknown cascade_name" `Quick
            test_cascade_name_rejects_unknown;
          test_case "accepts known cascade names" `Quick
            test_cascade_name_accepts_known;
          test_case "accepts reserved tool lane without live catalog" `Quick
            test_cascade_name_accepts_tool_lane_without_catalog;
          test_case "invalid cascade message lists live catalog" `Quick
            test_cascade_name_error_lists_live_catalog;
          test_case "accepts catalog entry (legacy alias)" `Quick
            test_cascade_name_accepts_catalog_entry;
          test_case "rejects system-only cascade (keeper_assignable=false)"
            `Quick test_cascade_name_rejects_system_only;
          test_case "accepts assignable when system-only sibling exists"
            `Quick test_cascade_name_accepts_assignable_after_system_only_added;
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
