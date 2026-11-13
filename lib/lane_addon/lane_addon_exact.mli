(** A package's exact-output requests (RFC operator-quiz §4.3, K1): the request
    a worker lists, the host's retained record of it, and the result the
    package receives.

    The record is keyed by the declaration id and the request id. A call runs
    in three steps. The runner first resolves the add-on lane; a lane that is
    unconfigured, off or without admitted slots is retained as a not-final
    attempt, and nothing was sent. Then the request is retained and the call
    is entered. The call may wait for a provider admission permit; when it
    reaches its first generation dispatch, one attempt is marked as started
    and written, and the request is sent. Its outcome is written after. So a
    request listed again after a restart gets the retained final result. A
    request whose call was cancelled, or whose process stopped, before the
    marker was written is tried again. A request whose attempt was started but
    has no outcome gets [Outcome_unknown]: the host cannot tell whether the
    provider received it, so it does not call again. A call that raises an
    exception after the marker was written ends its request as
    [Outcome_unknown]. A call that raises before [run] saved the marker sent no
    generation request: [run] is an [Error] and writes no attempt, so the next
    run reads the record as it was.

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
    means the call raised after its started marker. Same-process recovery during graceful shutdown is
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
  | Every_slot_held of { until : float }
      (** No slot of the lane may be sent this request now and at least one
          waits for a time its provider stated -- its account's stated reset,
          or the end of its own Retry-After -- so none was called. Any other
          slot is one whose provider refused this request for its size
          (RFC-exact-request-skips-a-slot-that-refused-its-input 3.2).
          [until] is the earliest stated time, Unix epoch seconds; the next
          host event after it walks the lane again
          (RFC-exact-lane-waits-for-a-stated-reset). *)

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

val final_status : final -> string
(** The [status] value {!final_to_json} writes. *)

val final_to_json : final -> Yojson.Safe.t
(** The result body a package receives. *)
val final_of_json : schema:Yojson.Safe.t -> Yojson.Safe.t -> (final, string) result
(** Strict host-result decoding, including the declared schema check for an
    answer. It never constructs a checked answer from unchecked wire JSON. *)

val original_consumer_answer_payload : request -> Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** Read an answered original's canonical envelope and its captured consumer
    schema's partial shape, returning only raw JSON. This does not check the
    package baseline, a host terminal or an execution proof and grants no
    authority to deliver or use the answer. *)

val not_final_reason : not_final -> string
(** The [reason] value {!not_final_to_json} writes. *)

val not_final_to_json : not_final -> Yojson.Safe.t
(** The reason an attempt did not end the request, as the host shows it. *)

val not_final_of_json : Yojson.Safe.t -> (not_final, string) result
(** Exactly what {!not_final_to_json} writes; any other reason or field is an error.
    A held [until] is also read as an integer, which is how the store writes
    a whole second. *)

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

type dispatch = Measurement | Generation
(** What a call is about to send. [Measurement] is a token-count request: it
    returns no answer, so it leaves no started attempt. [Generation] is the
    request whose answer ends the call, over HTTP or through an official
    client. An official client's own admission, its account authorization and
    subscription probe, runs after this guard, so a client cut off there
    leaves a started attempt. *)

type runner = before_dispatch:(dispatch -> (unit, string) result) ->
  admission_class:Agent_core.Llm_provider.Admission_class.t ->
  lane_key:string -> schema:Yojson.Safe.t ->
  size_refused:Keeper_exact_walk_receipt.http_slot list -> request -> (call, lane_unavailable) result
(** Resolves the add-on lane [lane_key] for the permitted provider [schema]
    (package baseline or request schema). The supplied [validate] still checks
    the package baseline independently. [size_refused] names the HTTP slots
    whose provider refused this request for its size while sending [schema],
    as {!run} read them from the request's retained proofs; the runner sends
    such a slot this request again only when no HTTP slot is held
    (RFC-exact-request-skips-a-slot-that-refused-its-input 3.2).
    [admission_class] comes only from the
    trusted host authority for this original request and is retained by the
    returned call, never selected by worker data. It governs the HTTP Exact
    flow, not an official client's separate process admission.
    It sends nothing and does not call [before_dispatch]; the returned [call]
    does both. The call must invoke the supplied [before_dispatch] after any
    provider admission wait, before every measurement, generation or
    official-client dispatch, naming which one it is. {!run} writes the
    started marker inside the first [Generation] guard
    and then checks the authority. A guard error stops candidate progression;
    it is not a provider/input refusal. A guard is never called to rejudge an
    already returned provider result. *)

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

module Retained_key : sig
  type t = private { declaration_id : string; request_id : string; digest : string }

  val of_record : Yojson.Safe.t -> (t, string) result
  (** The declaration, request ID and request digest a retained record of the
      Exact store names, read without decoding the rest of the record. *)

  val of_request : declaration_id:string -> request -> t
  (** The key [declaration_id] keeps this request's record and proof link
      under. *)

  val equal : t -> t -> bool

  val proof_path : t -> string
  (** The proof link of that request, below {!Lane_addon_store.root}. *)
end

val retained_final : Yojson.Safe.t -> (final option, string) result
(** The final a retained record of the Exact store holds, [None] while it is
    open. Reads the record's shape only; it binds the record to no request. *)

val proof_store_roots : Yojson.Safe.t -> string list
(** The store roots the entries of a proof link name, read without decoding
    the link. *)

val check_retained_record : store:Lane_addon_store.t -> first:Yojson.Safe.t ->
  proof:Yojson.Safe.t option -> second:Yojson.Safe.t -> (unit, string) result
(** Decode one retained record of the Exact store and its proof link with the
    reads {!run} applies before reusing them: the record envelope, its
    original request, the declaration and request identity it names, every
    attempt and final, and every proof of the link against [store] and its
    attempt. Started markers are exactly [{"started":"<32 lowercase hex>"}]
    and only occur last in an open record. Unknown terminal attempts require
    their cause, and [raised] requires nonblank exception evidence. Old null
    markers and cause-less unknown attempts are refused: deployment requires a
    hard cut of those records and their consumer originals.

    [first] is the record as read before the link, [proof] the link ([None]
    when the request has none) and [second] the record read again after it.
    Both records are bound to the request and digest [first] names; the link
    is bound to the attempts of [second]. The server writes attempt n before
    proof n, so a link read between two reads of a live record matches the
    second one. Reads nothing and writes nothing. *)

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
    Delivery refusals appended after a retained final are observations of that
    final, not later executions; their original audit entries remain intact.
    A later unresolved or never-dispatched attempt never borrows an earlier
    proof. Validate the complete original history and all sparse proofs before
    returning the actual ordinal; no caller guesses it from a worker result.
    Missing evidence remains unproven. This read performs no effect and grants
    no retry, partition, worker delivery, Memory or ACK authority. Offload the
    complete blocking scope in Eio contexts. *)

val latest_of_files : store:Lane_addon_store.t -> declaration_id:string ->
  schema:Yojson.Safe.t -> request -> record:Yojson.Safe.t option ->
  proof:Yojson.Safe.t option -> (latest_original_execution, string) result
(** What {!read_latest_original_execution} answers when the original's Exact
    record and proof link hold [record] and [proof] ([None] when a file is
    absent). [store] names only the root each proof must name. Reads nothing
    and writes nothing. *)

val read_latest_slot_observations : store:Lane_addon_store.t -> declaration_id:string ->
  schema:Yojson.Safe.t -> request -> (Exact_lane_slot_observation.t list option,string) result
(** Validate the actual latest original execution first, then read only its
    digest-bound passive companion. Old originals have [None]; current config,
    another attempt or another request never fills a missing endpoint/time.
    Diagnostic errors must not change dispatch, final delivery or domain ACK.
    Offload the whole read to a system thread in Eio contexts. *)
val proof_directory : declaration_id:string -> string
(** The Store directory below {!Lane_addon_store.root} that holds the original
    execution link of every request [declaration_id] ran. *)
val proof_request_id : declaration_id:string -> file_name:string -> Yojson.Safe.t ->
  (string, string) result
(** The original request ID of the link stored as [file_name] in
    {!proof_directory}. [Error] when the link names no request, or names one
    whose link has another file name. Checks nothing else in the link. *)
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

val observe_record : declaration_id:string -> schema:Yojson.Safe.t -> request ->
  Yojson.Safe.t option -> (retained_observation, string) result
(** What {!observe_retained} answers when the original's Exact record holds
    this JSON ([None] when there is no record). Reads nothing and writes
    nothing. *)

type recovery_error =
  | Recovery_unavailable of string
      (** The record could not be read at all. A later attempt may find it. *)
  | Recovery_invalid of string
      (** A record exists but is not a trustworthy original: it fails decoding,
          schema or domain validation, or its proof does not belong to it.
          Retrying cannot repair that, so the caller must refuse rather than
          wait for a record that will never become valid. *)

val describe_recovery_error : recovery_error -> string

val recover_retained : store:Lane_addon_store.t -> declaration_id:string ->
  schema:Yojson.Safe.t -> request -> (retained_observation, recovery_error) result
(** Restore a lost terminal publication from the latest started attempt's
    confirmed original host execution proof. The caller holds the workspace
    process lease. This operation claims the original request, rereads and
    validates its complete record and sparse proofs, checks the original
    schema, publishes only a proven [Call_ended] result and rereads it before
    returning. No runner, route, worker RPC or provider is invoked.

    An active claim is observed without writing. Missing proof and a proven
    provider refusal remain open without changing the started marker or
    synthesizing an unknown outcome. An absent record with an orphaned proof
    is an error. This grants no new execution, Memory write or source ACK;
    the immutable original consumer still validates its answer and authority.
    In Eio, protect the complete system-thread call from cancellation so
    publication and confirmation finish before returning its observation. *)

val recovery_of_files : store:Lane_addon_store.t -> declaration_id:string ->
  schema:Yojson.Safe.t -> request -> record:Yojson.Safe.t option ->
  proof:Yojson.Safe.t option -> (Yojson.Safe.t option, string) result
(** The original's Exact record as {!recover_retained} leaves it when it holds
    the claim and the original's record and proof link hold [record] and
    [proof] ([None] when a file is absent). An open record it finishes from
    its proof is the record it saves; any other record stays as it is.
    {!observe_record} reads the result as {!recover_retained} answers. Every
    [Error] is one it returns as [Recovery_invalid]. [store] names only the
    root each proof must name. Reads nothing and writes nothing. *)

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
    output cannot erase that uncertainty. Cancellation is checked after the
    request is retained and before the call is entered, and again after the
    started marker is written and before the generation request is sent.

    [Error] when [declaration_id] cannot own an add-on lane, when the
    record cannot be read or written, or when the authority is
    [Undecided]. Nothing is delivered then. A returned
    call's original host proof is saved and strictly confirmed before outcome
    publication. Confirmed proof plus its original started marker permits
    publication-only recovery without resolving or invoking a runner. Missing
    proof keeps [Outcome_unknown]; invalid or unreadable proof refuses recovery.
    A call cancelled after the first generation guard wrote the marker leaves
    its attempt started, even when the request was not sent yet. A call
    cancelled before that leaves the request retained with no started attempt,
    and the next run tries it again. A call that ends without a generation
    dispatch writes the marker before its proof. A marker save that reports a
    failure stops the call before its dispatch and is an [Error]. An exception
    from the runner's resolution step propagates; nothing was sent and no
    attempt was written for it. *)
