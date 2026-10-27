(** Retained Goal review execution through the shared original/progress store
    and existing tool-capable reviewer. The serialized host selects the
    original, supplies run identities and owns actual Goal transitions and
    human confirmation. Frontier/commit record its facts; they grant no
    independent domain authority or unknown-execution replacement. *)

type run_identity = { run_id : string; started_at : float }
type receipt = {
  run : run_identity;
  result : Task.Anti_rationalization.review_result;
  tools : Verification_run_registry.tool_observation list;
  elapsed_s : float;
}

val goal_admission_result :
  Task.Anti_rationalization.review_result -> Task.Anti_rationalization.review_result
(** Pure Goal admission projection shared by execution and host publication.
    A verdict without its stated reason is a non-verdict with no automatic
    retry. The retained raw reviewer result is unchanged; this projection
    grants no dispatch, retry or domain authority. *)

type error =
  | Store_unavailable of string
  | Original_invalid of string
  | Authority_changed of string
  | Execution_pending of string
val error_to_string : error -> string

type retained
val host_installation_id : string
val host_package_id : string

val retain :
  store:Lane_addon_store.t -> installation_id:string -> package_id:string ->
  run:run_identity -> Goal_verifier_original.t -> (retained, error) result
(** Retain the complete original before dispatch. The fixed run identity is
    part of the owner summary; changing it cannot reset an existing attempt.
    A wake must first restore its original instead of inventing another run. *)

val load :
  store:Lane_addon_store.t -> installation_id:string -> package_id:string ->
  goal_id:string -> request_id:string -> attempt:int ->
  (retained option, error) result
val inventory :
  store:Lane_addon_store.t -> installation_id:string -> package_id:string ->
  (retained list, error) result
(** Strict actual scope discovery. A malformed, missing or changed published
    original rejects the inventory; partial results are not a complete list.
    Neither function creates an original, authorizes dispatch or picks a retry. *)

val inventory_for_goal :
  store:Lane_addon_store.t -> installation_id:string -> package_id:string ->
  goal_id:string -> (retained list, error) result
(** Restore all valid requests and attempts belonging to this Goal after
    classifying canonical subject keys. A noncanonical key with a parseable
    Goal/request is never loaded as an original and does not block this recovery
    inventory; the exact request frontier decides whether it prevents dispatch.
    Unattributable keys retain the no-original refusal so unknown work cannot
    authorize a fresh dispatch. Any selected original's body, identity or
    destination failure still rejects the Goal result. *)

val inventory_by_goal :
  store:Lane_addon_store.t -> installation_id:string -> package_id:string ->
  (((string * (retained list, error) result) list * (string * error) list), error) result
(** Group valid originals by Goal and return rejected metadata separately.
    The first list preserves Goal/record order and per-Goal full-body outcomes;
    the second preserves every noncanonical or unattributable request ID and
    its typed error instead of silently dropping it or failing every Goal.
    Other destinations' bodies are read only when their subject shares a
    selected Goal, where the destination conflict is refused. Discovery grants
    no dispatch or cross-Goal authority. *)

val frontier :
  store:Lane_addon_store.t -> installation_id:string -> package_id:string ->
  goal_id:string -> request_id:string -> new_run:(unit -> run_identity) ->
  (retained option, error) result
(** Restore the exact linked original before preparing a new input. A definite
    terminal refusal with typed retryable runtimes may retain one successor;
    its complete input and fixed run are staged before the parent intent.
    Restart restores that staged child without calling [new_run] or rendering
    prompts. Once the parent has observed a successor, its actual retained
    record and progress are required; a missing or different child is an error,
    never a fresh [Captured] replacement or another unknown dispatch.
    A noncanonical key for this exact Goal/request refuses selection even when
    a canonical original exists; another Goal or request's noncanonical key
    does not block this one. Unattributable metadata blocks selection only when
    no canonical original exists. Unknown dispatch, missing links and corrupt
    inventory grant no retry. [None] means no first attempt exists. The host
    serializes this request under its workspace lease through selection,
    retention and run. *)

val request_retry :
  store:Lane_addon_store.t -> installation_id:string -> package_id:string ->
  goal_id:string -> request_id:string -> requested_by:string ->
  new_run:(unit -> run_identity) -> (unit, error) result
(** Actual explicit request_complete boundary only: retain one linked retry
    after a definitely settled non-verdict, including a permanent candidate
    refusal whose configuration an actor repaired or a Goal verdict without
    its required stated reason. The exact reviewer result stays in its receipt;
    the Goal admission projection grants no judgment or automatic retry.
    Store the actor/parent
    authorization in the complete staged child before acknowledging it.
    An ordinary wake, active/unknown dispatch or judgment grants no retry. *)

val original : retained -> Goal_verifier_original.t
val run_identity : retained -> run_identity
val destination : retained -> string * string
(** The original installation_id and package_id, in that order. *)
val progress : retained -> Lane_addon_request_progress.t
val restored_receipt : retained -> (receipt option, error) result
(** A retained judgment/terminal refusal and all actual tool observations, independent
    of today's lookup availability. Captured/admission/pending returns None. *)

val retained_judgment : retained -> (Yojson.Safe.t, error) result
(** Complete validated stored judgment for the host's commit payload. Returns
    an error before judgment; never rebuilds a receipt or a model decision. *)

val tool_observations : retained ->
  (Verification_run_registry.tool_observation list, error) result
(** Restore actual saved observations, including unknown/cancelled/raised dispatch.
    This passive read grants no judgment, retry or domain effect. *)

val observed_receipt : retained -> (receipt option, error) result
(** Passive receipt restoration including admission and unknown outcomes.
    Unlike [restored_receipt], a returned value need not be a settled review;
    the caller must use progress for dispatch/commit authority. *)

val record_observer :
  store:Lane_addon_store.t -> retained:retained ->
  Lane_addon_request_receipt.event -> (retained, error) result
(** Persist an actual host publication intent/acknowledgement on this exact
    original. The host authenticates the payload and confirms publication;
    the event performs no registry write or domain effect. *)

val run :
  ?on_tool_result:(input:Yojson.Safe.t -> Tool_result.result -> unit) ->
  ?sw:Eio.Switch.t option ->
  store:Lane_addon_store.t -> retained:retained ->
  authority:Verification_authority_tools.goal_review ->
  provider_rest:(string -> Task.Anti_rationalization.provider_rest) ->
  unit -> (receipt, error) result
(** Restore exact prior judgments first. Otherwise confirm original authority
    and persist dispatch intent before using the actual retained reviewer.
    Unknown dispatch/cancellation/exception never redispatches; a proven pre-admission
    refusal may reuse the same original. Persist the structured reply and full
    tool observations atomically before returning control to the Goal host.
    Host proof commitment and run-registry publication remain separate. *)

val commit :
  store:Lane_addon_store.t -> retained:retained ->
  change:Lane_addon_request_progress.change ->
  observe:(Lane_addon_request_progress.change -> (Yojson.Safe.t, string) result) ->
  apply:(Lane_addon_request_progress.change -> (unit, string) result) ->
  (unit, error) result
(** Host-only application of the retained structured judgment. [change.after]
    must bind its original_digest and complete receipt. Recovery always uses
    the original intent, confirms an exact authoritative after-state, or
    retries only after observing that intent's own before-state. Divergence
    records a conflict, never permission to rebase or apply another decision.
    The host authenticates the actual Goal domain payload and owns the proof,
    run-registry, Candle and human-confirmation boundaries. *)
