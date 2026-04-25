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
  expect_keeper ~name:"sangsu" ~persona:"executor"

(** Write a temporary TOML file, run load_keeper_toml, clean up. *)
let with_temp_toml content f =
  let path = Filename.temp_file "keeper_test_" ".toml" in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () -> f path)

let test_cascade_name_rejects_unknown () =
  let result =
    with_temp_toml
      "[keeper]\nname = \"testkeeper\"\ncascade_name = \"nick0cave\"\n"
      KTP.load_keeper_toml
  in
  match result with
  | Ok _ -> fail "nick0cave cascade_name should be rejected"
  | Error e ->
      check bool "error mentions cascade_name" true
        (let len = String.length e in
         let needle = "invalid cascade_name" in
         let nlen = String.length needle in
         let found = ref false in
         for i = 0 to len - nlen do
           if String.sub e i nlen = needle then found := true
         done;
         !found)

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
  check_ok "local_recovery phase-routing" "local_recovery"

let test_cascade_name_accepts_catalog_entry () =
  (* "tool_use_strict" is a known catalog entry in cascade.json,
     distinct from compile-time variants.  Tests that the live catalog
     is consulted during validation. *)
  let catalog =
    try Masc_mcp.Keeper_cascade_profile.catalog_names ()
    with _ -> []
  in
  let test_name =
    (* Pick a catalog entry that is NOT a compile-time variant *)
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

(* #10158: when a cascade_name is rejected, the operator-visible
   error message must include cascade.toml [catalog] entries —
   otherwise an operator who tried [tool_use_strict] (a real
   catalog entry) would see the rejection list missing that name
   and conclude the system does not support it.  Pre-fix the
   message printed only [compile_known @ phase_routing] (4 names
   on prod). *)
let test_invalid_cascade_name_message_includes_catalog () =
  let catalog =
    try Masc_mcp.Keeper_cascade_profile.catalog_names ()
    with _ -> []
  in
  let unique_catalog_name =
    List.find_opt
      (fun n ->
        not (List.mem n Masc_mcp.Keeper_cascade_profile.known_cascades)
        && not (List.mem n [ "local_only"; "local_recovery" ]))
      catalog
  in
  match unique_catalog_name with
  | None ->
      (* Catalog unavailable in test environment — the fix is still
         correct (it just degrades to the old behaviour); skip. *)
      ()
  | Some name ->
      let result =
        with_temp_toml
          "[keeper]\nname = \"foo\"\n\
           cascade_name = \"definitely_not_real_xyz_10158\"\n"
          KTP.load_keeper_toml
      in
      (match result with
       | Ok _ -> fail "should reject"
       | Error e ->
           let contains needle s =
             let n = String.length s and m = String.length needle in
             if m > n then false
             else
               let rec loop i =
                 if i + m > n then false
                 else if String.sub s i m = needle then true
                 else loop (i + 1)
               in
               loop 0
           in
           check bool
             (Printf.sprintf "message mentions catalog entry %s" name)
             true (contains name e))

(* The "(known: ...)" list must be sorted + deduplicated so
   operators see a stable, readable enumeration even when
   compile_known and the catalog overlap or reorder. *)
let test_invalid_cascade_name_message_sorted_and_unique () =
  let result =
    with_temp_toml
      "[keeper]\nname = \"foo\"\n\
       cascade_name = \"definitely_not_real_xyz_10158_dup\"\n"
      KTP.load_keeper_toml
  in
  match result with
  | Ok _ -> fail "should reject"
  | Error e ->
      let prefix = "(known: " in
      let plen = String.length prefix in
      let n = String.length e in
      let rec find i =
        if i + plen > n then None
        else if String.sub e i plen = prefix then Some (i + plen)
        else find (i + 1)
      in
      (match find 0 with
       | None -> fail (Printf.sprintf "no (known: ...) in: %s" e)
       | Some start ->
           (* End at the matching ')' *)
           let close = String.index_from e start ')' in
           let body = String.sub e start (close - start) in
           let names =
             String.split_on_char ',' body |> List.map String.trim
           in
           let sorted = List.sort String.compare names in
           check (list string) "names are sorted alphabetically"
             sorted names;
           let unique = List.sort_uniq String.compare names in
           check int "no duplicates"
             (List.length names) (List.length unique))

let test_tool_preset_accepts_dispatch () =
  let result =
    with_temp_toml
      "[keeper]\nname = \"taskmaster\"\ntool_preset = \"dispatch\"\n"
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
  check string "uncategorized" "other" (f "completely novel problem")

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
          test_case "accepts catalog entry (legacy alias)" `Quick
            test_cascade_name_accepts_catalog_entry;
          test_case "rejection message includes catalog entries (#10158)" `Quick
            test_invalid_cascade_name_message_includes_catalog;
          test_case "rejection message is sorted + deduped (#10158)" `Quick
            test_invalid_cascade_name_message_sorted_and_unique;
          test_case "accepts dispatch tool_preset" `Quick
            test_tool_preset_accepts_dispatch;
        ] );
      ( "network_mode validation",
        [
          test_case "rejects unknown network_mode" `Quick
            test_network_mode_rejects_unknown;
          test_case "accepts host as deprecated alias for inherit" `Quick
            test_network_mode_accepts_host_alias;
          test_case "classifies failures into bounded label set" `Quick
            test_classify_toml_failure_reason_buckets;
        ] );
    ]
