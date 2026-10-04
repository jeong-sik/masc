type t
type event = Updated of t | Browse of string option | Preview of string | Manual | Jump | Cancel
val create : ?directory:string -> unit -> t
val directory : t -> string option
val receive : Yojson.Safe.t -> t -> (t, string) result
val selected_manifest : t -> string option
val handle : key:string -> t -> (event, string) result
val lines : height:int -> render:(string -> string list) -> t -> string list
(** [render] sanitizes and wraps terminal text at the actual frame width.
    Lists keep the selected entry visible. Complete selected metadata follows
    the list and can be scrolled, even in a short terminal. *)
