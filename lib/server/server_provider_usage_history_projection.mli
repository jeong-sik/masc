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

val response_json : days:int -> t -> Yojson.Safe.t
(** Apply source/day replacement before selecting daily display points.
    [days] is the caller's validated window length. Empty reports remain
    distinct from measured zero and from days without a report. *)

val record_json :
  scope_id:string ->
  observed_at:float ->
  Runtime_provider_usage_window.report ->
  Yojson.Safe.t list
(** Encode the accepted report, with a complete-snapshot marker before its
    windows when appropriate. [scope_id] is the caller's opaque scope digest. *)
