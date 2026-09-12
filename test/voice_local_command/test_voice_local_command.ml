(* The two voice kinds that run a command instead of reaching an address.

   Every argv asserted here was run before it was written down, on macOS 26 on
   an M3 Max, 2026-09-12:

     say -v Yuna -o out.aiff "안녕하세요 키퍼입니다"     -> 84KB AIFF
     afconvert -f WAVE -d LEI16@16000 -c 1 out.aiff out.wav
     whisper-cli -m ggml-large-v3-turbo.bin -l auto -nt -f out.wav
       -> auto-detected language: ko (p = 0.998641)
       -> " 안녕하세요. 키퍼입니다."  in 5.1s wall

   The afconvert step is not in the product: masc records at 16 kHz mono
   16-bit WAV already, which is what whisper.cpp wants. It was only needed to
   feed say's own output back in.

   What these hold is that the argv masc builds is that argv, and that a kind
   which cannot do the asked-for half says so rather than building something
   that will fail further away. *)

module Overlay = Voice_runtime_overlay
module Bridge = Masc.Voice_bridge

let endpoint ?command ~kind id =
  { Voice_config.id
  ; kind
  ; base_url = None
  ; mcp_url = None
  ; health_url = None
  ; api_key_env = None
  ; enabled = true
  ; timeout_seconds = None
  ; default_voice = None
  ; command
  }

let argv_of = function
  | Ok (request : Overlay.command_request) -> request.Overlay.argv
  | Error message -> Alcotest.fail message

let test_say_is_asked_for_a_voice_and_a_file () =
  let argv =
    argv_of
      (Overlay.tts_command_for_endpoint
         (endpoint ~kind:Voice_config.Macos_say "macos-say")
         ~voice:"Yuna" ~message:"안녕하세요 키퍼입니다" ~output_file:"/tmp/out.aiff")
  in
  Alcotest.(check (list string))
    "the argv that was run"
    [ "say"; "-v"; "Yuna"; "-o"; "/tmp/out.aiff"; "안녕하세요 키퍼입니다" ]
    argv

(* A reader who never picked a voice has been listening to the system voice all
   along, and say uses it when told nothing. Passing an empty -v would instead
   ask for a voice named "". *)
let test_no_voice_leaves_the_flag_off () =
  let argv =
    argv_of
      (Overlay.tts_command_for_endpoint
         (endpoint ~kind:Voice_config.Macos_say "macos-say")
         ~voice:"  " ~message:"hello" ~output_file:"/tmp/out.aiff")
  in
  Alcotest.(check (list string))
    "no -v at all" [ "say"; "-o"; "/tmp/out.aiff"; "hello" ] argv

(* The message is the last argument and is never joined into a string. A
   keeper's sentence is arbitrary text, and a shell between here and say would
   make quoting decide what runs. *)
let test_the_message_stays_one_argument () =
  let argv =
    argv_of
      (Overlay.tts_command_for_endpoint
         (endpoint ~kind:Voice_config.Macos_say "macos-say")
         ~voice:"Yuna" ~message:"; rm -rf ~ # \"quoted\"" ~output_file:"/tmp/o.aiff")
  in
  Alcotest.(check string)
    "the whole sentence is one argv entry"
    "; rm -rf ~ # \"quoted\"" (List.nth argv (List.length argv - 1));
  Alcotest.(check int) "and nothing was split off it" 6 (List.length argv)

let test_whisper_is_asked_for_the_model_and_the_file () =
  let argv =
    argv_of
      (Overlay.stt_command_for_endpoint
         (endpoint ~kind:Voice_config.Whisper_cli "whisper-local")
         ~audio_file:"/tmp/heard.wav" ~model:"/models/ggml-large-v3-turbo.bin")
  in
  Alcotest.(check (list string))
    "the argv that was run"
    [ "whisper-cli"
    ; "-m"
    ; "/models/ggml-large-v3-turbo.bin"
    ; "-l"
    ; "auto"
    ; "-nt"
    ; "-f"
    ; "/tmp/heard.wav"
    ]
    argv

(* auto rather than a configured language: it detected Korean at p = 0.9986 on
   the sample above, so a language setting would be one more thing to get wrong
   for no accuracy gained. *)
let test_the_language_is_detected_not_configured () =
  let argv =
    argv_of
      (Overlay.stt_command_for_endpoint
         (endpoint ~kind:Voice_config.Whisper_cli "whisper-local")
         ~audio_file:"/tmp/heard.wav" ~model:"/models/m.bin")
  in
  let rec after_l = function
    | "-l" :: value :: _ -> Some value
    | _ :: rest -> after_l rest
    | [] -> None
  in
  Alcotest.(check (option string)) "asked to detect" (Some "auto") (after_l argv)

(* Blank is refused by name. Defaulting to a path would fail inside whisper
   with a message about a model file, and the reader would go looking for a
   file rather than for the setting that is empty. *)
let test_a_missing_model_is_refused_by_name () =
  match
    Overlay.stt_command_for_endpoint
      (endpoint ~kind:Voice_config.Whisper_cli "whisper-local")
      ~audio_file:"/tmp/heard.wav" ~model:"   "
  with
  | Ok request ->
    Alcotest.failf "expected a refusal, got %s" (String.concat " " request.Overlay.argv)
  | Error message ->
    Alcotest.(check bool) "the refusal names the setting to fill" true
      (Astring.String.is_infix ~affix:"default_model" message)

(* An installation that keeps the binary somewhere PATH does not carry. *)
let test_the_command_can_be_overridden () =
  let argv =
    argv_of
      (Overlay.stt_command_for_endpoint
         (endpoint ~command:"/opt/homebrew/bin/whisper-cli" ~kind:Voice_config.Whisper_cli
            "whisper-local")
         ~audio_file:"/tmp/heard.wav" ~model:"/models/m.bin")
  in
  Alcotest.(check string) "the path given, not the name" "/opt/homebrew/bin/whisper-cli"
    (List.nth argv 0)

(* Each half refuses the other. An endpoint that transcribes is not a fallback
   for one that speaks: a chain that quietly used it would report success for a
   turn nobody heard. *)
let test_each_half_refuses_the_other () =
  (match
     Overlay.tts_command_for_endpoint
       (endpoint ~kind:Voice_config.Whisper_cli "whisper-local")
       ~voice:"Yuna" ~message:"hello" ~output_file:"/tmp/o.aiff"
   with
   | Ok _ -> Alcotest.fail "a transcriber must not be asked to speak"
   | Error message ->
     Alcotest.(check bool) "and says which way round it is" true
       (Astring.String.is_infix ~affix:"does not speak" message));
  match
    Overlay.stt_command_for_endpoint
      (endpoint ~kind:Voice_config.Macos_say "macos-say")
      ~audio_file:"/tmp/heard.wav" ~model:"/models/m.bin"
  with
  | Ok _ -> Alcotest.fail "a speaker must not be asked to transcribe"
  | Error message ->
    Alcotest.(check bool) "and says which way round it is" true
      (Astring.String.is_infix ~affix:"does not transcribe" message)

(* An HTTP endpoint asked for a command is told what it is reached over, not
   told the command is missing. *)
let test_an_http_endpoint_is_not_a_command () =
  match
    Overlay.tts_command_for_endpoint
      (endpoint ~kind:Voice_config.Elevenlabs_direct "elevenlabs")
      ~voice:"Yuna" ~message:"hello" ~output_file:"/tmp/o.aiff"
  with
  | Ok _ -> Alcotest.fail "an HTTP endpoint has no command to run"
  | Error message ->
    Alcotest.(check bool) "the transport is named" true
      (Astring.String.is_infix ~affix:"elevenlabs_direct" message)

(* An address on a command kind is refused when the configuration is read
   rather than dropped on the floor: a field that is silently ignored reads as
   a setting that took. *)
let test_an_address_on_a_command_kind_is_refused () =
  let text =
    {|{"tts": {"default_model": "-", "default_voice": "Yuna",
       "endpoints": [{"id": "macos-say", "kind": "macos_say",
                      "base_url": "http://127.0.0.1:9/v1"}]}}|}
  in
  match Voice_config.parse_json (Yojson.Safe.from_string text) with
  | Ok _ -> Alcotest.fail "an address on a command kind should be refused"
  | Error message ->
    Alcotest.(check bool) "and says the kind runs a command" true
      (Astring.String.is_infix ~affix:"runs a command" message)

(* What say actually printed, taken from the machine on 2026-09-12. Six lines
   out of 184: two ordinary, one whose locale is not two-and-two (ar_001), one
   whose name carries the parenthesised language say adds when a name exists in
   several, and Korean. *)
let say_output =
  "Albert              en_US    # Hello! My name is Albert.\n\
   Alice               it_IT    # Ciao! Mi chiamo Alice.\n\
   Majed               ar_001   # \xd9\x85\xd8\xb1\xd8\xad\xd8\xa8\xd9\x8b\xd8\xa7!\n\
   Eddy (\xed\x95\x9c\xea\xb5\xad\xec\x96\xb4(\xed\x95\x9c\xea\xb5\xad))      ko_KR    # \xec\x95\x88\xeb\x85\x95\xed\x95\x98\xec\x84\xb8\xec\x9a\x94\n\
   Yuna                ko_KR    # \xec\x95\x88\xeb\x85\x95\xed\x95\x98\xec\x84\xb8\xec\x9a\x94\n"

let voices () = Bridge.say_catalogue_of_output say_output

let test_every_printed_voice_becomes_a_row () =
  Alcotest.(check int) "five voices, five rows" 5 (List.length (voices ()))

let test_the_locale_is_read_as_the_last_field_not_by_its_shape () =
  let majed =
    List.find
      (fun (v : Bridge.catalogue_voice) ->
        v.Bridge.voice_id = "Majed")
      (voices ())
  in
  (* ar_001 is not two letters and two letters. A locale regex would drop it,
     and a reader with Arabic installed would be told they have no such voice. *)
  Alcotest.(check (option string)) "the locale as printed" (Some "ar_001")
    majed.Bridge.voice_language

(* The id is the whole label. say -v Eddy picked an English voice that read a
   Korean sentence as 4.7KB of noise; say -v "Eddy (한국어(한국))" gave 72KB of
   the Korean one. Trimming the parenthetical here would hand the wizard a name
   that silently selects the wrong language. *)
let test_a_parenthesised_name_keeps_its_parenthesis () =
  let ids =
    List.map
      (fun (v : Bridge.catalogue_voice) -> v.Bridge.voice_id)
      (voices ())
  in
  Alcotest.(check bool) "the label say prints, whole" true
    (List.exists (fun id -> Astring.String.is_prefix ~affix:"Eddy (" id) ids)

let test_a_line_naming_no_voice_is_dropped () =
  Alcotest.(check int) "nothing to choose, nothing offered" 0
    (List.length (Bridge.say_catalogue_of_output "# just a comment\n\n"))


(* Which transport answers a transcript. Before this was routed by kind, every
   enabled STT endpoint was sent an HTTP request -- including whisper, which
   has no address, so the only endpoint that can transcribe on this machine was
   the one that could not be asked. *)

let write_fake_whisper ~prints =
  let path = Filename.temp_file "fake-whisper" ".sh" in
  let channel = open_out path in
  output_string channel (Printf.sprintf "#!/bin/sh\nprintf '%%s\\n' \"%s\"\n" prints);
  close_out channel;
  Unix.chmod path 0o755;
  path

let test_whisper_answers_with_what_the_command_printed () =
  let command = write_fake_whisper ~prints:" 안녕하세요. 키퍼입니다." in
  let transcript =
    Bridge.transcribe_endpoint
      (endpoint ~kind:Voice_config.Whisper_cli ~command "whisper-local")
      ~audio_file:"/tmp/captured.wav"
      ~model:"/tmp/ggml-large-v3-turbo.bin"
  in
  Sys.remove command;
  match transcript with
  | Some (Ok text) ->
    Alcotest.(check string) "the command's own output" "안녕하세요. 키퍼입니다." text
  | Some (Error reason) -> Alcotest.fail reason
  | None -> Alcotest.fail "whisper transcribes, so it must be asked"

(* A kind that speaks is not a broken transcriber: it is one that was never
   asked. Reporting it as a refusal would read as an endpoint that is down. *)
let test_a_speaking_kind_is_not_asked_for_a_transcript () =
  let asked kind =
    Option.is_some
      (Bridge.transcribe_endpoint
         (endpoint ~kind "endpoint")
         ~audio_file:"/tmp/captured.wav"
         ~model:"/tmp/model.bin")
  in
  Alcotest.(check bool) "say has no ear" false (asked Voice_config.Macos_say);
  Alcotest.(check bool) "the mcp endpoint speaks" false (asked Voice_config.Voice_mcp);
  Alcotest.(check bool) "whisper does" true (asked Voice_config.Whisper_cli)

let () =
  Alcotest.run
    "voice_local_command"
    [ ( "speaking"
      , [ Alcotest.test_case "say is asked for a voice and a file" `Quick
            test_say_is_asked_for_a_voice_and_a_file
        ; Alcotest.test_case "no voice leaves the flag off" `Quick
            test_no_voice_leaves_the_flag_off
        ; Alcotest.test_case "the message stays one argument" `Quick
            test_the_message_stays_one_argument
        ] )
    ; ( "transcribing"
      , [ Alcotest.test_case "whisper is asked for the model and the file" `Quick
            test_whisper_is_asked_for_the_model_and_the_file
        ; Alcotest.test_case "the language is detected not configured" `Quick
            test_the_language_is_detected_not_configured
        ; Alcotest.test_case "a missing model is refused by name" `Quick
            test_a_missing_model_is_refused_by_name
        ; Alcotest.test_case "the command can be overridden" `Quick
            test_the_command_can_be_overridden
        ] )
    ; ( "the voices say has"
      , [ Alcotest.test_case "every printed voice becomes a row" `Quick
            test_every_printed_voice_becomes_a_row
        ; Alcotest.test_case "the locale is read as the last field" `Quick
            test_the_locale_is_read_as_the_last_field_not_by_its_shape
        ; Alcotest.test_case "a parenthesised name keeps its parenthesis" `Quick
            test_a_parenthesised_name_keeps_its_parenthesis
        ; Alcotest.test_case "a line naming no voice is dropped" `Quick
            test_a_line_naming_no_voice_is_dropped
        ] )
    ; ( "which transport answers a transcript"
      , [ Alcotest.test_case "whisper answers with what it printed" `Quick
            test_whisper_answers_with_what_the_command_printed
        ; Alcotest.test_case "a speaking kind is not asked" `Quick
            test_a_speaking_kind_is_not_asked_for_a_transcript
        ] )
    ; ( "what each kind will not do"
      , [ Alcotest.test_case "each half refuses the other" `Quick
            test_each_half_refuses_the_other
        ; Alcotest.test_case "an http endpoint is not a command" `Quick
            test_an_http_endpoint_is_not_a_command
        ; Alcotest.test_case "an address on a command kind is refused" `Quick
            test_an_address_on_a_command_kind_is_refused
        ] )
    ]
