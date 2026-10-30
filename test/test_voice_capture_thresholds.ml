(** What a microphone capture has to clear before it is transcribed.

    Two numbers decide it, and both were constants until a room was measured
    against them. The recording threshold was a literal 1% of full scale
    (about -40 dBFS). Measured on one workstation 2026-09-03: the noise floor
    sat at -37.2 dB on one pass and -26.3 dB on another a few minutes later.
    Both are above -40, so sox's silence filter saw sound continuously —
    recording began at once and the trailing-silence condition never came
    true. Every capture ran to its timeout and handed the transcriber a room.

    What the transcriber does with a room is the second half. Three captures
    of an empty room, sent to the local whisper endpoint, came back
    "감사합니다.", "감사합니다." and "네" — fluent Korean for an operator who
    said nothing. That is the "wrong voice" an operator sees, and no byte
    count separates it from speech: a capture that ran to its timeout on room
    tone is large.

    These pin the two margins against the separation actually measured, so a
    later edit that widens either one has to answer the same numbers. The
    margins are read from {!Voice_config.default_capture}, the one place they
    are defined: a copy exported from [Voice_bridge] went on describing the
    trigger as a peak margin after the capture had moved to RMS. *)

open Alcotest
module Bridge = Masc.Voice_bridge

let capture = Voice_config.default_capture
let trigger_margin_db = capture.Voice_config.trigger_margin_db
let speech_margin_db = capture.Voice_config.speech_margin_db

(* Measured 2026-09-03/04, laptop built-in microphone, ordinary speaking
   voice. RMS and peak are recorded separately because the defect this file
   exists for was reading one where the other was meant; both margins now
   read RMS. *)
let room_peak_percent = 4.48
let speech_peak_percent = 100.0
let room_rms_percent = 1.18
let speech_rms_percent = 11.9

(* Two RMS passes minutes apart, which is where the "the floor moves" fact
   comes from. *)
let floor_pass_one_db = -37.2
let floor_pass_two_db = -26.3

let db_ratio a b = 20.0 *. log10 (a /. b)
let rms_separation_db = db_ratio speech_rms_percent room_rms_percent

(* The floor is read per capture rather than configured because it moved this
   far in one room between two passes. A single configured number would have
   been wrong for one of them. *)
let test_the_floor_moves_more_than_either_margin () =
  let drift = Float.abs (floor_pass_two_db -. floor_pass_one_db) in
  check
    bool
    "the room moved further than the trigger margin between two passes"
    true
    (drift > trigger_margin_db)
;;

(* The trigger reads RMS, where room and voice are 20 dB apart on this
   microphone, so it only has to leave the room behind. *)
let test_the_trigger_clears_the_room_without_swallowing_speech () =
  check
    bool
    (Printf.sprintf
       "trigger margin fits under the %.1f dB RMS separation"
       rms_separation_db)
    true
    (trigger_margin_db < rms_separation_db);
  check
    bool
    "and still sits clear of the room rather than on it"
    true
    (trigger_margin_db > 0.0)
;;

(* The defect, kept as the thing being answered: peak and RMS are not
   interchangeable. A trigger derived from the RMS floor lands below the
   room's peak — where a peak-reading filter sees sound at once and never
   sees silence again. That is why the capture reads RMS on both sides now,
   rather than handing an RMS-derived threshold to sox's silence filter. *)
let test_an_rms_derived_trigger_would_sit_below_the_rooms_peak () =
  let from_rms = room_rms_percent *. (10.0 ** (trigger_margin_db /. 20.0)) in
  check
    bool
    "a trigger computed from RMS is under the room's peak"
    true
    (from_rms < room_peak_percent);
  let from_peak = room_peak_percent *. (10.0 ** (trigger_margin_db /. 20.0)) in
  check
    bool
    "and one computed from peak is above it"
    true
    (from_peak > room_peak_percent);
  check
    bool
    "while still under the voice"
    true
    (from_peak < speech_peak_percent)
;;

(* The end of speech: once a capture has started, the level has to fall back
   under room + this margin and stay there for the trailing silence. It reads
   RMS, the same basis as the trigger, so it answers to the RMS separation;
   and it sits below the trigger so the two thresholds are not one line that
   a hovering level would cross in both directions on every reading. *)
let test_the_speech_margin_fits_the_rms_separation () =
  check
    bool
    (Printf.sprintf
       "speech margin fits under the %.1f dB RMS separation"
       rms_separation_db)
    true
    (speech_margin_db < rms_separation_db);
  check
    bool
    "and above zero, so room tone alone does not count as speech going on"
    true
    (speech_margin_db > 0.0);
  check
    bool
    "and below the trigger, so starting and ending speech are two thresholds"
    true
    (speech_margin_db < trigger_margin_db)
;;

let approx name expected actual =
  check bool (Printf.sprintf "%s (%.4f vs %.4f)" name expected actual) true
    (Float.abs (expected -. actual) < 1e-9)
;;

let test_db_and_amplitude_round_trip () =
  List.iter
    (fun db -> approx "round trip" db (Bridge.db_of_amplitude (Bridge.amplitude_of_db db)))
    [ -60.0; -37.2; -26.3; -20.2; -6.0 ];
  (* Silence is the case the gate reads most often; it must not produce a
     number that compares as louder than the floor. *)
  check
    bool
    "zero amplitude is negative infinity, not a finite level"
    true
    (Bridge.db_of_amplitude 0.0 = Float.neg_infinity);
  approx "and maps back to zero" 0.0 (Bridge.amplitude_of_db Float.neg_infinity)
;;

(* The constant this replaced, kept as the thing being answered: 1% of full
   scale. Both measured floors are above it, which is why the old threshold
   never fired. *)
let test_the_old_constant_was_below_both_measured_floors () =
  let one_percent_db = Bridge.db_of_amplitude 0.01 in
  check
    bool
    "1% of full scale is below the quieter measured floor"
    true
    (one_percent_db < floor_pass_one_db);
  check
    bool
    "and below the louder one"
    true
    (one_percent_db < floor_pass_two_db)
;;

let () =
  run
    "Voice capture thresholds"
    [ ( "margins"
      , [ test_case
            "the floor moves more than either margin"
            `Quick
            test_the_floor_moves_more_than_either_margin
        ; test_case
            "the trigger clears the room without swallowing speech"
            `Quick
            test_the_trigger_clears_the_room_without_swallowing_speech
        ; test_case
            "the speech margin fits the rms separation"
            `Quick
            test_the_speech_margin_fits_the_rms_separation
        ; test_case
            "an rms-derived trigger would sit below the room's peak"
            `Quick
            test_an_rms_derived_trigger_would_sit_below_the_rooms_peak
        ] )
    ; ( "levels"
      , [ test_case "dB and amplitude round trip" `Quick test_db_and_amplitude_round_trip
        ; test_case
            "the old constant was below both measured floors"
            `Quick
            test_the_old_constant_was_below_both_measured_floors
        ] )
    ]
;;
