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
  | Http_status of { code : int; body : string }
  | Slack_api of { error : string }
  | Other of string

val pp_error : Format.formatter -> error -> unit

val message_text_limit : int
(** Slack's native [markdown_text] limit (12000 characters). Callers that may
    overflow must split themselves; this client does not. *)

val streaming_update_min_interval_sec : float
(** Minimum interval between [chat.update] calls while projecting a streaming
    reply. Slack's agent guidance currently requires at least three seconds. *)

val default_http_timeout_sec : float
(** Default deadline (seconds) for the outbound calls below. Effective only
    when the caller also threads [~clock] ({!Masc_http_client.post_sync} needs
    both); clock-less callers stay unbounded. *)

val send_message :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  token:string ->
  channel_id:string ->
  text:string ->
  ?thread_ts:string ->
  unit ->
  (string, error) result
(** [chat.postMessage] using Slack's native [markdown_text] request field.
    Returns the created message [ts] on success.
    [thread_ts] posts the message as a threaded reply. Bot token is resolved
    by the caller (so a rotation does not require a server restart). With
    [~clock] the request is bounded by [timeout_sec] (default
    {!default_http_timeout_sec}) so a stalled Slack API cannot pin the reply
    fiber. *)

val build_post_message_request :
  token:string ->
  channel_id:string ->
  text:string ->
  ?thread_ts:string ->
  unit ->
  string * (string * string) list * string
(** Pure request builder for [chat.postMessage], exposed for unit tests. The
    authored Markdown is sent unchanged as [markdown_text]; [text] and
    [blocks] are intentionally absent because Slack rejects combining them. *)

val parse_post_response :
  status:int ->
  body:string ->
  (string, error) result
(** Classifies a [chat.postMessage] response. Non-2xx HTTP status is
    [Http_status]; 2xx Slack [ok=false] is [Slack_api]. *)

val edit_message :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  token:string ->
  channel_id:string ->
  ts:string ->
  text:string ->
  unit ->
  (unit, error) result
(** [chat.update] using Slack's native [markdown_text] request field. Patches
    a prior message identified by [channel] + [ts].
    Used by the in-process gateway to project keeper streaming snapshots
    into one edited reply. Bounded by [timeout_sec] (default
    {!default_http_timeout_sec}) when [~clock] is supplied. *)

val build_update_request :
  token:string ->
  channel_id:string ->
  ts:string ->
  text:string ->
  unit ->
  string * (string * string) list * string
(** Pure request builder for [chat.update], exposed for unit tests. The same
    single-content-field contract as {!build_post_message_request} applies. *)

val parse_update_response :
  status:int ->
  body:string ->
  (unit, error) result
(** Classifies a [chat.update] response. Non-2xx HTTP status is
    [Http_status]; 2xx Slack [ok=false] is [Slack_api]. *)

(** Bot identity resolved from [auth.test]. *)
type auth_test_ok = {
  user_id : string;       (** The bot's own Slack user id ([U...]). *)
  team_id : string option;
}

val auth_test :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  token:string ->
  unit ->
  (auth_test_ok, error) result
(** [auth.test]. Resolves the bot's own [user_id] (for inbound mention
    detection) and [team_id] (for the Slack surface) from the bot token
    ([xoxb-...]). Called once at gateway start; bounded by [timeout_sec]
    (default {!default_http_timeout_sec}) when [~clock] is supplied so a
    stalled auth.test cannot pin the gateway boot fiber. *)

val build_auth_test_request :
  token:string -> string * (string * string) list * string
(** Pure request builder for [auth.test], exposed for unit tests. *)

val parse_auth_test_response :
  status:int ->
  body:string ->
  (auth_test_ok, error) result
(** Classifies an [auth.test] response. Non-2xx HTTP status is [Http_status];
    2xx Slack [ok=false] is [Slack_api]; [ok=true] without [user_id] is
    [Other]. *)
