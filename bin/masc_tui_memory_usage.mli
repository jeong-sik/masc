(** Memory's selected Keeper reading over the same recent-record window as
    /context. These are complete request inputs, not Recall-only tokens. *)
type display_unit = Tokens | Bytes

val next_unit : display_unit -> display_unit
val unit_label : display_unit -> string
val page_limit : int

type distribution =
  { samples : int
  ; mean : float
  ; minimum : int
  ; maximum : int
  }

type reading =
  { distribution : distribution option
  ; last : int option
      (** The newest record's value, never the newest nonmissing value. *)
  }

type t =
  { records : int
  ; tokens : reading
  ; bytes : reading
  }

val of_records : Turn_record.t list -> t
(** Records in chronological endpoint order. Token samples require
    [Per_request] usage; bytes require an observed serialized request.
    Missing values are excluded, reported zeros are included. A per-request
    token value can originate from a runtime context estimate; TurnRecord
    does not preserve that measurement basis. *)

val decode : keeper:string -> Yojson.Safe.t -> (t, string) result
(** Decodes the turn-record page, including an empty page. Every record must
    belong to the requested Keeper. A malformed record or nonzero
    [skipped_rows] fails the reading: an omitted newest row must not make an
    older input look like the last one. *)
