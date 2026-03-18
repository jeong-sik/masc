let replay_events ~rule ~initial_state ~events =
  let module R = (val rule : Rule.S) in
  List.fold_left
    (fun state (event : Engine_event.t) ->
      try R.apply_event ~state ~event
      with exn ->
        Util.log_info "skipping event seq=%d room=%s type=%s: %s"
          event.seq event.room_id
          (Engine_event.string_of_event_type event.event_type)
          (Printexc.to_string exn);
        state)
    initial_state events

let derive_state ~rule ~config ~events =
  let module R = (val rule : Rule.S) in
  let base = R.init_state ~config in
  let replayed = replay_events ~rule ~initial_state:base ~events in
  R.derive_state ~state:replayed
