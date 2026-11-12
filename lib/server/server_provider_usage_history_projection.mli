(** Pure decoding and daily projection of durable provider reports. *)

type t

val create : since_at:float -> now:float -> t
(** Start an empty projection for the inclusive observation-time interval.
    The caller derives [since_at] from its validated UTC day window. *)

val consume_item : t -> Yojson.Safe.t -> (t, string) result
(** Decode one item before filtering it by observation time. An error is a
    diagnostic for this item only; it does not increment the unreadable count.
    Equal source/window/day timestamps retain the first encountered item. *)

val note_unreadable : t -> t
(** Count one unreadable item or physical row after the caller has logged it. *)

val unbounded : unit -> t
(** A projection with no observation-time bound, for the rows of one day
    file kept between reads; {!absorb} applies the window when it answers. *)

val absorb : t -> t -> t
(** [absorb t kept] adds [kept]'s readings and unreadable count to [t] under
    [t]'s window and the latest-reading rules of {!consume_item}. Absorbing
    the day files' projections oldest first answers what consuming their
    rows in that order would have. *)

val response_json : days:int -> t -> Yojson.Safe.t
(** Apply source/day replacement before selecting daily display points.
    [days] is the caller's validated window length. Empty reports remain
    distinct from measured zero and from days without a report. *)

type stored_reports = {
  reports : (string * float * Runtime_provider_usage_window.report) list;
      (** Scope digest, the time the report was observed, and the report.
          Reports of one scope and source are oldest first. *)
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
    stated no windows yields one report without windows. *)

val record_json :
  scope_id:string ->
  observed_at:float ->
  Runtime_provider_usage_window.report ->
  Yojson.Safe.t list
(** Encode the accepted report, with a complete-snapshot marker before its
    windows when appropriate. [scope_id] is the caller's opaque scope digest. *)
