open Alcotest
module Voice = Masc_mcp.Voice_runtime_overlay

let with_env name value f =
  let previous = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> Unix.putenv name "");
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some v -> Unix.putenv name v
      | None -> Unix.putenv name "")
    f
;;

let test_resolve_voice_aliases () =
  let elevenlabs = Option.get (Voice.resolve_adapter "elevenlabs") in
  check string "elevenlabs alias" "elevenlabs-direct" elevenlabs.canonical_name;
  let openai_compat = Option.get (Voice.resolve_adapter "openai_compat") in
  check string "openai compat alias" "voice-openai-compat" openai_compat.canonical_name
;;

let test_voice_auth_env_resolution () =
  let elevenlabs = Option.get (Voice.resolve_adapter "elevenlabs-direct") in
  check
    (option string)
    "elevenlabs auth env"
    (Some "ELEVENLABS_API_KEY")
    (Voice.auth_env_name elevenlabs);
  let openai_compat = Option.get (Voice.resolve_adapter "voice-openai-compat") in
  check
    (option string)
    "endpoint override auth env"
    (Some "VOICE_PROXY_KEY")
    (Voice.auth_env_name ~endpoint_api_key_env:"VOICE_PROXY_KEY" openai_compat)
;;

let test_default_agent_voices_preserve_runtime_defaults () =
  check
    (list (pair string string))
    "agent voice defaults"
    [ "llama", "Laura"
    ; "claude", "Sarah"
    ; "codex", "George"
    ; "gemini", "Roger"
    ; "claude-api", "Sarah"
    ; "codex-api", "George"
    ; "gemini-api", "Roger"
    ]
    (Voice.default_agent_voices ())
;;

let test_stt_request_elevenlabs_direct () =
  let endpoint : Masc_mcp.Voice_config.endpoint =
    { id = "test-stt"
    ; kind = Elevenlabs_direct
    ; base_url = Some "https://api.elevenlabs.io/v1"
    ; mcp_url = None
    ; health_url = None
    ; api_key_env = Some "ELEVENLABS_API_KEY"
    ; enabled = true
    ; timeout_seconds = Some 30.0
    ; max_retries = Some 2
    }
  in
  with_env "ELEVENLABS_API_KEY" (Some "test-key-123") (fun () ->
    match
      Voice.stt_request_for_endpoint
        endpoint
        ~api_key:"test-key-123"
        ~audio_file:"/tmp/test.wav"
        ~model:"scribe_v2"
    with
    | Ok req ->
      check string "url" "https://api.elevenlabs.io/v1/speech-to-text" req.url;
      check
        bool
        "has xi-api-key header"
        true
        (List.exists (fun (k, _) -> k = "xi-api-key") req.headers);
      check
        bool
        "model_id in form_fields"
        true
        (List.exists (fun (k, v) -> k = "model_id" && v = "scribe_v2") req.form_fields);
      let field_name, file_path = req.file_field in
      check string "file field name" "file" field_name;
      check string "file path" "/tmp/test.wav" file_path
    | Error err -> fail (Printf.sprintf "expected Ok, got Error: %s" err))
;;

let test_stt_request_openai_compat () =
  let endpoint : Masc_mcp.Voice_config.endpoint =
    { id = "test-openai-stt"
    ; kind = Openai_compat
    ; base_url = Some "https://api.openai.com/v1"
    ; mcp_url = None
    ; health_url = None
    ; api_key_env = Some "OPENAI_API_KEY"
    ; enabled = true
    ; timeout_seconds = Some 30.0
    ; max_retries = Some 2
    }
  in
  match
    Voice.stt_request_for_endpoint
      endpoint
      ~api_key:"sk-test"
      ~audio_file:"/tmp/test.wav"
      ~model:"whisper-1"
  with
  | Ok req ->
    check string "url" "https://api.openai.com/v1/audio/transcriptions" req.url;
    check
      bool
      "has Authorization header"
      true
      (List.exists (fun (k, _) -> k = "Authorization") req.headers);
    check
      bool
      "model in form_fields"
      true
      (List.exists (fun (k, v) -> k = "model" && v = "whisper-1") req.form_fields)
  | Error err -> fail (Printf.sprintf "expected Ok, got Error: %s" err)
;;

let test_stt_request_mcp_rejected () =
  let endpoint : Masc_mcp.Voice_config.endpoint =
    { id = "test-mcp-stt"
    ; kind = Voice_mcp
    ; base_url = None
    ; mcp_url = Some "http://localhost:8936"
    ; health_url = None
    ; api_key_env = None
    ; enabled = true
    ; timeout_seconds = Some 5.0
    ; max_retries = Some 1
    }
  in
  match
    Voice.stt_request_for_endpoint
      endpoint
      ~api_key:""
      ~audio_file:"/tmp/test.wav"
      ~model:"scribe_v2"
  with
  | Ok _ -> fail "expected Error for voice_mcp endpoint"
  | Error _ -> ()
;;

let () =
  run
    "voice_runtime_overlay"
    [ ( "adapter"
      , [ test_case "resolve voice aliases" `Quick test_resolve_voice_aliases
        ; test_case "voice auth env resolution" `Quick test_voice_auth_env_resolution
        ; test_case
            "default agent voices preserve runtime defaults"
            `Quick
            test_default_agent_voices_preserve_runtime_defaults
        ] )
    ; ( "stt"
      , [ test_case
            "stt request elevenlabs direct"
            `Quick
            test_stt_request_elevenlabs_direct
        ; test_case "stt request openai compat" `Quick test_stt_request_openai_compat
        ; test_case "stt request mcp rejected" `Quick test_stt_request_mcp_rejected
        ] )
    ]
;;
