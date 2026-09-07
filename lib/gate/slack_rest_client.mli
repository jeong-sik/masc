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

(** One user's profile names from [users.info] (issue #28376). Blank fields
    are [None], never empty labels. *)
type user_info_ok = {
  user_id : string;
  name : string option;         (** Legacy handle. *)
  real_name : string option;    (** [profile.real_name]. *)
  display_name : string option; (** [profile.display_name]. *)
}

type conversation_info_ok = {
  channel_id : string;
  channel_name : string option;
}
(** [channel_name] is absent for a direct message and for a blank name, so a
    renderer never prints an empty label where a channel goes. *)

val conversations_info :
  ?clock:_ Eio.Time.clock ->
  ?timeout_sec:float ->
  token:string ->
  channel_id:string ->
  unit ->
  (conversation_info_ok, error) result
(** [conversations.info] for one channel. Needs [channels:read] (public) or
    [groups:read] (private) on the token; without them Slack answers
    [missing_scope], which is a typed {!Slack_api} error and not a crash. *)

val users_info :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  token:string ->
  user_id:string ->
  unit ->
  (user_info_ok, error) result
(** [users.info] for one Slack user id. Bounded by [timeout_sec] (default
    {!default_http_timeout_sec}) when [~clock] is supplied. A missing
    [users:read] scope surfaces as [Slack_api]. *)

val build_users_info_request :
  token:string -> user_id:string -> string * (string * string) list * string
(** Pure request builder for [users.info], exposed for unit tests. *)

val parse_users_info_response :
  status:int -> body:string -> (user_info_ok, error) result
(** Classifies a [users.info] response. Non-2xx HTTP status is
    [Http_status]; 2xx Slack [ok=false] is [Slack_api]. *)

(** One message from [conversations.history]. The fields the slack-lane poll
    fiber filters on are typed; text carries the body as Slack rendered it. *)
type history_message = {
  ts : string;
  user_id : string option;   (** Absent when the author is an app/bot. *)
  bot_id : string option;    (** Present for app/bot authors. *)
  subtype : string option;   (** Present for message_changed, joins, … *)
  thread_ts : string option; (** Present when this is a thread reply. *)
  text : string;
}

type conversations_history_ok = {
  messages : history_message list;  (** Slack order: newest first. *)
  has_more : bool;
  next_cursor : string option;      (** [response_metadata.next_cursor]. *)
}

val conversations_history :
  ?clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  ?timeout_sec:float ->
  token:string ->
  channel_id:string ->
  ?oldest:string ->
  ?limit:int ->
  ?cursor:string ->
  unit ->
  (conversations_history_ok, error) result
(** [conversations.history] for one channel after [oldest] (exclusive, a
    message ts). Needs [channels:history] (public) or [groups:history]
    (private) on the token; a missing scope surfaces as [Slack_api], not a
    crash. One page per call — pagination belongs to the caller via
    {!conversations_history_ok.next_cursor}. *)

val build_conversations_history_request :
  token:string ->
  channel_id:string ->
  ?oldest:string ->
  ?limit:int ->
  ?cursor:string ->
  unit ->
  string * (string * string) list * string
(** Pure request builder for [conversations.history], exposed for unit
    tests. *)

val parse_conversations_history_response :
  status:int -> body:string -> (conversations_history_ok, error) result
(** Classifies a [conversations.history] response. Non-2xx HTTP status is
    [Http_status]; 2xx Slack [ok=false] is [Slack_api]; a message entry
    without [ts] is [Other] — Slack keys messages by [ts], so its absence is
    a broken page, not a skippable entry. *)
