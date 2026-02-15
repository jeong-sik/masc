let replay_events ~rule ~initial_state ~events =
  let module R = (val rule : Trpg_rule.S) in
  List.fold_left (fun state event -> R.apply_event ~state ~event) initial_state events

let derive_state ~rule ~config ~events =
  let module R = (val rule : Trpg_rule.S) in
  let base = R.init_state ~config in
  let replayed = replay_events ~rule ~initial_state:base ~events in
  R.derive_state ~state:replayed
