(** Worker-local retained PNG for immutable lane frames. *)
val encode_frame : Msx_lane.frame -> (string, string) result
