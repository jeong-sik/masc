(* Audio whisper-cli does not read, and what masc does before running it.

   whisper-cli 1.9.2 answers a WebM, Ogg Opus, AIFF or MP4 file by printing
   "failed to read audio file" to stderr and exiting 0 with nothing on stdout.
   An empty transcript is also the answer to a recording of silence, so a
   reader of the command's result cannot tell the two apart. The dashboard
   microphone posts WebM.

   The byte prefixes below are the first 36 bytes of files that were run
   through whisper-cli on 2026-09-13, each encoded from the same synthesized
   sentence. *)

module Overlay = Voice_runtime_overlay

let of_hex hex =
  String.init (String.length hex / 2) (fun i ->
    Char.chr (int_of_string ("0x" ^ String.sub hex (2 * i) 2)))

let wav = of_hex "524946466ee6000057415645666d74201000000001000100803e0000007d000002001000"
let flac = of_hex "664c6143000000221200120000153d0018f103e800f000006b3b07bc9b9a2fd80abf9c63"
let mp3_with_id3 = of_hex "49443304000000000023545353450000000f0000034c61766636302e31362e3130310000"
let mp3_frame = of_hex "fff338c40014aa9664014f38008f8a412fe24e1ab2f6300001801b08da5d485b0b82c1ce"
let webm = of_hex "1a45dfa39f4286810142f7810142f2810442f381084282847765626d4287810442858102"
let ogg_opus = of_hex "4f6767530002000000000000000066ceaa7600000000590f54da01134f70757348656164"
let aifc = of_hex "464f524d00013786414946434656455200000004a2805140434f4d4d0000004400010000"
let m4a = of_hex "0000001c667479704d344120000000004d3441206d70343269736f6d0000021c6d6f6f76"

(* Not measured through whisper-cli: an Ogg page carrying Vorbis rather than
   Opus, and an AAC ADTS frame, which shares an MP3 frame's sync bits. *)
let ogg_vorbis =
  "OggS\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04\x00\x00\x00\x00"
  ^ "\x00\x00\x00\x00\x01\x1e\x01vorbis\x00\x00\x00\x00"
let aac_adts = of_hex "fff15080"

let container =
  Alcotest.testable
    (fun formatter value ->
      Format.pp_print_string formatter (Overlay.audio_container_name value))
    ( = )

let input =
  Alcotest.testable
    (fun formatter value ->
      Format.pp_print_string
        formatter
        (match value with
         | Overlay.Reads -> "Reads"
         | Overlay.Does_not_read -> "Does_not_read"
         | Overlay.Not_measured -> "Not_measured"))
    ( = )

let recognised ~bytes ~expected ~reads () =
  let found = Overlay.audio_container_of_leading_bytes bytes in
  Alcotest.check container "container" expected found;
  Alcotest.check input "whisper-cli" reads (Overlay.whisper_cli_input found)

let test_the_probe_reads_no_further_than_it_says () =
  List.iter
    (fun bytes ->
      Alcotest.(check int)
        "every measured prefix is the probe length"
        Overlay.audio_container_probe_bytes
        (String.length bytes))
    [ wav; flac; mp3_with_id3; mp3_frame; webm; ogg_opus; aifc; m4a ]

let test_a_short_prefix_names_nothing_it_has_not_seen () =
  Alcotest.check container "empty" Overlay.Unrecognized
    (Overlay.audio_container_of_leading_bytes "");
  Alcotest.check container "RIFF without WAVE" Overlay.Unrecognized
    (Overlay.audio_container_of_leading_bytes "RIFF\x24\x00\x00\x00");
  Alcotest.check container "Ogg without the Opus header" Overlay.Unrecognized
    (Overlay.audio_container_of_leading_bytes (String.sub ogg_opus 0 27))

(* The transport, with a script standing in for whisper-cli. The script writes
   a mark before it answers, so a refusal that happened after spawning would
   leave the mark behind. *)

let with_temp_dir f =
  let dir = Filename.temp_file "masc-voice-container-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter (fun name -> Sys.remove (Filename.concat dir name)) (Sys.readdir dir);
      Unix.rmdir dir)
    (fun () -> f dir)

let with_process_runtime f =
  Eio_main.run
  @@ fun env ->
  Process_eio.init
    ~cwd_default:(Eio.Stdenv.cwd env)
    ~proc_mgr:(Eio.Stdenv.process_mgr env)
    ~clock:(Eio.Stdenv.clock env);
  f ()

let write path contents =
  let channel = open_out_bin path in
  output_string channel contents;
  close_out channel

let transcriber_in dir =
  let mark = Filename.concat dir "ran" in
  let script = Filename.concat dir "whisper-cli" in
  write script (Printf.sprintf "#!/bin/sh\n: > '%s'\necho heard\n" mark);
  Unix.chmod script 0o755;
  let endpoint =
    { Voice_config.id = "whisper-local"
    ; kind = Voice_config.Whisper_cli
    ; base_url = None
    ; mcp_url = None
    ; health_url = None
    ; api_key_env = None
    ; enabled = true
    ; timeout_seconds = None
    ; default_voice = None
    ; command = Some script
    }
  in
  endpoint, mark

let transcribe_bytes bytes =
  with_process_runtime
  @@ fun () ->
  with_temp_dir
  @@ fun dir ->
  let endpoint, mark = transcriber_in dir in
  let audio_file = Filename.concat dir "utterance" in
  write audio_file bytes;
  let result =
    Voice_bridge_transport.transcribe_via_command
      endpoint
      ~audio_file
      ~model:(Filename.concat dir "model.bin")
  in
  result, Sys.file_exists mark

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  go 0

let refused_before_running ~bytes ~named () =
  match transcribe_bytes bytes with
  | Ok transcript, _ -> Alcotest.failf "%s was transcribed as %S" named transcript
  | Error reason, ran ->
    Alcotest.(check bool) "whisper-cli was not run" false ran;
    Alcotest.(check bool)
      (Printf.sprintf "the container is named (%s)" reason)
      true
      (contains ~needle:("this audio is " ^ named) reason);
    Alcotest.(check bool)
      "and what it does read"
      true
      (contains ~needle:"reads WAV, FLAC or MP3" reason)

let run_through ~bytes ~named () =
  match transcribe_bytes bytes with
  | Error reason, _ -> Alcotest.failf "%s was refused: %s" named reason
  | Ok transcript, ran ->
    Alcotest.(check bool) "whisper-cli was run" true ran;
    Alcotest.(check string) "its answer comes back" "heard" transcript

let test_audio_that_cannot_be_read_is_not_run () =
  with_process_runtime
  @@ fun () ->
  with_temp_dir
  @@ fun dir ->
  let endpoint, mark = transcriber_in dir in
  match
    Voice_bridge_transport.transcribe_via_command
      endpoint
      ~audio_file:(Filename.concat dir "absent.wav")
      ~model:(Filename.concat dir "model.bin")
  with
  | Ok transcript -> Alcotest.failf "an absent file was transcribed as %S" transcript
  | Error reason ->
    Alcotest.(check bool) "whisper-cli was not run" false (Sys.file_exists mark);
    Alcotest.(check bool)
      (Printf.sprintf "says the audio could not be read (%s)" reason)
      true
      (contains ~needle:"the audio could not be read" reason)

let () =
  let case name f = Alcotest.test_case name `Quick f in
  Alcotest.run
    "voice container refusal"
    [ ( "the first bytes"
      , [ case "WAV is read" (recognised ~bytes:wav ~expected:Overlay.Wave ~reads:Overlay.Reads)
        ; case "FLAC is read" (recognised ~bytes:flac ~expected:Overlay.Flac ~reads:Overlay.Reads)
        ; case "MP3 with an ID3 tag is read"
            (recognised ~bytes:mp3_with_id3 ~expected:Overlay.Mp3 ~reads:Overlay.Reads)
        ; case "MP3 starting at a frame is read"
            (recognised ~bytes:mp3_frame ~expected:Overlay.Mp3 ~reads:Overlay.Reads)
        ; case "WebM is not read"
            (recognised ~bytes:webm ~expected:Overlay.Webm ~reads:Overlay.Does_not_read)
        ; case "Ogg Opus is not read"
            (recognised ~bytes:ogg_opus ~expected:Overlay.Ogg_opus
               ~reads:Overlay.Does_not_read)
        ; case "AIFF-C is not read"
            (recognised ~bytes:aifc ~expected:Overlay.Aiff ~reads:Overlay.Does_not_read)
        ; case "M4A is not read"
            (recognised ~bytes:m4a ~expected:Overlay.Mp4 ~reads:Overlay.Does_not_read)
        ; case "Ogg Vorbis is left to whisper-cli"
            (recognised ~bytes:ogg_vorbis ~expected:Overlay.Unrecognized
               ~reads:Overlay.Not_measured)
        ; case "an AAC frame is not taken for MP3"
            (recognised ~bytes:aac_adts ~expected:Overlay.Unrecognized
               ~reads:Overlay.Not_measured)
        ; case "the probe length covers every measured prefix"
            test_the_probe_reads_no_further_than_it_says
        ; case "a short prefix names nothing" test_a_short_prefix_names_nothing_it_has_not_seen
        ] )
    ; ( "before whisper-cli runs"
      , [ case "WebM is refused" (refused_before_running ~bytes:webm ~named:"WebM")
        ; case "Ogg Opus is refused" (refused_before_running ~bytes:ogg_opus ~named:"Ogg Opus")
        ; case "AIFF is refused" (refused_before_running ~bytes:aifc ~named:"AIFF")
        ; case "M4A is refused" (refused_before_running ~bytes:m4a ~named:"MP4/M4A")
        ; case "WAV is run" (run_through ~bytes:wav ~named:"WAV")
        ; case "an unrecognised container is run" (run_through ~bytes:ogg_vorbis ~named:"Ogg Vorbis")
        ; case "audio that cannot be read is not run" test_audio_that_cannot_be_read_is_not_run
        ] )
    ]
