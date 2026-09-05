(** When a capture decides speech has started, and when it decides it is over.

    sox used to decide both, through its [silence] filter, and neither could
    be observed while it was happening: with that filter the output file stays
    at zero bytes until the trigger fires, so nothing could read the level the
    decision was being made from. The decision moved into OCaml on 2026-09-04
    so that the meter an operator watches and the threshold that ends the
    recording are the same number.

    These check that number against a table of levels. No clock, no file, and
    no microphone: [advance_phase] is handed a level and a time and says what
    the capture does next. *)

open Alcotest
module Bridge = Masc.Voice_bridge
module Config = Voice_config

(* A room at -40 dB and a margin of 6 dB puts the trigger at -34; the quiet
   threshold sits at -36. Chosen so every level below reads as an obvious
   round number rather than something copied out of a run. *)
let room = Bridge.amplitude_of_db (-40.0)

let capture =
  { Config.calibration_seconds = 0.5
  ; trigger_margin_db = 6.0
  ; trailing_silence_seconds = 2.0
  ; speech_margin_db = 4.0
  ; noise_reduction = false
  }
;;

let at db = Some (Bridge.amplitude_of_db db)

let step ?(now = 0.0) ?level phase =
  Bridge.advance_phase ~capture ~now ~level:(Option.value level ~default:None) phase
;;

let phase_name = function
  | Bridge.Calibrating _ -> "calibrating"
  | Bridge.Listening _ -> "listening"
  | Bridge.Speaking { quiet_since = None; _ } -> "speaking"
  | Bridge.Speaking { quiet_since = Some _; _ } -> "speaking, gone quiet"
;;

let continues ~expect ?now ?level phase =
  match step ?now ?level phase with
  | Bridge.Continue next -> check string "phase" expect (phase_name next); next
  | Bridge.Finish _ -> failf "expected to continue in %s, the capture ended" expect
;;

let finishes ?now ?level phase =
  match step ?now ?level phase with
  | Bridge.Finish ending -> ending
  | Bridge.Continue next -> failf "expected the capture to end, it went to %s" (phase_name next)
;;

let listening = Bridge.Listening { floor = room }
let speaking = Bridge.Speaking { floor = room; quiet_since = None }

(* The recorder creates the file before it writes to it, and with a
   microphone that delivers nothing it never writes at all. Every capture
   starts here, so it cannot be an error. *)
let test_nothing_to_measure_leaves_the_phase_alone () =
  ignore (continues ~expect:"listening" ~level:None listening);
  ignore (continues ~expect:"calibrating" ~level:None (Bridge.Calibrating { until = 1.0; floor = None }))
;;

let test_the_room_does_not_start_a_capture () =
  ignore (continues ~expect:"listening" ~level:(at (-40.0)) listening)
;;

(* One dB under the margin is still the room. The boundary is checked from
   both sides so a later edit cannot widen it without moving this. *)
let test_just_under_the_margin_is_still_the_room () =
  ignore (continues ~expect:"listening" ~level:(at (-34.5)) listening)
;;

let test_clearing_the_margin_starts_the_capture () =
  ignore (continues ~expect:"speaking" ~level:(at (-33.0)) listening)
;;

(* The room is the quietest thing heard during calibration, not the average
   and not the last reading: a chair moving while the operator gets ready
   would otherwise set the threshold for the whole capture. *)
let test_calibration_keeps_the_quietest_reading () =
  let phase = Bridge.Calibrating { until = 1.0; floor = None } in
  let phase = continues ~expect:"calibrating" ~now:0.1 ~level:(at (-30.0)) phase in
  let phase = continues ~expect:"calibrating" ~now:0.2 ~level:(at (-45.0)) phase in
  let phase = continues ~expect:"calibrating" ~now:0.3 ~level:(at (-35.0)) phase in
  match continues ~expect:"listening" ~now:1.5 ~level:(at (-45.0)) phase with
  | Bridge.Listening { floor } ->
    check (float 0.5) "the quietest of the four" (-45.0) (Bridge.db_of_amplitude floor)
  | other -> failf "expected to be listening, got %s" (phase_name other)
;;

let test_calibration_does_not_end_before_its_window () =
  let phase = Bridge.Calibrating { until = 1.0; floor = None } in
  ignore (continues ~expect:"calibrating" ~now:0.9 ~level:(at (-40.0)) phase)
;;

(* Speech that stops is not speech that has ended. The clock starts on the
   first quiet reading and the capture stays open until it runs out. *)
let test_a_pause_starts_the_clock_but_does_not_end_the_capture () =
  ignore (continues ~expect:"speaking, gone quiet" ~now:5.0 ~level:(at (-40.0)) speaking)
;;

let test_speech_resuming_clears_the_pause () =
  let paused = Bridge.Speaking { floor = room; quiet_since = Some 5.0 } in
  ignore (continues ~expect:"speaking" ~now:5.5 ~level:(at (-20.0)) paused)
;;

(* The reason the pause is timed rather than acted on at once: a capture that
   stopped on the first gap would cut most sentences in half. *)
let test_a_pause_shorter_than_the_window_holds_the_capture_open () =
  let paused = Bridge.Speaking { floor = room; quiet_since = Some 5.0 } in
  ignore (continues ~expect:"speaking, gone quiet" ~now:6.9 ~level:(at (-40.0)) paused)
;;

let test_a_pause_that_outlasts_the_window_ends_the_capture () =
  let paused = Bridge.Speaking { floor = room; quiet_since = Some 5.0 } in
  match finishes ~now:7.0 ~level:(at (-40.0)) paused with
  | Bridge.Ended_after_speech -> ()
  | Bridge.Ended_without_speech _ | Bridge.Stopped_before_speech _ | Bridge.Discarded_after_speech _ ->
    fail "a capture that heard speech must end as having heard it"
;;

(* A capture cut off mid-sentence carries speech and is worth sending. One
   that never rose above the room is a recording of a room, and whisper
   answers those with a fluent sentence -- three captures of an empty room
   returned "감사합니다.", "감사합니다." and "네". *)
let test_a_deadline_during_speech_still_counts_as_speech () =
  match Bridge.end_at_deadline speaking with
  | Bridge.Ended_after_speech -> ()
  | Bridge.Ended_without_speech _ | Bridge.Stopped_before_speech _ | Bridge.Discarded_after_speech _ ->
    fail "speech already heard must survive the deadline"
;;

let test_a_deadline_before_any_speech_carries_no_transcript () =
  List.iter
    (fun phase ->
       match Bridge.end_at_deadline phase with
       | Bridge.Ended_without_speech _ -> ()
       | Bridge.Ended_after_speech | Bridge.Stopped_before_speech _ | Bridge.Discarded_after_speech _ ->
         failf "%s must not be transcribed" (phase_name phase))
    [ listening; Bridge.Calibrating { until = 1.0; floor = None } ]
;;

(* The key says "stop", not "cancel", and the reason to reach for it is
   usually that the sentence is finished and the trailing-silence wait is two
   seconds away. Discarding then costs the whole sentence again; transcribing
   something unwanted costs one deletion in a draft that has not been sent. *)
let test_a_stop_mid_sentence_keeps_what_was_said () =
  match Bridge.end_at_operator_stop Bridge.Keep_what_was_heard speaking with
  | Bridge.Ended_after_speech -> ()
  | Bridge.Ended_without_speech _ | Bridge.Stopped_before_speech _ | Bridge.Discarded_after_speech _ ->
    fail "a stop after speech must keep it"
;;

let test_a_stop_during_a_pause_keeps_what_was_said () =
  let paused = Bridge.Speaking { floor = room; quiet_since = Some 5.0 } in
  match Bridge.end_at_operator_stop Bridge.Keep_what_was_heard paused with
  | Bridge.Ended_after_speech -> ()
  | Bridge.Ended_without_speech _ | Bridge.Stopped_before_speech _ | Bridge.Discarded_after_speech _ ->
    fail "a pause inside a sentence is still a sentence"
;;

(* Before any speech it is an abort, and the transcriber must not see it:
   whisper answers a room with a fluent sentence. *)
let test_a_stop_before_any_speech_carries_no_transcript () =
  List.iter
    (fun phase ->
       match Bridge.end_at_operator_stop Bridge.Keep_what_was_heard phase with
       | Bridge.Stopped_before_speech _ -> ()
       | Bridge.Discarded_after_speech _ ->
         failf "%s heard no speech, so there was nothing to discard" (phase_name phase)
       | Bridge.Ended_after_speech | Bridge.Ended_without_speech _ ->
         failf "%s must not be transcribed" (phase_name phase))
    [ listening; Bridge.Calibrating { until = 1.0; floor = None } ]
;;

(* Esc, and the only place in the capture path where the operator says what
   they want instead of the levels inferring it. A recording that picked up
   something they did not mean to send has to be abandonable, and no amount of
   speech in it makes that less true. Mid-sentence the ending says a sentence
   was thrown away: reported as "nothing was heard", an operator who had just
   spoken went looking for a microphone fault that was not there. *)
let test_a_discard_mid_sentence_says_a_sentence_was_thrown_away () =
  List.iter
    (fun phase ->
       match Bridge.end_at_operator_stop Bridge.Discard phase with
       | Bridge.Discarded_after_speech floor ->
         check (float 0.5) "carrying the room it was speaking over" (-40.0)
           (Bridge.db_of_amplitude floor)
       | Bridge.Stopped_before_speech _ ->
         failf "a discard of %s is not a stop before speech" (phase_name phase)
       | Bridge.Ended_after_speech | Bridge.Ended_without_speech _ ->
         failf "a discard must abandon %s" (phase_name phase))
    [ speaking; Bridge.Speaking { floor = room; quiet_since = Some 5.0 } ]
;;

let test_a_discard_before_any_speech_is_a_plain_stop () =
  List.iter
    (fun phase ->
       match Bridge.end_at_operator_stop Bridge.Discard phase with
       | Bridge.Stopped_before_speech _ -> ()
       | Bridge.Discarded_after_speech _ ->
         failf "%s heard no speech, so there was nothing to discard" (phase_name phase)
       | Bridge.Ended_after_speech | Bridge.Ended_without_speech _ ->
         failf "a discard must abandon %s" (phase_name phase))
    [ listening; Bridge.Calibrating { until = 1.0; floor = None } ]
;;

(* The result JSON is read back through the bridge's own reader. These pin
   that every status it writes has a row, and that the one status it does not
   write is reported rather than folded into a silence -- the TUI's string
   match used to send a transcriber that answered with empty text to
   "nothing was heard". *)
let outcome_json ?(text = "") ?message ?endpoint_id status =
  `Assoc
    ([ "status", `String status; "text", `String text ]
     @ (match message with
        | Some m -> [ "message", `String m ]
        | None -> [])
     @
     match endpoint_id with
     | Some e -> [ "endpoint_id", `String e ]
     | None -> [])
;;

let test_every_status_reads_back_as_itself () =
  List.iter
    (fun status ->
       check bool
         (Bridge.capture_status_to_string status)
         true
         (Bridge.capture_status_of_string (Bridge.capture_status_to_string status)
          = Some status))
    [ Bridge.Transcribed; Bridge.No_audio; Bridge.Discarded ]
;;

let test_a_discard_reads_back_as_a_discard () =
  match
    Bridge.capture_outcome_of_json
      (outcome_json ~message:"recording discarded" "discarded")
  with
  | Bridge.Discarded_recording { message } ->
    check string "with its message" "recording discarded" message
  | Bridge.Transcript _
  | Bridge.Transcriber_returned_nothing _
  | Bridge.Nothing_heard _
  | Bridge.Unrecognized_status _ -> fail "a discard must read back as a discard"
;;

let test_an_empty_transcript_names_the_transcriber () =
  match
    Bridge.capture_outcome_of_json
      (outcome_json ~text:"  " ~endpoint_id:"whisper-local" "transcribed")
  with
  | Bridge.Transcriber_returned_nothing { endpoint_id } ->
    check (option string) "naming the endpoint that answered" (Some "whisper-local")
      endpoint_id
  | Bridge.Transcript _
  | Bridge.Discarded_recording _
  | Bridge.Nothing_heard _
  | Bridge.Unrecognized_status _ ->
    fail "an empty transcript is the transcriber's answer, not a silence"
;;

let test_a_transcript_reads_back_trimmed () =
  match
    Bridge.capture_outcome_of_json
      (outcome_json ~text:"  hello there \n" ~endpoint_id:"whisper-local" "transcribed")
  with
  | Bridge.Transcript { text; endpoint_id } ->
    check string "text" "hello there" text;
    check (option string) "endpoint" (Some "whisper-local") endpoint_id
  | Bridge.Transcriber_returned_nothing _
  | Bridge.Discarded_recording _
  | Bridge.Nothing_heard _
  | Bridge.Unrecognized_status _ -> fail "a transcript must read back as one"
;;

let test_a_silence_reads_back_with_its_levels () =
  match
    Bridge.capture_outcome_of_json
      (outcome_json ~message:"nothing rose above the room — room -40.0 dB" "no_audio")
  with
  | Bridge.Nothing_heard { message } ->
    check string "the message is what the operator sees" "nothing rose above the room — room -40.0 dB"
      message
  | Bridge.Transcript _
  | Bridge.Transcriber_returned_nothing _
  | Bridge.Discarded_recording _
  | Bridge.Unrecognized_status _ -> fail "a silence must read back as one"
;;

let test_an_unknown_status_is_reported_not_folded () =
  (match Bridge.capture_outcome_of_json (outcome_json "queued") with
   | Bridge.Unrecognized_status status -> check string "the status is named" "queued" status
   | Bridge.Transcript _
   | Bridge.Transcriber_returned_nothing _
   | Bridge.Discarded_recording _
   | Bridge.Nothing_heard _ -> fail "an unknown status must not become any known one");
  match Bridge.capture_outcome_of_json (`Assoc [ "text", `String "hello" ]) with
  | Bridge.Unrecognized_status _ -> ()
  | Bridge.Transcript _
  | Bridge.Transcriber_returned_nothing _
  | Bridge.Discarded_recording _
  | Bridge.Nothing_heard _ -> fail "text without a status is not a transcript"
;;

(* The two requests are only allowed to differ where there is speech. Before
   any, both abandon, so an operator who reaches for the wrong key loses
   nothing. *)
let test_stop_and_discard_differ_only_once_there_is_speech () =
  List.iter
    (fun phase ->
       check
         bool
         (phase_name phase)
         true
         (Bridge.end_at_operator_stop Bridge.Keep_what_was_heard phase
          = Bridge.end_at_operator_stop Bridge.Discard phase))
    [ listening; Bridge.Calibrating { until = 1.0; floor = None } ]
;;

(* Why a recording ended does not decide what happens to it -- what was heard
   does. The two endings agree wherever that question has the same answer. *)
let test_a_stop_and_a_deadline_agree_on_whether_there_is_speech () =
  let carries = function
    | Bridge.Ended_after_speech -> true
    | Bridge.Ended_without_speech _ | Bridge.Stopped_before_speech _ | Bridge.Discarded_after_speech _ -> false
  in
  List.iter
    (fun phase ->
       check
         bool
         (phase_name phase)
         (carries (Bridge.end_at_deadline phase))
         (carries (Bridge.end_at_operator_stop Bridge.Keep_what_was_heard phase)))
    [ speaking
    ; Bridge.Speaking { floor = room; quiet_since = Some 5.0 }
    ; listening
    ; Bridge.Calibrating { until = 1.0; floor = None }
    ]
;;

(* The room is carried out of the capture so the operator can be told what it
   was. Without it "nothing was heard" is the same sentence whether the
   microphone is dead, the room is loud, or the transcriber failed. *)
let test_an_ending_without_speech_carries_the_room_it_measured () =
  match Bridge.end_at_deadline listening with
  | Bridge.Ended_without_speech (Some floor) ->
    check (float 0.5) "the room it was listening against" (-40.0)
      (Bridge.db_of_amplitude floor)
  | Bridge.Ended_without_speech None -> fail "the room was measured, so it must be reported"
  | Bridge.Ended_after_speech | Bridge.Stopped_before_speech _ | Bridge.Discarded_after_speech _ ->
    fail "listening with no speech must end without speech"
;;

(* Calibration can end before a single reading arrives -- a microphone that
   delivers nothing keeps the capture there until the deadline. There is no
   room to report then, and reporting one would be inventing it. *)
let test_an_ending_during_calibration_reports_no_room_when_none_was_read () =
  match Bridge.end_at_deadline (Bridge.Calibrating { until = 1.0; floor = None }) with
  | Bridge.Ended_without_speech None -> ()
  | Bridge.Ended_without_speech (Some floor) ->
    failf "no reading arrived, yet %f was reported" floor
  | Bridge.Ended_after_speech | Bridge.Stopped_before_speech _ | Bridge.Discarded_after_speech _ ->
    fail "calibration with no speech must end without speech"
;;

let () =
  run
    "Voice capture phases"
    [ ( "starting"
      , [ test_case
            "nothing to measure leaves the phase alone"
            `Quick
            test_nothing_to_measure_leaves_the_phase_alone
        ; test_case "the room does not start a capture" `Quick test_the_room_does_not_start_a_capture
        ; test_case
            "just under the margin is still the room"
            `Quick
            test_just_under_the_margin_is_still_the_room
        ; test_case
            "clearing the margin starts the capture"
            `Quick
            test_clearing_the_margin_starts_the_capture
        ] )
    ; ( "reading the room"
      , [ test_case
            "calibration keeps the quietest reading"
            `Quick
            test_calibration_keeps_the_quietest_reading
        ; test_case
            "calibration does not end before its window"
            `Quick
            test_calibration_does_not_end_before_its_window
        ] )
    ; ( "ending"
      , [ test_case
            "a pause starts the clock but does not end the capture"
            `Quick
            test_a_pause_starts_the_clock_but_does_not_end_the_capture
        ; test_case "speech resuming clears the pause" `Quick test_speech_resuming_clears_the_pause
        ; test_case
            "a pause shorter than the window holds the capture open"
            `Quick
            test_a_pause_shorter_than_the_window_holds_the_capture_open
        ; test_case
            "a pause that outlasts the window ends the capture"
            `Quick
            test_a_pause_that_outlasts_the_window_ends_the_capture
        ] )
    ; ( "the operator stops it"
      , [ test_case
            "a stop mid-sentence keeps what was said"
            `Quick
            test_a_stop_mid_sentence_keeps_what_was_said
        ; test_case
            "a stop during a pause keeps what was said"
            `Quick
            test_a_stop_during_a_pause_keeps_what_was_said
        ; test_case
            "a stop before any speech carries no transcript"
            `Quick
            test_a_stop_before_any_speech_carries_no_transcript
        ; test_case
            "a discard mid-sentence says a sentence was thrown away"
            `Quick
            test_a_discard_mid_sentence_says_a_sentence_was_thrown_away
        ; test_case
            "a discard before any speech is a plain stop"
            `Quick
            test_a_discard_before_any_speech_is_a_plain_stop
        ; test_case
            "stop and discard differ only once there is speech"
            `Quick
            test_stop_and_discard_differ_only_once_there_is_speech
        ; test_case
            "a stop and a deadline agree on whether there is speech"
            `Quick
            test_a_stop_and_a_deadline_agree_on_whether_there_is_speech
        ] )
    ; ( "what the ending reports"
      , [ test_case
            "an ending without speech carries the room it measured"
            `Quick
            test_an_ending_without_speech_carries_the_room_it_measured
        ; test_case
            "an ending during calibration reports no room when none was read"
            `Quick
            test_an_ending_during_calibration_reports_no_room_when_none_was_read
        ] )
    ; ( "running out of time"
      , [ test_case
            "a deadline during speech still counts as speech"
            `Quick
            test_a_deadline_during_speech_still_counts_as_speech
        ; test_case
            "a deadline before any speech carries no transcript"
            `Quick
            test_a_deadline_before_any_speech_carries_no_transcript
        ] )
    ; ( "reading the result back"
      , [ test_case "every status reads back as itself" `Quick test_every_status_reads_back_as_itself
        ; test_case "a discard reads back as a discard" `Quick test_a_discard_reads_back_as_a_discard
        ; test_case
            "an empty transcript names the transcriber"
            `Quick
            test_an_empty_transcript_names_the_transcriber
        ; test_case "a transcript reads back trimmed" `Quick test_a_transcript_reads_back_trimmed
        ; test_case
            "a silence reads back with its levels"
            `Quick
            test_a_silence_reads_back_with_its_levels
        ; test_case
            "an unknown status is reported, not folded"
            `Quick
            test_an_unknown_status_is_reported_not_folded
        ] )
    ]
;;
