(** Durable provider reports for exact daily Usage observations. The scope
    identifier is an opaque digest of the quota scope; raw scope material is
    never written to this store or returned by its read API. *)

val scope_id : Runtime_quota_window.scope -> string
(** The opaque identity of a quota scope, as both this store and the
    [provider_usage_windows] rows of [/api/v1/runtime/resolved] name it. One
    digest from [Runtime_quota_window.scope_id], so history, current windows
    and Setup groups agree; readers compare it and never recompute it.
    A credential-location scope is not an authenticated provider account ID. *)

val install : Workspace.config -> unit
(** Register the server-side sink before runtimes begin reporting. *)

val restore :
  Workspace.config ->
  now:float ->
  scopes:Runtime_quota_window.scope list ->
  (unit, string) result
(** Put the stored reports of the last fourteen UTC days back in the
    in-memory usage table for [scopes], as {!Runtime_provider_usage_window.restore}
    describes, choosing them as
    {!Server_provider_usage_history_projection.stored_reports} does. Stored
    reports of a scope not in [scopes] stay on disk only. Nothing is written
    to the store. [Error] when the store cannot be read; the table is then
    left as it was. Called once at start, before runtimes report. *)

type window = One_day | Seven_days | Fourteen_days
(** The UTC day windows the history answers for. *)

val window_of_days : int -> window option
(** The window a [days] query names; [None] for any other count. *)

val days_of_window : window -> int

val read :
  Workspace.config -> now:float -> window:window -> (Yojson.Safe.t, string) result
(** Return the latest report on each UTC day, per scope and reported window.
    Complete reports remove omitted windows from that day's sample; sparse
    updates retain unstated windows. Earlier days retain their own readings.
    A successful complete empty scope/day appears in [reported_no_windows]
    with its opaque [scope_id] and [observed_at], unless another source retains
    windows for that scope/day. Missing days have neither a point nor an empty
    report.

    Each journal day file of the widest window is folded once and kept for
    the workspace: a read folds only what the files gained since the last
    one, and reads a rotated file again from its start. A stored line that
    cannot be read is logged once, skipped, and counted in
    [unreadable_reports]; the rest are still read. A store that cannot be
    read at all, or a report that failed to persist in the window, fails the
    read. *)
