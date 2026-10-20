(** A package's exact-output requests (RFC operator-quiz §4.3, K1): the request
    a worker lists, the host's retained record of it, and the result the
    package receives.

    The record is keyed by the declaration id and the request id, and it is
    written before the runner is asked, with one attempt marked as started.
    The attempt's outcome is written after. So a request listed again after a
    restart gets the retained final result, and a request whose attempt was
    started but has no outcome gets [Outcome_unknown]: the host cannot tell
    whether the provider received it, so it does not call again. *)

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

type input_refusal =
  | Input_capacity
  | Context_overflow
  | Invalid_request
  | Request_body_refused

type usage = { input_tokens : int; output_tokens : int }

(** What a package receives. Each one ends the request. *)
type final =
  | Answered of { output : Yojson.Safe.t; slot : string; usage : usage option }
  | Invalid_output of { detail : string }
      (** Every slot answered and no answer matched the schema. *)
  | Input_refused of input_refusal
      (** A provider refused this input itself; the same input cannot pass. *)
  | Outcome_unknown
      (** A call may have been sent and no outcome was retained. *)
  | Not_allowed of { reason : string }
      (** The manifest does not declare the output. Only a package change can
          make the same request pass. *)
  | Request_id_reused

(** Why an attempt did not end the request. It stays listed and is tried
    again on the next host event; each attempt is retained as evidence. *)
type not_final =
  | Lane_unconfigured
  | Lane_off
  | No_admitted_slots
  | Provider_unavailable of { detail : string }
      (** Rate limit, overload, network or timeout. *)
  | Provider_auth_refused of { detail : string }
  | Attempt_in_progress
      (** Another worker of the same installation is running this request now. *)

type attempt =
  | Final of final
  | Not_final of not_final

val final_to_json : final -> Yojson.Safe.t
(** The result body a package receives. *)

type runner = lane_key:string -> schema:Yojson.Safe.t -> request -> attempt
(** Runs one exact-output call on the add-on lane [lane_key] against the
    package's declared [schema]. Raising other than [Eio.Cancel.Cancelled]
    is recorded as [Outcome_unknown]. *)

val run :
  store:Lane_addon_store.t ->
  declaration_id:string ->
  package:Lane_addon_types.package ->
  runner:runner ->
  request ->
  (attempt, string) result
(** [Error] only when the record cannot be read or written; then nothing is
    delivered and nothing is consumed. A cancelled runner leaves its attempt
    started, which a later [run] reads as [Outcome_unknown]. *)
