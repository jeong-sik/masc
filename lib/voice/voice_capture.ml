(* Voice_capture — microphone record + transcribe pipeline (E09 phase 2d).

    Extracted verbatim from voice_bridge.ml: the capture state machine
    (noise floor, level watch, phases), recorder spawn, and the
    record_and_transcribe entry point. Voice_bridge re-exports the
    historical surface. *)

let safe_agent_id = Voice_bridge_transport.safe_agent_id
let play_tone = Voice_player.play_tone
let transcribe_audio = Voice_probe.transcribe_audio
let capture_status_to_string = Voice_probe.capture_status_to_string
let capture_status_of_string = Voice_probe.capture_status_of_string
let ( let* ) = Result.bind
(** {1 Microphone record + transcribe} *)

let capture_config () =
  match Voice_config.load_detailed () with
  | Ok config -> Ok config.Voice_config.capture
  | Error Voice_config.Not_configured -> Ok Voice_config.default_capture
  | Error (Voice_config.Invalid reason) ->
    Error (Printf.sprintf "voice config is invalid, so no capture was started: %s" reason)
;;

(* How long past its own deadline a recorder's arm waits before giving up on
   it. The watcher, or the probe's trim, is what ends a recording; this only
   keeps one that somehow never ends from holding the microphone. *)
let recorder_arm_grace_seconds = 5.0

(* The opening of a capture the room profile is taken from. sox drops leading
   silence, so what survives at the start is this room during this capture. *)
let noise_profile_seconds = 0.25

(* How much of that profile sox's noisered subtracts, on its 0 to 1 scale.
   Measured on one sample at this setting: the floor went entirely and 81% of
   the speech stayed. *)
let noise_reduction_amount = 0.21

(* A bound on each sox pass over a finished capture, which is a file
   operation and not a recording. *)
let sox_pass_timeout_seconds = 15.0

(* How long a capture may run before it ends on its own, when the caller does
   not say. The keeper listen tool passes nothing when the model names no
   timeout, and its schema advertises this number. *)
let default_capture_timeout_seconds = 15.0

(* Every level in the capture path is an RMS amplitude on this scale, and dB
   here is dBFS. Measured 2026-09-04 on one workstation, an idle room read
   1.18% and an ordinary sentence 11.9% — 20 dB apart, which is the whole
   separation the thresholds have to work with. *)
let db_of_amplitude v = if v > 0.0 then 20.0 *. log10 v else neg_infinity
let amplitude_of_db d = if d = neg_infinity then 0.0 else 10.0 ** (d /. 20.0)

let run_voice_status = Voice_bridge_transport.run_voice_status

(* One short capture, recording the room as it is, for as long as a capture
   would spend calibrating. *)
let measure_noise_floor ~agent_id () =
  match capture_config () with
  | Error reason ->
    (* The capture that follows refuses with this same reason; a probe that
       ran anyway would measure a room for a capture that is not going to
       happen. *)
    Log.Transport.debug "voice noise floor not measured: %s" reason;
    None
  | Ok capture ->
    let calibration_seconds = capture.Voice_config.calibration_seconds in
    let probe =
      Filename.temp_file (Printf.sprintf "masc_nf_%s_" (safe_agent_id agent_id)) ".wav"
    in
    let cleanup () = try Sys.remove probe with Sys_error _ -> () in
    Eio_guard.protect ~finally:cleanup (fun () ->
         match
           run_voice_status
             ~timeout_sec:(calibration_seconds +. recorder_arm_grace_seconds)
             [ "rec"; "-q"; "-t"; "wav"; "-b"; "16"; "-e"; "signed-integer"; probe
             ; "rate"; string_of_int Voice_pcm.sample_rate; "channels"; "1"
             ; "trim"; "0"; Printf.sprintf "%.2f" calibration_seconds ]
         with
         | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
         | Unix.WEXITED 0, _ -> (
           (* RMS, and the whole probe rather than its tail: the capture that
              uses this floor compares RMS against it. A peak floor under an
              RMS level sits roughly a decade too high on room tone. *)
           match
             Voice_pcm.tail_rms ~window_seconds:calibration_seconds probe
           with
           | Ok amplitude -> Some amplitude
           | Error _ -> None)
         | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ -> None)
;;

(* Run [f] on a copy with the room subtracted; when either sox step fails,
   [f] runs on what the caller already had rather than on nothing.

   The profile comes from the capture's own leading moment, not a separate
   recording: sox drops leading silence, so what survives at the start is this
   room during this capture. A profile taken seconds earlier describes a room
   that may have changed, and subtracting the wrong profile removes speech. *)
let with_noise_reduced_audio ~audio_file ~f =
  (* The copy belongs to this scope, not its caller: both temporaries are
     removed when [f] returns, whatever it returns. The old shape handed the
     reduced file to its caller and nobody removed it — every noise-reduced
     capture left a masc_nr_*.wav behind forever. *)
  let profile = Filename.temp_file "masc_nr_" ".prof" in
  let reduced = Filename.temp_file "masc_nr_" ".wav" in
  let cleanup () =
    List.iter (fun p -> try Sys.remove p with Sys_error _ -> ()) [ profile; reduced ]
  in
  Eio_guard.protect ~finally:cleanup (fun () ->
    match
      run_voice_status
        ~timeout_sec:sox_pass_timeout_seconds
        [ "sox"; audio_file; "-n"; "trim"; "0"; Printf.sprintf "%.2f" noise_profile_seconds
        ; "noiseprof"; profile ]
    with
    | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
    | Unix.WEXITED 0, _ -> (
      match
        run_voice_status
          ~timeout_sec:sox_pass_timeout_seconds
          [ "sox"; audio_file; reduced; "noisered"; profile
          ; Printf.sprintf "%.2f" noise_reduction_amount ]
      with
      | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
      | Unix.WEXITED 0, _ -> f reduced
      | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ -> f audio_file)
    | (Unix.WEXITED _ | Unix.WSIGNALED _ | Unix.WSTOPPED _), _ -> f audio_file)
;;

(* How often the level is re-read while recording. Each read is a seek and a
   few thousand multiplications rather than a subprocess, so this can be far
   faster than the half-second the meter used to manage. *)
let level_poll_seconds = 0.1

(* The span each level is measured over. Shorter reads chatter on the gaps
   between consonants inside a single word; longer ones smear the end of an
   utterance into the silence after it and delay the stop by their own width. *)
let level_window_seconds = 0.3

(* Which of the three ways a recording can end. Only the first is speech; the
   other two carry no transcript and must not reach the endpoint, because
   whisper answers silence with a sentence. *)
(* Where the watcher is in the recording. A variant rather than a pair of
   flags: "calibrating" and "speaking" carry different fields, and no state
   outside these three exists. *)
type level_phase =
  | Calibrating of { until : float; floor : float option }
  | Listening of { floor : float }
  | Speaking of { floor : float; quiet_since : float option }

(* What the operator asked for when they ended a recording early. Two ways to
   end it, and a single variant rather than two flags: "stop" and "discard"
   cannot both be true, and a pair of booleans would let them be. *)
type stop_request =
  | Keep_what_was_heard
  | Discard

(* Why a recording is over. What is done with it turns on two things: whether
   speech was heard, and whether the operator said they do not want it. A
   capture stopped mid-sentence by the stop key carries a sentence; one
   abandoned mid-sentence by the discard key carried one and threw it away,
   and must say so -- reporting it as nothing heard tells an operator who
   just said something that their microphone is dead. *)
type capture_end =
  | Ended_after_speech
  (* These carry the room the capture measured, when it got that far. An
     operator whose draft came back empty cannot tell a microphone that heard
     nothing from a transcriber that failed, and the two levels are the
     difference: "you were at -38, speech had to clear -32" is a thing to act
     on, where "nothing was heard" is not. [None] when the recorder never
     produced a sample to measure. *)
  | Ended_without_speech of float option
  | Stopped_before_speech of float option
  (* The floor is always known here: speech was heard, so calibration had
     finished. *)
  | Discarded_after_speech of float

(* Watches the recording as it is written and decides when it is over.

   sox's own [silence] filter used to make this decision. It could not be
   observed while it was making it: with that filter the output file stays at
   zero bytes until the trigger fires, so a meter reading the file reported
   nothing for exactly as long as the operator needed to see something. The
   decision and the display now read the same number, once per poll. *)
(* What one reading does to the watcher, with no clock and no file in it. The
   loop below supplies the time and the level; every choice the capture makes
   is here, where it can be checked against a table of levels rather than a
   microphone. *)
type level_step =
  | Continue of level_phase
  | Finish of capture_end

let advance_phase ~(capture : Voice_config.capture_config) ~now ~level phase =
  let trigger_at floor =
    db_of_amplitude floor +. capture.Voice_config.trigger_margin_db
  in
  let quiet_below floor =
    db_of_amplitude floor +. capture.Voice_config.speech_margin_db
  in
  match level, phase with
  (* No audio to measure yet. The recorder creates the file before it writes
     to it, so this is the state every capture starts in. *)
  | None, phase -> Continue phase
  (* The room is read from the capture's own opening rather than a probe
     before it: whatever the recorder hears before speech starts is this room
     during this recording, and it costs no extra second. The smallest reading
     wins, so a door closing during calibration does not raise the threshold
     for the rest of the capture. *)
  | Some amplitude, Calibrating { until; floor } ->
    let floor =
      match floor with
      | Some previous -> Some (Float.min previous amplitude)
      | None -> Some amplitude
    in
    (match floor with
     | Some floor when now >= until -> Continue (Listening { floor })
     | Some _ | None -> Continue (Calibrating { until; floor }))
  | Some amplitude, Listening { floor } ->
    if db_of_amplitude amplitude > trigger_at floor
    then Continue (Speaking { floor; quiet_since = None })
    else Continue (Listening { floor })
  | Some amplitude, Speaking { floor; quiet_since } ->
    if db_of_amplitude amplitude < quiet_below floor
    then (
      match quiet_since with
      | Some since when now -. since >= capture.Voice_config.trailing_silence_seconds
        -> Finish Ended_after_speech
      | Some _ -> Continue (Speaking { floor; quiet_since })
      | None -> Continue (Speaking { floor; quiet_since = Some now }))
    else
      (* Speech resumed. The pause was inside the sentence. *)
      Continue (Speaking { floor; quiet_since = None })
;;

(* What a deadline means depends on where the watcher got to. A capture cut
   off mid-sentence still carries speech and is worth transcribing; one that
   never heard any is a recording of a room, and whisper answers those with a
   sentence. *)
let end_at_deadline = function
  | Speaking _ -> Ended_after_speech
  | Calibrating { floor; _ } -> Ended_without_speech floor
  | Listening { floor } -> Ended_without_speech (Some floor)
;;

(* The same question, asked of the other way a recording ends. The key says
   "stop", and the reason to press it is usually that the speaker has finished
   and does not want to sit out the trailing-silence wait; discarding then
   costs them the sentence again, while transcribing something unwanted costs
   one deletion in a draft that has not been sent.

   Before any speech it is an abort, and yields nothing -- which is also what
   keeps a room away from a transcriber that answers silence with a sentence. *)
let end_at_operator_stop request phase =
  match request, phase with
  (* An explicit discard is the operator saying they do not want it, which no
     amount of speech overrides. Nothing else in the capture path can say
     that: every other ending is inferred from levels. It is its own ending
     because what was thrown away was a sentence, and the operator is told
     that rather than that nothing was heard. *)
  | Discard, Speaking { floor; _ } -> Discarded_after_speech floor
  | Discard, Calibrating { floor; _ } -> Stopped_before_speech floor
  | Discard, Listening { floor } -> Stopped_before_speech (Some floor)
  | Keep_what_was_heard, Speaking _ -> Ended_after_speech
  | Keep_what_was_heard, Calibrating { floor; _ } -> Stopped_before_speech floor
  | Keep_what_was_heard, Listening { floor } -> Stopped_before_speech (Some floor)
;;

type capture_level =
  | Level_observed of float
  | Level_unavailable
  | Meter_closed

let watch_capture_level
      ~clock
      ~audio_file
      ~(capture : Voice_config.capture_config)
      ~noise_floor
      ~on_level
      ~should_stop
      ~deadline
  =
  (* Nothing but the clock, the file, and the operator's key is decided here.
     [advance_phase] holds every threshold. *)
  let rec step phase =
    Eio.Time.sleep clock level_poll_seconds;
    let now = Eio.Time.now clock in
    match should_stop () with
    | Some request -> end_at_operator_stop request phase
    | None ->
    if now >= deadline
    then end_at_deadline phase
    else (
      let level =
        match Voice_pcm.tail_rms ~window_seconds:level_window_seconds audio_file with
        | Ok amplitude -> Some amplitude
        | Error _ -> None
      in
      on_level
        (match level with
         | Some amplitude -> Level_observed (db_of_amplitude amplitude)
         | None -> Level_unavailable);
      match advance_phase ~capture ~now ~level phase with
      | Finish ending -> ending
      | Continue next ->
        (* Said once, when the room stops being a guess. *)
        (match phase, next with
         | Calibrating _, Listening { floor } ->
           Log.Transport.debug
             "voice capture: room %.1f dB, speech above %.1f dB"
             (db_of_amplitude floor)
             (db_of_amplitude floor +. capture.Voice_config.trigger_margin_db)
         | (Calibrating _, (Calibrating _ | Speaking _)) | ((Listening _ | Speaking _), _) -> ());
        step next)
  in
  let start = Eio.Time.now clock in
  let floor = Option.map (fun f -> f) noise_floor in
  match floor with
  (* A caller that has just captured for the same agent already knows the
     room, and re-measuring it would delay this capture by the calibration
     window for an answer it has. *)
  | Some floor -> step (Listening { floor })
  | None ->
    step
      (Calibrating
          { until = start +. capture.Voice_config.calibration_seconds; floor = None })
;;

(* What a capture that carries no speech says for itself.

   The levels are in it because without them the answer is not actionable: an
   empty draft looks the same whether the microphone heard nothing, the room
   rose over the threshold, or the transcriber failed. With them it is a
   number and a target, and an operator who reads "-38.2 dB, speech had to
   clear -32.2 dB" knows both that the capture ran and what to change. *)
let no_audio ~reason ~floor (capture : Voice_config.capture_config) =
  let detail =
    match floor with
    | Some floor ->
      Printf.sprintf
        "%s — room %.1f dB, speech had to clear %.1f dB"
        reason
        (db_of_amplitude floor)
        (db_of_amplitude floor +. capture.Voice_config.trigger_margin_db)
    (* The recorder produced nothing to measure, which is its own answer and a
       different one: not a room too loud but a microphone that delivered no
       samples at all. *)
    | None -> reason ^ " — the recorder produced no audio to measure"
  in
  `Assoc
    [ "status", `String (capture_status_to_string No_audio)
    ; "text", `String ""
    ; "message", `String detail
    ]
;;

(* What a discarded capture says for itself. It heard speech -- that is what
   separates it from {!no_audio} -- so the levels that explain a silence are
   not the point; that a sentence was thrown away on purpose is. *)
let discarded_json =
  `Assoc
    [ "status", `String (capture_status_to_string Discarded)
    ; "text", `String ""
    ; "message", `String "recording discarded — speech was heard and not transcribed"
    ]
;;

(* The capture result read back as one of the things it can be. This is the
   reader for the JSON {!record_and_transcribe} returns, kept next to the
   writers so the two cannot drift: a status neither knows is reported as
   such, and a result with no status at all is its own answer; neither is
   folded into "nothing was heard". *)
type capture_outcome =
  | Transcript of
      { text : string
      ; endpoint_id : string option
      }
  | Transcriber_returned_nothing of { endpoint_id : string option }
  | Nothing_heard of { message : string }
  | Discarded_recording of { message : string }
  | Unrecognized_status of string
  | Status_absent

let capture_outcome_of_json json =
  let field name = Json_util.get_string json name in
  let nonempty name = Json_util.get_string_nonempty json name in
  let message ~fallback = Option.value (nonempty "message") ~default:fallback in
  match field "status" with
  | None -> Status_absent
  | Some raw ->
    (match capture_status_of_string raw with
     | None -> Unrecognized_status raw
     | Some Transcribed ->
       (match nonempty "text" with
        | Some text -> Transcript { text = String.trim text; endpoint_id = nonempty "endpoint_id" }
        | None -> Transcriber_returned_nothing { endpoint_id = nonempty "endpoint_id" })
     | Some No_audio -> Nothing_heard { message = message ~fallback:"nothing was heard" }
     | Some Discarded ->
       Discarded_recording { message = message ~fallback:"recording discarded" })
;;

(* What a capture says when its recorder never started. A fresh mac has no
   sox, and sox is what carries rec, so the common case is named with what to
   run; every other refusal keeps the runner's own sentence, because guessing a
   cause for a permission or cwd failure would send the operator to install
   something they already have. *)
(* What a recorder that ran and failed says. The exit code alone is the number
   this path used to answer with; sox names its cause on stderr, so when it
   said something the failure says that. The code stays when the recorder left
   no reason behind, so the message never invents one. *)
let rec_exit_message ?device ~code ~stdout ~stderr () =
  let device_note =
    match device with
    | Some device -> Printf.sprintf " (the device picked: %s)" device
    | None -> ""
  in
  let blank text = String.trim text = "" in
  (* One line at most, and only its first: a chatty recorder's transcript is
     not a failure reason, and the operator copies this sentence into a report.
     200 characters holds sox's own "can't open input ..." lines and keeps a
     hostile tool from pushing the sentence into wrapping. *)
  let reason text =
    let trimmed = String.trim text in
    let line =
      match String.index_opt trimmed '\n' with
      | Some index -> String.sub trimmed 0 index
      | None -> trimmed
    in
    if String.length line > 200 then String.sub line 0 200 ^ "..." else line
  in
  match (blank stderr, blank stdout) with
  | false, _ -> Printf.sprintf "rec exit %d: %s%s" code (reason stderr) device_note
  | true, false ->
    Printf.sprintf "rec exit %d: %s%s" code (reason stdout) device_note
  | true, true -> Printf.sprintf "rec exit %d%s" code device_note
;;
(* One place says why a recorder is not starting: a missing program is named
   with the install that carries it, and a device the operator picked is named
   when there was one -- an operator whose pick no longer exists should be
   told that and not that the recorder itself is broken. *)
let recorder_refusal_message ?device (refusal : Process_eio.spawn_refusal) =
  match refusal with
  | Process_eio.Executable_not_found program ->
    Printf.sprintf
      "%s is not installed; it comes with sox. `masc prerequisite-actions \
       whisper` names the install."
      program
  (* The same sentence every other voice command gives for a refusal that is
     not a missing program -- one wording for "could not start", kept where the
     transport keeps it. A device the operator picked is named when there was
     one: an operator who no longer has the device they picked should be told
     that and not that the recorder itself is broken. *)
  | (Process_eio.Empty_argv
    | Process_eio.Spawn_failed _
    | Process_eio.Child_setup_failed _
    | Process_eio.Cwd_unavailable _ as refusal) ->
    Voice_bridge_transport.command_refusal_reason
      ~command:
        (match device with
         | Some device -> Printf.sprintf "recorder for %S" device
         | None -> "the recorder")
      refusal
;;

(* The recorder's argv. Pinned rather than left to sox, which chooses 32-bit
   when it is not told. The reader that measures this file decodes 16-bit, and
   a mismatch is not an error either side reports: it reads as noise. Measured
   2026-09-04, a 32-bit capture read 0.41 where sox said 0.011. *)
let rec_argv ~audio_file =
  [ "rec"
  ; "-q"
  ; "-t"
  ; "wav"
  ; "-b"
  ; "16"
  ; "-e"
  ; "signed-integer"
  ; audio_file
  ; "rate"
  ; string_of_int Voice_pcm.sample_rate
  ; "channels"
  ; "1"
  ]
;;

(* One place decides which device a capture opens: an [AUDIODEV] in the
   environment wins when it names a device, a blank one is no name and
   falls through, and the stored pick is next. The panel and every capture
   resolve through {!resolved_audio_device}, so what the panel names is
   what sox opens. *)
let resolved_audio_device ?(env = Unix.environment ()) ~pick () =
  let from_env =
    Array.find_map
      (fun kv ->
         if String.starts_with ~prefix:"AUDIODEV=" kv then
           Some (String.trim (String.sub kv 9 (String.length kv - 9)))
         else None)
      env
  in
  match from_env with
  | Some device when device <> "" -> Some device
  | _ -> pick

let record_and_transcribe
      ~agent_id
      ?(timeout_sec = default_capture_timeout_seconds)
      ?language_code
      ?noise_floor
      ?audio_device
      ?(on_level = fun (_ : capture_level) -> ())
      ?(should_stop = fun () -> None)
      ()
  =
  (* Refused here, before a tone is played or a microphone opened: a config
     that exists and does not parse names its reason. *)
  let* capture = capture_config () in
  let audio_file =
    Filename.temp_file (Printf.sprintf "masc_stt_%s_" (safe_agent_id agent_id)) ".wav"
  in
  (* Pinned rather than left to sox, which chooses 32-bit when it is not told.
     The reader that measures this file decodes 16-bit, and a mismatch is not
     an error either side reports: it reads as noise. Measured 2026-09-04, a
     32-bit capture read 0.41 where sox said 0.011. *)
  let rec_argv = rec_argv ~audio_file in
  (* The device the operator picked travels as AUDIODEV rather than as an
     argument, because rec is sox's alias for [sox -d] and AUDIODEV is its
     documented answer to "which device when -d is absent". Passing the child
     only the current environment plus this one assignment keeps every other
     knob the parent carries intact. *)
  let recorder_env =
    Option.map
      (fun device ->
         let inherited =
           Unix.environment ()
           |> Array.to_list
           |> List.filter (fun kv ->
                  not (String.starts_with ~prefix:"AUDIODEV=" kv))
         in
         (* Exactly one AUDIODEV travels. A duplicated name's interpretation is
            unspecified, and a blank inherited value must not shadow the device
            the operator picked -- either would open a different device than
            the panel names. *)
         Array.of_list (inherited @ [ Printf.sprintf "AUDIODEV=%s" device ]))
      audio_device
  in
  let cleanup () =
    try Sys.remove audio_file with
    | Sys_error _ -> ()
  in
  Eio_guard.protect ~finally:cleanup (fun () ->
    match Process_eio.get_clock () with
    | Error message -> Error (Printf.sprintf "voice capture has no clock: %s" message)
    | Ok clock ->
      play_tone 880.0;
      (* The recorder has no end of its own, so the watcher is what stops it:
         when the watcher returns, [Fiber.first] cancels the recording. The
         cancelled spawn sends sox SIGTERM and then waits, up to
         [Process_eio.child_exit_grace_seconds], for sox to close its pipes
         -- which it does on exit, after it has written the length into the
         WAV header. SIGKILL follows only if the grace runs out.

         The wait is what keeps the tail: sox flushes about one stdio buffer
         on SIGTERM, and a SIGKILL in the same instant loses it -- a quarter
         second of a two-second recording, measured 2026-09-04. A discard
         pays the same wait although the file is removed right after:
         [Process_eio] stops a cancelled spawn one way, and a kill that skips
         the grace is not a path it offers.

         The recorder's own arm carries the same deadline so that a watcher
         that somehow never returns cannot leave a microphone open. *)
      let outcome =
        Eio.Fiber.first
          (fun () ->
             (* The typed runner, so a recorder that never started is told
                apart from one that ran and failed. The tuple runner folds
                every failure before the process -- not found, not
                permitted, a cwd that would not open -- into exit 127, and
                reading 127 as "not installed" would give some of them the
                wrong reason. Both runners spawn through the same drain, so
                the cancel grace that keeps the WAV tail is unchanged. *)
             match
               Process_eio.run_argv_with_status_split_or_refusal
                 ?env:recorder_env
                 ~timeout_sec:(timeout_sec +. recorder_arm_grace_seconds)
                 rec_argv
             with
             | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
             | exception exn ->
               Error (Printf.sprintf "rec exception: %s" (Printexc.to_string exn))
             | Error refusal ->
               Error (recorder_refusal_message ?device:audio_device refusal)
             (* The recorder has no end of its own, so reaching one means it
                stopped on its own arm without the watcher having decided
                anything. No floor was settled. *)
             | Ok (Unix.WEXITED 0, _, _) -> Ok (Ended_without_speech None)
             | Ok (Unix.WEXITED code, stdout, stderr) ->
               Error
                 (rec_exit_message ?device:audio_device ~code ~stdout ~stderr ())
             | Ok ((Unix.WSIGNALED _ | Unix.WSTOPPED _), _, _) ->
               Error "rec process failed")
          (fun () ->
             Ok
               (watch_capture_level
                  ~clock
                  ~audio_file
                  ~capture
                  ~noise_floor
                  ~on_level
                  ~should_stop
                  ~deadline:(Eio.Time.now clock +. timeout_sec)))
      in
      play_tone 440.0;
      on_level Meter_closed;
      (match outcome with
       | Error message -> Error message
       | Ok (Stopped_before_speech floor) ->
         (* Stopped before anything was said. Distinct from the message below
            because nothing waited for speech here -- saying the room was too
            quiet would blame a microphone that was never given a chance. *)
         Ok (no_audio ~reason:"stopped before anything was said" ~floor capture)
       | Ok (Discarded_after_speech _) ->
         (* The operator abandoned a recording that had speech in it. Not a
            silence: the microphone worked, and saying otherwise would send
            them looking for a fault that is not there. *)
         Ok discarded_json
       | Ok (Ended_without_speech floor) ->
         (* The gate that keeps a room away from the transcriber. It used to
            re-read the finished file and compare its average against its own
            opening; now the watcher has already compared every tenth of a
            second against the room and knows no reading cleared it. *)
         Ok (no_audio ~reason:"nothing rose above the room" ~floor capture)
       | Ok Ended_after_speech ->
         if capture.Voice_config.noise_reduction
         then
           with_noise_reduced_audio ~audio_file ~f:(fun audio_file ->
               transcribe_audio ~audio_file ?language_code ())
         else transcribe_audio ~audio_file ?language_code ()))
;;

module For_testing = struct
  let with_timeout = Voice_speak.with_timeout
end
