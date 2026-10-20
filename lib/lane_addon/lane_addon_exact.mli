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

type request = private
  { request_id : string
  ; output : string  (** A [world.exact_outputs] name. *)
  ; system : string option
  ; messages : string list  (** User messages, in order. Images are not part of v1. *)
  }

val request_of_json : Yojson.Safe.t -> (request, string) result
(** Exactly [kind = "exact_output"], [request_id], [output], [messages] and an
    optional [system]. Any other key, a blank id or no message is refused. *)

val request_to_json : request -> Yojson.Safe.t

val digest : request -> string
(** SHA-256 of the request's canonical JSON. The same request id with a
    different digest is [Request_id_reused]. *)

type checked
(** An answer that matched the package's declared schema. Only the
    [validate] function [run] hands to a call makes one. *)

val checked_json : checked -> Yojson.Safe.t

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

(** What a package receives. Each one ends the request. *)
type final =
  | Call_final of call_final
  | Outcome_unknown
      (** A call may have been sent and no outcome was retained. *)
  | Not_allowed of { reason : string }
      (** The manifest does not declare the output. Only a package change can
          make the same request pass. *)
  | Request_id_reused

(** Why the add-on lane could not take a call. Nothing was sent. *)
type lane_unavailable =
  | Lane_unconfigured
  | Lane_off
  | No_admitted_slots

(** A provider refusal of a sent call that may pass without changing the
    input. *)
type provider_refusal =
  | Provider_unavailable of { detail : string }
      (** Rate limit, overload, network or timeout. *)
  | Provider_auth_refused of { detail : string }

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

(** What a sent call can end in. *)
type call_outcome =
  | Call_ended of call_final
  | Call_refused of provider_refusal

type call = validate:(Yojson.Safe.t -> (checked, string) result) -> call_outcome
(** Sends the call. [validate] checks one answer against the package's
    declared schema. Raising other than [Eio.Cancel.Cancelled] is recorded as
    [Outcome_unknown]. *)

type runner = lane_key:string -> schema:Yojson.Safe.t -> request -> (call, lane_unavailable) result
(** Resolves the add-on lane [lane_key] for a call against the package's
    declared [schema]. It sends nothing; the returned [call] does. *)

val run :
  store:Lane_addon_store.t ->
  declaration_id:string ->
  package:Lane_addon_types.package ->
  runner:runner ->
  request ->
  (attempt, string) result
(** A retained [Answered] is checked against the schema the package declares
    now before it is delivered. One that no longer matches is delivered as
    [Invalid_output] and the provider is not called again.

    [Error] when [declaration_id] cannot own an add-on lane, or when the
    record cannot be read or written. Nothing is delivered then. If the
    outcome of a sent call cannot be written, the started attempt stays, and
    a later [run] reads it as [Outcome_unknown]. A cancelled call leaves its
    attempt started too. An exception from the runner's resolution step
    propagates; nothing was sent and no attempt was written for it. *)
