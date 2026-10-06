(* The command kinds, run for real.

   The sibling suite pins the argv. This one runs it: it asks masc's own
   transport to speak a Korean sentence through [say] and checks that a file
   with audio in it appeared. An argv that is right on paper and wrong in
   practice -- a flag that moved, a command that writes to stdout instead of
   the file -- is only visible here.

   Each command's cases run only where that command is installed: the say
   cases on a mac, the espeak-ng cases where espeak-ng is. A machine with
   neither -- CI included -- runs nothing. The skip prints its reason before
   the runner starts, because alcotest captures per-case output and a reason
   printed inside a case is not shown for a case that passed. *)

let command_is_installed command =
  match Unix.system (Printf.sprintf "command -v %s > /dev/null 2>&1" command) with
  | Unix.WEXITED 0 -> true
  | Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> false

let say_is_installed () = command_is_installed "say"

let espeak_is_installed () = command_is_installed "espeak-ng"

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
  ; command = None
  ; model = None
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
          (Sys.file_exists output_file))

(* A voice name that does not exist does NOT fail. Measured 2026-09-12: say
   exits 0 and writes 91,028 bytes in another voice. A neighbouring
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

let espeak_endpoint =
  { Voice_config.id = "espeak-local"
  ; kind = Voice_config.Espeak_ng
  ; base_url = None
  ; mcp_url = None
  ; health_url = None
  ; api_key_env = None
  ; enabled = true
  ; timeout_seconds = None
  ; default_voice = None
  ; command = None
  ; model = None
  }

(* espeak-ng through masc's own transport, for real. Korean on purpose, like
   the say case: it has to reach the Korean voice, not just any voice. *)
let test_espeak_writes_audio_that_can_be_played () =
  let output_file = Filename.temp_file "masc_espeak_live_" ".wav" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove output_file with
      | Sys_error _ -> ())
    (fun () ->
      match
        Voice_bridge_transport.speak_via_command_to_file
          espeak_endpoint
          ~message:sentence
          ~voice:"ko"
          ~output_file
      with
      | Error message -> Alcotest.fail message
      | Ok file_size ->
        Alcotest.(check bool)
          (Printf.sprintf "espeak-ng wrote %d bytes of audio" file_size)
          true (file_size > 1024);
        Alcotest.(check bool) "and the file is where it was asked for" true
          (Sys.file_exists output_file))

(* The mirror of the say case above. Measured 2026-10-07 with espeak-ng
   1.52.0: an unknown voice exits 1 with "Error: The specified espeak-ng
   voice does not exist." and writes no file. Loud, where say is silent --
   which is why the catalogue check for this kind fails fast with the name
   rather than catching a silent fallback. *)
let test_an_unknown_espeak_voice_fails_loudly () =
  let output_file = Filename.temp_file "masc_espeak_live_" ".wav" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove output_file with
      | Sys_error _ -> ())
    (fun () ->
      match
        Voice_bridge_transport.speak_via_command_to_file
          espeak_endpoint
          ~message:sentence
          ~voice:"NoSuchVoiceExists"
          ~output_file
      with
      | Error message ->
        Alcotest.(check bool) "espeak-ng's own refusal reaches the caller" true
          (Astring.String.is_infix ~affix:"does not exist" message)
      | Ok size ->
        Alcotest.failf "espeak-ng spoke %d bytes for a voice it does not have" size)

(* The catalogue off this machine: 142 lines -- a header and 141 voices -- on
   the one that measured it. Each row needs an id, at least one voice is
   Korean, and at least one row carries an alias -- the (en 3) after
   English_(America) -- without which a bare -v en would fail the catalogue
   check while the command itself answers to it. *)
let test_the_installed_espeak_voices_can_be_listed () =
  match Masc.Voice_bridge.list_voices espeak_endpoint with
  | Error message -> Alcotest.fail message
  | Ok voices ->
    Alcotest.(check bool)
      (Printf.sprintf "espeak-ng listed %d voices" (List.length voices))
      true
      (List.length voices > 10);
    List.iter
      (fun (voice : Masc.Voice_bridge.catalogue_voice) ->
        if String.trim voice.Masc.Voice_bridge.voice_id = ""
        then Alcotest.fail "a listed voice has no id to choose")
      voices;
    Alcotest.(check bool) "and at least one of them is Korean" true
      (List.exists
         (fun (voice : Masc.Voice_bridge.catalogue_voice) ->
           voice.Masc.Voice_bridge.voice_language = Some "ko")
         voices);
    Alcotest.(check bool) "and at least one carries an alias" true
      (List.exists
         (fun (voice : Masc.Voice_bridge.catalogue_voice) ->
           voice.Masc.Voice_bridge.voice_aliases <> [])
         voices);
    (* --voices shows spaces as underscores and -v wants them back, so the
       stored id is the restored name. If no id carries a space, the
       restoration stopped running and multi-word voices fail when chosen. *)
    Alcotest.(check bool) "and a stored name has its spaces back" true
      (List.exists
         (fun (voice : Masc.Voice_bridge.catalogue_voice) ->
           String.contains voice.Masc.Voice_bridge.voice_id ' ')
         voices)

let () =
  let say_here = say_is_installed () in
  let espeak_here = espeak_is_installed () in
  if not say_here && not espeak_here
  then
    print_endline
      "voice_local_command_live: skipped, neither say nor espeak-ng is installed"
  else (
    if not say_here
    then print_endline "voice_local_command_live: say cases skipped, say is not installed";
    if not espeak_here
    then
      print_endline
        "voice_local_command_live: espeak-ng cases skipped, espeak-ng is not installed";
    let speaking =
      (if say_here
       then
         [ Alcotest.test_case "say writes audio that can be played" `Quick
             test_say_writes_audio_that_can_be_played
         ; Alcotest.test_case "an unknown voice does not fail" `Quick
             test_an_unknown_voice_does_not_fail
         ]
       else [])
      @
      if espeak_here
      then
        [ Alcotest.test_case "espeak-ng writes audio that can be played" `Quick
            test_espeak_writes_audio_that_can_be_played
        ; Alcotest.test_case "an unknown espeak-ng voice fails loudly" `Quick
            test_an_unknown_espeak_voice_fails_loudly
        ]
      else []
    in
    let listing =
      (if say_here
       then
         [ Alcotest.test_case "the installed voices can be listed" `Quick
             test_the_installed_voices_can_be_listed
         ]
       else [])
      @
      if espeak_here
      then
        [ Alcotest.test_case "the installed espeak-ng voices can be listed" `Quick
            test_the_installed_espeak_voices_can_be_listed
        ]
      else []
    in
    Alcotest.run
      "voice_local_command_live"
      [ "speaking for real", speaking; "listing for real", listing ])
