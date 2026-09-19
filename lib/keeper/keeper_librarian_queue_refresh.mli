val remember_turn : base_path:string -> keeper_name:string -> trace_id:string ->
  (meta:Keeper_meta_contract.keeper_meta -> Keeper_librarian_runtime.trigger -> unit) -> unit
(** Retain immutable latest-turn evidence for an official-client turn, which
    has no Agent-Core checkpoint range. Agent-Core turns use the durable store
    and never call this function. *)

val forget_turn : base_path:string -> keeper_name:string -> unit
(** Remove a direct official-client closure when the same Keeper resumes on an
    Agent-Core checkpoint. The durable range is then the only conversation
    producer for that Keeper. *)
val install : unit -> unit
(** Install after the detached memory executor. Queue producers never wait for
    this extraction; source selection happens when the latest unit runs. *)

val submit_durable : base_path:string -> keeper_name:string -> unit
(** Submit one disk-selected pass after this Keeper's Librarian lifecycle has
    opened. Launch admission owns restart catch-up; there is no pre-admission
    fleet scan and no process-local remembered closure participates. *)

val run_completed_turn : base_path:string -> keeper_name:string -> unit
(** Run the durable Agent-Core consumer, then attempt an official-client
    closure when one exists. Normal return records an attempt, not extraction
    or commit success. *)

module For_testing : sig
  val attempt_remembered : base_path:string -> keeper_name:string ->
    trace_id:string -> meta:Keeper_meta_contract.keeper_meta -> sources_changed:bool ->
    trigger:Keeper_librarian_runtime.trigger -> bool
end
