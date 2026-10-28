open Accumulator
let event id time kind =
  let metadata = {event_id=id; recorded_at=time} in
  match kind with
  | None -> Good (Current_stimulus {metadata})
  | Some reaction_kind -> Good (Current_reaction {metadata; reaction_kind})
let rows = [|
  event "stimulus" 9. None;
  event "start" 11. (Some Turn_started);
  event "finish" 13. (Some Turn_finished);
  event "ack" 12. (Some Event_queue_ack);
  event "cancel" 10. (Some Event_queue_cancelled)
|]
let result accumulator =
  event_queue_reaction_evidence_of_accumulator ~keeper_name:"k" ~stimulus_id:"s" accumulator
let oracle () =
  let cases = [
    [];
    [rows.(0)];
    [rows.(1); rows.(0)];
    Array.to_list rows;
    [Bad Invalid_row; rows.(1); rows.(1); rows.(0); Bad Wrong_keeper];
    [event "same" 3. (Some Turn_started); event "same" 20. (Some Event_queue_ack)];
    [Bad Invalid_row; event "bad-replay" 1. (Some Turn_finished);
      event "other" 3. (Some Turn_finished); event "older" (-4.) (Some Turn_finished)]
  ] in
  List.iter (fun events ->
    let state = empty_event_queue_reaction_evidence_accumulator () in
    Marshal.to_channel stdout (result state) [Marshal.No_sharing];
    List.iter (fun row ->
      note_event_queue_reaction_evidence_row ~keeper_name:"k" state row;
      Marshal.to_channel stdout (result state) [Marshal.No_sharing]) events) cases
let allocated s = s.Gc.minor_words +. s.major_words -. s.promoted_words
let measure mode n =
  Gc.full_major ();
  let before = Gc.stat () in
  let cpu_start = Sys.time () and wall_start = Unix.gettimeofday () in
  let items = Array.init n (fun _ -> empty_event_queue_reaction_evidence_accumulator ()) in
  (match mode with
   | "create" -> ()
   | "updates" ->
     Array.iter (fun state -> Array.iter (note_event_queue_reaction_evidence_row ~keeper_name:"k" state) rows) items
   | "project" ->
     Array.iter (fun state -> ignore (Sys.opaque_identity (result state))) items
   | _ -> invalid_arg mode);
  let cpu = Sys.time () -. cpu_start and wall = Unix.gettimeofday () -. wall_start in
  Gc.full_major ();
  let after = Gc.stat () in
  let kept = Array.length (Sys.opaque_identity items) in
  Printf.printf "{\"mode\":\"%s\",\"n\":%d,\"allocated_bytes\":%.0f,\"retained_bytes\":%d,\"cpu_seconds\":%.9f,\"wall_seconds\":%.9f,\"kept\":%d}\n"
    mode n ((allocated after -. allocated before) *. float_of_int (Sys.word_size / 8))
    ((after.Gc.live_words - before.Gc.live_words) * (Sys.word_size / 8)) cpu wall kept
let () =
  match Array.to_list Sys.argv with
  | [_; "oracle"] -> oracle ()
  | [_; mode; n] -> measure mode (int_of_string n)
  | _ -> invalid_arg "usage: bench oracle | bench MODE N"
