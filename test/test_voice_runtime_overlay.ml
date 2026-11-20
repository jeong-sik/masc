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

let voice_test_base =
  let path = Filename.temp_file "voice-runtime-overlay-" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let () =
  Unix.putenv "MASC_BASE_PATH" voice_test_base;
  at_exit (fun () -> rm_rf voice_test_base)
;;

let test_config () = Masc.Workspace.default_config voice_test_base

let allow_external_effect ~operation:_ ~input:_ ~call_summary:_ ~continue =
  continue ()

(* The stdlib has no unsetenv, and [Unix.putenv key ""] leaves the variable
   set to an empty string. The test dependency library carries a C stub for
   the real call. *)
external unsetenv : string -> unit = "masc_test_unsetenv"

let without_env key f =
  let prior = Sys.getenv_opt key in
  unsetenv key;
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> unsetenv key)
    f
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
  ; default_voice = None
  ; agent_voices = []
  ; command = None
  ; model = None
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
    ; default_voice = None
    ; agent_voices = []
    ; command = None
    ; model = None
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
    ; default_voice = None
    ; agent_voices = []
    ; command = None
    ; model = None
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
    ; default_voice = None
    ; agent_voices = []
    ; command = None
    ; model = None
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
      (* agent_name is omitted: the fixture derives the canonical
         keeper-<name>-agent form, which the parser requires. *)
      (`Assoc
          [ "name", `String name; "trace_id", `String "voice-queue-test" ])
  with
  | Ok meta -> meta
  | Error err -> fail ("make_keeper_meta: " ^ err)
;;

(* Regression for the 2026-06-10 voice repeat incident: the speak tool is
   synchronous, so with no TTS endpoint configured in the sandbox the call
   ends as status=error — never as a fire-and-forget "queued" pseudo-success
   the model would mistake for completed playback.

   Since #34449 the Gate allows a speak at once, so a review of a speak that
   no endpoint can carry approves nothing and the bridge then fails it as a
   runtime fault (tool matrix case 048, nightly 2026-09-08). No voice config
   is therefore refused before the Gate, as a missing dependency, with the
   model told to say it in text. *)
let test_keeper_voice_speak_refuses_before_the_gate_when_unconfigured () =
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
    let reviewed = ref false in
    let review_then_continue ~operation:_ ~input:_ ~call_summary:_ ~continue =
      reviewed := true;
      continue ()
    in
    let outcome =
      Masc.Keeper_tool_voice_runtime.handle_voice_tool_with_outcome
        ~config
        ~meta
        ~authorize_external_effect:review_then_continue
        ~name:"keeper_voice_speak"
        ~args:(`Assoc [ "message", `String "hello from sync voice test" ])
        ()
    in
    let json = Yojson.Safe.from_string outcome.Masc.Keeper_tool_execution.raw_output in
    check bool "the Gate was not asked" false !reviewed;
    check string "error status" "error"
      Yojson.Safe.Util.(member "status" json |> to_string);
    (match outcome.Masc.Keeper_tool_execution.disposition with
     | Tool_result.Failed Tool_result.Dependency_unavailable -> ()
     | Tool_result.Failed other ->
       fail
         ("an unconfigured voice refused as "
          ^ Tool_result.tool_failure_class_to_string other)
     | Tool_result.Completed () | Tool_result.Deferred () ->
       fail "an unconfigured voice did not refuse");
    check string "the model is told voice is not configured"
      Masc.Keeper_tool_voice_runtime.voice_not_configured_message
      Yojson.Safe.Util.(member "message" json |> to_string))
;;

(* An exemption decides whether the Gate reviews a speak, not whether voice
   exists. An exempt keeper with no config used to reach the bridge and get
   the runtime fault the refusal above replaces; it is refused the same way. *)
let test_keeper_voice_speak_exempt_keeper_is_refused_when_unconfigured () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock ~sw (fun () ->
    let config = test_config () in
    let meta =
      { (make_keeper_meta "voice-exempt-keeper") with
        Masc.Keeper_meta_contract.always_allow = Some true
      }
    in
    let reviewed = ref false in
    let review_then_continue ~operation:_ ~input:_ ~call_summary:_ ~continue =
      reviewed := true;
      continue ()
    in
    let outcome =
      Masc.Keeper_tool_voice_runtime.handle_voice_tool_with_outcome
        ~config
        ~meta
        ~authorize_external_effect:review_then_continue
        ~name:"keeper_voice_speak"
        ~args:(`Assoc [ "message", `String "hello from an exempt keeper" ])
        ()
    in
    check bool "the Gate was not asked" false !reviewed;
    match outcome.Masc.Keeper_tool_execution.disposition with
    | Tool_result.Failed Tool_result.Dependency_unavailable -> ()
    | Tool_result.Failed other ->
      fail
        ("an exempt keeper without voice refused as "
         ^ Tool_result.tool_failure_class_to_string other)
    | Tool_result.Completed () | Tool_result.Deferred () ->
      fail "an exempt keeper without voice did not refuse")
;;

(* The legacy memory bank is gone:
   a spoken or fallback utterance persists via the chat store only, and the
   speak response no longer reports a memory write. This pins the removal —
   if the memory_* response fields return, this fails. *)
let test_keeper_voice_speak_text_fallback_reports_no_memory_fields () =
  let config = test_config () in
  let meta = make_keeper_meta "voice-fallback-memory-keeper" in
  let message = "fallback speech is chat-store only" in
  let raw =
    Masc.Keeper_tool_voice_runtime.handle_voice_tool
      ~config
      ~meta
      ~authorize_external_effect:allow_external_effect
      ~name:"keeper_voice_speak"
      ~args:(`Assoc [ "message", `String message ])
      ()
  in
  let json = Yojson.Safe.from_string raw in
  check string "text fallback status" "text_fallback"
    Yojson.Safe.Util.(member "status" json |> to_string);
  check bool "no memory_recorded field" true
    Yojson.Safe.Util.(member "memory_recorded" json = `Null);
  check bool "no memory_rows_written field" true
    Yojson.Safe.Util.(member "memory_rows_written" json = `Null)
;;

let test_keeper_voice_agent_reports_turn_based_capability () =
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
    let agent =
      Masc.Keeper_tool_voice_runtime.handle_voice_tool
        ~config
        ~meta
        ~authorize_external_effect:allow_external_effect
        ~name:"keeper_voice_agent"
        ~args:(`Assoc [])
        ()
      |> Yojson.Safe.from_string
    in
    let loop = Yojson.Safe.Util.member "voice_loop" agent in
    check string "loop input route" "POST /api/v1/voice/transcribe"
      Yojson.Safe.Util.(
        member "operator_input" loop |> member "server_route" |> to_string);
    check string "loop output tool" "keeper_voice_speak"
      Yojson.Safe.Util.(member "keeper_output" loop |> member "tool" |> to_string);
    check string "loop output route" "GET /api/v1/voice/audio/<token>"
      Yojson.Safe.Util.(
        member "keeper_output" loop |> member "browser_route" |> to_string))
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

(* No-silent-fallback contract for voice config loading:
   - an explicit but broken config surfaces a typed load failure
     (never proceeds with a hardcoded model name);
   - no config at all means voice is explicitly disabled, reported
     through the pre-existing "no ... endpoint" terminals;
   - endpoint failover keeps every attempt observable. *)
let remove_voice_config_file () =
  let path = Voice_config.config_path () in
  if Sys.file_exists path then Sys.remove path
;;

let with_voice_config_file contents f =
  let path = Voice_config.config_path () in
  mkdir_if_missing (Filename.dirname path);
  write_file path contents;
  Fun.protect ~finally:remove_voice_config_file f
;;

let broken_config_json = "{ this is not json"

(* A speak under a voice config that exists and does not parse. The Gate is
   not asked: nothing can be played under that config, so a review would
   approve nothing and hide why. The tool answers with the loader's own
   sentence, naming the key that did not parse and the type it wanted, from
   the one read that decided the route.

   [Voice_config.load_detailed] reads the config root's [runtime.toml]
   [\[voice\]] section before the JSON file, and the root follows
   MASC_BASE_PATH only while MASC_CONFIG_DIR is unset; the variable is
   cleared so the config read is the one written here. *)
let test_keeper_voice_speak_under_an_invalid_config_is_refused_without_review () =
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let mono_clock = Eio.Stdenv.mono_clock env in
  Eio_context.with_test_env ~net ~clock ~mono_clock ~sw (fun () ->
    without_env "MASC_CONFIG_DIR" @@ fun () ->
    with_voice_config_file {|{ "capture": { "trigger_margin_db": "6" } }|} (fun () ->
      let config = test_config () in
      let meta = make_keeper_meta "voice-invalid-config-keeper" in
      let refuse_review ~operation ~input:_ ~call_summary:_ ~continue:_ =
        fail ("the Gate was asked to review " ^ operation)
      in
      let raw =
        Masc.Keeper_tool_voice_runtime.handle_voice_tool
          ~config
          ~meta
          ~authorize_external_effect:refuse_review
          ~name:"keeper_voice_speak"
          ~args:(`Assoc [ "message", `String "hello under a config that does not parse" ])
          ()
      in
      let json = Yojson.Safe.from_string raw in
      check string "error status" "error"
        Yojson.Safe.Util.(member "status" json |> to_string);
      let message = Yojson.Safe.Util.(member "message" json |> to_string) in
      check bool "the refusal names the key that did not parse" true
        (String_util.string_contains_substring
           ~needle:"capture.trigger_margin_db"
           message);
      check bool "and the type it wanted" true
        (String_util.string_contains_substring ~needle:"must be a number" message);
      (* Exactly the loader's sentence, with nothing in front of it. The
         bridge answers "voice config load failed: <sentence>", so an exact
         match also pins that the refusal came from the tool's one read and
         the bridge, with its second read, was not reached. *)
      let loaders_sentence =
        match Voice_config.load_detailed () with
        | Error (Voice_config.Invalid reason) -> reason
        | Error Voice_config.Not_configured -> fail "the fixture was not read"
        | Ok _ -> fail "the fixture must not load"
      in
      check string "the message is the loader's sentence, unprefixed" loaders_sentence
        message))
;;

(* Valid config whose TTS/STT endpoints all fail deterministically without
   network: the API key env var is unset in the test process. *)
let failover_config_json =
  {|
{
  "tts": {
    "default_model": "test-tts-model",
    "default_voice": "test-voice",
    "endpoints": [
      { "id": "tts-a", "kind": "elevenlabs_direct",
        "api_key_env": "MASC_VOICE_TEST_UNSET_KEY", "enabled": true },
      { "id": "tts-b", "kind": "elevenlabs_direct",
        "api_key_env": "MASC_VOICE_TEST_UNSET_KEY", "enabled": true }
    ]
  },
  "stt": {
    "default_model": "test-stt-model",
    "endpoints": [
      { "id": "stt-a", "kind": "elevenlabs_direct",
        "api_key_env": "MASC_VOICE_TEST_UNSET_KEY", "enabled": true },
      { "id": "stt-b", "kind": "elevenlabs_direct",
        "api_key_env": "MASC_VOICE_TEST_UNSET_KEY", "enabled": true }
    ]
  },
  "session": {
    "endpoints": []
  }
}
|}
;;

let test_transcribe_invalid_config_surfaces_load_failure () =
  with_voice_config_file broken_config_json (fun () ->
    match
      Masc.Voice_bridge.transcribe_audio ~audio_file:"/tmp/masc-voice-noaudio.wav" ()
    with
    | Ok _ -> fail "expected typed config failure, got Ok"
    | Error msg ->
      check
        bool
        "broken config surfaces load failure"
        true
        (String_util.contains_substring msg "voice config load failed");
      check
        bool
        "does not masquerade as unconfigured"
        false
        (String_util.contains_substring msg "no enabled STT endpoints configured");
      check
        bool
        "does not proceed with hardcoded scribe model"
        false
        (String_util.contains_substring msg "scribe"))
;;

let test_transcribe_unconfigured_is_explicitly_disabled () =
  remove_voice_config_file ();
  match
    Masc.Voice_bridge.transcribe_audio ~audio_file:"/tmp/masc-voice-noaudio.wav" ()
  with
  | Ok _ -> fail "expected explicit disabled error, got Ok"
  | Error msg ->
    check
      string
      "STT explicitly disabled when voice is not configured"
      "no enabled STT endpoints configured"
      msg
;;

let test_transcribe_endpoint_failover_surfaces_each_attempt () =
  with_voice_config_file failover_config_json (fun () ->
    with_env "MASC_VOICE_TEST_UNSET_KEY" None (fun () ->
      match
        Masc.Voice_bridge.transcribe_audio ~audio_file:"/tmp/masc-voice-noaudio.wav" ()
      with
      | Ok _ -> fail "expected aggregate endpoint failure, got Ok"
      | Error msg ->
        check
          bool
          "aggregate failure reported"
          true
          (String_util.contains_substring msg "all enabled STT endpoints failed");
        check
          bool
          "first endpoint attempt visible"
          true
          (String_util.contains_substring msg "stt-a:");
        check
          bool
          "second endpoint attempt visible"
          true
          (String_util.contains_substring msg "stt-b:")))
;;

(* Two whisper_cli endpoints whose commands are scripts, so no network or
   model is involved. Each command leaves a marker when it starts. *)
let stt_chain_fixture ~first ~second f =
  let dir = Filename.temp_file "stt-chain-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let script name body =
    let path = Filename.concat dir name in
    write_file path ("#!/bin/sh\n" ^ body);
    Unix.chmod path 0o700;
    path
  in
  let first_marker = Filename.concat dir "first-started" in
  let second_marker = Filename.concat dir "second-started" in
  let first_cmd =
    script "first.sh" (Printf.sprintf "printf started > %s\n%s\n" (Filename.quote first_marker) first)
  in
  let second_cmd =
    script "second.sh" (Printf.sprintf "printf started > %s\n%s\n" (Filename.quote second_marker) second)
  in
  let audio = Filename.concat dir "clip.wav" in
  write_file audio "RIFF\000\000\000\000WAVEfmt ";
  let config =
    Printf.sprintf
      {|{"stt":{"default_model":"fake.bin","endpoints":[
         {"id":"first","kind":"whisper_cli","command":"%s","model":"fake.bin","enabled":true},
         {"id":"second","kind":"whisper_cli","command":"%s","model":"fake.bin","enabled":true}]}}|}
      first_cmd second_cmd
  in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () ->
    without_env "MASC_CONFIG_DIR" @@ fun () ->
    with_voice_config_file config (fun () ->
      f ~audio ~first_marker ~second_marker ~first_cmd ~second_cmd))
;;

let test_stt_chain_fails_over_after_an_endpoint_error () =
  stt_chain_fixture ~first:"exit 3" ~second:"printf second-heard"
    (fun ~audio ~first_marker ~second_marker ~first_cmd:_ ~second_cmd:_ ->
      Eio_main.run @@ fun _env ->
      match Masc.Voice_bridge.transcribe_audio ~audio_file:audio () with
      | Error msg -> failf "the second endpoint must answer: %s" msg
      | Ok json ->
        check bool "the first endpoint ran" true (Sys.file_exists first_marker);
        check bool "the second endpoint ran" true (Sys.file_exists second_marker);
        check string "the second endpoint's transcript" "second-heard"
          (Option.value ~default:"" (Json_util.get_string json "text")))
;;

let prepare_stt_exn () =
  match Masc.Voice_bridge.prepare_transcription () with
  | Ok prepared -> prepared
  | Error error -> fail (Masc.Voice_bridge.transcription_error_to_string error)
;;

let transcribe_prepared_exn prepared ~audio =
  match Masc.Voice_bridge.transcribe_prepared prepared ~audio_file:audio () with
  | Ok transcript -> transcript
  | Error error -> fail (Masc.Voice_bridge.transcription_error_to_string error)
;;

let test_prepared_stt_keeps_its_configuration () =
  stt_chain_fixture
    ~first:{|printf 'first-%s' "$2"|}
    ~second:{|printf 'second-%s' "$2"|}
    (fun ~audio ~first_marker ~second_marker ~first_cmd ~second_cmd ->
      Eio_main.run @@ fun _env ->
      let first = prepare_stt_exn () in
      let first_identity = Masc.Voice_bridge.transcription_identity first in
      check string "same configuration has the same identity" first_identity
        (Masc.Voice_bridge.transcription_identity (prepare_stt_exn ()));
      let endpoint ~id ~command ~model =
        `Assoc [ "id", `String id; "kind", `String "whisper_cli"
               ; "command", `String command; "model", `String model
               ; "enabled", `Bool true ] in
      let set_endpoints endpoints =
        write_file (Voice_config.config_path ())
          (Yojson.Safe.to_string (`Assoc [ "stt", `Assoc [ "endpoints", `List endpoints ] ])) in
      let a = endpoint ~id:"first" ~command:first_cmd ~model:"fake.bin" in
      let b = endpoint ~id:"second" ~command:second_cmd ~model:"fake.bin" in
      List.iter (fun (label, endpoints) ->
        set_endpoints endpoints;
        check bool (label ^ " changes the reading identity") false
          (String.equal first_identity
             (Masc.Voice_bridge.transcription_identity (prepare_stt_exn ()))))
        [ "endpoint", [endpoint ~id:"renamed" ~command:first_cmd ~model:"fake.bin"; b]
        ; "model", [endpoint ~id:"first" ~command:first_cmd ~model:"changed.bin"; b]
        ; "command", [endpoint ~id:"first" ~command:second_cmd ~model:"fake.bin"; b]
        ; "order", [b; a]
        ];
      set_endpoints [endpoint ~id:"second" ~command:second_cmd ~model:"next.bin"; a];
      let next = prepare_stt_exn () in
      let heard_first = transcribe_prepared_exn first ~audio in
      check string "prepared A keeps its command and model" "first-fake.bin" heard_first.text;
      check string "prepared A keeps its endpoint" "first" heard_first.endpoint_id;
      check (option string) "command reported no language" None heard_first.language_code;
      check bool "only A started before its answer" true (Sys.file_exists first_marker);
      check bool "new configuration did not redirect A" false (Sys.file_exists second_marker);
      let heard_next = transcribe_prepared_exn next ~audio in
      check string "fresh B runs its command and model" "second-next.bin" heard_next.text;
      check string "fresh B uses its first endpoint" "second" heard_next.endpoint_id;
      check bool "B actually started" true (Sys.file_exists second_marker))
;;

let test_prepared_stt_preserves_empty_and_language_results () =
  stt_chain_fixture ~first:"exit 0" ~second:"printf must-not-run"
    (fun ~audio ~first_marker:_ ~second_marker ~first_cmd:_ ~second_cmd:_ ->
      Eio_main.run @@ fun _env ->
      let transcript = transcribe_prepared_exn (prepare_stt_exn ()) ~audio in
      check string "successful empty command output stays empty" "" transcript.text;
      check (option string) "no reported language remains absent" None transcript.language_code;
      let legacy ?language_code () =
        match Masc.Voice_bridge.transcribe_audio ~audio_file:audio ?language_code () with
        | Ok json -> json
        | Error message -> fail message in
      let json = legacy () in
      check (option string) "JSON keeps empty text" (Some "") (Json_util.get_string json "text");
      check (option string) "JSON names an unreported language" (Some "unknown")
        (Json_util.get_string json "language_code");
      check (option string) "explicit empty language is preserved" (Some "")
        (Json_util.get_string (legacy ~language_code:"" ()) "language_code");
      check bool "empty success does not try another endpoint" false (Sys.file_exists second_marker))
;;

let test_agent_speak_invalid_config_surfaces_load_failure () =
  with_voice_config_file broken_config_json (fun () ->
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    (match
       Masc.Voice_bridge.agent_speak
         ~sw
         ~clock
         ~net
         ~agent_id:"voice-config-test"
         ~message:"invalid config must surface"
         ()
     with
     | Ok _ -> fail "expected typed config failure, got Ok"
     | Error msg ->
       check
         bool
         "broken config surfaces load failure"
         true
         (String_util.contains_substring msg "voice config load failed");
       check
         bool
         "does not masquerade as unconfigured"
         false
         (String_util.contains_substring msg "no configured TTS endpoint");
       check
         bool
         "does not proceed with hardcoded elevenlabs model"
         false
         (String_util.contains_substring msg "eleven_multilingual")))
;;

let test_agent_speak_unconfigured_is_explicitly_disabled () =
  remove_voice_config_file ();
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  match
    Masc.Voice_bridge.agent_speak
      ~sw
      ~clock
      ~net
      ~agent_id:"voice-config-test"
      ~message:"unconfigured voice is explicitly disabled"
      ()
  with
  | Ok _ -> fail "expected explicit disabled error, got Ok"
  | Error msg ->
    check
      string
      "TTS explicitly disabled when voice is not configured"
      "no configured TTS endpoint"
      msg
;;

let test_agent_speak_endpoint_failover_surfaces_each_attempt () =
  with_voice_config_file failover_config_json (fun () ->
    with_env "MASC_VOICE_TEST_UNSET_KEY" None (fun () ->
      Eio_main.run
      @@ fun env ->
      Eio.Switch.run
      @@ fun sw ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.clock env in
      match
        Masc.Voice_bridge.agent_speak
          ~sw
          ~clock
          ~net
          ~agent_id:"voice-config-test"
          ~message:"failover attempts stay visible"
          ()
      with
      | Ok _ -> fail "expected aggregate endpoint failure, got Ok"
      | Error msg ->
        check
          bool
          "aggregate failure reported"
          true
          (String_util.contains_substring msg "all configured TTS endpoints failed");
        check
          bool
          "first endpoint attempt visible"
          true
          (String_util.contains_substring msg "tts-a:");
        check
          bool
          "second endpoint attempt visible"
          true
          (String_util.contains_substring msg "tts-b:")))
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
  let bin_dir = Filename.concat voice_test_base "fake-playback-bin" in
  mkdir_if_missing bin_dir;
  let fake_afplay = Filename.concat bin_dir "afplay" in
  let fake_open = Filename.concat bin_dir "open" in
  write_file fake_afplay "#!/bin/sh\nexit 1\n";
  write_file fake_open "#!/bin/sh\nexit 0\n";
  Unix.chmod fake_afplay 0o755;
  Unix.chmod fake_open 0o755;
  let audio_file = Filename.concat voice_test_base "voice-open-fallback.mp3" in
  write_file audio_file "fake audio bytes";
  with_env "PATH" (Some bin_dir) (fun () ->
    match
      Voice_bridge_core.run_local_playback
        ~sw
        ~agent_id:"alpha"
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
    ; ( "voice_config_state"
      , [ test_case
            "transcribe invalid config surfaces load failure"
            `Quick
            test_transcribe_invalid_config_surfaces_load_failure
        ; test_case
            "transcribe unconfigured is explicitly disabled"
            `Quick
            test_transcribe_unconfigured_is_explicitly_disabled
        ; test_case
            "transcribe failover surfaces each attempt"
            `Quick
            test_transcribe_endpoint_failover_surfaces_each_attempt
        ; test_case
            "STT chain fails over after an endpoint error"
            `Quick
            test_stt_chain_fails_over_after_an_endpoint_error
        ; test_case
            "prepared STT keeps its configuration"
            `Quick
            test_prepared_stt_keeps_its_configuration
        ; test_case
            "prepared STT preserves empty and language results"
            `Quick
            test_prepared_stt_preserves_empty_and_language_results
        ; test_case
            "agent_speak invalid config surfaces load failure"
            `Quick
            test_agent_speak_invalid_config_surfaces_load_failure
        ; test_case
            "agent_speak unconfigured is explicitly disabled"
            `Quick
            test_agent_speak_unconfigured_is_explicitly_disabled
        ; test_case
            "agent_speak failover surfaces each attempt"
            `Quick
            test_agent_speak_endpoint_failover_surfaces_each_attempt
        ] )
    ; ( "keeper_voice_speak"
      , [ test_case
            "keeper_voice_speak with no voice configured is refused before the Gate"
            `Quick
            test_keeper_voice_speak_refuses_before_the_gate_when_unconfigured
        ; test_case
            "an exempt keeper with no voice configured is refused before the Gate"
            `Quick
            test_keeper_voice_speak_exempt_keeper_is_refused_when_unconfigured
        ; test_case
            "keeper_voice_speak under an invalid config is refused without a Gate review"
            `Quick
            test_keeper_voice_speak_under_an_invalid_config_is_refused_without_review
        ; test_case
            "fallback speak reports no memory fields"
            `Quick
            test_keeper_voice_speak_text_fallback_reports_no_memory_fields
        ; test_case
            "voice_agent reports turn-based capability"
            `Quick
            test_keeper_voice_agent_reports_turn_based_capability
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
