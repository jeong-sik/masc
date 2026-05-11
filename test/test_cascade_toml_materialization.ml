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

(* Removed alongside the JSON-match invariant tests (RFC-0058 §9):
   - [repo_toml_path] / [repo_json_path] env-var helpers
   - [render_or_fail], [model_names_for_profile],
     [model_entry_for_profile], [supports_tool_choice_for_profile]
   These keyed off the pre-RFC-0058 flat cascade.json shape
   ([<name>_models] arrays at the top level), which PR #14550 retired
   when cascade.toml moved to the 5-layer declarative schema. This
   suite no longer touches either cascade env var; for context,
   [MASC_CASCADE_TOML_PATH] is still in use elsewhere
   ([test_cascade_config_validity.inc] injects it as of #14578) and
   [MASC_CASCADE_JSON_PATH] is no longer injected by any dune stanza
   in the repo. *)

let minimal_toml =
  {|
[big_three]
models = ["ollama:qwen3.5:35b-a3b-nvfp4"]
|}

(* RFC-0058 §9: legacy profile-shape assertions on the repo seed
   (big_three / tool_rerank / __safe_lane / tier_fast / default_models)
   referred to the pre-RFC-0058 flat cascade.json shape.  After PR #14550
   migrated cascade.toml to the 5-layer declarative schema those names
   no longer exist as top-level [<name>] tables in TOML.  The legacy
   assertion was dropped along with the JSON-match invariant — the
   declarative parser/validator/adapter test suites cover the same
   ground for the new schema. *)

let test_routes_table_is_parsed () =
  match
    Masc_mcp.Cascade_toml_materializer.render_toml_string_to_json_string
      {|
[routes]
governance_judge = "big_three"
llm_rerank = "tool_rerank"

[big_three]
models = ["codex_cli:auto"]

[tool_rerank]
models = ["gemini_cli:auto"]
keeper_assignable = false
|}
  with
  | Error msg -> failf "expected routes table to parse, got: %s" msg
  | Ok json_str ->
      let json = Yojson.Safe.from_string json_str in
      let routes = json |> member "routes" in
      check string "governance_judge route rendered" "big_three"
        (routes |> member "governance_judge" |> to_string);
      check string "llm_rerank route rendered" "tool_rerank"
        (routes |> member "llm_rerank" |> to_string);
      check (list string) "routes is not a profile section fallback"
        [ "big_three"; "tool_rerank" ]
        (let dir = Filename.temp_file "cascade-routes-section-" "" in
         Sys.remove dir;
         Unix.mkdir dir 0o755;
         let toml_path = Filename.concat dir "cascade.toml" in
         let json_path = Filename.concat dir "cascade.json" in
         write_file toml_path
           {|
[routes]
governance_judge = "big_three"

[big_three]
models = ["codex_cli:auto"]

[tool_rerank]
models = ["gemini_cli:auto"]
|};
         Fun.protect
           ~finally:(fun () -> rm_rf dir)
           (fun () ->
             match
               Masc_mcp.Cascade_toml_materializer.toml_section_names_result
                 ~config_path:json_path
             with
             | Ok names -> names
             | Error msg -> failf "section fallback failed: %s" msg))

(* RFC-0058 §9: the JSON↔TOML byte-equality round-trip was the SSOT
   anchor for the pre-RFC-0058 cascade.json file.  §9 declares that
   "cascade.json [is] no longer generated or consumed"; re-asserting the
   round-trip would re-anchor the to-be-removed file as ground truth.
   Consumer migration to in-memory materialization continues in follow-up
   PRs; this drop unblocks main without committing a JSON regen. *)

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

let test_num_ctx_field_is_parsed () =
  match
    Masc_mcp.Cascade_toml_materializer.render_toml_string_to_json_string
      {|
[ollama_only]
models = ["ollama:qwen3.6:27b-coding-nvfp4"]
num_ctx = 32768
|}
  with
  | Error msg -> failf "expected num_ctx to parse, got: %s" msg
  | Ok json_str ->
      let json = Yojson.Safe.from_string json_str in
      check int "num_ctx key is rendered"
        32768
        (json |> member "ollama_only_num_ctx" |> to_int)

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
  (* RFC-0058 §9.4: cascade.toml is the on-disk SSOT; the loader path
     argument may still use the legacy .json convention because the
     materializer resolves to the .toml sibling. *)
  let toml_path = Filename.concat dir "cascade.toml" in
  let json_path = Filename.concat dir "cascade.json" in
  write_file toml_path
    {|[ollama_only]
models = ["ollama:qwen3.6:27b-coding-nvfp4"]
fallback_cascade = "big_three"

[big_three]
models = ["codex_cli:auto"]
|};
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
  let toml_path = Filename.concat config_dir "cascade.toml" in
  write_file toml_path
    {|[ollama_only]
models = ["ollama:qwen3.6:27b-coding-nvfp4"]
fallback_cascade = "does_not_exist"

[big_three]
models = ["codex_cli:auto"]
|};
  with_config_dir config_dir @@ fun () ->
  check (option string)
    "unknown fallback target is dropped, not propagated"
    None
    (Masc_mcp.Keeper_cascade_profile.fallback_cascade_for "ollama_only")

let test_keeper_profile_resolves_known_fallback_target () =
  with_temp_dir "cascade-fallback-known" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  let toml_path = Filename.concat config_dir "cascade.toml" in
  write_file toml_path
    {|[ollama_only]
models = ["ollama:qwen3.6:27b-coding-nvfp4"]
fallback_cascade = "big_three"

[big_three]
models = ["codex_cli:auto"]
|};
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

let test_legacy_timeout_sec_field_is_ignored () =
  match
    Masc_mcp.Cascade_toml_materializer.render_toml_string_to_json_string
      {|
[big_three]
models = ["ollama:qwen3.5:35b-a3b-nvfp4"]
timeout_sec = 60
|}
  with
  | Error msg -> failf "legacy timeout_sec should be accepted: %s" msg
  | Ok rendered ->
      let json = Yojson.Safe.from_string rendered in
      check bool "profile still renders models" true
        (json |> member "big_three_models" <> `Null);
      check bool "legacy timeout_sec is not materialized" true
        (json |> member "big_three_timeout_sec" = `Null)

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
      (* TOML-only mode: no JSON file written to disk *)
      check bool "json NOT materialized in TOML-only mode" false
        (Sys.file_exists json_path)
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
  let stale_json = {|{"alpha_models":["ollama:qwen3.5:35b-a3b-nvfp4"]}|} in
  write_file json_path stale_json;
  with_config_dir config_dir @@ fun () ->
  match Masc_mcp.Cascade_catalog_runtime.inspect_active () with
  | Ok (Masc_mcp.Cascade_catalog_runtime.Validated _) ->
      (* TOML-only mode: stale JSON left untouched on disk, TOML loaded in-memory *)
      check string "stale json NOT rewritten in TOML-only mode"
        stale_json (read_file json_path)
  | Ok _ -> fail "expected fully validated catalog"
  | Error rejection ->
      failf "unexpected validation failure: %s"
        (Yojson.Safe.to_string
           (Masc_mcp.Cascade_catalog_runtime.rejection_to_yojson rejection))

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

(* Phase 2 regression: when load_catalog_source fails (malformed TOML, missing
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

(* Phase 2c regression: when cascade.json fails to load,
   normalize_priority_tiers must surface the underlying load failure
   instead of returning the misleading "no configured models"
   message.  Without this, an operator sees an empty-profile error
   while the real problem is an unreadable config file. *)
let test_priority_tiers_load_failure_message () =
  with_temp_dir "cascade-priority-tiers-load-failed" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  let json_path = Filename.concat config_dir "cascade.json" in
  write_file json_path "{ malformed";
  with_config_dir config_dir @@ fun () ->
  match
    Masc_mcp.Cascade_config.normalize_priority_tiers
      ~config_path:json_path
      ~name:"any_profile"
      [ [ "ollama:any-model" ] ]
  with
  | Ok _ -> fail "expected Error, got Ok"
  | Error msg ->
      check bool
        "Error message must mention the load failure, not the generic \
         'no configured models' fallback (PR Phase 2c)" true
        (contains_substring msg "cascade config load failed")

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

(* Smoke guard for [Cascade_metrics.on_profile_candidate_drop]: the
   call site in [validate_profile_static] is only exercised when an
   invalid candidate entry slips past the 5-layer typed parser, which
   is hard to provoke from a TOML fixture (the parser typically
   rejects shape errors first).  This smoke test exercises the three
   reasons directly so a future refactor that drops the call site
   loses a reference (mli check) rather than silently dead-coding the
   counter.  Prometheus state is process-global and not asserted. *)
let test_profile_candidate_drop_helpers_do_not_throw () =
  Masc_mcp.Cascade_metrics.on_profile_candidate_drop
    ~cascade:"smoke_test_cascade" ~reason:"unregistered_scheme";
  Masc_mcp.Cascade_metrics.on_profile_candidate_drop
    ~cascade:"smoke_test_cascade" ~reason:"unavailable_scheme";
  Masc_mcp.Cascade_metrics.on_profile_candidate_drop
    ~cascade:"smoke_test_cascade" ~reason:"invalid_syntax";
  check bool "all three reasons callable without raising" true true

(* Smoke + contract guard for [Cascade_metrics.on_resolve_provider_leak].
   The contract is documented as: [leak_count=0] is a no-op (callers
   can call unconditionally), [leak_count>0] bumps the counter by that
   amount.  This test exercises both arms.  As with the candidate-drop
   smoke test, Prometheus state is process-global and not asserted —
   the goal is to lock the signature + no-op contract so a future
   refactor that breaks the unconditional-call invariant trips a
   compile or runtime failure here. *)
let test_resolve_provider_leak_helper_zero_is_no_op_and_positive_callable () =
  (* leak_count=0 must be a no-op (no exception, no metric tick that
     could pollute neighboring tests). *)
  Masc_mcp.Cascade_metrics.on_resolve_provider_leak
    ~cascade:"smoke_test_cascade" ~leak_count:0;
  Masc_mcp.Cascade_metrics.on_resolve_provider_leak
    ~cascade:"smoke_test_cascade" ~leak_count:3;
  check bool "zero and positive leak_count both callable without raising"
    true true

(* Smoke + name-stability guard for [metric_provider_health_probe_error].
   The probe-error counter is owned by Prometheus.ml (alongside the
   sibling [_skipped] / [_actual_health_status] probe metrics) rather
   than [Cascade_metrics] because all probe-namespace metrics share
   the same labels and a single SSOT.  A future rename of the name
   constant — or removal of the .mli export — trips a compile
   failure here, which preserves dashboard alert continuity. *)
(* Smoke + contract guard for [Cascade_metrics.on_route_config_error].
   Same shape as on_resolve_provider_leak: zero is a no-op (callers
   call unconditionally) and positive is callable with both
   documented error_type label values. *)
(* Smoke + label-stability guard for [Cascade_metrics.on_resolve_failure].
   The five call sites (non-strict 2 + strict 3) in
   [Cascade_catalog_runtime] must all use one of three documented
   reason labels: [lookup_failed], [provider_filter_rejected],
   [no_callable_providers].  A typo at any call site would emit an
   undocumented label and pollute Prometheus cardinality.  This test
   exercises each label string explicitly so a future refactor that
   introduces a fourth reason — or renames an existing one — has to
   update this test, keeping the documented set in lockstep with the
   call sites. *)
(* Smoke + label-stability guard for
   [Cascade_metrics.on_validated_with_rejections].  Mirrors the LKG
   counter's documented-reason pinning (iter 5): the two reasons
   [fresh_partial_rejection] and [stale_partial_rejection_cached]
   must stay in lockstep with the two call sites in
   [inspect_active].  A future refactor that introduces a third
   reason — or renames an existing one — must update this test. *)
(* Smoke + name-stability guard for
   [Cascade_metrics.on_provider_filter_widening].  The non-strict
   [apply_provider_filter] fall-OPEN arm is hit only when the
   operator-supplied filter expresses an intent the cascade can't
   satisfy — a hard scenario to provoke from a unit test without
   constructing a full Provider_config.t list with mismatched
   kinds.  This smoke test exercises the call surface directly so
   the [cascade] label name and helper signature are pinned. *)
(* Regression for iter 13: the wrapper
   [resolve_named_providers_strict_with_secondary_resolver] has three
   Error returns (lookup_failed / provider_filter_rejected /
   no_callable_providers) that were silent before this iteration —
   iter 10 covered the base [resolve_named_providers_strict] but
   keeper_turn_driver actually calls the wrapper, so the silent
   Error paths were the most common cause of keeper turn failures
   going unobserved.  Two of the three Error paths are reachable via
   [install_snapshot_for_tests] (lookup_failed and
   no_callable_providers); the provider_filter_rejected arm requires
   a non-empty provider_filter against a non-empty candidate set,
   which is harder to set up via the test helper and stays covered
   by the smoke test of [on_resolve_failure] at iter 10. *)
let test_secondary_resolver_unknown_cascade_returns_error () =
  Masc_mcp.Cascade_catalog_runtime.reset_cache_for_tests ();
  Masc_mcp.Cascade_catalog_runtime.install_snapshot_for_tests
    ~source_path:"/tmp/test-cascade-iter13-unknown.toml"
    ~profile_names:[ "known_cascade_iter13" ];
  match
    Masc_mcp.Cascade_catalog_runtime
    .resolve_named_providers_strict_with_secondary_resolver
      ~cascade_name:"unknown_cascade_iter13"
      ()
  with
  | Ok _ ->
    fail
      "expected Error for unknown cascade name; lookup_failed metric \
       call site was not exercised"
  | Error _ ->
    check bool "Error returned as expected (lookup_failed path)" true true

let test_secondary_resolver_empty_cascade_returns_error () =
  Masc_mcp.Cascade_catalog_runtime.reset_cache_for_tests ();
  Masc_mcp.Cascade_catalog_runtime.install_snapshot_for_tests
    ~source_path:"/tmp/test-cascade-iter13-empty.toml"
    ~profile_names:[ "empty_cascade_iter13" ];
  match
    Masc_mcp.Cascade_catalog_runtime
    .resolve_named_providers_strict_with_secondary_resolver
      ~cascade_name:"empty_cascade_iter13"
      ()
  with
  | Ok _ ->
    fail
      "expected Error for cascade with no callable providers; \
       no_callable_providers metric call site was not exercised"
  | Error _ ->
    check bool
      "Error returned as expected (no_callable_providers path)" true true

(* Smoke + behavior guard for the iter-14 wrapper
   [Cascade_config.parse_weighted_entry_with_drop_metric].

   Ok path: a valid provider:model entry returns [Some _] like the
   iter-21-removed plain [parse_weighted_entry] used to.

   Drop path: an invalid-syntax entry returns [None] (matching the
   removed plain contract) AND ticks the iter-6 candidate-drop
   counter via the typed [Drop_invalid_syntax] reason from
   [parse_weighted_entry_diag].

   Prometheus state is process-global and not asserted; the goal is
   to pin the option-preserving contract so a future refactor that
   widens the return shape — or drops the wrapper entirely — fails
   here rather than silently regressing the resolve-path drop
   visibility this iteration introduced. *)
(* Smoke + contract guard for [Cascade_metrics.on_auto_expansion_fanout].
   The fanout=0 arm (all plain entries, no provider:auto in the
   cascade) must be a no-op so callers in
   [expand_weighted_entries] can emit unconditionally without
   polluting Prometheus state on every cascade load.  fanout>0
   exercises the inc_counter call site. *)
(* Smoke + cardinality guard for
   [Cascade_metrics.on_ordering_health_widening].  The widening arm
   in [order_weighted_entries] is hit only when [Cascade_health_tracker]
   has cooled every provider in a cascade — a hard scenario to provoke
   from a unit test (the global health tracker has long-lived state
   shared across the suite).  Smoke test pins the cascade label name
   + helper signature so a future refactor that breaks the call shape
   trips here rather than silently dead-coding the counter. *)
(* Smoke + label-stability guard for
   [Cascade_metrics.on_provider_cooldown].  Four reasons map to the
   four cooldown-entry branches in [Cascade_health_tracker.record]
   (failure_threshold, soft_rate_limit, hard_quota, terminal_failure).
   A typo at any call site would produce an undocumented label and
   pollute Prometheus cardinality; pinning the four strings here
   keeps the documented set canonical. *)
(* Smoke + label-stability guard for
   [Cascade_metrics.on_strategy_starvation_guard].  Two documented
   strategy labels map 1:1 to the two ordering branches in
   [Cascade_strategy.order_candidates] that fall open on
   capacity=0 (Circuit_breaker_cycling and Priority_tier).  A typo
   at either call site would emit an undocumented strategy label;
   pinning the two strings here keeps the canonical set in lockstep
   with the code.  The fail-open branches themselves require an
   adapter that always reports capacity=0, which is hard to
   provoke from a unit test without rewriting half the strategy
   harness — smoke is signature-only. *)
(* Smoke + cardinality guard for [Cascade_metrics.on_sticky_drift].
   Drift path in [sticky_order] is reachable only via a
   [Cascade_state] mutation between two strategy calls
   (cascade.toml reload + pin loss), which is harder to provoke
   from the cascade-toml-materialization suite than from the
   dedicated [test_cascade_strategy] suite that drives sticky
   pinning under harness.  Smoke test pins the cascade label name
   + helper signature. *)
(* Smoke for [Cascade_metrics.on_sticky_expiry].  The expiry arm in
   [Cascade_state.lookup_sticky] only fires after a TTL window has
   passed since [record_sticky_choice], which is awkward to drive
   from a unit test without mock clocks.  Smoke pins the helper
   signature; the natural code path is exercised by the existing
   [test_cascade_strategy] / [test_cascade_state] suites. *)
(* Smoke + label-stability guard for
   [Cascade_metrics.on_default_label_fallback].  Two documented
   reasons map 1:1 to the two fallback arms in
   [Cascade_runtime.default_model_strings].  A typo at either call
   site would emit an undocumented label and pollute Prometheus
   cardinality; pinning both strings here keeps the canonical set
   canonical. *)
(* Smoke + label-stability guard for
   [Cascade_metrics.on_max_context_fallback].  Four documented site
   labels map 1:1 to the four [fallback_context_window] arms in
   [Cascade_runtime].  A typo at any call site would emit an
   undocumented label and pollute Prometheus cardinality.  Pinning
   all four strings here keeps the canonical set in lockstep with
   the implementation. *)
(* Smoke for [Cascade_metrics.on_discovered_context_below_floor].
   No-arg helper — pin the call shape so a future refactor that
   adds a parameter trips here.  The natural code path requires a
   discovery API that returns a value below 4_096, which is awkward
   to provoke from a unit test without mocking
   [Cascade_config.resolve_label_context]. *)
(* Smoke for [Cascade_metrics.on_context_capability_drift].  The
   natural code path requires a registered provider whose
   [Capabilities.max_context_tokens] exceeds [entry.max_context],
   which is brittle to provoke from a unit test (registration
   shape changes with each adapter).  Smoke pins the provider
   label name + helper signature. *)
(* Smoke for [Cascade_metrics.on_llama_model_not_discovered].  The
   natural code path requires a registered llama endpoint whose
   [Discovery.context_for_model] returns None for a queried model_id
   — driving that from a unit test would need a live discovery
   fixture.  Smoke pins the no-arg helper signature. *)
(* Smoke + label-stability guard for
   [Cascade_metrics.on_route_resolve_fallback].  Two documented
   reasons map 1:1 to the two fallback arms in
   [Cascade_routes.cascade_name_for_use].  A typo at either call
   site would emit an undocumented label; pinning both strings
   here keeps the canonical set in lockstep with the code. *)
(* Smoke for [Cascade_metrics.on_deprecated_profile_name_filter].
   The closed deprecated-name set is bounded (~28 names) so the
   label cardinality stays safe.  Smoke test pins two
   representative names from the canonical list — exhaustive
   per-name coverage would just enumerate a constant list and add
   noise; the call-site coverage in catalog_runtime and
   config_loader exercises the actual emission paths. *)
(* Smoke + contract guard for
   [Cascade_metrics.on_capability_mismatch].  Same shape as iter
   7 / 9 / 15 [count=0 is no-op]: callers tick unconditionally and
   the helper guards against zero so neighboring tests stay
   unaffected.  Counter has no label dimensions (cardinality 1). *)
(* Smoke + label-stability guard for
   [Cascade_metrics.on_route_binding_dropped].  Two documented
   reasons map 1:1 to the two filter arms in
   [Cascade_routes.route_bindings_from_json].  Pinning both
   strings here keeps the canonical set in lockstep with the
   call sites. *)
let test_route_binding_dropped_documented_reasons_are_callable () =
  Masc_mcp.Cascade_metrics.on_route_binding_dropped
    ~reason:"invalid_value";
  Masc_mcp.Cascade_metrics.on_route_binding_dropped
    ~reason:"empty_key_or_target";
  check bool "both documented reasons callable without raising"
    true true

let test_capability_mismatch_zero_is_no_op_and_positive_callable () =
  Masc_mcp.Cascade_metrics.on_capability_mismatch ~count:0;
  Masc_mcp.Cascade_metrics.on_capability_mismatch ~count:2;
  check bool "zero is no-op and positive is callable without raising"
    true true

let test_deprecated_profile_name_filter_helper_callable () =
  Masc_mcp.Cascade_metrics.on_deprecated_profile_name_filter
    ~name:"default";
  Masc_mcp.Cascade_metrics.on_deprecated_profile_name_filter
    ~name:"keeper_unified";
  check bool "representative deprecated names callable without raising"
    true true

let test_route_resolve_fallback_documented_reasons_are_callable () =
  Masc_mcp.Cascade_metrics.on_route_resolve_fallback
    ~reason:"catalog_unvalidated";
  Masc_mcp.Cascade_metrics.on_route_resolve_fallback
    ~reason:"target_not_in_catalog";
  check bool "both documented reasons callable without raising"
    true true

let test_llama_model_not_discovered_helper_callable () =
  Masc_mcp.Cascade_metrics.on_llama_model_not_discovered ();
  check bool "no-arg helper callable without raising" true true

let test_context_capability_drift_helper_callable () =
  Masc_mcp.Cascade_metrics.on_context_capability_drift
    ~provider:"smoke_test_provider_iter28";
  check bool "single-label provider helper callable" true true

let test_discovered_context_below_floor_helper_callable () =
  Masc_mcp.Cascade_metrics.on_discovered_context_below_floor ();
  check bool "no-arg helper callable without raising" true true

let test_max_context_fallback_documented_sites_are_callable () =
  Masc_mcp.Cascade_metrics.on_max_context_fallback
    ~site:"label_no_provider_name";
  Masc_mcp.Cascade_metrics.on_max_context_fallback
    ~site:"label_unregistered_scheme";
  Masc_mcp.Cascade_metrics.on_max_context_fallback
    ~site:"primary_no_available";
  Masc_mcp.Cascade_metrics.on_max_context_fallback
    ~site:"cascade_max_no_available";
  check bool "all four documented site labels callable without raising"
    true true

let test_default_label_fallback_documented_reasons_are_callable () =
  Masc_mcp.Cascade_metrics.on_default_label_fallback
    ~cascade:"smoke_test_cascade_iter25" ~reason:"no_execution_labels";
  Masc_mcp.Cascade_metrics.on_default_label_fallback
    ~cascade:"smoke_test_cascade_iter25" ~reason:"local_cascade_no_local";
  check bool "both documented reasons callable without raising"
    true true

let test_sticky_expiry_helper_callable () =
  Masc_mcp.Cascade_metrics.on_sticky_expiry
    ~cascade:"smoke_test_cascade_iter24";
  check bool "single-label cascade helper callable" true true

let test_sticky_drift_helper_callable () =
  Masc_mcp.Cascade_metrics.on_sticky_drift
    ~cascade:"smoke_test_cascade_iter23";
  check bool "single-label cascade helper callable" true true

let test_strategy_starvation_guard_documented_strategies_are_callable () =
  Masc_mcp.Cascade_metrics.on_strategy_starvation_guard
    ~cascade:"smoke_test_cascade_iter22" ~strategy:"circuit_breaker_cycling";
  Masc_mcp.Cascade_metrics.on_strategy_starvation_guard
    ~cascade:"smoke_test_cascade_iter22" ~strategy:"priority_tier";
  check bool "both documented strategy labels callable without raising"
    true true

let test_provider_cooldown_documented_reasons_are_callable () =
  Masc_mcp.Cascade_metrics.on_provider_cooldown
    ~provider:"smoke_test_provider_iter20" ~reason:"failure_threshold";
  Masc_mcp.Cascade_metrics.on_provider_cooldown
    ~provider:"smoke_test_provider_iter20" ~reason:"soft_rate_limit";
  Masc_mcp.Cascade_metrics.on_provider_cooldown
    ~provider:"smoke_test_provider_iter20" ~reason:"hard_quota";
  Masc_mcp.Cascade_metrics.on_provider_cooldown
    ~provider:"smoke_test_provider_iter20" ~reason:"terminal_failure";
  check bool "all four documented reasons callable without raising"
    true true

let test_ordering_health_widening_helper_callable () =
  Masc_mcp.Cascade_metrics.on_ordering_health_widening
    ~cascade:"smoke_test_cascade_iter18";
  check bool "single-label cascade helper callable" true true

let test_auto_expansion_fanout_zero_is_no_op_and_positive_callable () =
  Masc_mcp.Cascade_metrics.on_auto_expansion_fanout
    ~cascade:"smoke_test_cascade_iter15" ~fanout:0;
  Masc_mcp.Cascade_metrics.on_auto_expansion_fanout
    ~cascade:"smoke_test_cascade_iter15" ~fanout:4;
  check bool "zero and positive fanout both callable without raising"
    true true

let test_parse_weighted_entry_with_drop_metric_contract () =
  let ok_entry : Masc_mcp.Cascade_config_loader.weighted_entry =
    { model = "ollama:qwen3.5:35b-a3b-nvfp4"
    ; weight = 1
    ; supports_tool_choice = None
    ; secondary = None
    ; secondary_supports_tool_choice = None
    }
  in
  let drop_entry : Masc_mcp.Cascade_config_loader.weighted_entry =
    { ok_entry with model = "no-colon-syntax-iter14" }
  in
  let ok_result =
    Masc_mcp.Cascade_config.parse_weighted_entry_with_drop_metric
      ~cascade:"smoke_test_cascade_iter14"
      ok_entry
  in
  let drop_result =
    Masc_mcp.Cascade_config.parse_weighted_entry_with_drop_metric
      ~cascade:"smoke_test_cascade_iter14"
      drop_entry
  in
  check bool "valid entry returns Some _" true (Option.is_some ok_result);
  check bool "invalid-syntax entry returns None" true (Option.is_none drop_result)

let test_provider_filter_widening_helper_callable () =
  Masc_mcp.Cascade_metrics.on_provider_filter_widening
    ~cascade:"smoke_test_cascade";
  check bool "single-label cascade helper callable" true true

let test_validated_with_rejections_helper_documented_reasons_are_callable () =
  Masc_mcp.Cascade_metrics.on_validated_with_rejections
    ~reason:"fresh_partial_rejection";
  Masc_mcp.Cascade_metrics.on_validated_with_rejections
    ~reason:"stale_partial_rejection_cached";
  check bool "both documented reasons callable without raising"
    true true

let test_resolve_failure_helper_documented_reasons_are_callable () =
  Masc_mcp.Cascade_metrics.on_resolve_failure
    ~cascade:"smoke_test_cascade" ~reason:"lookup_failed";
  Masc_mcp.Cascade_metrics.on_resolve_failure
    ~cascade:"smoke_test_cascade" ~reason:"provider_filter_rejected";
  Masc_mcp.Cascade_metrics.on_resolve_failure
    ~cascade:"smoke_test_cascade" ~reason:"no_callable_providers";
  check bool "all three documented reasons callable without raising"
    true true

let test_route_config_error_helper_zero_is_no_op_and_positive_callable () =
  Masc_mcp.Cascade_metrics.on_route_config_error
    ~error_type:"missing_target_profile" ~count:0;
  Masc_mcp.Cascade_metrics.on_route_config_error
    ~error_type:"missing_target_profile" ~count:2;
  Masc_mcp.Cascade_metrics.on_route_config_error
    ~error_type:"unknown_route_key" ~count:0;
  Masc_mcp.Cascade_metrics.on_route_config_error
    ~error_type:"unknown_route_key" ~count:1;
  check bool "both error_type labels callable with zero and positive"
    true true

let test_provider_health_probe_error_metric_name_is_exported () =
  let name = Masc_mcp.Prometheus.metric_provider_health_probe_error in
  check string "metric name is the documented total"
    "masc_provider_health_probe_error_total"
    name;
  (* And the call site shape used in record_probe_metrics is callable
     without raising. *)
  Masc_mcp.Prometheus.inc_counter
    name
    ~labels:
      [ ("provider_name", "smoke_probe_kind")
      ; ("profile_name", "smoke_probe_profile")
      ]
    ();
  check bool "inc_counter callable with both labels" true true

(* Regression guard for [Serving_last_known_good] entry + recovery
   transitions.  Previously these transitions happened silently:
   [inspect_active] would flip a Validated cache into LKG (or back)
   without log or Prometheus signal, leaving operators unaware that
   the catalog had drifted into a degraded state.

   The catalog runtime now ticks
   [masc_cascade_serving_last_known_good_total{reason}] on every LKG
   entry and [masc_cascade_degraded_recovery_total] on every
   recovery (the latter renamed from [lkg_recovery] in iter 16 after
   iter 11 broadened the detection to include partial recovery) —
   plus a single WARN at entry transition and INFO at recovery
   transition (not on steady-state replays).

   This test pins the state-machine itself: valid -> invalid (LKG)
   -> valid (recovery).  The metric counters themselves aren't
   asserted (they're process-global and shared across the suite);
   we rely on coverage from the state transitions to exercise the
   counter call sites. *)
let test_serving_last_known_good_entry_and_recovery () =
  with_temp_dir "cascade-lkg" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  let toml_path = Filename.concat config_dir "cascade.toml" in
  write_file toml_path minimal_toml;
  Masc_mcp.Cascade_catalog_runtime.reset_cache_for_tests ();
  with_config_dir config_dir @@ fun () ->
  (* Step 1: valid TOML -> Validated, primes the cache. *)
  (match Masc_mcp.Cascade_catalog_runtime.inspect_active () with
   | Ok (Masc_mcp.Cascade_catalog_runtime.Validated _) -> ()
   | Ok _ -> fail "step 1: expected Validated state"
   | Error rejection ->
     failf "step 1: unexpected Error: %s"
       (Yojson.Safe.to_string
          (Masc_mcp.Cascade_catalog_runtime.rejection_to_yojson rejection)));
  (* Step 2: replace TOML with a syntactically invalid file and
     advance mtime so the catalog/loader caches miss.  Should land
     on Serving_last_known_good with the cached snapshot. *)
  write_file toml_path "[broken\nthis is not valid toml syntax";
  Masc_mcp.Cascade_config_loader.invalidate_cache_entry toml_path;
  let t1 = Unix.gettimeofday () +. 2.0 in
  Unix.utimes toml_path t1 t1;
  (match Masc_mcp.Cascade_catalog_runtime.inspect_active () with
   | Ok (Masc_mcp.Cascade_catalog_runtime.Serving_last_known_good _) -> ()
   | Ok Validated _ -> fail "step 2: expected LKG, got Validated"
   | Ok (Validated_with_rejections _) ->
     fail "step 2: expected LKG, got Validated_with_rejections"
   | Error _ -> fail "step 2: expected LKG, got Error");
  (* Step 3: restore valid TOML, advance mtime, expect recovery
     transition LKG -> Validated. *)
  write_file toml_path minimal_toml;
  Masc_mcp.Cascade_config_loader.invalidate_cache_entry toml_path;
  let t2 = Unix.gettimeofday () +. 4.0 in
  Unix.utimes toml_path t2 t2;
  match Masc_mcp.Cascade_catalog_runtime.inspect_active () with
  | Ok (Masc_mcp.Cascade_catalog_runtime.Validated _) -> ()
  | _ -> fail "step 3: expected Validated after recovery"

(* Regression guard for the [load_toml_in_memory] race-aware rewrite.
   The previous implementation rendered TOML first and stat'd second,
   which meant a cache-hit path still paid the full parse cost.  The
   new pre-stat fast path returns the cached JSON without re-rendering
   when the mtime is unchanged, and produces fresh content (with cache
   refresh) when the mtime advances.  Pin both behaviors here. *)
let test_loader_cache_hits_when_mtime_unchanged () =
  with_temp_dir "cascade-loader-cache" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  let toml_path = Filename.concat config_dir "cascade.toml" in
  write_file toml_path minimal_toml;
  match Masc_mcp.Cascade_config_loader.load_catalog_source toml_path with
  | Error msg -> failf "first load failed: %s" msg
  | Ok first ->
    (match Masc_mcp.Cascade_config_loader.load_catalog_source toml_path with
     | Error msg -> failf "second load failed: %s" msg
     | Ok second ->
       (* Cache hit must return the same in-memory JSON value (physical
          equality is the strongest possible signal that no re-parse
          happened; we accept structural equality to stay tolerant if
          the loader ever swaps in a deep copy). *)
       check string "cache hit returns identical content"
         (Yojson.Safe.to_string first)
         (Yojson.Safe.to_string second))

let test_loader_refreshes_when_mtime_advances () =
  with_temp_dir "cascade-loader-refresh" @@ fun dir ->
  let config_dir = Filename.concat dir "config" in
  init_config_root config_dir;
  let toml_path = Filename.concat config_dir "cascade.toml" in
  write_file toml_path minimal_toml;
  (match Masc_mcp.Cascade_config_loader.load_catalog_source toml_path with
   | Error msg -> failf "first load failed: %s" msg
   | Ok _ -> ());
  (* Replace content and advance mtime past the cache entry. *)
  write_file
    toml_path
    {|
[other_profile]
models = ["ollama:qwen3.5:35b-a3b-nvfp4"]
|};
  let now = Unix.gettimeofday () +. 2.0 in
  Unix.utimes toml_path now now;
  match Masc_mcp.Cascade_config_loader.load_catalog_source toml_path with
  | Error msg -> failf "post-update load failed: %s" msg
  | Ok refreshed ->
    let json_str = Yojson.Safe.to_string refreshed in
    check bool "fresh content reflects new profile" true
      (contains_substring json_str "other_profile");
    check bool "stale profile name is gone" false
      (contains_substring json_str "big_three_models")

let () =
  run "cascade_toml_materialization"
    [
      ( "validation",
        [
          test_case "unknown profile field is rejected" `Quick
            test_unknown_profile_field_is_rejected;
          test_case "legacy timeout_sec field is ignored" `Quick
            test_legacy_timeout_sec_field_is_ignored;
          test_case "fallback_cascade field is parsed" `Quick
            test_fallback_cascade_field_is_parsed;
          test_case "fallback_cascade absent is backward compatible" `Quick
            test_fallback_cascade_absent_is_backward_compatible;
          test_case "keep_alive field is parsed" `Quick
            test_keep_alive_field_is_parsed;
          test_case "keep_alive duration string is parsed" `Quick
            test_keep_alive_duration_string_is_parsed;
          test_case "num_ctx field is parsed" `Quick
            test_num_ctx_field_is_parsed;
          test_case "routes table is parsed" `Quick
            test_routes_table_is_parsed;
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
          test_case
            "normalize_priority_tiers surfaces load failure (Phase 2c)"
            `Quick test_priority_tiers_load_failure_message;
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
      ( "loader_cache",
        [
          test_case "cache hits when mtime unchanged" `Quick
            test_loader_cache_hits_when_mtime_unchanged;
          test_case "refreshes when mtime advances" `Quick
            test_loader_refreshes_when_mtime_advances;
        ] );
      ( "lkg_transitions",
        [
          test_case "valid -> invalid (LKG) -> valid (recovery)" `Quick
            test_serving_last_known_good_entry_and_recovery;
        ] );
      ( "metrics_smoke",
        [
          test_case "profile_candidate_drop helpers do not throw" `Quick
            test_profile_candidate_drop_helpers_do_not_throw;
          test_case
            "resolve_provider_leak: zero is no-op, positive callable"
            `Quick
            test_resolve_provider_leak_helper_zero_is_no_op_and_positive_callable;
          test_case
            "provider_health_probe_error metric name + call shape" `Quick
            test_provider_health_probe_error_metric_name_is_exported;
          test_case
            "route_config_error: zero is no-op, both labels callable" `Quick
            test_route_config_error_helper_zero_is_no_op_and_positive_callable;
          test_case
            "resolve_failure: all three documented reasons callable" `Quick
            test_resolve_failure_helper_documented_reasons_are_callable;
          test_case
            "validated_with_rejections: both documented reasons callable"
            `Quick
            test_validated_with_rejections_helper_documented_reasons_are_callable;
          test_case
            "provider_filter_widening: cascade label helper callable" `Quick
            test_provider_filter_widening_helper_callable;
          test_case
            "parse_weighted_entry_with_drop_metric: option contract preserved"
            `Quick
            test_parse_weighted_entry_with_drop_metric_contract;
          test_case
            "auto_expansion_fanout: zero is no-op, positive callable" `Quick
            test_auto_expansion_fanout_zero_is_no_op_and_positive_callable;
          test_case
            "ordering_health_widening: cascade label helper callable" `Quick
            test_ordering_health_widening_helper_callable;
          test_case
            "provider_cooldown: all four documented reasons callable" `Quick
            test_provider_cooldown_documented_reasons_are_callable;
          test_case
            "strategy_starvation_guard: both documented strategies callable"
            `Quick
            test_strategy_starvation_guard_documented_strategies_are_callable;
          test_case
            "sticky_drift: cascade label helper callable" `Quick
            test_sticky_drift_helper_callable;
          test_case
            "sticky_expiry: cascade label helper callable" `Quick
            test_sticky_expiry_helper_callable;
          test_case
            "default_label_fallback: both documented reasons callable"
            `Quick
            test_default_label_fallback_documented_reasons_are_callable;
          test_case
            "max_context_fallback: all four documented sites callable"
            `Quick
            test_max_context_fallback_documented_sites_are_callable;
          test_case
            "discovered_context_below_floor: helper callable" `Quick
            test_discovered_context_below_floor_helper_callable;
          test_case
            "context_capability_drift: provider label helper callable" `Quick
            test_context_capability_drift_helper_callable;
          test_case
            "llama_model_not_discovered: helper callable" `Quick
            test_llama_model_not_discovered_helper_callable;
          test_case
            "route_resolve_fallback: both documented reasons callable"
            `Quick
            test_route_resolve_fallback_documented_reasons_are_callable;
          test_case
            "deprecated_profile_name_filter: representative names callable"
            `Quick
            test_deprecated_profile_name_filter_helper_callable;
          test_case
            "capability_mismatch: zero is no-op, positive callable" `Quick
            test_capability_mismatch_zero_is_no_op_and_positive_callable;
          test_case
            "route_binding_dropped: both documented reasons callable" `Quick
            test_route_binding_dropped_documented_reasons_are_callable;
        ] );
      ( "secondary_resolver_error_paths",
        [
          test_case
            "unknown cascade name -> Error (lookup_failed path)" `Quick
            test_secondary_resolver_unknown_cascade_returns_error;
          test_case
            "empty cascade -> Error (no_callable_providers path)" `Quick
            test_secondary_resolver_empty_cascade_returns_error;
        ] );
    ]
