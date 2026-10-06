type t
type event = Updated of t | Browse of string option | Preview of string | Manual | Jump | Declare | Cancel
(** [Declare] asks for the raw TOML declaration editor. *)
val create : ?directory:string -> unit -> t
val directory : t -> string option
val receive : Yojson.Safe.t -> t -> (t, string) result
val selected_manifest : t -> string option
val handle : key:string -> t -> (event, string) result
(** Left opens the parent of the folder on screen. A starting folder that has
    not been read has no known parent, so Left opens the workspace root. *)
val hints : t -> string
val lines : height:int -> render:(string -> string list) -> t -> string list
(** [render] sanitizes and wraps terminal text at the actual frame width.
    Lists keep the selected entry visible. Complete selected metadata follows
    the list and can be scrolled, even in a short terminal. *)
