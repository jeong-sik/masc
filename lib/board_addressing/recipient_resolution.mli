(** Recipient_resolution — which of the names written after [@] are
    recipients (RFC-at-name-resolves-to-declared-recipient).

    {!Board_addressing.parse} finds the names in a text.  Such a name is only
    a {e candidate}: the [check] in [dune build @check] is a dune alias, not a
    person.  A candidate is a {e recipient} when the caller's declaration
    accepts it, and prose when it does not.

    The declaration is an argument.  This leaf cannot import the Keeper
    registry, as the board libraries cannot, so the recipient type, the case
    folding and the lookup belong to the caller.  Nothing here is global and
    nothing is set from outside: a caller passes its lookup in the call, and a
    test passes its own. *)

module Candidate : sig
  type t
  (** A name written after [@] that has the shape of a name. *)

  val of_string : string -> t option
  (** [of_string name] is [Some] when [name] is not empty and holds only
      letters, digits, ['_'] and ['-'] ({!Board_addressing.is_routable_target}).
      Anything else, such as ["types/node"], ["../x"], ["a.b"] or ["alice's"],
      is prose and gives [None].  Such a token is not a candidate, so it never
      reaches [declared] and never shows up in [unresolved].

      A Keeper's metadata file is its name plus a suffix, so a lookup builds a
      file name from the candidate it is given.  Stopping a path separator or a
      dot here means no lookup gets a candidate that leaves its directory.  The
      shape is necessary and not sufficient: it does not say the name is a
      valid Keeper name, which the lookup still decides. *)

  val to_string : t -> string
  (** The name as the author wrote it.  Case is preserved; folding it is the
      caller's id type's job, as in {!Board_addressing}. *)
end

type 'recipient resolution =
  { recipients : 'recipient list
        (** Each recipient once, in the order its first candidate was written.
            A consumer that wakes one recipient wakes the first. *)
  ; unresolved : string list
        (** The candidates the declaration does not know, as the author spelled
            them, once per spelling, in the order written. *)
  }

val resolve :
  equal:('recipient -> 'recipient -> bool)
  -> declared:(Candidate.t -> ('recipient option, 'failure) result)
  -> Candidate.t list
  -> ('recipient resolution, 'failure) result
(** [resolve ~equal ~declared candidates] asks [declared] about each candidate
    and sorts the answers.

    - [Ok (Some recipient)]: the name is declared.  [equal] merges candidates
      that name the same recipient, such as ["Alice"] and ["alice"], or a
      Keeper's name and its alias.
    - [Ok None]: the name is not declared.  It is prose.
    - [Error failure]: the lookup could not tell, for example a Keeper's
      metadata could not be read.  That is not prose.  [resolve] returns the
      failure at once, asks [declared] no more, and makes no result from the
      candidates it already sorted.

    [declared] is asked once per distinct spelling, because a lookup can scan
    every Keeper.  ["Alice"] and ["alice"] are two spellings, and the caller's
    answer decides whether they are one recipient. *)
