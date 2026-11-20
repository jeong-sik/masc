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
    draft it, and only a raw TOML declaration can install it. A binding
    schema that is nothing but a [oneOf] of object alternatives, each with a
    name of its own from its schema ([title], [description] or constant
    members) that no other alternative has, is filled one alternative at a
    time, chosen in the form's first slot when there is more than one. Any
    other binding schema is left as the [binding] member of the form's
    root. *)
val handle : key:string -> t -> (event,string) result
val paste : text:string -> t -> t
val lines : ?ko:bool -> ?height:int -> ?render:(string -> string list) -> t -> string list
val lines_with_selection : ?ko:bool -> ?height:int -> ?render:(string -> string list) -> t -> (bool * string) list
val hints : ?ko:bool -> t -> string

val begin_catalog : request_id:int -> directory:string option -> t -> (t,string) result
val receive_catalog : request_id:int -> directory:string option -> (Yojson.Safe.t,string) result -> t -> (t * string option) option

val begin_preview : request_id:int -> path:string -> t -> (t,string) result
val receive_preview : request_id:int -> path:string -> (Yojson.Safe.t,string) result -> t -> (t * string option) option

type read = Read_catalog of string option | Read_preview of string
val pending_read : t -> read option
val text_entry_open : t -> bool
(** Whether the installer is currently focused on a text-entry form rather
    than browsing the package catalog or waiting on a pending read. *)
val suspend_read : t -> t
(** Restore the editing or browsing state preceding a retired read. *)
