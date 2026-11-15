(** Pure decoding and daily projection of durable provider reports. *)

type t

val create : since_at:float -> now:float -> t
(** Start an empty projection for the inclusive observation-time interval.
    The caller derives [since_at] from its validated UTC day window. *)

val consume_report : t -> Yojson.Safe.t list -> t * string list
(** Consume the items of one stored line, which is one report. Each item is
    decoded before it is filtered by observation time. An item that cannot
    be read is counted as unreadable and its diagnostic returned for the
    caller to log; the other items of the line are still read for the daily
    history. The report is then held as one that was not read whole, under
    each scope, source and observation time the line's items state, which
    {!stored_reports} answers for. Equal source/window/day timestamps retain
    the first encountered item. *)

val note_unreadable : t -> t
(** Count one physical row that is not a report list, after the caller has
    logged it. *)

val unbounded : unit -> t
(** A projection with no observation-time bound, for the rows of one day
    file kept between reads; {!absorb} applies the window when it answers. *)

val absorb : t -> t -> t
(** [absorb t kept] adds [kept]'s readings, unread reports and unreadable count to [t] under
    [t]'s window and the latest-reading rules of {!consume_report}. Absorbing
    the day files' projections oldest first answers what consuming their
    rows in that order would have. *)

val response_json : days:int -> t -> Yojson.Safe.t
(** Apply source/day replacement before selecting daily display points.
    [days] is the caller's validated window length. Empty reports remain
    distinct from measured zero and from days without a report. *)

type stored =
  | Report of { observed_at : float; report : Runtime_provider_usage_window.report }
      (** A report and the time it was observed. *)
  | Unreadable_complete_report of {
      source : Runtime_provider_usage_window.source;
      observed_at : float;
    }
      (** The latest complete report of this source, observed at
          [observed_at], had a row that could not be read or that names a
          kind this build does not write. Nothing of the source is to be put
          back: the rows that were read are not the report, and the earlier
          reports are ones it replaced. *)

type stored_reports = {
  reports : (string * stored) list;
      (** Scope digest and what its source stored. Reports of one scope and
          source are oldest first. *)
  unrestorable : int;
      (** Readings whose source or kind word this build does not write. *)
}

val stored_reports : t -> stored_reports
(** The reports a restarted server puts back in its table. For each scope and
    source, each window's latest reading across the days of [t] is kept and
    readings that share an observation time form one report. A reading older
    than its source's latest complete snapshot is left out, as a window that
    snapshot no longer stated. A reading whose row carries no [role] is left
    out: the row was stored before rows carried one, and a role is not
    derived from source and kind. A source whose latest complete snapshot
    stated no windows yields one report without windows.

    A source of the [Complete_snapshot] shape is answered whole or not at
    all. When its latest report is one {!consume_report} did not read whole,
    or one of its readings names a kind this build does not write, the source
    yields one [Unreadable_complete_report] and no [Report]. When one of its
    readings carries no [role], it yields nothing. A report that was not read
    whole and that a later, wholly read report of the source replaced is left
    out with its readings. A [Sparse_update] source keeps each reading that
    could be read. *)

val record_json :
  scope_id:string ->
  observed_at:float ->
  Runtime_provider_usage_window.report ->
  Yojson.Safe.t list
(** Encode the accepted report, with a complete-snapshot marker before its
    windows when appropriate. [scope_id] is the caller's opaque scope digest. *)
