(** Meaning preservation of derived received-work context. This does not judge
    permission, completion, Memory disposition or the original queue entries. *)
type verdict = Faithful | Needs_revision | Insufficient_evidence

type observation
val observation_to_yojson : observation -> Yojson.Safe.t
val permits_publication : observation -> bool
(** Only an explicit [Needs_revision] withholds the proposed batch. Skips,
    failures and insufficient evidence retain the existing structural checks;
    they are never reported as verified preservation. *)

val run :
  ?observe:(observation -> unit) ->
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  keeper_id:string -> input:Keeper_librarian_context.input ->
  proposed:Keeper_librarian_context.pocket list -> unit -> observation
(** One typed choice for the complete batch, including the source material of
    named previous merge targets. [observe] must not yield; it records the start
    before the request and the receipt before returning. Cancellation propagates. *)
