(* What masc voice-verify says about a keeper mapped to a say voice this
   machine does not have.

   say does not fail on such a name: it exits 0 and speaks in another voice.
   Measured 2026-09-13 on macOS 26 whose first language is Korean: [-v
   NoSuchVoice] wrote the same bytes as [-v Yuna]. The probe used to answer a
   mapping like that with the same "answered" as a mapping that took, so the
   check an operator runs to confirm a voice confirmed the wrong one.

   say here is a script. Asked [-v ?] it prints a recorded catalogue; asked to
   speak it notes the voice and copies a WAV into place. PATH holds only its
   directory and /bin. *)

module Voice_bridge = Masc.Voice_bridge

let rm_rf path =
  let rec go path =
    match Sys.is_directory path with
    | true ->
      Array.iter (fun entry -> go (Filename.concat path entry)) (Sys.readdir path);
      Unix.rmdir path
    | false -> Sys.remove path
    | exception Sys_error _ -> ()
  in
  go path

let base =
  let path = Filename.temp_file "masc-voice-say-voice-probe-" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let bin = Filename.concat base "bin"
let config_dir = Filename.concat base ".masc/config"
let runtime_toml = Filename.concat config_dir "runtime.toml"
let spoken_log = Filename.concat base "spoken.log"

let write ?(perm = 0o644) path contents =
  let channel = open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] perm path in
  output_string channel contents;
  close_out channel

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)

(* A WAV header and one second of 16 kHz silence: past the size the probe
   believes. *)
let wav_bytes =
  let data = 32_000 in
  let buffer = Buffer.create (44 + data) in
  let u32 n = Buffer.add_int32_le buffer (Int32.of_int n) in
  let u16 n = Buffer.add_uint16_le buffer n in
  Buffer.add_string buffer "RIFF";
  u32 (36 + data);
  Buffer.add_string buffer "WAVEfmt ";
  u32 16; u16 1; u16 1; u32 16_000; u32 32_000; u16 2; u16 16;
  Buffer.add_string buffer "data";
  u32 data;
  Buffer.add_string buffer (String.make data '\000');
  Buffer.contents buffer

(* Lines as say -v ? prints them: space-padded, the whole label before the
   locale. *)
let catalogue =
  "Eddy (\xed\x95\x9c\xea\xb5\xad\xec\x96\xb4(\xed\x95\x9c\xea\xb5\xad))      ko_KR    # \xec\x95\x88\xeb\x85\x95\n\
   Eddy (\xec\x98\x81\xec\x96\xb4(\xeb\xaf\xb8\xea\xb5\xad))       en_US    # Hello\n\
   Yuna                ko_KR    # \xec\x95\x88\xeb\x85\x95\n"

let say_script ~lists =
  Printf.sprintf
    "#!/bin/sh\n\
     if [ \"$1\" = \"-v\" ] && [ \"$2\" = \"?\" ]; then %s; fi\n\
     voice=system\n\
     while [ $# -gt 0 ]; do\n\
     \  case \"$1\" in -v) voice=\"$2\";; -o) out=\"$2\";; esac\n\
     \  shift\n\
     done\n\
     echo \"$voice\" >> '%s'\n\
     cp '%s' \"$out\"\n"
    (if lists
     then Printf.sprintf "cat '%s'; exit 0" (Filename.concat base "catalogue.txt")
     else "echo 'voice list unavailable' >&2; exit 1")
    spoken_log
    (Filename.concat base "template.wav")

let voice_section =
  Printf.sprintf
    {|[voice.tts]
default_voice = "Yuna"

[voice.tts.agent_voices]
ghost = "NoSuchVoice"
lowercase = "yuna"
bare = "Eddy"
korean-eddy = "Eddy (한국어(한국))"

[[voice.tts.endpoints]]
id = "macos-say"
kind = "macos_say"
enabled = true
command = "%s"
|}
    (Filename.concat bin "say")

let () =
  mkdir_p bin;
  mkdir_p config_dir;
  write (Filename.concat base "template.wav") wav_bytes;
  write (Filename.concat base "catalogue.txt") catalogue;
  write runtime_toml voice_section;
  Unix.putenv "MASC_BASE_PATH" base;
  Unix.putenv "PATH" (bin ^ ":/bin");
  at_exit (fun () -> rm_rf base)

let probe ?agent_id ~lists () =
  write ~perm:0o755 (Filename.concat bin "say") (say_script ~lists);
  (try Sys.remove spoken_log with Sys_error _ -> ());
  Config_dir_resolver.reset ();
  Eio_main.run
  @@ fun env ->
  Eio.Switch.run
  @@ fun sw ->
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  Eio_context.with_test_env
    ~net:(Eio.Stdenv.net env)
    ~clock:(Eio.Stdenv.clock env)
    ~mono_clock:(Eio.Stdenv.mono_clock env)
    ~sw
    (fun () ->
      match Voice_bridge.probe_tts ?agent_id ~message:"목소리 확인입니다." () with
      | Error reason -> Alcotest.failf "the probe did not run: %s" reason
      | Ok [ attempt ] -> attempt.Voice_bridge.outcome
      | Ok attempts -> Alcotest.failf "expected one endpoint, got %d" (List.length attempts))

let spoken () =
  match In_channel.with_open_bin spoken_log In_channel.input_all with
  | text -> List.filter (fun line -> line <> "") (String.split_on_char '\n' text)
  | exception Sys_error _ -> []

let outcome = Alcotest.testable
    (fun ppf outcome -> Format.pp_print_string ppf (Voice_bridge.probe_outcome_to_string outcome))
    ( = )

let refused_with ~prefix = function
  | Voice_bridge.Refused reason -> String.starts_with ~prefix reason
  | Voice_bridge.Answered _ | Voice_bridge.Skipped _ -> false

let test_a_voice_say_has_answers () =
  let result = probe ~lists:true () in
  Alcotest.check outcome "the section default is installed"
    (Voice_bridge.Answered "32044 bytes of audio in \"Yuna\"") result;
  Alcotest.(check (list string)) "and say was asked for it" [ "Yuna" ] (spoken ())

let test_a_voice_say_lacks_is_refused_before_it_speaks () =
  let result = probe ~agent_id:"ghost" ~lists:true () in
  Alcotest.check outcome "refused, naming the voice and the list"
    (Voice_bridge.Refused
       "say has no voice named \"NoSuchVoice\", and would speak in another one without \
        failing; masc voice-local-setup --list-voices prints the 3 it has")
    result;
  Alcotest.(check (list string)) "say was never asked to speak" [] (spoken ())

let test_say_matches_names_without_case () =
  let result = probe ~agent_id:"lowercase" ~lists:true () in
  Alcotest.(check bool)
    (Voice_bridge.probe_outcome_to_string result)
    true
    (match result with Voice_bridge.Answered _ -> true | Voice_bridge.Refused _ | Voice_bridge.Skipped _ -> false)

(* say prints Eddy only with a language. The bare name is not one of its
   labels, and say -v Eddy read a Korean sentence in an English voice. *)
let test_a_bare_name_is_not_a_label () =
  Alcotest.(check bool) "bare Eddy is refused" true
    (refused_with ~prefix:"say has no voice named \"Eddy\""
       (probe ~agent_id:"bare" ~lists:true ()));
  Alcotest.(check bool) "the whole label answers" true
    (match probe ~agent_id:"korean-eddy" ~lists:true () with
     | Voice_bridge.Answered _ -> true
     | Voice_bridge.Refused _ | Voice_bridge.Skipped _ -> false)

let test_a_catalogue_that_cannot_be_read_is_not_taken_as_a_yes () =
  let result = probe ~lists:false () in
  Alcotest.(check bool)
    (Voice_bridge.probe_outcome_to_string result)
    true
    (refused_with ~prefix:"the voices say has could not be listed to check \"Yuna\"" result);
  Alcotest.(check (list string)) "say was never asked to speak" [] (spoken ())

let () =
  Alcotest.run
    "voice say voice probe"
    [ ( "a keeper's say voice"
      , [ Alcotest.test_case "a voice say has answers" `Quick test_a_voice_say_has_answers
        ; Alcotest.test_case "a voice say lacks is refused before it speaks" `Quick
            test_a_voice_say_lacks_is_refused_before_it_speaks
        ; Alcotest.test_case "say matches names without case" `Quick
            test_say_matches_names_without_case
        ; Alcotest.test_case "a bare name is not a label" `Quick
            test_a_bare_name_is_not_a_label
        ; Alcotest.test_case "a catalogue that cannot be read is not a yes" `Quick
            test_a_catalogue_that_cannot_be_read_is_not_taken_as_a_yes
        ] )
    ]
