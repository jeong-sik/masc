(** Read-only application observations. Saved TOML identity and worker state are
    separate from the editable draft and the save receipt. *)
type target = {
  source_path : string; installation_id : string; source_revision : string;
  desired_revision : string; enabled : bool;
}
type state = Starting | Cleaning | Applied of string | Inactive
  | Failed of string list | Unknown of string list
type observation = { target : target; state : state }
type tracking = Observed of state | Awaiting_declaration | Different_source
  | Different_inputs | Unavailable of string

val decode : Yojson.Safe.t -> (observation, string) result
(** Decode a parsed declaration, including its closed application discriminator.
    Missing or inconsistent fields fail rather than claiming application. *)
val track : target:target -> complete:bool -> observation list -> tracking
val describe : tracking -> string

type ticket
type 'a reading
val empty : 'a reading
val start : generation:int -> 'a reading -> ('a reading * ticket) option
(** One read per explicit-action generation; starting does not clear a reading. *)
val finish : generation:int -> ticket -> ('a, string) result -> 'a reading -> 'a reading
(** Only the current ticket and action generation can publish a result. *)
val accept : ('a, string) result -> 'a reading
(** A foreground inventory result supersedes any background read. *)
val value : 'a reading -> ('a, string) result option
val pending : 'a reading -> bool
