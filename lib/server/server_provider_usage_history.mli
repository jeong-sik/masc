(** Durable provider reports for exact daily Usage observations. The scope
    identifier is an opaque digest of the quota scope; raw scope material is
    never written to this store or returned by its read API. *)

val scope_id : Runtime_quota_window.scope -> string
(** The opaque identity of a quota scope, as both this store and the
    [provider_usage_windows] rows of [/api/v1/runtime/resolved] name it. One
    digest, taken here, so a history point and the current window row it
    belongs to always agree; readers compare it and never recompute it. *)

val install : Workspace.config -> unit
(** Register the server-side sink before runtimes begin reporting. *)

type window = One_day | Seven_days | Fourteen_days
(** The UTC day windows the history answers for. *)

val window_of_days : int -> window option
(** The window a [days] query names; [None] for any other count. *)

val days_of_window : window -> int

val read :
  Workspace.config -> now:float -> window:window -> (Yojson.Safe.t, string) result
(** Return the latest report on each UTC day, per scope and reported window.
    Missing days have no point. A stored line that cannot be read is logged,
    skipped, and counted in [unreadable_reports]; the rest are still read. A
    store that cannot be read at all, or a report that failed to persist in
    the window, fails the read. *)
