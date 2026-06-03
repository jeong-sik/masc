open Alcotest
module Voice = Masc.Voice_runtime_overlay

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
  check string "provider_d compat alias" "voice-provider_d-compat" openai_compat.canonical_name
;;

let test_voice_auth_env_resolution () =
  let elevenlabs = Option.get (Voice.resolve_adapter "elevenlabs-direct") in
  check
    (option string)
    "elevenlabs auth env"
    (Some "ELEVENLABS_API_KEY")
    (Voice.auth_env_name elevenlabs);
  let openai_compat = Option.get (Voice.resolve_adapter "voice-provider_d-compat") in
  check
    (option string)
    "endpoint override auth env"
    (Some "VOICE_PROXY_KEY")
    (Voice.auth_env_name ~endpoint_api_key_env:"VOICE_PROXY_KEY" openai_compat)
;;

let test_default_agent_voices_are_config_driven () =
  check
    (list (pair string string))
    "agent voice defaults are not hardcoded"
    []
    (Voice.default_agent_voices ())
;;

let test_voice_mcp_env_no_longer_overrides_default_session_url () =
  with_env "MASC_HTTP_BASE_URL" None (fun () ->
    with_env "MASC_HOST" None (fun () ->
      with_env "MASC_HTTP_PORT" None (fun () ->
        with_env "VOICE_MCP_HOST" (Some "voice.example.test") (fun () ->
          with_env "VOICE_MCP_PORT" (Some "9999") (fun () ->
            check
              string
              "voice env ignored"
              "http://127.0.0.1:8935/mcp"
              (Voice.default_session_url ~path:"/mcp"))))))
;;

let test_stt_request_elevenlabs_direct () =
  let endpoint : Masc.Voice_config.endpoint =
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
  let endpoint : Masc.Voice_config.endpoint =
    { id = "test-provider_d-stt"
    ; kind = Openai_compat
    ; base_url = Some "https://api.provider_d.com/v1"
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
    check string "url" "https://api.provider_d.com/v1/audio/transcriptions" req.url;
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
  let endpoint : Masc.Voice_config.endpoint =
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

let make_keeper_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
          [ "name", `String name
          ; "agent_name", `String name
          ; "trace_id", `String "voice-queue-test"
          ])
  with
  | Ok meta -> meta
  | Error err -> fail ("make_keeper_meta: " ^ err)
;;

let test_keeper_voice_speak_returns_queued_with_root_switch () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock ~sw (fun () ->
    let meta = make_keeper_meta "voice-queue-keeper" in
    let raw =
      Masc.Keeper_tool_voice_runtime.handle_voice_tool
        ~meta
        ~name:"keeper_voice_speak"
        ~args:(`Assoc [ "message", `String "hello from queued voice test" ])
    in
    let json = Yojson.Safe.from_string raw in
    check string "queued status" "queued"
      Yojson.Safe.Util.(member "status" json |> to_string);
    check string "background execution" "background_voice_queue"
      Yojson.Safe.Util.(member "execution" json |> to_string))
;;

let () =
  run
    "voice_runtime_overlay"
    [ ( "adapter"
      , [ test_case "resolve voice aliases" `Quick test_resolve_voice_aliases
        ; test_case "voice auth env resolution" `Quick test_voice_auth_env_resolution
        ; test_case
            "default agent voices are config driven"
            `Quick
            test_default_agent_voices_are_config_driven
        ; test_case
            "voice mcp env no longer overrides default session url"
            `Quick
            test_voice_mcp_env_no_longer_overrides_default_session_url
        ] )
    ; ( "stt"
      , [ test_case
            "stt request elevenlabs direct"
            `Quick
            test_stt_request_elevenlabs_direct
        ; test_case "stt request provider_d compat" `Quick test_stt_request_openai_compat
        ; test_case "stt request mcp rejected" `Quick test_stt_request_mcp_rejected
        ] )
    ; ( "keeper_voice_queue"
      , [ test_case
            "keeper_voice_speak queues on root switch"
            `Quick
            test_keeper_voice_speak_returns_queued_with_root_switch
        ] )
    ]
;;
