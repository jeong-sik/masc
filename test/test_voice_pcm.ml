(** Reading the level of a capture while the recorder still holds the file.

    This exists because sox cannot. Measured against a live [rec] on
    2026-09-04: [stat] on a file whose header carries no length fails with
    "RIFF header not found", and [trim -0.4] fails with "Position is relative
    to end of audio, but audio length is unknown". Both are the normal state
    of every capture until the recorder closes it, which is exactly the span a
    level meter has to cover.

    The numbers here are constructed rather than recorded, so each one has an
    arithmetic answer the test can state. That the reader agrees with sox on
    real audio was checked separately: a two-second capture read 0.010424
    against sox's 0.010424. *)

open Alcotest
module Pcm = Masc.Voice_pcm

(* A header that is not 44 bytes. The recorder wrote 80 in one measured case,
   so a reader that assumes the textbook size decodes its own header as audio.
   The padding sits in a chunk of its own so the file stays a valid WAV. *)
let wav_of_samples ?(declared_length = None) ?(pad_chunk_bytes = 0) samples =
  let data = Buffer.create (List.length samples * 2) in
  List.iter
    (fun sample ->
       let raw = if sample < 0 then sample + 65_536 else sample in
       Buffer.add_char data (Char.chr (raw land 0xff));
       Buffer.add_char data (Char.chr ((raw lsr 8) land 0xff)))
    samples;
  let data = Buffer.contents data in
  let le32 value =
    let buffer = Bytes.create 4 in
    Bytes.set_uint8 buffer 0 (value land 0xff);
    Bytes.set_uint8 buffer 1 ((value lsr 8) land 0xff);
    Bytes.set_uint8 buffer 2 ((value lsr 16) land 0xff);
    Bytes.set_uint8 buffer 3 ((value lsr 24) land 0xff);
    Bytes.to_string buffer
  in
  let le16 value =
    let buffer = Bytes.create 2 in
    Bytes.set_uint8 buffer 0 (value land 0xff);
    Bytes.set_uint8 buffer 1 ((value lsr 8) land 0xff);
    Bytes.to_string buffer
  in
  let fmt =
    "fmt " ^ le32 16 ^ le16 1 ^ le16 1 ^ le32 16_000 ^ le32 32_000 ^ le16 2 ^ le16 16
  in
  let pad =
    if pad_chunk_bytes = 0
    then ""
    else "LIST" ^ le32 pad_chunk_bytes ^ String.make pad_chunk_bytes '\000'
  in
  let declared =
    match declared_length with
    | Some length -> length
    | None -> String.length data
  in
  let body = "WAVE" ^ fmt ^ pad ^ "data" ^ le32 declared ^ data in
  "RIFF" ^ le32 (String.length body) ^ body
;;

let write_wav contents =
  let path = Filename.temp_file "masc_pcm_test_" ".wav" in
  let channel = open_out_bin path in
  output_string channel contents;
  close_out channel;
  path
;;

let with_wav contents f =
  let path = write_wav contents in
  Fun.protect ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ()) (fun () -> f path)
;;

let rms = testable Fmt.float (fun a b -> Float.abs (a -. b) < 1e-6)

let read ?window_seconds path =
  match Pcm.tail_rms ?window_seconds path with
  | Ok value -> value
  | Error message -> failf "expected a level, got %S" message
;;

(* A square wave at a known amplitude has that amplitude as its RMS, so the
   expected value is the input rather than a number copied out of a run. *)
let test_a_constant_amplitude_reads_as_that_amplitude () =
  let samples = List.init 1600 (fun index -> if index mod 2 = 0 then 3_277 else -3_277) in
  with_wav (wav_of_samples samples) (fun path ->
    check rms "3277/32768" (3_277.0 /. 32_768.0) (read ~window_seconds:0.1 path))
;;

(* The recorder writes the length field when it closes the file. Every read
   before that sees zero, and a reader that trusts it measures nothing. *)
let test_a_length_field_of_zero_does_not_hide_the_audio () =
  let samples = List.init 1600 (fun _ -> 1_000) in
  with_wav (wav_of_samples ~declared_length:(Some 0) samples) (fun path ->
    check rms "1000/32768" (1_000.0 /. 32_768.0) (read ~window_seconds:0.1 path))
;;

let test_a_header_longer_than_44_bytes_is_still_found () =
  let samples = List.init 1600 (fun _ -> 2_000) in
  with_wav (wav_of_samples ~pad_chunk_bytes:36 samples) (fun path ->
    check rms "2000/32768" (2_000.0 /. 32_768.0) (read ~window_seconds:0.1 path))
;;

(* The reason the window exists. A capture that has been quiet for ten seconds
   and is loud right now must read loud: an average over the whole file would
   report the silence and the meter would lag the speaker by the length of
   their own utterance. *)
let test_the_window_reads_the_present_not_the_whole_file () =
  let quiet = List.init 16_000 (fun _ -> 100) in
  let loud = List.init 1_600 (fun _ -> 8_000) in
  with_wav
    (wav_of_samples (quiet @ loud))
    (fun path ->
       check rms "the last tenth of a second" (8_000.0 /. 32_768.0) (read ~window_seconds:0.1 path);
       (* Same file, whole-file window: the quiet dominates, which is what a
          meter must not report. *)
       let whole = read ~window_seconds:2.0 path in
       check bool "a whole-file read is far quieter" true (whole < 3_000.0 /. 32_768.0))
;;

(* Shorter than the window is the first moment of every capture. *)
let test_a_file_shorter_than_the_window_is_measured_whole () =
  let samples = List.init 160 (fun _ -> 4_000) in
  with_wav (wav_of_samples samples) (fun path ->
    check rms "4000/32768" (4_000.0 /. 32_768.0) (read ~window_seconds:1.0 path))
;;

(* [Filename.temp_file] creates the file, and the recorder may not write to it
   for a while -- or ever, if the speaker never triggers it. That is a state to
   report, not a fault to raise. *)
let test_an_empty_file_reports_that_there_is_no_audio_yet () =
  with_wav "" (fun path ->
    match Pcm.tail_rms path with
    | Ok value -> failf "expected no audio, read %f" value
    | Error message -> check string "reason" "no audio yet" message)
;;

let test_a_header_with_no_samples_reports_no_audio_yet () =
  with_wav (wav_of_samples []) (fun path ->
    match Pcm.tail_rms path with
    | Ok value -> failf "expected no audio, read %f" value
    | Error message -> check string "reason" "no audio yet" message)
;;

let test_a_missing_file_reports_rather_than_raises () =
  match Pcm.tail_rms "/nonexistent/masc-voice-pcm-test.wav" with
  | Ok value -> failf "expected an error, read %f" value
  | Error _ -> ()
;;

let () =
  run
    "Voice PCM"
    [ ( "levels"
    , [ test_case
          "a constant amplitude reads as that amplitude"
          `Quick
          test_a_constant_amplitude_reads_as_that_amplitude
      ; test_case
          "the window reads the present, not the whole file"
          `Quick
          test_the_window_reads_the_present_not_the_whole_file
      ; test_case
          "a file shorter than the window is measured whole"
          `Quick
          test_a_file_shorter_than_the_window_is_measured_whole
      ] )
  ; ( "a file the recorder still holds"
    , [ test_case
          "a length field of zero does not hide the audio"
          `Quick
          test_a_length_field_of_zero_does_not_hide_the_audio
      ; test_case
          "a header longer than 44 bytes is still found"
          `Quick
          test_a_header_longer_than_44_bytes_is_still_found
      ] )
  ; ( "nothing to read"
    , [ test_case
          "an empty file reports that there is no audio yet"
          `Quick
          test_an_empty_file_reports_that_there_is_no_audio_yet
      ; test_case
          "a header with no samples reports no audio yet"
          `Quick
          test_a_header_with_no_samples_reports_no_audio_yet
      ; test_case
          "a missing file reports rather than raises"
          `Quick
          test_a_missing_file_reports_rather_than_raises
      ] )
  ]
;;
