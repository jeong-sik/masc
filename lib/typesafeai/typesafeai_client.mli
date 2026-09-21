(** HTTP client for System One evaluation servers.

    One request is posted to a list of {!destination}s in the order given,
    each with its own model id and bearer key, until one of them answers.
    Two servers speak this protocol: TypeSafe AI's own
    ([https://api.typesafe.ai/v1/systemone], model [jev-latest]) and
    OpenRouter's ([https://openrouter.ai/api/v1/systemone], model
    [~typesafe/jev-latest]), whose response adds [id], [provider] and
    [usage.cost], which the decoder ignores. Sources, read 2026-09-21:
    docs.typesafe.ai/api and openrouter.ai/docs/guides/community/typesafe-sdk.
    Uses {!Masc_http_client.post_sync} for outbound keep-alive pooling. *)

type destination =
  { endpoint : string  (** the URL the request is posted to *)
  ; model : string  (** the model id as this server names it *)
  ; api_key : string  (** the bearer key this server takes *)
  }

type refusal =
  | Transport_failure of string
  | Http_response_failure of
      { status : int
      ; destination_uri : string
      ; body : string
      ; detail : string
      }
(** What one destination did instead of answering: a transport diagnostic,
    or the response it actually returned. [body] removes that destination's
    API key and credential-bearing endpoint before observation, preserving
    every other received byte. JSON observations use a string for UTF-8
    bodies and the [encoding]/[content]/[total_bytes] base64 representation
    otherwise. Diagnostics are valid UTF-8. [destination_uri] is the
    observation URL: userinfo, query and fragment removed; the outbound URL
    is unchanged. Response content is private evidence, not guaranteed free
    of secrets that the remote server chose to echo. *)

type attempt =
  { destination_uri : string
  ; model : string
  ; refusal : refusal
  }
(** One destination asked, the model id it was asked for, and its refusal. *)

type failure =
  { first_attempt : attempt
  ; later_attempts : attempt list
  }
(** Every destination the walk asked refused, in the order asked. The walk
    always asks the first destination, so there is always a first attempt. *)

type evaluated =
  { response : Typesafeai_types.eval_response
  ; destination_uri : string
  ; request_body_sha256 : string
  ; passed_over : attempt list
  }
(** A decoded response, the destination that gave it, the sha256 of the exact
    request bytes that destination received, and the destinations asked
    before it with their refusals: [[]] when the first destination answered. *)

type disposition =
  | Ask_next_destination
  | Stop_walk

val disposition_of_refusal : refusal -> disposition
(** Whether a refusal ends the walk. A destination that says the request body
    itself is wrong ends it, because the next destination would receive the
    same bytes: HTTP 400 (OpenRouter: malformed input), 413 (OpenRouter:
    payload too large) and 422 (TypeSafe: validation failed). Every other
    refusal is about the destination that gave it, so the next one is asked:
    its key (401, 403), its account (402), its route (404), its capacity
    (429, 5xx), a body it returned that does not decode, or no response. *)

val endpoint_for_observation : string -> string
val refusal_to_string : refusal -> string
val refusal_to_yojson : refusal -> Yojson.Safe.t

val attempts : failure -> attempt list
(** In the order asked. *)

val failure_to_string : failure -> string
(** One attempt renders as its refusal; several render as the list of them. *)

val failure_to_yojson : failure -> Yojson.Safe.t

val evaluate :
  ?timeout_sec:float ->
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  destinations:destination * destination list ->
  state:Yojson.Safe.t ->
  questions:(string * Typesafeai_types.question) list ->
  unit ->
  (evaluated, failure) result
(** Asks the destinations in order: the first always, each later one only
    when {!disposition_of_refusal} says so for the refusal before it. Each
    destination receives the request body with its own model id, so the
    [request_body_sha256] of the answer names what that destination read.
    [timeout_sec] bounds each destination's request/response exchange
    separately and defaults to
    {!Masc_http_client.default_request_timeout_sec}, the deadline the other
    outbound clients share. *)

module For_testing : sig
  val transport_failure : endpoint:string -> api_key:string -> string -> refusal
end
