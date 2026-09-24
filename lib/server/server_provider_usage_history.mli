(** Durable provider reports for exact daily Usage observations. The scope
    identifier is an opaque digest of the quota scope; raw scope material is
    never written to this store or returned by its read API. *)

val install : Workspace.config -> unit
(** Register the server-side sink before runtimes begin reporting. *)

val failure_in_window : now:float -> days:int -> bool
(** Whether a report failed to persist within the requested UTC day window. *)

val read :
  Workspace.config -> now:float -> days:int -> (Yojson.Safe.t, string) result
(** Return the latest report on each UTC day, per account and reported
    window. Only 1, 7, and 14 day reads are accepted. Missing days have no
    point. Any malformed or unreadable store fails the read. *)
