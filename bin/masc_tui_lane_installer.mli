(** Guided package inspection and local declaration drafting; no implicit save. *)
type t
type event = Updated of t | Preview of string | Draft of Masc_tui_lane_declaration.session | Cancel
val create : unit -> (t,string) result
val accept_preview : Yojson.Safe.t -> (t,string) result
val handle : key:string -> t -> (event,string) result
val paste : text:string -> t -> t
val lines : t -> string list
