(** HTTP client for System One evaluation servers.

    One request is posted to a list of {!destination}s in the order given,
    each with its own model id and bearer key, until one of them answers.
    Two servers speak this protocol: TypeSafe AI's own
    ([https://api.typesafe.ai/v1/systemone], model [jev-latest]) and
    OpenRouter's ([https://openrouter.ai/api/v1/systemone], model
    [~typesafe/jev-latest]), whose response adds [id], [provider] and
    [usage.cost], which the decoder ignores. Sources, read 2026-09-21:
    docs.typesafe.ai/api and openrouter.ai/docs/guides/community/typesafe-sdk.
    Uses {!Masc_http_client.post_sync} for outbound keep-alive pooling.

    A destination's key goes to that destination's endpoint and nowhere else.
    Whoever can name a destination can therefore send a secret to a URL of
    their choosing; that is the same trust runtime.toml already carries for
    [\[providers.<id>\]] endpoints and their credentials. *)

type destination =
  { endpoint : string  (** the URL the request is posted to *)
  ; model : string  (** the model id as this server names it *)
  ; api_key : string  (** the bearer key this server takes *)
  }

type destination_id =
  { destination_uri : string
  ; model : string
  }
(** A destination without its key, for records and projections.
    [destination_uri] is the observation URL: userinfo, query and fragment
    removed; the outbound URL is unchanged. [model] is the id the destination
    was asked for, which is part of the request body it received. *)

val identify : destination -> destination_id
val destination_id_to_yojson : destination_id -> Yojson.Safe.t

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
    otherwise. Diagnostics are valid UTF-8. Response content is private
    evidence, not guaranteed free of secrets that the remote server chose to
    echo. *)

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
(** Every destination refused, in the order asked. The walk always asks the
    first destination, so there is always a first attempt, and it asks every
    destination before it fails, so the attempts are the whole list. *)

type evaluated =
  { response : Typesafeai_types.eval_response
  ; destination : destination_id
  ; request_body_sha256 : string
  ; passed_over : attempt list
  }
(** A decoded response, the destination that gave it, the sha256 of the exact
    request bytes that destination received, and the destinations asked
    before it with their refusals: [[]] when the first destination answered.
    [destination.model] is the id requested; [response.model] is the id the
    server says answered. *)

val endpoint_for_observation : string -> string
val refusal_to_string : refusal -> string
val refusal_to_yojson : refusal -> Yojson.Safe.t
val attempt_to_yojson : attempt -> Yojson.Safe.t

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
(** Asks the destinations in order until one answers. Every refusal moves the
    walk to the next destination, whatever it says: the destinations share the
    state and the questions but not the body, since each is asked for its own
    model id, and their limits differ, so one server calling a request wrong
    or too large says nothing about the next. A request that really is wrong
    costs one refused call per destination and ends with all of them in the
    {!failure}. Cancellation is not a refusal: it propagates and nothing more
    is asked.

    [timeout_sec] bounds each destination's request/response exchange
    separately and defaults to
    {!Masc_http_client.default_request_timeout_sec}, the deadline the other
    outbound clients share. *)

module For_testing : sig
  val transport_failure : endpoint:string -> api_key:string -> string -> refusal
end
