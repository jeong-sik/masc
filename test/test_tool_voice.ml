(** Coverage tests for Tool_voice *)

open Alcotest

module Tool_voice = Masc_mcp.Tool_voice
module Voice_bridge = Masc_mcp.Voice_bridge
module Config = Masc_mcp.Config

let contains haystack needle =
  let text = String.lowercase_ascii haystack in
  let sub = String.lowercase_ascii needle in
  try
    ignore (Str.search_forward (Str.regexp_string sub) text 0);
    true
  with Not_found -> false

let temp_dir () =
  let dir = Filename.temp_file "masc_tool_voice" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then (
        Sys.readdir path |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path)
      else
        Sys.remove path
  in
  rm dir

let with_env key value f =
  let old = Sys.getenv_opt key in
  Unix.putenv key value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some prev -> Unix.putenv key prev
      | None -> Unix.putenv key "")
    f

let with_cwd path f =
  let old = Sys.getcwd () in
  Unix.chdir path;
  Fun.protect
    ~finally:(fun () -> Unix.chdir old)
    f

let with_temp_voice_config config_json f =
  let root = temp_dir () in
  let masc_dir = Filename.concat root ".masc" in
  Unix.mkdir masc_dir 0o755;
  let config_path = Filename.concat masc_dir "voice_config.json" in
  let oc = open_out config_path in
  output_string oc config_json;
  close_out oc;
  Fun.protect
    ~finally:(fun () -> cleanup_dir root)
    (fun () ->
      with_env "MASC_BASE_PATH" root (fun () -> with_env "ME_ROOT" root f))

let write_voice_config root config_json =
  let masc_dir = Filename.concat root ".masc" in
  if not (Sys.file_exists masc_dir) then Unix.mkdir masc_dir 0o755;
  let config_path = Filename.concat masc_dir "voice_config.json" in
  let oc = open_out config_path in
  output_string oc config_json;
  close_out oc

let with_ctx_no_net f =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let ctx : _ Tool_voice.context =
            {
              agent_name = "test-agent";
              sw;
              clock = Eio.Stdenv.clock env;
              net = None;
            }
          in
          f ctx))

let with_ctx_net f =
  Eio_main.run (fun env ->
      Eio.Switch.run (fun sw ->
          let ctx : _ Tool_voice.context =
            {
              agent_name = "test-agent";
              sw;
              clock = Eio.Stdenv.clock env;
              net = Some (Eio.Stdenv.net env);
            }
          in
          f ctx))

let dispatch_exn ctx ~name ~args =
  match Tool_voice.dispatch ctx ~name ~args with
  | Some result -> result
  | None -> failwith ("dispatch returned None for " ^ name)

let json_field name json =
  match Yojson.Safe.from_string json with
  | `Assoc fields -> List.assoc_opt name fields
  | _ -> None

let json_assoc_keys json =
  match json with
  | `Assoc fields -> List.map fst fields
  | _ -> []

let test_dispatch_unknown () =
  with_ctx_no_net (fun ctx ->
      check bool "unknown returns None" true
        (Tool_voice.dispatch ctx ~name:"unknown_tool" ~args:(`Assoc []) = None))

let test_dispatch_known_tools () =
  with_ctx_no_net (fun ctx ->
      let tools =
        [
          "masc_voice_speak";
          "masc_voice_session_start";
          "masc_voice_session_end";
          "masc_voice_sessions";
          "masc_voice_agent";
          "masc_voice_conference_start";
          "masc_voice_conference_end";
        ]
      in
      List.iter
        (fun name ->
          check bool (name ^ " dispatches") true
            (Tool_voice.dispatch ctx ~name ~args:(`Assoc []) <> None))
        tools)

let test_voice_agent_uses_configured_voice () =
  with_ctx_no_net (fun ctx ->
      let ok, body =
        dispatch_exn ctx ~name:"masc_voice_agent"
          ~args:(`Assoc [ ("agent_id", `String "claude") ])
      in
      check bool "ok" true ok;
      check (option string) "voice"
        (Some "Sarah")
        (match json_field "voice" body with Some (`String s) -> Some s | _ -> None))

let test_voice_agent_reads_nested_tuning_config () =
  let config_json =
    {|
{
  "tts": {
    "default_model": "eleven_multilingual_v2",
    "default_voice": "Sarah",
    "default_voice_settings": {
      "stability": 0.5,
      "similarity_boost": 0.75,
      "style": 0.0
    },
    "agent_voices": {
      "sangsu": "Roger"
    },
    "agent_voice_settings": {
      "sangsu": {
        "stability": 0.28,
        "similarity_boost": 0.82,
        "style": 0.45
      }
    },
    "endpoints": [
      {
        "id": "test-tts",
        "kind": "openai_compat",
        "base_url": "https://example.invalid/v1",
        "enabled": true
      }
    ]
  },
  "stt": {
    "default_model": "whisper-1",
    "endpoints": [
      {
        "id": "test-stt",
        "kind": "openai_compat",
        "base_url": "https://api.openai.com/v1",
        "enabled": true
      }
    ]
  },
  "session": {
    "endpoints": [
      {
        "id": "test-session",
        "kind": "voice_mcp",
        "base_url": "http://127.0.0.1:8936",
        "enabled": true
      }
    ]
  },
  "local_playback": {
    "enabled": true,
    "agents": ["sangsu"]
  }
}
|}
  in
  with_temp_voice_config config_json @@ fun () ->
      with_ctx_no_net @@ fun ctx ->
      let ok, body =
        dispatch_exn ctx ~name:"masc_voice_agent"
          ~args:(`Assoc [ ("agent_id", `String "sangsu") ])
      in
      check bool "ok" true ok;
      check (option string) "voice"
        (Some "Roger")
        (match json_field "voice" body with Some (`String s) -> Some s | _ -> None);
      let tuning = Masc_mcp.Voice_bridge.tuning_for_agent "sangsu" in
      check (float 0.001) "stability" 0.28 tuning.stability;
      check (float 0.001) "similarity_boost" 0.82 tuning.similarity_boost;
      check (float 0.001) "style" 0.45 tuning.style;
      check bool "local playback enabled" true
        (Masc_mcp.Voice_bridge.local_playback_enabled_for_agent "sangsu")

let test_voice_provider_alias_selects_adapter_endpoint () =
  let config_json =
    {|
{
  "tts": {
    "default_model": "eleven_multilingual_v2",
    "default_voice": "Sarah",
    "agent_voices": {
      "sangsu": "Roger"
    },
    "endpoints": [
      {
        "id": "elevenlabs-direct",
        "kind": "elevenlabs_direct",
        "base_url": "https://api.elevenlabs.io/v1",
        "api_key_env": "ELEVENLABS_API_KEY",
        "enabled": true
      },
      {
        "id": "railway-elevenlabs-proxy",
        "kind": "openai_compat",
        "base_url": "https://example.test/v1",
        "enabled": true
      }
    ]
  },
  "stt": {
    "default_model": "whisper-1",
    "endpoints": [
      {
        "id": "openai-stt",
        "kind": "openai_compat",
        "base_url": "https://api.openai.com/v1",
        "enabled": true
      }
    ]
  },
  "session": {
    "endpoints": [
      {
        "id": "local-session",
        "kind": "voice_mcp",
        "base_url": "http://127.0.0.1:8936",
        "enabled": true
      }
    ]
  }
}
|}
  in
  with_temp_voice_config config_json @@ fun () ->
      let endpoints = Masc_mcp.Voice_bridge.available_tts_endpoints ~provider:"elevenlabs" () in
      check int "one endpoint" 1 (List.length endpoints);
      let endpoint = List.hd endpoints in
      check string "selected direct endpoint" "elevenlabs-direct" endpoint.id

let test_voice_request_builder_follows_adapter_contract () =
  let config_json =
    {|
{
  "tts": {
    "default_model": "eleven_multilingual_v2",
    "default_voice": "Roger",
    "default_voice_settings": {
      "stability": 0.28,
      "similarity_boost": 0.82,
      "style": 0.45
    },
    "endpoints": [
      {
        "id": "elevenlabs-direct",
        "kind": "elevenlabs_direct",
        "base_url": "https://api.elevenlabs.io/v1/",
        "api_key_env": "ELEVENLABS_API_KEY",
        "enabled": true
      }
    ]
  },
  "stt": {
    "default_model": "whisper-1",
    "endpoints": [
      {
        "id": "openai-stt",
        "kind": "openai_compat",
        "base_url": "https://api.openai.com/v1",
        "enabled": true
      }
    ]
  },
  "session": {
    "endpoints": [
      {
        "id": "local-session",
        "kind": "voice_mcp",
        "base_url": "http://127.0.0.1:8936",
        "enabled": true
      }
    ]
  }
}
|}
  in
  with_temp_voice_config config_json @@ fun () ->
      let endpoint = List.hd (Masc_mcp.Voice_bridge.available_tts_endpoints ~provider:"elevenlabs" ()) in
      let tuning = Masc_mcp.Voice_bridge.tuning_for_agent "sangsu" in
      match
        Masc_mcp.Provider_adapter.voice_http_request_for_tts endpoint ~api_key:"secret"
          ~message:"hello" ~voice:"Roger" ~model:"eleven_multilingual_v2" ~tuning
      with
      | Error msg -> failf "request build failed: %s" msg
      | Ok request ->
          check bool "elevenlabs path" true
            (String.ends_with ~suffix:"/text-to-speech/CwhRBWXzGAHq8TQ4Fs17" request.url);
          check bool "has xi-api-key" true
            (List.mem ("xi-api-key", "secret") request.headers)

let test_voice_session_urls_follow_adapter_contract () =
  let config_json =
    {|
{
  "tts": {
    "default_model": "eleven_multilingual_v2",
    "default_voice": "Roger",
    "endpoints": [
      {
        "id": "elevenlabs-direct",
        "kind": "elevenlabs_direct",
        "base_url": "https://api.elevenlabs.io/v1",
        "enabled": true
      }
    ]
  },
  "stt": {
    "default_model": "whisper-1",
    "endpoints": [
      {
        "id": "openai-stt",
        "kind": "openai_compat",
        "base_url": "https://api.openai.com/v1",
        "enabled": true
      }
    ]
  },
  "session": {
    "endpoints": [
      {
        "id": "local-voice-mcp",
        "kind": "voice_mcp",
        "base_url": "https://voice.example/base",
        "enabled": true
      }
    ]
  }
}
|}
  in
  with_temp_voice_config config_json @@ fun () ->
      check string "mcp uri" "https://voice.example/base/mcp"
        (Uri.to_string (Masc_mcp.Voice_bridge.voice_mcp_uri ()));
      check string "health uri" "https://voice.example/base/health"
        (Uri.to_string (Masc_mcp.Voice_bridge.voice_health_uri ()))

let test_voice_session_urls_default_to_http_listener () =
  let config_json =
    {|
{
  "tts": {
    "default_model": "eleven_multilingual_v2",
    "default_voice": "Roger",
    "endpoints": [
      {
        "id": "elevenlabs-direct",
        "kind": "elevenlabs_direct",
        "base_url": "https://api.elevenlabs.io/v1",
        "enabled": true
      }
    ]
  },
  "stt": {
    "default_model": "whisper-1",
    "endpoints": [
      {
        "id": "openai-stt",
        "kind": "openai_compat",
        "base_url": "https://api.openai.com/v1",
        "enabled": true
      }
    ]
  },
  "session": {
    "endpoints": [
      {
        "id": "local-voice-mcp",
        "kind": "voice_mcp",
        "enabled": true
      }
    ]
  }
}
|}
  in
  with_temp_voice_config config_json @@ fun () ->
      with_env "MASC_HTTP_BASE_URL" "" (fun () ->
        with_env "MASC_HOST" "127.0.0.1" (fun () ->
          with_env "MASC_HTTP_PORT" "9315" (fun () ->
            with_env "VOICE_MCP_HOST" "" (fun () ->
              with_env "VOICE_MCP_PORT" "" (fun () ->
                check string "mcp uri defaults to HTTP listener"
                  "http://127.0.0.1:9315/mcp"
                  (Uri.to_string (Masc_mcp.Voice_bridge.voice_mcp_uri ()));
                check string "health uri defaults to HTTP listener"
                  "http://127.0.0.1:9315/health"
                  (Uri.to_string (Masc_mcp.Voice_bridge.voice_health_uri ())))))))

let test_voice_session_urls_prefer_http_base_url () =
  let config_json =
    {|
{
  "tts": {
    "default_model": "eleven_multilingual_v2",
    "default_voice": "Roger",
    "endpoints": [
      {
        "id": "elevenlabs-direct",
        "kind": "elevenlabs_direct",
        "base_url": "https://api.elevenlabs.io/v1",
        "enabled": true
      }
    ]
  },
  "stt": {
    "default_model": "whisper-1",
    "endpoints": [
      {
        "id": "openai-stt",
        "kind": "openai_compat",
        "base_url": "https://api.openai.com/v1",
        "enabled": true
      }
    ]
  },
  "session": {
    "endpoints": [
      {
        "id": "local-voice-mcp",
        "kind": "voice_mcp",
        "enabled": true
      }
    ]
  }
}
|}
  in
  with_temp_voice_config config_json @@ fun () ->
      with_env "MASC_HTTP_BASE_URL" "http://127.0.0.1:9415/" (fun () ->
        with_env "MASC_HOST" "127.0.0.1" (fun () ->
          with_env "MASC_HTTP_PORT" "9315" (fun () ->
            with_env "VOICE_MCP_HOST" "127.0.0.1" (fun () ->
              with_env "VOICE_MCP_PORT" "9444" (fun () ->
                check string "mcp uri prefers explicit HTTP base url"
                  "http://127.0.0.1:9415/mcp"
                  (Uri.to_string (Masc_mcp.Voice_bridge.voice_mcp_uri ()));
                check string "health uri prefers explicit HTTP base url"
                  "http://127.0.0.1:9415/health"
                  (Uri.to_string (Masc_mcp.Voice_bridge.voice_health_uri ())))))))

let test_voice_session_urls_use_legacy_voice_env_fallback () =
  let config_json =
    {|
{
  "tts": {
    "default_model": "eleven_multilingual_v2",
    "default_voice": "Roger",
    "endpoints": [
      {
        "id": "elevenlabs-direct",
        "kind": "elevenlabs_direct",
        "base_url": "https://api.elevenlabs.io/v1",
        "enabled": true
      }
    ]
  },
  "stt": {
    "default_model": "whisper-1",
    "endpoints": [
      {
        "id": "openai-stt",
        "kind": "openai_compat",
        "base_url": "https://api.openai.com/v1",
        "enabled": true
      }
    ]
  },
  "session": {
    "endpoints": [
      {
        "id": "local-voice-mcp",
        "kind": "voice_mcp",
        "enabled": true
      }
    ]
  }
}
|}
  in
  with_temp_voice_config config_json @@ fun () ->
      with_env "MASC_HTTP_BASE_URL" "" (fun () ->
        with_env "MASC_HOST" "" (fun () ->
          with_env "MASC_HTTP_PORT" "" (fun () ->
            with_env "VOICE_MCP_HOST" "127.0.0.1" (fun () ->
              with_env "VOICE_MCP_PORT" "9444" (fun () ->
                check string "mcp uri uses legacy voice env"
                  "http://127.0.0.1:9444/mcp"
                  (Uri.to_string (Masc_mcp.Voice_bridge.voice_mcp_uri ()));
                check string "health uri uses legacy voice env"
                  "http://127.0.0.1:9444/health"
                  (Uri.to_string (Masc_mcp.Voice_bridge.voice_health_uri ())))))))

let test_voice_speak_without_net_errors () =
  with_ctx_no_net (fun ctx ->
      let ok, body =
        dispatch_exn ctx ~name:"masc_voice_speak"
          ~args:
            (`Assoc
              [
                ("agent_id", `String "gemini");
                ("message", `String "hello from voice");
              ])
      in
      check bool "fails" false ok;
      check bool "mentions net" true (contains body "net"))

(* Voice tools now use local session manager — no network required.
   session_start, sessions, conference_end succeed without net. *)
let test_voice_session_start_without_net_errors () =
  with_ctx_no_net (fun ctx ->
      let ok, _body =
        dispatch_exn ctx ~name:"masc_voice_session_start"
          ~args:(`Assoc [ ("agent_id", `String "claude") ])
      in
      check bool "succeeds (local session)" true ok)

let test_voice_sessions_without_net_errors () =
  with_ctx_no_net (fun ctx ->
      let ok, _body =
        dispatch_exn ctx ~name:"masc_voice_sessions" ~args:(`Assoc [])
      in
      check bool "succeeds (local list)" true ok)

let test_voice_conference_end_without_net_errors () =
  with_ctx_no_net (fun ctx ->
      let ok, _body =
        dispatch_exn ctx ~name:"masc_voice_conference_end"
          ~args:(`Assoc [ ("agent_ids", `List [ `String "claude"; `String "gemini" ]) ])
      in
      check bool "succeeds (local conference)" true ok)

let test_voice_conference_end_with_unavailable_server_errors () =
  let config_json =
    {|
{
  "tts": {
    "default_model": "eleven_multilingual_v2",
    "default_voice": "Sarah",
    "agent_voices": {
      "claude": "Sarah",
      "gemini": "Roger"
    },
    "endpoints": [
      {
        "id": "test-tts",
        "kind": "openai_compat",
        "base_url": "http://127.0.0.1:1/v1",
        "enabled": true
      }
    ]
  },
  "stt": {
    "default_model": "whisper-1",
    "endpoints": [
      {
        "id": "test-stt",
        "kind": "openai_compat",
        "base_url": "https://api.openai.com/v1",
        "enabled": true
      }
    ]
  },
  "session": {
    "endpoints": [
      {
        "id": "test-session",
        "kind": "voice_mcp",
        "base_url": "http://127.0.0.1:1",
        "enabled": true
      }
    ]
  },
  "local_playback": {
    "enabled": true,
    "agents": ["sangsu"]
  }
}
|}
  in
  with_temp_voice_config config_json @@ fun () ->
      with_ctx_net @@ fun ctx ->
      let ok, body =
        dispatch_exn ctx ~name:"masc_voice_conference_end"
          ~args:(`Assoc [ ("agent_ids", `List [ `String "claude"; `String "gemini" ]) ])
      in
      check bool "succeeds (local session teardown, no server needed)" true ok;
      check bool "reports ended count" true (contains body "ended")

let test_voice_public_config_json () =
  let config_json =
    {|
{
  "tts": {
    "default_model": "eleven_multilingual_v2",
    "default_voice": "Sarah",
    "agent_voices": {
      "claude": "Sarah",
      "gemini": "Roger",
      "sangsu": "Josh"
    },
    "endpoints": [
      {
        "id": "railway-proxy",
        "kind": "openai_compat",
        "base_url": "https://example.test/v1",
        "enabled": true
      }
    ]
  },
  "stt": {
    "default_model": "whisper-1",
    "endpoints": [
      {
        "id": "openai-stt",
        "kind": "openai_compat",
        "base_url": "https://api.openai.com/v1",
        "enabled": true
      }
    ]
  },
  "session": {
    "endpoints": [
      {
        "id": "local-session",
        "kind": "voice_mcp",
        "base_url": "http://127.0.0.1:8936",
        "enabled": true
      }
    ]
  },
  "local_playback": {
    "enabled": true,
    "agents": ["sangsu"]
  }
}
|}
  in
  with_temp_voice_config config_json @@ fun () ->
  match Masc_mcp.Voice_bridge.public_config_json () with
  | Error json ->
      failf "expected Ok, got Error: %s" (Yojson.Safe.to_string json)
  | Ok json ->
      let open Yojson.Safe.Util in
      let tts_json = json |> member "tts" in
      let active_endpoint_json = tts_json |> member "active_endpoint" in
      check string "status" "ok" (json |> member "status" |> to_string);
      check bool "tts active endpoint configured" true
        (active_endpoint_json |> member "configured" |> to_bool);
      check bool "tts active endpoint enabled" true
        (active_endpoint_json |> member "enabled" |> to_bool);
      check bool "tts fallback configured false" false
        (active_endpoint_json |> member "fallback_configured" |> to_bool);
      check bool "local playback enabled" true
        (json |> member "local_playback" |> member "enabled" |> to_bool);
      check bool "local playback agent sangsu" true
        (json |> member "local_playback" |> member "agents" |> to_list
         |> List.exists (function `String "sangsu" -> true | _ -> false));
      check bool "includes sangsu voice" true
        (tts_json |> member "available_voices" |> to_list
         |> List.exists (function `String "Roger" -> true | _ -> false));
      check bool "agent voices hidden" true
        (not (List.mem "agent_voices" (json_assoc_keys tts_json)));
      check bool "endpoint id hidden" true
        (not (List.mem "id" (json_assoc_keys active_endpoint_json)));
      check bool "endpoint kind hidden" true
        (not (List.mem "kind" (json_assoc_keys active_endpoint_json)));
      check bool "endpoint url hidden" true
        (not (List.mem "endpoint_url" (json_assoc_keys active_endpoint_json)));
      check bool "local playback enabled surfaced" true
        (json |> member "local_playback" |> member "enabled" |> to_bool)

let touch_executable dir name =
  let path = Filename.concat dir name in
  let oc = open_out path in
  output_string oc "#!/bin/sh\nexit 0\n";
  close_out oc;
  Unix.chmod path 0o755;
  path

let test_local_playback_argv_prefers_ffplay () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let ffplay = touch_executable dir "ffplay" in
      ignore (touch_executable dir "mpg123");
      let argv =
        Voice_bridge.local_playback_argv ~path_value:dir
          ~audio_file:"/tmp/sample.mp3" ()
      in
      check (option (list string)) "ffplay selected first"
        (Some [ ffplay; "-nodisp"; "-autoexit"; "-loglevel"; "error"; "/tmp/sample.mp3" ])
        argv)

let test_local_playback_argv_falls_back_to_open () =
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () ->
      let open_cmd = touch_executable dir "open" in
      let argv =
        Voice_bridge.local_playback_argv ~path_value:dir
          ~audio_file:"/tmp/sample.mp3" ()
      in
      check (option (list string)) "open fallback selected"
        (Some [ open_cmd; "/tmp/sample.mp3" ])
        argv)

let voice_tools =
  [
    "masc_voice_speak";
    "masc_voice_session_start";
    "masc_voice_session_end";
    "masc_voice_sessions";
    "masc_voice_agent";
    "masc_voice_conference_start";
    "masc_voice_conference_end";
  ]

let test_voice_tools_are_registered () =
  (* Mode system removed. Just verify all voice tools are in the schema list. *)
  let all_names = Config.all_tool_names () in
  List.iter
    (fun name ->
      check bool (name ^ " is registered") true
        (List.mem name all_names))
    voice_tools

let test_error_message_contains_restart_guide () =
  with_ctx_no_net (fun ctx ->
      let _ok, body =
        dispatch_exn ctx ~name:"masc_voice_speak"
          ~args:
            (`Assoc
              [
                ("agent_id", `String "test");
                ("message", `String "hello");
              ])
      in
      check bool "contains Restart" true (contains body "Restart");
      check bool "contains --http" true (contains body "--http"))

let test_voice_tools_count () =
  (* Verify we have a known number of voice tools *)
  check bool "at least 6 voice tools" true (List.length voice_tools >= 6)

let test_voice_config_prefers_repo_root_over_me_root () =
  let repo_root = temp_dir () in
  let me_root = temp_dir () in
  let repo_json =
    {|
{
  "tts": {
    "default_model": "repo-model",
    "default_voice": "RepoVoice",
    "default_voice_settings": { "stability": 0.5, "similarity_boost": 0.75, "style": 0.0 },
    "agent_voices": {},
    "agent_voice_settings": {},
    "endpoints": [
      { "id": "repo-tts", "kind": "openai_compat", "base_url": "https://example.invalid/v1", "enabled": true }
    ]
  },
  "stt": {
    "default_model": "whisper-1",
    "endpoints": [
      { "id": "repo-stt", "kind": "openai_compat", "base_url": "https://api.openai.com/v1", "enabled": true }
    ]
  },
  "session": {
    "endpoints": [
      { "id": "repo-session", "kind": "voice_mcp", "base_url": "http://127.0.0.1:8936", "enabled": true }
    ]
  },
  "local_playback": { "enabled": false, "agents": [] }
}
|}
  in
  let global_json =
    {|
{
  "tts": {
    "default_model": "global-model",
    "default_voice": "GlobalVoice",
    "default_voice_settings": { "stability": 0.5, "similarity_boost": 0.75, "style": 0.0 },
    "agent_voices": {},
    "agent_voice_settings": {},
    "endpoints": [
      { "id": "global-tts", "kind": "openai_compat", "base_url": "https://example.invalid/v1", "enabled": true }
    ]
  },
  "stt": {
    "default_model": "whisper-1",
    "endpoints": [
      { "id": "global-stt", "kind": "openai_compat", "base_url": "https://api.openai.com/v1", "enabled": true }
    ]
  },
  "session": {
    "endpoints": [
      { "id": "global-session", "kind": "voice_mcp", "base_url": "http://127.0.0.1:8936", "enabled": true }
    ]
  },
  "local_playback": { "enabled": false, "agents": [] }
}
|}
  in
  Fun.protect
    ~finally:(fun () ->
      cleanup_dir repo_root;
      cleanup_dir me_root)
    (fun () ->
      Unix.mkdir (Filename.concat repo_root ".git") 0o755;
      write_voice_config repo_root repo_json;
      write_voice_config me_root global_json;
      let nested = Filename.concat repo_root "subdir" in
      Unix.mkdir nested 0o755;
      with_env "ME_ROOT" me_root (fun () ->
        with_cwd nested (fun () ->
          match Masc_mcp.Voice_config.load () with
          | Ok config ->
              check string "repo config wins" "RepoVoice"
                config.tts.default_voice;
              let expected_path = Filename.concat repo_root ".masc/voice_config.json" in
              let actual_path = Masc_mcp.Voice_config.config_path () in
              let expected_stat = Unix.stat expected_path in
              let actual_stat = Unix.stat actual_path in
              check int "resolved path inode matches repo config"
                expected_stat.st_ino actual_stat.st_ino;
              check int "resolved path device matches repo config"
                expected_stat.st_dev actual_stat.st_dev
          | Error e ->
              failf "expected repo voice config to load: %s" e)))

let test_voice_runtime_paths_prefer_masc_base_path () =
  let base_root = temp_dir () in
  let me_root = temp_dir () in
  let config_json =
    {|
{
  "tts": {
    "default_model": "base-model",
    "default_voice": "BaseVoice",
    "default_voice_settings": { "stability": 0.5, "similarity_boost": 0.75, "style": 0.0 },
    "agent_voices": {},
    "agent_voice_settings": {},
    "endpoints": [
      { "id": "base-tts", "kind": "openai_compat", "base_url": "https://example.invalid/v1", "enabled": true }
    ]
  },
  "stt": {
    "default_model": "whisper-1",
    "endpoints": [
      { "id": "base-stt", "kind": "openai_compat", "base_url": "https://api.openai.com/v1", "enabled": true }
    ]
  },
  "session": {
    "endpoints": [
      { "id": "base-session", "kind": "voice_mcp", "base_url": "http://127.0.0.1:8936", "enabled": true }
    ]
  },
  "local_playback": { "enabled": false, "agents": [] }
}
|}
  in
  Fun.protect
    ~finally:(fun () ->
      cleanup_dir base_root;
      cleanup_dir me_root)
    (fun () ->
      write_voice_config base_root config_json;
      with_env "MASC_BASE_PATH" base_root (fun () ->
        with_env "ME_ROOT" me_root (fun () ->
          let expected = Filename.concat base_root ".masc" in
          check string "voice bridge uses MASC_BASE_PATH" expected
            (Masc_mcp.Voice_bridge.masc_base_dir ());
          check string "keeper voice local uses MASC_BASE_PATH" expected
            (Masc_mcp.Keeper_voice_local.masc_base_dir ());
          check string "voice config path uses MASC_BASE_PATH"
            (Filename.concat expected "voice_config.json")
            (Masc_mcp.Voice_config.config_path ()))))

let () =
  run "Tool_voice"
    [
      ( "dispatch",
        [
          test_case "unknown" `Quick test_dispatch_unknown;
          test_case "known tools" `Quick test_dispatch_known_tools;
        ] );
      ( "registration",
        [
          test_case "voice tools are registered" `Quick
            test_voice_tools_are_registered;
          test_case "voice tools count" `Quick
            test_voice_tools_count;
          test_case "error message contains restart guide" `Quick
            test_error_message_contains_restart_guide;
        ] );
      ( "handlers",
        [
          test_case "voice agent" `Quick test_voice_agent_uses_configured_voice;
          test_case "voice agent reads nested config" `Quick
            test_voice_agent_reads_nested_tuning_config;
          test_case "voice provider alias selects adapter endpoint" `Quick
            test_voice_provider_alias_selects_adapter_endpoint;
          test_case "voice request builder follows adapter contract" `Quick
            test_voice_request_builder_follows_adapter_contract;
          test_case "voice session urls follow adapter contract" `Quick
            test_voice_session_urls_follow_adapter_contract;
          test_case "voice session urls default to HTTP listener" `Quick
            test_voice_session_urls_default_to_http_listener;
          test_case "voice session urls prefer HTTP base url" `Quick
            test_voice_session_urls_prefer_http_base_url;
          test_case "voice session urls use legacy voice env fallback" `Quick
            test_voice_session_urls_use_legacy_voice_env_fallback;
          test_case "speak without net errors" `Quick
            test_voice_speak_without_net_errors;
          test_case "session start no net" `Quick test_voice_session_start_without_net_errors;
          test_case "sessions no net errors" `Quick
            test_voice_sessions_without_net_errors;
          test_case "conference end no net errors" `Quick
            test_voice_conference_end_without_net_errors;
          test_case "conference end unavailable server errors" `Quick
            test_voice_conference_end_with_unavailable_server_errors;
          test_case "voice public config json" `Quick
            test_voice_public_config_json;
          test_case "voice config prefers repo root over me root" `Quick
            test_voice_config_prefers_repo_root_over_me_root;
          test_case "voice runtime paths prefer MASC_BASE_PATH" `Quick
            test_voice_runtime_paths_prefer_masc_base_path;
          test_case "local playback argv prefers ffplay" `Quick
            test_local_playback_argv_prefers_ffplay;
          test_case "local playback argv falls back to open" `Quick
            test_local_playback_argv_falls_back_to_open;
        ] );
    ]
