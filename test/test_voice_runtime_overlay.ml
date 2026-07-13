open Alcotest
module Voice = Voice_runtime_overlay

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

let rec rm_rf path =
  if Sys.file_exists path
  then if Sys.is_directory path
  then (
    Sys.readdir path |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
    Unix.rmdir path)
  else Sys.remove path
;;

let voice_session_test_base =
  let path = Filename.temp_file "voice-runtime-overlay-" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let () =
  Unix.putenv "MASC_BASE_PATH" voice_session_test_base;
  Unix.putenv "MASC_BASE_PATH_INPUT" voice_session_test_base;
  at_exit (fun () -> rm_rf voice_session_test_base)
;;

let test_config () = Masc.Workspace.default_config voice_session_test_base

let read_lines path =
  if not (Sys.file_exists path)
  then []
  else (
    let ic = open_in path in
    let rec loop acc =
      match input_line ic with
      | line -> loop (line :: acc)
      | exception End_of_file ->
        close_in ic;
        List.rev acc
      | exception exn ->
        close_in_noerr ic;
        raise exn
    in
    loop [])
;;

let write_file path contents =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents)
;;

let mkdir_if_missing path =
  if not (Sys.file_exists path) then Unix.mkdir path 0o755
;;

let contains_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len = 0 then true
  else
    let rec loop idx =
      idx + needle_len <= haystack_len
      && (String.sub haystack idx needle_len = needle || loop (idx + 1))
    in
    loop 0
;;

let check_json_omits label needle json =
  check bool label false (contains_substring ~needle (Yojson.Safe.to_string json))
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

let elevenlabs_tts_endpoint : Voice_config.endpoint =
  { id = "test-tts"
  ; kind = Voice_config.Elevenlabs_direct
  ; base_url = Some "https://api.elevenlabs.io/v1"
  ; mcp_url = None
  ; health_url = None
  ; api_key_env = Some "ELEVENLABS_API_KEY"
  ; enabled = true
  ; timeout_seconds = Some 30.0
  ; max_retries = Some 2
  }
;;

let default_voice_tuning : Voice_config.voice_tuning =
  { stability = 0.55; similarity_boost = 0.75; style = 0.0 }
;;

let test_elevenlabs_voice_id = "testvoiceid0123456789"

let test_tts_request_elevenlabs_accepts_voice_id () =
  match
    Voice.http_request_for_tts
      elevenlabs_tts_endpoint
      ~api_key:"test-key-123"
      ~message:"hello"
      ~voice:test_elevenlabs_voice_id
      ~model:"eleven_multilingual_v2"
      ~tuning:default_voice_tuning
  with
  | Ok req ->
    check
      string
      "url uses configured voice_id"
      ("https://api.elevenlabs.io/v1/text-to-speech/" ^ test_elevenlabs_voice_id)
      req.url
  | Error err -> fail (Printf.sprintf "expected Ok, got Error: %s" err)
;;

let test_tts_request_elevenlabs_rejects_blank_voice () =
  match
    Voice.http_request_for_tts
      elevenlabs_tts_endpoint
      ~api_key:"test-key-123"
      ~message:"hello"
      ~voice:""
      ~model:"eleven_multilingual_v2"
      ~tuning:default_voice_tuning
  with
  | Ok _ -> fail "expected Error for blank ElevenLabs voice"
  | Error err ->
    check
      bool
      "error explains configured voice_id requirement"
      true
      (String_util.contains_substring err "configured voice_id")
;;

let test_tts_request_elevenlabs_rejects_unknown_name () =
  match
    Voice.http_request_for_tts
      elevenlabs_tts_endpoint
      ~api_key:"test-key-123"
      ~message:"hello"
      ~voice:"Charlotte"
      ~model:"eleven_multilingual_v2"
      ~tuning:default_voice_tuning
  with
  | Ok _ -> fail "expected Error for unknown ElevenLabs voice name"
  | Error err ->
    check
      bool
      "error explains voice_id requirement"
      true
      (String_util.contains_substring err "voice_id"
       && String_util.contains_substring err "Charlotte")
;;

let test_stt_request_elevenlabs_direct () =
  let endpoint : Voice_config.endpoint =
    { id = "test-stt"
    ; kind = Voice_config.Elevenlabs_direct
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
  let endpoint : Voice_config.endpoint =
    { id = "test-openai-stt"
    ; kind = Voice_config.Openai_compat
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
  let endpoint : Voice_config.endpoint =
    { id = "test-mcp-stt"
    ; kind = Voice_config.Voice_mcp
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

(* Regression for the 2026-06-10 voice repeat incident: the speak tool is
   synchronous again. With no TTS endpoint configured in the sandbox, the
   failure must surface to the caller as status=error — never as a
   fire-and-forget "queued" pseudo-success the model would mistake for
   completed playback. *)
let test_keeper_voice_speak_surfaces_tts_failure () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock ~sw (fun () ->
    let config = test_config () in
    let meta = make_keeper_meta "voice-sync-keeper" in
    let raw =
      Masc.Keeper_tool_voice_runtime.handle_voice_tool
        ~config
        ~meta
        ~name:"keeper_voice_speak"
        ~args:(`Assoc [ "message", `String "hello from sync voice test" ])
        ()
    in
    let json = Yojson.Safe.from_string raw in
    check string "error status" "error"
      Yojson.Safe.Util.(member "status" json |> to_string);
    check string "failure reason surfaced" "no configured TTS endpoint"
      Yojson.Safe.Util.(member "message" json |> to_string))
;;

let test_keeper_voice_speak_failure_writes_no_memory_row () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock ~sw (fun () ->
    let config = test_config () in
    let meta = make_keeper_meta "voice-memory-keeper" in
    let message = "unspoken voice must not be recorded" in
    ignore
      (Masc.Keeper_tool_voice_runtime.handle_voice_tool
         ~config
         ~meta
         ~name:"keeper_voice_speak"
         ~args:(`Assoc [ "message", `String message; "priority", `Int 3 ])
         ());
    let memory_path = Masc.Keeper_types_support.keeper_memory_bank_path config meta.name in
    let rows =
      read_lines memory_path
      |> List.filter_map Masc.Keeper_memory_bank.parse_memory_bank_row
    in
    let row =
      rows
      |> List.find_opt (fun row ->
        row.Masc.Keeper_memory_bank.source = Masc.Keeper_memory_bank.Voice_output
        && String.equal row.text message)
    in
    check bool "no voice_output row for failed speak" true (Option.is_none row))
;;

let test_keeper_voice_speak_text_fallback_records_memory_bank_row () =
  let config = test_config () in
  let meta = make_keeper_meta "voice-fallback-memory-keeper" in
  let message = "fallback speech should be durable" in
  let raw =
    Masc.Keeper_tool_voice_runtime.handle_voice_tool
      ~config
      ~meta
      ~name:"keeper_voice_speak"
      ~args:(`Assoc [ "message", `String message ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  check string "text fallback status" "text_fallback"
    Yojson.Safe.Util.(member "status" json |> to_string);
  check bool "fallback memory recorded" true
    Yojson.Safe.Util.(member "memory_recorded" json |> to_bool);
  let memory_path = Masc.Keeper_types_support.keeper_memory_bank_path config meta.name in
  let rows =
    read_lines memory_path
    |> List.filter_map Masc.Keeper_memory_bank.parse_memory_bank_row
  in
  let row =
    rows
    |> List.find_opt (fun row ->
      row.Masc.Keeper_memory_bank.source = Masc.Keeper_memory_bank.Voice_output
      && row.kind = Masc.Keeper_memory_bank.Progress
      && String.equal row.text message)
  in
  match row with
  | Some row ->
    check string "fallback memory execution" "text_fallback"
      Yojson.Safe.Util.(member "execution" row.json |> to_string)
  | None -> fail "expected fallback voice_output progress memory row"
;;

(* Regression for the 2026-06-14 sangsu voice self-echo loop: the raw
   voice_output row must stay durable in the memory bank, but it must not
   appear in the auto-injected recent-note summary that drives the next
   turn, or the model will answer its own spoken text repeatedly. *)
let test_voice_output_row_is_excluded_from_memory_recent_notes () =
  let config = test_config () in
  let meta = make_keeper_meta "voice-recent-note-filter-keeper" in
  let message = "this should not echo back as a recent note" in
  let raw =
    Masc.Keeper_tool_voice_runtime.handle_voice_tool
      ~config
      ~meta
      ~name:"keeper_voice_speak"
      ~args:(`Assoc [ "message", `String message ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  check bool "fallback memory recorded" true
    Yojson.Safe.Util.(member "memory_recorded" json |> to_bool);
  let memory_path = Masc.Keeper_types_support.keeper_memory_bank_path config meta.name in
  let lines = read_lines memory_path in
  let summary =
    Masc.Keeper_memory_bank.summarize_memory_bank_lines lines ~recent_limit:4
  in
  let has_voice_text =
    List.exists
      (fun (row : Masc.Keeper_memory_bank.keeper_memory_line) ->
         String.equal row.text message)
      summary.recent_notes
  in
  check bool "voice_output source not in recent_notes" false has_voice_text
;;

let test_keeper_voice_session_start_does_not_store_session_name_as_voice () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock ~sw (fun () ->
    let config = test_config () in
    let meta = make_keeper_meta "voice-session-name-regression" in
    let session_name = "shutup-shutup-shutup" in
    let raw =
      Masc.Keeper_tool_voice_runtime.handle_voice_tool
        ~config
        ~meta
        ~name:"keeper_voice_session_start"
        ~args:(`Assoc [ "session_name", `String session_name ])
        ()
    in
    let json = Yojson.Safe.from_string raw in
    let voice = Yojson.Safe.Util.(member "voice" json |> to_string) in
    check bool "session_name is not persisted as voice" true
      (not (String.equal session_name voice));
    let voice_loop = Yojson.Safe.Util.member "voice_loop" json in
    check string "session start loop mode" "turn_based_batch"
      Yojson.Safe.Util.(member "mode" voice_loop |> to_string);
    check bool "session start loop active" true
      Yojson.Safe.Util.(member "session_active" voice_loop |> to_bool);
    check bool "session start realtime unsupported" false
      Yojson.Safe.Util.(member "realtime_supported" voice_loop |> to_bool);
    check string "session start output tool" "keeper_voice_speak"
      Yojson.Safe.Util.(
        member "keeper_output" voice_loop |> member "tool" |> to_string);
    ignore
      (Masc.Keeper_tool_voice_runtime.handle_voice_tool
         ~config
         ~meta
         ~name:"keeper_voice_session_end"
         ~args:(`Assoc [])
         ()))
;;

let test_voice_realtime_bridge_endpoint_validation () =
  let getenv_missing _ = None in
  check
    (option string)
    "missing bridge endpoint"
    None
    (Masc.Voice_session_manager.realtime_bridge_endpoint ~getenv:getenv_missing ());
  let getenv_blank _ = Some "   " in
  check
    (option string)
    "blank bridge endpoint"
    None
    (Masc.Voice_session_manager.realtime_bridge_endpoint ~getenv:getenv_blank ());
  let getenv_http _ = Some "https://voice.example.test/ws" in
  check
    (option string)
    "http bridge endpoint rejected"
    None
    (Masc.Voice_session_manager.realtime_bridge_endpoint ~getenv:getenv_http ());
  let getenv_ws _ = Some " ws://127.0.0.1:9999/voice " in
  check
    (option string)
    "ws bridge endpoint accepted"
    (Some "ws://127.0.0.1:9999/voice")
    (Masc.Voice_session_manager.realtime_bridge_endpoint ~getenv:getenv_ws ());
  let getenv_wss _ = Some "wss://voice.example.test/live" in
  check
    (option string)
    "wss bridge endpoint accepted"
    (Some "wss://voice.example.test/live")
    (Masc.Voice_session_manager.realtime_bridge_endpoint ~getenv:getenv_wss ())
;;

let json_string_list json =
  Yojson.Safe.Util.to_list json |> List.map Yojson.Safe.Util.to_string
;;

let test_keeper_voice_session_end_reports_ended () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock ~sw (fun () ->
    let config = test_config () in
    let meta = make_keeper_meta "voice-session-end-keeper" in
    ignore
      (Masc.Keeper_tool_voice_runtime.handle_voice_tool
         ~config
         ~meta
         ~name:"keeper_voice_session_start"
         ~args:(`Assoc [ "session_name", `String "end regression" ])
         ());
    let end_raw =
      Masc.Keeper_tool_voice_runtime.handle_voice_tool
        ~config
        ~meta
        ~name:"keeper_voice_session_end"
        ~args:(`Assoc [])
        ()
    in
    let end_json = Yojson.Safe.from_string end_raw in
    check string "session ended" "ended"
      Yojson.Safe.Util.(member "status" end_json |> to_string);
    (* The fire-and-forget speak queue was removed with the synchronous
       speak contract; session_end no longer reports discarded jobs. *)
    check bool "no queue discard field" true
      (Yojson.Safe.Util.member "discarded_voice_queue_jobs" end_json = `Null))
;;

let test_keeper_voice_session_start_realtime_requires_bridge_env () =
  with_env Masc.Voice_session_manager.realtime_bridge_env None (fun () ->
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    let mono_clock = Eio.Stdenv.mono_clock env in
    Eio_context.with_test_env ~net ~clock ~mono_clock ~sw (fun () ->
      let config = test_config () in
      let meta = make_keeper_meta "voice-realtime-missing-bridge" in
      ignore
        (Masc.Keeper_tool_voice_runtime.handle_voice_tool
           ~config
           ~meta
           ~name:"keeper_voice_session_end"
           ~args:(`Assoc [])
           ());
      let raw =
        Masc.Keeper_tool_voice_runtime.handle_voice_tool
          ~config
          ~meta
          ~name:"keeper_voice_session_start"
          ~args:(`Assoc [ "conversation_mode", `String "realtime_bridge" ])
          ()
      in
      let json = Yojson.Safe.from_string raw in
      check
        string
        "realtime start rejected"
        "voice_realtime_bridge_unavailable"
        Yojson.Safe.Util.(member "error" json |> to_string);
      check
        string
        "bridge env surfaced"
        Masc.Voice_session_manager.realtime_bridge_env
        Yojson.Safe.Util.(member "required_env" json |> to_string);
      check string "fallback mode surfaced" "turn_based"
        Yojson.Safe.Util.(member "fallback_conversation_mode" json |> to_string);
      let agent_raw =
        Masc.Keeper_tool_voice_runtime.handle_voice_tool
          ~config
          ~meta
          ~name:"keeper_voice_agent"
          ~args:(`Assoc [])
          ()
      in
      let agent_json = Yojson.Safe.from_string agent_raw in
      check bool "rejected realtime start does not create session" false
        Yojson.Safe.Util.(member "session_active" agent_json |> to_bool)))
;;

let test_keeper_voice_agent_reports_turn_based_capability () =
  with_env Masc.Voice_session_manager.realtime_bridge_env None (fun () ->
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock ~sw (fun () ->
    let config = test_config () in
    let meta = make_keeper_meta "voice-capability-keeper" in
    let read_agent () =
      Masc.Keeper_tool_voice_runtime.handle_voice_tool
        ~config
        ~meta
        ~name:"keeper_voice_agent"
        ~args:(`Assoc [])
        ()
      |> Yojson.Safe.from_string
    in
    let end_session () =
      ignore
        (Masc.Keeper_tool_voice_runtime.handle_voice_tool
           ~config
           ~meta
           ~name:"keeper_voice_session_end"
           ~args:(`Assoc [])
           ())
    in
    end_session ();
    let before = read_agent () in
    check string "conversation mode" "turn_based"
      Yojson.Safe.Util.(member "conversation_mode" before |> to_string);
    check string "transport mode" "batch_stt_tts"
      Yojson.Safe.Util.(member "transport_mode" before |> to_string);
    check bool "realtime unsupported" false
      Yojson.Safe.Util.(member "realtime_supported" before |> to_bool);
    let realtime_bridge = Yojson.Safe.Util.member "realtime_bridge" before in
    check bool "realtime bridge unconfigured" false
      Yojson.Safe.Util.(member "configured" realtime_bridge |> to_bool);
    check
      string
      "realtime bridge env surfaced"
      Masc.Voice_session_manager.realtime_bridge_env
      Yojson.Safe.Util.(member "required_env" realtime_bridge |> to_string);
    check bool "realtime bridge endpoint absent" true
      (Yojson.Safe.Util.member "endpoint" realtime_bridge = `Null);
    check (list string) "available conversation modes" [ "turn_based" ]
      Yojson.Safe.Util.(
        member "available_conversation_modes" before |> json_string_list);
    let before_loop = Yojson.Safe.Util.member "voice_loop" before in
    check string "loop input route" "POST /api/v1/voice/transcribe"
      Yojson.Safe.Util.(
        member "operator_input" before_loop |> member "server_route" |> to_string);
    check string "loop output route" "GET /api/v1/voice/audio/<token>"
      Yojson.Safe.Util.(
        member "keeper_output" before_loop |> member "browser_route" |> to_string);
    check bool "no active session" false
      Yojson.Safe.Util.(member "session_active" before |> to_bool);
    check bool "active_session is null" true
      (Yojson.Safe.Util.member "active_session" before = `Null);
    ignore
      (Masc.Keeper_tool_voice_runtime.handle_voice_tool
         ~config
         ~meta
         ~name:"keeper_voice_session_start"
         ~args:(`Assoc [])
         ());
    let after = read_agent () in
    check bool "session active" true
      Yojson.Safe.Util.(member "session_active" after |> to_bool);
    check string "active session agent" meta.name
      Yojson.Safe.Util.(member "active_session" after |> member "agent_id" |> to_string);
    check string "active session loop mode" "turn_based_batch"
      Yojson.Safe.Util.(
        member "active_session" after
        |> member "voice_loop"
        |> member "mode"
        |> to_string);
    end_session ()))
;;

let test_keeper_voice_agent_reports_realtime_bridge_capability () =
  let bridge_endpoint = "wss://token:secret@bridge.example/live?token=abc123" in
  with_env
    Masc.Voice_session_manager.realtime_bridge_env
    (Some bridge_endpoint)
    (fun () ->
      Eio_main.run
      @@ fun env ->
      Eio.Switch.run
      @@ fun sw ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.clock env in
      let mono_clock = Eio.Stdenv.mono_clock env in
      Eio_context.with_test_env ~net ~clock ~mono_clock ~sw (fun () ->
        let config = test_config () in
        let meta = make_keeper_meta "voice-realtime-bridge-keeper" in
        let read_agent () =
          Masc.Keeper_tool_voice_runtime.handle_voice_tool
            ~config
            ~meta
            ~name:"keeper_voice_agent"
            ~args:(`Assoc [])
            ()
          |> Yojson.Safe.from_string
        in
        let end_session () =
          ignore
            (Masc.Keeper_tool_voice_runtime.handle_voice_tool
               ~config
               ~meta
               ~name:"keeper_voice_session_end"
               ~args:(`Assoc [])
               ())
        in
        end_session ();
        let before = read_agent () in
        check string "default conversation mode" "turn_based"
          Yojson.Safe.Util.(member "conversation_mode" before |> to_string);
        check bool "realtime bridge makes realtime available" true
          Yojson.Safe.Util.(member "realtime_supported" before |> to_bool);
        let realtime_bridge = Yojson.Safe.Util.member "realtime_bridge" before in
        check bool "realtime bridge configured" true
          Yojson.Safe.Util.(member "configured" realtime_bridge |> to_bool);
        check bool "realtime bridge endpoint hidden" true
          (Yojson.Safe.Util.member "endpoint" realtime_bridge = `Null);
        check_json_omits "agent capability omits raw endpoint" bridge_endpoint before;
        check_json_omits "agent capability omits endpoint secret" "secret" before;
        check
          (list string)
          "available realtime conversation modes"
          [ "turn_based"; "realtime_bridge" ]
          Yojson.Safe.Util.(
            member "available_conversation_modes" before |> json_string_list);
        let start_raw =
          Masc.Keeper_tool_voice_runtime.handle_voice_tool
            ~config
            ~meta
            ~name:"keeper_voice_session_start"
            ~args:(`Assoc [ "conversation_mode", `String "realtime_bridge" ])
            ()
        in
        let start_json = Yojson.Safe.from_string start_raw in
        check string "realtime session mode" "realtime_bridge"
          Yojson.Safe.Util.(member "conversation_mode" start_json |> to_string);
        check string "realtime transport" "websocket_audio_bridge"
          Yojson.Safe.Util.(member "transport_mode" start_json |> to_string);
        check bool "realtime session supported" true
          Yojson.Safe.Util.(member "realtime_supported" start_json |> to_bool);
        check bool "realtime endpoint not serialized" true
          (Yojson.Safe.Util.member "realtime_bridge_endpoint" start_json = `Null);
        check_json_omits "session start omits raw endpoint" bridge_endpoint start_json;
        check_json_omits "session start omits endpoint secret" "secret" start_json;
        let voice_loop = Yojson.Safe.Util.member "voice_loop" start_json in
        check string "realtime loop mode" "realtime_bridge"
          Yojson.Safe.Util.(member "mode" voice_loop |> to_string);
        check string "realtime protocol" "masc.voice.realtime_bridge.v1"
          Yojson.Safe.Util.(member "protocol" voice_loop |> to_string);
        check bool "realtime loop bridge endpoint hidden" true
          (Yojson.Safe.Util.member "bridge_endpoint" voice_loop = `Null);
        let loop_bridge = Yojson.Safe.Util.member "realtime_bridge" voice_loop in
        check bool "realtime loop bridge configured" true
          Yojson.Safe.Util.(member "configured" loop_bridge |> to_bool);
        check bool "realtime loop bridge endpoint hidden" true
          (Yojson.Safe.Util.member "endpoint" loop_bridge = `Null);
        let after = read_agent () in
        check_json_omits "active agent omits raw endpoint" bridge_endpoint after;
        check_json_omits "active agent omits endpoint secret" "secret" after;
        check string "active realtime conversation mode" "realtime_bridge"
          Yojson.Safe.Util.(member "conversation_mode" after |> to_string);
        check string "active realtime session mode" "realtime_bridge"
          Yojson.Safe.Util.(
            member "active_session" after
            |> member "conversation_mode"
            |> to_string);
        check string "active realtime loop mode" "realtime_bridge"
          Yojson.Safe.Util.(
            member "active_session" after
            |> member "voice_loop"
            |> member "mode"
            |> to_string);
        end_session ()))
;;

let test_playback_timeout_parsers_and_budget () =
  check (option (float 0.001)) "afinfo duration line parses"
    (Some 236.6)
    (Voice_bridge_core.parse_afinfo_duration
       "File: x.mp3\nestimated duration: 236.600 sec\naudio bytes: 1\n");
  check (option (float 0.001)) "afinfo garbage is None" None
    (Voice_bridge_core.parse_afinfo_duration "no duration here");
  check (option (float 0.001)) "ffprobe bare seconds parses"
    (Some 61.25)
    (Voice_bridge_core.parse_ffprobe_duration "61.25\n");
  check (option (float 0.001)) "ffprobe N/A is None" None
    (Voice_bridge_core.parse_ffprobe_duration "N/A");
  check (float 0.001) "known duration gets margin"
    (100.0 +. Voice_bridge_core.playback_timeout_margin_sec)
    (Voice_bridge_core.playback_timeout_sec_for ~duration_sec:(Some 100.0));
  check (float 0.001) "unknown duration uses generous default"
    Voice_bridge_core.unknown_duration_playback_timeout_sec
    (Voice_bridge_core.playback_timeout_sec_for ~duration_sec:None)
;;

let write_local_playback_config () =
  let config_path = Voice_config.config_path () in
  mkdir_if_missing (Filename.dirname config_path);
  write_file config_path
    {|
{
  "tts": {
    "default_model": "test-tts",
    "default_voice": "test-voice",
    "default_voice_settings": {
      "stability": 0.5,
      "similarity_boost": 0.75,
      "style": 0.0
    },
    "agent_voices": {},
    "agent_voice_settings": {},
    "endpoints": [
      {
        "id": "test-tts",
        "kind": "elevenlabs_direct",
        "api_key_env": "ELEVENLABS_API_KEY",
        "enabled": true
      }
    ]
  },
  "stt": {
    "default_model": "test-stt",
    "endpoints": [
      {
        "id": "test-stt",
        "kind": "elevenlabs_direct",
        "api_key_env": "ELEVENLABS_API_KEY",
        "enabled": true
      }
    ]
  },
  "session": {
    "endpoints": []
  },
  "local_playback": {
    "enabled": true,
    "agents": []
  }
}
|}
;;

let test_playback_open_fallback_reports_handoff () =
  Eio_main.run
  @@ fun _env ->
  Eio.Switch.run
  @@ fun sw ->
  write_local_playback_config ();
  let bin_dir = Filename.concat voice_session_test_base "fake-playback-bin" in
  mkdir_if_missing bin_dir;
  let fake_afplay = Filename.concat bin_dir "afplay" in
  let fake_open = Filename.concat bin_dir "open" in
  write_file fake_afplay "#!/bin/sh\nexit 1\n";
  write_file fake_open "#!/bin/sh\nexit 0\n";
  Unix.chmod fake_afplay 0o755;
  Unix.chmod fake_open 0o755;
  let audio_file = Filename.concat voice_session_test_base "voice-open-fallback.mp3" in
  write_file audio_file "fake audio bytes";
  with_env "PATH" (Some bin_dir) (fun () ->
    match
      Voice_bridge_core.run_local_playback
        ~sw
        ~agent_id:"sangsu"
        ~message:"open fallback regression"
        ~audio_file
        ()
    with
    | `Opened _ -> ()
    | `Dedup_hit -> fail "expected open handoff, got dedup"
    | `Failed reason -> fail ("expected open handoff, got failed: " ^ reason)
    | `Played _ -> fail "expected open handoff, got played"
    | `Skipped reason -> fail ("expected open handoff, got skipped: " ^ reason))
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
        ; test_case "stt request openai compat" `Quick test_stt_request_openai_compat
        ; test_case "stt request mcp rejected" `Quick test_stt_request_mcp_rejected
        ] )
    ; ( "tts"
      , [ test_case
            "tts request elevenlabs accepts voice_id"
            `Quick
            test_tts_request_elevenlabs_accepts_voice_id
        ; test_case
            "tts request elevenlabs rejects blank voice"
            `Quick
            test_tts_request_elevenlabs_rejects_blank_voice
        ; test_case
            "tts request elevenlabs rejects unknown name"
            `Quick
            test_tts_request_elevenlabs_rejects_unknown_name
        ] )
    ; ( "keeper_voice_speak"
      , [ test_case
            "keeper_voice_speak surfaces TTS failure"
            `Quick
            test_keeper_voice_speak_surfaces_tts_failure
        ; test_case
            "failed speak writes no memory row"
            `Quick
            test_keeper_voice_speak_failure_writes_no_memory_row
        ; test_case
            "keeper_voice_speak fallback records memory"
            `Quick
            test_keeper_voice_speak_text_fallback_records_memory_bank_row
        ; test_case
            "voice_output row is excluded from memory recent notes"
            `Quick
            test_voice_output_row_is_excluded_from_memory_recent_notes
        ; test_case
            "session_start does not store session_name as voice"
            `Quick
            test_keeper_voice_session_start_does_not_store_session_name_as_voice
        ; test_case
            "realtime bridge endpoint validation"
            `Quick
            test_voice_realtime_bridge_endpoint_validation
        ; test_case
            "session_end reports ended without queue field"
            `Quick
            test_keeper_voice_session_end_reports_ended
        ; test_case
            "realtime session start requires bridge env"
            `Quick
            test_keeper_voice_session_start_realtime_requires_bridge_env
        ; test_case
            "voice_agent reports turn-based capability"
            `Quick
            test_keeper_voice_agent_reports_turn_based_capability
        ; test_case
            "voice_agent reports realtime bridge capability"
            `Quick
            test_keeper_voice_agent_reports_realtime_bridge_capability
        ] )
    ; ( "playback_timeout"
      , [ test_case
            "duration parsers and timeout budget"
            `Quick
            test_playback_timeout_parsers_and_budget
        ; test_case
            "open fallback reports handoff"
            `Quick
            test_playback_open_fallback_reports_handoff
        ] )
    ]
;;
