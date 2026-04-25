(** Smoke tests for {!Dashboard_cascade} — the dashboard projection
    of cascade config + health tracker.

    These tests exercise the JSON-shape contract the HTTP routes rely on.
    They do not hit the network or the real cascade.json — they validate
    that each top-level field exists with the expected type so a schema
    regression is caught without starting the server. *)

open Alcotest

let json : Yojson.Safe.t testable =
  let pp fmt j = Format.fprintf fmt "%s" (Yojson.Safe.to_string j) in
  testable pp Yojson.Safe.equal

let member key = Yojson.Safe.Util.member key

let to_list_opt = function
  | `List xs -> Some xs
  | _ -> None

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

let write_file path contents =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents)

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
       let len = in_channel_length ic in
       really_input_string ic len)

let with_temp_config_root_setup setup f =
  let dir = Filename.temp_file "dashboard-cascade-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let prev_config_dir = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      (match prev_config_dir with
       | Some value -> Unix.putenv "MASC_CONFIG_DIR" value
       | None -> Unix.putenv "MASC_CONFIG_DIR" "");
      Masc_mcp.Config_dir_resolver.reset ();
      rm_rf dir)
    (fun () ->
      setup dir;
      Unix.putenv "MASC_CONFIG_DIR" dir;
      Masc_mcp.Config_dir_resolver.reset ();
      f dir)

let with_temp_config_root contents f =
  with_temp_config_root_setup
    (fun dir -> write_file (Filename.concat dir "cascade.json") contents)
    (fun dir -> f (Filename.concat dir "cascade.json"))

let profile_names json =
  match member "profiles" json with
  | `List profiles ->
      List.filter_map
        (fun profile ->
           match member "name" profile with
           | `String name -> Some name
           | _ -> None)
        profiles
  | _ -> []

let profile_by_name json target =
  match member "profiles" json with
  | `List profiles ->
      List.find_opt
        (fun profile ->
           match member "name" profile with
           | `String name -> String.equal name target
           | _ -> false)
        profiles
  | _ -> None

let with_dashboard_snapshot f =
  Masc_mcp.Cascade_catalog_runtime.reset_cache_for_tests ();
  Masc_mcp.Cascade_catalog_runtime.install_snapshot_for_tests
    ~source_path:"/tmp/dashboard-cascade-test.json"
    ~profile_names:[ Masc_mcp.Keeper_config.default_cascade_name ];
  Fun.protect
    ~finally:Masc_mcp.Cascade_catalog_runtime.reset_cache_for_tests
    f
(* ── config_json ───────────────────────────────────── *)

let test_config_shape () =
  with_dashboard_snapshot @@ fun () ->
  let j = Masc_mcp.Dashboard_cascade.config_json () in
  (* Required top-level keys *)
  (match member "updated_at" j with
   | `String _ -> () | _ -> fail "updated_at should be string");
  (match member "config_path" j with
   | `String _ | `Null -> ()
   | _ -> fail "config_path should be string or null");
  (match member "source_kind" j with
   | `String ("json" | "toml") -> ()
   | _ -> fail "source_kind should be json or toml");
  (match member "source_path" j with
   | `String _ -> ()
   | _ -> fail "source_path should be string");
  (match member "validation_status" j with
   | `String ("validated" | "serving_valid_subset" | "serving_last_known_good" | "invalid") -> ()
   | _ -> fail "validation_status should be known string");
  (match member "validation_errors" j with
   | `List _ -> ()
   | _ -> fail "validation_errors should be list");
  (match member "invalid_profiles" j with
   | `List _ -> ()
   | _ -> fail "invalid_profiles should be list");
  (match member "profiles" j with
   | `List _ -> () | _ -> fail "profiles should be list");
  (match member "keeper_profiles" j with
   | `List _ -> () | _ -> fail "keeper_profiles should be list")

let test_config_validated_status () =
  with_temp_config_root
    {|
      {
        "big_three_models": ["ollama:qwen3.5:35b-a3b-nvfp4"]
      }
    |}
    (fun cascade_path ->
      Masc_mcp.Cascade_catalog_runtime.reset_cache_for_tests ();
      Masc_mcp.Cascade_catalog_runtime.install_snapshot_for_tests
        ~source_path:cascade_path
        ~profile_names:[ Masc_mcp.Keeper_config.default_cascade_name ];
      Fun.protect
        ~finally:Masc_mcp.Cascade_catalog_runtime.reset_cache_for_tests
        (fun () ->
           let j = Masc_mcp.Dashboard_cascade.config_json () in
           check string "validated status" "validated"
             Yojson.Safe.Util.(j |> member "validation_status" |> to_string);
           check int "validation errors empty" 0
             Yojson.Safe.Util.(j |> member "validation_errors" |> to_list |> List.length);
           check int "invalid profiles empty" 0
             Yojson.Safe.Util.(j |> member "invalid_profiles" |> to_list |> List.length)))

let test_config_profile_shape () =
  with_dashboard_snapshot @@ fun () ->
  let j = Masc_mcp.Dashboard_cascade.config_json () in
  match to_list_opt (member "profiles" j) with
  | None | Some [] -> fail "expected at least one profile"
  | Some (p :: _) ->
    (match member "name" p with
     | `String _ -> () | _ -> fail "profile.name should be string");
    (match member "source" p with
     | `String s when List.mem s ["named"; "default_fallback"; "hardcoded_defaults"] -> ()
     | `String s -> fail (Printf.sprintf "unexpected source: %s" s)
     | _ -> fail "profile.source should be string");
    (match member "keeper_assignable" p with
     | `Bool _ -> ()
     | _ -> fail "profile.keeper_assignable should be bool");
    (match member "candidates" p with
     | `List _ -> () | _ -> fail "profile.candidates should be list")

let test_config_candidate_shape () =
  with_dashboard_snapshot @@ fun () ->
  let j = Masc_mcp.Dashboard_cascade.config_json () in
  let rec first_nonempty_candidates = function
    | [] -> None
    | p :: rest ->
      (match to_list_opt (member "candidates" p) with
       | Some (c :: _) -> Some c
       | _ -> first_nonempty_candidates rest)
  in
  match to_list_opt (member "profiles" j) with
  | None -> fail "profiles missing"
  | Some profiles ->
    (match first_nonempty_candidates profiles with
     | None -> () (* No candidates is allowed when config_path is None *)
     | Some c ->
       let fields = ["model"; "config_weight"; "effective_weight";
                     "success_rate"; "in_cooldown"] in
       List.iter (fun k ->
         match member k c with
         | `Null -> fail (Printf.sprintf "candidate.%s missing" k)
         | _ -> ()) fields)

let test_config_uses_live_catalog () =
  with_temp_config_root
    {|
      {
        "default_models": ["ollama:qwen3.5:35b-a3b-nvfp4"],
        "custom_live_models": ["ollama:qwen3.5:35b-a3b-nvfp4"],
        "governance_judge_models": ["ollama:qwen3.5:35b-a3b-nvfp4"],
        "governance_judge_keeper_assignable": false,
        "tool_rerank_temperature": 0.0,
        "tool_rerank_max_tokens": 200,
        "tool_rerank_keeper_assignable": false
      }
    |}
    (fun cascade_path ->
      let j = Masc_mcp.Dashboard_cascade.config_json () in
      let names = profile_names j in
      check bool "includes dynamic live profile" true
        (List.mem "custom_live" names);
      check bool "includes system-only live profile" true
        (List.mem "governance_judge" names);
      check bool "includes profiles declared by non-model schema keys" true
        (List.mem "tool_rerank" names);
      let assert_keeper_assignable name expected =
        match profile_by_name j name with
        | Some profile ->
            check bool (name ^ " keeper_assignable")
              expected
              Yojson.Safe.Util.(profile |> member "keeper_assignable" |> to_bool)
        | None -> fail (Printf.sprintf "missing profile %s" name)
      in
      assert_keeper_assignable "custom_live" true;
      assert_keeper_assignable "governance_judge" false;
      assert_keeper_assignable "tool_rerank" false;
      check (option string) "config_path reflects active root"
        (Some cascade_path)
        Yojson.Safe.Util.(j |> member "config_path" |> to_string_option))

let test_config_invalid_catalog_surfaces_validation_metadata () =
  with_temp_config_root
    {|
      {
        "broken_profile_models": ["__nonexistent_provider_sentinel__:fake"]
      }
    |}
    (fun _cascade_path ->
      Masc_mcp.Cascade_catalog_runtime.reset_cache_for_tests ();
      Fun.protect
        ~finally:Masc_mcp.Cascade_catalog_runtime.reset_cache_for_tests
        (fun () ->
           let j = Masc_mcp.Dashboard_cascade.config_json () in
           check string "invalid status" "invalid"
             Yojson.Safe.Util.(j |> member "validation_status" |> to_string);
           check bool "invalid provider surfaced in metadata" true
             (contains_substring (Yojson.Safe.to_string j)
                "__nonexistent_provider_sentinel__");
           check bool "broken profile listed" true
             (Yojson.Safe.Util.(j |> member "invalid_profiles" |> to_list)
              |> List.exists (fun profile ->
                     match member "name" profile with
                     | `String "broken_profile" -> true
                     | _ -> false))))

(* ── raw_config_json / save_raw_config_json ───────────────────── *)

let test_raw_config_shape () =
  with_temp_config_root
    {|
      {
        "big_three_models": ["ollama:qwen3.5:35b-a3b-nvfp4"]
      }
    |}
    (fun cascade_path ->
      let j = Masc_mcp.Dashboard_cascade.raw_config_json () in
      let raw_json = Yojson.Safe.Util.(j |> member "raw_json" |> to_string) in
      let source_text = Yojson.Safe.Util.(j |> member "source_text" |> to_string) in
      (match member "updated_at" j with
       | `String _ -> ()
       | _ -> fail "updated_at should be string");
      check (option string) "config_path reflects active root"
        (Some cascade_path)
        Yojson.Safe.Util.(j |> member "config_path" |> to_string_option);
      check string "json source kind" "json"
        Yojson.Safe.Util.(j |> member "source_kind" |> to_string);
      check string "json source path" cascade_path
        Yojson.Safe.Util.(j |> member "source_path" |> to_string);
      check bool "source remains editable" true
        Yojson.Safe.Util.(j |> member "source_editable" |> to_bool);
      check bool "json raw is editable" true
        Yojson.Safe.Util.(j |> member "raw_json_editable" |> to_bool);
      check bool "source_text includes current file contents" true
        (contains_substring source_text "big_three_models");
      check bool "raw_json includes current file contents" true
        (contains_substring raw_json "big_three_models"))

let test_raw_config_defaults_when_file_missing () =
  with_temp_config_root "{}\n"
    (fun cascade_path ->
      Sys.remove cascade_path;
      let j = Masc_mcp.Dashboard_cascade.raw_config_json () in
      check (option string) "config_path still known"
        (Some cascade_path)
        Yojson.Safe.Util.(j |> member "config_path" |> to_string_option);
      check bool "still editable in json mode" true
        Yojson.Safe.Util.(j |> member "raw_json_editable" |> to_bool);
      check string "missing source file seeds default object"
        "{}\n"
        Yojson.Safe.Util.(j |> member "source_text" |> to_string);
      check string "missing file seeds default object"
        "{}\n"
        Yojson.Safe.Util.(j |> member "raw_json" |> to_string))

let test_raw_config_toml_source_exposes_editable_source_and_preview () =
  let toml =
    {|
comment = "test"

[big_three]
models = ["ollama:qwen3.5:35b-a3b-nvfp4"]
|}
  in
  with_temp_config_root_setup
    (fun dir -> write_file (Filename.concat dir "cascade.toml") toml)
    (fun dir ->
      let json_path = Filename.concat dir "cascade.json" in
      let toml_path = Filename.concat dir "cascade.toml" in
      let j = Masc_mcp.Dashboard_cascade.raw_config_json () in
      check (option string) "runtime json path still surfaced"
        (Some json_path)
        Yojson.Safe.Util.(j |> member "config_path" |> to_string_option);
      check string "toml source kind" "toml"
        Yojson.Safe.Util.(j |> member "source_kind" |> to_string);
      check string "toml source path" toml_path
        Yojson.Safe.Util.(j |> member "source_path" |> to_string);
      check bool "source stays editable in toml mode" true
        Yojson.Safe.Util.(j |> member "source_editable" |> to_bool);
      check bool "generated json preview stays read-only" false
        Yojson.Safe.Util.(j |> member "raw_json_editable" |> to_bool);
      check bool "source text surfaces toml contents" true
        (contains_substring
           Yojson.Safe.Util.(j |> member "source_text" |> to_string)
           "[big_three]");
      check bool "generated runtime json visible" true
        (contains_substring
           Yojson.Safe.Util.(j |> member "raw_json" |> to_string)
           "big_three_models");
      check bool "runtime json materialized on read" true
        (Sys.file_exists json_path))

let test_save_raw_config_json_rejects_invalid_json () =
  with_temp_config_root "{}\n"
    (fun _cascade_path ->
      match Masc_mcp.Dashboard_cascade.save_raw_config_json "{ invalid" with
      | Ok _ -> fail "invalid JSON should be rejected"
      | Error msg ->
          check bool "error mentions invalid JSON" true
            (contains_substring msg "invalid JSON"))

let test_save_raw_config_json_persists_and_refreshes_projection () =
  with_temp_config_root
    {|
      {
        "alpha_models": ["ollama:qwen3.5:35b-a3b-nvfp4"]
      }
    |}
    (fun cascade_path ->
      let before = Masc_mcp.Dashboard_cascade.config_json () in
      check bool "old profile visible before save" true
        (List.mem "alpha" (profile_names before));
      let next_raw =
        {|
          {
            "beta_editor_models": ["ollama:qwen3.5:35b-a3b-nvfp4"]
          }
        |}
      in
      match Masc_mcp.Dashboard_cascade.save_raw_config_json next_raw with
      | Error msg -> fail ("save_raw_config_json failed: " ^ msg)
      | Ok saved_config ->
          check bool "new profile visible immediately after save" true
            (List.mem "beta_editor" (profile_names saved_config));
          check bool "old profile removed after save" false
            (List.mem "alpha" (profile_names saved_config));
          check string "file persisted verbatim"
            next_raw
            (read_file cascade_path))

let test_save_raw_config_json_rejects_invalid_toml () =
  let toml =
    {|
[big_three]
models = ["ollama:qwen3.5:35b-a3b-nvfp4"]
|}
  in
  with_temp_config_root_setup
    (fun dir -> write_file (Filename.concat dir "cascade.toml") toml)
    (fun _dir ->
      match
        Masc_mcp.Dashboard_cascade.save_raw_config_json
          {|
[broken
models = ["ollama:qwen3.5:35b-a3b-nvfp4"]
|}
      with
      | Ok _ -> fail "invalid TOML should be rejected"
      | Error msg ->
          check bool "error mentions invalid TOML" true
            (contains_substring msg "invalid TOML"))

let test_save_raw_config_json_persists_toml_source_and_materializes_json () =
  let toml =
    {|
[alpha]
models = ["ollama:qwen3.5:35b-a3b-nvfp4"]
|}
  in
  with_temp_config_root_setup
    (fun dir -> write_file (Filename.concat dir "cascade.toml") toml)
    (fun dir ->
      let toml_path = Filename.concat dir "cascade.toml" in
      let json_path = Filename.concat dir "cascade.json" in
      let next_toml =
        {|
comment = "edited in dashboard"

[beta_editor]
models = ["ollama:qwen3.5:35b-a3b-nvfp4"]
|}
      in
      match Masc_mcp.Dashboard_cascade.save_raw_config_json next_toml with
      | Error msg -> fail ("save_raw_config_json failed for TOML source: " ^ msg)
      | Ok saved_config ->
          check bool "new profile visible immediately after save" true
            (List.mem "beta_editor" (profile_names saved_config));
          check bool "old profile removed after save" false
            (List.mem "alpha" (profile_names saved_config));
          check string "toml source persisted verbatim"
            next_toml
            (read_file toml_path);
          check bool "materialized json refreshed" true
            (contains_substring (read_file json_path) "beta_editor_models"))

(* ── health_json ───────────────────────────────────── *)

let test_health_shape () =
  let j = Masc_mcp.Dashboard_cascade.health_json () in
  (match member "updated_at" j with
   | `String _ -> () | _ -> fail "updated_at should be string");
  (match member "window_sec" j with
   | `Float _ -> () | _ -> fail "window_sec should be float");
  (match member "cooldown_threshold" j with
   | `Int _ -> () | _ -> fail "cooldown_threshold should be int");
  (match member "cooldown_sec" j with
   | `Float _ -> () | _ -> fail "cooldown_sec should be float");
  (match member "providers" j with
   | `List _ -> () | _ -> fail "providers should be list")

let test_health_serializable () =
  let j = Masc_mcp.Dashboard_cascade.health_json () in
  let s = Yojson.Safe.to_string j in
  check bool "non-empty json" true (String.length s > 0);
  (* Roundtrip *)
  let reparsed = Yojson.Safe.from_string s in
  check json "roundtrip" j reparsed

(* ── provider_scheme_of_model_string / declared merge ─────────────────── *)

let test_provider_scheme_extracts_prefix () =
  let scheme = Masc_mcp.Dashboard_cascade.provider_scheme_of_model_string in
  check string "prefixed with colon"
    "codex_cli" (scheme "codex_cli:auto");
  check string "prefix with hyphen"
    "glm-coding" (scheme "glm-coding:glm-5.1");
  check string "bare passes through"
    "ollama-only" (scheme "ollama-only");
  check string "empty string safe"
    "" (scheme "")

let test_provider_status_transitions () =
  let info_cooldown : Masc_mcp.Cascade_health_tracker.provider_info =
    { provider_key = "x"; success_rate = 0.0; consecutive_failures = 3
    ; in_cooldown = true; cooldown_expires_at = Some 1.0
    ; events_in_window = 5; rejected_in_window = 5
    ; top_fingerprints = []; last_failure_at = None }
  in
  let info_active : Masc_mcp.Cascade_health_tracker.provider_info =
    { info_cooldown with in_cooldown = false; consecutive_failures = 0
    ; cooldown_expires_at = None; events_in_window = 5
    ; rejected_in_window = 0; success_rate = 1.0 }
  in
  let info_idle : Masc_mcp.Cascade_health_tracker.provider_info =
    { info_active with events_in_window = 0; rejected_in_window = 0 }
  in
  check string "cooldown"   "cooldown"
    (Masc_mcp.Dashboard_cascade.provider_status info_cooldown);
  check string "active"     "active"
    (Masc_mcp.Dashboard_cascade.provider_status info_active);
  check string "configured" "configured"
    (Masc_mcp.Dashboard_cascade.provider_status info_idle)

let test_zero_provider_info_is_optimistic () =
  let info = Masc_mcp.Dashboard_cascade.zero_provider_info "some_scheme" in
  check string "key" "some_scheme" info.provider_key;
  check (float 0.0) "optimistic success rate" 1.0 info.success_rate;
  check int "no failures" 0 info.consecutive_failures;
  check bool "not in cooldown" false info.in_cooldown;
  check int "no events" 0 info.events_in_window;
  check int "no rejects" 0 info.rejected_in_window

let test_provider_entry_json_adds_declared_and_status () =
  let info = Masc_mcp.Dashboard_cascade.zero_provider_info "unheard_provider" in
  let j = Masc_mcp.Dashboard_cascade.provider_entry_to_json
    ~declared:true info in
  (match member "declared" j with
   | `Bool true -> ()
   | _ -> fail "declared should be true");
  (match member "status" j with
   | `String "configured" -> ()
   | other -> fail (Printf.sprintf "status expected 'configured', got %s"
                      (Yojson.Safe.to_string other)));
  check string "provider_key surfaces unchanged" "unheard_provider"
    (Yojson.Safe.Util.to_string (member "provider_key" j));
  (* Behavioural fields are still present — PR is strictly additive. *)
  (match member "events_in_window" j with
   | `Int 0 -> () | _ -> fail "events_in_window should be int 0");
  (match member "in_cooldown" j with
   | `Bool false -> () | _ -> fail "in_cooldown should be false")

let test_declared_provider_schemes_reads_all_profiles () =
  (* Fixture covers: string model spec, object-with-weight model spec,
     profile-less key (temperature without matching models) that the
     catalog loader must tolerate, and a commented field that must be
     skipped. Assert that every declared scheme — across both primary
     and secondary profiles — ends up in the returned list, and that
     non-profile keys do not leak in. *)
  let cascade_contents =
    {|{
  "_comment": "Fixture for declared_provider_schemes_of_config",
  "default_models": [
    { "model": "codex_cli:auto", "weight": 1 },
    { "model": "kimi_cli:kimi-for-coding", "weight": 1 }
  ],
  "default_temperature": 0.2,
  "default_max_tokens": 16384,
  "big_three_models": [
    { "model": "codex_cli:auto", "weight": 1 },
    { "model": "glm-coding:auto", "weight": 1 }
  ],
  "local_only_models": [ "ollama:auto" ],
  "big_three_temperature": 0.2
}
|}
  in
  with_temp_config_root cascade_contents (fun config_path ->
    let schemes =
      Masc_mcp.Dashboard_cascade.declared_provider_schemes_of_config
        ~config_path ()
    in
    let sorted_expected =
      List.sort compare
        [ "codex_cli"; "glm-coding"; "kimi_cli"; "ollama" ]
    in
    check (list string)
      "all declared provider schemes surfaced, deduplicated, sorted"
      sorted_expected schemes)

let test_declared_provider_schemes_handles_missing_path () =
  let schemes =
    Masc_mcp.Dashboard_cascade.declared_provider_schemes_of_config
      ?config_path:None ()
  in
  check (list string) "missing path gives empty list" [] schemes

let test_declared_provider_schemes_handles_malformed_config () =
  with_temp_config_root "not valid json at all" (fun config_path ->
    (* Catalog loader fails → we swallow and return empty.  Health
       endpoint must not disappear because cascade.json is broken. *)
    let schemes =
      Masc_mcp.Dashboard_cascade.declared_provider_schemes_of_config
        ~config_path ()
    in
    check (list string) "malformed json gives empty list" [] schemes)

(* ── SLO (LT-11) ─────────────────────────────────────── *)

module ST = Masc_mcp.Cascade_strategy_trace

let mk_trace ?(ts = 0.0) ?(strategy = "failover") ~kind () =
  { ST.ts; cascade_name = "c1"; strategy; cycle = 0;
    candidates_in = 1; candidates_out = 1; backoff_ms = 0; kind }

let assert_field name fields =
  match List.assoc_opt name fields with
  | Some v -> v
  | None -> fail (Printf.sprintf "field %s missing" name)

let slo_fields () =
  match Masc_mcp.Dashboard_cascade.slo_json () with
  | `Assoc fs -> fs
  | _ -> fail "expected assoc"

let current_field fields key =
  match assert_field "current" fields with
  | `Assoc cs ->
    (match List.assoc_opt key cs with
     | Some v -> v
     | None -> fail (Printf.sprintf "current.%s missing" key))
  | _ -> fail "current not assoc"

let test_slo_empty_ring_is_ok () =
  ST.clear ();
  let fs = slo_fields () in
  (match assert_field "status" fs with
   | `String "ok" -> ()
   | _ -> fail "expected status=ok on empty ring");
  (match current_field fs "ordered_ratio" with
   | `Float v -> check (float 0.0) "idle treated as 1.0" 1.0 v
   | _ -> fail "ordered_ratio not float")

let test_slo_all_ordered () =
  ST.clear ();
  for _ = 1 to 10 do
    ST.record (mk_trace ~kind:ST.Ordered ())
  done;
  let fs = slo_fields () in
  (match current_field fs "ordered_ratio" with
   | `Float v -> check (float 0.0) "all ordered → 1.0" 1.0 v
   | _ -> fail "ordered_ratio not float");
  (match assert_field "status" fs with
   | `String "ok" -> ()
   | _ -> fail "expected status=ok")

let test_slo_partial_filtered () =
  ST.clear ();
  for _ = 1 to 90 do
    ST.record (mk_trace ~kind:ST.Ordered ())
  done;
  for _ = 1 to 10 do
    ST.record (mk_trace ~kind:ST.Filtered_empty ())
  done;
  let fs = slo_fields () in
  (match current_field fs "ordered_ratio" with
   | `Float v ->
     check bool "ratio ≈ 0.9 (< 0.99 target)" true (v < 0.99);
     check bool "ratio > 0.8" true (v > 0.8)
   | _ -> fail "ordered_ratio not float");
  (match assert_field "status" fs with
   | `String ("violated") -> ()
   | `String "warn" -> ()  (* depending on exhaustion_count too *)
   | `String other -> fail (Printf.sprintf "expected violated/warn, got %s" other)
   | _ -> fail "status not string")

let test_slo_exhaustion_breach () =
  ST.clear ();
  for _ = 1 to 11 do
    ST.record (mk_trace ~kind:ST.Exhausted ())
  done;
  let fs = slo_fields () in
  (match current_field fs "exhaustion_count" with
   | `Int v -> check bool "exhaustion_count >= 11 (> 10 target)" true (v >= 11)
   | _ -> fail "exhaustion_count not int");
  (match assert_field "status" fs with
   | `String "violated" -> ()
   | _ -> fail "expected status=violated");
  (match assert_field "violations" fs with
   | `List xs ->
     check bool "violations includes exhaustion_count" true
       (List.exists (function `String "exhaustion_count" -> true | _ -> false) xs)
   | _ -> fail "violations not list")

let test_slo_burn_rate_math () =
  ST.clear ();
  (* 98 ordered + 2 filtered_empty → ratio = 0.98 → burn = 2.0 *)
  for _ = 1 to 98 do ST.record (mk_trace ~kind:ST.Ordered ()) done;
  for _ = 1 to 2 do ST.record (mk_trace ~kind:ST.Filtered_empty ()) done;
  let fs = slo_fields () in
  (match current_field fs "burn_rate" with
   | `Float v ->
     check bool "burn_rate ≈ 2.0 (> 1.0 target)" true (v > 1.9 && v < 2.1)
   | _ -> fail "burn_rate not float")

let test_slo_top_level_shape () =
  ST.clear ();
  let fs = slo_fields () in
  check bool "has updated_at" true (List.mem_assoc "updated_at" fs);
  check bool "has window_sample_size" true (List.mem_assoc "window_sample_size" fs);
  check bool "has targets" true (List.mem_assoc "targets" fs);
  check bool "has current" true (List.mem_assoc "current" fs);
  check bool "has status" true (List.mem_assoc "status" fs);
  check bool "has violations" true (List.mem_assoc "violations" fs)

(* ── keeper_profile_json: raw vs canonical contract ──────────────── *)

(* These tests exercise the pure [keeper_profile_json] projection directly
   on a synthesized [Keeper_registry.registry_entry] shape.  They verify
   the two-column contract the dashboard UI depends on:

   - [cascade_name] = raw string from TOML / state JSON
   - [canonical]   = active-catalog resolution of the raw

   When the two match (declared cascade is active in the live catalog),
   the UI collapses the canonical cell to "—"; when they diverge (e.g.
   TOML references an unknown cascade, a legacy alias, or a stale inactive
   built-in), the UI surfaces
   the mismatch as config drift. *)

let lookup fields key =
  match List.assoc_opt key fields with
  | Some (`String s) -> s
  | Some _ -> fail (Printf.sprintf "%s should be string" key)
  | None -> fail (Printf.sprintf "%s missing" key)

let test_keeper_profile_preserves_raw_unknown_cascade () =
  (* Genuinely unknown cascade — not in [Keeper_cascade_profile.t] and
     not a registered legacy alias. Typical sources: typos, personal
     playground profiles, vendor drift. The raw string must survive so
     the dashboard [canonical] column renders the mismatch. *)
  let fs =
    Masc_mcp.Dashboard_cascade.keeper_profile_fields
      ~keeper:"cheolsu" ~cascade_name:"playground_experiment_xyz"
  in
  check string "keeper name forwarded" "cheolsu" (lookup fs "keeper");
  check string "cascade_name preserves raw TOML value"
    "playground_experiment_xyz" (lookup fs "cascade_name");
  check string "canonical collapses unknown → keeper_unified"
    "big_three" (lookup fs "canonical");
  check bool "raw and canonical differ → UI shows drift"
    true (lookup fs "cascade_name" <> lookup fs "canonical")

let test_keeper_profile_preserves_raw_legacy_alias () =
  let fs =
    Masc_mcp.Dashboard_cascade.keeper_profile_fields
      ~keeper:"alice" ~cascade_name:"oas-keeper_unified"
  in
  check string "legacy alias preserved as raw"
    "oas-keeper_unified" (lookup fs "cascade_name");
  check string "legacy alias canonicalizes to keeper_unified"
    "big_three" (lookup fs "canonical");
  check bool "raw and canonical differ → UI shows drift"
    true (lookup fs "cascade_name" <> lookup fs "canonical")

let test_keeper_profile_canonical_matches_when_raw_is_canonical () =
  let fs =
    Masc_mcp.Dashboard_cascade.keeper_profile_fields
      ~keeper:"verdict" ~cascade_name:"big_three"
  in
  check string "cascade_name stays canonical"
    "big_three" (lookup fs "cascade_name");
  check string "canonical matches"
    "big_three" (lookup fs "canonical");
  check bool "raw == canonical → UI renders —"
    true (lookup fs "cascade_name" = lookup fs "canonical")

let test_keeper_profile_stale_builtin_falls_back_to_live_default () =
  with_temp_config_root
    {|
      {
        "default_models": ["ollama:qwen3.5:35b-a3b-nvfp4"],
        "big_three_models": ["ollama:qwen3.5:35b-a3b-nvfp4"]
      }
    |}
    (fun _cascade_path ->
      let fs =
        Masc_mcp.Dashboard_cascade.keeper_profile_fields
          ~keeper:"minjae" ~cascade_name:"vendor_mix_balanced"
      in
      check string "stale built-in raw value preserved"
        "vendor_mix_balanced" (lookup fs "cascade_name");
      check string "stale built-in falls back to live default"
        "big_three" (lookup fs "canonical");
      check bool "raw and canonical differ for inactive built-in"
        true (lookup fs "cascade_name" <> lookup fs "canonical"))

(* ── Phase 2a: low-trust recommendations ──────────── *)

module DC = Masc_mcp.Dashboard_cascade

let mk_info ?(success_rate = 1.0) ?(consecutive_failures = 0)
    ?(in_cooldown = false) ?(cooldown_expires_at = None)
    ?(events_in_window = 0) ?(rejected_in_window = 0)
    ?(top_fingerprints = []) ?(last_failure_at = None)
    ?(trust_score = 1.0) ?(same_fingerprint_count = 0) provider_key
  : Masc_mcp.Cascade_health_tracker.provider_info =
  { provider_key
  ; success_rate
  ; consecutive_failures
  ; in_cooldown
  ; cooldown_expires_at
  ; events_in_window
  ; rejected_in_window
  ; top_fingerprints
  ; last_failure_at
  ; trust_score
  ; same_fingerprint_count
  }

let test_recommendation_healthy_returns_none () =
  let info = mk_info "p" ~trust_score:1.0 ~events_in_window:10 in
  match DC.classify_recommendation info with
  | None -> ()
  | Some _ -> failwith "healthy provider should not yield a recommendation"

let test_recommendation_reduce_weight_for_partial_failure () =
  let info =
    mk_info "p" ~trust_score:0.2 ~events_in_window:10
      ~same_fingerprint_count:1
      ~top_fingerprints:[("timeout|abc12345", 4)]
  in
  match DC.classify_recommendation info with
  | Some r -> check string "reduce_weight"
      "reduce_weight"
      (DC.recommendation_action_to_string r.rec_action)
  | None -> failwith "expected reduce_weight recommendation"

let test_recommendation_disable_for_decayed_provider () =
  let info =
    mk_info "p" ~trust_score:0.05 ~events_in_window:10
      ~same_fingerprint_count:2
      ~top_fingerprints:[("failure|deadbeef", 3)]
  in
  match DC.classify_recommendation info with
  | Some r -> check string "disable"
      "disable"
      (DC.recommendation_action_to_string r.rec_action)
  | None -> failwith "expected disable recommendation"

let test_recommendation_investigate_for_stuck_streak () =
  let info =
    mk_info "p" ~trust_score:0.5  (* trust above the disable/reduce
                                      thresholds, so the stuck-streak
                                      branch is what trips the rule *)
      ~events_in_window:8 ~same_fingerprint_count:6
      ~top_fingerprints:[("runtime_mcp_auth|cafed00d", 6)]
  in
  match DC.classify_recommendation info with
  | Some r -> check string "investigate (stuck streak)"
      "investigate"
      (DC.recommendation_action_to_string r.rec_action)
  | None -> failwith "expected investigate recommendation"

let test_recommendation_investigate_high_volume_overrides_disable () =
  let info =
    mk_info "p" ~trust_score:0.05 ~events_in_window:50
      ~same_fingerprint_count:1  (* not stuck-streak *)
      ~top_fingerprints:[("failure|11223344", 12)]
  in
  match DC.classify_recommendation info with
  | Some r -> check string "investigate (high volume + very low trust)"
      "investigate"
      (DC.recommendation_action_to_string r.rec_action)
  | None -> failwith "expected investigate recommendation"

let test_recommendations_sorted_by_trust () =
  let infos = [
    mk_info "high" ~trust_score:0.25 ~events_in_window:5;
    mk_info "low"  ~trust_score:0.05 ~events_in_window:5;
    mk_info "mid"  ~trust_score:0.15 ~events_in_window:5;
    mk_info "ok"   ~trust_score:0.9  ~events_in_window:5;  (* skipped *)
  ] in
  let recs = DC.low_trust_recommendations infos in
  check int "count" 3 (List.length recs);
  let keys = List.map (fun r -> r.DC.rec_provider_key) recs in
  check (list string) "ascending trust order" ["low"; "mid"; "high"] keys

let test_recommendation_to_json_shape () =
  let info =
    mk_info "p" ~trust_score:0.05 ~events_in_window:30
      ~same_fingerprint_count:1
      ~top_fingerprints:[("timeout|f00d", 3)]
  in
  match DC.classify_recommendation info with
  | None -> failwith "expected recommendation"
  | Some r ->
    let j = DC.recommendation_to_json r in
    let member k = Yojson.Safe.Util.member k j in
    check string "provider_key"
      "p"
      (Yojson.Safe.Util.to_string (member "provider_key"));
    check string "action present"
      "investigate"
      (Yojson.Safe.Util.to_string (member "action"));
    (match member "top_fingerprint" with
     | `String s -> check bool "top_fingerprint preserved"
                       true (String.length s > 0)
     | _ -> failwith "top_fingerprint missing")

(* ── Suite ─────────────────────────────────────────── *)

let () =
  run "dashboard_cascade" [
    "config_json", [
      test_case "top-level shape" `Quick test_config_shape;
      test_case "validated status when snapshot exists" `Quick test_config_validated_status;
      test_case "profile shape" `Quick test_config_profile_shape;
      test_case "candidate shape" `Quick test_config_candidate_shape;
      test_case "uses live config catalog" `Quick test_config_uses_live_catalog;
      test_case "invalid catalog surfaces validation metadata" `Quick
        test_config_invalid_catalog_surfaces_validation_metadata;
    ];
    "raw_config_json", [
      test_case "top-level shape" `Quick test_raw_config_shape;
      test_case "missing file seeds default object" `Quick
        test_raw_config_defaults_when_file_missing;
      test_case "toml source exposes editable source + preview" `Quick
        test_raw_config_toml_source_exposes_editable_source_and_preview;
      test_case "invalid JSON is rejected" `Quick
        test_save_raw_config_json_rejects_invalid_json;
      test_case "invalid TOML is rejected" `Quick
        test_save_raw_config_json_rejects_invalid_toml;
      test_case "save persists and refreshes config projection" `Quick
        test_save_raw_config_json_persists_and_refreshes_projection;
      test_case "toml source save persists + materializes json" `Quick
        test_save_raw_config_json_persists_toml_source_and_materializes_json;
    ];
    "health_json", [
      test_case "top-level shape" `Quick test_health_shape;
      test_case "roundtrip serializable" `Quick test_health_serializable;
      test_case "provider_scheme_of_model_string extracts prefix" `Quick
        test_provider_scheme_extracts_prefix;
      test_case "provider_status transitions cooldown/active/configured"
        `Quick test_provider_status_transitions;
      test_case "zero_provider_info has optimistic defaults" `Quick
        test_zero_provider_info_is_optimistic;
      test_case "provider_entry_to_json surfaces declared + status" `Quick
        test_provider_entry_json_adds_declared_and_status;
      test_case "declared_provider_schemes reads all profiles" `Quick
        test_declared_provider_schemes_reads_all_profiles;
      test_case "declared_provider_schemes tolerates missing path" `Quick
        test_declared_provider_schemes_handles_missing_path;
      test_case "declared_provider_schemes tolerates malformed json"
        `Quick test_declared_provider_schemes_handles_malformed_config;
    ];
    "slo_json", [
      test_case "top-level shape" `Quick test_slo_top_level_shape;
      test_case "empty ring → status ok, ratio 1.0" `Quick test_slo_empty_ring_is_ok;
      test_case "all ordered → ratio 1.0" `Quick test_slo_all_ordered;
      test_case "partial filtered drops ratio" `Quick test_slo_partial_filtered;
      test_case "exhaustion > 10 → violated" `Quick test_slo_exhaustion_breach;
      test_case "burn_rate math" `Quick test_slo_burn_rate_math;
    ];
    "keeper_profile_json", [
      test_case "unknown cascade preserves raw, canonical shows drift"
        `Quick test_keeper_profile_preserves_raw_unknown_cascade;
      test_case "legacy alias preserves raw, canonicalizes at point-of-use"
        `Quick test_keeper_profile_preserves_raw_legacy_alias;
      test_case "inactive built-in cascade falls back to live default"
        `Quick test_keeper_profile_stale_builtin_falls_back_to_live_default;
      test_case "canonical cascade: raw == canonical (UI renders —)"
        `Quick test_keeper_profile_canonical_matches_when_raw_is_canonical;
    ];
    "recommendations", [
      test_case "healthy provider yields no recommendation" `Quick
        test_recommendation_healthy_returns_none;
      test_case "trust ∈ [0.1, 0.3) → reduce_weight" `Quick
        test_recommendation_reduce_weight_for_partial_failure;
      test_case "trust < 0.1 (decayed) → disable" `Quick
        test_recommendation_disable_for_decayed_provider;
      test_case "stuck-fingerprint streak → investigate" `Quick
        test_recommendation_investigate_for_stuck_streak;
      test_case "high-volume + very low trust → investigate" `Quick
        test_recommendation_investigate_high_volume_overrides_disable;
      test_case "list sorted ascending by trust" `Quick
        test_recommendations_sorted_by_trust;
      test_case "JSON shape preserves fields" `Quick
        test_recommendation_to_json_shape;
    ];
  ]
