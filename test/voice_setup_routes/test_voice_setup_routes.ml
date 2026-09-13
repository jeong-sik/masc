(* The wire shape of voice setup. What these fix is that unknown input is
   refused by name rather than folded into a default: a request naming a kind
   this build does not have is a request for something that will not work, and
   answering it with a guess writes the guess to runtime.toml. *)

module Actions = Server_voice_setup_actions

let runtime_toml =
  {|[providers."deepseek"]
display-name = "Fixture HTTP (deepseek)"
protocol = "openai-compatible-http"
endpoint = "https://fixture.invalid/v1"
[providers."deepseek".credentials]
type = "inline"
value = "previous-fixture-key"
[models.chat]
api-name = "deepseek-v4-pro"
["deepseek".chat]
[runtime]
default = "deepseek.chat"

[voice.stt]
default_model = "scribe_v2"

[[voice.stt.endpoints]]
id = "whisper-local"
kind = "openai_compat"
base_url = "http://127.0.0.1:2022/v1"
enabled = true
timeout_seconds = 60.0
|}

let with_workspace f =
  let base = Filename.temp_file "voice-routes" "" in
  Unix.unlink base;
  Unix.mkdir base 0o700;
  let config_dir = Filename.concat (Filename.concat base ".masc") "config" in
  Unix.mkdir (Filename.concat base ".masc") 0o700;
  Unix.mkdir config_dir 0o700;
  let path = Filename.concat config_dir "runtime.toml" in
  Out_channel.with_open_bin path (fun out -> output_string out runtime_toml);
  let rec cleanup target =
    match Unix.lstat target with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> cleanup (Filename.concat target name)) (Sys.readdir target);
      Unix.rmdir target
    | _ -> Unix.unlink target
  in
  Fun.protect ~finally:(fun () -> cleanup base) (fun () -> f ~base_path:base ~path)

let read path = In_channel.with_open_bin path In_channel.input_all

let member name json =
  match json with
  | `Assoc fields -> Option.value (List.assoc_opt name fields) ~default:`Null
  | _ -> `Null

let string_member name json =
  match member name json with
  | `String value -> value
  | _ -> Alcotest.failf "expected a string at %S" name

let revision ~base_path =
  match Actions.observe ~base_path with
  | Ok json -> string_member "revision" json
  | Error error -> Alcotest.fail (Actions.error_message error)

let request revision changes =
  `Assoc [ "expected_revision", `String revision; "changes", `List changes ]

(* GET /api/v1/voice/config answers three booleans and no endpoint identity,
   because it is a public read. A wizard needs to show what is actually
   configured before changing it. *)
let test_observe_names_the_endpoints () =
  with_workspace (fun ~base_path ~path:_ ->
    match Actions.observe ~base_path with
    | Error error -> Alcotest.fail (Actions.error_message error)
    | Ok json ->
      let stt = member "stt" json in
      Alcotest.(check string) "the section model" "scribe_v2"
        (string_member "default_model" stt);
      (match member "endpoints" stt with
       | `List [ endpoint ] ->
         Alcotest.(check string) "the endpoint is named" "whisper-local"
           (string_member "id" endpoint);
         Alcotest.(check string) "its kind is spelled as the config spells it"
           "openai_compat" (string_member "kind" endpoint);
         Alcotest.(check string) "and its address is there"
           "http://127.0.0.1:2022/v1" (string_member "base_url" endpoint)
       | _ -> Alcotest.fail "expected exactly one stt endpoint"))

let test_an_unknown_kind_is_refused_by_name () =
  with_workspace (fun ~base_path ~path ->
    let before = read path in
    let change =
      `Assoc
        [ "change", `String "put_endpoint"
        ; "section", `String "stt"
        ; "endpoint",
          `Assoc [ "id", `String "new"; "kind", `String "grpc_stream" ]
        ]
    in
    match Actions.apply ~base_path (request (revision ~base_path) [ change ]) with
    | Ok _ -> Alcotest.fail "an endpoint kind this build does not have must be refused"
    | Error error ->
      let message = Actions.error_message error in
      Alcotest.(check bool) "the refusal quotes what was asked for" true
        (Astring.String.is_infix ~affix:"grpc_stream" message);
      Alcotest.(check string) "and nothing was written" before (read path))

let test_an_unknown_change_is_refused () =
  with_workspace (fun ~base_path ~path ->
    let before = read path in
    let change = `Assoc [ "change", `String "delete_everything" ] in
    match Actions.apply ~base_path (request (revision ~base_path) [ change ]) with
    | Ok _ -> Alcotest.fail "an unknown change must be refused"
    | Error _ -> Alcotest.(check string) "nothing was written" before (read path))

let test_an_unknown_section_is_refused () =
  with_workspace (fun ~base_path ~path ->
    let before = read path in
    let change =
      `Assoc
        [ "change", `String "set_default_model"
        ; "section", `String "session"
        ; "model", `String "x"
        ]
    in
    match Actions.apply ~base_path (request (revision ~base_path) [ change ]) with
    | Ok _ -> Alcotest.fail "a section this route does not serve must be refused"
    | Error _ -> Alcotest.(check string) "nothing was written" before (read path))

let test_apply_writes_and_answers_with_the_new_revision () =
  with_workspace (fun ~base_path ~path ->
    let before = revision ~base_path in
    let change =
      `Assoc
        [ "change", `String "put_endpoint"
        ; "section", `String "stt"
        ; "endpoint",
          `Assoc
            [ "id", `String "elevenlabs-stt"
            ; "kind", `String "elevenlabs_direct"
            ; "api_key_env", `String "ELEVENLABS_API_KEY"
            ]
        ]
    in
    match Actions.apply ~base_path (request before [ change ]) with
    | Error error -> Alcotest.fail (Actions.error_message error)
    | Ok answer ->
      let after = string_member "revision" answer in
      Alcotest.(check bool) "the revision moved" true (not (String.equal before after));
      (match Voice_config.parse_runtime_toml_text (read path) with
       | Ok (Some config) ->
         (match config.Voice_config.stt with
          | Some stt ->
            Alcotest.(check (list string)) "both endpoints are there"
              [ "whisper-local"; "elevenlabs-stt" ]
              (List.map
                 (fun (endpoint : Voice_config.endpoint) -> endpoint.Voice_config.id)
                 stt.Voice_config.endpoints)
          | None -> Alcotest.fail "speech in should still be configured")
       | Ok None -> Alcotest.fail "the section should exist"
       | Error message -> Alcotest.fail message))

(* A caller that read, thought, and then wrote is told its read went stale
   rather than quietly overwriting whoever wrote in between. *)
let test_a_stale_revision_is_a_conflict () =
  with_workspace (fun ~base_path ~path ->
    let stale = revision ~base_path in
    Out_channel.with_open_bin path (fun out ->
      output_string out (runtime_toml ^ "\n# another session was here\n"));
    let after_concurrent_write = read path in
    let change =
      `Assoc
        [ "change", `String "set_default_model"
        ; "section", `String "stt"
        ; "model", `String "whatever"
        ]
    in
    match Actions.apply ~base_path (request stale [ change ]) with
    | Ok _ -> Alcotest.fail "a stale revision must be refused"
    | Error error ->
      (match error with
       | Actions.Setup_failed Voice_setup.Configuration_changed -> ()
       | _ -> Alcotest.failf "expected a conflict, got: %s" (Actions.error_message error));
      Alcotest.(check string) "the concurrent write is preserved" after_concurrent_write
        (read path))

let test_preview_does_not_write () =
  with_workspace (fun ~base_path ~path ->
    let before = read path in
    let change =
      `Assoc
        [ "change", `String "set_default_model"
        ; "section", `String "stt"
        ; "model", `String "large-v3-turbo"
        ]
    in
    match Actions.preview ~base_path (request (revision ~base_path) [ change ]) with
    | Error error -> Alcotest.fail (Actions.error_message error)
    | Ok answer ->
      Alcotest.(check string) "the file on disk is unchanged" before (read path);
      Alcotest.(check bool) "the proposal carries the new value" true
        (Astring.String.is_infix ~affix:{|default_model = "large-v3-turbo"|}
           (string_member "runtime_toml" answer)))

(* The encoder and the decoder sit on opposite sides of one wire, in different
   libraries. A drift between them shows up only as a request the server
   refuses, which is a bad place to find it, so the two are held together here:
   what the wizard sends is what these routes read, and the endpoint that lands
   on disk is the one the draft described. *)
let test_what_the_wizard_sends_is_what_the_routes_read () =
  with_workspace (fun ~base_path ~path ->
    let draft =
      { (Voice_wizard.blank ~section:Voice_setup.Stt
           ~provider:Voice_wizard.Openai_compatible)
        with
        Voice_wizard.endpoint_id = "second-whisper"
      ; Voice_wizard.address = "http://127.0.0.1:9000/v1"
      ; Voice_wizard.model = "large-v3-turbo"
      }
    in
    let body =
      match Voice_wizard.save_request draft ~revision:(revision ~base_path) with
      | Ok body -> body
      | Error gaps ->
        Alcotest.failf "the draft should be complete: %s"
          (String.concat "; " (List.map Voice_wizard.gap_message gaps))
    in
    match Actions.apply ~base_path body with
    | Error error ->
      Alcotest.failf "the routes refused what the wizard produced: %s"
        (Actions.error_message error)
    | Ok _ ->
      (match Voice_config.parse_runtime_toml_text (read path) with
       | Error message -> Alcotest.fail message
       | Ok None -> Alcotest.fail "the section should exist"
       | Ok (Some config) ->
         (match config.Voice_config.stt with
          | None -> Alcotest.fail "speech in should be configured"
          | Some stt ->
            Alcotest.(check string) "the model the wizard was given"
              "large-v3-turbo" stt.Voice_config.default_model;
            let landed =
              List.find_opt
                (fun (endpoint : Voice_config.endpoint) ->
                  String.equal endpoint.Voice_config.id "second-whisper")
                stt.Voice_config.endpoints
            in
            (match landed with
             | None -> Alcotest.fail "the endpoint the wizard described is not there"
             | Some endpoint ->
               Alcotest.(check (option string)) "with the address it was given"
                 (Some "http://127.0.0.1:9000/v1") endpoint.Voice_config.base_url;
               (* A local endpoint the wizard was not given a credential for must
                  not acquire one: the header it would add is what a server that
                  never asked for it answers 401 to. *)
               Alcotest.(check (option string)) "and no credential it was not given"
                 None endpoint.Voice_config.api_key_env))))

(* [voice.tts] cannot be created a field at a time -- the section validates on
   commit and wants its model and default voice -- so every case that needs one
   sends them with whatever else it is testing, in a single transaction. *)
let tts_section_changes rest =
  [ `Assoc
      [ "change", `String "set_default_model"
      ; "section", `String "tts"
      ; "model", `String "eleven_v3"
      ]
  ; `Assoc [ "change", `String "set_tts_default_voice"; "voice", `String "cassidy" ]
  ; `Assoc
      [ "change", `String "put_endpoint"
      ; "section", `String "tts"
      ; "endpoint",
        `Assoc
          [ "id", `String "eleven"
          ; "kind", `String "elevenlabs_direct"
          ; "base_url", `String "https://fixture.invalid/v1"
          ]
      ]
  ]
  @ rest

(* A request that is refused must leave the file alone, which is what every
   case below checks alongside the refusal itself. *)
let refused ~what change =
  with_workspace (fun ~base_path ~path ->
    let before = read path in
    match Actions.apply ~base_path (request (revision ~base_path) [ change ]) with
    | Ok _ -> Alcotest.failf "%s must be refused" what
    | Error _ -> Alcotest.(check string) "nothing was written" before (read path))

(* The observation emits these two kinds, so refusing them here made the API
   unable to put back what it had just handed out. *)
let test_a_command_kind_round_trips () =
  with_workspace (fun ~base_path ~path ->
    let changes =
      tts_section_changes
        [ `Assoc
            [ "change", `String "put_endpoint"
            ; "section", `String "tts"
            ; "endpoint", `Assoc [ "id", `String "say"; "kind", `String "macos_say" ]
            ]
        ]
    in
    match Actions.apply ~base_path (request (revision ~base_path) changes) with
    | Error error -> Alcotest.fail (Actions.error_message error)
    | Ok _ ->
      Alcotest.(check bool) "the kind reached the file" true
        (Astring.String.is_infix ~affix:"macos_say" (read path));
      (match Actions.observe ~base_path with
       | Error error -> Alcotest.fail (Actions.error_message error)
       | Ok json ->
         let kinds =
           match member "endpoints" (member "tts" json) with
           | `List endpoints -> List.map (string_member "kind") endpoints
           | _ -> Alcotest.fail "tts endpoints must be a list"
         in
         Alcotest.(check bool) "and comes back out of the observation" true
           (List.mem "macos_say" kinds)))

(* say has no transcription at all, so installing it as an STT endpoint would
   report success over something that never runs. *)
let test_a_kind_that_cannot_serve_the_section_is_refused () =
  refused ~what:"a TTS-only kind in the STT section"
    (`Assoc
       [ "change", `String "put_endpoint"
       ; "section", `String "stt"
       ; "endpoint", `Assoc [ "id", `String "say"; "kind", `String "macos_say" ]
       ])

(* "false" is not false. Substituting the default committed the opposite of
   what the caller sent. *)
let test_a_mistyped_optional_field_is_refused () =
  refused ~what:"a string where a boolean belongs"
    (`Assoc
       [ "change", `String "put_endpoint"
       ; "section", `String "stt"
       ; "endpoint",
         `Assoc
           [ "id", `String "x"
           ; "kind", `String "openai_compat"
           ; "enabled", `String "false"
           ]
       ])

let test_a_mistyped_timeout_is_refused () =
  refused ~what:"a string where a number belongs"
    (`Assoc
       [ "change", `String "put_endpoint"
       ; "section", `String "stt"
       ; "endpoint",
         `Assoc
           [ "id", `String "x"
           ; "kind", `String "openai_compat"
           ; "timeout_seconds", `String "60"
           ]
       ])

(* The misspelling that matters is a credential one: the endpoint lands without
   the key and the call reports success. *)
let test_a_misspelled_endpoint_property_is_refused () =
  refused ~what:"an endpoint property this route does not read"
    (`Assoc
       [ "change", `String "put_endpoint"
       ; "section", `String "stt"
       ; "endpoint",
         `Assoc
           [ "id", `String "x"
           ; "kind", `String "openai_compat"
           ; "api_key_en", `String "MASC_KEY"
           ]
       ])

(* This one used to succeed and write voice.tts.agent_voices -- the opposite of
   the section the caller named. *)
let test_a_field_the_change_does_not_read_is_refused () =
  refused ~what:"set_agent_voice naming a section"
    (`Assoc
       [ "change", `String "set_agent_voice"
       ; "section", `String "stt"
       ; "agent", `String "voice-route-fixture"
       ; "voice", `String "aria"
       ])

(* Forgetting the field is not the same request as sending null, and folding
   them together turned a malformed payload into a deletion. *)
let test_set_agent_voice_without_a_voice_is_refused () =
  refused ~what:"set_agent_voice with no voice field"
    (`Assoc [ "change", `String "set_agent_voice"; "agent", `String "voice-route-fixture" ])

let test_an_explicit_null_voice_clears_the_mapping () =
  with_workspace (fun ~base_path ~path ->
    let set =
      tts_section_changes
        [ `Assoc
            [ "change", `String "set_agent_voice"
            ; "agent", `String "voice-route-fixture"
            ; "voice", `String "aria"
            ]
        ]
    in
    match Actions.apply ~base_path (request (revision ~base_path) set) with
    | Error error -> Alcotest.fail (Actions.error_message error)
    | Ok _ ->
      Alcotest.(check bool) "the mapping was written" true
        (Astring.String.is_infix ~affix:"aria" (read path));
      let clear =
        `Assoc
          [ "change", `String "set_agent_voice"
          ; "agent", `String "voice-route-fixture"
          ; "voice", `Null
          ]
      in
      (match Actions.apply ~base_path (request (revision ~base_path) [ clear ]) with
       | Error error -> Alcotest.fail (Actions.error_message error)
       | Ok _ ->
         Alcotest.(check bool) "and an explicit null took it away" false
           (Astring.String.is_infix ~affix:"aria" (read path))))

(* With this on, ending a capture sends the transcript straight away. A client
   that could not see it showed the default-off flow. *)
let test_the_observation_names_send_on_stop () =
  with_workspace (fun ~base_path ~path:_ ->
    match Actions.observe ~base_path with
    | Error error -> Alcotest.fail (Actions.error_message error)
    | Ok json ->
      (match member "send_on_stop" (member "stt" json) with
       | `Bool _ -> ()
       | other ->
         Alcotest.failf "stt.send_on_stop must be a boolean, got %s"
           (Yojson.Safe.to_string other)))

let test_the_observation_names_the_tts_tuning () =
  with_workspace (fun ~base_path ~path ->
    (* The fixture has no [voice.tts]; write one so the projection has a section
       to describe. *)
    match Actions.apply ~base_path (request (revision ~base_path) (tts_section_changes [])) with
    | Error error -> Alcotest.fail (Actions.error_message error)
    | Ok _ ->
      ignore (read path);
      (match Actions.observe ~base_path with
       | Error error -> Alcotest.fail (Actions.error_message error)
       | Ok json ->
         (match member "default_voice_settings" (member "tts" json) with
          | `Assoc fields ->
            List.iter
              (fun key ->
                Alcotest.(check bool) (Printf.sprintf "tuning names %s" key) true
                  (List.mem_assoc key fields))
              [ "stability"; "similarity_boost"; "style" ]
          | other ->
            Alcotest.failf "tts.default_voice_settings must be an object, got %s"
              (Yojson.Safe.to_string other));
         (match member "agent_voice_settings" (member "tts" json) with
          | `Assoc _ -> ()
          | other ->
            Alcotest.failf "tts.agent_voice_settings must be an object, got %s"
              (Yojson.Safe.to_string other))))

(* adapter_for_endpoint resolves the id before the kind, so an id that is an
   alias for another adapter reaches that transport while the API reports the
   declared one. *)
let test_an_id_that_contradicts_the_kind_is_refused () =
  refused ~what:"an id naming a different transport than the declared kind"
    (`Assoc
       [ "change", `String "put_endpoint"
       ; "section", `String "stt"
       ; "endpoint",
         `Assoc [ "id", `String "elevenlabs"; "kind", `String "openai_compat" ]
       ])

(* The fixture's own endpoint carries a timeout on an openai_compat kind, so the
   round trip has to keep accepting that pair. *)
let test_a_timeout_on_an_http_endpoint_is_accepted () =
  with_workspace (fun ~base_path ~path:_ ->
    let change =
      `Assoc
        [ "change", `String "put_endpoint"
        ; "section", `String "stt"
        ; "endpoint",
          `Assoc
            [ "id", `String "whisper-local"
            ; "kind", `String "openai_compat"
            ; "base_url", `String "http://127.0.0.1:2022/v1"
            ; "timeout_seconds", `Float 60.0
            ]
        ]
    in
    match Actions.apply ~base_path (request (revision ~base_path) [ change ]) with
    | Error error -> Alcotest.fail (Actions.error_message error)
    | Ok _ -> ())

let test_the_observation_names_the_session_section () =
  with_workspace (fun ~base_path ~path:_ ->
    match Actions.observe ~base_path with
    | Error error -> Alcotest.fail (Actions.error_message error)
    | Ok json ->
      (match member "session" json with
       | `Assoc fields ->
         Alcotest.(check bool) "the session section names its endpoints" true
           (List.mem_assoc "endpoints" fields)
       | other ->
         Alcotest.failf "session must be an object once voice is configured, got %s"
           (Yojson.Safe.to_string other)))

(* Which program a command kind runs is part of the endpoint, and the
   observation described it by a default it may have overridden. *)
let test_the_observation_names_a_command_override () =
  with_workspace (fun ~base_path ~path ->
    let before = read path in
    Out_channel.with_open_bin path (fun out ->
      output_string
        out
        (before
         ^ "\n[voice.tts]\ndefault_model = \"fixture-model\"\ndefault_voice = \"Fixture Voice\"\n\n[[voice.tts.endpoints]]\nid = \"say\"\nkind = \"macos_say\"\ncommand = \
            \"/opt/bin/say\"\n"));
    match Actions.observe ~base_path with
    | Error error -> Alcotest.fail (Actions.error_message error)
    | Ok json ->
      let commands =
        match member "endpoints" (member "tts" json) with
        | `List endpoints ->
          List.filter_map
            (fun endpoint ->
              match member "command" endpoint with
              | `String value -> Some value
              | _ -> None)
            endpoints
        | _ -> []
      in
      Alcotest.(check (list string)) "the configured override is observed"
        [ "/opt/bin/say" ] commands)

let endpoint_change extra =
  `Assoc
    [ "change", `String "put_endpoint"
    ; "section", `String "stt"
    ; "endpoint",
      (* base_url is required for this kind, so it is here rather than left out:
         without it the refusal would be attributable to the missing url and the
         case under test would prove nothing. *)
      `Assoc
        ([ "id", `String "x"
         ; "kind", `String "openai_compat"
         ; "base_url", `String "http://127.0.0.1:2022/v1"
         ]
         @ extra)
    ]

(* Zero is not a shorter timeout: Voice_bridge hands the value to Eio.Time.sleep,
   so the timeout branch wins immediately and every call fails. *)
let test_a_zero_timeout_is_refused () =
  refused ~what:"a zero timeout" (endpoint_change [ "timeout_seconds", `Float 0.0 ])

let test_a_negative_timeout_is_refused () =
  refused ~what:"a negative timeout" (endpoint_change [ "timeout_seconds", `Float (-1.0) ])

(* The readers take the first occurrence; a client or proxy that re-serializes
   may keep the last, so the commit could be the opposite of what was sent. *)
let test_a_repeated_field_is_refused () =
  refused ~what:"an object repeating a field"
    (`Assoc
       [ "change", `String "put_endpoint"
       ; "section", `String "stt"
       ; "endpoint",
         `Assoc
           [ "id", `String "x"
           ; "kind", `String "openai_compat"
           ; "base_url", `String "http://127.0.0.1:2022/v1"
           ; "enabled", `Bool false
           ; "enabled", `Bool true
           ]
       ])

(* select_endpoint trims a requested id before comparing, so an id stored with
   padding could never be selected again. *)
let test_a_padded_id_is_stored_trimmed () =
  with_workspace (fun ~base_path ~path ->
    let change =
      `Assoc
        [ "change", `String "put_endpoint"
        ; "section", `String "stt"
        ; "endpoint",
          `Assoc
            [ "id", `String "  padded  "
            ; "kind", `String "openai_compat"
            ; "base_url", `String "http://127.0.0.1:2022/v1"
            ]
        ]
    in
    match Actions.apply ~base_path (request (revision ~base_path) [ change ]) with
    | Error error -> Alcotest.fail (Actions.error_message error)
    | Ok _ ->
      Alcotest.(check bool) "the padding did not reach the file" false
        (Astring.String.is_infix ~affix:"\"  padded  \"" (read path));
      (match Actions.observe ~base_path with
       | Error error -> Alcotest.fail (Actions.error_message error)
       | Ok json ->
         let ids =
           match member "endpoints" (member "stt" json) with
           | `List endpoints -> List.map (string_member "id") endpoints
           | _ -> []
         in
         Alcotest.(check bool) "and the observation names the trimmed id" true
           (List.mem "padded" ids)))

(* Removal reads the same id the write stored. The removal path handed the raw
   value to the exact-match TOML editor while the write path trimmed, so a
   padded id matched no stanza and the response still said applied: the
   endpoint stayed and the caller was told it was gone.

   Two endpoints, because a section left with none does not load -- the parser
   requires [endpoints] to be an array and the edit is refused before it is
   written. That is its own question (#35729), and a removal proof does not
   need to answer it. *)
let test_a_padded_id_still_names_the_endpoint_to_remove () =
  with_workspace (fun ~base_path ~path ->
    let add =
      `Assoc
        [ "change", `String "put_endpoint"
        ; "section", `String "stt"
        ; "endpoint",
          `Assoc
            [ "id", `String "whisper-remote"
            ; "kind", `String "openai_compat"
            ; "base_url", `String "http://127.0.0.1:2023/v1"
            ]
        ]
    in
    (match Actions.apply ~base_path (request (revision ~base_path) [ add ]) with
     | Error error -> Alcotest.fail (Actions.error_message error)
     | Ok _ -> ());
    let remove =
      `Assoc
        [ "change", `String "remove_endpoint"
        ; "section", `String "stt"
        ; "id", `String "  whisper-local  "
        ]
    in
    match Actions.apply ~base_path (request (revision ~base_path) [ remove ]) with
    | Error error -> Alcotest.fail (Actions.error_message error)
    | Ok _ ->
      Alcotest.(check bool) "the stanza is gone from runtime.toml" false
        (Astring.String.is_infix ~affix:"whisper-local" (read path));
      (match Actions.observe ~base_path with
       | Error error -> Alcotest.fail (Actions.error_message error)
       | Ok json ->
         let ids =
           match member "endpoints" (member "stt" json) with
           | `List endpoints -> List.map (string_member "id") endpoints
           | _ -> []
         in
         Alcotest.(check (list string)) "and only the other one is left"
           [ "whisper-remote" ] ids))

(* Capture thresholds, the playback allowlist and the Gate's bypasses are in
   effect, so a response calling itself the full configuration has to carry
   them. *)
let test_the_observation_names_every_settings_section () =
  with_workspace (fun ~base_path ~path:_ ->
    match Actions.observe ~base_path with
    | Error error -> Alcotest.fail (Actions.error_message error)
    | Ok json ->
      List.iter
        (fun (section, keys) ->
          match member section json with
          | `Assoc fields ->
            List.iter
              (fun key ->
                Alcotest.(check bool)
                  (Printf.sprintf "%s names %s" section key) true
                  (List.mem_assoc key fields))
              keys
          | other ->
            Alcotest.failf "%s must be an object, got %s" section
              (Yojson.Safe.to_string other))
        [ "capture", [ "calibration_seconds"; "noise_reduction" ]
        ; "local_playback", [ "enabled"; "agents" ]
        ; "gate", [ "always_allow"; "exempt_agents" ]
        ])


(* The revision the route answers with has to be the one this write produced,
   not whatever a read after the commit happens to see. Taken from a second,
   unlocked read, it answered a failure for a write that landed, and under a
   concurrent writer it answered that writer's revision -- which the client
   would then send back as [expected_revision] without ever having observed
   what it described. The check a caller can make is the one that matters:
   editing again with it works. *)
let test_the_answered_revision_is_the_one_this_write_made () =
  with_workspace (fun ~base_path ~path ->
    let endpoint id =
      `Assoc
        [ "change", `String "put_endpoint"
        ; "section", `String "stt"
        ; "endpoint",
          `Assoc
            [ "id", `String id
            ; "kind", `String "elevenlabs_direct"
            ; "api_key_env", `String "ELEVENLABS_API_KEY"
            ]
        ]
    in
    let answered =
      match Actions.apply ~base_path (request (revision ~base_path) [ endpoint "first" ]) with
      | Error error -> Alcotest.fail (Actions.error_message error)
      | Ok answer -> string_member "revision" answer
    in
    Alcotest.(check string) "and it is what the file now carries" (revision ~base_path)
      answered;
    (* The wizard stays open and saves again with what it was handed. *)
    match Actions.apply ~base_path (request answered [ endpoint "second" ]) with
    | Error error ->
      Alcotest.failf "editing again with the answered revision was refused: %s"
        (Actions.error_message error)
    | Ok _ -> ignore (read path))

let () =
  Alcotest.run
    "voice_setup_routes"
    [ ( "reading"
      , [ Alcotest.test_case "observe names the endpoints" `Quick
            test_observe_names_the_endpoints
        ] )
    ; ( "unknown input is refused by name"
      , [ Alcotest.test_case "an unknown kind" `Quick test_an_unknown_kind_is_refused_by_name
        ; Alcotest.test_case "an unknown change" `Quick test_an_unknown_change_is_refused
        ; Alcotest.test_case "an unknown section" `Quick test_an_unknown_section_is_refused
        ] )
    ; ( "writing"
      , [ Alcotest.test_case "apply writes and answers with the new revision" `Quick
            test_apply_writes_and_answers_with_the_new_revision
        ; Alcotest.test_case "a stale revision is a conflict" `Quick
            test_a_stale_revision_is_a_conflict
        ; Alcotest.test_case "the answered revision is the one this write made" `Quick
            test_the_answered_revision_is_the_one_this_write_made
        ; Alcotest.test_case "preview does not write" `Quick test_preview_does_not_write
        ] )
    ; ( "a kind is taken or refused for what it can do"
      , [ Alcotest.test_case "a command kind round-trips" `Quick
            test_a_command_kind_round_trips
        ; Alcotest.test_case "a kind that cannot serve the section" `Quick
            test_a_kind_that_cannot_serve_the_section_is_refused
        ] )
    ; ( "a field is read as sent or not at all"
      , [ Alcotest.test_case "a mistyped boolean" `Quick
            test_a_mistyped_optional_field_is_refused
        ; Alcotest.test_case "a mistyped timeout" `Quick test_a_mistyped_timeout_is_refused
        ; Alcotest.test_case "a misspelled endpoint property" `Quick
            test_a_misspelled_endpoint_property_is_refused
        ; Alcotest.test_case "a field the change does not read" `Quick
            test_a_field_the_change_does_not_read_is_refused
        ] )
    ; ( "clearing a mapping is asked for explicitly"
      , [ Alcotest.test_case "no voice field at all" `Quick
            test_set_agent_voice_without_a_voice_is_refused
        ; Alcotest.test_case "an explicit null clears it" `Quick
            test_an_explicit_null_voice_clears_the_mapping
        ] )
    ; ( "the observation describes what is in effect"
      , [ Alcotest.test_case "send_on_stop" `Quick test_the_observation_names_send_on_stop
        ; Alcotest.test_case "the tts tuning" `Quick
            test_the_observation_names_the_tts_tuning
        ] )
    ; ( "the declared kind is what the runtime will use"
      , [ Alcotest.test_case "an id contradicting the kind" `Quick
            test_an_id_that_contradicts_the_kind_is_refused
        ; Alcotest.test_case "a timeout on an http endpoint stays accepted" `Quick
            test_a_timeout_on_an_http_endpoint_is_accepted
        ] )
    ; ( "the observation describes every section"
      , [ Alcotest.test_case "the session section" `Quick
            test_the_observation_names_the_session_section
        ; Alcotest.test_case "a command override" `Quick
            test_the_observation_names_a_command_override
        ] )
    ; ( "a value that cannot work is refused"
      , [ Alcotest.test_case "a zero timeout" `Quick test_a_zero_timeout_is_refused
        ; Alcotest.test_case "a negative timeout" `Quick
            test_a_negative_timeout_is_refused
        ; Alcotest.test_case "a repeated field" `Quick test_a_repeated_field_is_refused
        ; Alcotest.test_case "a padded id is stored trimmed" `Quick
            test_a_padded_id_is_stored_trimmed
        ; Alcotest.test_case "a padded id removes the endpoint it names" `Quick
            test_a_padded_id_still_names_the_endpoint_to_remove
        ] )
    ; ( "every settings section is described"
      , [ Alcotest.test_case "capture, playback and gate" `Quick
            test_the_observation_names_every_settings_section
        ] )
    ; ( "the wizard and the routes agree"
      , [ Alcotest.test_case "what the wizard sends is what the routes read" `Quick
            test_what_the_wizard_sends_is_what_the_routes_read
        ] )
    ]
