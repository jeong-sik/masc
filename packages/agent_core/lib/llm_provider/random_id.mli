(** Fork-safe, restart-collision-resistant identifiers sampled from the
    operating-system entropy source.

    This module lives in [Llm_provider] because that is the lowest library
    shared by provider call IDs and higher [Agent_sdk] consumers. Every
    identifier is sampled independently from operating-system entropy.
    Failure is explicit and never falls back to clocks, counters, process IDs,
    paths, or content-derived identities. *)

(** [hex ~bytes] samples exactly [bytes] bytes and returns lowercase
    hexadecimal. A non-positive byte count is rejected. *)
val hex : bytes:int -> (string, string) result

(** Equivalent to [hex ~bytes:16], yielding a 128-bit identifier. *)
val create : unit -> (string, string) result
