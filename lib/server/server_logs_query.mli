(** The query of [GET /api/v1/dashboard/logs] and of its stream: how many
    entries, the lowest level, a module, a category to keep or ones to leave
    out, and sequence cursors. *)

type t =
  { limit : int
  ; level_filter : string  (** As the request spelled it. *)
  ; applied_level : Log.level
  ; min_level : int
  ; module_filter : string
  ; since_seq : int option
  ; before_seq : int option
  ; categories : Log.category_selector list option
  ; exclude_categories : Log.category_selector list option
  }

val category_selectors_param :
  Httpun.Request.t -> string -> (Log.category_selector list option, string) result
(** Read a comma list of log category names from query [key]. [Ok None] when
    the key is absent or lists no name; [Error name] for the first name that
    is neither a category nor ["uncategorized"]. *)

val default_limit : int
val max_limit : int

val of_request : Httpun.Request.t -> (t, Yojson.Safe.t) result
(** [Error] carries the JSON body of a 400 for a level that is not one of
    debug, info, warn, warning, error, or for a [category] or [exclude_category]
    name that is neither a log category nor [uncategorized]. A cursor below
    zero is no cursor. *)

val read : t -> Log.Ring.entry list
(** The ring entries the query selects, newest first. *)

val to_json :
  config:Workspace.config -> t -> ring_bounds:Log.Ring.bounds -> Log.Ring.entry list -> Yojson.Safe.t
(** The [/logs] answer for [entries], with the ring bounds read after them. *)
