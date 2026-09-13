(* The two voice kinds that run a command instead of reaching an address.

   Every argv asserted here was run before it was written down, on macOS 26 on
   an M3 Max, 2026-09-12 and 2026-09-13:

     say -v Yuna --file-format=WAVE --data-format=LEI16@22050 -o out.wav
       "안녕하세요 키퍼입니다"                              -> 111KB WAVE
     whisper-cli -m ggml-large-v3-turbo.bin -l auto -nt -f out.wav
       -> auto-detected language: ko (p = 0.998641)
       -> " 안녕하세요. 키퍼입니다."  in 5.1s wall

   The format flags are in the argv because without them say picks its encoder
   from the file name, and the name masc hands it is a clip token. Measured
   2026-09-13, same machine:

     say -o clip.mp3 "..."    -> exit 0, 16 bytes, an empty MP3 tag frame
     say -o clip.wav "..."    -> exit 1, "Opening output file failed: fmt?"

   So an unnamed format fails two different ways and one of them is silent.
   With them named, the same sentence came back as 111KB of 16-bit mono WAVE.

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
         ~voice:"Yuna" ~message:"안녕하세요 키퍼입니다" ~output_file:"/tmp/out.wav")
  in
  Alcotest.(check (list string))
    "the argv that was run"
    [ "say"
    ; "-v"
    ; "Yuna"
    ; "--file-format=WAVE"
    ; "--data-format=LEI16@22050"
    ; "-o"
    ; "/tmp/out.wav"
    ; "안녕하세요 키퍼입니다"
    ]
    argv

(* A reader who never picked a voice has been listening to the system voice all
   along, and say uses it when told nothing. Passing an empty -v would instead
   ask for a voice named "". *)
let test_no_voice_leaves_the_flag_off () =
  let argv =
    argv_of
      (Overlay.tts_command_for_endpoint
         (endpoint ~kind:Voice_config.Macos_say "macos-say")
         ~voice:"  " ~message:"hello" ~output_file:"/tmp/out.wav")
  in
  Alcotest.(check (list string))
    "no -v at all"
    [ "say"
    ; "--file-format=WAVE"
    ; "--data-format=LEI16@22050"
    ; "-o"
    ; "/tmp/out.wav"
    ; "hello"
    ]
    argv

(* The message is the last argument and is never joined into a string. A
   keeper's sentence is arbitrary text, and a shell between here and say would
   make quoting decide what runs. *)
let test_the_message_stays_one_argument () =
  let argv =
    argv_of
      (Overlay.tts_command_for_endpoint
         (endpoint ~kind:Voice_config.Macos_say "macos-say")
         ~voice:"Yuna" ~message:"; rm -rf ~ # \"quoted\"" ~output_file:"/tmp/o.wav")
  in
  Alcotest.(check string)
    "the whole sentence is one argv entry"
    "; rm -rf ~ # \"quoted\"" (List.nth argv (List.length argv - 1));
  Alcotest.(check int) "and nothing was split off it" 8 (List.length argv)

(* The container and the samples are stated to say rather than implied by the
   file name. say has no MP3 encoder, and masc names its clips by a token: the
   extension arrives as whatever the clip format says, so the flags are what
   decide the bytes. Without them a clip named .mp3 is 16 bytes of silence
   that exits 0. *)
let test_say_is_told_which_container_to_write () =
  let argv =
    argv_of
      (Overlay.tts_command_for_endpoint
         (endpoint ~kind:Voice_config.Macos_say "macos-say")
         ~voice:"Yuna" ~message:"hello" ~output_file:"/tmp/9f3c.wav")
  in
  Alcotest.(check bool) "the container is named" true
    (List.mem "--file-format=WAVE" argv);
  Alcotest.(check bool) "and so are the samples" true
    (List.mem "--data-format=LEI16@22050" argv)

(* A say clip is stored as WAVE and an HTTP one as MP3, and the extension is
   what a reader resolves a token by. A kind that answered the wrong one would
   hand a player bytes it cannot decode, or report a live clip as reaped. *)
let test_each_kind_names_the_container_it_writes () =
  let format kind = Masc.Voice_bridge.clip_format_for_kind kind in
  Alcotest.(check bool) "say writes WAVE" true
    (format Voice_config.Macos_say = Voice_bridge_core.Wav);
  List.iter
    (fun kind ->
      Alcotest.(check bool) "everything over a wire answers MP3" true
        (format kind = Voice_bridge_core.Mp3))
    [ Voice_config.Openai_compat; Voice_config.Elevenlabs_direct; Voice_config.Voice_mcp ]

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
       ~voice:"Yuna" ~message:"hello" ~output_file:"/tmp/o.wav"
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
      ~voice:"Yuna" ~message:"hello" ~output_file:"/tmp/o.wav"
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

(* Where a clip is stored, and how a reader finds it again. The token in the
   URL says nothing about the container -- the endpoint that spoke decided
   that -- so a reader looks for each one. *)
let test_a_token_is_found_in_whichever_container_holds_it () =
  let dir = Filename.temp_file "masc_clip" "" in
  Sys.remove dir;
  Sys.mkdir dir 0o700;
  let write token format =
    let path = Filename.concat dir (token ^ Voice_bridge_core.clip_extension format) in
    let channel = open_out_bin path in
    output_string channel "audio";
    close_out channel;
    path
  in
  let wav_path = write "aaaa" Voice_bridge_core.Wav in
  let mp3_path = write "bbbb" Voice_bridge_core.Mp3 in
  (match Voice_bridge_core.find_clip ~dir ~token:"aaaa" with
   | Some (path, Voice_bridge_core.Wav) ->
     Alcotest.(check string) "the say clip" wav_path path
   | Some (_, Voice_bridge_core.Mp3) -> Alcotest.fail "a WAVE clip read as MP3"
   | None -> Alcotest.fail "a stored clip was reported as reaped");
  (match Voice_bridge_core.find_clip ~dir ~token:"bbbb" with
   | Some (path, Voice_bridge_core.Mp3) ->
     Alcotest.(check string) "the HTTP clip" mp3_path path
   | Some (_, Voice_bridge_core.Wav) -> Alcotest.fail "an MP3 clip read as WAVE"
   | None -> Alcotest.fail "a stored clip was reported as reaped");
  Alcotest.(check bool) "and a token nobody wrote is not found" true
    (Voice_bridge_core.find_clip ~dir ~token:"cccc" = None);
  List.iter Sys.remove [ wav_path; mp3_path ];
  Sys.rmdir dir

(* Each container is served as itself. Telling a player MP3 about WAVE bytes
   is the same silence as writing them under the wrong name. *)
let test_each_container_is_served_as_itself () =
  Alcotest.(check string) "WAVE" "audio/wav"
    (Voice_bridge_core.clip_content_type Voice_bridge_core.Wav);
  Alcotest.(check string) "MP3" "audio/mpeg"
    (Voice_bridge_core.clip_content_type Voice_bridge_core.Mp3)

(* A clip path answers with both halves at once. The caller that announces a
   spoken reply needs the token to build its URL and the type to say what the
   bytes are, and getting only the first is what let it announce MP3 for every
   clip -- including the WAVE one a fresh mac writes. *)
let test_a_clip_path_gives_back_its_token_and_its_type () =
  let announced path =
    Option.map
      (fun (token, format) -> token, Voice_bridge_core.clip_content_type format)
      (Voice_bridge_core.clip_of_path path)
  in
  let clip = Alcotest.(option (pair string string)) in
  Alcotest.check clip "a say clip is WAVE" (Some ("9f3c", "audio/wav"))
    (announced "/x/audio/9f3c.wav");
  Alcotest.check clip "an HTTP clip is MP3" (Some ("9f3c", "audio/mpeg"))
    (announced "/x/audio/9f3c.mp3");
  Alcotest.check clip "and something that is not a clip has neither" None
    (announced "/x/audio/notes.txt");
  (* A path with no extension at all used to raise here rather than answer. *)
  Alcotest.check clip "nor does a name with no extension" None
    (announced "/x/audio/9f3c")

(* The end of a failed command's output, because that is where the reason is.
   Measured on this machine: whisper-cli says which Metal library it loaded
   for nine lines before it says which file it could not open. *)
let test_a_failure_reports_its_last_line_not_its_first () =
  let noise = String.concat "\n" (List.init 40 (fun i -> Printf.sprintf "load_backend: %d" i)) in
  let reason =
    Voice_bridge_transport.command_failure_reason
      (noise ^ "\nerror: failed to open /models/missing.bin")
  in
  Alcotest.(check bool) "the reason survives" true
    (Astring.String.is_infix ~affix:"/models/missing.bin" reason);
  Alcotest.(check bool) "and the cut is marked" true
    (Astring.String.is_prefix ~affix:"..." reason);
  Alcotest.(check string) "a short output is left alone" "exit 1: no such file"
    (Voice_bridge_transport.command_failure_reason "exit 1: no such file")

(* A speaking section whose endpoints all run a command that takes no model is
   not made to invent one. The rule the loader used to apply -- every section
   names a model -- was justified by "every endpoint in it is asked for this
   model by name", and say is never asked. *)
let test_a_say_only_section_needs_no_model () =
  let text =
    {|{"tts": {"default_voice": "Yuna",
       "endpoints": [{"id": "macos-say", "kind": "macos_say"}]}}|}
  in
  match Voice_config.parse_json (Yojson.Safe.from_string text) with
  | Error message -> Alcotest.fail message
  | Ok config ->
    (match config.Voice_config.tts with
     | None -> Alcotest.fail "the section should have loaded"
     | Some tts ->
       (* Absent, not blank. A blank would be a model named "" and would reach
          an endpoint that way. *)
       Alcotest.(check (option string)) "and carries no model at all" None
         tts.Voice_config.default_model)

(* One endpoint that is asked for a model brings the requirement back. The
   section is shared, so a blank would reach that endpoint as model_id "". *)
let test_a_section_with_an_asked_endpoint_still_needs_one () =
  let text =
    {|{"tts": {"default_voice": "Yuna",
       "endpoints": [{"id": "macos-say", "kind": "macos_say"},
                     {"id": "eleven", "kind": "elevenlabs_direct"}]}}|}
  in
  match Voice_config.parse_json (Yojson.Safe.from_string text) with
  | Ok _ -> Alcotest.fail "an endpoint that is asked for a model should require one"
  | Error message ->
    Alcotest.(check bool) "and the refusal names the field" true
      (Astring.String.is_infix ~affix:"default_model" message)

(* Every transcriber is asked for one, so speech in keeps the requirement
   outright: the three that reach an address are asked by name, and whisper-cli
   is asked for the file it loads. *)
let test_speech_in_always_needs_a_model () =
  let text =
    {|{"stt": {"endpoints": [{"id": "whisper-local", "kind": "whisper_cli"}]}}|}
  in
  match Voice_config.parse_json (Yojson.Safe.from_string text) with
  | Ok _ -> Alcotest.fail "a transcriber without its model should be refused"
  | Error message ->
    Alcotest.(check bool) "and the refusal names the field" true
      (Astring.String.is_infix ~affix:"stt.default_model" message)

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
        ; Alcotest.test_case "say is told which container to write" `Quick
            test_say_is_told_which_container_to_write
        ; Alcotest.test_case "each kind names the container it writes" `Quick
            test_each_kind_names_the_container_it_writes
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
    ; ( "where a clip is stored"
      , [ Alcotest.test_case "a token is found in whichever container holds it" `Quick
            test_a_token_is_found_in_whichever_container_holds_it
        ; Alcotest.test_case "each container is served as itself" `Quick
            test_each_container_is_served_as_itself
        ; Alcotest.test_case "a clip path gives back its token and its type" `Quick
            test_a_clip_path_gives_back_its_token_and_its_type
        ; Alcotest.test_case "a failure reports its last line not its first" `Quick
            test_a_failure_reports_its_last_line_not_its_first
        ] )
    ; ( "what the section has to name"
      , [ Alcotest.test_case "a say-only section needs no model" `Quick
            test_a_say_only_section_needs_no_model
        ; Alcotest.test_case "a section with an asked endpoint still needs one" `Quick
            test_a_section_with_an_asked_endpoint_still_needs_one
        ; Alcotest.test_case "speech in always needs a model" `Quick
            test_speech_in_always_needs_a_model
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
    ; ( "what each kind will not do"
      , [ Alcotest.test_case "each half refuses the other" `Quick
            test_each_half_refuses_the_other
        ; Alcotest.test_case "an http endpoint is not a command" `Quick
            test_an_http_endpoint_is_not_a_command
        ; Alcotest.test_case "an address on a command kind is refused" `Quick
            test_an_address_on_a_command_kind_is_refused
        ] )
    ]
