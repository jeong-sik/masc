open Alcotest

module Vc = Voice_config

let with_env key value f =
  let prior = Sys.getenv_opt key in
  (match value with
   | Some v -> Unix.putenv key v
   | None -> Unix.putenv key "");
  Fun.protect
    ~finally:(fun () ->
      match prior with
      | Some v -> Unix.putenv key v
      | None -> Unix.putenv key "")
    f

let with_temp_dir prefix f =
  let dir = Filename.temp_file prefix "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let rec rm_rf path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path
        |> Array.iter (fun name -> rm_rf (Filename.concat path name));
        Unix.rmdir path
      end else
        Sys.remove path
  in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

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

let test_config_path_survives_deleted_cwd_without_base () =
  with_temp_dir "voice-config-deleted-cwd-" @@ fun root ->
  let doomed = Filename.concat root "doomed" in
  Unix.mkdir doomed 0o755;
  let saved_cwd = Sys.getcwd () in
  with_env "MASC_BASE_PATH" None @@ fun () ->
  with_env "HOME" (Some root) @@ fun () ->
  Fun.protect
    ~finally:(fun () -> Sys.chdir saved_cwd)
    (fun () ->
       Sys.chdir doomed;
       Unix.rmdir doomed;
       let path = Vc.config_path () in
       check bool
         "deleted cwd still resolves a voice_config.json path"
         true
         (Filename.basename path = "voice_config.json"))

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
          test_case
            "config path survives deleted cwd without base"
            `Quick
            test_config_path_survives_deleted_cwd_without_base;
        ] );
    ]
