open Alcotest

module Cache = Masc_mcp.Llm_response_cache
module Env_config = Masc_mcp.Env_config
module Llm_types = Masc_mcp.Llm_types
module Llm_orchestration = Masc_mcp.Llm_orchestration

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Array.iter (fun name -> rm_rf (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else
      Unix.unlink path

let with_temp_cwd f =
  let original = Sys.getcwd () in
  let dir = Filename.temp_file "test_llm_client_cascade_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  Unix.chdir dir;
  Fun.protect
    ~finally:(fun () ->
      Unix.chdir original;
      rm_rf dir)
    f

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f

(** Store a cached response in OAS api_response JSON format.
    Uses MASC cache key (temperature-aware) + OAS serialization. *)
let cache_response (req : Llm_types.completion_request) ~content ~model_used =
  let key = Llm_orchestration.cache_key_of_request req in
  let payload =
    `Assoc
      [
        ("v", `String "1");
        ("id", `String "cached");
        ("model", `String model_used);
        ("stop_reason", `String "end_turn");
        ("content", `List [
          `Assoc [("type", `String "text"); ("text", `String content)]
        ]);
        ("usage", `Assoc
          [
            ("input_tokens", `Int 1);
            ("output_tokens", `Int 1);
            ("cache_creation_input_tokens", `Int 0);
            ("cache_read_input_tokens", `Int 0);
          ]);
      ]
  in
  match Cache.set_json ~key ~ttl_seconds:30 payload with
  | Ok () -> ()
  | Error e -> fail ("set_json failed: " ^ e)

let make_request model_id =
  let model : Llm_types.model_spec =
    {
      provider = Llm_types.Custom "cached";
      model_id;
      max_context = 4096;
      api_url = "http://127.0.0.1:1";
      api_key_env = None;
      cost_per_1k_input = 0.0;
      cost_per_1k_output = 0.0;
    }
  in
  ({
     model;
     messages = [ Agent_sdk.Types.user_msg ("prompt:" ^ model_id) ];
     temperature = 0.0;
     max_tokens = 64;
     tools = [];
     response_format = `Text;
   }
    : Llm_types.completion_request)

let make_request_for_model ?(temperature = 0.0) ~model ~prompt ~max_tokens () =
  ({
     model;
     messages = [ Agent_sdk.Types.user_msg prompt ];
     temperature;
     max_tokens;
     tools = [];
     response_format = `Text;
   }
    : Llm_types.completion_request)

let contains_substring haystack needle =
  let h_len = String.length haystack in
  let n_len = String.length needle in
  let rec loop idx =
    idx + n_len <= h_len
    && (String.sub haystack idx n_len = needle || loop (idx + 1))
  in
  if n_len = 0 then true else loop 0

let test_cascade_uses_next_cached_response_when_validator_rejects () =
  with_temp_cwd (fun () ->
      Cache.clear_l1 ();
      let first = make_request "cached-1" in
      let second = make_request "cached-2" in
      cache_response first ~content:"reject me" ~model_used:"cached-1";
      cache_response second ~content:"accept me" ~model_used:"cached-2";
      match
        Llm_orchestration.cascade
          ~accept:(fun (resp : Llm_types.completion_response) ->
            not (String.equal (Llm_types.text_of_response resp) "reject me"))
          [ first; second ]
      with
      | Ok resp ->
          check string "content" "accept me" (Llm_types.text_of_response resp);
          check string "winner" "cached-2" resp.model_used
      | Error e -> fail ("unexpected cascade error: " ^ e))

let test_cascade_returns_error_when_all_responses_rejected () =
  with_temp_cwd (fun () ->
      Cache.clear_l1 ();
      let first = make_request "cached-only" in
      cache_response first ~content:"reject me" ~model_used:"cached-only";
      match
        Llm_orchestration.cascade
          ~accept:(fun (resp : Llm_types.completion_response) ->
            not (String.equal (Llm_types.text_of_response resp) "reject me"))
          [ first ]
      with
      | Ok _ -> fail "expected rejection error"
      | Error e ->
          check bool "validator rejection in error" true
            (contains_substring e "response rejected by validator"))

let test_available_model_specs_filters_invalid_and_missing_keys () =
  with_env "GEMINI_API_KEY" "" (fun () ->
      let specs =
        Llm_types.available_model_specs_of_strings
          [ "invalid"; "gemini:gemini-2.5-pro"; "llama:qwen3.5-35b-a3b-ud-q8-xl" ]
      in
      check int "only llama survives" 1 (List.length specs);
      match specs with
      | [ only ] ->
          check bool "provider" true (only.provider = Llm_types.Llama);
          check string "model id" "qwen3.5-35b-a3b-ud-q8-xl" only.model_id
      | _ -> fail "expected one filtered model")

let test_model_spec_of_string_rejects_bare_ollama_provider () =
  match Llm_types.model_spec_of_string "ollama:glm-4.7-flash" with
  | Ok _ -> fail "expected ollama: prefix to be rejected"
  | Error _ -> ()

let test_model_spec_of_string_parses_llama_provider () =
  match Llm_types.model_spec_of_string "llama:glm-4.7-flash" with
  | Ok spec ->
      check bool "provider" true (spec.provider = Llm_types.Llama);
      check string "model id" "glm-4.7-flash" spec.model_id
  | Error e -> fail ("expected llama: provider to parse: " ^ e)

let test_model_spec_of_string_resolves_default_label () =
  with_env "MASC_DEFAULT_PROVIDER" "glm" (fun () ->
      with_env "MASC_DEFAULT_MODEL" "glm-4.7" (fun () ->
          match Llm_types.model_spec_of_string "default" with
          | Ok spec ->
              check bool "provider" true (spec.provider = Llm_types.Glm_cloud);
              check string "model id" "glm-4.7" spec.model_id
          | Error e -> fail ("expected default to resolve: " ^ e)))

let test_model_spec_of_string_resolves_default_override () =
  with_env "MASC_DEFAULT_PROVIDER" "gemini" (fun () ->
      with_env "MASC_DEFAULT_MODEL" "gemini-2.5-pro" (fun () ->
          match Llm_types.model_spec_of_string "default:gemini-2.5-flash" with
          | Ok spec ->
              check bool "provider" true (spec.provider = Llm_types.Gemini);
              check string "model id" "gemini-2.5-flash" spec.model_id
          | Error e -> fail ("expected default override to resolve: " ^ e)))

let test_run_prompt_cascade_uses_same_request_shape () =
  with_temp_cwd (fun () ->
      Cache.clear_l1 ();
      let model1 : Llm_types.model_spec =
        {
          provider = Llm_types.Custom "cached";
          model_id = "run-prompt-1";
          max_context = 4096;
          api_url = "http://127.0.0.1:1";
          api_key_env = None;
          cost_per_1k_input = 0.0;
          cost_per_1k_output = 0.0;
        }
      in
      let model2 = { model1 with model_id = "run-prompt-2" } in
      let prompt = "shared helper prompt" in
      cache_response
        (make_request_for_model ~model:model1 ~prompt ~max_tokens:32 ())
        ~content:"reject me" ~model_used:"run-prompt-1";
      cache_response
        (make_request_for_model ~model:model2 ~prompt ~max_tokens:32 ())
        ~content:"accept me" ~model_used:"run-prompt-2";
      match
        Llm_orchestration.run_prompt_cascade ~temperature:0.0 ~timeout_sec:30
          ~accept:(fun (resp : Llm_types.completion_response) ->
            not (String.equal (Llm_types.text_of_response resp) "reject me"))
          ~model_specs:[ model1; model2 ] ~max_tokens:32 ~prompt ()
      with
      | Ok resp ->
          check string "content" "accept me" (Llm_types.text_of_response resp);
          check string "winner" "run-prompt-2" resp.model_used
      | Error e -> fail ("unexpected run_prompt_cascade error: " ^ e))

let test_llama_cache_key_preserves_requested_budget_below_global_cap () =
  let llama_model =
    { Llm_types.llama_default with model_id = "qwen3.5-35b-a3b-ud-q8-xl" }
  in
  let req_short =
    make_request_for_model ~model:llama_model ~prompt:"same prompt" ~max_tokens:32 ()
  in
  let req_long =
    make_request_for_model ~model:llama_model ~prompt:"same prompt" ~max_tokens:8192 ()
  in
  check bool "different cache key"
    true
    (Llm_orchestration.cache_key_of_request req_short
     <> Llm_orchestration.cache_key_of_request req_long)

let test_llama_cache_key_caps_requests_above_global_limit () =
  let llama_model =
    { Llm_types.llama_default with model_id = "qwen3.5-35b-a3b-ud-q8-xl" }
  in
  let req_near_cap =
    make_request_for_model ~model:llama_model ~prompt:"same prompt"
      ~max_tokens:(Env_config.Llama.max_tokens + 1) ()
  in
  let req_far_above_cap =
    make_request_for_model ~model:llama_model ~prompt:"same prompt"
      ~max_tokens:(Env_config.Llama.max_tokens * 2) ()
  in
  check string "same capped cache key"
    (Llm_orchestration.cache_key_of_request req_near_cap)
    (Llm_orchestration.cache_key_of_request req_far_above_cap)

let test_non_llama_cache_key_preserves_requested_budget () =
  let model : Llm_types.model_spec =
    {
      provider = Llm_types.Custom "cached";
      model_id = "shape-check";
      max_context = 4096;
      api_url = "http://127.0.0.1:1";
      api_key_env = None;
      cost_per_1k_input = 0.0;
      cost_per_1k_output = 0.0;
    }
  in
  let req_short =
    make_request_for_model ~model ~prompt:"same prompt" ~max_tokens:32 ()
  in
  let req_long =
    make_request_for_model ~model ~prompt:"same prompt" ~max_tokens:8192 ()
  in
  check bool "different cache key"
    true
    (Llm_orchestration.cache_key_of_request req_short
     <> Llm_orchestration.cache_key_of_request req_long)

let () =
  run "llm_client_cascade"
    [
      ( "accept",
        [
          test_case "uses next cached response after rejection" `Quick
            test_cascade_uses_next_cached_response_when_validator_rejects;
          test_case "all rejected returns error" `Quick
            test_cascade_returns_error_when_all_responses_rejected;
        ] );
      ( "helpers",
        [
          test_case "filters invalid and missing keys" `Quick
            test_available_model_specs_filters_invalid_and_missing_keys;
          test_case "rejects bare ollama provider" `Quick
            test_model_spec_of_string_rejects_bare_ollama_provider;
          test_case "parses llama provider" `Quick
            test_model_spec_of_string_parses_llama_provider;
          test_case "resolves default label" `Quick
            test_model_spec_of_string_resolves_default_label;
          test_case "resolves default override" `Quick
            test_model_spec_of_string_resolves_default_override;
          test_case "run_prompt_cascade request shape" `Quick
            test_run_prompt_cascade_uses_same_request_shape;
          test_case "llama cache key preserves requested budget below cap" `Quick
            test_llama_cache_key_preserves_requested_budget_below_global_cap;
          test_case "llama cache key caps requests above global limit" `Quick
            test_llama_cache_key_caps_requests_above_global_limit;
          test_case "non-llama cache key preserves requested budget" `Quick
            test_non_llama_cache_key_preserves_requested_budget;
        ] );
    ]
