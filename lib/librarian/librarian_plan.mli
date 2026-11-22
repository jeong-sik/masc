(** What an answer does to Memory, as a pure function
    (RFC librarian-call-only-proposes §8.2, step 1, §8.3 + Living Evolutionary
    Memory).

    A flaw in one op leaves out that op and nothing else.

    {b Evolutionary ops.}
    - [Add], [Merge], [Revise]: accept both [Observed] and [Derived] bases.
      A [Derived] fact is kept only when at least one derivation has all of
      its premises supported after the commit; otherwise the op is withdrawn
      as [Successor_unsupported].
    - [Synthesize]: resolves short premise refs ([m1], [m2], ...) to canonical
      memory IDs, constructs a [Derived] fact citing those premises, and
      preserves the premise facts in Memory.
    - [Molt]: proactively sheds named facts into compacted cold archive as
      {!Librarian_effects.Molted}.
    - [Promote_to_world]: resolves supporting local fact refs to canonical
      [source_fact_ids] and records a {!Librarian_lifecycle.world_promotion}
      in [effects.promotions] without removing local facts. If any supporting
      source leaves Memory in the same answer, the promotion is withdrawn as
      [Successor_unsupported]. *)

open Keeper_memory_os_types

type read =
  | Range of
      { memory : (string * string) list
      ; units : (string * int) list
      }
  | Item_alone of { units : (string * int) list }

type shown =
  | Read of read
  | Room of { memory : (string * string) list }
  | Molt of
      { memory : (string * string) list
      ; trigger : Librarian_lifecycle.molt_trigger
      }
  (** Proactive declarative consolidation, synthesis, and molting triggered at
      a structural lifecycle boundary (no new units). *)

type working_state =
  | Kept
  | Replaced of string
  | Alone of Librarian_log.alone_working_state

type t =
  { facts : fact list
  ; effects : Librarian_effects.t
  ; working_state : working_state
  }

(** Maximum accepted [Promote_to_world] ops per Librarian answer. *)
val max_promotions_per_answer : int

(** Maximum byte length of a promoted world claim after redaction. *)
val max_promotion_claim_bytes : int

(** Maximum byte length of a promoted world scope token after redaction. *)
val max_promotion_scope_bytes : int

(** Maximum facet count per promoted world entry. *)
val max_promotion_facets : int

(** Maximum byte length per promoted facet after redaction. *)
val max_promotion_facet_bytes : int

val of_answer
  :  ?is_public_board_post:(Board_types.Post_id.t -> bool)
  -> ?redact:Keeper_secret_redaction.t
  -> shown:shown
  -> facts:fact list
  -> removed_since:(string * int) list
  -> at:float
  -> trace_id:string
  -> Librarian_answer.t
  -> t
