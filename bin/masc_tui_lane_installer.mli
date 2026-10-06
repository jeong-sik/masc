(** Guided package inspection and local declaration drafting; no implicit save. *)
type t
type event = Updated of t | Browse of string option | Preview of string | Draft of Masc_tui_lane_declaration.session | Declare | Cancel
(** [Declare] closes the installer for the raw TOML declaration editor. *)
val browse : ?directory:string -> unit -> t
val directory : t -> string option
val create : unit -> (t,string) result
(** Manual manifest entry, also available with p in the package browser. *)
val accept_preview : Yojson.Safe.t -> (t option,string) result
(** [Ok None] is a valid package without a binding schema: the form cannot
    draft it, and only a raw TOML declaration can install it. *)
val handle : key:string -> t -> (event,string) result
val paste : text:string -> t -> t
val lines : ?height:int -> ?render:(string -> string list) -> t -> string list
val hints : t -> string

val begin_catalog : request_id:int -> directory:string option -> t -> (t,string) result
val receive_catalog : request_id:int -> directory:string option -> (Yojson.Safe.t,string) result -> t -> (t * string option) option

val begin_preview : request_id:int -> path:string -> t -> (t,string) result
val receive_preview : request_id:int -> path:string -> (Yojson.Safe.t,string) result -> t -> (t * string option) option
