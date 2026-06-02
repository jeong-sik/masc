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
  let json = Yojson.Safe.from_string json_str in
  Vc.parse_json json

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

let test_session_invalid_endpoint_rejected () =
  let json = minimal_config_json ~session_endpoints:{|[{"bad": true}]|} in
  match parse json with
  | Ok _ -> fail "expected Error for invalid endpoint, got Ok"
  | Error _ -> ()

let test_tts_empty_endpoints_rejected () =
  let json_str = {|{
  "tts": {
    "default_model": "m", "default_voice": "v",
    "default_voice_settings": {},
    "endpoints": []
  },
  "stt": {
    "default_model": "s",
    "endpoints": [{ "id": "stt", "kind": "elevenlabs_direct", "enabled": true }]
  },
  "session": { "endpoints": [] }
}|} in
  match parse json_str with
  | Ok _ -> fail "expected Error for empty tts endpoints, got Ok"
  | Error _ -> ()

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
      ( "error_paths",
        [
          test_case "invalid session endpoint rejected"
            `Quick test_session_invalid_endpoint_rejected;
          test_case "empty tts endpoints still rejected"
            `Quick test_tts_empty_endpoints_rejected;
        ] );
    ]
