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

let rec mkdir_p path =
  if path <> "" && not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let write_file path contents =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents)

(** Point MASC_BASE_PATH at a fresh empty dir so no runtime.toml
    [voice] section and no voice_config.json exist. *)
let with_unconfigured_voice f =
  with_temp_dir "voice-config-load-" @@ fun root ->
  with_env "MASC_BASE_PATH" (Some root) @@ fun () ->
  with_env "MASC_BASE_PATH_INPUT" (Some root) @@ f

(** Like {!with_unconfigured_voice} but with [contents] written to the
    resolved voice_config.json path (an explicit configuration). *)
let with_explicit_voice_config contents f =
  with_unconfigured_voice (fun () ->
    let path = Vc.config_path () in
    mkdir_p (Filename.dirname path);
    write_file path contents;
    f ())

let test_load_detailed_not_configured () =
  with_unconfigured_voice (fun () ->
    match Vc.load_detailed () with
    | Error Vc.Not_configured -> ()
    | Error (Vc.Invalid msg) ->
      fail (Printf.sprintf "expected Not_configured, got Invalid: %s" msg)
    | Ok _ -> fail "expected Not_configured, got Ok")

let test_load_detailed_invalid_json () =
  with_explicit_voice_config "{ this is not json" (fun () ->
    match Vc.load_detailed () with
    | Error (Vc.Invalid msg) ->
      check bool "json syntax error surfaced" true
        (contains_substring ~needle:"invalid voice config json" msg)
    | Error Vc.Not_configured ->
      fail "expected Invalid, got Not_configured"
    | Ok _ -> fail "expected Invalid, got Ok")

let test_load_detailed_schema_error_is_invalid () =
  with_explicit_voice_config {|{"tts": {"default_model": "m"}}|} (fun () ->
    match Vc.load_detailed () with
    | Error (Vc.Invalid msg) ->
      check bool "schema error surfaced" true
        (contains_substring ~needle:"required" msg)
    | Error Vc.Not_configured ->
      fail "expected Invalid, got Not_configured"
    | Ok _ -> fail "expected Invalid, got Ok")

let test_load_detailed_valid_config () =
  with_explicit_voice_config (minimal_config_json ~session_endpoints:"[]")
    (fun () ->
      match Vc.load_detailed () with
      | Ok config ->
        check string "stt model from config" "scribe_v1"
          config.stt.default_model
      | Error Vc.Not_configured ->
        fail "expected Ok, got Not_configured"
      | Error (Vc.Invalid msg) ->
        fail (Printf.sprintf "expected Ok, got Invalid: %s" msg))

(* [load ()] keeps its legacy error strings on top of [load_detailed]:
   unconfigured reads as "missing", a broken explicit config surfaces
   the parse error instead of falling through to a default. *)
let test_load_legacy_strings_preserved () =
  with_unconfigured_voice (fun () ->
    match Vc.load () with
    | Error msg ->
      check bool "missing reported" true
        (contains_substring ~needle:"voice config missing at" msg)
    | Ok _ -> fail "expected missing-config Error, got Ok");
  with_explicit_voice_config "{ this is not json" (fun () ->
    match Vc.load () with
    | Error msg ->
      check bool "json error surfaced" true
        (contains_substring ~needle:"invalid voice config json" msg)
    | Ok _ -> fail "expected invalid-config Error, got Ok")

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
      ( "load_detailed",
        [
          test_case "unconfigured is Not_configured"
            `Quick test_load_detailed_not_configured;
          test_case "broken json is Invalid"
            `Quick test_load_detailed_invalid_json;
          test_case "schema error is Invalid"
            `Quick test_load_detailed_schema_error_is_invalid;
          test_case "valid config loads"
            `Quick test_load_detailed_valid_config;
          test_case "legacy load strings preserved"
            `Quick test_load_legacy_strings_preserved;
        ] );
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
