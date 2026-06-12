(** Discord_rest_client — outbound Discord REST API client.

    Primary functions: post a message to a channel and trigger the
    channel typing indicator. Threads, DMs, and
    guild text channels are all addressed by the same snowflake
    [channel_id], so no per-surface dispatch is needed.

    Delegates the wire-level work to {!Masc_http_client.post_sync}
    (the repo-wide piaf-backed pool). Must be called inside an Eio
    context (the pool's transport relies on Eio fibers).

    See: docs/rfc/RFC-0203-discord-builtin-gateway.md §Modules,
         lib/masc_http_client/masc_http_client.mli *)

val message_content_limit : int
(** Discord text-message content limit, in Unicode scalar units.
    Messages longer than this must be split into multiple payloads. *)

(** Typed error from Discord REST. Closed sum — anything Discord
    returns that does not map to one of these becomes [Other]
    (preserving the JSON for inspection) so we never silently consume
    a new error variant. *)
type error =
  | Network of string
    (** Transport-level failure (DNS, TLS, timeout, body cap). *)
  | Http_status of { code : int; body : string }
    (** Non-2xx HTTP status whose body did not parse as a Discord
        error envelope. *)
  | Discord_api of { code : int; message : string }
    (** Non-2xx HTTP status carrying a Discord error envelope
        ({ "code": int, "message": string }). *)
  | Other of string
    (** 2xx response whose body did not contain an [id], or any
        other unexpected shape. Always includes a one-line reason. *)

val pp_error : Format.formatter -> error -> unit

val send_message :
  token:string ->
  channel_id:string ->
  content:string ->
  ?reply_to_message_id:string ->
  unit ->
  (string, error) result
(** [send_message ~token ~channel_id ~content ?reply_to_message_id ()]
    posts to [POST /api/v10/channels/{channel_id}/messages].
    When [reply_to_message_id] is provided, the message is sent as
    a reply (Discord threads the conversation). Returns the created
    message id on [Ok].

    Works for guild text channels, DM channels, and threads.

    @raise nothing — failures are surfaced as typed {!error}. *)

val edit_message :
  token:string ->
  channel_id:string ->
  message_id:string ->
  content:string ->
  unit ->
  (unit, error) result
(** [edit_message ~token ~channel_id ~message_id ~content ()] patches
    [PATCH /api/v10/channels/{channel_id}/messages/{message_id}].
    Used for streaming message display — the message content is updated
    in-place on Discord. Content exceeding {!message_content_limit} is
    silently truncated to the first 2000 characters.

    @raise nothing — failures are surfaced as typed {!error}. *)

val trigger_typing :
  token:string ->
  channel_id:string ->
  unit ->
  (unit, error) result
(** [trigger_typing ~token ~channel_id ()] posts to
    [POST /api/v10/channels/{channel_id}/typing]. Discord expires the
    typing indicator after 10 seconds, so callers handling long-running
    work should refresh it periodically until the final message is sent.

    @raise nothing — failures are surfaced as typed {!error}. *)

(** {1 Internal — exposed for unit testing}

    These functions decompose [send_message] so request shape and
    response classification can be tested without a real HTTP round
    trip. They are not part of the connector's stable API; callers
    should reach for {!send_message}. *)

val build_request :
  token:string ->
  channel_id:string ->
  content:string ->
  ?reply_to_message_id:string ->
  unit ->
  string * (string * string) list * string
(** [(url, headers, body) = build_request ~token ~channel_id ~content
    ?reply_to_message_id ()].  Headers include Authorization (Bot
    scheme), Content-Type, and a Discord-required User-Agent.  When
    [reply_to_message_id] is provided, the body includes a
    [message_reference] field so Discord threads the reply. *)

val build_typing_request :
  token:string ->
  channel_id:string ->
  unit ->
  string * (string * string) list * string
(** [(url, headers, body) = build_typing_request ~token ~channel_id ()].
    The body is empty; headers include Authorization and User-Agent. *)

val build_edit_request :
  token:string ->
  channel_id:string ->
  message_id:string ->
  content:string ->
  unit ->
  string * (string * string) list * string
(** [(url, headers, body) = build_edit_request ~token ~channel_id
    ~message_id ~content ()].  Content exceeding {!message_content_limit}
    is silently truncated. *)

val parse_response :
  status:int ->
  body:string ->
  (string, error) result
(** Classifies a Discord HTTP response:
    - 2xx with JSON object containing [id] string  → [Ok id]
    - 2xx with body shape mismatch                 → [Error (Other _)]
    - non-2xx with Discord error envelope          → [Error (Discord_api _)]
    - non-2xx without that envelope                → [Error (Http_status _)] *)

val parse_empty_response :
  status:int ->
  body:string ->
  (unit, error) result
(** Classifies a Discord HTTP response for empty-success endpoints:
    - 2xx → [Ok ()]
    - non-2xx with Discord error envelope → [Error (Discord_api _)]
    - non-2xx without that envelope → [Error (Http_status _)] *)
