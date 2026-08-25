(** Agent Identity - Unified Agent Identification across MCP sessions

    OpenClaw-inspired session tracking for multi-agent environments.
    Provides consistent agent identification across:
    - MCP tool calls
    - Workspace workspace
    - Task assignments
    - Federation/portal messages

    @since 0.5.0
*)

(** Typed classification of a session_key's display prefix.

    Replaces the previous string-collapsing helpers that mapped
    zero-length keys to the literal ["unknown"] inside both
    [from_mcp_params] and [to_display_string]. The collapse made it
    impossible for callers to distinguish a genuinely empty key from a
    key whose first eight bytes happened to spell ["unknown"], and it
    silenced short-key cases that downstream display logic might want
    to flag.

    Each call site now matches exhaustively on this closed sum, so any
    future variant (e.g. truncated/hashed prefix) forces an explicit
    decision at every consumer instead of being silently merged into a
    catch-all string. *)
type session_key_prefix =
  | Empty_session_key
      (** Original key had zero length — no usable display prefix. *)
  | Short_session_key of string
      (** Key shorter than 8 bytes; the entire key is the prefix. *)
  | Prefix of string
      (** Exactly the first 8 bytes of a key ≥ 8 bytes long. *)

let classify_session_key_prefix session_key =
  let len = String.length session_key in
  if len = 0 then Empty_session_key
  else if len < 8 then Short_session_key session_key
  else Prefix (String.sub session_key 0 8)

(** {1 Core Types} *)

(** Connection surface known to core.
    External platform names stay opaque so core does not depend on connector vendors. *)
type channel =
  | Api
  | Internal
  | External of string

(** {1 Channel Parsing} *)

let normalize_channel_label s =
  let normalized = String.trim s |> String.lowercase_ascii in
  if String.equal normalized "" then "unknown" else normalized

let channel_of_string s =
  match normalize_channel_label s with
  | "api" -> Api
  | "internal" -> Internal
  | "unknown" -> External "unknown"
  | other -> External other

let string_of_channel = function
  | Api -> "api"
  | Internal -> "internal"
  | External s -> normalize_channel_label s

let channel_to_yojson = function
  | Api -> `String "Api"
  | Internal -> `String "Internal"
  | External s ->
      `List [ `String "External"; `String (normalize_channel_label s) ]

let channel_of_yojson = function
  | `String "Api" | `String "api" -> Ok Api
  | `String "Internal" | `String "internal" -> Ok Internal
  | `String "Telegram" | `String "telegram" ->
      Ok (External "telegram")
  | `String "Discord" | `String "discord" ->
      Ok (External "discord")
  | `String "Slack" | `String "slack" -> Ok (External "slack")
  | `String "Signal" | `String "signal" -> Ok (External "signal")
  | `String "Webchat" | `String "webchat" ->
      Ok (External "webchat")
  | `String s -> Ok (channel_of_string s)
  | `List [ `String "External"; `String s ] ->
      Ok (External (normalize_channel_label s))
  | `List [ `String "Unknown"; `String s ] ->
      Ok (External (normalize_channel_label s))
  | other ->
      (* Accepted contract is one of:
         - bare [`String "api" | "internal" | "telegram" | ... | "<freeform>"]
         - tagged 2-tuple [`List [`String "External"|"Unknown"; `String _]]
         Non-conforming inputs now name the kind we actually saw, so
         operators chasing a misshapen [channel] field can tell a
         wrong-type bug ([`Int] / [`Null]) apart from a wrong-shape
         tagged variant ([`List] of wrong length / wrong leading tag)
         by reading the kind alone — without re-dumping the payload. *)
      Error
        (Printf.sprintf
           "channel_of_yojson: expected JSON string (e.g. \"api\" / \"telegram\") \
            or 2-element tagged list [\"External\"|\"Unknown\"; <label>], got %s"
           (Json_util.kind_name other))

(** Provenance of [agent_name]: whether the caller supplied it or the
    system minted a fallback.

    Carried so the auth-fallback gate in
    [Mcp_server_eio_caller_identity] can decide ephemerality from a
    typed origin instead of re-probing the name string with
    [String.starts_with name ~prefix:"agent-"]. The string [agent_name]
    field laundered this provenance away: by read time a
    system-generated ["agent-…"] fallback and an externally resolved
    name are both bare strings, so the only way to recover the origin
    was a substring probe. Deciding the origin once, here at the mint
    site, removes that probe.

    A mandatory field on [t] forces every record constructor to declare
    the provenance, so a new mint path cannot silently default to
    [`Supplied]. *)
type agent_name_origin =
  [ `Supplied        (** [_agent_name]/[agent_name] was provided by the caller. *)
  | `System_fallback (** No name given; this module minted a fallback. *)
  ]
[@@deriving to_yojson]

(** Agent identity - extracted from session/request context *)
type t = {
  uuid : string;                  (** Permanent UUIDv7 identifier *)
  session_key : string;           (** Unique session identifier *)
  agent_name : string;            (** Display name (e.g., "claude-agent-001") *)
  agent_name_origin : agent_name_origin;
      (** Provenance of [agent_name] (see {!agent_name_origin}). *)
  channel : channel option;       (** Source channel if known *)
  user_id : string option;        (** User ID from channel (e.g., telegram user id) *)
  capabilities : string list;     (** Declared agent capabilities *)
  registered_at : float;          (** Unix timestamp *)
  last_seen : float;              (** Last activity timestamp *)
  metadata : (string * string) list;  (** Additional metadata *)
}
[@@deriving to_yojson]

(** Generate a permanent UUID. [agent_name] is intentionally not encoded in
    the identifier; it remains display metadata. *)
let generate_uuid ~agent_name:_ =
  Random_id.uuid_v7 ()

(** {1 Identity Creation} *)

(** Generate a unique session key *)
let generate_session_key () =
  Random_id.hex ~bytes:16

(** Create identity from MCP request params *)
let from_mcp_params params =
  (* #9788: normalize null/non-object payloads to empty assoc so
     Json_util.get_string below cannot raise Type_error and crash
     tools/call dispatch. *)
  let params = match params with `Assoc _ -> params | _ -> `Assoc [] in
  let get_opt key = Json_util.get_string params key in
  let fallback_agent_name session_key =
    match classify_session_key_prefix session_key with
    | Empty_session_key -> "agent-anon"
    | Short_session_key s -> Printf.sprintf "agent-%s" s
    | Prefix s -> Printf.sprintf "agent-%s" s
  in
  let session_key = match get_opt "_session_key" with
    | Some k ->
        let k = String.trim k in
        if String.equal k "" then generate_session_key () else k
    | None -> generate_session_key ()
  in
  let agent_name, agent_name_origin =
    match get_opt "_agent_name", get_opt "agent_name" with
    | Some n, _ | _, Some n -> (n, `Supplied)
    | None, None -> (fallback_agent_name session_key, `System_fallback)
  in
  let channel = match get_opt "_channel" with
    | Some c -> Some (channel_of_string c)
    | None -> None
  in
  let user_id = get_opt "_user_id" in
  let capabilities = Json_util.get_string_list params "_capabilities" in
  let now = Time_compat.now () in
  {
    uuid = generate_uuid ~agent_name;
    session_key;
    agent_name;
    agent_name_origin;
    channel;
    user_id;
    capabilities;
    registered_at = now;
    last_seen = now;
    metadata = [];
  }

(** Create anonymous/unknown identity *)
let anonymous () =
  let now = Time_compat.now () in
  let key = generate_session_key () in
  let name = Printf.sprintf "anon-%s" (String.sub key 0 8) in
  {
    uuid = generate_uuid ~agent_name:name;
    session_key = key;
    agent_name = name;
    (* [anonymous] mints its own ["anon-…"] name; the caller supplied
       nothing, so the provenance is a system fallback. *)
    agent_name_origin = `System_fallback;
    channel = None;
    user_id = None;
    capabilities = [];
    registered_at = now;
    last_seen = now;
    metadata = [];
  }

(** {1 Utilities} *)

(** Check if identity has a specific capability *)
let has_capability identity cap =
  List.mem cap identity.capabilities

(** Get display string for logging *)
let to_display_string identity =
  let prefix_str =
    match classify_session_key_prefix identity.session_key with
    | Empty_session_key -> "unknown"
    | Short_session_key s -> s
    | Prefix s -> s
  in
  let channel_str = match identity.channel with
    | Some c -> Printf.sprintf " via %s" (string_of_channel c)
    | None -> ""
  in
  Printf.sprintf "%s (%s)%s"
    identity.agent_name
    prefix_str
    channel_str

(** Check if two identities refer to the same agent *)
let same_agent a b =
  String.equal a.session_key b.session_key || String.equal a.agent_name b.agent_name
