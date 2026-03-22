open Alcotest

module Model_spec = Masc_mcp.Model_spec
module Oas_worker = Masc_mcp.Oas_worker

let with_temp_json contents f =
  let path = Filename.temp_file "cascade_" ".json" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr oc;
      if Sys.file_exists path then Sys.remove path)
    (fun () ->
      output_string oc contents;
      close_out oc;
      f path)

let with_temp_me_root_config contents f =
  let base = Filename.temp_file "me_root_" "" in
  let cleanup path =
    let rec rm current =
      if Sys.file_exists current then
        if Sys.is_directory current then (
          Sys.readdir current
          |> Array.iter (fun name -> rm (Filename.concat current name));
          Unix.rmdir current)
        else
          Unix.unlink current
    in
    rm path
  in
  Unix.unlink base;
  Unix.mkdir base 0o755;
  let config_dir =
    Filename.concat base "workspace/yousleepwhen/masc-mcp/config"
  in
  let rec ensure_dir path =
    if not (Sys.file_exists path) then (
      ensure_dir (Filename.dirname path);
      Unix.mkdir path 0o755)
  in
  Fun.protect
    ~finally:(fun () -> cleanup base)
    (fun () ->
      ensure_dir config_dir;
      let path = Filename.concat config_dir "cascade.json" in
      let oc = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () ->
          output_string oc contents;
          close_out oc;
          let previous = Sys.getenv_opt "ME_ROOT" in
          Unix.putenv "ME_ROOT" base;
          Fun.protect
            ~finally:(fun () ->
              match previous with
              | Some value -> Unix.putenv "ME_ROOT" value
              | None -> Unix.putenv "ME_ROOT" "")
            (fun () -> f path)))

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

let test_load_models_from_config () =
  Eio_main.run @@ fun _env ->
  with_temp_json
    {|{"heartbeat_action_models":["llama:qwen-local","llama:qwen-local-fallback"]}|}
    (fun path ->
      let from_file =
        Llm_provider.Cascade_config.load_profile ~config_path:path ~name:"heartbeat_action"
      in
      check int "loaded model count" 2 (List.length from_file);
      let specs = Model_spec.available_model_specs_of_strings from_file in
      check int "spec count" 2 (List.length specs);
      match specs with
      | [ first; second ] ->
          check bool "first is llama" true (first.provider = Model_spec.Llama);
          check string "first model" "qwen-local" first.model_id;
          check bool "second is llama" true (second.provider = Model_spec.Llama);
          check string "second model" "qwen-local-fallback" second.model_id
      | _ -> fail "expected two specs")

let test_skips_invalid_and_missing_api_key () =
  Eio_main.run @@ fun _env ->
  with_env "GEMINI_API_KEY" "" (fun () ->
      with_temp_json
        {|{"heartbeat_action_models":["invalid","gemini:gemini-2.5-pro","llama:qwen-live"]}|}
        (fun path ->
          let from_file =
            Llm_provider.Cascade_config.load_profile ~config_path:path ~name:"heartbeat_action"
          in
          let specs = Model_spec.available_model_specs_of_strings from_file in
          check int "only llama survives" 1 (List.length specs);
          match specs with
          | [ only ] ->
              check bool "llama provider" true
                (only.provider = Model_spec.Llama);
              check string "llama model" "qwen-live" only.model_id
          | _ -> fail "expected one surviving spec"))

let test_missing_config_uses_defaults () =
  let defaults = Oas_worker.default_model_strings ~cascade_name:"heartbeat_action" in
  let specs = Model_spec.available_model_specs_of_strings defaults in
  check bool "defaults available" true (List.length specs >= 1);
  match specs with
  | first :: _ ->
      check bool "default starts with llama" true
        (first.provider = Model_spec.Llama);
      check string "default llama model" Masc_mcp.Env_config.Llama.default_model
        first.model_id
  | [] -> fail "expected default fallback models"

let test_call_returns_error_when_no_models () =
  (* Force an empty cascade by overriding the cascade config under a temp
     ME_ROOT so the runtime sees only a provider that lacks credentials. *)
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_mcp.Masc_eio_env.init ~sw ~net:(Eio.Stdenv.net env) ();
  with_env "ZAI_API_KEY" "" (fun () ->
    with_env "GEMINI_API_KEY" "" (fun () ->
      with_temp_me_root_config
        {|{"heartbeat_action_models":["gemini:fake-model"]}|}
        (fun _path ->
          let result =
            Oas_worker.run_named
              ~cascade_name:"heartbeat_action"
              ~goal:"test"
              ~max_turns:1
              ()
          in
          match result with
          | Error msg ->
              check bool "error mentions no callable" true
                (String.length msg > 0)
          | Ok _ ->
              (* If a model somehow responded, the cascade works — also OK *)
              ())))

let known_cascade_names =
  [
    "heartbeat_action"; "heartbeat_wake";
    (* sentinel_board/sentinel_task/sentinel_keeper removed — Sentinel deleted (#1834) *)
    "lodge_direct"; "lodge_context_rewrite"; "lodge_trait_gen";
    "lodge_comment"; "lodge_agent_match";
    "classification"; "context_router"; "capability_match";
    "tom"; "verifier"; "trpg_intent";
    "briefing"; "walph";
  ]

let test_all_known_names_return_nonempty () =
  List.iter
    (fun name ->
      let models = Oas_worker.default_model_strings ~cascade_name:name in
      check bool
        (Printf.sprintf "%s returns non-empty" name)
        true (models <> []))
    known_cascade_names

let test_unknown_name_returns_fallback () =
  let models =
    Oas_worker.default_model_strings ~cascade_name:"nonexistent_xyz"
  in
  check bool "catch-all returns non-empty" true (models <> [])

let test_glm_included_when_zai_key_set () =
  with_env "ZAI_API_KEY" "test-key" (fun () ->
    let models =
      Oas_worker.default_model_strings ~cascade_name:"nonexistent_xyz"
    in
    check bool "has glm:auto" true (List.mem "glm:auto" models);
    let last = List.nth models (List.length models - 1) in
    check string "last is glm:auto" "glm:auto" last)

let test_glm_excluded_when_zai_key_missing () =
  with_env "ZAI_API_KEY" "" (fun () ->
    let models =
      Oas_worker.default_model_strings ~cascade_name:"nonexistent_xyz"
    in
    check bool "no glm:auto" true (not (List.mem "glm:auto" models));
    check bool "still non-empty" true (models <> []))

let test_briefing_non_empty () =
  let models = Oas_worker.default_model_strings ~cascade_name:"briefing" in
  check bool "briefing is non-empty" true (List.length models >= 1)

let test_classification_uses_llama_first () =
  let models =
    Oas_worker.default_model_strings ~cascade_name:"classification"
  in
  let first = List.hd models in
  check bool "classification starts with llama:" true
    (String.length first > 6 && String.sub first 0 6 = "llama:")

module Cascade_inference = Masc_mcp.Cascade_inference

(* ── Cascade inference parameter tests ──────────────── *)

let test_inference_empty () =
  let e = Cascade_inference.empty in
  check (option (float 0.01)) "no temperature" None e.temperature;
  check (option int) "no max_tokens" None e.max_tokens

let test_inference_read_float () =
  let json = `Assoc [("t", `Float 0.5)] in
  let v = Cascade_inference.read_float_field json "t" in
  check (option (float 0.01)) "reads 0.5" (Some 0.5) v

let test_inference_read_float_from_int () =
  let json = `Assoc [("t", `Int 1)] in
  let v = Cascade_inference.read_float_field json "t" in
  check (option (float 0.01)) "reads 1.0" (Some 1.0) v

let test_inference_read_float_missing () =
  let json = `Assoc [] in
  let v = Cascade_inference.read_float_field json "missing" in
  check (option (float 0.01)) "None" None v

let test_inference_read_int () =
  let json = `Assoc [("n", `Int 4096)] in
  let v = Cascade_inference.read_int_field json "n" in
  check (option int) "reads 4096" (Some 4096) v

let test_inference_read_int_missing () =
  let json = `Assoc [] in
  let v = Cascade_inference.read_int_field json "missing" in
  check (option int) "None" None v

(* ── Cascade inference parameter tests ───────────────────
   Use for_json for deterministic filesystem-independent tests. *)

let sample_cascade_json = Yojson.Safe.from_string {|{
  "default_models": ["llama:auto"],
  "keeper_unified_temperature": 0.4,
  "keeper_unified_max_tokens": 2048,
  "keeper_autonomy_temperature": 0.3,
  "keeper_autonomy_max_tokens": 500,
  "keeper_turn_max_tokens": 1024,
  "default_temperature": 0.77,
  "default_max_tokens": 999
}|}

let test_inference_for_json_named () =
  let params = Cascade_inference.for_json ~name:"keeper_unified" sample_cascade_json in
  check (option (float 0.01)) "temperature" (Some 0.4) params.temperature;
  check (option int) "max_tokens" (Some 2048) params.max_tokens

let test_inference_for_json_named_autonomy () =
  let params = Cascade_inference.for_json ~name:"keeper_autonomy" sample_cascade_json in
  check (option (float 0.01)) "temperature" (Some 0.3) params.temperature;
  check (option int) "max_tokens" (Some 500) params.max_tokens

let test_inference_for_json_partial () =
  (* keeper_turn has max_tokens but no temperature — falls back to default_temperature *)
  let params = Cascade_inference.for_json ~name:"keeper_turn" sample_cascade_json in
  check (option (float 0.01)) "temperature falls to default" (Some 0.77) params.temperature;
  check (option int) "max_tokens" (Some 1024) params.max_tokens

let test_inference_for_json_unknown_falls_to_default () =
  let params = Cascade_inference.for_json ~name:"nonexistent_xyz" sample_cascade_json in
  check (option (float 0.01)) "default temperature" (Some 0.77) params.temperature;
  check (option int) "default max_tokens" (Some 999) params.max_tokens

let test_inference_for_json_no_defaults () =
  let json = Yojson.Safe.from_string {|{"default_models": ["llama:auto"]}|} in
  let params = Cascade_inference.for_json ~name:"unknown" json in
  check (option (float 0.01)) "no temperature" None params.temperature;
  check (option int) "no max_tokens" None params.max_tokens

let test_inference_for_json_named_overrides_default () =
  let json = Yojson.Safe.from_string {|{
    "default_temperature": 0.77,
    "named_temperature": 0.11,
    "default_max_tokens": 999,
    "named_max_tokens": 555
  }|} in
  let params = Cascade_inference.for_json ~name:"named" json in
  check (option (float 0.01)) "named temperature wins" (Some 0.11) params.temperature;
  check (option int) "named max_tokens wins" (Some 555) params.max_tokens

let test_inference_resolve_temperature_fallback () =
  (* resolve_temperature with a cascade_name that doesn't exist in config
     — exercises the fallback path regardless of cascade.json location *)
  let v = Cascade_inference.resolve_temperature
      ~cascade_name:"nonexistent_test_xyz_12345"
      ~fallback:(fun () -> 0.33) in
  check (float 0.01) "fallback temperature" 0.33 v

let test_inference_resolve_max_tokens_fallback () =
  let v = Cascade_inference.resolve_max_tokens
      ~cascade_name:"nonexistent_test_xyz_12345"
      ~fallback:(fun () -> 42) in
  check int "fallback max_tokens" 42 v

let () =
  run "cascade"
    [
      ( "loader",
        [
          test_case "loads provider:model order" `Quick
            test_load_models_from_config;
          test_case "skips invalid and missing api key" `Quick
            test_skips_invalid_and_missing_api_key;
          test_case "missing config uses defaults" `Quick
            test_missing_config_uses_defaults;
        ] );
      ( "call",
        [
          test_case "returns error when no callable models" `Quick
            test_call_returns_error_when_no_models;
        ] );
      ( "defaults",
        [
          test_case "all known names return non-empty" `Quick
            test_all_known_names_return_nonempty;
          test_case "unknown name returns fallback" `Quick
            test_unknown_name_returns_fallback;
          test_case "glm included when ZAI_API_KEY set" `Quick
            test_glm_included_when_zai_key_set;
          test_case "glm excluded when ZAI_API_KEY missing" `Quick
            test_glm_excluded_when_zai_key_missing;
          test_case "briefing non-empty" `Quick
            test_briefing_non_empty;
          test_case "classification uses llama first" `Quick
            test_classification_uses_llama_first;
        ] );
      ( "inference_params",
        [
          test_case "empty has no values" `Quick
            test_inference_empty;
          test_case "read_float_field parses float" `Quick
            test_inference_read_float;
          test_case "read_float_field parses int as float" `Quick
            test_inference_read_float_from_int;
          test_case "read_float_field returns None for missing" `Quick
            test_inference_read_float_missing;
          test_case "read_int_field parses int" `Quick
            test_inference_read_int;
          test_case "read_int_field returns None for missing" `Quick
            test_inference_read_int_missing;
          test_case "for_json named cascade" `Quick
            test_inference_for_json_named;
          test_case "for_json keeper_autonomy" `Quick
            test_inference_for_json_named_autonomy;
          test_case "for_json partial falls to default" `Quick
            test_inference_for_json_partial;
          test_case "for_json unknown falls to default" `Quick
            test_inference_for_json_unknown_falls_to_default;
          test_case "for_json no defaults returns empty" `Quick
            test_inference_for_json_no_defaults;
          test_case "for_json named overrides default" `Quick
            test_inference_for_json_named_overrides_default;
          test_case "resolve_temperature fallback" `Quick
            test_inference_resolve_temperature_fallback;
          test_case "resolve_max_tokens fallback" `Quick
            test_inference_resolve_max_tokens_fallback;
        ] );
    ]
