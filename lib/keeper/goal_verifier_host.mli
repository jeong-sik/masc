(** Actual Goal-domain and observation adapter for the retained reviewer.
    The application caller serializes each Goal under the workspace lease.
    This adapter owns neither a model runner nor another lifecycle store. *)

type error = Unavailable of string | Invalid_original of string | Conflict of string
val error_to_string : error -> string

val ensure_registered :
  registry:Goal_verification_run_registry.t -> Goal_verifier_worker.retained ->
  (unit, error) result
(** Register only an absent fixed run, authenticate an existing row without
    resetting its completion, and confirm the exact registration by readback. *)

val publish :
  store:Lane_addon_store.t -> registry:Goal_verification_run_registry.t -> Goal_verifier_worker.retained ->
  outcome:Goal_verification_run_registry.outcome -> (unit, error) result
(** Publish the retained result/runtime/tools and confirm the completed row.
    Reviewed must be durable before proof commit. Existing exact Committed
    history is never downgraded by a later observation or lifecycle change.
    Final committed publication is acknowledged on its durable original;
    finite display retention does not create unfinished work. *)

val needs_recovery :
  registry:Goal_verification_run_registry.t -> Goal_verifier_worker.retained ->
  (bool, error) result
(** Discover unfinished judgment/commit and missing final registry publication
    independently of today's Goal phase. No dispatch or proof effect. *)

val commit_proof :
  config:Workspace_utils_backend_setup.config -> store:Lane_addon_store.t ->
  registry:Goal_verification_run_registry.t ->
  Goal_verifier_worker.retained -> (unit, error) result
(** Bind the exact saved judgment to the authoritative pending proof, then use
    the actual internal Goal commit with Candle-before-proof ordering. Restore
    a prior intent before reading another before-state. Exact ledger-before-
    phase partial commits converge through existing locked reconciliation;
    changed request/criterion/evidence is a conflict. Human confirmation stays
    operator-owned; a bound result may commit while Verifying is suspended. *)
