(* The wizard decides which questions to ask and when enough has been answered.
   What matters most is the last test: a draft the wizard calls complete has to
   produce a file the loader actually reads. A wizard that finished on a draft
   the loader refuses would hand the operator a working-looking screen and a
   voice path that fails at the first speak. *)

let runtime_base =
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
|}

let with_config contents f =
  let home = Filename.temp_file "voice-wizard" "" in
  Unix.unlink home;
  Unix.mkdir home 0o700;
  let path = Filename.concat home "runtime.toml" in
  Out_channel.with_open_bin path (fun out -> output_string out contents);
  let rec cleanup target =
    match Unix.lstat target with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> cleanup (Filename.concat target name)) (Sys.readdir target);
      Unix.rmdir target
    | _ -> Unix.unlink target
  in
  Fun.protect ~finally:(fun () -> cleanup home) (fun () -> f path)

let read path = In_channel.with_open_bin path In_channel.input_all

let step_name : Voice_wizard.step -> string = function
  | Voice_wizard.Section -> "section"
  | Voice_wizard.Provider -> "provider"
  | Voice_wizard.Name -> "name"
  | Voice_wizard.Address -> "address"
  | Voice_wizard.Credential -> "credential"
  | Voice_wizard.Model -> "model"
  | Voice_wizard.Voice -> "voice"
  | Voice_wizard.Review -> "review"

let steps draft = List.map step_name (Voice_wizard.steps draft)

let gap_names draft =
  List.map
    (fun gap -> Voice_wizard.gap_message gap)
    (Voice_wizard.gaps draft)

(* Each side is offered exactly what can do its half, named rather than
   counted: a count stays green while the wrong provider sits in the list.

   An MCP tool and say both synthesize and have no transcribe path, so
   offering either for speech in would produce an endpoint every probe reports
   as not asked. whisper-cli is the mirror.

   say leads speech out because it is the only entry that needs nothing
   installed. *)
let provider_labels section =
  List.map Voice_wizard.provider_label (Voice_wizard.providers_for section)

let test_each_side_is_offered_what_can_do_its_half () =
  Alcotest.(check (list string))
    "speech out, the one that needs no download first"
    [ "macos_say"; "elevenlabs"; "openai_compatible"; "mcp_tool" ]
    (provider_labels Voice_setup.Tts);
  Alcotest.(check (list string))
    "speech in, and nothing in it only speaks"
    [ "whisper_cli"; "elevenlabs"; "openai_compatible" ]
    (provider_labels Voice_setup.Stt)

(* say is asked for a voice, not a model, so it is not asked for an address, a
   credential or a model either. Three questions and a review. *)
let test_say_is_asked_for_almost_nothing () =
  let draft =
    Voice_wizard.blank ~section:Voice_setup.Tts ~provider:Voice_wizard.Macos_say
  in
  Alcotest.(check (list string))
    "a name and a voice, and nothing that means nothing to a command"
    [ "section"; "provider"; "name"; "voice"; "review" ]
    (steps draft)

(* whisper-cli is asked for the model, because for it the model is the file it
   loads. Not for an address or a credential: nothing leaves the machine. *)
let test_whisper_is_asked_for_the_model_only () =
  let draft =
    Voice_wizard.blank ~section:Voice_setup.Stt ~provider:Voice_wizard.Whisper_cli
  in
  Alcotest.(check (list string))
    "a name and the model file"
    [ "section"; "provider"; "name"; "model"; "review" ]
    (steps draft)

(* Writing a blank model for say would write over a model that a sibling
   endpoint in the same section does need. *)
let test_say_writes_no_model () =
  let draft =
    { (Voice_wizard.blank ~section:Voice_setup.Tts ~provider:Voice_wizard.Macos_say) with
      Voice_wizard.endpoint_id = "macos-say"
    ; voice = "Yuna"
    }
  in
  match Voice_wizard.changes draft with
  | Error gaps ->
    Alcotest.failf "a complete say draft was refused: %s"
      (String.concat "; " (List.map Voice_wizard.gap_message gaps))
  | Ok changes ->
    Alcotest.(check bool) "no model change is written" false
      (List.exists
         (function
           | Voice_setup.Set_default_model _ -> true
           | Voice_setup.Put_endpoint _ | Voice_setup.Remove_endpoint _
           | Voice_setup.Set_tts_default_voice _ | Voice_setup.Set_agent_voice _ -> false)
         changes);
    Alcotest.(check bool) "the voice is written" true
      (List.exists
         (function
           | Voice_setup.Set_tts_default_voice voice -> voice = "Yuna"
           | Voice_setup.Put_endpoint _ | Voice_setup.Remove_endpoint _
           | Voice_setup.Set_default_model _ | Voice_setup.Set_agent_voice _ -> false)
         changes)

let test_the_questions_depend_on_the_provider () =
  Alcotest.(check (list string))
    "elevenlabs is not asked for an address, and speech out is asked for a voice"
    [ "section"; "provider"; "name"; "credential"; "model"; "voice"; "review" ]
    (steps (Voice_wizard.blank ~section:Voice_setup.Tts ~provider:Voice_wizard.Elevenlabs));
  Alcotest.(check (list string))
    "a local server is asked for an address"
    [ "section"; "provider"; "name"; "address"; "credential"; "model"; "review" ]
    (steps
       (Voice_wizard.blank ~section:Voice_setup.Stt ~provider:Voice_wizard.Openai_compatible));
  Alcotest.(check (list string))
    "a tool endpoint is not asked for a credential"
    [ "section"; "provider"; "name"; "address"; "voice"; "review" ]
    (steps (Voice_wizard.blank ~section:Voice_setup.Tts ~provider:Voice_wizard.Mcp_tool))

let test_elevenlabs_arrives_with_what_is_the_same_everywhere () =
  let draft =
    Voice_wizard.blank ~section:Voice_setup.Tts ~provider:Voice_wizard.Elevenlabs
  in
  Alcotest.(check string) "the address every workstation uses"
    Voice_config.default_elevenlabs_base_url draft.Voice_wizard.address;
  Alcotest.(check string) "and the variable every workstation names"
    "ELEVENLABS_API_KEY" draft.Voice_wizard.credential_variable;
  Alcotest.(check string) "nothing local is guessed" "" draft.Voice_wizard.endpoint_id

(* Leaving api_key_env out is what keeps the Authorization header off a local
   server that never asked for one, which is why that server answers 200. *)
let test_a_local_endpoint_may_go_without_a_credential () =
  let draft =
    { (Voice_wizard.blank ~section:Voice_setup.Stt
         ~provider:Voice_wizard.Openai_compatible)
      with
      Voice_wizard.endpoint_id = "whisper-local"
    ; Voice_wizard.address = "http://127.0.0.1:2022/v1"
    ; Voice_wizard.model = "scribe_v2"
    }
  in
  Alcotest.(check (list string)) "nothing is missing" [] (gap_names draft);
  match Voice_wizard.changes draft with
  | Error _ -> Alcotest.fail "a local endpoint without a credential is complete"
  | Ok _ -> ()

let test_elevenlabs_without_its_credential_is_incomplete () =
  let draft =
    { (Voice_wizard.blank ~section:Voice_setup.Tts ~provider:Voice_wizard.Elevenlabs)
      with
      Voice_wizard.endpoint_id = "elevenlabs-direct"
    ; Voice_wizard.model = "eleven_multilingual_v2"
    ; Voice_wizard.voice = "Sarah"
    ; Voice_wizard.credential_variable = "  "
    }
  in
  match Voice_wizard.changes draft with
  | Ok _ -> Alcotest.fail "elevenlabs cannot be reached without its key"
  | Error gaps ->
    Alcotest.(check bool) "the missing credential is what it names" true
      (List.mem Voice_wizard.Credential_variable_is_blank gaps)

let test_speech_out_needs_a_voice () =
  let draft =
    { (Voice_wizard.blank ~section:Voice_setup.Tts ~provider:Voice_wizard.Elevenlabs)
      with
      Voice_wizard.endpoint_id = "elevenlabs-direct"
    ; Voice_wizard.model = "eleven_multilingual_v2"
    }
  in
  match Voice_wizard.changes draft with
  | Ok _ -> Alcotest.fail "speech out with no voice is not complete"
  | Error gaps ->
    Alcotest.(check bool) "the voice is what it names" true
      (List.mem Voice_wizard.Voice_is_blank gaps)

let test_a_tool_endpoint_carries_its_url_as_mcp_url () =
  let draft =
    { (Voice_wizard.blank ~section:Voice_setup.Tts ~provider:Voice_wizard.Mcp_tool) with
      Voice_wizard.endpoint_id = "local-tool"
    ; Voice_wizard.address = "http://127.0.0.1:9000/mcp"
    ; Voice_wizard.model = "kokoro"
    ; Voice_wizard.voice = "af_heart"
    }
  in
  match Voice_wizard.changes draft with
  | Error _ -> Alcotest.fail "the draft is complete"
  | Ok changes ->
    let endpoint =
      List.find_map
        (function
          | Voice_setup.Put_endpoint (_, endpoint) -> Some endpoint
          | Voice_setup.Remove_endpoint _ | Voice_setup.Set_default_model _
          | Voice_setup.Set_tts_default_voice _ | Voice_setup.Set_agent_voice _ -> None)
        changes
    in
    (match endpoint with
     | None -> Alcotest.fail "the changes should carry an endpoint"
     | Some endpoint ->
       Alcotest.(check (option string)) "the address went to mcp_url"
         (Some "http://127.0.0.1:9000/mcp") endpoint.Voice_config.mcp_url;
       Alcotest.(check (option string)) "and not to base_url" None
         endpoint.Voice_config.base_url)

(* The one that matters. A draft the wizard calls complete has to produce a file
   the loader reads back -- including the section default_model, which a section
   that exists must name. *)
let test_a_complete_draft_writes_a_configuration_that_loads () =
  with_config runtime_base (fun path ->
    let draft =
      { (Voice_wizard.blank ~section:Voice_setup.Stt
           ~provider:Voice_wizard.Openai_compatible)
        with
        Voice_wizard.endpoint_id = "whisper-local"
      ; Voice_wizard.address = "http://127.0.0.1:2022/v1"
      ; Voice_wizard.model = "scribe_v2"
      }
    in
    let changes =
      match Voice_wizard.changes draft with
      | Ok changes -> changes
      | Error gaps ->
        Alcotest.failf "the draft should be complete: %s"
          (String.concat "; " (List.map Voice_wizard.gap_message gaps))
    in
    let revision =
      match Voice_setup.observe ~runtime_config_path:path with
      | Ok (revision, _) -> revision
      | Error error -> Alcotest.fail (Voice_setup.error_message error)
    in
    (match
       Voice_setup.apply ~runtime_config_path:path ~expected_revision:revision changes
     with
     | Ok () -> ()
     | Error error -> Alcotest.fail (Voice_setup.error_message error));
    match Voice_config.parse_runtime_toml_text (read path) with
    | Error message -> Alcotest.failf "the wizard wrote something that does not load: %s" message
    | Ok None -> Alcotest.fail "the section should exist after the wizard ran"
    | Ok (Some config) ->
      (match config.Voice_config.stt with
       | None -> Alcotest.fail "speech in should be configured"
       | Some stt ->
         Alcotest.(check string) "the model the wizard was given" "scribe_v2"
           stt.Voice_config.default_model;
         Alcotest.(check (list string)) "and the endpoint it was given"
           [ "whisper-local" ]
           (List.map
              (fun (endpoint : Voice_config.endpoint) -> endpoint.Voice_config.id)
              stt.Voice_config.endpoints)))

(* An MCP tool speaks and does not listen, so a draft carried to speech in has
   to give it up rather than sit on a provider its own offered list refuses. *)
let test_moving_to_speech_in_gives_up_a_provider_that_cannot_listen () =
  let draft =
    { (Voice_wizard.blank ~section:Voice_setup.Tts ~provider:Voice_wizard.Mcp_tool) with
      Voice_wizard.endpoint_id = "kept"
    }
  in
  let moved = Voice_wizard.with_section draft Voice_setup.Stt in
  Alcotest.(check bool) "the provider is one speech in can use" true
    (List.mem moved.Voice_wizard.provider (Voice_wizard.providers_for Voice_setup.Stt));
  Alcotest.(check string) "the name survives the move" "kept"
    moved.Voice_wizard.endpoint_id

let test_moving_keeps_a_provider_that_serves_both () =
  let draft =
    Voice_wizard.blank ~section:Voice_setup.Tts ~provider:Voice_wizard.Openai_compatible
  in
  let moved = Voice_wizard.with_section draft Voice_setup.Stt in
  Alcotest.(check bool) "still openai-compatible" true
    (moved.Voice_wizard.provider = Voice_wizard.Openai_compatible)

let test_mcp_writes_no_unused_model () =
  let draft =
    { (Voice_wizard.blank ~section:Voice_setup.Tts ~provider:Voice_wizard.Mcp_tool) with
      endpoint_id = "tool"; address = "http://fixture.invalid/mcp"; voice = "voice" }
  in
  match Voice_wizard.changes draft with
  | Error _ -> Alcotest.fail "MCP does not require a model"
  | Ok changes ->
    Alcotest.(check bool) "no unused model is written" false
      (List.exists
         (function Voice_setup.Set_default_model _ -> true | _ -> false)
         changes)

let () =
  Alcotest.run
    "voice_wizard"
    [ ( "which questions"
      , [ Alcotest.test_case "each side is offered what can do its half" `Quick
            test_each_side_is_offered_what_can_do_its_half
        ; Alcotest.test_case "say is asked for almost nothing" `Quick
            test_say_is_asked_for_almost_nothing
        ; Alcotest.test_case "whisper is asked for the model only" `Quick
            test_whisper_is_asked_for_the_model_only
        ; Alcotest.test_case "say writes no model" `Quick test_say_writes_no_model
        ; Alcotest.test_case "MCP writes no unused model" `Quick test_mcp_writes_no_unused_model
        ; Alcotest.test_case "the questions depend on the provider" `Quick
            test_the_questions_depend_on_the_provider
        ; Alcotest.test_case "elevenlabs arrives with what is the same everywhere" `Quick
            test_elevenlabs_arrives_with_what_is_the_same_everywhere
        ; Alcotest.test_case "moving to speech in gives up a provider that cannot listen" `Quick
            test_moving_to_speech_in_gives_up_a_provider_that_cannot_listen
        ; Alcotest.test_case "moving keeps a provider that serves both" `Quick
            test_moving_keeps_a_provider_that_serves_both
        ] )
    ; ( "when a draft is complete"
      , [ Alcotest.test_case "a local endpoint may go without a credential" `Quick
            test_a_local_endpoint_may_go_without_a_credential
        ; Alcotest.test_case "elevenlabs without its credential is incomplete" `Quick
            test_elevenlabs_without_its_credential_is_incomplete
        ; Alcotest.test_case "speech out needs a voice" `Quick test_speech_out_needs_a_voice
        ; Alcotest.test_case "a tool endpoint carries its url as mcp_url" `Quick
            test_a_tool_endpoint_carries_its_url_as_mcp_url
        ] )
    ; ( "what it writes"
      , [ Alcotest.test_case "a complete draft writes a configuration that loads" `Quick
            test_a_complete_draft_writes_a_configuration_that_loads
        ] )
    ]
