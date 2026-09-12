(** World constitution article vocabulary (RFC-0442).

    An article is a norm the keepers of one world ratified for themselves. The
    ledger under [<base_path>/.masc/constitution/] stores them and the
    [keeper.constitution] prompt slot renders the ones in force; this module
    owns the shape and its wire form and touches no files.

    Two invariants live in the types rather than in a validator. An article
    carries at least one piece of evidence, because RFC-0442 admits a norm only
    with a ledger coordinate behind it, and a ratification names at least one
    ratifier. Neither state can be constructed. *)

(** {1 Identity} *)

module Article_id : sig
  type t

  val of_string : string -> (t, string) result
  (** Accepts exactly what {!generate} mints: ["a-"] followed by 32 lowercase
      hex characters. A keeper that invents an id is refused here rather than
      reaching the ledger as a lookup that can only miss — the shape
      [Board_types.Comment_id] settled on for the same reason. *)

  val to_string : t -> string
  val generate : unit -> t
  val equal : t -> t -> bool

  val json_schema_pattern : string
  (** Pattern tool schemas declare for an [article_id] field. *)
end

(** {1 Non-empty lists}

    Used for evidence and ratifiers. Both are collections whose empty case
    RFC-0442 forbids, so the emptiness is parsed away once here instead of
    being re-checked at each reader. *)

module Non_empty : sig
  type 'a t

  val of_list : 'a list -> ('a t, [ `Empty ]) result
  val to_list : 'a t -> 'a list
  val length : 'a t -> int
end

(** {1 Article} *)

type evidence = {
  uri : string;
      (** Ledger coordinate (board post or comment id), or a file URI whose
          bytes a watcher bound. *)
  sha256 : string option;
      (** Present when the evidence is a file snapshot rather than a ledger
          row. *)
}

type state =
  | Proposed of { post_id : string }
      (** The board post carrying the proposal. Votes accumulate there. *)
  | Ratified of { at : float; ratifiers : string Non_empty.t }
      (** In force. Only this state renders into the system prompt. *)
  | Superseded of { by : Article_id.t; at : float }
      (** Replaced by another article. Terminal. *)
  | Repealed of { at : float; post_id : string }
      (** Withdrawn by the same vote cost that ratified it (RFC-0442 §3.2).
          Terminal. *)

type t = private {
  id : Article_id.t;
  text : string;  (** The bytes the prompt slot renders verbatim. *)
  evidence : evidence Non_empty.t;
  proposer : string;
  state : state;
  last_cited_at : float option;
      (** Drives expiry of articles nothing cites (RFC-0442 §3.2). [None]
          until first cited. *)
}

(** {2 Construction} *)

type invalid =
  | Empty_text
  | Empty_proposer
  | Empty_evidence_uri of { index : int }

val invalid_to_string : invalid -> string

val make :
  id:Article_id.t ->
  text:string ->
  evidence:evidence Non_empty.t ->
  proposer:string ->
  state:state ->
  last_cited_at:float option ->
  (t, invalid) result
(** Rejects an article whose rendered text would be empty, whose proposer is
    unnamed, or whose evidence carries a blank uri. *)

val cite : t -> at:float -> t
(** Record that a reader cited this article at [at]. Moves [last_cited_at]
    forward only; an older timestamp leaves the article unchanged, so a replay
    of out-of-order ledger lines cannot make an article look staler than it
    is. *)

(** {2 State transitions}

    The matrix below is exhaustive over both states. RFC-0442 keeps the
    transitions closed so that adding a state forces every pair to be answered
    here rather than defaulting through a catch-all. *)

type transition_error = Illegal_transition of { from_ : state; to_ : state }

val transition_error_to_string : transition_error -> string

val transition : t -> to_:state -> (t, transition_error) result
(** Legal moves: a proposal is ratified or repealed; an article in force is
    superseded or repealed. [Superseded] and [Repealed] are terminal, and no
    state re-enters itself. *)
