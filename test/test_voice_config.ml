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
        (String_util.string_contains_substring ~needle:"invalid voice config json" msg)
    | Error Vc.Not_configured ->
      fail "expected Invalid, got Not_configured"
    | Ok _ -> fail "expected Invalid, got Ok")

let test_load_detailed_schema_error_is_invalid () =
  with_explicit_voice_config {|{"tts": {"default_model": "m"}}|} (fun () ->
    match Vc.load_detailed () with
    | Error (Vc.Invalid msg) ->
      check bool "schema error surfaced" true
        (String_util.string_contains_substring ~needle:"required" msg)
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

let test_load_error_to_string () =
  with_unconfigured_voice (fun () ->
    check bool "missing reported" true
      (Vc.load_error_to_string Vc.Not_configured
       |> String_util.string_contains_substring
            ~needle:"voice config missing at"));
  with_explicit_voice_config "{ this is not json" (fun () ->
    match Vc.load_detailed () with
    | Error (Vc.Invalid _ as error) ->
      check bool "json error surfaced" true
        (Vc.load_error_to_string error
         |> String_util.string_contains_substring
              ~needle:"invalid voice config json")
    | Error Vc.Not_configured -> fail "expected Invalid, got Not_configured"
    | Ok _ -> fail "expected Invalid, got Ok")

let test_session_empty_endpoints_ok () =
  let json = minimal_config_json ~session_endpoints:"[]" in
  match parse json with
  | Ok config ->
    check int "session endpoints empty" 0 (List.length config.session.endpoints)
  | Error err ->
    fail (Printf.sprintf "expected Ok, got Error: %s" err)

let test_unknown_endpoint_field_is_rejected () =
  let endpoints =
    {|[{"id":"session","kind":"voice_mcp","mcp_url":"http://localhost/mcp","max_retries":2}]|}
  in
  match parse (minimal_config_json ~session_endpoints:endpoints) with
  | Ok _ -> fail "expected unknown endpoint field to be rejected"
  | Error message ->
    check bool "unknown field is named" true
      (String_util.string_contains_substring
         ~needle:"session.endpoints[0].max_retries is not a supported field"
         message)

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

(* A voice id is provider vocabulary: an ElevenLabs voice_id is 20-64
   alphanumerics, an OpenAI voice is a name like "alloy". The fallback chain
   used to resolve the voice once and hand it to whichever endpoint it landed
   on, so the second endpoint was asked for a voice that does not exist there
   (#24068). Each endpoint now answers for its own. *)
let two_provider_config =
  {|{
  "tts": {
    "default_model": "eleven_multilingual_v2",
    "default_voice": "aEO01A4wXwd1O8GPgGlF",
    "default_voice_settings": {},
    "endpoints": [
      { "id": "eleven", "kind": "elevenlabs_direct",
        "api_key_env": "ELEVENLABS_API_KEY", "enabled": true },
      { "id": "openai", "kind": "openai_compat",
        "base_url": "https://api.openai.com/v1",
        "api_key_env": "OPENAI_API_KEY", "enabled": true,
        "default_voice": "alloy" }
    ]
  },
  "stt": {
    "default_model": "scribe_v1",
    "endpoints": [
      { "id": "eleven-stt", "kind": "elevenlabs_direct",
        "api_key_env": "ELEVENLABS_API_KEY", "enabled": true }
    ]
  },
  "session": { "endpoints": [] }
}|}
;;

let endpoint_named config id =
  match List.find_opt (fun (e : Vc.endpoint) -> String.equal e.id id) config.Vc.tts.endpoints with
  | Some endpoint -> endpoint
  | None -> failf "tts endpoint %S is missing from the parsed config" id
;;

let test_endpoint_voice_overrides_the_workspace_default () =
  match parse two_provider_config with
  | Error _ -> fail "the two-provider config must parse"
  | Ok config ->
    let eleven = endpoint_named config "eleven" in
    let openai = endpoint_named config "openai" in
    check (option string) "the eleven endpoint declares none" None eleven.Vc.default_voice;
    check (option string) "the openai endpoint declares its own" (Some "alloy")
      openai.Vc.default_voice;
    check string
      "an endpoint without one falls back to the workspace default"
      "aEO01A4wXwd1O8GPgGlF"
      (Vc.voice_for_agent_at_endpoint config eleven "some-agent");
    check string
      "an endpoint with one answers for itself"
      "alloy"
      (Vc.voice_for_agent_at_endpoint config openai "some-agent");
    (* The point of the fix: switching endpoints changes the voice asked for. *)
    check bool
      "the two endpoints do not share a voice"
      false
      (String.equal
         (Vc.voice_for_agent_at_endpoint config eleven "some-agent")
         (Vc.voice_for_agent_at_endpoint config openai "some-agent"))
;;

let test_endpoint_voice_is_absent_when_not_declared () =
  (* The shared fixture declares no per-endpoint voice, so every endpoint has
     to keep resolving to the workspace default -- the field is additive. *)
  match parse (minimal_config_json ~session_endpoints:"[]") with
  | Error _ -> fail "the base config must parse"
  | Ok config ->
    List.iter
      (fun (endpoint : Vc.endpoint) ->
        check (option string)
          (Printf.sprintf "%s declares no voice" endpoint.Vc.id)
          None
          endpoint.Vc.default_voice;
        check string
          (Printf.sprintf "%s resolves to the workspace default" endpoint.Vc.id)
          (Vc.voice_for_agent config "some-agent")
          (Vc.voice_for_agent_at_endpoint config endpoint "some-agent"))
      config.Vc.tts.endpoints
;;


(* The whitelist is the contract the live config is written against, and
   nothing compared the two. [runtime.toml [voice]] carried [max_retries] on
   both endpoint lists; the whitelist introduced 2026-08-28 does not accept
   it, so every voice read failed from that day until 2026-09-03. The only
   surface that reported it was GET /api/v1/voice/config, which returns 500
   and no turn calls.

   This pins the shape a working endpoint actually has. A field added to the
   live config without being added here fails at parse, which is where it
   should. *)
let test_a_live_shaped_endpoint_parses () =
  let endpoint id =
    `Assoc
      [ "id", `String id
      ; "kind", `String "elevenlabs_direct"
      ; "api_key_env", `String "ELEVENLABS_API_KEY"
      ; "enabled", `Bool true
      ; "timeout_seconds", `Float 35.0
      ]
  in
  let json =
    `Assoc
      [ ( "tts"
        , `Assoc
            [ "default_model", `String "eleven_multilingual_v2"
            ; "default_voice", `String "SAz9YHcvj6GT2YYXdXww"
            ; "endpoints", `List [ endpoint "elevenlabs-tts" ]
            ] )
      ; ( "stt"
        , `Assoc
            [ "default_model", `String "scribe_v2"
            ; "endpoints", `List [ endpoint "elevenlabs-stt" ]
            ] )
      ]
  in
  match Vc.parse_json json with
  | Ok config ->
    check int "one tts endpoint" 1 (List.length config.Vc.tts.Vc.endpoints);
    check int "one stt endpoint" 1 (List.length config.Vc.stt.Vc.endpoints)
  | Error message -> fail ("a live-shaped voice config must parse: " ^ message)
;;

(* The field that broke it. Rejection is correct -- no reader consumes a retry
   count, and the fallback is the endpoint chain rather than a repeat of one
   endpoint (a repeated TTS attempt risks speaking twice). What was missing is
   anything that notices, so this pins that the rejection names the field. *)
let test_an_unknown_endpoint_field_is_rejected_by_name () =
  let json =
    `Assoc
      [ ( "tts"
        , `Assoc
            [ "default_voice", `String "SAz9YHcvj6GT2YYXdXww"
            ; ( "endpoints"
              , `List
                  [ `Assoc
                      [ "id", `String "elevenlabs-tts"
                      ; "kind", `String "elevenlabs_direct"
                      ; "enabled", `Bool true
                      ; "max_retries", `Int 2
                      ]
                  ] )
            ] )
      ]
  in
  match Vc.parse_json json with
  | Ok _ -> fail "max_retries is not a supported endpoint field"
  | Error message ->
    check
      bool
      "the rejection names the field so an operator can find it"
      true
      (String_util.string_contains_substring ~needle:"max_retries" message)
;;


(* The capture section. It exists because every default in it was measured on
   one workstation, and two margins picked that way were both wrong before an
   operator could do anything about it. *)
let test_capture_defaults_when_the_section_is_absent () =
  match Vc.parse_json (`Assoc []) with
  | Error message -> fail ("an absent capture section must parse: " ^ message)
  | Ok config ->
    check
      bool
      "absent means the measured defaults"
      true
      (config.Vc.capture = Vc.default_capture)
;;

let test_capture_values_are_read () =
  let json =
    `Assoc
      [ ( "capture"
        , `Assoc
            [ "calibration_seconds", `Float 1.25
            ; "trigger_margin_db", `Float 9.0
            ; "trailing_silence_seconds", `Float 1.5
            ; "speech_margin_db", `Int 3
            ; "noise_reduction", `Bool true
            ] )
      ]
  in
  match Vc.parse_json json with
  | Error message -> fail message
  | Ok config ->
    let capture = config.Vc.capture in
    check (float 0.001) "calibration" 1.25 capture.Vc.calibration_seconds;
    check (float 0.001) "trigger" 9.0 capture.Vc.trigger_margin_db;
    check (float 0.001) "trailing silence" 1.5 capture.Vc.trailing_silence_seconds;
    (* An int where a float is meant is what an operator types. Rejecting it
       would fail the config over a decimal point. *)
    check (float 0.001) "speech, given as an int" 3.0 capture.Vc.speech_margin_db;
    check bool "noise reduction" true capture.Vc.noise_reduction
;;

(* A partial section keeps the defaults for what it does not say, so tuning one
   value does not silently reset the others. *)
let test_a_partial_capture_section_keeps_the_rest () =
  match Vc.parse_json (`Assoc [ "capture", `Assoc [ "trigger_margin_db", `Float 2.0 ] ]) with
  | Error message -> fail message
  | Ok config ->
    check (float 0.001) "the one given" 2.0 config.Vc.capture.Vc.trigger_margin_db;
    check
      (float 0.001)
      "the rest default"
      Vc.default_capture.Vc.speech_margin_db
      config.Vc.capture.Vc.speech_margin_db
;;

(* A probe of no length measures nothing, and the threshold would then come
   from an empty file rather than a room. *)
(* Zero would end the capture on the first gap between two words, which is
   most sentences.

   Built on the full fixture rather than a bare capture section: the parser
   requires tts before it reaches capture, so a partial document is refused
   for the wrong reason and the test would pass without proving anything. *)
let test_a_zero_trailing_silence_is_refused () =
  let json =
    Yojson.Safe.from_string (minimal_config_json ~session_endpoints:"[]")
  in
  let json =
    match json with
    | `Assoc fields ->
      `Assoc
        (fields @ [ "capture", `Assoc [ "trailing_silence_seconds", `Float 0.0 ] ])
    | other -> other
  in
  match Vc.parse_json json with
  | Ok _ -> fail "a zero trailing-silence window must be refused"
  | Error message ->
    check
      bool
      "the rejection names the field"
      true
      (String_util.string_contains_substring ~needle:"trailing_silence_seconds" message)
;;

let test_a_zero_calibration_is_refused () =
  match Vc.parse_json (`Assoc [ "capture", `Assoc [ "calibration_seconds", `Float 0.0 ] ]) with
  | Ok _ -> fail "a zero-length calibration probe must be refused"
  | Error message ->
    check
      bool
      "the rejection names the field"
      true
      (String_util.string_contains_substring ~needle:"calibration_seconds" message)
;;

let () =
  Alcotest.run "voice_config"
    [
      ( "capture",
        [
          test_case "defaults when the section is absent"
            `Quick test_capture_defaults_when_the_section_is_absent;
          test_case "values are read"
            `Quick test_capture_values_are_read;
          test_case "a zero trailing silence is refused."
            `Quick test_a_zero_trailing_silence_is_refused;
          test_case "a partial section keeps the rest"
            `Quick test_a_partial_capture_section_keeps_the_rest;
          test_case "a zero calibration is refused"
            `Quick test_a_zero_calibration_is_refused;
        ] );
      ( "live_shape",
        [
          test_case "a live-shaped endpoint parses"
            `Quick test_a_live_shaped_endpoint_parses;
          test_case "an unknown endpoint field is rejected by name"
            `Quick test_an_unknown_endpoint_field_is_rejected_by_name;
        ] );
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
          test_case "load errors render at operator boundary"
            `Quick test_load_error_to_string;
        ] );
      ( "session_endpoints",
        [
          test_case "empty session endpoints parses ok"
            `Quick test_session_empty_endpoints_ok;
          test_case "unknown endpoint field is rejected"
            `Quick test_unknown_endpoint_field_is_rejected;
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
      ( "per_endpoint_voice"
      , [ test_case
            "endpoint voice overrides the workspace default"
            `Quick
            test_endpoint_voice_overrides_the_workspace_default
        ; test_case
            "absent endpoint voice keeps the workspace default"
            `Quick
            test_endpoint_voice_is_absent_when_not_declared
        ] )
    ]
