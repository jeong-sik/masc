module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Voice_bridge = Masc.Voice_bridge

let report_voice_failure state ~keeper error =
  Masc_tui_collab_queue.Chat_notice.chat_notice state ~keeper_name:(Some keeper)
    ~kind:Masc_tui_collab_queue.Chat_notice.Notice_failure
    ("voice failed: " ^ error);
  T.set_last_action state (Some ("voice failed: " ^ error, Unix.gettimeofday ()))

(* One microphone capture, off the input loop.

   [Voice_bridge.record_and_transcribe] blocks for as long as the operator
   speaks — up to its timeout — so running it inline would freeze the TUI mid
   sentence. It is forked, and what comes back arrives as an [async_msg] like
   every other background result.

   The meter is read from the recording as it grows rather than from the
   microphone: opening a second capture device costs about 2.5 s here, which is
   longer than most utterances. Sox writes the file continuously, so the level
   of the newest bytes is the level being heard now. Nothing else can tell the
   operator their input device is dead — a dead microphone and a quiet room
   both end as an empty draft. *)
let launch_voice_capture ?(calibrate = false) (state : T.state) ~mailbox ~keeper =
  let inherited_floor = state.T.voice_floor in
  let capture noise_floor =
    match Voice_bridge.record_and_transcribe
        ~agent_id:keeper ?noise_floor
        (* The operator's stored pick travels to the recorder, so a capture
           from the panel opens the device the config names, not whatever the
           OS currently calls the default input. *)
        ?audio_device:(Masc_tui_work_requests.Voice_requests.resolved_audio_input_device ~pick:state.T.boot_audio_input_device ~for_display:false)
        ~on_level:(fun level -> Masc_tui_transport.Workspace_admission.enqueue mailbox (P.Voice_msg (P.Voice_level { keeper; level })))
        ~should_stop:(fun () -> state.T.voice_stop_requested) () with
    | Error error -> P.Voice_msg (P.Voice_failed { keeper; error })
    | Ok json ->
        (* Read the bridge's typed outcome rather than guessing from text. *)
        match Voice_bridge.capture_outcome_of_json json with
        | Voice_bridge.Transcript { text; _ } -> P.Voice_msg (P.Voice_transcribed { keeper; text })
        | Voice_bridge.Transcriber_returned_nothing { endpoint_id } ->
          P.Voice_msg (P.Voice_silent
            { keeper
            ; reason =
                (match endpoint_id with
                 | Some endpoint -> "the transcriber (" ^ endpoint ^ ") returned no text"
                 | None -> "the transcriber returned no text")
            })
        | Voice_bridge.Nothing_heard { message } -> P.Voice_msg (P.Voice_silent { keeper; reason = message })
        | Voice_bridge.Discarded_recording { message } ->
          P.Voice_msg (P.Voice_discarded { keeper; reason = message })
        | Voice_bridge.Unrecognized_status status ->
          P.Voice_msg (P.Voice_failed { keeper; error = "voice result carried an unknown status: " ^ status })
        | Voice_bridge.Status_absent ->
          P.Voice_msg (P.Voice_failed { keeper; error = "voice result carried no status" })
  in
  let run () =
    let msg =
      try
        if calibrate then begin
          (* This probe owns the same microphone session as the capture. The
             key handler returns while it waits, but another capture must wait
             for this session's original terminal response. *)
          let floor = Voice_bridge.measure_noise_floor ~agent_id:keeper () in
          Masc_tui_transport.Workspace_admission.enqueue mailbox (P.Voice_msg (P.Voice_calibrated { keeper; floor }));
          match state.T.voice_stop_requested with
          | Some Voice_bridge.Discard ->
              P.Voice_msg (P.Voice_discarded { keeper; reason = "microphone preparation discarded" })
          | Some Voice_bridge.Keep_what_was_heard ->
              P.Voice_msg (P.Voice_silent { keeper; reason = "stopped during microphone preparation; no speech recorded" })
          | None ->
              (* The probe and its mailbox publication both yield. Turning
                 continuous mode off during either wait must not start a new
                 recorder. Once recording has started its existing Keep/
                 Discard policy still owns speech already captured. *)
              (match state.T.voice_continuous with
               | Some active when String.equal active keeper -> capture floor
               | Some _ | None -> P.Voice_msg (P.Voice_silent
                   {keeper; reason = "continuous mode stopped during microphone preparation"}))
        end else capture inherited_floor
      with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn -> P.Voice_msg (P.Voice_failed { keeper; error = Printexc.to_string exn })
    in
    Masc_tui_transport.Workspace_admission.enqueue mailbox msg
  in
  match Eio_context.get_switch_opt () with
  | None ->
      (* No capture exists to settle. Report this synchronous refusal at its
         original call site instead of sending a terminal event with no owner. *)
      ignore (T.refuse_voice_start state ~keeper);
      report_voice_failure state ~keeper "background recorder unavailable"
  | Some sw ->
      (* Eio fork can skip its body on an already cancelled switch. Check before
         claiming a microphone session; cancellation is not a recorder error. *)
      Eio.Switch.check sw;
      state.T.voice_capture <- Some keeper;
      state.T.voice_capture_phase <- (if calibrate then T.Voice_calibrating else T.Voice_starting);
      state.T.voice_capture_withdrawn <- false;
      state.T.voice_level_db <- None;
      state.T.voice_stop_requested <- None;
      Eio.Fiber.fork_daemon ~sw (fun () -> run (); `Stop_daemon)

(* Continuous mode's only moving part: after each capture settles, start the
   next one. Left as a separate step rather than looping inside the fiber so
   the mode can be turned off between utterances — a fiber that re-armed itself
   would have to be cancelled mid-recording, and that throws away speech
   already said. *)
let rearm_continuous_capture (state : T.state) ~mailbox ~keeper =
  match state.T.voice_continuous with
  | Some active when String.equal active keeper && state.T.voice_capture = None ->
      launch_voice_capture state ~mailbox ~keeper
  | Some _ | None -> ()
