(** Agent Identity - Unified Agent Identification across MCP sessions

    OpenClaw-inspired session tracking for multi-agent environments.
    Provides consistent agent identification across:
    - MCP tool calls
    - Room coordination
    - Task assignments
    - Federation/portal messages

    @since 0.5.0
*)

(** {1 Core Types} *)

(** Channel/surface type - where the agent is connected from *)
type channel =
  | Telegram
  | Discord
  | Slack
  | Signal
  | Webchat
  | Api
  | Internal
  | Unknown of string
[@@deriving yojson]

(** Agent identity - extracted from session/request context *)
type t = {
  session_key : string;           (** Unique session identifier *)
  agent_name : string;            (** Display name (e.g., "claude-agent-001") *)
  channel : channel option;       (** Source channel if known *)
  user_id : string option;        (** User ID from channel (e.g., telegram user id) *)
  room_id : string option;        (** Current room if joined *)
  capabilities : string list;     (** Declared agent capabilities *)
  registered_at : float;          (** Unix timestamp *)
  mutable last_seen : float;      (** Last activity timestamp *)
  metadata : (string * string) list;  (** Additional metadata *)
}
[@@deriving yojson]

(** {1 Channel Parsing} *)

let channel_of_string = function
  | "telegram" -> Telegram
  | "discord" -> Discord
  | "slack" -> Slack
  | "signal" -> Signal
  | "webchat" -> Webchat
  | "api" -> Api
  | "internal" -> Internal
  | s -> Unknown s

let string_of_channel = function
  | Telegram -> "telegram"
  | Discord -> "discord"
  | Slack -> "slack"
  | Signal -> "signal"
  | Webchat -> "webchat"
  | Api -> "api"
  | Internal -> "internal"
  | Unknown s -> s

(** {1 Identity Creation} *)

(** Generate a unique session key *)
let generate_session_key () =
  let uuid = Uuidm.v4_gen (Random.State.make_self_init ()) () in
  Uuidm.to_string uuid

(** Create identity from MCP request params *)
let from_mcp_params params =
  let open Yojson.Safe.Util in
  let get_opt key =
    try Some (params |> member key |> to_string)
    with _ -> None
  in
  let session_key = match get_opt "_session_key" with
    | Some k -> k
    | None -> generate_session_key ()
  in
  let agent_name = match get_opt "_agent_name", get_opt "agent_name" with
    | Some n, _ | _, Some n -> n
    | None, None -> Printf.sprintf "agent-%s" (String.sub session_key 0 8)
  in
  let channel = match get_opt "_channel" with
    | Some c -> Some (channel_of_string c)
    | None -> None
  in
  let user_id = get_opt "_user_id" in
  let room_id = get_opt "room" in
  let capabilities = try
    params |> member "_capabilities" |> to_list |> List.map to_string
  with _ -> []
  in
  let now = Unix.gettimeofday () in
  {
    session_key;
    agent_name;
    channel;
    user_id;
    room_id;
    capabilities;
    registered_at = now;
    last_seen = now;
    metadata = [];
  }

(** Create identity from agent_name (legacy support) *)
let from_agent_name agent_name =
  let now = Unix.gettimeofday () in
  {
    session_key = generate_session_key ();
    agent_name;
    channel = None;
    user_id = None;
    room_id = None;
    capabilities = [];
    registered_at = now;
    last_seen = now;
    metadata = [];
  }

(** Create anonymous/unknown identity *)
let anonymous () =
  let now = Unix.gettimeofday () in
  let key = generate_session_key () in
  {
    session_key = key;
    agent_name = Printf.sprintf "anon-%s" (String.sub key 0 8);
    channel = None;
    user_id = None;
    room_id = None;
    capabilities = [];
    registered_at = now;
    last_seen = now;
    metadata = [];
  }

(** {1 Identity Registry} *)

module Registry = struct
  type registry = {
    identities : (string, t) Hashtbl.t;  (** session_key -> identity *)
    by_agent_name : (string, string) Hashtbl.t;  (** agent_name -> session_key *)
    lock : Eio.Mutex.t;
  }

  let create () = {
    identities = Hashtbl.create 64;
    by_agent_name = Hashtbl.create 64;
    lock = Eio.Mutex.create ();
  }

  let with_lock reg f =
    Eio.Mutex.use_rw ~protect:true reg.lock (fun () -> f ())

  (** Register or update identity *)
  let register reg identity =
    with_lock reg (fun () ->
      Hashtbl.replace reg.identities identity.session_key identity;
      Hashtbl.replace reg.by_agent_name identity.agent_name identity.session_key;
      identity
    )

  (** Find by session key *)
  let find_by_session reg session_key =
    with_lock reg (fun () ->
      Hashtbl.find_opt reg.identities session_key
    )

  (** Find by agent name *)
  let find_by_name reg agent_name =
    with_lock reg (fun () ->
      match Hashtbl.find_opt reg.by_agent_name agent_name with
      | Some session_key -> Hashtbl.find_opt reg.identities session_key
      | None -> None
    )

  (** Update last_seen and optionally room *)
  let touch reg session_key ?room_id () =
    with_lock reg (fun () ->
      match Hashtbl.find_opt reg.identities session_key with
      | Some identity ->
          identity.last_seen <- Unix.gettimeofday ();
          (match room_id with
           | Some rid -> 
               let updated = { identity with room_id = Some rid } in
               Hashtbl.replace reg.identities session_key updated
           | None -> ())
      | None -> ()
    )

  (** Remove identity *)
  let unregister reg session_key =
    with_lock reg (fun () ->
      match Hashtbl.find_opt reg.identities session_key with
      | Some identity ->
          Hashtbl.remove reg.identities session_key;
          Hashtbl.remove reg.by_agent_name identity.agent_name
      | None -> ()
    )

  (** List all active identities (active within last N seconds) *)
  let list_active reg ~within_seconds =
    with_lock reg (fun () ->
      let cutoff = Unix.gettimeofday () -. within_seconds in
      Hashtbl.to_seq_values reg.identities
      |> Seq.filter (fun id -> id.last_seen > cutoff)
      |> List.of_seq
    )

  (** Get identity count *)
  let count reg =
    with_lock reg (fun () ->
      Hashtbl.length reg.identities
    )
end

(** {1 Utilities} *)

(** Check if identity has a specific capability *)
let has_capability identity cap =
  List.mem cap identity.capabilities

(** Get display string for logging *)
let to_display_string identity =
  let channel_str = match identity.channel with
    | Some c -> Printf.sprintf " via %s" (string_of_channel c)
    | None -> ""
  in
  let room_str = match identity.room_id with
    | Some r -> Printf.sprintf " in %s" r
    | None -> ""
  in
  Printf.sprintf "%s (%s)%s%s"
    identity.agent_name
    (String.sub identity.session_key 0 8)
    channel_str
    room_str

(** Check if two identities refer to the same agent *)
let same_agent a b =
  a.session_key = b.session_key || a.agent_name = b.agent_name
