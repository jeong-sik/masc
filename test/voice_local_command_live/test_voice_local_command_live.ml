(* The command kinds, run for real.

   The sibling suite pins the argv. This one runs it: it asks masc's own
   transport to speak a Korean sentence through [say] and checks that a file
   with audio in it appeared. An argv that is right on paper and wrong in
   practice -- a flag that moved, a command that writes to stdout instead of
   the file -- is only visible here.

   Skipped where [say] is not installed, which is every machine that is not a
   mac, including CI. The skip prints its reason before the runner starts,
   because alcotest captures per-case output and a reason printed inside a case
   is not shown for a case that passed. *)

let say_is_installed () =
  match Unix.system "command -v say > /dev/null 2>&1" with
  | Unix.WEXITED 0 -> true
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false

let endpoint =
  { Voice_config.id = "macos-say"
  ; kind = Voice_config.Macos_say
  ; base_url = None
  ; mcp_url = None
  ; health_url = None
  ; api_key_env = None
  ; enabled = true
  ; timeout_seconds = None
  ; default_voice = None
  ; agent_voices = []
  ; model = None
  ; command = None
  }

(* Korean on purpose. An English sentence would pass on a machine with no
   Korean voice installed and tell this workstation nothing. *)
let sentence = "안녕하세요. 키퍼입니다."

let test_say_writes_audio_that_can_be_played () =
  let output_file = Filename.temp_file "masc_say_live_" ".wav" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove output_file with
      | Sys_error _ -> ())
    (fun () ->
      match
        Voice_bridge_transport.speak_via_command_to_file
          endpoint
          ~message:sentence
          ~voice:"Yuna"
          ~output_file
      with
      | Error message -> Alcotest.fail message
      | Ok file_size ->
        (* Measured at 84KB for this sentence on 2026-09-12. The bound is loose
           on purpose: what it has to separate is audio from an empty file a
           clean exit left behind, not one encoder from another. *)
        Alcotest.(check bool)
          (Printf.sprintf "say wrote %d bytes of audio" file_size)
          true (file_size > 1024);
        Alcotest.(check bool) "and the file is where it was asked for" true
          (Sys.file_exists output_file);
        let header =
          In_channel.with_open_bin output_file (fun input -> really_input_string input 12)
        in
        Alcotest.(check string) "the container starts with RIFF" "RIFF" (String.sub header 0 4);
        Alcotest.(check string) "the container is WAVE, matching its MIME" "WAVE"
          (String.sub header 8 4))

(* A voice name that does not exist does NOT fail. Measured 2026-09-12: say
   exits 0 and writes 91,028 bytes in the system voice. A neighbouring
   measurement is worse -- "Eddy" names voices in several languages, and
   [say -v Eddy] on this Korean sentence wrote 4.7KB of an English voice
   mangling it, where [say -v "Eddy (한국어(한국))"] wrote 72KB of the Korean one.

   So a mistyped or half-typed voice is silent: the wrong voice speaks and
   nothing reports anything. That is why the name cannot be a free-text field
   in the wizard -- the list has to be offered, and say publishes one through
   [say -v '?'].

   This case is here to keep that fact from being quietly assumed away: if a
   future macOS starts refusing unknown voices, this goes red and the reason to
   offer a list weakens. *)
let test_an_unknown_voice_does_not_fail () =
  let output_file = Filename.temp_file "masc_say_live_" ".wav" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove output_file with
      | Sys_error _ -> ())
    (fun () ->
      match
        Voice_bridge_transport.speak_via_command_to_file
          endpoint
          ~message:sentence
          ~voice:"NoSuchVoiceExists"
          ~output_file
      with
      | Error message ->
        Alcotest.failf
          "say now refuses an unknown voice (%s) -- it used to fall back silently, and \
           the wizard's voice list was justified by that"
          message
      | Ok size ->
        Alcotest.(check bool)
          (Printf.sprintf "an unknown voice still spoke, in %d bytes" size)
          true (size > 1024))

(* The catalogue, read off this machine rather than off a recorded sample. The
   sibling suite pins the parse against six captured lines; this one runs the
   command and checks the parse survives all 184 of them. *)
let test_the_installed_voices_can_be_listed () =
  match Masc.Voice_bridge.list_voices endpoint with
  | Error message -> Alcotest.fail message
  | Ok voices ->
    Alcotest.(check bool)
      (Printf.sprintf "say listed %d voices" (List.length voices))
      true
      (List.length voices > 10);
    (* Every row has to be choosable: an id is what gets written to the
       configuration, and a blank one would be written as a blank. *)
    List.iter
      (fun (voice : Masc.Voice_bridge.catalogue_voice) ->
        if String.trim voice.Masc.Voice_bridge.voice_id = ""
        then Alcotest.fail "a listed voice has no id to choose")
      voices;
    (* This workstation speaks Korean, and the reason the list exists is that a
       Korean voice cannot be guessed by name. If the parse ever stops finding
       one, the wizard would offer a list with nothing usable in it. *)
    Alcotest.(check bool) "and at least one of them is Korean" true
      (List.exists
         (fun (voice : Masc.Voice_bridge.catalogue_voice) ->
           voice.Masc.Voice_bridge.voice_language = Some "ko_KR")
         voices)

let () =
  if not (say_is_installed ())
  then
    print_endline
      "voice_local_command_live: skipped, say is not installed (this suite runs on macOS)"
  else
    Alcotest.run
      "voice_local_command_live"
      [ ( "speaking for real"
        , [ Alcotest.test_case "say writes audio that can be played" `Quick
              test_say_writes_audio_that_can_be_played
          ; Alcotest.test_case "an unknown voice does not fail" `Quick
              test_an_unknown_voice_does_not_fail
          ] )
        ; ( "listing for real"
          , [ Alcotest.test_case "the installed voices can be listed" `Quick
                test_the_installed_voices_can_be_listed
            ] )
      ]
