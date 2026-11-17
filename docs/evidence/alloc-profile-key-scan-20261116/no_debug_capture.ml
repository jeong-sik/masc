(* Compiled without -g to exercise real missing-debug entries. *)
let[@inline never] capture max_frames = Printexc.get_callstack max_frames
