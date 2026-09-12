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


(* A present field of the wrong type is not an absent one. Read as absence,
   [{"api_key_env": 7}] removed the credential and answered success -- the one
   shape a client cannot tell apart from having been obeyed. *)
let test_a_wrongly_typed_optional_field_is_refused () =
  with_workspace (fun ~base_path ~path ->
    let before = read path in
    let attempt field value =
      let change =
        `Assoc
          [ "change", `String "put_endpoint"
          ; "section", `String "stt"
          ; "endpoint",
            `Assoc
              [ "id", `String "whisper-local"
              ; "kind", `String "openai_compat"
              ; "base_url", `String "http://127.0.0.1:2022/v1"
              ; field, value
              ]
          ]
      in
      Actions.apply ~base_path (request (revision ~base_path) [ change ])
    in
    let refused what result =
      match result with
      | Ok _ -> Alcotest.failf "%s of the wrong type must be refused" what
      | Error error ->
        Alcotest.(check bool) (what ^ " is named in the refusal") true
          (Astring.String.is_infix ~affix:what (Actions.error_message error))
    in
    refused "api_key_env" (attempt "api_key_env" (`Int 7));
    refused "enabled" (attempt "enabled" (`String "yes"));
    refused "timeout_seconds" (attempt "timeout_seconds" (`String "60"));
    Alcotest.(check string) "and nothing was written" before (read path))

(* null is absence spelled out, and the writer already reads a blank string as
   "nothing in this setting". Both stay. *)
let test_null_and_blank_still_clear_a_field () =
  with_workspace (fun ~base_path ~path ->
    let attempt value =
      let change =
        `Assoc
          [ "change", `String "put_endpoint"
          ; "section", `String "stt"
          ; "endpoint",
            `Assoc
              [ "id", `String "whisper-local"
              ; "kind", `String "openai_compat"
              ; "base_url", `String "http://127.0.0.1:2022/v1"
              ; "api_key_env", value
              ]
          ]
      in
      Actions.apply ~base_path (request (revision ~base_path) [ change ])
    in
    (match attempt `Null with
     | Ok _ -> ()
     | Error error -> Alcotest.fail (Actions.error_message error));
    (match attempt (`String "  ") with
     | Ok _ -> ()
     | Error error -> Alcotest.fail (Actions.error_message error));
    ignore (read path))

(* The comment said null and omission were different requests; the code read
   both as "clear it". A client that forgot the field deleted a mapping and was
   told it worked. *)
let test_a_missing_voice_does_not_clear_a_mapping () =
  with_workspace (fun ~base_path ~path ->
    let before = read path in
    let change = `Assoc [ "change", `String "set_agent_voice"; "agent", `String "alpha" ] in
    match Actions.apply ~base_path (request (revision ~base_path) [ change ]) with
    | Ok _ -> Alcotest.fail "a set_agent_voice with no voice field must be refused"
    | Error error ->
      Alcotest.(check bool) "the refusal says what is missing" true
        (Astring.String.is_infix ~affix:"voice" (Actions.error_message error));
      Alcotest.(check string) "and nothing was written" before (read path))

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
        ; Alcotest.test_case "a wrongly typed optional field" `Quick
            test_a_wrongly_typed_optional_field_is_refused
        ; Alcotest.test_case "a set_agent_voice with no voice field" `Quick
            test_a_missing_voice_does_not_clear_a_mapping
        ; Alcotest.test_case "null and blank still clear" `Quick
            test_null_and_blank_still_clear_a_field
        ] )
    ; ( "writing"
      , [ Alcotest.test_case "apply writes and answers with the new revision" `Quick
            test_apply_writes_and_answers_with_the_new_revision
        ; Alcotest.test_case "a stale revision is a conflict" `Quick
            test_a_stale_revision_is_a_conflict
        ; Alcotest.test_case "preview does not write" `Quick test_preview_does_not_write
        ] )
    ; ( "the wizard and the routes agree"
      , [ Alcotest.test_case "what the wizard sends is what the routes read" `Quick
            test_what_the_wizard_sends_is_what_the_routes_read
        ] )
    ]
