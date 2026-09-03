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

(* Measured 2026-09-03, laptop built-in microphone, ordinary speaking voice.
   Two passes minutes apart, each 2 s of room followed by a spoken sentence. *)
let floor_pass_one_db = -37.2
let speech_pass_one_db = -32.2
let floor_pass_two_db = -26.3
let speech_pass_two_db = -20.2

let separations = [ speech_pass_one_db -. floor_pass_one_db
                  ; speech_pass_two_db -. floor_pass_two_db
                  ]
;;

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

let test_the_trigger_clears_the_room_without_swallowing_speech () =
  List.iter
    (fun separation ->
       check
         bool
         (Printf.sprintf
            "trigger margin fits under a %.1f dB separation"
            separation)
         true
         (Bridge.trigger_margin_db < separation))
    separations;
  check
    bool
    "and still sits clear of the room rather than on it"
    true
    (Bridge.trigger_margin_db > 0.0)
;;

(* A capture can start on a transient and then carry nothing. The gate is
   therefore lower than the trigger: it refuses on the average of the whole
   capture, not on whatever started it. *)
let test_the_speech_gate_sits_below_the_trigger () =
  check
    bool
    "gate is below the trigger"
    true
    (Bridge.speech_margin_db < Bridge.trigger_margin_db);
  check
    bool
    "and above the floor, so room tone alone does not pass"
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
            "the speech gate sits below the trigger"
            `Quick
            test_the_speech_gate_sits_below_the_trigger
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
