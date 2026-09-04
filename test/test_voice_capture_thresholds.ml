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
    later edit that widens either one has to answer the same numbers. *)

open Alcotest
module Bridge = Masc.Voice_bridge

(* Measured 2026-09-03/04, laptop built-in microphone, ordinary speaking
   voice. RMS and peak are recorded separately because the two margins here
   read different ones, and the defect this file exists for was reading one
   where the other was meant. *)
let room_peak_percent = 4.48
let speech_peak_percent = 100.0
let room_rms_percent = 1.18
let speech_rms_percent = 11.9

(* Two RMS passes minutes apart, which is where the "the floor moves" fact
   comes from. *)
let floor_pass_one_db = -37.2
let floor_pass_two_db = -26.3

let db_ratio a b = 20.0 *. log10 (a /. b)
let peak_separation_db = db_ratio speech_peak_percent room_peak_percent
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
    (drift > Bridge.trigger_margin_db)
;;

(* The trigger is a peak margin because sox's silence filter reads peak. Room
   and voice are 27 dB apart there, so it only has to leave the room behind. *)
let test_the_trigger_clears_the_room_without_swallowing_speech () =
  check
    bool
    (Printf.sprintf
       "trigger margin fits under the %.1f dB peak separation"
       peak_separation_db)
    true
    (Bridge.trigger_margin_db < peak_separation_db);
  check
    bool
    "and still sits clear of the room rather than on it"
    true
    (Bridge.trigger_margin_db > 0.0)
;;

(* The defect: peak and RMS are not interchangeable, and a trigger derived
   from the RMS floor lands below the room's peak — where sox reads it as
   sound, starts recording at once, and never sees silence again. *)
let test_an_rms_derived_trigger_would_sit_below_the_rooms_peak () =
  let from_rms = room_rms_percent *. (10.0 ** (Bridge.trigger_margin_db /. 20.0)) in
  check
    bool
    "a trigger computed from RMS is under the room's peak"
    true
    (from_rms < room_peak_percent);
  let from_peak = room_peak_percent *. (10.0 ** (Bridge.trigger_margin_db /. 20.0)) in
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

(* A capture can start on a transient and then carry nothing. The gate is
   therefore lower than the trigger: it refuses on the average of the whole
   capture, not on whatever started it. *)
(* The gate reads RMS on both sides, so it answers to the RMS separation
   rather than the peak one. It is not compared against the trigger: the two
   margins measure different levels and an ordering between them says nothing. *)
let test_the_speech_gate_fits_the_rms_separation () =
  check
    bool
    (Printf.sprintf
       "gate margin fits under the %.1f dB RMS separation"
       rms_separation_db)
    true
    (Bridge.speech_margin_db < rms_separation_db);
  check
    bool
    "and above zero, so room tone alone does not pass"
    true
    (Bridge.speech_margin_db > 0.0)
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
            "the speech gate fits the rms separation"
            `Quick
            test_the_speech_gate_fits_the_rms_separation
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
