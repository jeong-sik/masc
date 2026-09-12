(** World constitution articles (RFC-0442).

    An article is one norm a world wrote down for itself. It is text, who wrote
    it, and when. Proposing, arguing and agreeing happen on the board and in
    chat where they already happen; nothing here models that. The only thing
    this vocabulary exists for is the step those conversations cannot take on
    their own — putting the agreed sentence where every keeper in the world
    reads it. *)

module Article_id : sig
  type t

  val of_string : string -> (t, string) result
  (** Accepts exactly what {!generate} mints: ["a-"] followed by 32 lowercase
      hex characters. A keeper that invents an id is refused here rather than
      reaching the ledger as a removal that can only miss — the shape
      [Board_types.Comment_id] settled on for the same reason. *)

  val to_string : t -> string
  val generate : unit -> t
  val equal : t -> t -> bool

  val json_schema_pattern : string
  (** Pattern tool schemas declare for an [article_id] field. *)
end

type evidence = {
  uri : string;
      (** Where the world talked this norm over: a board post or comment id,
          or a file a watcher bound. *)
  sha256 : string option;
      (** Present when the evidence is a file snapshot rather than a ledger
          row. *)
}

type t = private {
  id : Article_id.t;
  text : string;  (** The bytes the prompt slot renders verbatim. *)
  author : string;
  at : float;
  evidence : evidence list;
      (** May be empty. The conversation that produced the article is on the
          board whether or not someone pasted its coordinate here, and
          demanding one would only move the argument into the tool call. *)
}

type invalid =
  | Empty_text
  | Multiline_text
      (** An article is one sentence on one line. Text carrying a newline
          renders as several lines beside the real ones, and a line shaped like
          [- \[a-...\] ...] is indistinguishable from an article nobody
          wrote — and cannot be removed, because no such id is held. *)
  | Empty_author
  | Empty_evidence_uri of { index : int }

val invalid_to_string : invalid -> string

val make :
  id:Article_id.t ->
  text:string ->
  author:string ->
  at:float ->
  evidence:evidence list ->
  (t, invalid) result
(** Rejects an article whose rendered text would be empty, one nobody claims,
    and evidence that names nothing. *)

(** {1 Ledger entries}

    A world's ledger is a list of these. Writing a norm down and taking it back
    are the only two moves; there is no state in between for a procedure to
    advance through, because the procedure is the conversation that already
    happened. *)

type entry =
  | Added of t
  | Removed of {
      id : Article_id.t;
      by : string;
      at : float;
    }
      (** Removing an article someone else wrote is as cheap as writing one.
          Both stay in the ledger, so a norm that is written, removed and
          written again reads as the disagreement it is. *)
