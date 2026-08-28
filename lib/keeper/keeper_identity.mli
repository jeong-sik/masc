(** Keeper_identity — trace ID generation and the keeper identity value.

    RFC-0393: a keeper has exactly one name, its keeper_name. Nothing is
    encoded inside that string and no other identifier shape (wrapped
    [keeper-<name>-agent] alias, generated nickname) is recovered from it
    by parsing. Whether a string names a keeper is answered by a
    registry/meta lookup at the caller, never by the shape of the string. *)

val generate_trace_id : ?now:float -> unit -> string
(** Generate a unique trace ID from an epoch timestamp and monotonic counter.
    [~now] defaults to [Time_compat.now ()] — pass an explicit value in tests
    for deterministic output.  The counter guarantees uniqueness even when
    [now] is pinned to the same value across consecutive calls. *)

(** {1 Structural keeper identity (RFC-0232 §3.4, narrowed by RFC-0393)} *)

(** A comparable author identity minted once at the parse boundary. *)
module Keeper_id : sig
  type t = private string
  (** Canonical form: trimmed and case-folded. A keeper's id is its
      keeper_name; every other author (humans, external bots) mints a
      comparable id from its own name the same way. No alias or nickname
      recovery happens here (RFC-0393). *)

  val of_string : string -> t option
  (** [None] iff the input is whitespace-only. *)

  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end
