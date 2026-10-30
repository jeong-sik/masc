(** The candidate memories a recall judgment looks at, and how they are cut
    into requests (docs/rfc/RFC-keeper-recall-reaches-the-turn.md, section
    4.2). Nothing here filters candidates. *)

(** One current fact as the judge sees it. *)
type t

val of_fact : Keeper_memory_os_types.fact -> t
(** The claim is taken as the store holds it. It is not checked to be valid
    UTF-8, and the JSON writer does not check it either. *)

val id : t -> string
(** The memory id of the fact. It is the key the judge answers under. *)

val line : t -> Yojson.Safe.t
(** [question_id] (the memory id), [category], [claim] in full, [first_seen],
    [last_seen] and [origin]. The two dates are UTC days. A timestamp that is
    not a representable date is [null]; the candidate stays in. The origin is
    its kind only, never a trace id. *)

val utc_day : float -> string option
(** The UTC day of a time as {!line} writes it, [YYYY-MM-DD]. [None] for a
    time that is not a representable date. *)

val line_bytes : t -> int
(** Bytes of the compact serialization of {!line}, as the JSON writer emits
    it: UTF-8 whenever the claim is. *)

val state_bytes_per_piece : int
(** Most bytes of candidate lines in one request. Jev refused a 159.7 KB
    [state] and accepted 77.9 KB and 82.1 KB ones, so the starting value is
    below the largest accepted [state] (scripts/keeper-recall-jev-probe.py,
    evidence in docs/evidence/keeper-recall-jev-probe-2026-10-28). A [state]
    is a little larger than its lines (separators, wrapper, purpose) and the
    request adds one question per candidate, so the lines are only part of
    what a request weighs. A KB is 1000 bytes. *)

(** Candidates sent in one request. Never empty. *)
type piece

val piece_candidates : piece -> t list
val piece_line_bytes : piece -> int

val split : piece_bytes:int -> t list -> piece list
(** Cuts the candidates, in order, into pieces whose line bytes sum to at most
    [piece_bytes]. Every candidate lands in exactly one piece and order is
    kept. A candidate that alone exceeds [piece_bytes] gets a piece of its
    own. A budget of zero or less therefore puts every candidate in its own
    piece. *)
