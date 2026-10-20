(** The exact current Resources document. This projection reads state without
    changing retained bytes, request ownership, selection or scroll. *)
type t
val current : Masc_tui_types.state -> t option
(** [None] when no inventory entry owns the pending/error/content key. *)
val entry : t -> Masc_tui_resource_catalog.t
val rows : cols:int -> t -> string list
(** [cols] is the surface width after the Activity reservation, before the
    Resources list/detail split. Both drawing and search use this projection. *)
val search_rows : cols:int -> Masc_tui_types.state -> string list option
(** Search only the currently displayed admitted content. Metadata-only,
    loading another key, failures and withdrawn inventory return [None].
    Terminal styling is removed from copies; source contents stay immutable. *)
