open Alcotest

module Lodge_cascade = Masc_mcp.Lodge_cascade
module Llm_client = Masc_mcp.Llm_client

let with_temp_json contents f =
  let path = Filename.temp_file "lodge_cascade_" ".json" in
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
    {|{"heartbeat_action_models":["llama:qwen-local","ollama:glm-4.7-flash"]}|}
    (fun path ->
      let specs = Lodge_cascade.get_cascade ~config_path:path ~cascade_name:"heartbeat_action" () in
      check int "spec count" 2 (List.length specs);
      match specs with
      | [ first; second ] ->
          check bool "first is llama" true (first.provider = Llm_client.Llama);
          check string "first model" "qwen-local" first.model_id;
          check bool "second is ollama" true (second.provider = Llm_client.Ollama);
          check string "second model" "glm-4.7-flash" second.model_id
      | _ -> fail "expected two specs")

let test_skips_invalid_and_missing_api_key () =
  with_env "GEMINI_API_KEY" "" (fun () ->
      with_temp_json
        {|{"heartbeat_action_models":["invalid","gemini:gemini-2.5-pro","llama:qwen-live"]}|}
        (fun path ->
          let specs = Lodge_cascade.get_cascade ~config_path:path ~cascade_name:"heartbeat_action" () in
          check int "only llama survives" 1 (List.length specs);
          match specs with
          | [ only ] ->
              check bool "llama provider" true
                (only.provider = Llm_client.Llama);
              check string "llama model" "qwen-live" only.model_id
          | _ -> fail "expected one surviving spec"))

let test_missing_config_uses_defaults () =
  let path = Filename.concat (Filename.get_temp_dir_name ()) "missing-llm-cascade.json" in
  let specs = Lodge_cascade.get_cascade ~config_path:path ~cascade_name:"heartbeat_action" () in
  check bool "defaults available" true (List.length specs >= 1);
  match specs with
  | first :: _ ->
      check bool "default starts with llama" true
        (first.provider = Llm_client.Llama);
      check string "default llama model" "qwen3.5-35b-a3b-ud-q8-xl"
        first.model_id
  | [] -> fail "expected default fallback models"

let () =
  run "lodge_cascade"
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
    ]
