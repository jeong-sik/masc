(** The newest turns of one Keeper, for the Story window's feed (RFC-0515
    section 2.5). They come from the turn-records page the Memory pane already
    reads, cut to the newest few. A turn is placed by the time its record was
    written, which is when the turn ended, and carries the stop reason the
    execution receipt recorded. The reason is kept as the server wrote it and
    is never sorted into ok or failed here. *)

type stop =
  | Stopped of string
      (** The receipt's stop reason, verbatim. *)
  | No_stop_reason
      (** The record holds no stop reason: the turn ended before the receipt
          recorded one. *)

type turn =
  { at : float  (** Unix time the record was written. *)
  ; stop : stop
  }

val page_limit : int
(** How many of the newest records one read asks for. *)

val decode : keeper:string -> Yojson.Safe.t -> (turn list, string) result
(** Decodes the turn-record page, including an empty page. The turns come back
    oldest first, ordered by [at] whatever order the page was in; turns
    written at the same instant keep the page's order. Every record must
    belong to the requested Keeper. A malformed record or nonzero
    [skipped_rows] fails the read: an omitted newest row must not make an
    older turn look like the last one. *)
