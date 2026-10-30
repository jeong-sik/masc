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
let allocated s = s.Gc.minor_words +. s.major_words -. s.promoted_words
let () =
  let mode = Sys.argv.(1) and n = int_of_string Sys.argv.(2) in
  let items = Array.init 256 (fun _ -> empty_event_queue_reaction_evidence_accumulator ()) in
  (match mode with
   | "empty" -> ()
   | "filled" -> Array.iter (fun state -> Array.iter (note_event_queue_reaction_evidence_row ~keeper_name:"k" state) rows) items
   | _ -> invalid_arg mode);
  let project i =
    let state = items.(i mod Array.length items) in
    ignore (Sys.opaque_identity
      (event_queue_reaction_evidence_of_accumulator ~keeper_name:"k" ~stimulus_id:"s" state))
  in
  for i = 1 to 50000 do project i done;
  Gc.full_major ();
  let before = Gc.quick_stat () in
  let cpu_start = Sys.time () and wall_start = Unix.gettimeofday () in
  for i = 1 to n do project i done;
  let cpu = Sys.time () -. cpu_start and wall = Unix.gettimeofday () -. wall_start in
  let after = Gc.quick_stat () in
  Printf.printf "{\"mode\":\"%s\",\"iterations\":%d,\"allocated_bytes\":%.0f,\"cpu_seconds\":%.9f,\"wall_seconds\":%.9f}\n"
    mode n ((allocated after -. allocated before) *. float_of_int (Sys.word_size / 8)) cpu wall
