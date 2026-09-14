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

let offered section =
  List.map Voice_wizard.provider_label (Voice_wizard.providers_for section)

(* An MCP tool and say synthesize through something that has no transcribe
   path, and whisper-cli is the mirror. Offering either across the line would
   produce an endpoint every probe reports as not asked.

   The whole list is pinned rather than its length, so the order is pinned too:
   what a side offers first is what most people take. *)
let test_each_side_is_offered_what_can_do_its_half () =
  Alcotest.(check (list string)) "speech out, the command kind first"
    [ "macos_say"; "elevenlabs"; "openai_compatible"; "mcp_tool" ]
    (offered Voice_setup.Tts);
  Alcotest.(check (list string)) "speech in, the same"
    [ "whisper_cli"; "elevenlabs"; "openai_compatible" ]
    (offered Voice_setup.Stt)

(* Neither command is reached over the network, so neither is asked for an
   address or for the variable holding a key. say is asked for no model
   either: what it takes is a voice. *)
let test_a_command_is_asked_for_neither_an_address_nor_a_key () =
  Alcotest.(check (list string)) "say is asked for a name and a voice"
    [ "section"; "provider"; "name"; "voice"; "review" ]
    (steps (Voice_wizard.blank ~section:Voice_setup.Tts ~provider:Voice_wizard.Macos_say));
  Alcotest.(check (list string)) "whisper-cli is asked for the file it loads"
    [ "section"; "provider"; "name"; "model"; "review" ]
    (steps
       (Voice_wizard.blank ~section:Voice_setup.Stt ~provider:Voice_wizard.Whisper_cli))

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
    [ "section"; "provider"; "name"; "address"; "model"; "voice"; "review" ]
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
  match Voice_wizard.changes draft ~alongside:[] with
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
  match Voice_wizard.changes draft ~alongside:[] with
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
  match Voice_wizard.changes draft ~alongside:[] with
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
  match Voice_wizard.changes draft ~alongside:[] with
  | Error _ -> Alcotest.fail "the draft is complete"
  | Ok changes ->
    let endpoint =
      List.find_map
        (function
          | Voice_setup.Put_endpoint (_, endpoint) -> Some endpoint
          | Voice_setup.Remove_endpoint _ | Voice_setup.Set_default_model _
          | Voice_setup.Set_tts_default_voice _ | Voice_setup.Set_send_on_stop _
          | Voice_setup.Set_agent_voice _ -> None)
        changes
    in
    (match endpoint with
     | None -> Alcotest.fail "the changes should carry an endpoint"
     | Some endpoint ->
       Alcotest.(check (option string)) "the address went to mcp_url"
         (Some "http://127.0.0.1:9000/mcp") endpoint.Voice_config.mcp_url;
       Alcotest.(check (option string)) "and not to base_url" None
         endpoint.Voice_config.base_url)

(* say starts with nothing prefilled, unlike ElevenLabs, and needs nothing
   beyond a name and the voice speech out always asks for. An address or a key
   on it would be a field nothing reads. *)
let test_say_needs_only_a_name_and_a_voice () =
  let blank = Voice_wizard.blank ~section:Voice_setup.Tts ~provider:Voice_wizard.Macos_say in
  Alcotest.(check string) "no address is guessed" "" blank.Voice_wizard.address;
  Alcotest.(check string) "and no credential variable" ""
    blank.Voice_wizard.credential_variable;
  let draft =
    { blank with
      Voice_wizard.endpoint_id = "say-local"
    ; Voice_wizard.voice = "Yuna"
    }
  in
  Alcotest.(check (list string)) "nothing is missing" [] (gap_names draft)

(* whisper-cli loads a file. Without it there is nothing to transcribe with,
   and the refusal has to name the model rather than an address the command
   never reaches. *)
let test_whisper_cli_is_incomplete_without_the_model_file () =
  let draft =
    { (Voice_wizard.blank ~section:Voice_setup.Stt ~provider:Voice_wizard.Whisper_cli)
      with
      Voice_wizard.endpoint_id = "whisper-local"
    }
  in
  match Voice_wizard.changes draft ~alongside:[] with
  | Ok _ -> Alcotest.fail "whisper-cli has nothing to load without the model file"
  | Error gaps ->
    Alcotest.(check bool) "the model is what it names" true
      (List.mem Voice_wizard.Model_is_blank gaps);
    Alcotest.(check bool) "and not an address it never reaches" false
      (List.mem Voice_wizard.Address_is_blank gaps);
    Alcotest.(check bool) "nor a key nothing sends" false
      (List.mem Voice_wizard.Credential_variable_is_blank gaps)

(* Where the voice is written is not the wizard's choice to make freshly: a
   voice name is provider vocabulary, and the section default is read by every
   endpoint that declares none. Writing say's "Yuna" over a section an
   ElevenLabs endpoint falls back to hands that endpoint a voice it cannot
   resolve, and it fails at the first speak rather than at the save. *)
let voice_written draft ~alongside =
  match Voice_wizard.changes draft ~alongside with
  | Error gaps ->
    Alcotest.failf "the draft should be complete: %s"
      (String.concat "; " (List.map Voice_wizard.gap_message gaps))
  | Ok changes ->
    let section =
      List.find_map
        (function
          | Voice_setup.Set_tts_default_voice voice -> Some voice
          | Voice_setup.Put_endpoint _ | Voice_setup.Remove_endpoint _
          | Voice_setup.Set_default_model _ | Voice_setup.Set_send_on_stop _
          | Voice_setup.Set_agent_voice _ -> None)
        changes
    in
    let endpoint =
      List.find_map
        (function
          | Voice_setup.Put_endpoint (_, endpoint) ->
            Some endpoint.Voice_config.default_voice
          | Voice_setup.Remove_endpoint _ | Voice_setup.Set_default_model _
          | Voice_setup.Set_tts_default_voice _ | Voice_setup.Set_send_on_stop _
          | Voice_setup.Set_agent_voice _ -> None)
        changes
    in
    section, Option.join endpoint

(* Only what that provider is asked for: say takes no model, and ElevenLabs
   arrives with its address and credential variable already filled in. *)
let speaking ~provider ~voice =
  let draft =
    { (Voice_wizard.blank ~section:Voice_setup.Tts ~provider) with
      Voice_wizard.endpoint_id = "added"
    ; Voice_wizard.voice
    }
  in
  match provider with
  | Voice_wizard.Macos_say -> draft
  | Voice_wizard.Whisper_cli | Voice_wizard.Elevenlabs | Voice_wizard.Openai_compatible
  | Voice_wizard.Mcp_tool -> { draft with Voice_wizard.model = "a-model" }

let test_the_first_endpoint_owns_the_section_default () =
  let section, endpoint =
    voice_written (speaking ~provider:Voice_wizard.Macos_say ~voice:"Yuna") ~alongside:[]
  in
  Alcotest.(check (option string)) "the section default is this one's" (Some "Yuna")
    section;
  (* An endpoint voice outranks voice.tts.agent_voices, so one written where it
     is not needed makes every per-keeper voice inert. *)
  Alcotest.(check (option string)) "and the endpoint declares none" None endpoint

let test_another_kind_carries_its_own_voice () =
  let section, endpoint =
    voice_written
      (speaking ~provider:Voice_wizard.Elevenlabs ~voice:"SAz9YHcvj6GT2YYXdXww")
      ~alongside:[ Some Voice_config.Macos_say ]
  in
  Alcotest.(check (option string)) "the section default is left as say's" None section;
  Alcotest.(check (option string)) "and the id goes on the endpoint asking for it"
    (Some "SAz9YHcvj6GT2YYXdXww") endpoint

let test_one_more_of_the_same_kind_keeps_the_section_default () =
  let section, endpoint =
    voice_written
      (speaking ~provider:Voice_wizard.Elevenlabs ~voice:"SAz9YHcvj6GT2YYXdXww")
      ~alongside:[ Some Voice_config.Elevenlabs_direct ]
  in
  Alcotest.(check (option string)) "everything there reads this vocabulary"
    (Some "SAz9YHcvj6GT2YYXdXww") section;
  Alcotest.(check (option string)) "so per-keeper voices keep reaching the endpoint"
    None endpoint

let test_speech_in_writes_no_voice_at_all () =
  let draft =
    { (Voice_wizard.blank ~section:Voice_setup.Stt ~provider:Voice_wizard.Whisper_cli)
      with
      Voice_wizard.endpoint_id = "whisper-local"
    ; Voice_wizard.model = "/opt/models/ggml-large-v3.bin"
    }
  in
  let section, endpoint = voice_written draft ~alongside:[] in
  Alcotest.(check (option string)) "no section default" None section;
  Alcotest.(check (option string)) "and none on the endpoint" None endpoint

(* The one that matters. A draft the wizard calls complete has to produce a file
   the loader reads back, with the model on the endpoint it was given for. *)
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
      match Voice_wizard.changes draft ~alongside:[] with
      | Ok changes -> changes
      | Error gaps ->
        Alcotest.failf "the draft should be complete: %s"
          (String.concat "; " (List.map Voice_wizard.gap_message gaps))
    in
    let standalone_path = Filename.concat (Filename.dirname path) "voice_config.json" in
    let revision =
      match Voice_setup.observe ~runtime_config_path:path ~standalone_path with
      | Ok (revision, _) -> revision
      | Error error -> Alcotest.fail (Voice_setup.error_message error)
    in
    (match
       Voice_setup.apply ~runtime_config_path:path ~standalone_path
         ~expected_revision:revision changes
     with
     | Ok _revision -> ()
     | Error error -> Alcotest.fail (Voice_setup.error_message error));
    match Voice_config.parse_runtime_toml_text (read path) with
    | Error message -> Alcotest.failf "the wizard wrote something that does not load: %s" message
    | Ok None -> Alcotest.fail "the section should exist after the wizard ran"
    | Ok (Some config) ->
      (match config.Voice_config.stt with
       | None -> Alcotest.fail "speech in should be configured"
       | Some stt ->
         Alcotest.(check (list (option string))) "the model the wizard was given, on its endpoint"
           [ Some "scribe_v2" ]
           (List.map
              (fun (endpoint : Voice_config.endpoint) -> endpoint.Voice_config.model)
              stt.Voice_config.endpoints);
         Alcotest.(check (option string)) "and not as the section's fallback" None
           stt.Voice_config.default_model;
         Alcotest.(check (list string)) "and the endpoint it was given"
           [ "whisper-local" ]
           (List.map
              (fun (endpoint : Voice_config.endpoint) -> endpoint.Voice_config.id)
              stt.Voice_config.endpoints)))

(* The loader refuses an address on a command kind, so a draft that carried one
   would write a file the next start cannot read back. This is the half the
   step list cannot prove: the questions can be right while the endpoint still
   goes out with a base_url nobody asked for. *)
let test_a_command_endpoint_is_written_with_nothing_to_reach () =
  with_config runtime_base (fun path ->
    let draft =
      { (Voice_wizard.blank ~section:Voice_setup.Stt ~provider:Voice_wizard.Whisper_cli)
        with
        Voice_wizard.endpoint_id = "whisper-local"
      ; Voice_wizard.model = "/opt/models/ggml-large-v3.bin"
      }
    in
    let changes =
      match Voice_wizard.changes draft ~alongside:[] with
      | Ok changes -> changes
      | Error gaps ->
        Alcotest.failf "the draft should be complete: %s"
          (String.concat "; " (List.map Voice_wizard.gap_message gaps))
    in
    let standalone_path = Filename.concat (Filename.dirname path) "voice_config.json" in
    let revision =
      match Voice_setup.observe ~runtime_config_path:path ~standalone_path with
      | Ok (revision, _) -> revision
      | Error error -> Alcotest.fail (Voice_setup.error_message error)
    in
    (match
       Voice_setup.apply ~runtime_config_path:path ~standalone_path
         ~expected_revision:revision changes
     with
     | Ok _revision -> ()
     | Error error -> Alcotest.fail (Voice_setup.error_message error));
    match Voice_config.parse_runtime_toml_text (read path) with
    | Error message ->
      Alcotest.failf "the wizard wrote something that does not load: %s" message
    | Ok None -> Alcotest.fail "the section should exist after the wizard ran"
    | Ok (Some config) ->
      (match config.Voice_config.stt with
       | None -> Alcotest.fail "speech in should be configured"
       | Some stt ->
         (match stt.Voice_config.endpoints with
          | [ endpoint ] ->
            Alcotest.(check bool) "the kind that runs a command" true
              (endpoint.Voice_config.kind = Voice_config.Whisper_cli);
            Alcotest.(check (option string)) "the file it loads, on the endpoint"
              (Some "/opt/models/ggml-large-v3.bin") endpoint.Voice_config.model;
            Alcotest.(check (option string)) "no address" None
              endpoint.Voice_config.base_url;
            Alcotest.(check (option string)) "no tool url" None
              endpoint.Voice_config.mcp_url;
            Alcotest.(check (option string)) "no key to send" None
              endpoint.Voice_config.api_key_env;
            Alcotest.(check (option string)) "and the name it is installed under" None
              endpoint.Voice_config.command
          | endpoints ->
            Alcotest.failf "one endpoint was written, found %d" (List.length endpoints))))

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

(* Toggling the side on the first step is how most drafts start, and each
   command kind serves one side only. Landing on the other side's command
   rather than on a provider that needs an account is what keeps the toggle
   cheap. *)
let test_moving_lands_on_the_command_the_other_side_runs () =
  let heard =
    Voice_wizard.blank ~section:Voice_setup.Stt ~provider:Voice_wizard.Whisper_cli
  in
  Alcotest.(check bool) "speech in's command becomes speech out's" true
    ((Voice_wizard.with_section heard Voice_setup.Tts).Voice_wizard.provider
     = Voice_wizard.Macos_say);
  let spoken =
    Voice_wizard.blank ~section:Voice_setup.Tts ~provider:Voice_wizard.Macos_say
  in
  Alcotest.(check bool) "and back" true
    ((Voice_wizard.with_section spoken Voice_setup.Stt).Voice_wizard.provider
     = Voice_wizard.Whisper_cli)

let test_moving_keeps_a_provider_that_serves_both () =
  let draft =
    Voice_wizard.blank ~section:Voice_setup.Tts ~provider:Voice_wizard.Openai_compatible
  in
  let moved = Voice_wizard.with_section draft Voice_setup.Stt in
  Alcotest.(check bool) "still openai-compatible" true
    (moved.Voice_wizard.provider = Voice_wizard.Openai_compatible)

let () =
  Alcotest.run
    "voice_wizard"
    [ ( "which questions"
      , [ Alcotest.test_case "each side is offered what can do its half" `Quick
            test_each_side_is_offered_what_can_do_its_half
        ; Alcotest.test_case "a command is asked for neither an address nor a key" `Quick
            test_a_command_is_asked_for_neither_an_address_nor_a_key
        ; Alcotest.test_case "the questions depend on the provider" `Quick
            test_the_questions_depend_on_the_provider
        ; Alcotest.test_case "elevenlabs arrives with what is the same everywhere" `Quick
            test_elevenlabs_arrives_with_what_is_the_same_everywhere
        ; Alcotest.test_case "moving to speech in gives up a provider that cannot listen" `Quick
            test_moving_to_speech_in_gives_up_a_provider_that_cannot_listen
        ; Alcotest.test_case "moving keeps a provider that serves both" `Quick
            test_moving_keeps_a_provider_that_serves_both
        ; Alcotest.test_case "moving lands on the command the other side runs" `Quick
            test_moving_lands_on_the_command_the_other_side_runs
        ] )
    ; ( "when a draft is complete"
      , [ Alcotest.test_case "a local endpoint may go without a credential" `Quick
            test_a_local_endpoint_may_go_without_a_credential
        ; Alcotest.test_case "elevenlabs without its credential is incomplete" `Quick
            test_elevenlabs_without_its_credential_is_incomplete
        ; Alcotest.test_case "speech out needs a voice" `Quick test_speech_out_needs_a_voice
        ; Alcotest.test_case "a tool endpoint carries its url as mcp_url" `Quick
            test_a_tool_endpoint_carries_its_url_as_mcp_url
        ; Alcotest.test_case "say needs only a name and a voice" `Quick
            test_say_needs_only_a_name_and_a_voice
        ; Alcotest.test_case "whisper-cli is incomplete without the model file" `Quick
            test_whisper_cli_is_incomplete_without_the_model_file
        ] )
    ; ( "what it writes"
      , [ Alcotest.test_case "a complete draft writes a configuration that loads" `Quick
            test_a_complete_draft_writes_a_configuration_that_loads
        ; Alcotest.test_case "the first endpoint owns the section default" `Quick
            test_the_first_endpoint_owns_the_section_default
        ; Alcotest.test_case "another kind carries its own voice" `Quick
            test_another_kind_carries_its_own_voice
        ; Alcotest.test_case "one more of the same kind keeps the section default" `Quick
            test_one_more_of_the_same_kind_keeps_the_section_default
        ; Alcotest.test_case "speech in writes no voice at all" `Quick
            test_speech_in_writes_no_voice_at_all
        ; Alcotest.test_case "a command endpoint is written with nothing to reach" `Quick
            test_a_command_endpoint_is_written_with_nothing_to_reach
        ] )
    ]
