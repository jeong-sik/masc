(** How one recorded reviewer execution ended. [Owner_lost]: its writer is
    gone and left no terminal. *)
type t =
  | Succeeded
  | Failed
  | Cancelled
  | Owner_lost

val observation : runtime_id:string -> t -> Yojson.Safe.t
(** The observation a retained refusal keeps for one execution that ended
    without a settled report. [Cancelled] is the observation retained
    refusals already hold for a cancelled reviewer. *)

val of_observation : Yojson.Safe.t -> (string * t) option
(** The runtime and the ending when the value is exactly an {!observation}
    with a non-blank runtime; [None] for every other value. *)
