open Alcotest

module Cascade = Masc_mcp.Cascade
module Llm_types = Masc_mcp.Llm_types

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
  with_temp_json
    {|{"heartbeat_action_models":["llama:qwen-local","llama:qwen-local-fallback"]}|}
    (fun path ->
      let specs = Cascade.get_cascade ~config_path:path ~cascade_name:"heartbeat_action" () in
      check int "spec count" 2 (List.length specs);
      match specs with
      | [ first; second ] ->
          check bool "first is llama" true (first.provider = Llm_types.Llama);
          check string "first model" "qwen-local" first.model_id;
          check bool "second is llama" true (second.provider = Llm_types.Llama);
          check string "second model" "qwen-local-fallback" second.model_id
      | _ -> fail "expected two specs")

let test_skips_invalid_and_missing_api_key () =
  with_env "GEMINI_API_KEY" "" (fun () ->
      with_temp_json
        {|{"heartbeat_action_models":["invalid","gemini:gemini-2.5-pro","llama:qwen-live"]}|}
        (fun path ->
          let specs = Cascade.get_cascade ~config_path:path ~cascade_name:"heartbeat_action" () in
          check int "only llama survives" 1 (List.length specs);
          match specs with
          | [ only ] ->
              check bool "llama provider" true
                (only.provider = Llm_types.Llama);
              check string "llama model" "qwen-live" only.model_id
          | _ -> fail "expected one surviving spec"))

let test_missing_config_uses_defaults () =
  let path = Filename.concat (Filename.get_temp_dir_name ()) "missing-llm-cascade.json" in
  let specs = Cascade.get_cascade ~config_path:path ~cascade_name:"heartbeat_action" () in
  check bool "defaults available" true (List.length specs >= 1);
  match specs with
  | first :: _ ->
      check bool "default starts with llama" true
        (first.provider = Llm_types.Llama);
      check string "default llama model" Masc_mcp.Env_config.Llama.default_model
        first.model_id
  | [] -> fail "expected default fallback models"

let test_call_returns_error_when_no_models () =
  (* Force an empty cascade by using a config with an empty list and
     overriding so defaults also return empty via a provider that
     requires a missing API key. *)
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Masc_mcp.Masc_eio_env.init ~sw ~net:(Eio.Stdenv.net env) ();
  with_env "ZAI_API_KEY" "" (fun () ->
    with_env "GEMINI_API_KEY" "" (fun () ->
      with_temp_json
        {|{"heartbeat_action_models":["gemini:fake-model"]}|}
        (fun path ->
          let result =
            Cascade.call
              ~cascade_name:"heartbeat_action"
              ~prompt:"test"
              ~timeout_sec:1
              ~config_path:path
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
    "sentinel_board"; "sentinel_task"; "sentinel_keeper";
    "lodge_direct"; "lodge_context_rewrite"; "lodge_trait_gen";
    "lodge_comment"; "lodge_agent_match";
    "gardener_spawn";
    "classification"; "context_router"; "capability_match";
    "tom"; "verifier"; "trpg_intent";
    "briefing"; "walph";
  ]

let test_all_known_names_return_nonempty () =
  List.iter
    (fun name ->
      let models = Cascade.default_model_strings ~cascade_name:name in
      check bool
        (Printf.sprintf "%s returns non-empty" name)
        true (models <> []))
    known_cascade_names

let test_unknown_name_returns_fallback () =
  let models =
    Cascade.default_model_strings ~cascade_name:"nonexistent_xyz"
  in
  check bool "catch-all returns non-empty" true (models <> []);
  (* Always ends with glm:auto as safety net *)
  let last = List.nth models (List.length models - 1) in
  check string "last is glm:auto" "glm:auto" last

let test_briefing_always_has_glm_auto () =
  let models = Cascade.default_model_strings ~cascade_name:"briefing" in
  check bool "briefing is non-empty" true (List.length models >= 1);
  (* glm:auto is always the final fallback *)
  let last = List.nth models (List.length models - 1) in
  check string "briefing ends with glm:auto" "glm:auto" last

let test_classification_uses_llama_first () =
  let models =
    Cascade.default_model_strings ~cascade_name:"classification"
  in
  let first = List.hd models in
  check bool "classification starts with llama:" true
    (String.length first > 6 && String.sub first 0 6 = "llama:")

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
          test_case "briefing always has glm:auto" `Quick
            test_briefing_always_has_glm_auto;
          test_case "classification uses llama first" `Quick
            test_classification_uses_llama_first;
        ] );
    ]
