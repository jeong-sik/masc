(** Discord_rest_client — outbound Discord REST API client.

    Single function: post a message to a channel. Threads, DMs, and
    guild text channels are all addressed by the same snowflake
    [channel_id], so no per-surface dispatch is needed.

    Phase 1.1 (RFC-0203): typed surface only. {!send_message} returns
    [Error] until Phase 2 wires it through {!Masc_http_client.Pool}.

    See: docs/rfc/RFC-0203-discord-builtin-gateway.md §Modules,
         lib/masc_http_client/pool.mli *)

(** Typed error from Discord REST. Closed sum — anything Discord
    returns that does not map to one of these becomes [Other]
    (preserving the JSON for inspection) so we never silently consume
    a new error variant. *)
type error =
  | Network of string
  | Http_status of { code : int; body : string }
  | Discord_api of { code : int; message : string }
  | Other of string

val pp_error : Format.formatter -> error -> unit

val send_message :
  token:string ->
  channel_id:string ->
  content:string ->
  (string, error) result
(** [send_message ~token ~channel_id ~content] posts to
    [POST /api/v10/channels/{channel_id}/messages] with body
    [{"content": <content>}]. Returns the created message id on [Ok].

    Works for guild text channels, DM channels (use the snowflake
    Discord returns from [POST /users/@me/channels]), and threads.

    @raise nothing — failures are surfaced as typed {!error}. *)
