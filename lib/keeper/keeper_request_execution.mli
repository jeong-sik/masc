(** Canonical Core journals for native Keeper calls without a direct-operation
    owner. Each actual API invocation owns a fresh directory. This adapter
    neither resumes a previous call nor grants retry/effect authority. *)
type t

val prepare :
  base_path:string -> keeper_name:string -> config:Runtime_agent.config ->
  unit -> (t * Runtime_agent.config, string) result
(** Install a fresh execution store. Its scope callback durably publishes the
    opaque locator before provider/tool effects. An existing explicit store is
    rejected instead of overwritten. Preparation errors precede dispatch. *)

val reopen : base_path:string -> keeper_name:string -> call_id:string ->
  (t, string) result
(** Reopen the observation handle without creating directories or acquiring a
    writer. The handle reads the persisted locator, never a callback mirror. *)

val request_evidence : t -> Request_observation.evidence
(** Read root-run provider requests from the authoritative journal, including
    returned failures. A missing, malformed or unreadable locator is
    [Read_failed]: absence alone cannot prove that no scope was published.
    No requested intent is synthesized. *)

val call_id : t -> string
