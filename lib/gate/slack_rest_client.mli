(** Slack_rest_client — outbound Slack Web API.

    Thin wrapper over {!Masc_http_client.post_sync}, mirroring
    {!Discord_rest_client}. The bot token ([xoxb-...]) for outbound REST is
    distinct from the app token ([xapp-...]) the inbound Socket Mode client
    ({!Slack_socket_client}) uses for [apps.connections.open].

    Slack's Web API always answers HTTP 200 with [{ ok: bool, error?: string }]
    even on logical failure, so failures surface as {!Slack_api}, not HTTP
    status. See RFC-0317. *)

type error =
  | Network of string
  | Slack_api of { error : string }
  | Other of string

val pp_error : Format.formatter -> error -> unit

val message_text_limit : int
(** Slack's per-message text limit (40000). Callers that may overflow must
    split themselves; this client does not. *)

val send_message :
  token:string ->
  channel_id:string ->
  text:string ->
  ?thread_ts:string ->
  unit ->
  (string, error) result
(** [chat.postMessage]. Returns the created message [ts] on success.
    [thread_ts] posts the message as a threaded reply. Bot token is resolved
    by the caller (so a rotation does not require a server restart). *)

val edit_message :
  token:string ->
  channel_id:string ->
  ts:string ->
  text:string ->
  unit ->
  (unit, error) result
(** [chat.update]. Patches a prior message identified by [channel] + [ts].
    Used by the in-process gateway to project keeper streaming snapshots
    into one edited reply. *)
