(** Private offline protocol; caller owns quiescent BasePath ownership. *)
type completion = Completed | Not_completed
type action = Bootstrap | Adopt
type io = {
  read : Board_initialization_inspect.file_io;
  write : Board_initialization_inspect.file_io;
}
type t
val run :
  ?io:io -> action:action -> base_path:string ->
  expected_intent_sha256:string -> unit -> t
val completion : t -> completion
val to_yojson : t -> Yojson.Safe.t
val finish : t -> completion
