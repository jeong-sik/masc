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

val split_at_codepoint : string -> limit:int -> string * string
(** [split_at_codepoint s ~limit] returns [(head, tail)] where [head] is
    a valid-UTF-8 prefix of [s] of at most [limit] Unicode scalar values
    and [tail] is the remainder ([""] when [s] fits). Splitting on
    codepoint boundaries (not bytes) keeps each piece valid UTF-8 so
    Discord does not reject it with a 400. *)

val chunk_by_codepoint : string -> limit:int -> string list
(** [chunk_by_codepoint s ~limit] splits [s] into chunks of at most
    [limit] Unicode scalar values each, every chunk valid UTF-8.
    [chunk_by_codepoint "" ~limit] is [[]]. *)

val truncate_to_limit : string -> string
(** Truncate to {!message_content_limit} Unicode scalar values on a
    codepoint boundary (valid UTF-8). Used for PATCH edits. *)

(** Typed error from Discord REST. Response bodies never cross this
    boundary; failures retain only request correlation, status/code,
    reason, and body byte count. *)
type error =
  | Network of string
    (** Transport-level failure (DNS, TLS, timeout, body cap). *)
  | Http_status of { request_id : string; code : int; body_bytes : int }
    (** Non-2xx HTTP status whose body did not parse as a Discord
        error envelope. *)
  | Discord_api of { request_id : string; http_status : int; code : int }
    (** Non-2xx HTTP status carrying a Discord error envelope. [http_status]
        preserves authentication/authorization classification even when the
        Discord payload's own [code] is zero or unrelated. *)
  | Other of { request_id : string; reason : string; body_bytes : int }
    (** A response whose body or shape was not usable. *)

type snowflake
(** Validated Discord identifier: a non-empty decimal string. *)

val snowflake_of_string : string -> (snowflake, string) result
val snowflake_to_string : snowflake -> string

val pp_error : Format.formatter -> error -> unit

val send_message :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  token:string ->
  channel_id:string ->
  content:string ->
  ?reply_to_message_id:string ->
  ?allowed_user_mentions:string list ->
  unit ->
  (string, error) result
(** [send_message ~token ~channel_id ~content ?reply_to_message_id ()]
    posts to [POST /api/v10/channels/{channel_id}/messages].
    When [reply_to_message_id] is provided, the message is sent as
    a reply (Discord threads the conversation). [allowed_user_mentions]
    contains the only user snowflakes Discord may notify; when omitted or
    empty, user, role, and everyone mentions are all suppressed. Returns the
    created message id on [Ok].

    Works for guild text channels, DM channels, and threads.

    @raise nothing — failures are surfaced as typed {!error}. *)

val edit_message :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
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
    silently truncated to the first 2000 Unicode scalar values on a
    codepoint boundary (see {!truncate_to_limit}).

    @raise nothing — failures are surfaced as typed {!error}. *)

val trigger_typing :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  token:string ->
  channel_id:string ->
  unit ->
  (unit, error) result
(** [trigger_typing ~token ~channel_id ()] posts to
    [POST /api/v10/channels/{channel_id}/typing]. Discord expires the
    typing indicator after 10 seconds, so callers handling long-running
    work should refresh it periodically until the final message is sent.

    @raise nothing — failures are surfaced as typed {!error}. *)

(** {1 Read-only Discord resources} *)

val get_channel :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  token:string ->
  channel_id:snowflake ->
  unit ->
  (Yojson.Safe.t, error) result
(** Fetch the Discord channel object for [channel_id]. *)

val get_guild :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  token:string ->
  guild_id:snowflake ->
  unit ->
  (Yojson.Safe.t, error) result
(** Fetch the Discord guild object for [guild_id]. *)

val get_guild_channels :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  token:string ->
  guild_id:snowflake ->
  unit ->
  (Yojson.Safe.t, error) result
(** List all guild channels visible to the bot. *)

val get_channel_messages :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  token:string ->
  channel_id:snowflake ->
  ?limit:int ->
  ?before:snowflake ->
  ?after:snowflake ->
  unit ->
  (Yojson.Safe.t, error) result
(** Fetch channel messages, newest first. [before] and [after] are mutually
    exclusive at the Discord API boundary. *)

val get_guild_members :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  token:string ->
  guild_id:snowflake ->
  ?query:string ->
  ?limit:int ->
  ?after:snowflake ->
  unit ->
  (Yojson.Safe.t, error) result
(** List or search members of [guild_id]. A non-empty [query] uses Discord's
    guild-member search endpoint; without it, the paged member-list endpoint
    is used. *)

val get_guild_member :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  token:string ->
  guild_id:snowflake ->
  user_id:snowflake ->
  unit ->
  (Yojson.Safe.t, error) result
(** Fetch one guild member, retaining the user's guild nickname and roles. *)

(** {1 Embed support} *)

type embed =
  { title : string
  ; description : string option
  ; url : string option
  ; color : int
  ; image : string option
  ; fields : (string * string * bool) list
  }
(** Simplified Discord embed. [color] is decimal RGB (0xRRGGBB).
    [fields] are (name, value, inline) tuples. [url] is the embed link;
    [image] is the URL of an image to display. *)

val embed_to_json : embed -> Yojson.Safe.t
(** Convert an embed to its JSON representation. Exposed for testing. *)

(** Discord embed field value limit, in characters. *)

val color_blue : int
val color_green : int
(** Predefined embed colors: blue=running, green=success, red=error. *)

val link_embed :
  url:string ->
  title:string ->
  description:string option ->
  image:string option ->
  embed
(** Build a link-preview embed with optional description and thumbnail. *)

val image_embed : url:string -> caption:string option -> embed
(** Build an image embed with optional caption as the description. *)

val send_embed_message :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  token:string ->
  channel_id:string ->
  content:string ->
  ?embeds:embed list ->
  unit ->
  (string, error) result
(** [send_embed_message] posts a message with optional embeds.
    Returns the created message id on [Ok]. *)

(** [edit_embed_message] patches a message with updated content/embeds. *)

(** {1 Internal — exposed for unit testing}

    These functions decompose [send_message] so request shape and
    response classification can be tested without a real HTTP round
    trip. They are not part of the connector's stable API; callers
    should reach for {!send_message}. *)

val build_request :
  token:string ->
  channel_id:snowflake ->
  content:string ->
  ?reply_to_message_id:snowflake ->
  ?allowed_user_mentions:snowflake list ->
  unit ->
  string * (string * string) list * string
(** [(url, headers, body) = build_request ~token ~channel_id ~content
    ?reply_to_message_id ()].  Headers include Authorization (Bot
    scheme), Content-Type, a fail-closed [allowed_mentions] object, and a
    Discord-required User-Agent. When
    [reply_to_message_id] is provided, the body includes a
    [message_reference] field so Discord threads the reply. *)

val build_typing_request :
  token:string ->
  channel_id:snowflake ->
  unit ->
  string * (string * string) list * string
(** [(url, headers, body) = build_typing_request ~token ~channel_id ()].
    The body is empty; headers include Authorization and User-Agent. *)

val build_channel_request :
  token:string ->
  channel_id:snowflake ->
  unit ->
  string * (string * string) list * string

val build_guild_request :
  token:string ->
  guild_id:snowflake ->
  unit ->
  string * (string * string) list * string

val build_guild_channels_request :
  token:string ->
  guild_id:snowflake ->
  unit ->
  string * (string * string) list * string

val build_channel_messages_request :
  token:string ->
  channel_id:snowflake ->
  ?limit:int ->
  ?before:snowflake ->
  ?after:snowflake ->
  unit ->
  string * (string * string) list * string

val build_guild_members_request :
  token:string ->
  guild_id:snowflake ->
  ?query:string ->
  ?limit:int ->
  ?after:snowflake ->
  unit ->
  string * (string * string) list * string

val build_guild_member_request :
  token:string ->
  guild_id:snowflake ->
  user_id:snowflake ->
  unit ->
  string * (string * string) list * string

val build_edit_request :
  token:string ->
  channel_id:snowflake ->
  message_id:snowflake ->
  content:string ->
  unit ->
  string * (string * string) list * string
(** [(url, headers, body) = build_edit_request ~token ~channel_id
    ~message_id ~content ()].  Content exceeding {!message_content_limit}
    is silently truncated. *)

val build_embed_request :
  token:string ->
  channel_id:snowflake ->
  content:string ->
  ?embeds:embed list ->
  unit ->
  string * (string * string) list * string
(** Embed variant of {!build_request}. Body contains [embeds] array
    when embeds are provided. Exposed for unit testing. *)

val build_edit_embed_request :
  token:string ->
  channel_id:snowflake ->
  message_id:snowflake ->
  content:string ->
  ?embeds:embed list ->
  unit ->
  string * (string * string) list * string
(** Embed variant of {!build_edit_request}. Patches a message with
    updated content and/or embeds. Exposed for unit testing. *)

val parse_response :
  ?request_id:string ->
  status:int ->
  body:string ->
  unit ->
  (string, error) result
(** Classifies a Discord HTTP response:
    - 2xx with JSON object containing [id] string  → [Ok id]
    - 2xx with body shape mismatch                 → [Error (Other _)]
    - non-2xx with Discord error envelope          → [Error (Discord_api _)]
    - non-2xx without that envelope                → [Error (Http_status _)] *)

val parse_empty_response :
  ?request_id:string ->
  status:int ->
  body:string ->
  unit ->
  (unit, error) result
(** Classifies a Discord HTTP response for empty-success endpoints:
    - 2xx → [Ok ()]
    - non-2xx with Discord error envelope → [Error (Discord_api _)]
    - non-2xx without that envelope → [Error (Http_status _)] *)

val parse_json_response :
  ?request_id:string ->
  status:int ->
  body:string ->
  unit ->
  (Yojson.Safe.t, error) result
(** Classifies a JSON Discord response without imposing an endpoint-specific
    top-level shape. *)
