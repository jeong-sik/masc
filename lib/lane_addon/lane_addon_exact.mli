(** A package's exact-output requests (RFC operator-quiz §4.3, K1): the request
    a worker lists, the host's retained record of it, and the result the
    package receives.

    The record is keyed by the declaration id and the request id. A call runs
    in two steps. The runner first resolves the add-on lane; a lane that is
    unconfigured, off or without admitted slots is retained as a not-final
    attempt, and nothing was sent. Only then is one attempt marked as started
    and written, and the call is sent. Its outcome is written after. So a
    request listed again after a restart gets the retained final result, and a
    request whose attempt was started but has no outcome gets
    [Outcome_unknown]: the host cannot tell whether the provider received it,
    so it does not call again.

    The Lane store lives under the base path, and only the server process that
    holds the base-path lease ([Server_startup_takeover.acquire_base_path_lock])
    calls [run]. So the requests this process is running are every request
    being run, and a started attempt this process is not running was cut off by
    a crash or a cancellation. *)

type role = User | Assistant
type message = { role : role; text : string }
(** Text conversation turns. System text belongs to [request.system]; tool
    messages and multimodal blocks are not accepted by this protocol. *)

type request = private
  { request_id : string
  ; output : string  (** A [world.exact_outputs] name. *)
  ; system : string option
  ; messages : message list  (** Original roles and order are retained. *)
  ; schema : Yojson.Safe.t option
      (** Canonical request schema. Only an explicitly granted package output
          may use it; the package baseline remains mandatory. *)
  }

val request_of_json : Yojson.Safe.t -> (request, string) result
(** Exactly [kind = "exact_output"], [request_id], [output], [messages] and an
    optional [system] and [schema]. A request schema must be a canonical JSON
    object; its dialect belongs to the consumer. Each message is exactly [{"role": "user"|"assistant",
    "text": string}]. Unknown roles, extra or duplicate keys, a blank id or no
    message are refused. Roles participate in the retained request digest. *)

val request_to_json : request -> Yojson.Safe.t

val digest : request -> string
(** SHA-256 of the request's canonical JSON. The same request id with a
    different digest is [Request_id_reused]. *)

type checked
(** An answer that matched the package's declared baseline schema. The [run]
    and [validate_answer] paths additionally check a supplied request schema's
    partial required shape. This does not prove full compliance with a
    consumer's request-schema dialect. Constructed by the
    [validate] function [run] hands to a call, or strict [final_of_json] decoding. *)

val checked_json : checked -> Yojson.Safe.t

val schema_for_request : output:Lane_addon_types.exact_output -> request -> (Yojson.Safe.t, string) result
(** Check the exact output name and its request-schema grant, then return the
    provider requirement. Does not resolve a route or call a provider. *)
val validate_answer : output:Lane_addon_types.exact_output -> request -> Yojson.Safe.t -> (checked, string) result
(** Recheck authority and the package baseline, plus the same partial shape
    check for new and retained results. The request cannot weaken the baseline. *)

type input_refusal =
  | Input_capacity
  | Context_overflow
  | Invalid_request
  | Request_body_refused

type usage = { input_tokens : int; output_tokens : int }

(** How a sent call ended the request. *)
type call_final =
  | Answered of { output : checked; slot : string; usage : usage option }
  | Invalid_output of { detail : string }
      (** Every slot answered and no answer matched the schema. *)
  | Input_refused of input_refusal
      (** A provider refused this input itself; the same input cannot pass. *)
  | Output_limit_reached of { detail : string }
      (** The admitted candidates exhausted the provider's output limit.
          Kept distinct from invalid JSON, incomplete output and schema/domain
          rejection. This final never permits replay of the original request;
          any smaller successor is a separate consumer-owned decision. *)

(** What a package receives. Each one ends the request. *)
type final =
  | Call_final of call_final
  | Outcome_unknown
      (** A call may have been sent and no outcome was retained. *)
  | Not_allowed of { reason : string }
      (** The effective package does not permit this output. A newly refused
          request retains this final result, even after the selection changes.
          A refusal to deliver an already retained answer leaves that original
          answer intact; it can be delivered when the output is selected again. *)
  | Request_id_reused

(** Why a started call has no retained outcome. Only host code sees this;
    workers continue receiving [Outcome_unknown] without a cause. *)
type unknown_cause = Interrupted | Cut | Raised
(** [Interrupted] means another server incarnation left the started marker;
    [Cut] means this process no longer runs its own started attempt; [Raised]
    means the call raised. Same-process recovery during graceful shutdown is
    still [Cut]. A completed original proof takes priority over either marker
    cause. The incarnation is a process-wide, memory-only random 128-bit value. *)

type retained_final =
  | Retained_call of call_final
  | Retained_unknown of unknown_cause
  | Retained_not_allowed of { reason : string }
  | Retained_request_id_reused

val delivered : retained_final -> final
(** Remove host-only cause evidence for worker delivery. *)
val refused_before_host : final -> bool
(** [true] only for [Call_final (Input_refused Request_body_refused)]. The
    worker refuses a request no host listing reply can carry before the host
    retains it ([submit] in addons/exact_worker.py, the [fits] check that
    precedes [store.write accepted]). So no host terminal and no latest
    execution proof can exist for this final, and it carries no answer.
    Every consumer that confirms a worker final against the host store asks
    this one question when the host holds no record. *)
val retained_final_to_json : retained_final -> Yojson.Safe.t
val retained_final_of_json : schema:Yojson.Safe.t -> Yojson.Safe.t -> (retained_final, string) result
(** Strict host evidence codec. Unknown outcomes require one of [interrupted],
    [cut], [raised]; cause-less worker results are not host evidence. *)

(** Why the add-on lane could not take a call. Nothing was sent. *)
type lane_unavailable =
  | Lane_unconfigured
  | Lane_off
  | No_admitted_slots
  | Lane_registry_unavailable of { detail : string }
      (** The host has no published lane registry right now: before startup
          published one, or while a replacement is being committed. *)

(** A provider refusal of a sent call that may pass without changing the
    input. *)
type provider_refusal =
  | Provider_unavailable of { detail : string }
      (** Rate limit, overload, network or timeout. *)
  | Provider_auth_refused of { detail : string }
  | Provider_configuration_refused of { detail : string }
      (** A slot's runtime, quota, billing or the host could not take the
          call. It may pass after the operator changes one of them. *)

(** Why an attempt did not end the request. It stays listed and is tried
    again on the next host event; each attempt is retained as evidence. *)
type not_final =
  | Lane_unavailable of lane_unavailable
  | Provider_refused of provider_refusal
  | Attempt_in_progress
      (** This process is running the same request now. *)

type attempt =
  | Final of final
  | Not_final of not_final

val final_to_json : final -> Yojson.Safe.t
(** The result body a package receives. *)
val final_of_json : schema:Yojson.Safe.t -> Yojson.Safe.t -> (final, string) result
(** Strict host-result decoding, including the declared schema check for an
    answer. It never constructs a checked answer from unchecked wire JSON. *)

val not_final_to_json : not_final -> Yojson.Safe.t
(** The reason an attempt did not end the request, as the host shows it. *)

val not_final_of_json : Yojson.Safe.t -> (not_final, string) result
(** Exactly what {!not_final_to_json} writes; any other reason or field is an error. *)

(** What a sent call can end in. *)
type call_outcome =
  | Call_ended of call_final
  | Call_refused of provider_refusal

type execution_result = {
  outcome : call_outcome;
  receipt : Keeper_exact_walk_receipt.t;
}
(** Host-created evidence of the original call. It is retained separately from
    the unchanged worker outcome and cannot be supplied through worker JSON. *)

type call = validate:(Yojson.Safe.t -> (checked, string) result) -> execution_result
(** Sends the call. [validate] checks one answer against the package's
    declared schema. Raising other than [Eio.Cancel.Cancelled] is recorded as
    [Outcome_unknown]. *)

type dispatch_guard = unit -> (unit, string) result
(** Fresh execution authority, checked before each actual provider/measurement
    dispatch. An error stops the walk; it never invalidates an answer already
    returned by a provider. Not used for local retained terminal observation. *)

type runner = before_dispatch:dispatch_guard -> admission_class:Agent_core.Llm_provider.Admission_class.t ->
  lane_key:string -> schema:Yojson.Safe.t -> request -> (call, lane_unavailable) result
(** Resolves the add-on lane [lane_key] for the permitted provider [schema]
    (package baseline or request schema). The supplied [validate] still checks
    the package baseline independently. [admission_class] comes only from the
    trusted host authority for this original request and is retained by the
    returned call, never selected by worker data. It governs the HTTP Exact
    flow, not an official client's separate process admission.
    It sends nothing; the returned [call] does. The call must invoke the
    supplied [before_dispatch] after any provider admission wait, before every
    measurement, generation or official-client dispatch. An authority error
    stops candidate progression; it is not a provider/input refusal. A guard
    is never called to rejudge an already returned provider result. *)

type output_validator = Yojson.Safe.t -> (unit, string) result
type execution_scope = (unit -> (attempt, string) result) -> (attempt, string) result
(** Inline host lifecycle scope covering fresh initial authority, admission,
    started intent, actual provider walk and proof/final publication. New
    execution only; retained terminals never register another effect scope. *)
type request_authorization = {
  admission_class : Agent_core.Llm_provider.Admission_class.t;
  validate_output : output_validator;
  before_dispatch : dispatch_guard;
  with_execution : execution_scope;
}
(** Why the host consumer grants no authority for a request. *)
type authority_refusal =
  | Unowned of { reason : string }
      (** The host has no original request with this ID, so none can grant
          it later. The request ends as [Not_allowed]. *)
  | Undecided of { detail : string }
      (** The owner cannot decide now: its record could not be read, or it
          does not match the request. Nothing is written under the ID, which
          its original may still own, and the request stays listed. *)
type execution_authority =
  store:Lane_addon_store.t -> declaration_id:string -> package:Lane_addon_types.package ->
  request -> (request_authorization, authority_refusal) result
(** Trusted host binding to an original consumer's pure domain validator and
    execution admission policy. Resolution may read host-owned state; the
    returned validator must perform no effects. All fields belong to the same
    verified original request. Worker package/lane names are not policy grants.
    A worker cannot supply this port or disable it through Hooks.
    Either refusal refuses both dispatch and delivery without replacing the
    original result. Authority is resolved again on every [run], including
    replay; delivering a retained result never invokes the runner. The
    authorization is not serialized into the worker request or a durable
    admission-class audit.
    [before_dispatch] is execution-only: an initial refusal occurs before the
    started marker, later guard vetoes stop the actual walk. Retained terminal
    replay uses only original validation and never invokes this guard. *)

val check_retained_record : Yojson.Safe.t -> (unit, string) result
(** Decode one retained record of the Exact store with the reads {!run}
    applies before reusing it: the record envelope, its original request, the
    declaration and request identity it names, and every attempt and final.
    Started markers are exactly [{"started":"<32 lowercase hex>"}] and only
    occur last in an open record. Unknown terminal attempts require their
    cause, and [raised] requires nonblank exception evidence. Old null markers
    and cause-less unknown attempts are refused: deployment requires a hard
    cut of those records and their consumer originals. Reads nothing else and
    writes nothing. *)

type retained_observation = Retained_absent | Retained_open | Retained_terminal of retained_final

type original_execution =
  | No_completed_original
  | Completed_original of execution_result

val read_original_execution : store:Lane_addon_store.t -> declaration_id:string ->
  schema:Yojson.Safe.t -> attempt_ordinal:int -> request ->
  (original_execution, string) result
(** Read the original host call evidence under the caller's original Store,
    request, schema and one-based attempt identity. Missing proof remains
    unproven; malformed, conflicting and unreadable evidence returns [Error].
    Package-only answers use the declared value schema; consumer-schema
    answers use the same partial shape guard as {!validate_answer}. The
    original request and canonical schema remain bound to the proof. This
    read does not establish full consumer-dialect compliance or replace the
    fresh package baseline and consumer authority checks before delivery.
    A complete proof may precede final publication. This read never claims,
    writes, resolves a route, delivers to a worker or calls a provider. It grants
    no Memory, queue-consumption or new execution authority. Proof identity
    includes the original Store root; moving the workspace directory makes
    that proof a conflicting identity and returns [Error]. Offload the whole
    blocking scope to a system thread. *)
type latest_original_execution =
  | No_completed_latest
  | Completed_latest of { attempt_ordinal : int; execution : execution_result }

val read_latest_original_execution : store:Lane_addon_store.t -> declaration_id:string ->
  schema:Yojson.Safe.t -> request -> (latest_original_execution, string) result
(** Strictly read the actual last original attempt and its matching host proof.
    A later unresolved or never-dispatched attempt never borrows an earlier
    proof. Validate the complete original history and all sparse proofs before
    returning the actual ordinal; no caller guesses it from a worker result.
    Missing evidence remains unproven. This read performs no effect and grants
    no retry, partition, worker delivery, Memory or ACK authority. Offload the
    complete blocking scope in Eio contexts. *)
val observe_retained : store:Lane_addon_store.t -> declaration_id:string ->
  schema:Yojson.Safe.t -> request -> (retained_observation, string) result
(** Read only the original host Exact record under the caller's workspace
    authority. Strictly check the complete canonical envelope, declaration and
    request ID, original request/digest, attempt outcomes and terminal against
    the caller's original schema, using the package value contract or original
    consumer partial shape contract as in {!read_original_execution}.
    Missing/malformed/conflicting records remain
    distinct. A started attempt without a final is [Retained_open], since this
    read cannot determine whether its provider is still running. It does not
    claim, write, resolve a route, call a provider or synthesize Outcome_unknown.

    This is an observation for the trusted original consumer, including while
    the worker is Off. It grants no package/worker delivery, new execution or
    domain write authority. That consumer first restores its immutable capture
    and acknowledged ancestry, supplies the original request/schema, validates
    the full domain answer and rechecks authority before its separate effects.
    Run the complete blocking read/validation scope on a system thread in Eio. *)

val run :
  store:Lane_addon_store.t ->
  declaration_id:string ->
  package:Lane_addon_types.package ->
  runner:runner ->
  authorize_request:execution_authority ->
  request ->
  (attempt, string) result
(** Request-schema permission is checked before dispatch and delivery without
    replacing an already retained final. A retained [Answered] is checked against
    the current package baseline and the original request's partial required
    shape and trusted consumer semantics before delivery. The same pure checks
    are supplied inside the original HTTP/CLI candidate walk before acceptance.
    One that no longer matches is delivered as
    [Invalid_output] and the provider is not called again.

    Request identity is checked before output selection. A refused output
    cannot reuse a retained id with another body. New refusals are retained;
    refusing delivery of an existing final records the refusal without
    replacing the original final. An [Unowned] authority refusal is one of
    these refusals: the worker receives [Not_allowed] and the request leaves
    its listing. A started attempt without an outcome or
    confirmed execution proof is retained as [Outcome_unknown] before selection is checked, so disabling an
    output cannot erase that uncertainty. Cancellation is checked after the started
    record is written and immediately before entering the provider call.

    [Error] when [declaration_id] cannot own an add-on lane, when the
    record cannot be read or written, or when the authority is
    [Undecided]. Nothing is delivered then. A returned
    call's original host proof is saved and strictly confirmed before outcome
    publication. Confirmed proof plus its original started marker permits
    publication-only recovery without resolving or invoking a runner. Missing
    proof keeps [Outcome_unknown]; invalid or unreadable proof refuses recovery.
    A cancelled call leaves its
    attempt started too. An exception from the runner's resolution step
    propagates; nothing was sent and no attempt was written for it. *)
