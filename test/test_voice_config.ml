open Alcotest

module Vc = Masc_mcp.Voice_config

let minimal_config_json ~session_endpoints =
  Printf.sprintf {|{
  "tts": {
    "default_model": "eleven_multilingual_v2",
    "default_voice": "Roger",
    "default_voice_settings": {},
    "endpoints": [
      { "id": "elevenlabs-roger", "kind": "elevenlabs_direct",
        "api_key_env": "ELEVENLABS_API_KEY", "enabled": true }
    ]
  },
  "stt": {
    "default_model": "scribe_v1",
    "endpoints": [
      { "id": "elevenlabs-stt", "kind": "elevenlabs_direct",
        "api_key_env": "ELEVENLABS_API_KEY", "enabled": true }
    ]
  },
  "session": {
    "endpoints": %s
  }
}|} session_endpoints

let parse json_str =
  let tmp = Filename.temp_file "test_voice_config" ".json" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove tmp with Sys_error _ -> ())
    (fun () ->
      let oc = open_out tmp in
      output_string oc json_str;
      close_out oc;
      (* Voice_config.load reads from config_path(), but we need to parse
         the JSON directly.  Use the internal parse chain via Yojson. *)
      let json = Yojson.Safe.from_string json_str in
      (* Replicate the load() pipeline without file I/O *)
      let open Result in
      let ( let* ) = bind in
      let* tts = Vc.parse_tts json in
      let* stt = Vc.parse_stt json in
      let* session = Vc.parse_session json in
      let* local_playback = Vc.parse_local_playback json in
      Ok { Vc.tts; stt; session; local_playback })

let test_session_empty_endpoints_ok () =
  let json = minimal_config_json ~session_endpoints:"[]" in
  match parse json with
  | Ok config ->
    check int "session endpoints empty" 0 (List.length config.session.endpoints)
  | Error err ->
    fail (Printf.sprintf "expected Ok, got Error: %s" err)

let test_session_with_endpoint_ok () =
  let session_ep =
    {|[{ "id": "voice-mcp", "kind": "voice_mcp",
         "mcp_url": "http://localhost:8936/mcp", "enabled": true }]|}
  in
  let json = minimal_config_json ~session_endpoints:session_ep in
  match parse json with
  | Ok config ->
    check int "session endpoints 1" 1 (List.length config.session.endpoints)
  | Error err ->
    fail (Printf.sprintf "expected Ok, got Error: %s" err)

let test_tts_endpoints_reachable_when_session_empty () =
  let json = minimal_config_json ~session_endpoints:"[]" in
  match parse json with
  | Ok config ->
    check int "tts endpoints available" 1
      (List.length config.tts.endpoints);
    let enabled =
      List.filter (fun (ep : Vc.endpoint) -> ep.enabled) config.tts.endpoints
    in
    check int "tts endpoints enabled" 1 (List.length enabled)
  | Error err ->
    fail (Printf.sprintf "expected Ok for tts check, got Error: %s" err)

let () =
  Alcotest.run "voice_config"
    [
      ( "session_endpoints",
        [
          test_case "empty session endpoints parses ok"
            `Quick test_session_empty_endpoints_ok;
          test_case "session with endpoint parses ok"
            `Quick test_session_with_endpoint_ok;
          test_case "tts reachable when session empty"
            `Quick test_tts_endpoints_reachable_when_session_empty;
        ] );
    ]
