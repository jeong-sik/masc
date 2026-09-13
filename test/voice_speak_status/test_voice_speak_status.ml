(* What keeper_voice_speak tells the model about whether anyone heard it.

   A keeper reads [status] to decide what to tell the operator. When nothing on
   this host played the clip -- no [voice.local_playback], so the clip is only
   attached to the chat -- the result says "synthesized", and the keeper has no
   word in it meaning the sentence was heard.

   say is a script that copies a WAV into place, and afplay is a script that
   exits 0. PATH holds only their directory and /bin, so no real player on the
   machine running the test is reachable. *)

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
  let path = Filename.temp_file "masc-voice-speak-status-" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let bin = Filename.concat base "bin"
let config_dir = Filename.concat base ".masc/config"
let runtime_toml = Filename.concat config_dir "runtime.toml"

let write ?(perm = 0o644) path contents =
  let channel = open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] perm path in
  output_string channel contents;
  close_out channel

let rec mkdir_p path =
  if not (Sys.file_exists path)
  then (
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755)

(* A mono 16-bit WAV of silence, one second at 16 kHz. *)
let wav_bytes =
  let samples = 16_000 in
  let data = samples * 2 in
  let buffer = Buffer.create (44 + data) in
  let u32 n =
    Buffer.add_char buffer (Char.chr (n land 0xff));
    Buffer.add_char buffer (Char.chr ((n lsr 8) land 0xff));
    Buffer.add_char buffer (Char.chr ((n lsr 16) land 0xff));
    Buffer.add_char buffer (Char.chr ((n lsr 24) land 0xff))
  in
  let u16 n =
    Buffer.add_char buffer (Char.chr (n land 0xff));
    Buffer.add_char buffer (Char.chr ((n lsr 8) land 0xff))
  in
  Buffer.add_string buffer "RIFF";
  u32 (36 + data);
  Buffer.add_string buffer "WAVEfmt ";
  u32 16;
  u16 1;
  u16 1;
  u32 16_000;
  u32 32_000;
  u16 2;
  u16 16;
  Buffer.add_string buffer "data";
  u32 data;
  Buffer.add_string buffer (String.make data '\000');
  Buffer.contents buffer

let voice_section ~local_playback =
  Printf.sprintf
    {|[voice.tts]
default_voice = "Yuna"

[[voice.tts.endpoints]]
id = "macos-say"
kind = "macos_say"
enabled = true
command = "%s"
%s|}
    (Filename.concat bin "say")
    (if local_playback then "\n[voice.local_playback]\nenabled = true\n" else "")

let () =
  mkdir_p bin;
  mkdir_p config_dir;
  let template = Filename.concat base "template.wav" in
  write template wav_bytes;
  write ~perm:0o755 (Filename.concat bin "say")
    (Printf.sprintf
       "#!/bin/sh\n\
        while [ $# -gt 0 ]; do if [ \"$1\" = \"-o\" ]; then out=\"$2\"; fi; shift; done\n\
        cp '%s' \"$out\"\n"
       template);
  write ~perm:0o755 (Filename.concat bin "afplay") "#!/bin/sh\nexit 0\n";
  Unix.putenv "MASC_BASE_PATH" base;
  Unix.putenv "MASC_BASE_PATH_INPUT" base;
  Unix.putenv "PATH" (bin ^ ":/bin");
  at_exit (fun () -> rm_rf base)

let allow_external_effect ~operation:_ ~input:_ ~call_summary:_ ~continue = continue ()

let meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String "speaker"; "trace_id", `String "voice-speak-status" ])
  with
  | Ok meta -> meta
  | Error err -> failwith ("meta fixture: " ^ err)

let speak ~local_playback ~message =
  write runtime_toml (voice_section ~local_playback);
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
      Masc.Keeper_tool_voice_runtime.handle_voice_tool
        ~config:(Masc.Workspace.default_config base)
        ~meta
        ~authorize_external_effect:allow_external_effect
        ~name:"keeper_voice_speak"
        ~args:(`Assoc [ "message", `String message ])
        ()
      |> Yojson.Safe.from_string)

let field json name =
  match Yojson.Safe.Util.member name json with
  | `String value -> Some value
  | `Null -> None
  | other -> Some (Yojson.Safe.to_string other)

let test_a_clip_nobody_played_is_synthesized () =
  let json = speak ~local_playback:false ~message:"아무도 틀지 않은 문장입니다." in
  Alcotest.(check (option string))
    (Printf.sprintf "status (%s)" (Yojson.Safe.to_string json))
    (Some "synthesized") (field json "status");
  Alcotest.(check (option string)) "playback" (Some "skipped")
    (field json "local_playback_status");
  Alcotest.(check (option string)) "and why" (Some "local playback disabled for agent")
    (field json "local_playback_reason");
  Alcotest.(check bool) "the clip is still offered to a browser" true
    (Option.is_some (field json "audio_url"))

let test_a_clip_this_host_played_is_spoken () =
  let json = speak ~local_playback:true ~message:"이 컴퓨터에서 재생된 문장입니다." in
  Alcotest.(check (option string))
    (Printf.sprintf "status (%s)" (Yojson.Safe.to_string json))
    (Some "spoken") (field json "status");
  Alcotest.(check (option string)) "playback" (Some "played")
    (field json "local_playback_status");
  Alcotest.(check bool) "with how long it played" true
    (Option.is_some (field json "played_seconds"))

let test_the_status_words_read_back () =
  List.iter
    (fun completion ->
      let word = Voice_bridge.agent_speak_completion_to_string completion in
      Alcotest.(check bool) word true
        (Voice_bridge.agent_speak_completion_of_string word = Some completion))
    [ Voice_bridge.Spoken; Voice_bridge.Synthesized; Voice_bridge.Dedup_skipped ];
  Alcotest.(check bool) "a word nobody writes is not read" true
    (Voice_bridge.agent_speak_completion_of_string "played" = None)

let () =
  Alcotest.run
    "voice speak status"
    [ ( "what the model is told"
      , [ Alcotest.test_case "a clip nobody played is synthesized" `Quick
            test_a_clip_nobody_played_is_synthesized
        ; Alcotest.test_case "a clip this host played is spoken" `Quick
            test_a_clip_this_host_played_is_spoken
        ; Alcotest.test_case "the status words read back" `Quick
            test_the_status_words_read_back
        ] )
    ]
