(** Meaning preservation of derived received-work context. This does not judge
    permission, completion, Memory disposition or the original queue entries. *)
type verdict = Faithful | Needs_revision | Insufficient_evidence

type observation
val observation_to_yojson : observation -> Yojson.Safe.t
type withholding_kind =
  | Not_withheld
  | Needs_revision
  | Review_failed of string

val withholding_kind : observation -> withholding_kind
(** Classify whether publication is permitted, revised by review, or blocked
    fail-closed due to an incomplete/invalid/failed review call. *)

val permits_publication : observation -> bool
(** Only {!Skipped} (missing policy, excluded keeper, or empty proposal) and an
    explicit {!Faithful} or {!Insufficient_evidence} verdict permit publication.
    {!Needs_revision}, incomplete {!Checking}, {!Failed}, and {!Invalid_answer}
    fail closed and withhold publication. *)

val run :
  ?observe:(observation -> unit) ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  keeper_id:string -> input:Keeper_librarian_context.input ->
  proposed:Keeper_librarian_context.pocket list -> unit -> observation
(** One typed choice for the complete batch, including the source material of
    named previous merge targets. [observe] must not yield; it records the start
    before the request and the receipt before returning. Cancellation propagates. *)
