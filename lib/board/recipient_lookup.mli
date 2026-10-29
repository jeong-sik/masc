(** Which Keeper a name written after [@] stands for
    (RFC-at-name-resolves-to-declared-recipient, layer L2c).

    The Board libraries cannot read Keeper settings, so the server hands the
    answer over when it starts the backend ({!Board_dispatch.init_jsonl}) and
    the write path only asks.  A name no Keeper declares is prose: it is not
    stored as a target and the author is told about it. *)

open Board_types

module Candidate = Recipient_resolution.Candidate
(** The name a lookup is asked about: what an author wrote after [@], which has
    the shape of a name and is nothing more yet. *)

type 'recipient resolution = 'recipient Recipient_resolution.resolution =
  { recipients : 'recipient list
        (** Each recipient once, in the order its first candidate was written. *)
  ; unresolved : string list
        (** The candidates nobody declares, as the author spelled them, once per
            spelling, in the order written. *)
  }

type t

val make : (Candidate.t -> (Agent_id.t option, string) result) -> t
(** [make declared] is a lookup that asks [declared] once per spelling.

    - [Ok (Some recipient)]: the name is declared and stands for [recipient],
      the Keeper's own name, whichever alias or case the author wrote.
    - [Ok None]: no Keeper declares the name.  It is prose.
    - [Error detail]: the declaration could not be read, so the write is
      refused and nothing is stored.  Recording "no recipient" instead would
      lose the address for good.  [detail] reaches the author, so it names what
      is broken. *)

val none_declared : t
(** Declares no name: every candidate is prose and nothing is ever an error.
    A Board with no Keepers to address uses it. *)

val unavailable : t
(** The lookup of a backend that nobody installed a lookup into.  It answers
    [Error] for every candidate, so a text with an address in it is refused
    and a text without one is written as usual.  Only a backend started by
    something other than {!Board_dispatch.init_jsonl} has this lookup. *)

val resolve
  :  t
  -> Candidate.t list
  -> (Agent_id.t resolution, string) result
(** {!Recipient_resolution.resolve} with the lookup as the declaration and the
    Board identity as the recipient.  An [Error] ends the walk, so no partial
    resolution comes back. *)
