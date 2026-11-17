(* Purpose-built skip-prefix control, not actual Stdlib implementation. *)
let[@inline never] rec capture depth max_frames =
  if depth = 0 then Printexc.get_callstack max_frames, 0
  else
    let raw, sum = capture (depth - 1) max_frames in
    raw, sum + depth
