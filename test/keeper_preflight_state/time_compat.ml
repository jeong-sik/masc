(* Standalone test stub for Time_compat — mirrors the real module's
   [now] signature using Unix.gettimeofday. *)
let now () = Unix.gettimeofday ()
